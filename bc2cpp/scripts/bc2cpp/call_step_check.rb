#!/usr/bin/env ruby
# encoding: UTF-8
# frozen_string_literal: true

# CALL_STEP (codegen_resumable.rb resumable_call_site): a suspendable method calling another with arguments makes the callee's frame and
# suspends with it; the callee's Fiber.yield reaches the resumer and its result is the caller's resume value.
#
# Usage: MRBC=path/to/mrbc [BC2CPP_MRUBY_FULL=dir | BC2CPP_FULL_BUILD_DIR=dir] ruby scripts/bc2cpp/call_step_check.rb

require_relative 'fixture_runtime'

suite = Bc2cppStepCheck.new('bc2cpp call step check')

SRC = <<~RUBY
  class CsClock
    def start
      @fiber = Fiber.new { run }
    end

    def run
      a = ask(3)
      b = ask(4)
      [a, b, a + b]
    end

    def ask(n)
      got = Fiber.yield n
      got.to_i + n
    end

    #{Bc2cppStepCheck::CLOCK_API}
  end
RUBY

code = suite.generate(SRC, %w[CsClock])
suite.check('run compiles as a resumable step function', code.include?('static mrb_value CsClock_run_step(mrb_state* M'))
suite.check('ask compiles as a resumable step function', code.include?('static mrb_value CsClock_ask_step(mrb_state* M'))
suite.check('run calls ask as a CALL (RESUMABLE_CALL)', code.include?('// RESUMABLE_CALL'))

DRIVER = <<~'RUBY'
  a = CsClock.new
  a.start
  out = []
  out << a.go
  GC.start
  out << a.go_with(10)
  GC.start
  out << a.go_with(20)
  out << a.fiber_alive
  p out
  puts 'end'
RUBY

suite.behaviour(DRIVER) do |interpreted, _|
  suite.check('each call yields its argument and the results combine', interpreted&.first == '[3, 4, [13, 24, 37], false]')
end
suite.finish
