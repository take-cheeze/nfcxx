#!/usr/bin/env ruby
# encoding: UTF-8
# frozen_string_literal: true

# RESUMABLE_ARGS (codegen_resumable.rb resumable_entry_function): the entry puts each required argument in its frame register and the
# driver's first step takes the frame (Bc2cppResumable.take_initial). Two roots interleave with GC.start, each keeping its own.
#
# Usage: MRBC=path/to/mrbc [BC2CPP_MRUBY_FULL=dir | BC2CPP_FULL_BUILD_DIR=dir] ruby scripts/bc2cpp/resumable_args_check.rb

require_relative 'fixture_runtime'

suite = Bc2cppStepCheck.new('bc2cpp resumable args check')

# RaClock#run is a Fiber root taking two required arguments; it keeps them across each yield.
SRC = <<~'RUBY'
  class RaClock
    def start(base, step)
      @base = base
      @step = step
      boot
    end

    def boot
      @fiber = Fiber.new { run(@base, @step) }
    end

    def run(base, step)
      acc = base
      i = 0
      while i < 4
        acc += step
        @acc = acc
        wait
        i += 1
      end
      [acc, i]
    end

    def wait
      Fiber.yield @acc
    end

    def go
      @fiber.resume
    end

    def maybe(a, b = 2)
      a + b
    end
  end
RUBY

code = suite.generate(SRC, %w[RaClock])
suite.check('run compiles as a resumable step function', code.include?('static mrb_value RaClock_run_step(mrb_state* M'))
suite.check('the entry takes its two arguments as mrb_values',
            code.match?(/^mrb_value RaClock_run_impl\(mrb_state\* M, mrb_value self, mrb_value \w+, mrb_value \w+\) \{/))
suite.check('the entry fills the argument registers of the frame', code.match?(/F->regs\[\d+\] = \w+;/))
suite.check('a method that no fiber root reaches (maybe) gets no step function', !code.include?('RaClock_maybe_step('))

DRIVER = <<~'RUBY'
  a = RaClock.new
  b = RaClock.new
  a.start(10, 3)
  b.start(100, 7)
  out = []
  4.times do
    out << a.go
    GC.start
    out << b.go
  end
  out << a.go
  out << b.go
  p out
  p [a.maybe(1), a.maybe(1, 5)]
  puts 'end'
RUBY

suite.behaviour(DRIVER)
suite.finish
