#!/usr/bin/env ruby
# frozen_string_literal: true

# DECLARED_OPTIONAL_PARAM (rbs_param_check.rb optional_targets): an optional parameter declared `?T` whose default is
# a literal of T (or `?T?` with a nil default) is checked on entry like a required one, and only when the call gives
# it (`bc2cpp_given_opt > k`); an omitted one holds its default. The class pool seeds it, so the body reads it as T.
#
#   1. generated (Array, Hash and String by their kind test, required ones too): `b.size2` on a declared `?Foo?` (default nil) is a direct call once the nil test passed, with the
#      guard on the given argument; `?Integer` with an Integer default is guarded; a default that is not a literal of
#      the declared kind, a default reading a later optional, and a `?untyped` optional give no guard (TC1005 info for
#      the typed ones); the guarded body is not inlined;
#   2. the guard contract (DeclaredReturns.optional_param_guard_failures) refuses a compiled body without the guard;
#   3. run on a full-core mruby against interpreted: the calls answer as interpreted, and a wrong given argument raises
#      BC2cppDeclarationViolation;
#   4. DECLARED_NUMERIC_ENTRY: a required Integer (Float) parameter is an Integer (numeric) operand past its guard, and
#      BC2CPP_DECLARED_NUMERIC_ENTRY=0 takes that back;
#   5. a singleton method's declaration (`def self.x`, a `class << self` def, a module's `def self.x`) is guarded and
#      seeds its body the same way, and a wrong argument raises the violation.
#
# Usage: MRBC=path/to/host/mrbc [BC2CPP_FULL_BUILD_DIR=dir] ruby scripts/bc2cpp/declared_optional_param_check.rb

require 'tmpdir'
require 'fileutils'
require_relative 'check_support'
require_relative 'fixture_runtime'
require_relative '../../tools/bc2cpp/declared_returns'

suite = FixtureCheck.new('declared_optional_param_check')
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
    def pick(a, b = nil)
      return a.size2 if b.nil?

      b.size2
    end

    def add(a, b = 2)
      a.size2 + b
    end

    def computed(a, b = a)
      return 0 if b.nil?

      b.size2
    end

    def later(a, b = c, c = nil)
      return 1 if c.nil?

      c.size2
    end

    def loose(a, b = nil)
      return 0 if b.nil?

      b.size2
    end

    def sorted(a, xs = [])
      (xs || []).size + a.size2
    end

    def keys_of(h)
      h.keys.size
    end

    def shout(s)
      s.upcase
    end

    def scale(n)
      n * 3 + 1
    end

    def halve(x)
      x / 2
    end

    def run
      f = Foo.new
      pick(f) + pick(f, f) + add(f) + add(f, 5) + computed(f) + later(f) + later(f, 1, f) + loose(f, f) +
        sorted(f) + sorted(f, [3, 1]) + sorted(f, nil) + keys_of({ a: 1 }) + shout('a').size +
        scale($menu_n) + halve($menu_f).to_i
    end

    def wrong_scale
      scale($menu_f)
    end

    def wrong_sorted
      sorted(Foo.new, 'z')
    end

    def wrong
      pick(Foo.new, 'x')
    end

    def wrong_add
      add(Foo.new, 'y')
    end

    def self.cpick(a, b = nil)
      return a.size2 if b.nil?

      b.size2
    end

    class << self
      def epick(a)
        a.size2 + a.size2
      end
    end
  end

  module Tools
    def self.mpick(a)
      a.size2 + a.size2
    end

    def self.run
      f = Foo.new
      Menu.cpick(f) + Menu.cpick(f, f) + Menu.epick(f) + mpick(f)
    end

    def self.wrong
      Menu.cpick(Foo.new, 'x')
    end

    def self.wrong_e
      Menu.epick('x')
    end

    def self.wrong_m
      mpick(1)
    end
  end
RUBY

SIGNATURES = <<~RBS
  class Foo
    def size2: () -> Integer
  end
  class Menu
    def pick: (Foo a, ?Foo? b) -> Integer
    def add: (Foo a, ?Integer b) -> Integer
    def computed: (Foo a, ?Foo? b) -> Integer
    def later: (Foo a, ?untyped b, ?Foo? c) -> Integer
    def loose: (Foo a, ?untyped b) -> Integer
    def sorted: (Foo a, ?Array[Integer]? xs) -> Integer
    def keys_of: (Hash[Symbol, Integer] h) -> Integer
    def shout: (String s) -> String
    def scale: (Integer n) -> Integer
    def halve: (Float x) -> Float
    def self.cpick: (Foo a, ?Foo? b) -> Integer
    def self.epick: (Foo a) -> Integer
  end
  module Tools
    def self.mpick: (Foo a) -> Integer
  end
RBS
OWNERS = %w[Foo Menu Menu.singleton Tools Tools.singleton].freeze

HARNESS = <<~'CPP'
  static int scenario(mrb_state* M) {
    mrb_value menu = mrb_obj_new(M, mrb_class_get(M, "Menu"), 0, nullptr);
    mrb_gv_set(M, mrb_intern_lit(M, "$menu_n"), mrb_fixnum_value(4));
    mrb_gv_set(M, mrb_intern_lit(M, "$menu_f"), mrb_float_value(M, 5.0));
    call(M, "run", menu, "run");
    call(M, "wrong pick", menu, "wrong");
    call(M, "wrong add", menu, "wrong_add");
    call(M, "wrong sorted", menu, "wrong_sorted");
    call(M, "wrong scale", menu, "wrong_scale");
    mrb_value tools = mrb_obj_value(mrb_module_get(M, "Tools"));
    call(M, "singleton run", tools, "run");
    call(M, "wrong singleton", tools, "wrong");
    call(M, "wrong eigenclass", tools, "wrong_e");
    call(M, "wrong module", tools, "wrong_m");
    return 0;
  }
CPP

generate = lambda do |dir, env = {}|
  saved = env.to_h { |k, _| [k, ENV[k]] }
  env.each { |k, v| ENV[k] = v }
  sigs = File.join(dir, 'sig')
  FileUtils.mkdir_p(sigs)
  File.write(File.join(sigs, 'menu.rbs'), SIGNATURES)
  ENV['BC2CPP_SIG_DIRS'] = sigs
  code, err = runtime.generate(SOURCE, dir, only_owners: OWNERS)
  [code, err, code.split(%r{^(?=// [\w.]+#)}).to_h { |part| [part[%r{\A// (\S+)}, 1], part] }]
ensure
  ENV.delete('BC2CPP_SIG_DIRS')
  saved&.each { |k, v| v.nil? ? ENV.delete(k) : ENV[k] = v }
end
guard = lambda do |body, name, arg, owner = 'Menu'|
  body.to_s.include?("/* DECLARED_PARAM_GUARD #{owner}##{name} arg #{arg} */")
end
direct = ->(body) { body.to_s.include?('MONO_EXACT_FLOW :size2 -> Foo#size2') && !body.to_s.include?('CLOSED_WORLD nomethod: recv.size2') }

Dir.mktmpdir('declared-optional-param') do |dir|
  code, err, by = generate.call(dir)
  check.call('a given `?Foo?` argument is checked only when given',
             by['Menu#pick'].to_s.include?('bc2cpp_given_opt <= 0 || (mrb_nil_p(b) || (bc2cpp_class_is(M, b,') &&
               guard.call(by['Menu#pick'], 'pick', 2))
  check.call('`b.size2` past the nil test is a direct call', direct.call(by['Menu#pick']))
  check.call('`?Integer` with an Integer default is guarded',
             by['Menu#add'].to_s.include?('bc2cpp_given_opt <= 0 || (mrb_fixnum_p(b))') && guard.call(by['Menu#add'], 'add', 2))
  check.call('a default that is no literal of the declared kind gives no guard',
             !guard.call(by['Menu#computed'], 'computed', 2) &&
               err.include?('Menu#computed parameter 2: optional Foo? gives no hint'))
  check.call('a default reading a later optional gives no guard to that optional',
             !guard.call(by['Menu#later'], 'later', 3) && err.include?('Menu#later parameter 3: optional Foo? gives no hint'))
  check.call('`?untyped` is neither guarded nor noted per parameter',
             !guard.call(by['Menu#loose'], 'loose', 2) && !err.include?('Menu#loose parameter 2'))
  check.call('`?Array?` with a `[]` default is guarded by its kind and `(xs || []).size` is the Array body',
             by['Menu#sorted'].to_s.include?('bc2cpp_given_opt <= 0 || (mrb_nil_p(xs) || (mrb_array_p(xs)))') &&
               !by['Menu#sorted'].to_s.include?('owner-call: size'))
  check.call('required Hash and String parameters are guarded by their kind',
             by['Menu#keys_of'].to_s.include?('mrb_hash_p(h)))) bc2cpp_declared_param_violation') &&
               by['Menu#shout'].to_s.include?('mrb_string_p(s)))) bc2cpp_declared_param_violation'))
  check.call('the guarded body is not inlined', !by['Menu#run'].to_s.include?('CALL_INLINE Menu#pick'))
  # DECLARED_NUMERIC_ENTRY: the call sites pass a global, so only the guarded declaration knows the class.
  integer_only = ->(body) { body.to_s.include?('INTEGER_OPERAND_PROOF') && !body.to_s.match?(/bc2cpp_num_\w+_float\(|mrb_float\(/) }
  check.call('a required `Integer` parameter is an Integer operand past its guard',
             guard.call(by['Menu#scale'], 'scale', 1) && integer_only.call(by['Menu#scale']))
  check.call('a required `Float` parameter is a numeric operand past its guard',
             guard.call(by['Menu#halve'], 'halve', 1) && by['Menu#halve'].to_s.include?('NUMERIC_OPERAND_PROOF') &&
               !by['Menu#halve'].to_s.include?('INTEGER_OPERAND_PROOF'))
  Dir.mktmpdir('declared-numeric-entry-off') do |off_dir|
    _off_code, _off_err, off = generate.call(off_dir, 'BC2CPP_DECLARED_NUMERIC_ENTRY' => '0')
    check.call('BC2CPP_DECLARED_NUMERIC_ENTRY=0 leaves the declared parameters unproven operands',
               guard.call(off['Menu#scale'], 'scale', 1) && !off['Menu#scale'].to_s.include?('NUMERIC_OPERAND_PROOF') &&
                 !off['Menu#halve'].to_s.include?('NUMERIC_OPERAND_PROOF'))
  end

  cpick = by['Menu.singleton#cpick'].to_s
  check.call('a `def self.x` declaration is guarded and seeds the body like an instance one',
             guard.call(cpick, 'cpick', 1, 'Menu.singleton') && direct.call(cpick) &&
               cpick.include?('bc2cpp_given_opt <= 0 || (mrb_nil_p(b) || (bc2cpp_class_is(M, b,'))
  singleton = ->(owner, name) { (b = by["#{owner}##{name}"]) && guard.call(b, name, 1, owner) && direct.call(b) }
  check.call('a `class << self` def and a module `def self.x` are guarded and seeded too',
             singleton.call('Menu.singleton', 'epick') && singleton.call('Tools.singleton', 'mpick'))

  params = { 'x' => [[1, 'Foo', 'Menu#pick', 'Foo?', :class, true, 0]] }
  check.call('the contract refuses a compiled body without its optional guard',
             DeclaredReturns.optional_param_guard_failures(params, [{ label: 'x', code: 'mrb_value f() {}' }]).size == 1 &&
               DeclaredReturns.optional_param_guard_failures(params, [{ label: 'x', code: '#error x' }]).empty? &&
               DeclaredReturns.optional_param_guard_failures(
                 params, [{ label: 'x', code: '/* DECLARED_PARAM_GUARD Menu#pick arg 2 */' }]
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
    check.call('a wrong given argument raises the violation in the compiled run',
               wrong.call(compiled) == ['wrong pick => raised BC2cppDeclarationViolation',
                                        'wrong add => raised BC2cppDeclarationViolation',
                                        'wrong sorted => raised BC2cppDeclarationViolation',
                                        'wrong scale => raised BC2cppDeclarationViolation',
                                        'wrong singleton => raised BC2cppDeclarationViolation',
                                        'wrong eigenclass => raised BC2cppDeclarationViolation',
                                        'wrong module => raised BC2cppDeclarationViolation'])
    warn output unless built && compiled.size == interpreted.size
  else
    puts '  SKIP run: no full-core mruby build'
  end
  File.write(File.join(dir, 'keep.cpp'), code) if ENV['BC2CPP_KEEP_DIR']
end

suite.finish!
