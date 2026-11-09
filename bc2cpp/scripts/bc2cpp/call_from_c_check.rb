#!/usr/bin/env ruby
# encoding: UTF-8
# frozen_string_literal: true

# CALL_FROM_C (codegen_resumable.rb bc2cpp_resumable_resume_from_c): a resumable method entered from C (interpreted Fiber or the VM)
# runs the frames its steps CALL to their end, so non-yielding blocks give the interpreted results; a Fiber.yield there is a FiberError.
#
# Usage: MRBC=path/to/mrbc [BC2CPP_MRUBY_FULL=dir | BC2CPP_FULL_BUILD_DIR=dir] ruby scripts/bc2cpp/call_from_c_check.rb

require_relative 'fixture_runtime'

suite = Bc2cppStepCheck.new('bc2cpp call from c check')

# A Fiber body calling the core iterators makes them take their resumable variant; the driver runs them from an interpreted Fiber.
PROBE = <<~RUBY
  class CallFromCProbe
    def run
      Fiber.new do
        r = []
        r << [3, 1, 2].sort { |a, b| Fiber.yield a; a <=> b }
        r << (1..3).collect { |x| Fiber.yield x; x }
        r << [3, 1, 2].sort! { |a, b| a <=> b }
        r
      end
    end
  end
RUBY

DRIVER = Bc2cppStepCheck::SHOW + <<~'RUBY'
  show('sort in fiber') { Fiber.new { [3, 1, 2].sort { |a, b| a <=> b } }.resume }
  show('sort in fiber, large') { Fiber.new { (1..20).to_a.reverse.sort { |a, b| a <=> b } }.resume }
  show('sort! in fiber') { Fiber.new { [3, 1, 2].sort! { |b, a| a <=> b } }.resume }
  show('collect in fiber') { Fiber.new { (1..3).collect { |x| x * 2 } }.resume }
  show('inject in fiber') { Fiber.new { (1..4).inject(0) { |a, x| a + x } }.resume }
  show('flat_map in fiber') { Fiber.new { (1..2).flat_map { |x| [x, x] } }.resume }
  show('sort yield in fiber') { Fiber.new { [2, 1].sort { |a, b| Fiber.yield a; a <=> b } }.resume }
  show('collect yield in fiber') { Fiber.new { (1..2).collect { |x| Fiber.yield x; x } }.resume }
  puts 'end'
RUBY

code = suite.generate(PROBE, %w[Array Enumerable Range Hash Integer String StringIO CallFromCProbe], guards: true)
suite.check('Array#sort has a resumable variant', code.include?('Array_sort_rsm_impl'))

# The last two lines yield inside an interpreted Fiber: a yield through compiled code needs a compiled Fiber body, so they are
# FiberErrors here (the interpreted run suspends them in its VM frames).
PLAIN = 6
suite.behaviour(DRIVER, banner: 'interpreted Fibers calling compiled iterators', same: false) do |interpreted, compiled|
  suite.check('the non-yielding blocks print what the interpreted runs print', interpreted&.first(PLAIN) == compiled&.first(PLAIN))
  suite.check('a Fiber.yield across the compiled iterator is a FiberError',
              compiled&.values_at(PLAIN, PLAIN + 1)&.all? { |l| l.include?('FiberError') })
end
suite.finish
