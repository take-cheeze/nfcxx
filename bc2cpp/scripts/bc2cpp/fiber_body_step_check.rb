#!/usr/bin/env ruby
# encoding: UTF-8
# frozen_string_literal: true

# FIBER_BODY_STEP (codegen_resumable.rb emit_fiber_body_step_site): a Fiber.new body that is not a single tail call is compiled as a
# step and is the C++ Fiber's root frame; its calls to suspendable methods are CALLs.
#
# Usage: MRBC=path/to/mrbc [BC2CPP_MRUBY_FULL=dir | BC2CPP_FULL_BUILD_DIR=dir] ruby scripts/bc2cpp/fiber_body_step_check.rb

require_relative 'fixture_runtime'

suite = Bc2cppStepCheck.new('bc2cpp fiber body step check')

# The body asks twice and yields a value of its own between the two calls.
SRC = <<~RUBY
  class FbClock
    def start
      @fiber = Fiber.new do
        a = ask(3)
        mid = Fiber.yield a * 100
        b = ask(4)
        [a, mid, b]
      end
    end

    def ask(n)
      got = Fiber.yield n
      got.to_i + n
    end

    #{Bc2cppStepCheck::CLOCK_API}
  end
RUBY

code = suite.generate(SRC, %w[FbClock])
suite.check('the body compiles as a step', code.match?(/static mrb_value FbClock_start__blk\d+_step\(mrb_state\* M/))
suite.check('the site builds the fiber from the step', code.include?('bc2cpp_fiber_new_step(M, '))
suite.check('the body calls ask as a CALL', code.include?('// RESUMABLE_CALL'))

DRIVER = <<~'RUBY'
  a = FbClock.new
  a.start
  out = []
  out << a.go
  GC.start
  out << a.go_with(10)
  out << a.go_with(7)
  GC.start
  out << a.go_with(20)
  out << a.fiber_alive
  p out
  puts 'end'
RUBY

suite.behaviour(DRIVER) do |interpreted, _|
  suite.check('the body combines the helper results and its own yield', interpreted&.first == '[3, 1300, 4, [13, 7, 24], false]')
end
suite.finish
