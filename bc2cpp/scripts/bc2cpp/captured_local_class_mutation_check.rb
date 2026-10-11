#!/usr/bin/env ruby
# frozen_string_literal: true

# Mutation test for CAPTURED_LOCAL_CLASS (docs/adr/0308). Each mutant is a copy of tools/bc2cpp with one soundness
# condition broken; scripts/bc2cpp/captured_local_class_check.rb, run against the mutant through BC2CPP_TOOL, must FAIL
# on the check that guards that condition. A mutant that passes means the condition has no negative case.
#
# One guard has no killing world and so no mutant: the explicit nested-write test (the flow already reads such a
# register as OTHER, so it stays as defence in depth, as numeric_upvar_mask keeps it).
#
# Usage: MRBC=path/to/mrbc [BC2CPP_MRUBY_FULL=dir] ruby scripts/bc2cpp/captured_local_class_mutation_check.rb

require 'fileutils'
require 'rbconfig'
require 'tmpdir'
require_relative 'mutant_pool'

ROOT = File.expand_path('../..', __dir__)
abort 'SKIP: set MRBC' unless ENV['MRBC']

# [name, file, pattern, replacement, check label that must FAIL, needs the run half]
MUTANTS = [
  ['writes after the closure was created are not joined', 'codegen_captured_locals.rb',
   'state[index] | (@rc_writes.dig(ancestor.label, index) || 0)', 'state[index]',
   /NEG CaHolder#cap_lambda_late|every method answers what the interpreter answers/, true],
  ['the defining frame is one block too shallow', 'codegen_captured_locals.rb',
   '(level + 1).times do', 'level.times do',
   /cap_nested|cap_hash|cap_two_blocks/, false],
  ['an argument of the defining frame is taken as its literal', 'codegen_captured_locals.rb',
   'return NumericFlow::OTHER unless state', 'return NumericFlow::OTHER unless state; state = state.map { |m| m.zero? ? m : NumericFlow::HSH }',
   /NEG CaHolder#cap_arg|NEG CaHolder#cap_mixed|NEG CaHolder#cap_unknown_call/, false],
  ['the kill switch is ignored', 'codegen_captured_locals.rb',
   "ENV.fetch('BC2CPP_CAPTURED_LOCAL_CLASS', '1') != '0' && captured_local_writers_absent?", 'captured_local_writers_absent?',
   /kill switch \(BC2CPP_CAPTURED_LOCAL_CLASS=0\)/, false],
  ['a binding, eval or local_variable_set never withdraws the proof', 'codegen_captured_locals.rb',
   'return false if names.include?(sym)', 'return false if false',
   /NEG a binding|NEG a local_variable_set|NEG an eval|NEG a binding named by a symbol/, false],
  ['a string class_eval never withdraws the proof', 'codegen_captured_locals.rb',
   '&& !literal_block_argument?(irep, idx, insn)', '&& false',
   /NEG a string class_eval/, false],
  ['a native of the build that writes locals by name is ignored', 'codegen_captured_locals.rb',
   'return false if names.any? { |name| !@closed_world.native_paths_spelling(name).empty? || @closed_world.outside_ruby_token?(name) }',
   'return false if false',
   /NEG a build gem with a native|NEG a build gem whose mrblib/, false],
  ['an outside Ruby source that spells binding is ignored', 'codegen_captured_locals.rb',
   '|| @closed_world.outside_ruby_token?(name)', '',
   /NEG a build gem whose mrblib spells binding/, false]
].freeze

# nil when the mutation site is gone, else the run of the check against the mutant.
mutate = lambda do |(_name, file, pattern, replacement, expected, needs_run)|
  Dir.mktmpdir do |dir|
    # bc2cpp.rb finds the engine's gems relative to itself (../..), so the copy keeps the repository layout.
    Dir.children(ROOT).reject { |entry| %w[.git tools].include?(entry) }.each do |entry|
      FileUtils.ln_s(File.join(ROOT, entry), File.join(dir, entry))
    end
    FileUtils.mkdir_p(File.join(dir, 'tools'))
    Dir.children(File.join(ROOT, 'tools')).reject { |entry| entry == 'bc2cpp' }.each do |entry|
      FileUtils.ln_s(File.join(ROOT, 'tools', entry), File.join(dir, 'tools', entry))
    end
    FileUtils.cp_r(File.join(ROOT, 'tools/bc2cpp'), File.join(dir, 'tools'))
    path = File.join(dir, 'tools', 'bc2cpp', file)
    text = File.read(path)
    next nil unless text.include?(pattern)

    File.write(path, text.sub(pattern) { replacement })
    env = { 'BC2CPP_TOOL' => File.join(dir, 'tools', 'bc2cpp', 'bc2cpp.rb') }
    env['CAL_GENERATED_ONLY'] = '1' unless needs_run
    # Stops at the first FAIL line the mutant is expected to cause (Bc2cppMutantPool.run).
    Bc2cppMutantPool.run(env, [RbConfig.ruby, File.join(ROOT, 'scripts/bc2cpp/captured_local_class_check.rb')],
                         stop_on: /^\s+FAIL .*(?:#{expected.source})/)
  end
end

failures = []
Bc2cppMutantPool.each_ordered(MUTANTS, work: mutate) do |(name, file, _pattern, _replacement, expected), run|
  if run.nil?
    puts "  FAIL #{name}: the mutation site is gone from #{file}"
    failures << name
    next
  end
  failed_lines = run.out.lines.grep(/^\s+FAIL /)
  killed = !run.success && failed_lines.any? { |l| l.match?(expected) }
  puts "  #{killed ? 'ok  ' : 'FAIL'} mutant killed: #{name}"
  unless killed
    puts failed_lines.first(5).join
    failures << name
  end
end

if failures.empty?
  puts 'bc2cpp captured local class mutation check: PASS'
else
  warn "bc2cpp captured local class mutation check: #{failures.size} surviving mutant(s)"
  exit 1
end
