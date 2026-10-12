#!/usr/bin/env ruby
# frozen_string_literal: true

# Mutants for scripts/bc2cpp/array_new_block_check.rb and scripts/bc2cpp/profiler_scope_check.rb (ADR 0391). Each one
# weakens one condition of an inlining and must be caught by that check's generated-code assertions
# (CC_GENERATED_ONLY / PSC_GENERATED_ONLY: no compiler runs); the controls must pass. A mutant that a second layer
# still covers is marked :passes and says which layer.
require 'fileutils'
require 'rbconfig'
require 'tmpdir'
require_relative 'mutant_pool'
ROOT = File.expand_path('../..', __dir__)
abort 'SKIP: set MRBC' unless ENV['MRBC']

ARR = 'codegen_array_new_inline.rb'
METHOD = 'codegen_method.rb'
PROF = 'codegen_profiler_results.rb'
INLINE = 'codegen_loop_inline.rb'
ANALYSIS = 'codegen_return_analysis.rb'
ARRAY_CHECK = 'scripts/bc2cpp/array_new_block_check.rb'
PROF_CHECK = 'scripts/bc2cpp/profiler_scope_check.rb'

# [name, check, edits ([file, pattern, replacement]...), env, expect]: expect is :caught or :passes.
MUTANTS = [
  ['array: control', ARRAY_CHECK, [], {}, :passes],
  ['array: switch off control', ARRAY_CHECK, [], { 'BC2CPP_ARRAY_NEW_INLINE' => '0' }, :caught],
  ['array: kill switch ignored', ARRAY_CHECK, [[ARR, "ENV['BC2CPP_ARRAY_NEW_INLINE'] != '0'", 'true']], { 'BC2CPP_ARRAY_NEW_INLINE' => '0' }, :caught],
  # Receiver: any `new` with one argument and a block is taken for Array.new.
  ['array: receiver not proved to be the constant', ARRAY_CHECK,
   [[ARR, "straight_line_constant_name(irep, idx, insn.reg, skip_blocks: true) == 'Array'", "insn.sym == 'new'"]], {}, :caught],
  # A class named Array nested in a module is not the top-level one.
  ['array: lexically nested Array accepted', ARRAY_CHECK,
   [[ARR, "return 'receiver_not_toplevel_array' unless resolve_class_constant_name('Array', owner_name) == 'Array'", '']], {}, :caught],
  ['array: constant rebinding ignored', ARRAY_CHECK,
   [[ARR, "return 'array_constant_unstable' unless @closed_world.stable_constant_identity?('Array')", '']], {}, :caught],
  ['array: construction proof dropped', ARRAY_CHECK,
   [[ARR, "return 'construction_replaceable' unless array_new_construction_unreplaced?", '']], {}, :caught],
  ['array: Object.new override ignored', ARRAY_CHECK,
   [[ARR, "return false unless @closed_world.standard_constructor_lookup? && exact_constructor_chain?('Array')", ''],
    [ARR, "ARRAY_NEW_CHAIN_OWNERS.any? { |owner| [owner, \"\#{owner}.singleton\"].include?(definition.owner) }", 'false']], {}, :caught],
  # The registry scan over the chain owners is a layer of its own: exact_constructor_chain? does not reach Object's singleton.
  ['array: chain-owner scan dropped', ARRAY_CHECK,
   [[ARR, "ARRAY_NEW_CHAIN_OWNERS.any? { |owner| [owner, \"\#{owner}.singleton\"].include?(definition.owner) }", 'false']], {}, :caught],
  ['array: outside definer ignored', ARRAY_CHECK,
   [[ARR, "if @closed_world.global_refusal || !@closed_world.core_native_arm_safe?('initialize', 'Array')", 'if false']], {}, :caught],
  ['array: prepend on Array ignored', ARRAY_CHECK,
   [[ARR, "return 'initialize_array_mixin' unless Array(@prepended_modules['Array']).empty? && !@unknown_mixins.include?('Array')", '']], {}, :caught],
  ['array: runtime installer ignored', ARRAY_CHECK,
   [[ARR, "return 'initialize_installed' if installed.nil? || installed.include?('initialize')", '']], {}, :caught],
  ['array: reopened Array#initialize ignored', ARRAY_CHECK,
   [[ARR, "return 'initialize_defined_on_array' if definitions.any? { |definition| definition.owner == 'Array' }", '']], {}, :caught],
  ['array: native spelling Array ignored', ARRAY_CHECK,
   [[ARR, '/array_class|"Array"|MRB_SYM\(Array\)/', '/NEVER_MATCHES_ANYTHING_HERE/']], {}, :caught],
  # An alias_method counts only the name it installs (the control above has an alias_method that copies initialize).
  ['array: alias_method source counted as installed', ARRAY_CHECK,
   [[ANALYSIS, "syms = syms.first(1) if destinations_only && insn.sym == 'alias_method'", '']], {}, :caught],
  ['array: block arity gate dropped', ARRAY_CHECK,
   [[ARR, "return 'block_arity' unless [0, 1].include?(mandatory_arity(block_irep)) && pure_mandatory_arity?(block_irep)", '']], {}, :caught],
  ['array: frame block read through the block accepted', ARRAY_CHECK,
   [[ARR, "return 'block_forwards_frame_block' unless block_blk_needs(block_irep) == []", '']], {}, :caught],
  ['array: size not converted by mrb_as_int', ARRAY_CHECK,
   [[ARR, 'mrb_as_int(M, r#{size_reg})', 'mrb_integer(r#{size_reg})']], {}, :caught],
  ['array: negative size allocates', ARRAY_CHECK,
   [[ARR, ' > 0 ? bc2cpp_anew_n_#{addr} : 0', '']], {}, :caught],
  ['array: index not bound', ARRAY_CHECK, [[ARR, 'bind_index: mandatory_arity(block_irep) == 1', 'bind_index: false']], {}, :caught],
  ['array: break does not skip the array assignment', ARRAY_CHECK,
   [[ARR, 'if (!#{broke}) r#{dest_reg} =', 'r#{dest_reg} =']], {}, :caught],

  ['profiler: control', PROF_CHECK, [], {}, :passes],
  ['profiler: rescue switch off control', PROF_CHECK, [], { 'BC2CPP_RESCUE_PROFILER_INLINE' => '0' }, :caught],
  ['profiler: rescue pass never runs', PROF_CHECK,
   [[METHOD, "recognize == :recognize_profiler_section_regions && ENV['BC2CPP_RESCUE_PROFILER_INLINE'] != '0'", 'false']], {}, :caught],
  ['profiler: rescue kill switch ignored', PROF_CHECK,
   [[METHOD, "ENV['BC2CPP_RESCUE_PROFILER_INLINE'] != '0'", 'true']], { 'BC2CPP_RESCUE_PROFILER_INLINE' => '0' }, :caught],
  ['profiler: scoped switch off control', PROF_CHECK, [], { 'BC2CPP_PROFILER_NAME_SCOPED' => '0' }, :caught],
  ['profiler: scoped kill switch ignored', PROF_CHECK,
   [[PROF, "ENV['BC2CPP_PROFILER_NAME_SCOPED'] == '0'", 'false']], { 'BC2CPP_PROFILER_NAME_SCOPED' => '0' }, :caught],
  ['profiler: definitions on the module ignored', PROF_CHECK,
   [[PROF, 'definitions.none? { |definition| profiler_owner?(definition.owner) }', 'true']], {}, :caught],
  ['profiler: module owner spelled only qualified', PROF_CHECK,
   [[PROF, "owner.to_s.delete_suffix('.singleton').split('::').last == 'Profiler'", "owner.to_s.delete_suffix('.singleton') == 'RGSS::Profiler'"]], {}, :caught],
  ['profiler: nested section function name not unique', PROF_CHECK,
   [[INLINE, '#{reg_offset ? "_in_#{irep.label}" : \'\'}', '']], {}, :caught]
].freeze

work = lambda do |(_name, check, edits, extra, _expect)|
  Dir.mktmpdir('block-direct-mutant') do |dir|
    FileUtils.cp_r(File.join(ROOT, 'tools'), dir)
    edits.each do |file, pattern, replacement|
      path = File.join(dir, 'tools/bc2cpp', file)
      source = File.read(path)
      File.write(path, source.sub(pattern) { replacement })
    end

    env = { 'BC2CPP_TOOL' => File.join(dir, 'tools/bc2cpp/bc2cpp.rb'), 'CC_GENERATED_ONLY' => '1', 'PSC_GENERATED_ONLY' => '1' }.merge(extra)
    Bc2cppMutantPool.run(env, [RbConfig.ruby, File.join(ROOT, check)])
  end
end

# A mutant's pattern must still be in the source: a rewritten line would turn the mutant into a no-op
# that "passes" for the wrong reason.
MUTANTS.each do |name, _check, edits, _extra, _expect|
  edits.each do |file, pattern, _replacement|
    next if File.read(File.join(ROOT, 'tools/bc2cpp', file)).include?(pattern)

    abort "mutant #{name.inspect}: #{pattern.inspect} is no longer in #{file}"
  end
end

failures = []
Bc2cppMutantPool.each_ordered(MUTANTS, work: work) do |(name, _check, _edits, _extra, expect), run|
  failed_check = run && run.out.match?(/^\s+FAIL /)
  ok = expect == :passes ? run&.success : failed_check
  puts "  #{ok ? 'ok  ' : 'FAIL'} mutant: #{name}"
  failures << name unless ok
  warn run&.out unless ok
end
abort "FAILED: #{failures.join(', ')}" unless failures.empty?
puts 'bc2cpp block-direct mutation check: PASS'
