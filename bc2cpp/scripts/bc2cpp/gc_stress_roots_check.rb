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

    LIMIT = 7
    # LITERAL_TABLES: a lambda's constant literal comes from its word table, a fresh tree of fresh Strings per call.
    def literals
      make = -> { { 1 => 'a', 2 => [3, nil, true, false, 'b', -70_000], 3 => { 4 => 4096, 5 => LIMIT } } }
      a = make.call
      b = make.call
      a[1] << 'z'
      a[2] << 9
      [a, b, a[1].equal?(b[1]), a[1].frozen?]
    end
  end
RUBY

code = suite.generate(SRC, %w[StressRoots Array Enumerable Enumerator Integer Kernel Range])
suite.check('the arena result root is emitted in a method entry',
            code.match?(/return bc2cpp_cfunc_result\(\{M, M->gc\.arena_idx, StressRoots_grown_impl\(/))
suite.check('the lambda literal is a word table', code.include?('bc2cpp_lit_build(M, bc2cpp_lit, bc2cpp_lit_s, bc2cpp_lit_d)'))

DRIVER = <<~'RUBY'
  # The first call: a VM block's array result, then a respond_to? on it that allocates.
  p((1..2).flat_map { |x| [x] })
  s = StressRoots.new
  p s.grown(300)
  p s.flat(1..2)
  p s.flat([3, 4])
  p s.indexed
  p s.literals
  puts 'end'
RUBY

suite.behaviour(DRIVER) do |_, compiled|
  literals = '[{1 => "az", 2 => [3, nil, true, false, "b", -70000, 9], 3 => {4 => 4096, 5 => 7}}, ' \
             '{1 => "a", 2 => [3, nil, true, false, "b", -70000], 3 => {4 => 4096, 5 => 7}}, false, false]'
  suite.check('the compiled run prints what MRI prints',
              compiled == ['[1, 2]', '["298", "299"]', '[1, 2]', '[3, 4]', '[0, 1, 2]', literals, 'end'])
end
suite.finish
