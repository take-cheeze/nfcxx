#!/usr/bin/env ruby
# encoding: UTF-8
# frozen_string_literal: true

# RESUMABLE_BLOCK_CALL (codegen_resumable.rb resumable_block_site): a resumable method yielding to its own block suspends with the
# yielded values and the driver calls the block. This block ends in Fiber.yield (tail form); block_step_check has the step form.
#
# Usage: MRBC=path/to/mrbc [BC2CPP_MRUBY_FULL=dir | BC2CPP_FULL_BUILD_DIR=dir] ruby scripts/bc2cpp/resumable_block_check.rb

require_relative 'fixture_runtime'

suite = Bc2cppStepCheck.new('bc2cpp resumable block check')

SRC = <<~'RUBY'
  class RbClock
    def start
      @fiber = Fiber.new { each_mark { |x| Fiber.yield x * 10 } }
    end

    def each_mark(&blk)
      i = 0
      while i < 3
        yield i
        i += 1
      end
      :done
    end

    def go
      @fiber.resume
    end
  end
RUBY

code = suite.generate(SRC, %w[RbClock])
suite.check('each_mark compiles as a resumable step function', code.include?('static mrb_value RbClock_each_mark_step(mrb_state* M'))
suite.check('the entry takes the block', code.match?(/^mrb_value RbClock_each_mark_impl\(mrb_state\* M, mrb_value self, mrb_value bc2cpp_blk\) \{/))
suite.check('the step suspends for the block call', code.include?('// RESUMABLE_BLOCK_CALL'))
suite.check('the driver calls the block on a block-call suspension', code.include?('"block_call?"'))

DRIVER = <<~'RUBY'
  a = RbClock.new
  a.start
  out = []
  3.times { out << a.go; GC.start }
  out << a.go
  p out
  puts 'end'
RUBY

suite.behaviour(DRIVER) do |interpreted, _|
  suite.check('the yields reach the fiber (0, 10, 20, then :done)', interpreted&.first == '[0, 10, 20, :done]')
end
suite.finish
