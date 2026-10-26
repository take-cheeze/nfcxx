#!/usr/bin/env ruby
# frozen_string_literal: true

# FREEZE_SLOT: a slot of a frozen literal table whose value is `LITERAL.freeze` has the
# container class of that literal (ARR for an Array, HSH for a Hash), not OTHER.
#
# 1. Host (CRuby): hand-built bytecode with the register layout mrbc emits for `T = [[1, 2].freeze, 3].freeze`
#    and its siblings. CodeGen#frozen_table_literal_shape is asked for the outer table's slot classes with the
#    kill switch on and off, and with the Array/Hash `freeze` names refused.
# 2. Compiled (MRBC): the same fixtures compiled by mrbc and decoded with the real irep loader.
#
# Every refusal (not adjacent to its literal, a `dup`, a second freeze, a call result, a refused name) keeps
# OTHER, and a refused name on the outer container proves no table at all.
#
# Usage: ruby scripts/bc2cpp/frozen_slot_check.rb            (host section)
#        MRBC=path/to/mrbc ruby scripts/bc2cpp/frozen_slot_check.rb   (adds the compiled section)

require 'set'
require 'tmpdir'
require_relative '../../tools/bc2cpp/irep'
require_relative '../../tools/bc2cpp/bytecode_ir'
require_relative '../../tools/bc2cpp/numeric_flow'
require_relative '../../tools/bc2cpp/frozen_tables'
require_relative '../../tools/bc2cpp/codegen_frozen_tables'

failures = []
check = lambda do |what, condition|
  puts "  #{condition ? 'ok  ' : 'FAIL'} #{what}"
  failures << what unless condition
end

NF = NumericFlow
INT = NF::INT
STR = NF::STR
ARR = NF::ARR
HSH = NF::HSH
OTHER = NF::OTHER

# A CodeGen with only the state the slot classifier reads.
def codegen(array_freeze_safe: true, hash_freeze_safe: true)
  cg = CodeGen.allocate
  cg.instance_variable_set(:@frozen_table_name_safe,
                           { ['freeze', 'Array'] => array_freeze_safe, ['freeze', 'Hash'] => hash_freeze_safe })
  cg.instance_variable_set(:@integer_constants, nil)
  cg
end

# Container and slot classes of the outer table of +irep+ (its last `freeze`), or nil.
def outer_table(cg, irep)
  site = irep.instructions.each_index.select { |idx| irep.instructions[idx].op == :SEND0 && irep.instructions[idx].sym == 'freeze' }.last
  return nil unless site

  shape = cg.send(:frozen_table_literal_shape, irep, site, irep.instructions[site], FrozenTables::Registry.new)
  shape && [shape.container, shape.slots]
end

def with_switch(value)
  saved = ENV.fetch('BC2CPP_FREEZE_SLOT', nil)
  value.nil? ? ENV.delete('BC2CPP_FREEZE_SLOT') : ENV['BC2CPP_FREEZE_SLOT'] = value
  yield
ensure
  saved.nil? ? ENV.delete('BC2CPP_FREEZE_SLOT') : ENV['BC2CPP_FREEZE_SLOT'] = saved
end

def irep_of(rows)
  irep = Irep.new(label: 'slot', nregs: 8, nlocals: 1)
  irep.instructions = rows.each_with_index.map do |(op, args), address|
    Insn.new(lineno: 1, addr: address, op: op, args: args, raw: "#{op} #{args}")
  end
  irep
end

# `T = [[1, 2].freeze, 3].freeze` as mrbc emits it.
NESTED = [
  [:LOADI_1, 'R1 (1)'], [:LOADI_2, 'R2 (2)'], [:ARRAY, 'R1 2'], [:SEND0, 'R1 :freeze'],
  [:LOADI_3, 'R2 (3)'], [:ARRAY, 'R1 2'], [:SEND0, 'R1 :freeze'], [:RETURN, 'R1']
].freeze
# `T = [[1, 2].dup, 3].freeze`: dup, not freeze.
DUP = NESTED.dup.tap { |rows| rows[3] = [:SEND0, 'R1 :dup'] }.freeze
# `T = [[1, 2].freeze.freeze, 3].freeze`: the second freeze's receiver is a call, not the literal.
DOUBLE = [*NESTED.take(4), [:SEND0, 'R1 :freeze'], *NESTED.drop(4)].freeze
# `T = { 8 => [1, 2].freeze }.freeze` (a Hash whose value is a frozen Array literal).
HASH_OF_ARRAY = [
  [:LOADI8, 'R1 8'], [:LOADI_1, 'R2 (1)'], [:LOADI_2, 'R3 (2)'], [:ARRAY, 'R2 2'], [:SEND0, 'R2 :freeze'],
  [:HASH, 'R1 1'], [:SEND0, 'R1 :freeze'], [:RETURN, 'R1']
].freeze
# `T = [[1, 2].freeze, 3].freeze` with the literal not adjacent to its freeze: a statement between them.
GAP = [
  [:LOADI_1, 'R1 (1)'], [:LOADI_2, 'R2 (2)'], [:ARRAY, 'R1 2'], [:MOVE, 'R3 R1'], [:SEND0, 'R1 :freeze'],
  [:LOADI_3, 'R2 (3)'], [:ARRAY, 'R1 2'], [:SEND0, 'R1 :freeze'], [:RETURN, 'R1']
].freeze

puts '-- host: the slot of a frozen literal table that is itself `LITERAL.freeze` (FREEZE_SLOT)'
cases = {
  'nested frozen Array' => [NESTED, [ARR, INT], [OTHER, INT]],
  'dup, not freeze' => [DUP, [OTHER, INT], [OTHER, INT]],
  'second freeze of a freeze' => [DOUBLE, [OTHER, INT], [OTHER, INT]],
  'freeze not adjacent to its literal' => [GAP, [OTHER, INT], [OTHER, INT]]
}
cases.each do |what, (rows, on, off)|
  irep = irep_of(rows)
  with_switch(nil) { check.call("#{what}: switch on -> #{on.inspect}", outer_table(codegen, irep)&.last == on) }
  with_switch('0') { check.call("#{what}: BC2CPP_FREEZE_SLOT=0 -> #{off.inspect}", outer_table(codegen, irep)&.last == off) }
end
with_switch(nil) do
  irep = irep_of(HASH_OF_ARRAY)
  check.call('a Hash slot holding a frozen Array literal: switch on -> [ARR]', outer_table(codegen, irep) == [:hash, [ARR]])
  with_switch('0') { check.call('the same with BC2CPP_FREEZE_SLOT=0 -> [OTHER]', outer_table(codegen, irep) == [:hash, [OTHER]]) }
end

puts '-- host: a refused freeze name'
with_switch(nil) do
  check.call('Array#freeze may be overridden: the outer Array proves no table',
             outer_table(codegen(array_freeze_safe: false), irep_of(NESTED)).nil?)
  check.call('only Array#freeze refused: a Hash of a refused inner literal keeps its slot OTHER',
             outer_table(codegen(array_freeze_safe: false), irep_of(HASH_OF_ARRAY)) == [:hash, [OTHER]])
  check.call('Hash#freeze refused: the outer Hash proves no table',
             outer_table(codegen(hash_freeze_safe: false), irep_of(HASH_OF_ARRAY)).nil?)
end

if ENV['MRBC']
  puts '-- compiled (MRBC): the same shapes from mrbc output'
  FIXTURES = {
    'T = [[1, 2].freeze, 3].freeze' => [ARR, INT],
    'T = [{ 8 => 1 }.freeze, "s"].freeze' => [HSH, STR],
    'T = [[].freeze].freeze' => [ARR],
    'T = [[1].freeze, [2, 3].freeze].freeze' => [ARR, ARR],
    'T = [[1, 2].dup, 3].freeze' => [OTHER, INT],
    'x = [1, 2]; x.push(9); T = [x.freeze, 3].freeze' => [OTHER, INT],
    'T = [foo.freeze, 3].freeze' => [OTHER, INT]
  }.freeze
  Dir.mktmpdir('frozen-slot') do |dir|
    FIXTURES.each_with_index do |(source, slots), n|
      src = File.join(dir, "case#{n}.rb")
      File.write(src, "#{source}\n")
      ireps, root = compile_ireps([src], "case#{n}", dir)
      with_switch(nil) { check.call("#{source}: switch on -> #{slots.inspect}", outer_table(codegen, ireps.fetch(root))&.last == slots) }
      with_switch('0') do
        off = slots.map { |s| s == ARR || s == HSH ? OTHER : s }
        check.call("#{source}: BC2CPP_FREEZE_SLOT=0", outer_table(codegen, ireps.fetch(root))&.last == off)
      end
    end
  end
end

abort "FAILED: #{failures.join(', ')}" unless failures.empty?
puts 'bc2cpp frozen slot check: PASS'
