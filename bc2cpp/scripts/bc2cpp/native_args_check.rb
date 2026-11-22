#!/usr/bin/env ruby
# frozen_string_literal: true

# NATIVE_ARGS (codegen.rb native_arg_positions): a compiled method's mandatory argument becomes a native mrb_int
# when its declaration says Integer and every call site passes a proven Fixnum there (ENTRY_ARG_CALLSITE_PROOF).
#   - every caller passes an integer literal: mrb_int, and a direct caller unboxes with mrb_as_int;
#   - one caller passes nil: boxed, though declared Integer;
#   - proven Fixnum at every site but declared nothing: boxed;
#   - the name also reaches a dynamic send: boxed.
# FIXNUM_ARG_UNBOX: a direct caller reads such a site register with mrb_fixnum, and an RGSS native's proven Fixnum
# argument too, where BC2CPP_FIXNUM_ARG_UNBOX=0 keeps mrb_as_int / mrb_integer; the compiled run answers as the
# interpreted one at the 31-bit Fixnum edges, and a non-Integer at the boxed entry still raises TypeError. Needs MRBC;
# the run needs a full-core libmruby (Bc2cppFixtureRuntime.full_or_build).
ENV['BC2CPP_SIG_DIRS'] = ''

require 'tmpdir'
require_relative 'check_support'
require_relative 'fixture_runtime'

suite = FixtureCheck.new('native_args_check')
suite.require_mrbc!

SOURCE = <<~RUBY
  class NaFx
    # bc2cpp: (fixnum) -> fixnum
    def dbl(x)
      x * 2
    end

    # bc2cpp: (fixnum)
    def loose(x)
      x.to_s
    end

    def plain(x)
      x + 1
    end

    # bc2cpp: (fixnum)
    def reflected(x)
      x - 1
    end

    def drive
      [dbl(3), dbl(4), loose(5), loose(nil), plain(6), reflected(7), send(:reflected, 8)]
    end
  end
RUBY

# FIXNUM_ARG_UNBOX on an RGSS native: `z = 5` is a proven Fixnum, `z = v` an unproven argument.
NATIVE_SOURCE = <<~RUBY
  module RGSS
    class Sprite; end
  end

  class NaNat
    def lit_z; s = RGSS::Sprite.new; s.z = 5; end
    def any_z(v); s = RGSS::Sprite.new; s.z = v; end
  end
RUBY

# Values at the edges of the narrowest Fixnum (31 bits, the Wio's word boxing) and a non-Integer at the boxed entry.
DRIVER = <<~'RUBY'
  class NaRun
    # bc2cpp: (fixnum)
    def na_half(x)
      x / 2
    end

    # bc2cpp: (fixnum, fixnum)
    def na_span(a, b)
      b - a
    end

    def drive
      [na_half(1_073_741_823), na_half(-1_073_741_824), na_span(-1_073_741_824, 1_073_741_823), na_span(3, 4),
       na_half(0)]
    end
  end
RUBY

Dir.mktmpdir('bc2cpp-native-args') do |dir|
  code, err = Bc2cppFixtureRuntime.generate(SOURCE, dir, only_owners: %w[NaFx])
  sig = ->(name) { code[/^mrb_value NaFx_#{name}_impl\(mrb_state\* M, mrb_value self, ([^)]*)\) \{/, 1] }
  suite.check("every caller passes a Fixnum: mrb_int (#{sig.call('dbl').inspect})", sig.call('dbl') == 'mrb_int x')
  suite.check('a direct caller reads the proven site register inline (FIXNUM_ARG_UNBOX)',
              code.match?(/NaFx_dbl_impl\(M, self, mrb_fixnum\(r\d+\)\)/) &&
                !code.include?('NaFx_dbl_impl(M, self, mrb_as_int('))
  suite.check("one caller passes nil: boxed (#{sig.call('loose').inspect})", sig.call('loose') == 'mrb_value x')
  suite.check("not declared Integer: boxed (#{sig.call('plain').inspect})", sig.call('plain') == 'mrb_value x')
  suite.check("reached by a dynamic send: boxed (#{sig.call('reflected').inspect})", sig.call('reflected') == 'mrb_value x')
  suite.check('the diagnostic lists exactly the retyped method', err.scan(/^  NATIVE_ARG (\S+) (\S+)$/) == [%w[NaFx#dbl 1]])
end

Dir.mktmpdir('bc2cpp-native-args-off') do |dir|
  ENV['BC2CPP_FIXNUM_ARG_UNBOX'] = '0'
  code, = Bc2cppFixtureRuntime.generate(SOURCE, dir, only_owners: %w[NaFx])
  suite.check('BC2CPP_FIXNUM_ARG_UNBOX=0: the direct caller converts with mrb_as_int',
              code.include?('NaFx_dbl_impl(M, self, mrb_as_int(M, '))
ensure
  ENV.delete('BC2CPP_FIXNUM_ARG_UNBOX')
end

native_body = lambda do |env|
  env.each { |k, v| ENV[k] = v }
  Dir.mktmpdir('bc2cpp-native-args-rgss') do |dir|
    code, = Bc2cppFixtureRuntime.generate(NATIVE_SOURCE, dir, only_owners: %w[NaNat])
    %w[lit_z any_z].to_h { |m| [m, code[/^mrb_value NaNat_#{m}_impl\(mrb_state\* M[^\n]*\{\n.*?^\}/m].to_s] }
  end
ensure
  env.each_key { |k| ENV.delete(k) }
end
on = native_body.call({})
off = native_body.call('BC2CPP_FIXNUM_ARG_UNBOX' => '0')
suite.check('a proven Fixnum RGSS argument reads with mrb_fixnum',
            on['lit_z'].match?(/rgss::\w+\(M, r\d+, mrb_fixnum\(r\d+\)\)/) && !on['lit_z'].include?('mrb_integer(r'))
suite.check('BC2CPP_FIXNUM_ARG_UNBOX=0: the proven RGSS argument reads with mrb_integer',
            off['lit_z'].match?(/rgss::\w+\(M, r\d+, mrb_integer\(r\d+\)\)/))
suite.check('an unproven RGSS argument keeps mrb_as_int',
            on['any_z'].include?('mrb_as_int(M,') && !on['any_z'].include?('mrb_fixnum(r') &&
              on['any_z'] == off['any_z'])

build = Bc2cppFixtureRuntime.full_or_build
if ENV['CC_GENERATED_ONLY'] == '1' || !build
  puts '  SKIP behavioural comparison: needs a full-core libmruby'
else
  Dir.mktmpdir('bc2cpp-native-args-run') do |dir|
    code, err = Bc2cppFixtureRuntime.generate(DRIVER, dir, core: true, only_owners: %w[NaRun])
    suite.check('the run fixture unboxes its direct calls',
                code.scan(/NaRun_(?:na_half|na_span)_impl\(M, self, mrb_fixnum\(/).size >= 3)
    body = <<~CPP
      static int scenario(mrb_state* M) {
        mrb_value o = mrb_obj_new(M, mrb_class_get(M, "NaRun"), 0, nullptr);
        call(M, "drive", o, "drive");
        mrb_value bad[] = { mrb_str_new_cstr(M, "x") };
        call(M, "na_half(String)", o, "na_half", 1, bad);
        mrb_value num[] = { mrb_int_value(M, 1000) };
        call(M, "na_half(1000)", o, "na_half", 1, num);
        return 0;
      }
    CPP
    built, output = Bc2cppFixtureRuntime.run(dir, err, %w[NaRun], body, build: build, full: true)
    sections = Bc2cppFixtureRuntime.sections(output)
    strip = ->(lines) { lines&.reject { |l| l.start_with?('  dispatches=') } }
    interpreted = strip.call(sections['interpreted']).to_a
    compiled = strip.call(sections['compiled']).to_a
    # The entry wrapper converts a declared Integer with mrb_get_args "i", unchanged by FIXNUM_ARG_UNBOX.
    entry = 'na_half(String) => raised TypeError'
    suite.check('the run fixture builds and runs', built)
    suite.check("compiled answers as interpreted (#{compiled.first.inspect})",
                built && !interpreted.empty? && interpreted.reject { |l| l.start_with?('na_half(String)') } ==
                                                compiled.reject { |l| l == entry })
    suite.check('a non-Integer at the boxed entry still raises the declaration TypeError', compiled.include?(entry))
    puts output unless built
  end
end

suite.finish!
