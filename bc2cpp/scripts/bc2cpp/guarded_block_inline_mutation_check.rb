#!/usr/bin/env ruby
# frozen_string_literal: true

# Mutants for scripts/bc2cpp/guarded_block_inline_check.rb (ADR 0420). Each one weakens one condition of the guarded
# block loops and must be caught by that check's generated-code assertions (GB_GENERATED_ONLY: no compiler runs);
# the controls must pass.
require 'fileutils'
require 'rbconfig'
require 'tmpdir'
require_relative 'mutant_pool'
ROOT = File.expand_path('../..', __dir__)
abort 'SKIP: set MRBC' unless ENV['MRBC']

GUARD = 'codegen_guarded_block_inline.rb'
METHOD = 'codegen_method.rb'
REGIONS = 'codegen_loop_regions.rb'
INLINE = 'codegen_loop_inline.rb'
CHECK = 'scripts/bc2cpp/guarded_block_inline_check.rb'

# [name, edits ([file, pattern, replacement]...), env, expect]: expect is :caught or :passes.
MUTANTS = [
  ['control', [], {}, :passes],
  ['switch off control', [], { 'BC2CPP_GUARDED_BLOCK_INLINE' => '0' }, :caught],
  ['kill switch ignored', [[GUARD, "ENV['BC2CPP_GUARDED_BLOCK_INLINE'] != '0'", 'true']], { 'BC2CPP_GUARDED_BLOCK_INLINE' => '0' }, :caught],
  # The arm gate is the proof that no definition, prepend, outside definer or installer answers the name on the class.
  ['arm gate dropped', [[GUARD, 'argc && guarded_inline_arm?(insn.sym, argc, pending[:klass]) &&', 'argc &&']], {}, :caught],
  ['arm gate asks for any class', [[GUARD, 'arms.any? { |arm| arm[:class] == klass }', 'arms.any?']], {}, :caught],
  ['arms switch ignored', [[GUARD, 'block_core_direct_enabled? && block_core_world', 'block_core_world']], { 'BC2CPP_BLOCK_CORE_DIRECT' => '0' }, :caught],
  ['root-context test dropped', [[GUARD, 'if (M->c == M->root_c && #{test})', 'if (#{test})']], {}, :caught],
  ['exact Array class test is only the type test', [[GUARD, " && mrb_obj_ptr(%<r>s)->c == M->array_class'", "'"]], {}, :caught],
  ['exact Hash class test is only the type test', [[GUARD, " && mrb_obj_ptr(%<r>s)->c == M->hash_class'", "'"]], {}, :caught],
  ['no label after the send', [[GUARD, "after_at[after.addr] = \"  \#{label}:;\\n\"", '']], {}, :caught],
  # Equivalent where the block fallback owns the send: its glue holds the dispatch and the SENDB itself is suppressed, so
  # a label on the send lands after the same code. The control marks that it is not a missing assertion.
  ['label on the send itself (equivalent under the block fallback)', [[GUARD, 'after = irep.instructions[send_idx + 1]', 'after = irep.instructions[send_idx]']], {}, :passes],
  ['the loop does not jump over the send', [[GUARD, '    goto #{label};\n  }\n"', '  }\n"']], {}, :caught],
  ['a rest-parameter Array is guarded instead of proven', [[REGIONS, 'return true if traced == klass', 'return guarded_inline_receiver?(insn, klass) if traced == klass']], {}, :caught],
  ['second loop shares the first loop labels', [[METHOD, 'region[:label_tag] = guarded_klass ? "_#{guarded_klass[0]}" : nil', 'region[:label_tag] = nil']], {}, :caught],
  ['each_with_index break flag not declared', [[INLINE, "if meth != 'each_with_index' || body.include?(\"bc2cpp_collect_broke_\#{addr}\")", "if meth != 'each_with_index'"]], {}, :caught],
  ['Hash loop never asked for', [[GUARD, "return false unless guarded_inline_sites? && GUARDED_INLINE_TESTS.key?(klass)", "return false unless guarded_inline_sites? && klass == 'Array'"]], {}, :caught]
].freeze

work = lambda do |(_name, edits, extra, _expect)|
  Dir.mktmpdir('guarded-inline-mutant') do |dir|
    FileUtils.cp_r(File.join(ROOT, 'tools'), dir)
    edits.each do |file, pattern, replacement|
      path = File.join(dir, 'tools/bc2cpp', file)
      File.write(path, File.read(path).sub(pattern) { replacement })
    end
    env = { 'BC2CPP_TOOL' => File.join(dir, 'tools/bc2cpp/bc2cpp.rb'), 'GB_GENERATED_ONLY' => '1' }.merge(extra)
    Bc2cppMutantPool.run(env, [RbConfig.ruby, File.join(ROOT, CHECK)])
  end
end

# A mutant's pattern must still be in the source: a rewritten line would turn the mutant into a no-op.
MUTANTS.each do |name, edits, _extra, _expect|
  edits.each do |file, pattern, _replacement|
    next if File.read(File.join(ROOT, 'tools/bc2cpp', file)).include?(pattern)

    abort "mutant #{name.inspect}: #{pattern.inspect} is no longer in #{file}"
  end
end

failures = []
Bc2cppMutantPool.each_ordered(MUTANTS, work: work) do |(name, _edits, _extra, expect), run|
  failed_check = run && run.out.match?(/^\s+FAIL /)
  ok = expect == :passes ? run&.success : failed_check
  puts "  #{ok ? 'ok  ' : 'FAIL'} mutant: #{name}"
  failures << name unless ok
  warn run&.out unless ok
end
abort "FAILED: #{failures.join(', ')}" unless failures.empty?
puts 'bc2cpp guarded block inline mutation check: PASS'
