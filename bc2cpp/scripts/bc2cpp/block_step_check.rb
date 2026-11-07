#!/usr/bin/env ruby
# encoding: UTF-8
# frozen_string_literal: true

# BLOCK_STEP (codegen_resumable.rb block_step_candidate?): a literal block whose Fiber.yield is not its last act is compiled again as a
# step with a frame maker, so a suspendable method calling the block makes the C++ Fiber CALL that step.
#
# Usage: MRBC=path/to/mrbc [BC2CPP_MRUBY_FULL=dir | BC2CPP_FULL_BUILD_DIR=dir] ruby scripts/bc2cpp/block_step_check.rb

require_relative 'fixture_runtime'

suite = Bc2cppStepCheck.new('bc2cpp block step check')

SRC = <<~RUBY
  class BsClock
    def start
      @fiber = Fiber.new { each_mark { |x| got = Fiber.yield x; got.to_i + 1 } }
    end

    def each_mark(&blk)
      out = []
      i = 0
      while i < 3
        out << yield(i)
        i += 1
      end
      out
    end

    #{Bc2cppStepCheck::CLOCK_API}
  end
RUBY

code = suite.generate(SRC, %w[BsClock])
suite.check('the block compiles as a resumable step', code.match?(/static mrb_value BsClock_start__blk\d+_step\(mrb_state\* M/))
suite.check('the block has a frame maker', code.include?('_step_maker(mrb_state* M, struct REnv* bc2cpp_env'))
suite.check('the block proc carries the maker (flag bit 2)', code.match?(/mrb_int_value\(M, \d*[4-7]\)/) || code.include?('| 4'))

DRIVER = <<~'RUBY'
  a = BsClock.new
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
  puts 'end'
RUBY

suite.behaviour(DRIVER) do |interpreted, _|
  suite.check('each resumed value reaches the block and the method result is built from them',
              interpreted&.first == '[0, 1, 2, [11, 21, 31], false]')
end
suite.finish
