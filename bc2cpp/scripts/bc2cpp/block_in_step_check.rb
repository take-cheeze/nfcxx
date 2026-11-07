#!/usr/bin/env ruby
# encoding: UTF-8
# frozen_string_literal: true

# BLOCKS_IN_STEPS (codegen_resumable.rb resumable_block_call_glue): a step may build blocks, and a call with a literal block whose
# body reaches Fiber.yield becomes a CALL carrying the block's heap proc, so the callee's `yield` CALLs the block's step.
#
# Usage: MRBC=path/to/mrbc [BC2CPP_MRUBY_FULL=dir | BC2CPP_FULL_BUILD_DIR=dir] ruby scripts/bc2cpp/block_in_step_check.rb

require_relative 'fixture_runtime'

suite = Bc2cppStepCheck.new('bc2cpp block in step check')
CLOCK = Bc2cppStepCheck::CLOCK_API

# BiClock#run builds a local-capturing block, then calls each_mark with a block that yields to the fiber.
SRC = <<~RUBY
  class BiClock
    def start
      @fiber = Fiber.new { run }
    end

    def run
      xs = []
      [1, 2, 3].each { |v| xs << v * 2 }
      got = Fiber.yield xs.size
      ys = []
      xs.each { |v| ys << v + got.to_i }
      marks = each_mark(2) { |x| back = Fiber.yield x; back.to_i + 1 }
      [xs, ys, marks]
    end

    def each_mark(n)
      out = []
      i = 0
      while i < n
        out << yield(i)
        i += 1
      end
      out
    end

    #{CLOCK}
  end
RUBY

# NbClock: the Fiber body is itself a step, and the block it builds is nested in it.
SRC2 = <<~RUBY
  class NbClock
    def start
      @fiber = Fiber.new do
        first = Fiber.yield :begin
        marks = nb_mark(2) { |x| back = Fiber.yield x; back.to_i + 1 }
        [first, marks]
      end
    end

    def nb_mark(n)
      out = []
      i = 0
      while i < n
        out << yield(i)
        i += 1
      end
      out
    end

    #{CLOCK}
  end
RUBY

# CcClock: the yielding block reads and writes locals of the step that builds it.
SRC3 = <<~RUBY
  class CcClock
    def start
      @fiber = Fiber.new { run }
    end

    def run
      total = 100
      log = []
      marks = cc_mark(3) do |x|
        back = Fiber.yield x
        total += back.to_i
        log << total
        total
      end
      [marks, total, log]
    end

    def cc_mark(n)
      out = []
      i = 0
      while i < n
        out << yield(i)
        i += 1
      end
      out
    end

    #{CLOCK}
  end
RUBY

# DyClock: the callee is reached through `send`, so the call is resolved at run time (bc2cpp_dyn_call).
SRC4 = <<~RUBY
  class DyClock
    def start
      @fiber = Fiber.new { run }
    end

    def run
      name = :dy_mark
      marks = send(name, 2) { |x| back = Fiber.yield x; back.to_i + 1 }
      plain = send(:dy_plain, 5)
      [marks, plain]
    end

    def dy_plain(n)
      n * 2
    end

    def dy_mark(n)
      out = []
      i = 0
      while i < n
        out << yield(i)
        i += 1
      end
      out
    end

    #{CLOCK}
  end
RUBY

# IbClock: the method yields from a block of its own (`n.times { yield }`), so the inner block calls the method's block.
SRC5 = <<~RUBY
  class IbClock
    def start
      @fiber = Fiber.new { run }
    end

    def run
      ib_each(3) { |x| back = Fiber.yield x; back.to_i * 2 }
    end

    def ib_each(n)
      out = []
      n.times { |i| out << yield(i) }
      out
    end

    #{CLOCK}
  end
RUBY

# RtClock: `return` from an inner block of a method step ends the method (the fiber unwinds to its frame).
SRC6 = <<~RUBY
  class RtClock
    def start
      @fiber = Fiber.new { run }
    end

    def run
      a = rt_find(4) { |x| back = Fiber.yield x; back.to_i > 5 }
      b = rt_find(2) { |x| Fiber.yield x; false }
      [a, b]
    end

    def rt_find(n)
      n.times { |k| return k if yield(k) }
      nil
    end

    #{CLOCK}
  end
RUBY

# BkClock: `break` out of the block a Fiber body step builds ends the call that took it.
SRC7 = <<~RUBY
  class BkClock
    def start
      @fiber = Fiber.new do
        first = bk_each(3) { |x| back = Fiber.yield x; break :stopped if back == :stop; back }
        second = bk_each(2) { |x| Fiber.yield x; x }
        [first, second]
      end
    end

    def bk_each(n)
      out = []
      n.times { |i| out << yield(i) }
      out
    end

    #{CLOCK}
  end
RUBY

OWNERS = %w[BiClock NbClock CcClock DyClock IbClock RtClock BkClock].freeze
code = suite.generate(SRC + SRC2 + SRC3 + SRC4 + SRC5 + SRC6 + SRC7, OWNERS)
suite.check('run compiles as a resumable step function', code.include?('static mrb_value BiClock_run_step(mrb_state* M'))
suite.check('each_mark compiles as a resumable step function', code.include?('static mrb_value BiClock_each_mark_step(mrb_state* M'))
suite.check('the block compiles as a resumable step', code.match?(/static mrb_value BiClock_run__blk\d+_step\(mrb_state\* M/))
suite.check('run calls each_mark with its block as a CALL (RESUMABLE_CALL)', code.include?('// RESUMABLE_CALL'))
suite.check('the nested block of the body step compiles as a step', code.match?(/static mrb_value NbClock_start__blk\d+_step\(mrb_state\* M/))
suite.check('the block capturing locals compiles as a resumable step', code.match?(/static mrb_value CcClock_run__blk\d+_step\(mrb_state\* M/))
suite.check('the send site is a dynamic call (RESUMABLE_DYN_CALL)', code.include?('// RESUMABLE_DYN_CALL'))
suite.check('dy_mark registers a dispatcher', code.include?('DyClock_dy_mark_impl_dyn'))
suite.check('the inner block of ib_each compiles as a resumable step', code.match?(/static mrb_value IbClock_ib_each__blk\d+_step\(mrb_state\* M/))
suite.check('the return of an inner block unwinds (RESUMABLE_UNWIND RETURN_BLK)', code.include?('RESUMABLE_UNWIND RETURN_BLK'))
suite.check('the break of a block unwinds (RESUMABLE_UNWIND BREAK)', code.include?('RESUMABLE_UNWIND BREAK'))

DRIVER = <<~'RUBY'
  a = BiClock.new
  a.start
  out = []
  out << a.go
  GC.start
  out << a.go_with(10)
  GC.start
  out << a.go_with(20)
  out << a.go_with(30)
  out << a.fiber_alive
  p out
  b = NbClock.new
  b.start
  o2 = []
  o2 << b.go
  o2 << b.go_with(5)
  GC.start
  o2 << b.go_with(10)
  o2 << b.go_with(20)
  o2 << b.fiber_alive
  p o2
  c = CcClock.new
  c.start
  o3 = []
  o3 << c.go
  GC.start
  o3 << c.go_with(1)
  o3 << c.go_with(2)
  GC.start
  o3 << c.go_with(3)
  o3 << c.fiber_alive
  p o3
  d = DyClock.new
  d.start
  o4 = []
  o4 << d.go
  o4 << d.go_with(1)
  GC.start
  o4 << d.go_with(2)
  o4 << d.fiber_alive
  p o4
  e = IbClock.new
  e.start
  o5 = []
  o5 << e.go
  o5 << e.go_with(1)
  GC.start
  o5 << e.go_with(2)
  o5 << e.go_with(3)
  o5 << e.fiber_alive
  p o5
  f = RtClock.new
  f.start
  o6 = []
  o6 << f.go
  o6 << f.go_with(1)
  GC.start
  o6 << f.go_with(9)
  o6 << f.go_with(0)
  o6 << f.go_with(0)
  o6 << f.fiber_alive
  p o6
  g = BkClock.new
  g.start
  o7 = []
  o7 << g.go
  o7 << g.go_with(1)
  GC.start
  o7 << g.go_with(:stop)
  o7 << g.go_with(5)
  o7 << g.go_with(6)
  o7 << g.fiber_alive
  p o7
  puts 'end'
RUBY

suite.behaviour(DRIVER) do |interpreted, _|
  at = ->(i) { interpreted&.[](i) }
  suite.check('the local-capturing block and the yielding block both give their values', at.(0) == '[3, 0, 1, [[2, 4, 6], [12, 14, 16], [21, 31]], false]')
  suite.check('a block step reads and writes the locals of the step that builds it', at.(2) == '[0, 1, 2, [[101, 103, 106], 106, [101, 103, 106]], false]')
  suite.check('a send chosen at run time reaches the suspendable method through a CALL', at.(3) == '[0, 1, [[2, 3], 10], false]')
  suite.check("a block that yields to its method's block suspends through it", at.(4) == '[0, 1, 2, [2, 4, 6], false]')
  suite.check('a return from an inner block ends the method', at.(5) == '[0, 1, 0, 1, [1, nil], false]')
  suite.check('a break out of a block ends the call that took it', at.(6) == '[0, 1, 0, 1, [:stopped, [0, 1]], false]')
  suite.check('a block nested in a Fiber body step yields through the callee', at.(1) == '[:begin, 0, 1, [5, [11, 21]], false]')
end
suite.finish
