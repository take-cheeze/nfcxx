#!/usr/bin/env ruby
# frozen_string_literal: true

# ADR 0335: each source, lookup or visibility mutant must fail its withdrawal
# case. The unmutated copy is a control; all cases use generated code only.
# Usage: MRBC=path/to/mrbc ruby scripts/bc2cpp/native_collection_results_mutation_check.rb

require 'fileutils'
require 'rbconfig'
require 'tmpdir'
require_relative 'mutant_pool'

ROOT = File.expand_path('../..', __dir__)
abort 'SKIP: set MRBC' unless ENV['MRBC']

AUDIT = 'native_class_results.rb'
MUTANTS = [
  ['control (unmutated)', AUDIT, nil, nil, nil],
  ['source digests ignored', AUDIT,
   'source && Array(digest).include?(Digest::SHA256.hexdigest(source))', 'source', /changed dup source/],
  ['dup allocation helper omitted', 'codegen_return_classes.rb',
   'allowed.all? { |relative| paths.any? { |path| path.end_with?("/#{relative}") } }', 'true', /dup requires its allocation helper/],
  ['compact allocation helper ignored', AUDIT,
   "return source_matches?(helper, '3rd/mruby/src/array.c')", 'return true', /changed compact helper/],
  ['core pins ignored', 'codegen_native_results.rb',
   'return core_kind if pinned && entry && native_core_entry_safe?(entry)', 'return core_kind if entry && native_core_entry_safe?(entry)', /changed join helper/],
  ['core lookup overrides ignored', 'codegen_native_results.rb',
   'return core_kind if pinned && entry && native_core_entry_safe?(entry)', 'return core_kind if pinned && entry', /Ruby Array compact override: compact class/],
  ['dup kill switch ignored', 'codegen_return_classes.rb',
   "return false if ENV['BC2CPP_NATIVE_COLLECTION_RESULTS'] == '0'", 'return false if false', /kill switch: dup class/],
  ['collection kill switch ignored', 'codegen_native_results.rb',
   "return nil if ENV['BC2CPP_NATIVE_COLLECTION_RESULTS'] == '0' && %w[compact join].include?(name)", 'return nil if false', /kill switch: compact class/]
].freeze

# nil when the mutation site is gone, else the run of the check against the mutant.
mutate = lambda do |(_name, file, pattern, replacement, expected)|
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
    if pattern
      path = File.join(dir, 'tools', 'bc2cpp', file)
      text = File.read(path)
      next nil unless text.include?(pattern)

      File.write(path, text.sub(pattern) { replacement })
    end
    env = { 'BC2CPP_TOOL' => File.join(dir, 'tools', 'bc2cpp', 'bc2cpp.rb'), 'NCR2_GENERATED_ONLY' => '1',
            'NCR2_TOOLS_DIR' => File.join(dir, 'tools', 'bc2cpp') }
    # A mutant stops at the first FAIL line it is expected to cause (Bc2cppMutantPool.run); the control runs to the end.
    stop = pattern ? /^\s+FAIL .*(?:#{expected.source})/ : nil
    Bc2cppMutantPool.run(env, [RbConfig.ruby, File.join(ROOT, 'scripts/bc2cpp/native_collection_results_check.rb')], stop_on: stop)
  end
end

failures = []
Bc2cppMutantPool.each_ordered(MUTANTS, work: mutate) do |(name, file, pattern, _replacement, expected), run|
  if run.nil?
    puts "  FAIL #{name}: the mutation site is gone from #{file}"
    failures << name
    next
  end
  if pattern.nil?
    puts "  #{run.success ? 'ok  ' : 'FAIL'} #{name} passes"
    unless run.success
      puts run.out.lines.last(15).join
      failures << name
    end
    next
  end
  failed_lines = run.out.lines.grep(/^\s+FAIL /)
  killed = !run.success && failed_lines.any? { |l| l.match?(expected) }
  puts "  #{killed ? 'ok  ' : 'FAIL'} mutant killed: #{name}"
  unless killed
    puts failed_lines.first(5).join
    puts run.out.lines.last(8).join if failed_lines.empty?
    failures << name
  end
end

if failures.empty?
  puts 'bc2cpp native collection results mutation check: PASS'
else
  warn "bc2cpp native collection results mutation check: #{failures.size} surviving mutant(s)"
  exit 1
end
