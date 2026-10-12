#!/usr/bin/env ruby
# frozen_string_literal: true

# The origin table's joins as may-sets (ADR 0379): an `ambiguous` row carries the sorted, distinct categories of the
# definitions that reach it (`literal_or_fresh|parameter`), and the census reads that as `join` (or as the one origin
# the definitions agree on). Each case has a positive answer and a negative one: a set with an unprovable member stays
# `unknown`, a refusal stays a refusal, an exact row is unchanged. Hand-built bytecode, no compiler needed.
require 'set'
require_relative '../../tools/bc2cpp/irep'
require_relative '../../tools/bc2cpp/bytecode_ir'
unless defined?(CodeGen)
  # site_origin_table.rb prepends into CodeGen; the check needs only the writer.
  class CodeGen; end
end
require_relative '../../tools/bc2cpp/site_origin_table'
require_relative '../../tools/bc2cpp/site_census'

def insn(addr, op, args)
  Insn.new(lineno: 1, addr: addr, op: op, args: args, raw: "#{op} #{args}")
end

failures = []
check = ->(label, ok) { failures << label unless ok }
writer = lambda do |list, index, reg, nlocals: nil|
  irep = Irep.new(label: 'may_set', instructions: list, catch_handlers: [], nlocals: nlocals)
  SiteOriginTable::Writer.origin(irep, index, reg)
end

# 0: ENTER (one required)  1: JMPNOT R9 -> 8  2: LOADI_1 R1  3: NOP  4: RETURN R1 (@8)
# R1 is the parameter on the skipping path and the literal on the other: a join of two origins.
param_or_literal = [
  insn(0, 'ENTER', "1:0:0:0:0:0:0:0\t(0x0)"), insn(2, 'JMPNOT', "R9\t8"), insn(4, 'LOADI_1', 'R1 (1)'),
  insn(6, 'NOP', ''), insn(8, 'RETURN', 'R1')
]
check.call('a join of a parameter and a literal is the may-set of both, sorted',
           writer.call(param_or_literal, 4, '1') == ['ambiguous', 'literal_or_fresh|parameter', 'ENTER@0,LOADI_1@2'])
check.call('the single-definition read after the LOADI stays exact (negative)',
           writer.call(param_or_literal, 3, '1') == ['exact', 'literal_or_fresh', 'LOADI_1@2'])

# Two writes of the same origin: the set collapses to one category, still ambiguous (two definitions).
same = [
  insn(0, 'ENTER', "1:0:0:0:0:0:0:0\t(0x0)"), insn(2, 'JMPNOT', "R9\t8"), insn(4, 'LOADI_1', 'R1 (1)'),
  insn(6, 'JMP', '10'), insn(8, 'LOADI_2', 'R1 (2)'), insn(10, 'RETURN', 'R1')
]
check.call('two literals give one category with two definitions', writer.call(same, 5, '1') == ['ambiguous', 'literal_or_fresh', 'LOADI_1@2,LOADI_2@4'])

# A call has no emitted text here, so it is a call_result (direct or by name is not provable).
call_or_param = [
  insn(0, 'ENTER', "1:0:0:0:0:0:0:0\t(0x0)"), insn(2, 'JMPNOT', "R9\t8"), insn(4, 'SEND0', "R1\t:f"),
  insn(6, 'NOP', ''), insn(8, 'RETURN', 'R1')
]
check.call('a send in the join is a call_result in the set', writer.call(call_or_param, 4, '1') == ['ambiguous', 'call_result|parameter', 'ENTER@0,SEND0@2'])

# ENTER's nil for a local joins the write on the other path: parameter-less method, local R3 (nlocals 4).
local_or_literal = [
  insn(0, 'ENTER', "1:0:0:0:0:0:0:0\t(0x0)"), insn(2, 'JMPNOT', "R1\t8"), insn(4, 'LOADI_5', 'R3 (5)'),
  insn(6, 'NOP', ''), insn(8, 'RETURN', 'R3')
]
check.call('a local written on one path joins the literal with ENTER\'s nil (one category, two definitions)',
           writer.call(local_or_literal, 4, '3', nlocals: 4) == ['ambiguous', 'literal_or_fresh', 'ENTER@0,LOADI_5@2'])
check.call('the same local with nlocals unknown stays refused with the ENTER cause (negative)',
           writer.call(local_or_literal, 4, '3') == ['refused', 'unmodelled:ENTER:temp', '-'])

# The ENTER parameter definitions are 'parameter'; the local's nil is not.
check.call('ENTER-stored R1 is a parameter', writer.call(local_or_literal, 1, '1') == ['exact', 'parameter', 'ENTER@0'])

# Producers that differ inside one instruction's text (a fast path and its dispatch): the writing op still says what
# it leaves. A call is a call_result, an operator an operator_result, an index an indexed_result; any other op with
# disagreeing producers stays unknown (negative), and agreeing producers keep the text's origin.
text_origin = lambda do |op, args, text|
  list = [insn(0, op, args), insn(2, 'RETURN', 'R1')]
  irep = Irep.new(label: 'txt', instructions: list, catch_handlers: [])
  SiteOriginTable::INSN_TEXT[['txt', 0]] = text
  SiteOriginTable::Writer.origin(irep, 1, '1')[1]
end
mixed = "  r1 = mrb_nil_value();\n  r1 = bc2cpp_send(M, r1, 0, 0);\n"
check.call('a SEND with disagreeing producers is a call_result', text_origin.call('SEND0', "R1\t:f", mixed) == 'call_result')
check.call('an ADD with disagreeing producers is an operator_result', text_origin.call('ADD', "R1\t(R2)", mixed) == 'operator_result')
check.call('a GETIDX0 with disagreeing producers is an indexed_result', text_origin.call('GETIDX0', "R1\tR0[0]", mixed) == 'indexed_result')
check.call('an op that is none of those with disagreeing producers stays unknown (negative)',
           text_origin.call('LOADSYM', "R1\t:a", mixed) == 'unknown')
check.call('agreeing producers keep the text origin', text_origin.call('SEND0', "R1\t:f", "  r1 = bc2cpp_send(M, r1, 0, 0);\n") == 'dynamic_call_result')

# Census side: the origin of a row from its set.
census = SiteCensus
tag = '/*SO:l:4:1:1*/'
line = "  r2 = bc2cpp_send(M, r1, 0, 0); #{tag}"
table = lambda do |status, category|
  { ['l', 4, '1', '1'] => [status, category, 'x'] }
end
check.call('two different origins are a join, with the set kept',
           census.exact_origin(line, 'r1', table.call('ambiguous', 'literal_or_fresh|parameter')) ==
             ['join', 'ambiguous', %w[literal_or_fresh parameter]])
check.call('one origin on every path is that origin',
           census.exact_origin(line, 'r1', table.call('ambiguous', 'parameter')) == ['parameter', 'ambiguous', %w[parameter]])
check.call('an unprovable member keeps the site unknown (negative)',
           census.exact_origin(line, 'r1', table.call('ambiguous', 'parameter|unknown')) == ['unknown', 'ambiguous', %w[parameter unknown]])
check.call('an ambiguous row from an older table (no set) stays unknown (negative)',
           census.exact_origin(line, 'r1', table.call('ambiguous', '-')) == ['unknown', 'ambiguous', nil])
check.call('a refused row keeps its status and has no set (negative)',
           census.exact_origin(line, 'r1', table.call('refused', 'unmodelled:ENTER:temp')) == ['unknown', 'refused', nil])
check.call('an exact row is unchanged', census.exact_origin(line, 'r1', table.call('exact', 'constant')) == ['constant', 'exact', nil])
check.call('a receiver register that is not the tagged one is not trusted (negative)',
           census.exact_origin(line, 'r2', table.call('ambiguous', 'literal_or_fresh|parameter')) == ['unknown', 'reg_mismatch', nil])

# A non-register receiver: the element variable of an inlined `&:sym` loop is the array read that opens the body.
loop_lines = <<~CPP.lines
  for (mrb_int bc2cpp_sym_i_3 = 0; bc2cpp_sym_i_3 < RARRAY_LEN(r2); ++bc2cpp_sym_i_3) {
    mrb_value bc2cpp_sym_e_3 = bc2cpp_ary_entry(M, r2, bc2cpp_sym_i_3);
    bc2cpp_send(M, bc2cpp_sym_e_3, 717, 0);
  }
CPP
check.call('a loop element variable read from an array is an indexed_result',
           census.loop_element_origin(loop_lines, 2, 'bc2cpp_sym_e_3') == 'indexed_result')
check.call('an element variable assigned again in the body is not trusted (negative)',
           census.loop_element_origin(loop_lines.dup.insert(2, "    bc2cpp_sym_e_3 = mrb_nil_value();\n"), 3, 'bc2cpp_sym_e_3').nil?)
check.call('an element variable declared from something else is not classed (negative)',
           census.loop_element_origin(loop_lines.map { |l| l.sub('bc2cpp_ary_entry(M, r2, bc2cpp_sym_i_3)', 'mrb_nil_value()') }, 2, 'bc2cpp_sym_e_3').nil?)
check.call('another name is not a loop element (negative)', census.loop_element_origin(loop_lines, 2, 'x').nil?)

abort("bc2cpp_origin_may_sets_check FAILED: #{failures.join(', ')}") unless failures.empty?
puts 'bc2cpp_origin_may_sets_check OK'
