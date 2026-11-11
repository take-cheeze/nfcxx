#!/usr/bin/env ruby
# frozen_string_literal: true

# Checks the aspec decoding in scripts/bc2cpp/base_rbs_native.rb: a registration's aspec, as the preprocessed text spells it,
# gives the parameter list its method takes (required, then optional), and a rest, post, keyword or unreadable aspec gives
# no list (the caller keeps the rest parameter). Host only, a few milliseconds.
#
#   ruby scripts/bc2cpp/native_arity_check.rb

require_relative 'base_rbs_native'

failures = []
checks = 0
check = lambda do |what, condition|
  checks += 1
  puts "  #{condition ? 'ok  ' : 'FAIL'} #{what}"
  failures << what unless condition
end

def shape(expr)
  BaseRbsNative.aspec_shape(expr)
end

puts '== shapes'
check.call('MRB_ARGS_NONE() is no parameters', shape('((mrb_aspec)(0))') == '')
check.call('MRB_ARGS_REQ(1) is one untyped parameter', shape('((mrb_aspec)((1)&0x1f) << 18)') == 'untyped')
check.call('MRB_ARGS_OPT(2) is two optional parameters', shape('((mrb_aspec)((2)&0x1f) << 13)') == '?untyped, ?untyped')
check.call('MRB_ARGS_ARG(1, 1) is required then optional',
           shape('(((mrb_aspec)((1)&0x1f) << 18)|((mrb_aspec)((1)&0x1f) << 13))') == 'untyped, ?untyped')
check.call('MRB_ARGS_BLOCK() alone is no parameters (the block bit does not count)', shape('((mrb_aspec)1)') == '')
check.call('a rest parameter is not modelled', shape('((mrb_aspec)(1 << 12))').nil?)
check.call('a keyword parameter is not modelled', shape('((mrb_aspec)((1)&0x1f) << 2)').nil?)
check.call('an expression that is not arithmetic is not modelled', shape('foo_aspec').nil?)
check.call('a missing aspec is not modelled', shape(nil).nil?)

puts
puts "native arity check: #{checks - failures.size} checks passed" if failures.empty?
abort "native arity check: #{failures.size} of #{checks} failed" unless failures.empty?
