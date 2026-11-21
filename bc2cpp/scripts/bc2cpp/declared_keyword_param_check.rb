#!/usr/bin/env ruby
# frozen_string_literal: true

# DECLARED_KEYWORD_PARAM (RbsParamCheck.keyword_guards): a keyword parameter an RBS signature types with a guardable
# kind (a value kind, Array/Hash/String, or a program class nothing subclasses, `T?` included) is checked right after
# the KARG that writes it, and the flow reads KARG's result as that kind. An omitted keyword's default is ordinary code.
#
#   1. generated: `b.size2` on a declared `?b: Foo?` (default nil) is a direct call past the nil test, with the guard
#      after its KARG; a required `foo: Foo`, `?n: Integer` and `?xs: Array[Integer]` are guarded; an untyped keyword
#      and a signature whose keywords are not the body's give no guard; the guarded body is not inlined;
#   2. the guard contract (DeclaredReturns.keyword_guard_failures) refuses a compiled body without the guard;
#   3. run on a full-core mruby against interpreted: the calls answer as interpreted, and a wrong keyword value raises
#      BC2cppDeclarationViolation.
#
# Usage: MRBC=path/to/host/mrbc [BC2CPP_FULL_BUILD_DIR=dir] ruby scripts/bc2cpp/declared_keyword_param_check.rb

require 'tmpdir'
require 'fileutils'
require_relative 'check_support'
require_relative 'fixture_runtime'
require_relative '../../tools/bc2cpp/declared_returns'

suite = FixtureCheck.new('declared_keyword_param_check')
check = suite.method(:check)
suite.require_mrbc!
runtime = Bc2cppFixtureRuntime

SOURCE = <<~RUBY
  class Foo
    def initialize
      @v = 1
      nil
    end

    def size2
      @v + 1
    end
  end

  class Menu
    def pick(a, b: nil)
      return a.size2 if b.nil?

      b.size2
    end

    def need(foo:)
      foo.size2
    end

    def counted(n: 2)
      n + 1
    end

    def items(xs: [])
      xs.size
    end

    def loose(a, k: nil)
      return 0 if k.nil?

      k.size2
    end

    def renamed(a, c: nil)
      return 0 if c.nil?

      c.size2
    end

    def blk(xs, f: Foo.new)
      xs.map { |x| f.size2 + x }.size
    end

    def run
      f = Foo.new
      pick(f) + pick(f, b: f) + need(foo: f) + counted + counted(n: 5) + items + items(xs: [1, 2]) +
        loose(f, k: f) + renamed(f, c: f) + blk([1]) + blk([2], f: f)
    end

    def wrong
      pick(Foo.new, b: 'x')
    end

    def wrong_need
      need(foo: 3)
    end

    def wrong_items
      items(xs: 'z')
    end
  end
RUBY

SIGNATURES = <<~RBS
  class Foo
    def size2: () -> Integer
  end
  class Menu
    def pick: (Foo a, ?b: Foo?) -> Integer
    def need: (foo: Foo) -> Integer
    def counted: (?n: Integer) -> Integer
    def items: (?xs: Array[Integer]) -> Integer
    def loose: (Foo a, ?k: untyped) -> Integer
    def renamed: (Foo a, ?b: Foo?) -> Integer
    def blk: (Array[Integer] xs, ?f: Foo) -> Integer
  end
RBS
OWNERS = %w[Foo Menu].freeze

HARNESS = <<~'CPP'
  static int scenario(mrb_state* M) {
    mrb_value menu = mrb_obj_new(M, mrb_class_get(M, "Menu"), 0, nullptr);
    call(M, "run", menu, "run");
    call(M, "wrong pick", menu, "wrong");
    call(M, "wrong need", menu, "wrong_need");
    call(M, "wrong items", menu, "wrong_items");
    return 0;
  }
CPP

generate = lambda do |dir, env = {}|
  env.each { |k, v| ENV[k] = v }
  sigs = File.join(dir, 'sig')
  FileUtils.mkdir_p(sigs)
  File.write(File.join(sigs, 'menu.rbs'), SIGNATURES)
  ENV['BC2CPP_SIG_DIRS'] = sigs
  code, err = runtime.generate(SOURCE, dir, only_owners: OWNERS)
  [code, err, code.split(%r{^(?=// \w+#)}).to_h { |part| [part[%r{\A// (\S+)}, 1], part] }]
ensure
  ENV.delete('BC2CPP_SIG_DIRS')
  env.each_key { |k| ENV.delete(k) }
end
guard = ->(body, name, kw) { body.to_s.include?("/* DECLARED_KEYWORD_GUARD Menu##{name} #{kw}: */") }
direct = ->(body) { body.to_s.include?('MONO_EXACT_FLOW :size2 -> Foo#size2') && !body.to_s.include?('CLOSED_WORLD nomethod: recv.size2') }

Dir.mktmpdir('declared-keyword-param') do |dir|
  code, err, by = generate.call(dir)
  check.call('a given `?b: Foo?` is checked after its KARG',
             by['Menu#pick'].to_s.match?(/mrb_nil_p\((\w+)\) \|\| \(bc2cpp_class_is\(M, \1,/) && guard.call(by['Menu#pick'], 'pick', 'b'))
  check.call('`b.size2` past the nil test is a direct call', direct.call(by['Menu#pick']))
  check.call('a required `foo: Foo` is guarded and its call is direct',
             guard.call(by['Menu#need'], 'need', 'foo') && direct.call(by['Menu#need']))
  check.call('`?n: Integer` and `?xs: Array[Integer]` are guarded by their kind',
             by['Menu#counted'].to_s.include?('mrb_fixnum_p(') && guard.call(by['Menu#counted'], 'counted', 'n') &&
               by['Menu#items'].to_s.include?('mrb_array_p(') && guard.call(by['Menu#items'], 'items', 'xs'))
  check.call('an untyped keyword gives no guard', !by['Menu#loose'].to_s.include?('DECLARED_KEYWORD_GUARD'))
  check.call("a signature whose keywords are not the body's gives no guard",
             !by['Menu#renamed'].to_s.include?('DECLARED_KEYWORD_GUARD'))
  # CAPTURED_LATER_WRITES: the KEY_P flag the keyword's register held before the block existed is no value the block
  # can read, so `f` in the block is the declared Foo.
  check.call('a block reads a declared keyword as its class (CAPTURED_LATER_WRITES)', direct.call(by['Menu#blk']))
  Dir.mktmpdir('declared-keyword-param-off') do |off_dir|
    _, _, off = generate.call(off_dir, 'BC2CPP_CAPTURED_LATER_WRITES' => '0')
    check.call('BC2CPP_CAPTURED_LATER_WRITES=0 keeps the KEY_P flag in the block\'s class set', !direct.call(off['Menu#blk']))
  end
  check.call('the guarded body is not inlined', !by['Menu#run'].to_s.include?('CALL_INLINE Menu#need'))

  guards = { 'x' => { 'b' => ['b', 'Foo', 'Menu#pick', 'b: Foo?', :class, true] } }
  check.call('the contract refuses a compiled body without its keyword guard',
             DeclaredReturns.keyword_guard_failures(guards, [{ label: 'x', code: 'mrb_value f() {}' }]).size == 1 &&
               DeclaredReturns.keyword_guard_failures(guards, [{ label: 'x', code: '#error x' }]).empty? &&
               DeclaredReturns.keyword_guard_failures(
                 guards, [{ label: 'x', code: '/* DECLARED_KEYWORD_GUARD Menu#pick b: */' }]
               ).empty?)

  build = runtime.full_or_build
  if build
    built, output = runtime.run(dir, err, OWNERS, HARNESS, build: build, full: true)
    sections = runtime.sections(output)
    plain = ->(lines) { lines.to_a.reject { |l| l.start_with?('  dispatches=') } }
    compiled = plain.call(sections['compiled'])
    interpreted = plain.call(sections['interpreted'])
    wrong = ->(lines) { lines.grep(/\Awrong /) }
    check.call('built and ran', built)
    check.call('the calls answer as interpreted',
               !compiled.empty? && compiled - wrong.call(compiled) == interpreted - wrong.call(interpreted))
    check.call('a wrong keyword value raises the violation in the compiled run',
               wrong.call(compiled) == ['wrong pick => raised BC2cppDeclarationViolation',
                                        'wrong need => raised BC2cppDeclarationViolation',
                                        'wrong items => raised BC2cppDeclarationViolation'])
    warn output unless built && compiled.size == interpreted.size
  else
    puts '  SKIP run: no full-core mruby build'
  end
  File.write(File.join(dir, 'keep.cpp'), code) if ENV['BC2CPP_KEEP_DIR']
end

suite.finish!
