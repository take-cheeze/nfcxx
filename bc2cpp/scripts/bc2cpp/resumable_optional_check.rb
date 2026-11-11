#!/usr/bin/env ruby
# encoding: UTF-8
# frozen_string_literal: true

# RESUMABLE_OPTIONAL (codegen_resumable.rb): the entry records the given optional count as -(given + 1) in the frame state and the
# step's jump-table glue runs the default of each omitted one. Roots with 0, 1 and 2 optionals interleave with GC.start.
#
# Usage: MRBC=path/to/mrbc [BC2CPP_MRUBY_FULL=dir | BC2CPP_FULL_BUILD_DIR=dir] ruby scripts/bc2cpp/resumable_optional_check.rb

require_relative 'fixture_runtime'

suite = Bc2cppStepCheck.new('bc2cpp resumable optional check')

SRC = <<~'RUBY'
  class OptClock
    def make(kind, base)
      case kind
      when :a then @f = Fiber.new { run(base) }
      when :b then @f = Fiber.new { run(base, 5) }
      when :c then @f = Fiber.new { run(base, 5, 'y') }
      end
      self
    end

    def run(base, step = base * 2, extra = 'x')
      acc = base
      i = 0
      while i < 3
        acc += step
        @acc = acc
        wait
        i += 1
      end
      [acc, extra, i]
    end

    def wait
      Fiber.yield @acc
    end

    def go
      @f.resume
    end
  end
RUBY

code = suite.generate(SRC, %w[OptClock])
suite.check('run compiles as a resumable step function', code.include?('static mrb_value OptClock_run_step(mrb_state* M'))
suite.check('the entry takes all three positional arguments and the given count last',
            code.match?(/^mrb_value OptClock_run_impl\(mrb_state\* M, mrb_value self, mrb_value \w+, mrb_value \w+, mrb_value \w+, mrb_int bc2cpp_given_opt\) \{/))
suite.check('the entry records the given count as a negative frame state', code.include?('F->state = -(bc2cpp_given_opt + 1);'))
suite.check('the step reads the given count from a negative frame state',
            code.include?('const mrb_int bc2cpp_given_opt = bc2cpp_state < 0 ? -bc2cpp_state - 1 : 0;'))
suite.check('the jump-table glue switches on the given count inside the step',
            code[/static mrb_value OptClock_run_step\(.*?\n\}\n/m].to_s.include?('switch (bc2cpp_given_opt)'))

DRIVER = <<~'RUBY'
  x = OptClock.new.make(:a, 1)
  y = OptClock.new.make(:b, 2)
  z = OptClock.new.make(:c, 3)
  out = []
  4.times do
    out << x.go
    GC.start
    out << y.go
    out << z.go
  end
  p out
  puts 'end'
RUBY

suite.behaviour(DRIVER) do |_, compiled|
  # MRI's own output (ruby 3.x): the three frames keep their own defaults and given counts.
  suite.check('the compiled run prints what MRI prints',
              compiled&.first == '[3, 7, 8, 5, 12, 13, 7, 17, 18, [7, "x", 3], [17, "x", 3], [18, "y", 3]]')
end
suite.finish
