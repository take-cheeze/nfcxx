#!/usr/bin/env ruby
# frozen_string_literal: true

# ADR 0334: each source, lookup or visibility mutant must fail its withdrawal
# case. The unmutated copy is a control; all cases use generated code only.
# Usage: MRBC=path/to/mrbc ruby scripts/bc2cpp/native_class_results_mutation_check.rb

require 'fileutils'
require 'rbconfig'
require 'tmpdir'
require_relative 'mutant_pool'

ROOT = File.expand_path('../..', __dir__)
abort 'SKIP: set MRBC' unless ENV['MRBC']

AUDIT = 'native_class_results.rb'
MUTANTS = [
  ['control (unmutated)', AUDIT, nil, nil, nil],
  ['unmodelled native sources are trusted', AUDIT,
   'return nil unless relative', "return { '<audited-native>' => kind } unless relative", /unmodelled native source/],
  ['String subclasses are treated as exact String', AUDIT,
   "|| !string_subclass_free", '', /String subclasses withdraw/],
  ['the string kill switch is ignored', AUDIT,
   "ENV['BC2CPP_NATIVE_STRING_RESULTS'] == '0'", 'false', /string result kill switch/],
  ['regexp nil is erased', AUDIT,
   "kind = ['String', :nil]", "kind = 'String'", /regexp nil retained/],
  ['the bigint delegate is not audited', AUDIT,
   "source && Digest::SHA256.hexdigest(source) == FILES.fetch('3rd/mruby/mrbgems/mruby-bigint/core/bigint.c')", 'true', /bigint delegate audited/],
  ['arbitrary aliases are trusted', 'codegen_native_results.rb',
   "NativeClassResults.source_matches?(irep.file, NativeClassResults::STRUCT_ALIAS_PATH, NativeClassResults::STRUCT_ALIAS_SHA)", 'true', /arbitrary alias/],
  ['Struct inspect replacement is trusted', 'codegen_native_results.rb',
   "return false if (@registry['inspect'] || []).any? { |definition| definition.owner == 'Struct' }", 'nil', /Struct inspect replacement/],
  ['outside Ruby definitions are trusted', 'closed_world.rb',
   "outside_ruby_paths_defining(name).all? { |path| audited_ruby_paths.include?(path) }", 'true', /linked foreign to_s/],
  ['opaque native inspect registrations are trusted', 'codegen_native_results.rb',
   "return false if opaque.fetch('inspect', []).any? { |owner| owner.nil? || owner == 'Struct' }", 'nil', /linked native inspect/],
  ['duplicate native inspect registrations are trusted', 'codegen_native_results.rb',
   "entries.one? && entries.first[:function] == 'mrb_struct_to_s'", "entries.any? { |entry| entry[:function] == 'mrb_struct_to_s' }", /linked ROM inspect/]
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
    env = { 'BC2CPP_TOOL' => File.join(dir, 'tools', 'bc2cpp', 'bc2cpp.rb'), 'NSR_GENERATED_ONLY' => '1',
            'NSR_AUDIT_TOOL' => File.join(dir, 'tools', 'bc2cpp', AUDIT) }
    # A mutant stops at the first FAIL line it is expected to cause (Bc2cppMutantPool.run); the control runs to the end.
    stop = pattern ? /^\s+FAIL .*(?:#{expected.source})/ : nil
    Bc2cppMutantPool.run(env, [RbConfig.ruby, File.join(ROOT, 'scripts/bc2cpp/native_string_results_check.rb')], stop_on: stop)
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
  puts 'bc2cpp native string results mutation check: PASS'
else
  warn "bc2cpp native string results mutation check: #{failures.size} surviving mutant(s)"
  exit 1
end
