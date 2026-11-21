#!/usr/bin/env ruby
# encoding: UTF-8
# frozen_string_literal: true

# GC roots in compiled code: a block result is rooted after bc2cpp_yield_argv (a VM block's result is otherwise in no root), and a
# cfunc result is rooted over the VM epilogue, which reallocs a grown arena (bc2cpp_cfunc_result). Both lose the object only under
# an MRB_GC_STRESS mruby, so point BC2CPP_MRUBY_FULL at one to exercise them; a normal build checks the output only.
#
# IMMEDIATE_BARRIER (codegen_ivar_poly.rb proven_immediate_operand?): an embedded ivar store of a value every reaching
# definition proves nil, true, false, a Symbol or a Fixnum has no write barrier; any other value, and every store under
# BC2CPP_IMMEDIATE_BARRIER=0, keeps it. The driver stores across incremental GC steps (tiny interval and step ratios,
# generational mode), where a barrier missing on a heap value would lose it.
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

  class IbCell
    def initialize(v)
      @v = v
    end
    def set_nil; @v = nil; self; end
    def set_sym(c); @v = c ? :on : :off; self; end
    def set_int(c); @v = c ? 5 : -3; self; end
    def set_obj(o); @v = o; self; end
    def set_str(n); @v = n.to_s; self; end
    def v; @v; end
  end
RUBY

OWNERS = %w[StressRoots IbCell Array Enumerable Enumerator Integer Kernel Range].freeze
BARRIER = 'mrb_field_write_barrier_value('
MARK = '/* IMMEDIATE_BARRIER */'

def body_of(code, name)
  code.scan(/^(?:static )?mrb_value #{name}_impl\w*\(mrb_state\* M.*?(?=^(?:static )?mrb_value \w+\(mrb_state\* M|\z)/m).join
end

ENV['BC2CPP_IMMEDIATE_BARRIER'] = '0'
off = suite.generate(SRC, OWNERS)
ENV.delete('BC2CPP_IMMEDIATE_BARRIER')
suite.check('BC2CPP_IMMEDIATE_BARRIER=0 keeps every write barrier',
            !off.include?(MARK) && body_of(off, 'IbCell_set_nil').include?(BARRIER))

code = suite.generate(SRC, OWNERS)
suite.check('the arena result root is emitted in a method entry',
            code.match?(/return bc2cpp_cfunc_result\(\{M, M->gc\.arena_idx, StressRoots_grown_impl\(/))
suite.check('the stores compile to the embedded field', body_of(code, 'IbCell_set_nil').include?('(IbCell_ivars*)DATA_PTR(self))->ivar_v'))
%w[set_nil set_sym set_int].each do |name|
  body = body_of(code, "IbCell_#{name}")
  suite.check("#{name}: an immediate store has no write barrier", body.include?(MARK) && !body.include?(BARRIER))
end
%w[set_obj set_str initialize].each do |name|
  body = body_of(code, "IbCell_#{name}")
  suite.check("#{name}: a heap or unknown value keeps the write barrier", body.include?(BARRIER) && !body.include?(MARK))
end

DRIVER = <<~'RUBY'
  # The first call: a VM block's array result, then a respond_to? on it that allocates.
  p((1..2).flat_map { |x| [x] })
  s = StressRoots.new
  p s.grown(300)
  p s.flat(1..2)
  p s.flat([3, 4])
  p s.indexed
  GC.generational_mode = true if GC.respond_to?(:generational_mode=)
  GC.interval_ratio = 1 if GC.respond_to?(:interval_ratio=)
  GC.step_ratio = 1 if GC.respond_to?(:step_ratio=)
  cells = (0...200).map { |i| IbCell.new(i) }
  4.times do |round|
    cells.each_with_index do |c, i|
      case (i + round) % 5
      when 0 then c.set_nil
      when 1 then c.set_sym(i.even?)
      when 2 then c.set_int(i.odd?)
      when 3 then c.set_obj([i, round])
      else c.set_str(i * round)
      end
      'x' * 64
    end
    GC.start if round == 2
  end
  p cells.map(&:v).first(6)
  puts 'end'
RUBY

suite.behaviour(DRIVER) do |_, compiled|
  suite.check('the compiled run prints what MRI prints', compiled == ['[1, 2]', '["298", "299"]', '[1, 2]', '[3, 4]', '[0, 1, 2]',
                                                                           '[[0, 3], "3", nil, :off, -3, [5, 3]]', 'end'])
end
suite.finish
