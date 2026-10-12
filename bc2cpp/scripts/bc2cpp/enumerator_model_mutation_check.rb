#!/usr/bin/env ruby
# frozen_string_literal: true

# Mutation check of scripts/bc2cpp/enumerator_model_check.rb (docs/adr/0418): each mutant removes one soundness condition of
# the Enumerator model from a copy of tools/bc2cpp and the check must report a FAIL; the control must pass. Each mutant
# runs only the phase / generated worlds it can change (EM_PHASE, EM_GEN), so the full-core fixture is not rebuilt for it.

require 'fileutils'
require 'rbconfig'
require 'tmpdir'
require_relative 'mutant_pool'

ROOT = File.expand_path('../..', __dir__)
abort 'SKIP: set MRBC' unless ENV['MRBC']

# [name, file, pattern, replacement, env]
MUTANTS = [
  ['control', nil, nil, nil, { 'EM_PHASE' => 'unit' }],
  # EnumeratorModel.analyze
  ['switch ignored', 'enumerator_model.rb', "if ENV['BC2CPP_ENUMERATOR_MODEL'] == '0'\n", "if false\n", { 'EM_PHASE' => 'unit' }],
  ['owner gate omitted', 'enumerator_model.rb', "unless definition.owner == 'Kernel' && definition.irep", 'unless definition.irep', { 'EM_PHASE' => 'unit' }],
  ['source gate omitted', 'enumerator_model.rb', 'unless body && body.file.to_s.end_with?(FILE_SUFFIX)', 'unless body', { 'EM_PHASE' => 'unit' }],
  ['uniqueness omitted', 'enumerator_model.rb', 'unless to_enum_defs.size == 1', 'unless true', { 'EM_PHASE' => 'unit' }],
  ['body gate omitted', 'enumerator_model.rb', 'unless to_enum_body?(body, ireps)', 'unless true', { 'EM_PHASE' => 'unit' }],
  ['enum_for gate omitted', 'enumerator_model.rb', 'unless enum_for.empty?', 'unless true', { 'EM_PHASE' => 'unit' }],
  ['alias gate omitted', 'enumerator_model.rb', "return Result.new(false, 'to_enum/enum_for are aliased elsewhere')", 'nil', { 'EM_PHASE' => 'unit' }],
  ['construction chain omitted', 'enumerator_model.rb', 'next unless CONSTRUCTION_OWNERS.include?(other.owner)', 'next', { 'EM_PHASE' => 'unit' }],
  ['body op list widened', 'enumerator_model.rb', 'return false unless body.reps.empty? && body.instructions.all? { |i| BODY_OPS.include?(i.op) }', 'return false unless body.reps.empty?', { 'EM_PHASE' => 'unit' }],
  # the constant
  ['nested statement allowed', 'enumerator_model.rb', "if insn.sym_token == 'Enumerator' && irep.label != root_label", 'if false', { 'EM_PHASE' => 'unit' }],
  ['assignment allowed', 'enumerator_model.rb', "return \"assigned in \#{irep.file}\" if insn.const_name == 'Enumerator'", 'nil', { 'EM_PHASE' => 'unit' }],
  ['const_set allowed', 'enumerator_model.rb', 'if insn.sym.to_s.match?(StableClassConstants::DYNAMIC_MUTATION)', 'if false', { 'EM_PHASE' => 'unit' }],
  ['outside const_set allowed', 'enumerator_model.rb', 'if text.match?(StableClassConstants::DYNAMIC_MUTATION)', 'if false', { 'EM_PHASE' => 'unit' }],
  ['outside reassignment allowed', 'enumerator_model.rb', "if StableClassConstants.foreign_reassigned_names(foreign_paths).include?('Enumerator')", 'if false', { 'EM_PHASE' => 'unit' }],
  # ClassLayout
  ['ivar receiver not traced', 'class_layout.rb', 'array_ret_proof, receiver_class: receiver_class)', 'array_ret_proof)', { 'EM_PHASE' => 'unit' }],
  ['any receiver accepted', 'class_layout.rb', "next 'Array' if called == 'map' || traced == 'Array'", "next 'Array'", { 'EM_PHASE' => 'unit' }],
  # code generation
  ['arm unchecked', 'codegen_core_exact_direct.rb', '-- proven #{site[:klass]} receiver: builds', '-- #{site[:klass]} receiver: builds', { 'EM_PHASE' => 'positive' }],
  ['arguments dropped', 'codegen_core_exact_direct.rb', 'vector = [recv, meth, *argv.drop(1)]', 'vector = [recv, meth]', { 'EM_PHASE' => 'positive' }],
  ['default method name dropped', 'codegen_core_exact_direct.rb', %q{meth = argv.empty? ? 'mrb_symbol_value(mrb_intern_lit(M, "each"))' : argv.first}, 'meth = argv.first || "mrb_nil_value()"', { 'EM_PHASE' => 'positive' }],
  ['helper builds another class', 'codegen_core_exact_direct.rb', 'mrb_class_get(M, "Enumerator")', 'mrb_class_get(M, "Array")', { 'EM_PHASE' => 'positive' }],
  ['model ignored', 'codegen_core_exact_direct.rb', 'return nil unless model&.to_enum_direct && ', 'return nil unless ', { 'EM_PHASE' => 'generated', 'EM_GEN' => 'redef' }],
  ['constant stability ignored', 'codegen_core_exact_direct.rb', 'return nil unless model.constant_stable', 'nil', { 'EM_PHASE' => 'generated', 'EM_GEN' => 'nested' }],
  ['installer names ignored', 'codegen_core_exact_direct.rb', 'return nil unless installed && (EnumeratorModel::NAMES + EnumeratorModel::CONSTRUCTION_NAMES).none? { |n| installed.include?(n) }', 'nil', { 'EM_PHASE' => 'generated', 'EM_GEN' => 'installer' }]
].freeze

work = lambda do |(_name, file, pattern, replacement, extra)|
  Dir.mktmpdir('enumerator-model-mutant') do |dir|
    FileUtils.cp_r(File.join(ROOT, 'tools'), dir)
    if file
      path = File.join(dir, 'tools/bc2cpp', file)
      source = File.read(path)
      next nil unless source.include?(pattern)

      File.write(path, source.sub(pattern) { replacement })
    end
    env = { 'BC2CPP_TOOL' => File.join(dir, 'tools/bc2cpp/bc2cpp.rb') }.merge(extra)
    Bc2cppMutantPool.run(env, [RbConfig.ruby, File.join(ROOT, 'scripts/bc2cpp/enumerator_model_check.rb')], stop_on: /^\s+FAIL /)
  end
end
failures = []
Bc2cppMutantPool.each_ordered(MUTANTS, work: work) do |(name, file, _pattern, _replacement, _extra), run|
  ok = run && (file ? !run.success && run.out.match?(/^\s+FAIL /) : run.success)
  puts "  #{ok ? 'ok  ' : 'FAIL'} #{name}#{run ? '' : ' (pattern not found in the generator)'}"
  failures << name unless ok
  warn run&.out unless ok
end
abort "FAILED: #{failures.join(', ')}" unless failures.empty?
puts 'bc2cpp Enumerator model mutation check: PASS'
