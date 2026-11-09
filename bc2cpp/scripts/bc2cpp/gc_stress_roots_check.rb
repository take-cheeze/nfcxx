#!/usr/bin/env ruby
# encoding: UTF-8
# frozen_string_literal: true

# GC roots in compiled code: a block result is rooted after bc2cpp_yield_argv (a VM block's result is otherwise in no root), and a
# cfunc result is rooted over the VM epilogue, which reallocs a grown arena (bc2cpp_cfunc_result). Both lose the object only under
# an MRB_GC_STRESS mruby, so point BC2CPP_MRUBY_FULL at one to exercise them; a normal build checks the output only.
#
# Usage: MRBC=path/to/mrbc [BC2CPP_MRUBY_FULL=dir | BC2CPP_FULL_BUILD_DIR=dir] ruby scripts/bc2cpp/gc_stress_roots_check.rb

require_relative 'fixture_runtime'

suite = Bc2cppStepCheck.new('bc2cpp gc stress roots check')

SRC = <<~'RUBY'
  class StressRoots
    # More than 100 arena slots without a restore: the cfunc epilogue shrinks the arena while the result is only in a C++ local.
    def grown(count)
      kept = []
      count.times { |n| kept << n.to_s }
      kept.last(2)
    end

    def flat(range)
      range.flat_map { |x| [x] }
    end

    def indexed
      [1, 2, 3].each_with_index.map { |_, i| i }
    end
  end
RUBY

code = suite.generate(SRC, %w[StressRoots Array Enumerable Enumerator Integer Kernel Range])
suite.check('the arena result root is emitted in a method entry',
            code.match?(/return bc2cpp_cfunc_result\(\{M, M->gc\.arena_idx, StressRoots_grown_impl\(/))

DRIVER = <<~'RUBY'
  # The first call: a VM block's array result, then a respond_to? on it that allocates.
  p((1..2).flat_map { |x| [x] })
  s = StressRoots.new
  p s.grown(300)
  p s.flat(1..2)
  p s.flat([3, 4])
  p s.indexed
  puts 'end'
RUBY

suite.behaviour(DRIVER) do |_, compiled|
  suite.check('the compiled run prints what MRI prints', compiled == ['[1, 2]', '["298", "299"]', '[1, 2]', '[3, 4]', '[0, 1, 2]', 'end'])
end
suite.finish
