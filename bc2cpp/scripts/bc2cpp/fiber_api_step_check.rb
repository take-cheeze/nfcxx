#!/usr/bin/env ruby
# encoding: UTF-8
# frozen_string_literal: true

# FIBER_API (runtime/bc2cpp_fiber.hxx): block parameters bound from the first resume, multi-value yield/resume, Fiber.current inside
# and outside, and a fiber whose body raised being dead, on the C++ Fiber alone.
#
# Usage: MRBC=path/to/mrbc [BC2CPP_MRUBY_FULL=dir | BC2CPP_FULL_BUILD_DIR=dir] ruby scripts/bc2cpp/fiber_api_step_check.rb

require_relative 'fixture_runtime'

suite = Bc2cppStepCheck.new('bc2cpp fiber api step check')

# FaClock's body takes parameters, yields several values and reads Fiber.current; FaBoom's body raises after a yield.
SRC = <<~'RUBY'
  class FaClock
    def start
      @fiber = Fiber.new do |a, b|
        first = Fiber.yield(a, b)
        second = Fiber.yield(first)
        third = Fiber.yield
        Fiber.yield(1, 2, 3)
        [a, b, first, second, third, Fiber.current.equal?(@fiber)]
      end
    end

    def go(*args)
      @fiber.resume(*args)
    end

    def current_is_fiber
      Fiber.current.equal?(@fiber)
    end

    def fiber_alive
      @fiber.alive?
    end
  end

  class FaBoom
    def start
      @fiber = Fiber.new do
        Fiber.yield 1
        raise 'boom'
      end
    end

    def go
      @fiber.resume
    end

    def fiber_alive
      @fiber.alive?
    end
  end
RUBY

code = suite.generate(SRC, %w[FaClock FaBoom])
suite.check('the body with parameters compiles as a step', code.match?(/static mrb_value FaClock_start__blk\d+_step\(mrb_state\* M/))
suite.check('the body that raises compiles as a step', code.match?(/static mrb_value FaBoom_start__blk\d+_step\(mrb_state\* M/))

DRIVER = <<~'RUBY'
  a = FaClock.new
  a.start
  out = []
  out << a.go(1, 2)          # a=1, b=2; yields [1, 2]
  GC.start
  out << a.go(:x, :y)        # Fiber.yield returned [:x, :y]; yields it
  out << a.go(9)             # second=9; Fiber.yield with no value yields nil
  out << a.go                # third=nil; yields [1, 2, 3]
  out << a.current_is_fiber  # outside the fiber
  out << a.go(7)             # the body finishes
  out << a.fiber_alive
  p out
  b = FaBoom.new
  b.start
  r = []
  r << b.go
  begin
    b.go
  rescue => e
    r << e.message
  end
  r << b.fiber_alive
  p r
  puts 'end'
RUBY

suite.behaviour(DRIVER) do |interpreted, _|
  suite.check('parameters bind, several values round-trip, Fiber.current is the fiber inside only',
              interpreted&.first == '[[1, 2], [:x, :y], nil, [1, 2, 3], false, [1, 2, [:x, :y], 9, nil, true], false]')
  suite.check('a fiber whose body raised is dead', interpreted&.[](1) == '[1, "boom", false]')
end
suite.finish
