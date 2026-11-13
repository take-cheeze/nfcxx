#!/usr/bin/env ruby
# frozen_string_literal: true

# STEP_SUPER_STATIC (codegen_resumable.rb): the resumable variants of `Range#max` / `Range#min` (mruby-range-ext) run
# their `super(&block)` in a step. The target, core `Enumerable#max` / `#min`, is fixed by the closed ancestry, so the
# step calls its entry (bc2cpp_dyn_super_static) and parks its frame without looking the method up.
#
#   1. generated code: each variant's step calls bc2cpp_dyn_super_static with the target's entry, and no
#      bc2cpp_dyn_super lookup is left;
#   2. run on a full-core mruby, compiled against interpreted: blocks that suspend inside the target, take the
#      resume value back across the super, raise after a resume, and break out of the Fiber body.
#
# Usage: MRBC=path/to/mrbc [BC2CPP_MRUBY_FULL=dir | BC2CPP_FULL_BUILD_DIR=dir] ruby scripts/bc2cpp/step_super_static_check.rb

require_relative 'fixture_runtime'

suite = Bc2cppStepCheck.new('bc2cpp step super static check')

# [label, fiber body]. Each body runs in its own compiled method, so the fiber's frames are compiled steps.
SCENARIOS = [
  ['max yields each pair', '(1..4).max { |a, b| Fiber.yield [a, b]; a <=> b }'],
  ['min yields each pair', '(1..4).min { |a, b| Fiber.yield [a, b]; a <=> b }'],
  ['max takes the resume value', '(1..3).max { |a, b| Fiber.yield(a) || (a <=> b) }'],
  ['min takes the resume value', "('a'..'d').min { |a, b| Fiber.yield(b) || (a <=> b) }"],
  ['max raises after a resume', '(1..3).max { |a, b| Fiber.yield a; raise ArgumentError, "from #{a}" }'],
  ['min breaks out', '[(1..3).min { |a, b| Fiber.yield a; break :out }, :after]'],
  ['max over an empty Range', '(3..1).max { |a, b| Fiber.yield a; 0 }'],
  ['max without a block', 'Fiber.yield(:before); (1..5).max'],
  ['max of an endless Range', '(1..).max { |a, b| Fiber.yield a; 0 }']
].freeze

PROBE = <<~RUBY
  class SuperStepProbe
  #{SCENARIOS.each_with_index.map { |(_, body), i| "  def fiber_#{i}\n    Fiber.new { #{body} }\n  end\n" }.join("\n")}
  end
RUBY

# Resumes with the step count: odd counts send nil (the block's own comparison), even ones a comparison value.
FEED = <<~RUBY
  def feed(f)
    out = []
    n = 0
    while f.alive?
      out << f.resume(n.even? ? nil : (n % 3) - 1)
      n += 1
      GC.start
    end
    out
  end
RUBY

DRIVER = "#{Bc2cppStepCheck::SHOW}#{FEED}" +
         SCENARIOS.each_with_index.map { |(label, _), i| "show('#{label}') { feed(SuperStepProbe.new.fiber_#{i}) }" }.join("\n") +
         "\nputs 'end'\n"

OWNERS = %w[Enumerable Range SuperStepProbe].freeze
code = suite.generate(PROBE, OWNERS, guards: true)

# A step runs to the next function (its body has column-0 braces of its own).
step = ->(name) { code[/^static mrb_value #{name}_rsm_step\(.*?(?=^(?:\[\[maybe_unused\]\] )?(?:static )?mrb_value \w+\(mrb_state\* M|\z)/m].to_s }
{ 'Range_max' => 'Enumerable_max', 'Range_min' => 'Enumerable_min' }.each do |caller, target|
  text = step.call(caller)
  suite.check("#{caller}: the step's super calls #{target} with no lookup",
              text.match?(/= bc2cpp_dyn_super_static\(M, self, #{target}, \w+\(M\), /) && !text.include?('= bc2cpp_dyn_super(M'))
end
suite.check('no bc2cpp_dyn_super lookup in the generated code', !code.include?('= bc2cpp_dyn_super(M'))

suite.behaviour(DRIVER, same: true) do |_interpreted, compiled|
  next unless compiled

  suite.check('the resume value reaches the block across the super', compiled.any? { |l| l.start_with?('max takes the resume value: [') })
end
suite.finish
