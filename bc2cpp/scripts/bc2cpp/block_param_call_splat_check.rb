#!/usr/bin/env ruby
# encoding: UTF-8
# frozen_string_literal: true

# BLOCK_PARAM_CALL_SPLAT (docs/adr/0373): `blk.call(*args)` on a compiled core method's own
# `&blk`, with a runtime-sized splat, has a Proc arm and a NoMethodError else instead of a
# by-name `mrb_funcall_argv`. Checks the generated code only: what is taken, every reason it is
# withheld, and that the Proc arm yields with the splatted Array's own length and elements.
#
# Usage: MRBC=path/to/mrbc ruby scripts/bc2cpp/block_param_call_splat_check.rb

require 'tmpdir'
require_relative 'fixture_runtime'

runtime = Bc2cppFixtureRuntime
failures = []
check = lambda do |what, condition|
  puts "  #{condition ? 'ok  ' : 'FAIL'} #{what}"
  failures << what unless condition
end

unless system(runtime.mrbc, '--version', out: File::NULL, err: File::NULL)
  puts 'SKIP: needs MRBC'
  exit 0
end

# A file below 3rd/mruby/mrblib/ is mruby's own Ruby to bc2cpp, which the block proof is for.
CORE_PATH = '3rd/mruby/mrblib/dn_core.rb'
WORLD = <<~'RUBY'
  class DnSplat
    def each_splat(&blk); [[1, 2], [3]].each { |*v| blk.call(*v) }; end
    def direct(*args, &blk); blk.call(*args); end
    def mixed(a, *args, &blk); blk.call(a, *args); end
    def opt(a, b = 2, &blk); [a, b].each { |*v| blk.call(*v) }; end
    def reassign(*args, &blk); blk = nil; blk.call(*args); end
    def maybe(x, *args, &blk); blk = proc { |*v| v } if x; blk.call(*args); end
    def plain_param(blk, *args); blk.call(*args); end
    def nested_write(*args, &blk); [1].each { blk = nil }; blk.call(*args); end
    def yielded(a); [[a, 2], [3]].each { |*v| yield(*v) }; end
    def yielded_direct(a); args = [a]; args << 2 if a; yield(*args); end
    def literal(&blk); blk.call(*[1, 2]); end
  end
RUBY

generate = lambda do |source, closed: true, path: CORE_PATH, extra: nil|
  Dir.mktmpdir do |dir|
    runtime.generate(source, dir, closed: closed, path: path, extra: extra ? [['engine.rb', extra]] : []).first
  end
end
body_of = lambda do |code, fn|
  # A block's body is its own function, `<method>_block_fallback_<n>_impl`.
  code.scan(/^(?:static )?mrb_value DnSplat_#{fn}(?:_block_fallback_\d+)?_impl\(mrb_state\* M.*?(?=^(?:static )?mrb_value \w+\(mrb_state\* M|\z)/m).join
end
# The `"call"` dispatch: the argv form is what a runtime-sized splat can only use.
by_name = ->(body) { body.scan(/\bmrb_funcall_argv\(|\bbc2cpp_funcall_argv\(/).size }

closed = generate.call(WORLD)
%w[direct mixed].each do |fn|
  body = body_of.call(closed, fn)
  check.call("#{fn}: splatted blk.call yields with the Array's length and elements, nil raises NoMethodError",
             body.include?('BLOCK_PARAM_CALL_SPLAT :call') &&
               body.match?(/if \(mrb_proc_p\(r\d+\)\) \{\n\s+r\d+ = bc2cpp_yield_argv\(M, r\d+, RARRAY_LEN\(r\d+\), RARRAY_PTR\(r\d+\)\);/) &&
               body.include?('bc2cpp_nomethod(M, r') && by_name.call(body).zero?)
end
check.call('a call from a block nested in the method (the each_splat shape of Enumerable) is proven',
           body_of.call(closed, 'each_splat').include?('BLOCK_PARAM_CALL_SPLAT :call'))
%w[yielded yielded_direct].each do |fn|
  check.call("#{fn}: `yield *args` (BLKPUSH, nil raises LocalJumpError first) has no by-name else",
             body_of.call(closed, fn).include?('BLOCK_PARAM_CALL_SPLAT :call') && by_name.call(body_of.call(closed, fn)).zero?)
end
check.call('an optional parameter before the block is proven',
           body_of.call(closed, 'opt').include?('BLOCK_PARAM_CALL_SPLAT :call'))
check.call('a literal-sized splat does not take the runtime-sized path', !body_of.call(closed, 'literal').include?('BLOCK_PARAM_CALL_SPLAT'))

{ 'reassign' => 'a block rewritten to nil', 'maybe' => 'a block replaced on one path',
  'plain_param' => 'a plain parameter', 'nested_write' => 'a block rewritten by a nested block' }.each do |fn, why|
  body = body_of.call(closed, fn)
  check.call("#{fn}: #{why} keeps the CORE_PROC_CALL by-name else",
             !body.include?('BLOCK_PARAM_CALL_SPLAT') && body.include?('CORE_PROC_CALL') && body.include?('mrb_funcall_argv('))
end

check.call('the same fixture outside mruby\'s own Ruby is untouched',
           !generate.call(WORLD.sub('DnSplat', 'DnUser'), path: 'fixture.rb').include?('BLOCK_PARAM_CALL_SPLAT'))
check.call('without the closed world no core proof is taken',
           !generate.call(WORLD, closed: false).include?('BLOCK_PARAM_CALL_SPLAT'))

{
  'a Ruby call on any class' => "class DnOther\n  def call(x); x; end\nend\n",
  'a Ruby call on NilClass' => "class NilClass\n  def call(*); 1; end\nend\n",
  'a method_missing on NilClass' => "class NilClass\n  def method_missing(*); 1; end\nend\n",
  'a singleton call' => "class DnOther\n  def self.call(x); x; end\nend\n",
  'a dynamic installer' => "class DnOther\n  def install(n); Object.send(:define_method, n) { 1 }; end\nend\n"
}.each do |what, extra|
  code = generate.call(WORLD, extra: extra)
  check.call("#{what} withdraws BLOCK_PARAM_CALL_SPLAT",
             !code.include?('BLOCK_PARAM_CALL_SPLAT') && body_of.call(code, 'direct').include?('CORE_PROC_CALL'))
end

puts
if failures.empty?
  puts 'bc2cpp block-param splat call check: PASS'
else
  puts "bc2cpp block-param splat call check: #{failures.size} FAILED"
  exit 1
end
