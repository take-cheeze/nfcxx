#!/usr/bin/env ruby
# frozen_string_literal: true

# ADR 0333: each source, lookup or visibility mutant must fail its withdrawal
# case. The unmutated copy is a control; all cases use generated code only.
# Usage: MRBC=path/to/mrbc ruby scripts/bc2cpp/native_class_results_mutation_check.rb

require 'fileutils'
require 'rbconfig'
require 'tmpdir'
require_relative 'mutant_pool'

ROOT = File.expand_path('../..', __dir__)
abort 'SKIP: set MRBC' unless ENV['MRBC']

AUDIT = 'native_class_results.rb'
RETURNS = 'codegen_numeric_returns.rb'
MUTANTS = [
  ['control (unmutated)', AUDIT, nil, nil, nil],
  ['the digest is ignored', AUDIT,
   'source && Array(FILES.fetch(relative)).include?(Digest::SHA256.hexdigest(source))', 'source', /changed source/],
  ['unmodelled native files are trusted', AUDIT,
   'return nil unless relative', "return { '<audited-native>' => kind } unless relative", /unmodelled native registration/],
  ['the native fact kill switch is ignored', AUDIT,
   "if ENV['BC2CPP_NATIVE_CLASS_RESULTS'] == '0'", 'if false', /native fact kill switch/],
  ['snapshot nil returns are erased', AUDIT,
   "['RGSS::Bitmap', :nil]", "'RGSS::Bitmap'", /snapshot retains every nil return/],
  ['range nil returns are erased', AUDIT,
   "['Array', :nil]", "'Array'", /numeric range conversion retains nil fallback/],
  ['range allocation is not audited', AUDIT,
   "return nil unless source_matches?(helper, '3rd/mruby/src/array.c')", 'return nil if false', /numeric range conversion audits Array allocation/],
  ['nested range switch is ignored', AUDIT,
   "return nil if name == '__num_to_a' && ENV['BC2CPP_CORE_RUBY_NESTED_RESULTS'] == '0'", 'return nil if false', /nested switch withdraws native range helper/],
  ['the Method delegate is not audited', AUDIT,
   "return nil unless paths.any? { |path| path.end_with?('/mruby-proc-ext/src/proc.c') }", 'return nil if false', /Method parameters requires its Proc delegate/],
  ['the absent-native kill switch is ignored', RETURNS,
   "if ENV['BC2CPP_ABSENT_NATIVE_RETURNS'] == '0'", 'if false', /absent definition kill switch: parameters/],
  ['exact core lookup ignores overrides', 'codegen_native_results.rb',
   "return core_kind if pinned && entry && native_core_entry_safe?(entry)", "return core_kind if pinned && entry", /reopened String bytes/],
  ['linked native definitions are removed', RETURNS,
   'return definitions unless @native_name_sources && @foreign_method_names && @closed_world&.name_fully_visible?(name)',
   'nil', /native return is retained in mixed Ruby\/native join/]
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
    env = { 'BC2CPP_TOOL' => File.join(dir, 'tools', 'bc2cpp', 'bc2cpp.rb'), 'NCR_GENERATED_ONLY' => '1',
            'NCR_AUDIT_TOOL' => File.join(dir, 'tools', 'bc2cpp', AUDIT) }
    # A mutant stops at the first FAIL line it is expected to cause (Bc2cppMutantPool.run); the control runs to the end.
    stop = pattern ? /^\s+FAIL .*(?:#{expected.source})/ : nil
    Bc2cppMutantPool.run(env, [RbConfig.ruby, File.join(ROOT, 'scripts/bc2cpp/native_class_results_check.rb')], stop_on: stop)
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
  puts 'bc2cpp native class results mutation check: PASS'
else
  warn "bc2cpp native class results mutation check: #{failures.size} surviving mutant(s)"
  exit 1
end
