#!/usr/bin/env ruby
# frozen_string_literal: true

# INTEGER_EXACT (CodeGen#integer_exact_class): a receiver the flow proves an Integer (a fixnum or a bigint, the one
# Integer class) is an exact-Integer site.
#
#   1. generated: `n.times { }` on a declared Integer calls Integer#times' compiled body (BLOCK_CORE_DIRECT's fallback,
#      behind the guarded inline loop) with no class test and no dynamic else; `(n + 1).to_s` and `n.to_i` are NUMERIC_NATIVE_EXACT; `n.to_f` keeps its fixnum test, since the
#      audited Integer#to_f expression reads a fixnum only; an unproven receiver keeps its class tests;
#   2. BC2CPP_INTEGER_EXACT=0 keeps the dynamic sends;
#   3. run on a full-core mruby against interpreted, with products in and past the fixnum range: the calls answer as
#      interpreted.
#
# Usage: MRBC=path/to/host/mrbc [BC2CPP_FULL_BUILD_DIR=dir] ruby scripts/bc2cpp/integer_exact_check.rb

require 'tmpdir'
require 'fileutils'
require_relative 'check_support'
require_relative 'fixture_runtime'

suite = FixtureCheck.new('integer_exact_check')
check = suite.method(:check)
suite.require_mrbc!
runtime = Bc2cppFixtureRuntime

SOURCE = <<~RUBY
  class IntFx
    def count(n)
      s = 0
      n.times { |i| s += i }
      s
    end

    def down(n)
      r = []
      n.downto(n - 2) { |i| r << i }
      r
    end

    def label(n)
      (n + 1).to_s
    end

    def ident(n)
      n.to_i
    end

    def float(n)
      n.to_f
    end

    # `n * n * n` may leave the fixnum range: the flow's Integer is a bigint there.
    def cube_label(n)
      (n * n * n).to_s
    end

    def cube_float(n)
      (n * n * n).to_f
    end

    def loose(x)
      s = 0
      x.times { |i| s += i }
      s
    end

    def run
      big = 3_000_000_000_000
      [count(4), down(3), label(9), ident(7), float(2), loose(2), cube_label(5), cube_float(5), cube_label(big), cube_float(big)]
    end
  end
RUBY

SIGNATURES = <<~RBS
  class IntFx
    def count: (Integer n) -> Integer
    def down: (Integer n) -> Array[Integer]
    def label: (Integer n) -> String
    def ident: (Integer n) -> Integer
    def float: (Integer n) -> Float
    def cube_label: (Integer n) -> String
    def cube_float: (Integer n) -> Float
  end
RBS
OWNERS = %w[IntFx].freeze

HARNESS = <<~'CPP'
  static int scenario(mrb_state* M) {
    mrb_value fx = mrb_obj_new(M, mrb_class_get(M, "IntFx"), 0, nullptr);
    call(M, "run", fx, "run");
    return 0;
  }
CPP

generate = lambda do |dir, env = {}|
  env.each { |k, v| ENV[k] = v }
  sigs = File.join(dir, 'sig')
  FileUtils.mkdir_p(sigs)
  File.write(File.join(sigs, 'int_fx.rbs'), SIGNATURES)
  ENV['BC2CPP_SIG_DIRS'] = sigs
  code, err = runtime.generate(SOURCE, dir, only_owners: OWNERS, core: true)
  [code, err, code.split(%r{^(?=// \w+#)}).to_h { |part| [part[%r{\A// (\S+)}, 1], part] }]
ensure
  ENV.delete('BC2CPP_SIG_DIRS')
  env.each_key { |k| ENV.delete(k) }
end
dynamic = ->(body, name) { body.to_s.match?(/owner-call: #{Regexp.escape(name)} \*\/|mrb_funcall\w*\(M, \w+, "#{Regexp.escape(name)}"/) }

Dir.mktmpdir('integer-exact') do |dir|
  _code, err, by = generate.call(dir)
  core_direct = lambda do |body, name|
    body.to_s.include?("BLOCK_CORE_DIRECT :#{name} -- proven Integer receiver") && body.to_s.include?("Integer_#{name}_impl(") &&
      !dynamic.call(body, name)
  end
  check.call('`n.times { }` on a declared Integer calls the compiled body with no class test', core_direct.call(by['IntFx#count'], 'times'))
  check.call('`n.downto(m) { }` the same', core_direct.call(by['IntFx#down'], 'downto'))
  check.call('`(n + 1).to_s` is NUMERIC_NATIVE_EXACT', by['IntFx#label'].to_s.include?('NUMERIC_NATIVE_EXACT :to_s') &&
               !dynamic.call(by['IntFx#label'], 'to_s'))
  check.call('`n.to_i` is NUMERIC_NATIVE_EXACT', by['IntFx#ident'].to_s.include?('NUMERIC_NATIVE_EXACT :to_i'))
  check.call('`n.to_f` keeps its fixnum test (the expression reads a fixnum only)',
             by['IntFx#float'].to_s.include?('mrb_integer_p(') && dynamic.call(by['IntFx#float'], 'to_f'))
  check.call('an unproven receiver keeps its class tests', by['IntFx#loose'].to_s.include?('mrb_integer_p(') &&
               dynamic.call(by['IntFx#loose'], 'times'))

  Dir.mktmpdir('integer-exact-off') do |off_dir|
    _, _, off = generate.call(off_dir, 'BC2CPP_INTEGER_EXACT' => '0')
    check.call('BC2CPP_INTEGER_EXACT=0 keeps the dynamic sends',
               dynamic.call(off['IntFx#count'], 'times') && dynamic.call(off['IntFx#label'], 'to_s'))
  end

  build = runtime.full_or_build
  if build
    built, output = runtime.run(dir, err, OWNERS, HARNESS, build: build, full: true)
    sections = runtime.sections(output)
    plain = ->(lines) { lines.to_a.reject { |l| l.start_with?('  dispatches=') } }
    check.call('built and ran', built)
    check.call('compiled answers as interpreted (fixnum and bigint)',
               built && !plain.call(sections['compiled']).empty? && plain.call(sections['compiled']) == plain.call(sections['interpreted']))
  else
    puts '  SKIP: no full-core libmruby (set BC2CPP_FULL_BUILD_DIR); the behavioural check needs it'
  end
end

suite.finish!
