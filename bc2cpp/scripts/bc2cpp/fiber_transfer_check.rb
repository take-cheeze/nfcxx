#!/usr/bin/env ruby
# encoding: UTF-8
# frozen_string_literal: true

# FIBER_TRANSFER (runtime/bc2cpp_fiber.hxx): Fiber#transfer between the root and a fiber, a fiber resumed from inside another's step
# and the FiberError cases, with compiled bodies (no body runs on mruby-fiber). Both runs print the same line per scenario.
#
# Usage: MRBC=path/to/mrbc [BC2CPP_MRUBY_FULL=dir | BC2CPP_FULL_BUILD_DIR=dir] ruby scripts/bc2cpp/fiber_transfer_check.rb

require_relative 'fixture_runtime'

suite = Bc2cppStepCheck.new('bc2cpp fiber transfer check')

# State the bodies read lives in instance variables: a Fiber body does not capture the locals of the method building it.
SRC = <<~'RUBY'
  class FtTransfer
    def start
      @main = Fiber.current
      @f = Fiber.new do
        resumed = @main.transfer(:yielded)
        [:done, resumed]
      end
    end

    def first
      @f.transfer
    end

    def second
      @f.transfer(:resumed)
    end

    def fiber_alive
      @f.alive?
    end

    def main_is_current
      @main.equal?(Fiber.current)
    end
  end

  class FtNested
    def start
      @outer = Fiber.new do |a|
        @a = a
        @inner = Fiber.new do |b|
          Fiber.yield [@a, b]
          :inner_done
        end
        first = @inner.resume(2)
        resumed = Fiber.yield(first)
        [resumed, @inner.resume, @inner.alive?]
      end
    end

    def go(*args)
      @outer.resume(*args)
    end
  end

  class FtErrors
    def start
      @self_resuming = Fiber.new { @self_resuming.resume }
      @short = Fiber.new { :short }
      @a = Fiber.new { @b.resume }
      @b = Fiber.new { @a.resume }
      @yielder = Fiber.new do
        Fiber.yield 1
        2
      end
    end

    def resume_self
      @self_resuming.resume
    end

    def resume_dead
      @short.resume
      @short.resume
    end

    def resume_resuming
      @a.resume
    end

    def transfer_to_yielded
      @yielder.resume
      @yielder.transfer
    end

    def start_more
      @main = Fiber.current
      @away = Fiber.new do
        @main.transfer(1)
        2
      end
      @yields_after_transfer = Fiber.new { Fiber.yield 3 }
      @c = Fiber.new { @d.transfer }
      @d = Fiber.new { @c.resume }
    end

    def resume_transferred
      @away.transfer
      @away.resume
    end

    def yield_after_transfer
      @yields_after_transfer.transfer
    end

    def transfer_to_resuming
      @c.resume
    end
  end

  class FtChain
    def start
      @main = Fiber.current
      @g = Fiber.new do
        r = @f.transfer(:to_f)
        [:g_done, r]
      end
      @f = Fiber.new do
        @g.transfer(:from_f)
        :f_done
      end
    end

    def run
      @g.transfer
    end

    def alive
      [@g.alive?, @f.alive?]
    end
  end
RUBY

OWNERS = %w[FtTransfer FtNested FtErrors FtChain].freeze
code = suite.generate(SRC, OWNERS)
OWNERS.each do |owner|
  suite.check("#{owner}'s fiber bodies compile as steps", code.match?(/static mrb_value #{owner}_start__blk\d+_step\(mrb_state\* M/))
end

DRIVER = Bc2cppStepCheck::SHOW + <<~'RUBY'
  t = FtTransfer.new
  t.start
  show('transfer out') { t.first }
  show('transfer alive') { t.fiber_alive }
  show('transfer back') { t.second }
  show('transfer dead') { t.fiber_alive }
  show('root is current') { t.main_is_current }
  n = FtNested.new
  n.start
  show('nested first') { n.go(1) }
  GC.start
  show('nested second') { n.go(3, 4) }
  e = FtErrors.new
  e.start
  show('resume self') { e.resume_self }
  show('resume dead') { e.resume_dead }
  show('resume resuming') { e.resume_resuming }
  show('transfer to yielded') { e.transfer_to_yielded }
  m = FtErrors.new
  m.start
  m.start_more
  show('resume transferred') { m.resume_transferred }
  show('yield after transfer') { m.yield_after_transfer }
  show('transfer to resuming') { m.transfer_to_resuming }
  c = FtChain.new
  c.start
  show('chain') { c.run }
  show('chain alive') { c.alive }
  puts 'end'
RUBY

suite.behaviour(DRIVER)
suite.finish
