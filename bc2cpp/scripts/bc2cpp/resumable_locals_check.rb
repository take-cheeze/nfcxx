#!/usr/bin/env ruby
# encoding: UTF-8
# frozen_string_literal: true

# RESUMABLE_LOCAL_REGISTERS (codegen_resumable.rb, docs/bc2cpp-resumable-locals.md): a step keeps registers in C++ locals, loads them on
# entry and stores them back at each yield; a step taking a register's address (or BC2CPP_RESUMABLE_LOCALS=0) keeps references.
#
# Usage: MRBC=path/to/mrbc [BC2CPP_MRUBY_FULL=dir | BC2CPP_FULL_BUILD_DIR=dir] ruby scripts/bc2cpp/resumable_locals_check.rb

require_relative 'fixture_runtime'

suite = Bc2cppStepCheck.new('bc2cpp resumable locals check')

# RlClock#main_loop is a Fiber root with two yielding helpers; `row` is a fresh Array held across both yields.
# RlBlock#main_loop hands a block capturing its locals to a compiled method between yields.
SRC = <<~'RUBY'
  class RlClock
    def initialize
      @hclk = 0
      @target = 3
      @log = []
      @fiber = Fiber.new { main_loop }
    end

    def main_loop
      i = 0
      while i < 6
        row = [i, @hclk]
        wait_two
        @log << row
        wait_one
        @log << [row.size, i * 2, @hclk]
        i += 1
      end
      @log.size
    end

    def wait_one
      @hclk += 1
      Fiber.yield @hclk if @target <= @hclk
    end

    def wait_two
      @hclk += 2
      Fiber.yield if @target <= @hclk
    end

    def step(target)
      @target = target
      @fiber.resume
    end

    def running
      @fiber.alive?
    end

    def log
      @log
    end
  end

  class RlBlock
    def initialize
      @fiber = Fiber.new { main_loop }
    end

    def twice
      yield 1
      yield 2
    end

    def main_loop
      sum = 0
      i = 0
      while i < 3
        twice { |x| sum += x + i }
        Fiber.yield sum
        i += 1
      end
      sum
    end

    def step
      @fiber.resume
    end
  end
RUBY

OWNERS = %w[RlClock RlBlock].freeze

def step_function(code, klass = 'RlClock')
  code[/^static mrb_value #{klass}_main_loop_step\(mrb_state\* M.*?(?=^static mrb_value #{klass}_main_loop_step_thunk)/m].to_s
end

code = suite.generate(SRC, OWNERS)
step = step_function(code)
yields = step.scan('return bc2cpp_frame_value;').size
spills = step.scan(/^  (?:R\[\d+\] = r\d+; )*R\[\d+\] = r\d+;\n  mrb_write_barrier\(M, \(struct RBasic\*\)mrb_ary_ptr\(bc2cpp_regs_ary\)\);\n  return bc2cpp_frame_value;/).size
suite.check('main_loop compiles as a resumable step function', !step.empty? && yields >= 2)
suite.check('the step function marks its registers local', step.include?('// RESUMABLE_LOCAL_REGISTERS'))
suite.check('registers are locals loaded from the frame', step.match?(/^  mrb_value r\d+ = R\[\d+\];$/) &&
                                                          !step.match?(/^  mrb_value& r\d+ = R\[\d+\];$/))
suite.check("every yield (#{yields}) stores the registers back before returning", spills == yields)
block_step = step_function(code, 'RlBlock')
suite.check('a step function taking a register address keeps references into the frame',
            block_step.match?(/reinterpret_cast<uintptr_t>\(&r\d+\)/) && block_step.match?(/^  mrb_value& r\d+ = R\[\d+\];$/) &&
            !block_step.include?('RESUMABLE_LOCAL_REGISTERS'))

ENV['BC2CPP_RESUMABLE_LOCALS'] = '0'
off, = Dir.mktmpdir { |dir| Bc2cppFixtureRuntime.generate(SRC, dir, core: true, only_owners: OWNERS) }
ENV.delete('BC2CPP_RESUMABLE_LOCALS')
off_step = step_function(off)
suite.check('BC2CPP_RESUMABLE_LOCALS=0 keeps references into the frame',
            off_step.match?(/^  mrb_value& r\d+ = R\[\d+\];$/) && !off_step.include?('RESUMABLE_LOCAL_REGISTERS') &&
            !off_step.match?(/^  R\[(?:[2-9]|\d{2,})\] = r\d+;/))

DRIVER = <<~'RUBY'
  c = RlClock.new
  out = []
  t = 1
  while c.running
    out << c.step(t)
    GC.start
    t += 2
  end
  p out
  p c.log
  b = RlBlock.new
  p [b.step, b.step, b.step, b.step]
  puts 'end'
RUBY

suite.behaviour(DRIVER)
suite.finish
