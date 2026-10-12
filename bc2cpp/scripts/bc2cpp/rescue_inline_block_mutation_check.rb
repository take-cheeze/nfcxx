#!/usr/bin/env ruby
# frozen_string_literal: true

# Mutants for scripts/bc2cpp/rescue_inline_block_check.rb (ADR 0376). Each one weakens a condition the
# inlining of a protected block loop needs and must be caught by the check's generated-code assertions
# (CC_GENERATED_ONLY=1: no compiler runs); the controls must pass. A mutant may carry several edits, since
# two layers refuse a method return (the recognizer-side test and the scan of the emitted glue): each layer
# is weakened alone (the other must still hold, so the check passes) and both together (it must fail).
require 'fileutils'
require 'rbconfig'
require 'tmpdir'
require_relative 'mutant_pool'
ROOT = File.expand_path('../..', __dir__)
abort 'SKIP: set MRBC' unless ENV['MRBC']

RESCUE = 'codegen_rescue.rb'
METHOD = 'codegen_method.rb'
REGIONS = 'codegen_loop_regions.rb'
INLINE = 'codegen_loop_inline.rb'

RETURN_BLK_TEST = [RESCUE, "block_irep.nil? || !irep_tree_has_op?(block_irep, 'RETURN_BLK')", 'true'].freeze
RETURN_SCAN = [RESCUE, "return false if text.match?(/\\breturn\\b/)", 'nil'].freeze

# [name, edits ([file, pattern, replacement]...), env, expect]: expect is :caught or :passes.
MUTANTS = [
  ['control', [], {}, :passes],
  ['switch off control', [], { 'BC2CPP_RESCUE_INLINE_BLOCKS' => '0' }, :caught],
  # The try body runs no inliner pass: the protected loops go back to block calls.
  ['no passes in the try body', [[RESCUE, 'if inline_mand && !@resumable && rescue_inline_blocks_enabled?', 'if false']], {}, :caught],
  # The kill switch is not read.
  ['kill switch ignored', [[RESCUE, "ENV['BC2CPP_RESCUE_INLINE_BLOCKS'] != '0'", 'true']], { 'BC2CPP_RESCUE_INLINE_BLOCKS' => '0' }, :caught],
  # A block body's own rescue (emit_rescue_try_body for a block irep) gets the passes, where the register
  # model of a method does not hold: the flag that only compile_method sets is ignored.
  ['passes run for any irep', [[RESCUE, 'if inline_mand && !@resumable && rescue_inline_blocks_enabled?', 'if !@resumable && rescue_inline_blocks_enabled?']],
   {}, :compile_error],
  # A return from the method through the try function: either layer alone is covered by the other...
  ['return refusal: recognizer layer only dropped', [RETURN_BLK_TEST], {}, :passes],
  ['return refusal: glue scan only dropped', [RETURN_SCAN], {}, :passes],
  # ...both gone, the loop with `return x * 10` is inlined and its `return` leaves the try function.
  ['return refusal: both layers dropped', [RETURN_BLK_TEST, RETURN_SCAN], {}, :caught],
  # Only the block's own instructions are scanned for RETURN_BLK, not its nested blocks: the nested-block pass
  # of the inliner refuses a RETURN_BLK itself, so the check still passes (a second layer, as above).
  ['return refusal: nested blocks not scanned',
   [[RESCUE, "return true if BytecodeIR.for(irep).op?(op)\n\n    (irep.reps || []).any? do |label|\n      child = @ireps[label]\n      child && irep_tree_has_op?(child, op)\n    end",
     'return BytecodeIR.for(irep).op?(op)']], {}, :passes],
  # The range filter is gone: the recognizers see the whole method, so the try function would emit (and
  # claim the nested block functions of) a loop after the rescue as well.
  ['range filter dropped', [[RESCUE, 'return false unless range.cover?(anchor) && range.cover?(sendb) && anchor < range.end && sendb < range.end',
                             'return false unless anchor && sendb']], {}, :caught],
  # The spread: a row is not spread (only the first parameter binds), every parameter is bound from index 0,
  # a non-Array element binds nothing, the length test is gone, and the arity gate admits one parameter too many.
  ['spread binds only the first parameter',
   [[INLINE, 'n.times do |k|', 'n.clamp(0, 1).times do |k|']], {}, :caught],
  ['spread index stuck at zero',
   [[INLINE, "RARRAY_PTR(\#{row})[\#{k}]; }", "RARRAY_PTR(\#{row})[0]; }"]], {}, :caught],
  ['spread length test dropped',
   [[INLINE, "if (RARRAY_LEN(\#{row}) > \#{k}) { r\#{first_reg + k} = ", "{ r\#{first_reg + k} = "]], {}, :caught],
  ['spread by #to_ary',
   [[INLINE, "if (mrb_array_p(\#{row})) {", "if (mrb_array_p(mrb_check_array_type(M, \#{row}))) { // to_ary"]], {}, :caught],
  ['non-Array element dropped',
   [[INLINE, "out << \"        r\#{first_reg} = \#{row};\\n\"", "out << \"        \\n\""]], {}, :caught],
  ['arity gate admits any arity',
   [[REGIONS, 'arity.between?(2, EACH_SPREAD_MAX) && each_spread_enabled?', 'arity >= 2']], {}, :caught],
  ['spread switch ignored', [[REGIONS, "ENV['BC2CPP_EACH_SPREAD'] != '0'", 'true']], { 'BC2CPP_EACH_SPREAD' => '0' }, :caught]
].freeze

work = lambda do |(_name, edits, extra, _expect)|
  Dir.mktmpdir('rescue-inline-mutant') do |dir|
    FileUtils.cp_r(File.join(ROOT, 'tools'), dir)
    edits.each do |file, pattern, replacement|
      path = File.join(dir, 'tools/bc2cpp', file)
      source = File.read(path)
      File.write(path, source.sub(pattern) { replacement })
    end

    env = { 'BC2CPP_TOOL' => File.join(dir, 'tools/bc2cpp/bc2cpp.rb'), 'CC_GENERATED_ONLY' => '1' }.merge(extra)
    Bc2cppMutantPool.run(env, [RbConfig.ruby, File.join(ROOT, 'scripts/bc2cpp/rescue_inline_block_check.rb')])
  end
end

# A mutant's pattern must still be in the source: a rewritten line would turn the mutant into a no-op
# that "passes" for the wrong reason.
MUTANTS.each do |name, edits, _extra, _expect|
  edits.each do |file, pattern, _replacement|
    next if File.read(File.join(ROOT, 'tools/bc2cpp', file)).include?(pattern)

    abort "mutant #{name.inspect}: #{pattern.inspect} is no longer in #{file}"
  end
end

failures = []
Bc2cppMutantPool.each_ordered(MUTANTS, work: work) do |(name, _edits, _extra, expect), run|
  failed_check = run && run.out.match?(/^\s+FAIL /)
  ok = case expect
       when :passes then run&.success
       when :compile_error then run && !run.success
       else failed_check
       end
  puts "  #{ok ? 'ok  ' : 'FAIL'} mutant: #{name}"
  failures << name unless ok
  warn run&.out unless ok
end
abort "FAILED: #{failures.join(', ')}" unless failures.empty?
puts 'bc2cpp rescue inline-block mutation check: PASS'
