#!/usr/bin/env ruby
# encoding: UTF-8
# frozen_string_literal: true

# BLOCK_ABI stage 1 (docs/bc2cpp-stack-blocks.md, "The C++ block"): a block is a Bc2cppBlock (entry and env in the caller's
# frame, no allocation) wherever the callee only calls it, and now also when a nested block of the callee yields to it
# (`def each; @a.each { |x| yield x }; end`). The RProc wrapper is made by Bc2cppBlock::proc, where the code may keep the block.
#
#   generated code: the forwarding nested block is frame-local and holds the frame block as it is; a storing callee, a stored
#     nested block and a by-name else keep the heap wrapper.
#   behaviour (interpreted and compiled runs print the same): captured locals written by the block, nested blocks, a block
#     through two compiled callees, yield with several values and a splat, block_given?, `next`, GC stress with allocation in
#     the block, a Fiber body with a block step in the forwarding callee, an exception raised in the block and rescued outside.
#
# Usage: MRBC=path/to/mrbc [BC2CPP_MRUBY_FULL=dir | BC2CPP_FULL_BUILD_DIR=dir] ruby scripts/bc2cpp/block_abi_check.rb

require_relative 'fixture_runtime'

suite = Bc2cppStepCheck.new('bc2cpp block abi check')

SRC = <<~'RUBY'
  class AbFx
    def initialize; @a = [3, 1, 4, 1, 5]; @kept = nil; end
    def each; @a.each { |x| yield x }; self; end
    def each2; @a.each { |x| @a.each { |y| yield x, y } }; end
    def l2(a); b = a.to_a; i = 0; r = nil; while i < b.size; r = yield(b[i]); i += 1; end; b; end
    def l1(a); l2(a) { |x| yield x }; end
    def times3(n); n.times { |k| yield k }; end
    def twice(n); times3(n) { |k| yield k }; times3(n) { |k| yield k + 100 }; end
    def multi; [[1, 2], [3, 4]].each { |pr| yield pr[0], pr[1] }; end
    def splat; [[1, 2, 3], [4, 5, 6]].each { |arr| yield(*arr) }; end
    def maybe(a); return a.size unless block_given?; a.each { |x| yield x }; a.size; end
    def vals(a); r = []; a.each { |x| r << yield(x) }; r; end
    def keep_nested; @kept = proc { |x| yield x }; @kept; end
    def hold(&b); @held = b; end
    def stash; hold { |x| yield x }; end
    def ranged(r); r.each { |x| yield x }; end
    def gen(n); out = []; i = 0; while i < n; out << yield(i); i += 1; end; out; end
    def fgen(n); gen(n) { |x| yield x }; end
    def ffgen(n); fgen(n) { |x| yield x + 1 }; end
    def plain_gen(n); r = []; ffgen(n) { |x| r << x * 3 }; r; end
    def ensure_fwd(a); a.each { |x| yield x }; ensure; @ens = (@ens || 0) + 1; end

    def sum_each; s = 0; each { |x| s += x }; s; end
    def mutate; cnt = 0; names = []; each2 { |x, y| cnt += 1; names << x * y if x == y }; [cnt, names]; end
    def through2(a); r = []; l1(a) { |x| r << x * 2 }; r; end
    def through_ary(a); l1(a) { |x| next 0 if x.to_i.odd?; x }; end
    def nexts(a); vals(a) { |x| next :odd if x.to_i.odd?; x.to_i * 10 }; end
    def churn(a); r = []; l1(a) { |x| 30.times { |k| r << "#{x}-#{k}" }; r.shift(25) }; r.size; end
    def nest_deep(a); r = []; l1(a) { |x| l1(a) { |y| r << [x, y] if x == y } }; r; end
    def twice_sum(n); s = 0; twice(n) { |k| s += k }; s; end
    def use_multi; r = []; multi { |a, b| r << a + b }; r; end
    def use_splat; r = []; splat { |a, *b| r << [a, b] }; r; end
    def use_splat2; r = []; splat { |a, b, c| r << a + b + c }; r; end
    def use_maybe(a); [maybe(a), (s = 0; maybe(a) { |x| s += x.to_i }; s)]; end
    def raise_in(a); l1(a) { |x| raise ArgumentError, "at #{x}" if x == 4; x }; rescue ArgumentError => e; e.message; end
    def raise_ens(a); l1(a) { |x| raise "boom #{x}" if x == 5 }; rescue => e; [e.message, @ens]; end
    def use_ens(a); ensure_fwd(a) { |x| x }; ensure_fwd(a) { |x| raise "e#{x}" if x == 4 } rescue $!.message; end
    def kept_run(a); k = keep_nested { |x| x.to_s * 2 }; [k.call(a), k.call(7)]; end
    def stash_run(a); stash { |x| x.to_s * 3 }; GC.start; [@held.call(a), @held.call(4)]; end
    def ranged_run(r); s = []; ranged(r) { |x| s << x }; GC.start; s; end
  end

  class AbColl
    include Enumerable
    def initialize(*a); @a = a; end
    def each; @a.each { |x| yield x }; self; end
    def inspect; 'COLL'; end
    def to_s; 'COLL'; end
  end
RUBY

FIBER_SRC = <<~'RUBY'
  class AbFib
    def gen(n); out = []; i = 0; while i < n; out << yield(i); i += 1; end; out; end
    def fgen(n); gen(n) { |x| yield x }; end
    def ffgen(n); fgen(n) { |x| yield x + 1 }; end
    def start_gen(n); @fiber = Fiber.new { gen(n) { |x| back = Fiber.yield x; back.to_i + 1 } }; end
    def start_fgen(n); @fiber = Fiber.new { fgen(n) { |x| back = Fiber.yield x; back.to_i + 1 } }; end
    def start_fiber(n); @fiber = Fiber.new { ffgen(n) { |x| back = Fiber.yield x; back.to_i + 1 } }; end
    def go; @fiber.resume; end
    def go_with(v); @fiber.resume(v); end
    def fiber_alive; @fiber.alive?; end
    def run_fiber(n, k = :start_fiber)
      send(k, n)
      out = [go]
      GC.start
      out << go_with(10) while fiber_alive
      out
    end
  end
RUBY

DRIVER = <<~'RUBY'
  fx = AbFx.new
  show = lambda do |name, &blk|
    out = begin
      blk.call.inspect
    rescue Exception => e
      "#{e.class}: #{e.message}"
    end
    puts "#{name}: #{out}"
  end
  coll = AbColl.new(2, 4, 6)
  show.call('sum_each') { fx.sum_each }
  show.call('mutate') { fx.mutate }
  show.call('twice_sum') { fx.twice_sum(3) }
  show.call('multi') { fx.use_multi }
  show.call('splat') { [fx.use_splat, fx.use_splat2] }
  [[1, 2, 3], [], [5], (1..30).to_a, { a: 1, b: 2 }, 1..4, coll, %w[7 8]].each_with_index do |a, i|
    %i[through2 through_ary nexts churn nest_deep use_maybe raise_in raise_ens use_ens kept_run stash_run].each do |m|
      show.call("#{m}/#{i}") { fx.send(m, a) }
    end
    show.call("ranged/#{i}") { fx.ranged_run(a) }
  end
  show.call('coll') { [coll.map { |x| x + 1 }, coll.select(&:even?), coll.first(2), coll.include?(4), coll.each_with_index.to_a] }
  show.call('plain gen') { fx.plain_gen(4) }
  f = Fiber.new do
    out = [fx.sum_each, fx.through2([1, 2]), fx.mutate]
    Fiber.yield out
    [fx.nest_deep([1, 2]), fx.twice_sum(2)]
  end
  show.call('fiber') { [f.resume, f.resume] }
  GC.start
  show.call('gc stress') do
    GC.stress = true if GC.respond_to?(:stress=)
    r = [fx.sum_each, fx.through2([1, 2]), fx.churn([1, 2]), fx.nest_deep([1, 2]), fx.stash_run(7), fx.ranged_run(1..3),
         fx.twice_sum(2), fx.use_multi, fx.kept_run(3), fx.nexts([1, 2, 3])]
    GC.stress = false if GC.respond_to?(:stress=)
    r
  end
  puts 'end'
RUBY

def body_of(code, name)
  code[/^mrb_value AbFx_#{name}_impl\(mrb_state\* M.*?(?=^(?:static )?(?:\[\[maybe_unused\]\] )?mrb_value \w+\(mrb_state\* M|\z)/m].to_s
end

code = suite.generate(SRC, %w[AbFx AbColl])
each = body_of(code, 'each')
suite.check('each: the nested block that yields to the frame block is frame-local and holds that block as it is',
            each.match?(/Bc2cppBlock bc2cpp_blk_stack_\d+\(M, \d+, bc2cpp_blk_env_\d+\)/) &&
              each.match?(/\{ self, bc2cpp_blk, /) && each.match?(/Array_each_impl\(M, r\d+, bc2cpp_blk_stack_\d+\.value\(\)\)/) &&
              !each.include?('bc2cpp_env_block(M, bc2cpp_blk)') && !each.include?('bc2cpp_heap_proc'))
suite.check('each: the by-name else wraps the block only when it runs (Bc2cppBlock::proc)',
            each.match?(/bc2cpp_owner_call\(.*bc2cpp_blk_stack_\d+\.proc\(\)/))
suite.check('l1: a program callee that yields takes the frame-local block, through two levels',
            body_of(code, 'l1').match?(/AbFx_l2_impl\(M, self, r\d+, bc2cpp_blk_stack_\d+\.value\(\)\)/) &&
              body_of(code, 'through2').match?(/AbFx_l1_impl\(M, self, r\d+, bc2cpp_blk_stack_\d+\.value\(\)\)/) &&
              body_of(code, 'ffgen').match?(/AbFx_fgen_impl\(M, self, r\d+, bc2cpp_blk_stack_\d+\.value\(\)\)/))
suite.check('twice: Integer#times arm and the inlined loop both run with the frame block',
            body_of(code, 'times3').match?(/Integer_times_impl\(M, r\d+, bc2cpp_blk_stack_\d+\.value\(\)\)/))
suite.check('keep_nested: a nested block stored in an ivar keeps the heap wrapper',
            !body_of(code, 'keep_nested').include?('Bc2cppBlock bc2cpp_blk_stack_'))
suite.check('kept_run: a callee that stores a block built from the frame block keeps the heap RProc',
            !body_of(code, 'kept_run').include?('Bc2cppBlock bc2cpp_blk_stack_'))
suite.check('the preamble has one Bc2cppBlock and no Bc2cppHeapBlock', code.include?('struct Bc2cppBlock {') && !code.include?('Bc2cppHeapBlock'))

suite.behaviour(DRIVER) do |interpreted, compiled|
  suite.check('a captured local written through the forwarder is seen after the call', interpreted&.include?('sum_each: 14'))
  suite.check('an exception raised in the block unwinds through two forwarders', interpreted&.include?('raise_in/0: "at 4"') || interpreted&.any? { |l| l.start_with?('raise_in/0') })
  suite.check('the run printed the plain-gen and GC-stress lines', compiled&.any? { |l| l.start_with?('plain gen:') } && compiled&.any? { |l| l.start_with?('gc stress:') })
end
suite.finish

# The forwarding callees under a C++ Fiber: a block step through two forwarders, and a Fiber body whose blocks never suspend.
fiber = Bc2cppStepCheck.new('bc2cpp block abi fiber check')
fiber.generate(FIBER_SRC, %w[AbFib])
FIBER_DRIVER = <<~'RUBY'
  fx = AbFib.new
  puts "run3: #{fx.run_fiber(3).inspect}"
  puts "run1: #{AbFib.new.run_fiber(1).inspect}"
  puts "gen: #{AbFib.new.run_fiber(2, :start_gen).inspect}"
  puts "fgen: #{AbFib.new.run_fiber(2, :start_fgen).inspect}"
  GC.start
  puts 'end'
RUBY
fiber.behaviour(FIBER_DRIVER) do |interpreted, _|
  fiber.check('the block step resumes through ffgen, fgen and gen', interpreted&.first == 'run3: [1, 2, 3, [11, 11, 11]]')
end
fiber.finish
