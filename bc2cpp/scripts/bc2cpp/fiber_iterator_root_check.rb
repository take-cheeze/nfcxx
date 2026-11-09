#!/usr/bin/env ruby
# encoding: UTF-8
# frozen_string_literal: true

# RECEIVER_ITERATOR_ROOTS (codegen_block_fallback.rb): a fiber root that sends `n.step(a, b) { ... }` with a block reaching
# Fiber.yield through its own helper methods (Optcarrot::PPU#main_loop's shape) needs the iterator compiled as a step; a
# plain C-called Integer#step raised "can't cross C function boundary". Interpreted and compiled runs must print the same.
#
# Usage: MRBC=path/to/mrbc [BC2CPP_MRUBY_FULL=dir | BC2CPP_FULL_BUILD_DIR=dir] ruby scripts/bc2cpp/fiber_iterator_root_check.rb

require_relative 'fixture_runtime'

suite = Bc2cppStepCheck.new('bc2cpp fiber iterator root check')

SRC = <<~RUBY
  class IterRootPpu
    def initialize
      @hclk = 0
      @target = 0
      @line = 0
      @log = []
    end

    attr_reader :log

    def run
      @fiber ||= Fiber.new do
        main_loop
        :done
      end
      @target += 20 unless @fiber.resume
    end

    def wait_frame
      Fiber.yield true
    end

    def wait_one_clock
      @hclk += 1
      Fiber.yield if @target <= @hclk
    end

    def wait_two_clocks
      @hclk += 2
      Fiber.yield if @target <= @hclk
    end

    def main_loop
      wait_frame
      while true
        3.step(11, 4) do
          @log << @hclk
          wait_two_clocks
          wait_two_clocks
        end
        while true
          @line += 1
          wait_one_clock
          break if @line % 3 == 0

          0.step(16, 8) { @log << -@hclk; wait_one_clock }
        end
        wait_frame
      end
    end
  end
RUBY

code = suite.generate(SRC, %w[IterRootPpu Integer Float Kernel], guards: true)
suite.check('Integer#step is compiled as a step', code.include?('Integer_step_step('))

DRIVER = <<~'RUBY'
  m = IterRootPpu.new
  8.times { m.run }
  p m.log
  puts 'end'
RUBY

suite.behaviour(DRIVER) do |interpreted, _|
  suite.check('the interpreted run logged clocks', interpreted&.first&.start_with?('[0, 4, 8'))
end
suite.finish
