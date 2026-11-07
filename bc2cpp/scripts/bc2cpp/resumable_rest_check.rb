#!/usr/bin/env ruby
# encoding: UTF-8
# frozen_string_literal: true

# RESUMABLE_REST (codegen_resumable.rb): the registered wrapper checks the count and builds the rest Array; the impl checks nothing and
# the step reads the Array from its register. Roots with 0..2 extra arguments, alone or after optionals, interleave with GC.start.
#
# Usage: MRBC=path/to/mrbc [BC2CPP_MRUBY_FULL=dir | BC2CPP_FULL_BUILD_DIR=dir] ruby scripts/bc2cpp/resumable_rest_check.rb

require_relative 'fixture_runtime'

suite = Bc2cppStepCheck.new('bc2cpp resumable rest check')

SRC = <<~'RUBY'
  class RestClock
    def make(kind, base)
      case kind
      when :a then @f = Fiber.new { run(base) }
      when :b then @f = Fiber.new { run(base, 5) }
      when :c then @f = Fiber.new { run(base, 5, 6) }
      when :d then @f = Fiber.new { run_opt(base) }
      when :e then @f = Fiber.new { run_opt(base, 3) }
      when :f then @f = Fiber.new { run_opt(base, 3, 4, 9) }
      end
      self
    end

    def run(base, *steps)
      acc = base
      i = 0
      while i < 3
        acc += steps.empty? ? 1 : steps.first
        @acc = acc
        wait
        i += 1
      end
      [acc, steps, i]
    end

    def run_opt(base, step = base * 2, *more)
      acc = base
      i = 0
      while i < 3
        acc += step + more.size
        @acc = acc
        wait
        i += 1
      end
      [acc, step, more, i]
    end

    def wait
      Fiber.yield @acc
    end

    def go
      @f.resume
    end
  end
RUBY

code = suite.generate(SRC, %w[RestClock])
suite.check('run compiles as a resumable step function', code.include?('static mrb_value RestClock_run_step(mrb_state* M'))
suite.check('run_opt compiles as a resumable step function', code.include?('static mrb_value RestClock_run_opt_step(mrb_state* M'))
suite.check('the impl takes the rest as an Array argument',
            code.match?(/^mrb_value RestClock_run_impl\(mrb_state\* M, mrb_value self, mrb_value \w+, mrb_value \w+\) \{/))
run_body = code[/^mrb_value RestClock_run_impl\(.*?\n\}\n/m].to_s
suite.check('the impl of run checks no argument count itself', !run_body.empty? && !run_body.include?('bc2cpp_check_argc'))
suite.check('the impl of run_opt takes the given count after the rest',
            code.match?(/^mrb_value RestClock_run_opt_impl\(mrb_state\* M, mrb_value self, mrb_value \w+, mrb_value \w+, mrb_value \w+, mrb_int bc2cpp_given_opt\) \{/))
suite.check('the wrapper checks the count and builds the rest Array',
            code.include?('bc2cpp_check_argc(M, 1, -1);') && code.include?('mrb_ary_new_from_values(M, bc2cpp_rest_len, bc2cpp_rest_ptr)'))

DRIVER = <<~'RUBY'
  objs = [:a, :b, :c, :d, :e, :f].each_with_index.map { |k, i| RestClock.new.make(k, i + 1) }
  out = []
  4.times do
    objs.each { |o| out << o.go }
    GC.start
  end
  p out
  puts 'end'
RUBY

suite.behaviour(DRIVER) do |_, compiled|
  # MRI's own output: each frame keeps its rest Array and its given optional count.
  suite.check('the compiled run prints what MRI prints',
              compiled&.first == '[2, 7, 8, 12, 8, 11, 3, 12, 13, 20, 11, 16, 4, 17, 18, 28, 14, 21, ' \
                                 '[4, [], 3], [17, [5], 3], [18, [5, 6], 3], [28, 8, [], 3], [14, 3, [], 3], [21, 3, [4, 9], 3]]')
end
suite.finish
