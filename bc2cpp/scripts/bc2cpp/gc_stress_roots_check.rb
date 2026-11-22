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
# LITERAL_TABLES in a class unit (codegen_literal_tables.rb): the unit's word tables build what the VM's body built
# (fresh mutable containers and Strings, the frozen ones frozen), under the same GC stress; BC2CPP_LITERAL_WALK=0 keeps
# the pair-by-pair code.
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

  # LITERAL_WALK: class-body constant literals each followed by a def, an attr or a visibility send, so the walk steps
  # over the unit's own instructions; LITERAL_ARRAY_KEYS: Array keys; LITERAL_CONST_INTS: a proved Integer constant.
  # No Symbols: a fixture's names are not presym ids (class_body_lambda_check covers those).
  class LitConsts
    N = -1
    PLAIN = { 1 => 'a', 2 => [3, nil, true, false, 'b', -70_000], 3 => { 4 => 4096, 5 => N } }
    def plain_size = PLAIN.size
    TURNS = { [2, 4] => [6, 8], [4, 2] => [2, 6], [6, 8] => [4, N], [8, 6] => [8, 4] }.freeze
    attr_reader :x
    ROWS = [[1, 's'], [2, 's'], [N, 's'], [4, nil]]
    public
    NAMES = { 1 => 'u', 2 => 'd', 3 => 'l', 4 => N }.freeze
    def tag = :tag
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

OWNERS = %w[StressRoots IbCell LitConsts Array Enumerable Enumerator Integer Kernel Range].freeze
BARRIER = 'mrb_field_write_barrier_value('
MARK = '/* IMMEDIATE_BARRIER */'
# EMBED_STORE_OUTLINED: bc2cpp_embed_store runs the barrier itself (bc2cpp.rb).
def barrier?(body) = body.include?(BARRIER) || body.match?(/bc2cpp_embed_store(?:_unfrozen)?\(M, /)

def body_of(code, name)
  code.scan(/^(?:static )?mrb_value #{name}_impl\w*\(mrb_state\* M.*?(?=^(?:static )?mrb_value \w+\(mrb_state\* M|\z)/m).join
end

ENV['BC2CPP_IMMEDIATE_BARRIER'] = '0'
off = suite.generate(SRC, OWNERS)
ENV.delete('BC2CPP_IMMEDIATE_BARRIER')
suite.check('BC2CPP_IMMEDIATE_BARRIER=0 keeps every write barrier',
            !off.include?(MARK) && barrier?(body_of(off, 'IbCell_set_nil')))

ENV['BC2CPP_LITERAL_WALK'] = '0'
walk_off = suite.generate(SRC, OWNERS)
ENV.delete('BC2CPP_LITERAL_WALK')
unit_of = ->(text) { text[/^[^\n]*mrb_value bc2cpp_class_body_LitConsts\w*\(mrb_state\* M\) \{.*?^\}/m].to_s }
suite.check('BC2CPP_LITERAL_WALK=0: a literal before a def is built pair by pair',
            unit_of.call(walk_off).include?('mrb_hash_set(M, h, '))

code = suite.generate(SRC, OWNERS)
unit = unit_of.call(code)
suite.check('the class-body literals before a def, an attr and a visibility send are word tables',
            unit.scan('bc2cpp_lit_build(M, bc2cpp_lit,').size == 4 && !unit.include?('mrb_hash_set') &&
            !unit.include?('mrb_ary_new_from_values'))
suite.check('the proved constant N is a table word, not a kept read', unit.include?('0x9000, 0xffff, 0xffff') &&
            !unit.include?('bc2cpp_lit_d'))
suite.check('the arena result root is emitted in a method entry',
            code.match?(/return bc2cpp_cfunc_result\(\{M, M->gc\.arena_idx, StressRoots_grown_impl\(/))
# LITERAL_CONST_INTS: LIMIT is a proved Integer, so the lambda's table holds it and hands no read over.
suite.check('the lambda literal is a word table', code.include?('bc2cpp_lit_build(M, bc2cpp_lit, bc2cpp_lit_s, nullptr)') &&
                                                  code.include?('0x8005, 0x8007 };'))
suite.check('the stores compile to the embedded field', body_of(code, 'IbCell_set_nil').include?('(IbCell_ivars*)DATA_PTR(self))->ivar_v'))
%w[set_nil set_sym set_int].each do |name|
  body = body_of(code, "IbCell_#{name}")
  suite.check("#{name}: an immediate store has no write barrier", body.include?(MARK) && !barrier?(body))
end
%w[set_obj set_str initialize].each do |name|
  body = body_of(code, "IbCell_#{name}")
  suite.check("#{name}: a heap or unknown value keeps the write barrier", barrier?(body) && !body.include?(MARK))
end

DRIVER = <<~'RUBY'
  # The first call: a VM block's array result, then a respond_to? on it that allocates.
  p((1..2).flat_map { |x| [x] })
  s = StressRoots.new
  p s.grown(300)
  p s.flat(1..2)
  p s.flat([3, 4])
  p s.indexed
  p s.literals
  # The class-body tables: fresh mutable containers and Strings unless frozen, as the VM builds them.
  c = LitConsts
  p [c::PLAIN, c::TURNS, c::ROWS, c::NAMES]
  p [c::PLAIN.frozen?, c::PLAIN[1].frozen?, c::TURNS.frozen?, c::TURNS[[2, 4]].frozen?, c::TURNS.keys.first.frozen?,
     c::NAMES.frozen?, c::NAMES[1].frozen?, c::ROWS[0][1].equal?(c::ROWS[1][1])]
  c::PLAIN[1] << 'z'
  c::PLAIN[2] << 9
  c::PLAIN[9] = c::PLAIN.size
  c::TURNS[[2, 4]] << 1
  c::NAMES[1] << '!'
  c::ROWS[0][1] << 't'
  p [c::PLAIN, c::TURNS[[2, 4]], c::TURNS[[6, 8]], c::NAMES[1], c::ROWS]
  begin
    c::TURNS[[1, 1]] = 0
  rescue FrozenError => e
    p e.class
  end
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
  literals = '[{1 => "az", 2 => [3, nil, true, false, "b", -70000, 9], 3 => {4 => 4096, 5 => 7}}, ' \
             '{1 => "a", 2 => [3, nil, true, false, "b", -70000], 3 => {4 => 4096, 5 => 7}}, false, false]'
  suite.check('the compiled run prints what MRI prints',
              compiled == ['[1, 2]', '["298", "299"]', '[1, 2]', '[3, 4]', '[0, 1, 2]', literals,
                           '[{1 => "a", 2 => [3, nil, true, false, "b", -70000], 3 => {4 => 4096, 5 => -1}}, ' \
                           '{[2, 4] => [6, 8], [4, 2] => [2, 6], [6, 8] => [4, -1], [8, 6] => [8, 4]}, ' \
                           '[[1, "s"], [2, "s"], [-1, "s"], [4, nil]], {1 => "u", 2 => "d", 3 => "l", 4 => -1}]',
                           '[false, false, true, false, false, true, false, false]',
                           '[{1 => "az", 2 => [3, nil, true, false, "b", -70000, 9], 3 => {4 => 4096, 5 => -1}, 9 => 3}, ' \
                           '[6, 8, 1], [4, -1], "u!", [[1, "st"], [2, "s"], [-1, "s"], [4, nil]]]',
                           'FrozenError',
                           '[[0, 3], "3", nil, :off, -3, [5, 3]]', 'end'])
end
suite.finish
