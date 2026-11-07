#!/usr/bin/env ruby
# encoding: UTF-8
# frozen_string_literal: true

# STEP_CLOSURES (codegen_resumable.rb, codegen_block_fallback.rb): a variable a block may keep lives in a heap cell shared by the
# step and its blocks, so the closure outlives the step's frame and the C stack. Every scenario prints the same compiled as
# interpreted (the fiber bodies are compiled, not eval'd).
#
# Usage: MRBC=path/to/mrbc [BC2CPP_MRUBY_FULL=dir | BC2CPP_FULL_BUILD_DIR=dir] ruby scripts/bc2cpp/step_closures_check.rb

require_relative 'fixture_runtime'

suite = Bc2cppStepCheck.new('bc2cpp step closures check')

WIDE = (0...250).map { |i| "      l#{i} = #{i}\n" }.join
WIDE_LIST = (0...250).map { |i| "l#{i}" }.join(', ')

# Each ScClosures method is one scenario; the driver prints what it returns.
SRC = <<~RUBY
  class ScClosures
    # A block kept past the fiber: it writes a variable of the (finished) body.
    def sc_escape
      f = Fiber.new do
        x = 1
        capture = proc { x += 1 }
        Fiber.yield capture
        capture.call
      end
      capture = f.resume
      GC.start
      [capture.call, f.resume, capture.call, f.alive?]
    end

    # Two blocks over one variable see each other's writes.
    def sc_shared
      f = Fiber.new do
        n = 10
        inc = proc { n += 1 }
        get = proc { n }
        Fiber.yield [inc, get]
        inc.call
        n
      end
      inc, get = f.resume
      GC.start
      [inc.call, get.call, f.resume, get.call]
    end

    # A body that writes captured parameters, optional and rest included.
    def sc_params(a, b = 2, *rest)
      f = Fiber.new do
        a += 1
        Fiber.yield a
        b += 1
        rest << :x
        [a, b, rest]
      end
      [f.resume, f.resume, a, b]
    end

    # A body inside a block: the outer block's parameter is an upvar of the body.
    def sc_outer
      out = []
      [1, 2].each do |i|
        f = Fiber.new do
          Fiber.yield i
          i * 2
        end
        out << f.resume << f.resume
      end
      out
    end

    # A step's variable captured by a block that is yielded out and called later, from the resumer.
    def sc_step_local
      f = Fiber.new do
        count = 0
        step = proc { count += 1 }
        2.times { |i| Fiber.yield step; step.call }
        count
      end
      s = f.resume
      GC.start
      [s.call, f.resume.class, f.resume, s.call, f.alive?]
    end

    # A method with 250 locals yielding an Array of them.
    def sc_wide
      f = Fiber.new do
  #{WIDE}      Fiber.yield [#{WIDE_LIST}]
        [l0, l249]
      end
      a = f.resume
      [a.size, a.first, a.last, f.resume]
    end

    # The classic closure: two procs over one local, both outliving the method.
    def sc_counter
      count = 0
      inc = proc { count += 1 }
      [inc, proc { count }]
    end

    # One proc per element of a loop: each captures its own element (the loop's block is not inlined).
    def sc_adders
      [1, 2, 3].map { |n| proc { |x| x + n } }
    end

    # A default proc keeps its block; the local is written after the Hash exists.
    def sc_hash_default
      base = 100
      h = Hash.new { |hash, k| hash[k] = base + k }
      base = 200
      h
    end

    # Arity and parameters of compiled blocks: mandatory, rest, lambda.
    def sc_arity
      g = proc { |x, y| }
      r = proc { |*rest| rest }
      l = lambda { |x, y| x }
      [g.arity, g.parameters, g.lambda?, r.arity, r.parameters, r.call(5, 6), l.arity, l.parameters, l.lambda?, l.call(1, 2)]
    end

    # A kept block nested in a block that is only called during the call reads and writes the method's local.
    def sc_nested
      total = 0
      procs = []
      [1, 2].each { |i| procs << proc { total += i } }
      [procs, proc { total }]
    end

    # The same inside a Fiber body, and two blocks deep.
    def sc_nested_fiber
      f = Fiber.new do
        x = 100
        procs = []
        [1, 2].each { |i| [10, 20].each { |j| procs << proc { x += i * j } } }
        Fiber.yield [procs, proc { x }]
        x
      end
      procs, get = f.resume
      GC.start
      [procs.map(&:call), get.call, f.resume, get.call]
    end

    # The middle block suspends (it is a step of its own).
    def sc_nested_step
      f = Fiber.new do
        x = 100
        procs = []
        [1, 2].each { |i| Fiber.yield i; procs << proc { x += i } }
        Fiber.yield [procs, proc { x }]
        x
      end
      f.resume
      f.resume
      procs, get = f.resume
      GC.start
      [procs.map(&:call), get.call, f.resume, get.call]
    end

    # Many kept blocks writing their cells: no root is kept per cell (the stores gray the Array).
    def sc_roots
      before = ($__bc2cpp_upvar_roots || {}).size
      kept = []
      12.times { |n| x = n.to_s; blk = proc { x += 'a' }; blk.call; kept << blk }
      GC.start
      [kept.map(&:call).size, kept.last.call, ($__bc2cpp_upvar_roots || {}).size - before < 4]
    end
  end
RUBY

OWNERS = %w[ScClosures].freeze

DRIVER = Bc2cppStepCheck::SHOW + <<~'RUBY'
  s = ScClosures.new
  show('escape') { s.sc_escape }
  show('shared') { s.sc_shared }
  show('params') { s.sc_params(1) }
  show('params with optional and rest') { s.sc_params(1, 5, 7, 8) }
  show('outer') { s.sc_outer }
  show('step local') { s.sc_step_local }
  show('wide') { s.sc_wide }
  show('counter') { inc, get = s.sc_counter; GC.start; [inc.call, inc.call, get.call, inc.call] }
  show('adders') { adders = s.sc_adders; GC.start; adders.map { |a| a.call(10) } }
  show('hash default') { h = s.sc_hash_default; GC.start; [h[1], h[2], h.size] }
  show('arity') { s.sc_arity }
  show('nested') { ps, g = s.sc_nested; GC.start; [ps.map(&:call), g.call, ps.map(&:call), g.call] }
  show('nested fiber') { s.sc_nested_fiber }
  show('nested step') { s.sc_nested_step }
  show('roots') { s.sc_roots }
  puts 'end'
RUBY

code = suite.generate(SRC, OWNERS)
# A method the compiler could not translate is left to the interpreter, where it trivially matches: every scenario must be
# compiled, not skipped.
%w[sc_escape sc_shared sc_params sc_outer sc_step_local sc_wide sc_counter sc_adders sc_hash_default sc_arity sc_nested sc_nested_fiber sc_nested_step sc_roots].each do |name|
  suite.check("ScClosures##{name} is compiled", code.include?("mrb_value ScClosures_#{name}_impl(mrb_state* M") &&
                                                !code.include?("BC2CPP_SKIPPED_ScClosures_#{name} "))
end

suite.behaviour(DRIVER, same: false) do |interpreted, compiled|
  interpreted.zip(compiled).each do |a, b|
    suite.check("#{a.to_s[/\A[^:]+/]}: interpreted and compiled runs print the same", a == b)
    puts "    interpreted: #{a}\n    compiled:    #{b}" unless a == b
  end if interpreted && compiled
end
suite.finish
