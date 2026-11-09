#!/usr/bin/env ruby
# frozen_string_literal: true

# NATIVE_ARGS (codegen.rb native_arg_positions): a compiled method's mandatory argument becomes a native mrb_int
# when its declaration says Integer and every call site passes a proven Fixnum there (ENTRY_ARG_CALLSITE_PROOF).
#   - every caller passes an integer literal: mrb_int, and a direct caller unboxes with mrb_as_int;
#   - one caller passes nil: boxed, though declared Integer;
#   - proven Fixnum at every site but declared nothing: boxed;
#   - the name also reaches a dynamic send: boxed.
# Needs MRBC.
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

Dir.mktmpdir('bc2cpp-native-args') do |dir|
  code, err = Bc2cppFixtureRuntime.generate(SOURCE, dir, only_owners: %w[NaFx])
  sig = ->(name) { code[/^mrb_value NaFx_#{name}_impl\(mrb_state\* M, mrb_value self, ([^)]*)\) \{/, 1] }
  suite.check("every caller passes a Fixnum: mrb_int (#{sig.call('dbl').inspect})", sig.call('dbl') == 'mrb_int x')
  suite.check('a direct caller unboxes', code.include?('NaFx_dbl_impl(M, self, mrb_as_int(M, '))
  suite.check("one caller passes nil: boxed (#{sig.call('loose').inspect})", sig.call('loose') == 'mrb_value x')
  suite.check("not declared Integer: boxed (#{sig.call('plain').inspect})", sig.call('plain') == 'mrb_value x')
  suite.check("reached by a dynamic send: boxed (#{sig.call('reflected').inspect})", sig.call('reflected') == 'mrb_value x')
  suite.check('the diagnostic lists exactly the retyped method', err.scan(/^  NATIVE_ARG (\S+) (\S+)$/) == [%w[NaFx#dbl 1]])
end

suite.finish!
