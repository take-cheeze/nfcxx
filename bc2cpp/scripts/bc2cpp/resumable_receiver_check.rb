#!/usr/bin/env ruby
# encoding: UTF-8
# frozen_string_literal: true

# RECEIVER_ROOTS (codegen_block_fallback.rb): a Fiber body calling `arr.each_index { ... }` makes every definition of that name a
# candidate root, so the core iterator compiles as a resumable step and a Fiber.yield in its block crosses only VM frames.
#
# Usage: MRBC=path/to/mrbc [BC2CPP_MRUBY_FULL=dir | BC2CPP_FULL_BUILD_DIR=dir] ruby scripts/bc2cpp/resumable_receiver_check.rb

require_relative 'fixture_runtime'

suite = Bc2cppStepCheck.new('bc2cpp resumable receiver check')

SRC = <<~'RUBY'
  class RvClock
    def start(arr)
      @fiber = Fiber.new { arr.each_index { |i| Fiber.yield i } }
    end

    def go
      @fiber.resume
    end
  end
RUBY

code = suite.generate(SRC, %w[RvClock Array])
suite.check('Array#each_index compiles as a resumable step function (its variant)', code.include?('static mrb_value Array_each_index_rsm_step(mrb_state* M'))
suite.check('the entry takes the block', code.match?(/^mrb_value Array_each_index_impl\(mrb_state\* M, mrb_value self, mrb_value bc2cpp_blk\) \{/))

DRIVER = <<~'RUBY'
  a = RvClock.new
  arr = [10, 20, 30]
  a.start(arr)
  out = []
  3.times { out << a.go; GC.start }
  out << a.go
  p out
  puts 'end'
RUBY

suite.behaviour(DRIVER) do |interpreted, _|
  suite.check('the fiber yields 0, 1, 2 and then the array', interpreted&.first == '[0, 1, 2, [10, 20, 30]]')
end
suite.finish
