#!/usr/bin/env ruby
# frozen_string_literal: true

# Mutation test for EXACT_NATIVE_WRAPPER (docs/adr/0307). Each mutant is a copy of tools/bc2cpp with one
# condition broken; scripts/bc2cpp/exact_native_wrappers_check.rb, run against the mutant through
# BC2CPP_TOOL, must FAIL on the check that guards that condition. A mutant that passes means the condition
# has no negative case.
#
# Usage: MRBC=path/to/mrbc [BC2CPP_MRUBY_FULL=dir] ruby scripts/bc2cpp/exact_native_wrappers_mutation_check.rb

require 'fileutils'
require 'rbconfig'
require 'tmpdir'
require_relative 'fixture_runtime'
require_relative 'mutant_pool'

ROOT = File.expand_path('../..', __dir__)
abort 'SKIP: set MRBC' unless ENV['MRBC']

# [name, file, pattern, replacement, check label that must FAIL, needs the run half]
MUTANTS = [
  ['a nil receiver is taken as exact without the nil test', 'codegen_exact_native_wrappers.rb',
   'klass = exact_flow_user_class(irep, idx, reg)',
   'klass = return_class_of_mask(exact_flow_mask(irep, idx, reg)&.then { |m| m & ~NumericFlow::NIL })',
   /nil-or-Bitmap takes one nil test|raises where the interpreter does|every method answers/, false],
  ['an argument receiver counts as exact (the hint, not the flow)', 'codegen_exact_native_wrappers.rb',
   'klass = exact_flow_user_class(irep, idx, reg)', "klass = 'RGSS::Bitmap'",
   /argument receiver keeps the class test|keeps the guard/, false],
  ['blt reports the opacity as given when it is not', 'codegen_exact_native_wrappers.rb',
   "argv.size == 5 ? 'TRUE' : 'FALSE'", "'TRUE'", /the unguarded call is the guarded arm's call \(rgss::bitmap_blt_direct\)/, false],
  ['stretch_blt reports the opacity as not given when it is', 'codegen_exact_native_wrappers.rb',
   "argv.size == 4 ? 'TRUE' : 'FALSE'", "'FALSE'", /the unguarded call is the guarded arm's call \(rgss::bitmap_stretch_blt_direct\)/, false],
  ['draw_text packs one argument too many', 'codegen_exact_native_wrappers.rb',
   'rgss::bitmap_draw_text_direct(M, #{recv}, #{argv.size},', 'rgss::bitmap_draw_text_direct(M, #{recv}, #{argv.size + 1},',
   /the unguarded call is the guarded arm's call \(rgss::bitmap_draw_text_direct\)/, false],
  ['any arity is taken (a fill_rect of two arguments gets the five-argument body)', 'codegen_exact_native_wrappers.rb',
   'return [:call, builder] if arities.include?(argc)', 'return [:call, builder]',
   /bad_arity: a call of another arity/, false],
  ['the kill switch is ignored', 'codegen_exact_native_wrappers.rb',
   "ENV.fetch('BC2CPP_EXACT_NATIVE_WRAPPERS', '1') != '0'", 'true', /the kill switch/, false],
  ['the nil test is not worth it for an unguarded call (EXACT_NATIVE_WRAPPER leaves NILABLE_RECEIVER\'s exact marks)',
   'codegen_nilable_receiver.rb', 'NATIVE_EXACT_DIRECT|EXACT_NATIVE_WRAPPER|', 'NATIVE_EXACT_DIRECT|', /NILABLE_RECEIVER's exact marks name the unguarded wrapper call/, false]
].freeze

# Concurrent mutants must not race to build the shared BC2CPP_FULL_BUILD_DIR: build it once first.
Bc2cppFixtureRuntime.full_or_build if ENV['BC2CPP_FULL_BUILD_DIR'] && MUTANTS.any?(&:last)

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
    env['EW_GENERATED_ONLY'] = '1' unless needs_run
    # Stops at the first FAIL line the mutant is expected to cause (Bc2cppMutantPool.run).
    Bc2cppMutantPool.run(env, [RbConfig.ruby, File.join(ROOT, 'scripts/bc2cpp/exact_native_wrappers_check.rb')],
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
  puts 'bc2cpp exact native wrappers mutation check: PASS'
else
  warn "bc2cpp exact native wrappers mutation check: #{failures.size} surviving mutant(s)"
  exit 1
end
