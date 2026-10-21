#!/usr/bin/env ruby
# frozen_string_literal: true

# ENUMERATOR_RESULT: a blockless `map`/`collect` (SEND, no block) on an exact Array or Hash receiver has the
# NumericFlow::ENUMERATOR bit, a reserved bit that names no class. The block form (SENDB) keeps its Array result.
#
# Host only (no mrbc): CodeGen#native_core_blockless_enumerator_result and native_core_class_result, driven on a
# CodeGen with a stubbed ClosedWorld and definition registry. The consumers that turn a return mask into class names
# must refuse the bit. Kill switch: BC2CPP_NATIVE_CLASS_RESULTS=0.
#
# Usage: ruby scripts/bc2cpp/enumerator_result_check.rb

require 'set'
require_relative '../../tools/bc2cpp/irep'
require_relative '../../tools/bc2cpp/bytecode_ir'
require_relative '../../tools/bc2cpp/numeric_flow'
require_relative '../../tools/bc2cpp/core_blockless_iterator_sigs'
require_relative '../../tools/bc2cpp/core_block_iterator_sigs'
require_relative '../../tools/bc2cpp/core_hierarchy_sigs'
require_relative '../../tools/bc2cpp/codegen_native_results'

failures = []
check = lambda do |what, condition|
  puts "  #{condition ? 'ok  ' : 'FAIL'} #{what}"
  failures << what unless condition
end

NF = NumericFlow
ARR = NF::ARR
HSH = NF::HSH
INT = NF::INT

# SEND0 takes no count operand; SEND carries n=0.
def insn(op, sym, reg: 1, argc: 0)
  args = op.end_with?('0') ? "R#{reg}\t:#{sym}" : "R#{reg}\t:#{sym}\tn=#{argc}"
  Insn.new(lineno: 1, addr: 0, op: op, args: args, raw: "#{op} #{args}")
end

ClosedWorldStub = Struct.new(:exact) do
  def exact_instances_singleton_free? = exact
end

# A CodeGen with the facts the hook reads. +exact+: the closed world proves exact instances; +installed+: names a
# program or installer defines; +defs+: the registry's definitions per name.
def codegen_with(exact: true, installed: Set.new, defs: {})
  cg = CodeGen.allocate
  cg.instance_variable_set(:@closed_world, ClosedWorldStub.new(exact))
  cg.instance_variable_set(:@registry, defs)
  cg.define_singleton_method(:symbol_installed_names) { installed }
  cg
end

NATIVE = Struct.new(:owner)
def native_defs(*names) = names.to_h { |n| [n, [NATIVE.new('<native>')]] }

def state_for(bit) = { 1 => bit }

puts '== reserved bit'
check.call('ENUMERATOR is the bit at ENUMERATOR_BIT = OBJECT_KIND_BASE - 2',
           NF::ENUMERATOR == 1 << NF::ENUMERATOR_BIT && NF::ENUMERATOR_BIT == NF::OBJECT_KIND_BASE - 2)
check.call('ENUMERATOR sits in CLASS_BITS and is not the CHECKED provenance bit',
           NF::CLASS_BITS.anybits?(NF::ENUMERATOR) && NF::ENUMERATOR != NF::CHECKED)
cg_alloc = CodeGen.allocate
names = (0...(NF::ENUMERATOR_BIT - NF::CLASS_BIT_BASE)).map { |i| "K#{i}" }
allocated = names.map { |n| cg_alloc.numeric_class_bit(n) }
check.call('class bits fill up to the bit below ENUMERATOR', allocated.last == 1 << (NF::ENUMERATOR_BIT - 1))
refused = begin
  cg_alloc.numeric_class_bit('Overflow')
  false
rescue RuntimeError => e
  e.message.include?('ENUMERATOR_BIT')
end
check.call('the next class bit is refused, not allocated on top of ENUMERATOR', refused)

puts '== tables'
check.call('blockless Enumerable#map and #collect read as Enumerator',
           %w[map collect].all? { |m| CoreBlocklessIteratorSigs.results.dig('Enumerable', m) == 'Enumerator' })
check.call('the block overload still reads Array (core_block_iterators)',
           %w[map collect].all? { |m| CoreBlockIteratorSigs.results.dig('Enumerable', m) == 'Array' })
check.call('a method without a blockless Enumerator is absent from the blockless table',
           CoreBlocklessIteratorSigs.results.dig('Enumerable', 'each').nil?)

puts '== codegen hook'
cg = codegen_with(defs: native_defs('map', 'collect'))
check.call('SEND map on an exact Array is ENUMERATOR',
           cg.native_core_blockless_enumerator_result(insn('SEND0', 'map'), state_for(ARR)) == NF::ENUMERATOR)
check.call('SEND map on an exact Hash is ENUMERATOR',
           cg.native_core_blockless_enumerator_result(insn('SEND', 'collect'), state_for(HSH)) == NF::ENUMERATOR)
check.call('SENDB map is not the blockless result',
           cg.native_core_blockless_enumerator_result(insn('SENDB', 'map'), state_for(ARR)).nil?)
check.call('an Integer receiver is not claimed', cg.native_core_blockless_enumerator_result(insn('SEND0', 'map'), state_for(INT)).nil?)
check.call('a name outside the table is not claimed', cg.native_core_blockless_enumerator_result(insn('SEND0', 'each'), state_for(ARR)).nil?)
check.call('an inexact receiver is not claimed',
           codegen_with(exact: false, defs: native_defs('map')).native_core_blockless_enumerator_result(insn('SEND0', 'map'), state_for(ARR)).nil?)
check.call('a program definition of map withdraws the claim',
           codegen_with(defs: { 'map' => [Struct.new(:owner).new('Bag')] }).native_core_blockless_enumerator_result(insn('SEND0', 'map'), state_for(ARR)).nil?)
check.call('an installed map withdraws the claim',
           codegen_with(installed: Set['map'], defs: native_defs('map')).native_core_blockless_enumerator_result(insn('SEND0', 'map'), state_for(ARR)).nil?)
check.call('no installer data withdraws the claim',
           codegen_with(defs: native_defs('map')).tap { |c| c.define_singleton_method(:symbol_installed_names) { nil } }
                                                 .native_core_blockless_enumerator_result(insn('SEND0', 'map'), state_for(ARR)).nil?)
ENV['BC2CPP_NATIVE_CLASS_RESULTS'] = '0'
check.call('the kill switch BC2CPP_NATIVE_CLASS_RESULTS=0 withdraws the claim',
           cg.native_core_blockless_enumerator_result(insn('SEND0', 'map'), state_for(ARR)).nil? &&
           cg.native_core_class_result(insn('SEND0', 'map'), state_for(ARR)).nil?)
ENV.delete('BC2CPP_NATIVE_CLASS_RESULTS')
check.call('native_core_class_result returns the bit for a blockless map',
           cg.native_core_class_result(insn('SEND0', 'map'), state_for(ARR)) == NF::ENUMERATOR)

check.call('every declared blockless name answers Enumerator on Enumerable',
           CoreBlocklessIteratorSigs.results['Enumerable'].values.all? { |k| k == 'Enumerator' })
check.call('find_index is not declared (its blockless call with an argument is not an Enumerator)',
           CoreBlocklessIteratorSigs.arity('Enumerable', 'find_index').nil?)
check.call('arity: each_slice takes exactly one argument', CoreBlocklessIteratorSigs.arity('Enumerable', 'each_slice') == [1, 1])
check.call('arity: each_entry takes any number', CoreBlocklessIteratorSigs.arity('Enumerable', 'each_entry') == [0, nil])
check.call('a Range receiver is claimed (Range includes Enumerable)',
           cg.native_core_blockless_enumerator_result(insn('SEND0', 'map'), state_for(NF::RNG)) == NF::ENUMERATOR)
check.call('a String receiver is refused (String does not include Enumerable)',
           cg.native_core_blockless_enumerator_result(insn('SEND0', 'map'), state_for(NF::STR)).nil?)
check.call('SEND0 each_slice (no argument) is refused: the arity needs one',
           cg.native_core_blockless_enumerator_result(insn('SEND0', 'each_slice'), state_for(ARR)).nil?)
check.call('SEND each_slice with one argument is claimed',
           cg.native_core_blockless_enumerator_result(insn('SEND', 'each_slice', argc: 1), state_for(ARR)) == NF::ENUMERATOR)
check.call('SEND map with one argument is refused (map takes none)',
           cg.native_core_blockless_enumerator_result(insn('SEND', 'map', argc: 1), state_for(ARR)).nil?)
check.call('a splat argument count is refused', cg.native_core_blockless_enumerator_result(
  Insn.new(lineno: 1, addr: 0, op: 'SEND', args: "R1\t:map\tn=*", raw: 'SEND R1 :map n=*'), state_for(ARR)).nil?)
check.call('a Hash receiver is claimed', cg.native_core_blockless_enumerator_result(insn('SEND0', 'select'), state_for(HSH)) == NF::ENUMERATOR)

puts '== consumers refuse the bit'
check.call('return_class_of_mask names no class for ENUMERATOR', cg.return_class_of_mask(NF::ENUMERATOR).nil?)
check.call('bytecode_ir_mask_classes refuses ENUMERATOR', cg.bytecode_ir_mask_classes(NF::ENUMERATOR).nil?)
check.call('bytecode_ir_mask_classes refuses ENUMERATOR joined with Array',
           cg.bytecode_ir_mask_classes(NF::ENUMERATOR | ARR).nil?)
check.call('return_class_of_mask still names Array', cg.return_class_of_mask(ARR) == 'Array')

if failures.empty?
  puts 'enumerator_result_check: ok'
else
  warn "enumerator_result_check: #{failures.size} failure(s)"
  exit 1
end
