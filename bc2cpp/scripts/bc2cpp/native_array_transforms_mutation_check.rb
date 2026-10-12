#!/usr/bin/env ruby
# frozen_string_literal: true

# ADR 0336: each source, lookup or visibility mutant must fail its withdrawal
# case. The unmutated copy is a control; all cases use generated code only.
# Usage: MRBC=path/to/mrbc ruby scripts/bc2cpp/native_array_transforms_mutation_check.rb

require 'fileutils'
require 'rbconfig'
require 'tmpdir'
require_relative 'mutant_pool'

ROOT = File.expand_path('../..', __dir__)
abort 'SKIP: set MRBC' unless ENV['MRBC']

AUDIT = 'native_class_results.rb'
MUTANTS = [
  ['control (unmutated)', AUDIT, nil, nil, nil],
  ['source digest ignored', AUDIT,
   'source && Array(FILES.fetch(relative)).include?(Digest::SHA256.hexdigest(source))', 'source', /changed .*mruby-array-ext.*compact/],
  ['allocation helper ignored', AUDIT,
   'return nil unless source_matches?(helper, relative)', 'return nil if false', /changed 3rd\/mruby\/src\/array.c: compact/],
  ['unknown native registration trusted', AUDIT,
   'return nil unless relative', "return { '<audited-native>' => kind } unless relative", /unknown registration compact/],
  ['transform switch ignored', AUDIT,
   "return nil if ARRAY_TRANSFORMS.include?(name) && ENV['BC2CPP_NATIVE_ARRAY_TRANSFORMS'] == '0'", 'return nil if false', /transform kill switch: unique class/],
  ['String subclass gate ignored', AUDIT,
   'return nil unless string_subclass_free', 'return nil if false', /String subclass: join class/],
  ['audited foreign candidate exemption omitted', 'codegen_numeric_returns.rb',
   'next if @foreign_method_names.include?(name) && !string_native && !collection_native',
   'next if @foreign_method_names.include?(name) && !string_native', /unlinked foreign Ruby: unique class/],
  ['class switch ignored', AUDIT,
   "return nil if ENV['BC2CPP_NATIVE_CLASS_RESULTS'] == '0'", 'return nil if false', /class fact kill switch: unique class/]
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
    env = { 'BC2CPP_TOOL' => File.join(dir, 'tools', 'bc2cpp', 'bc2cpp.rb'), 'NAT_GENERATED_ONLY' => '1',
            'NAT_AUDIT_TOOL' => File.join(dir, 'tools', 'bc2cpp', AUDIT) }
    # A mutant stops at the first FAIL line it is expected to cause (Bc2cppMutantPool.run); the control runs to the end.
    stop = pattern ? /^\s+FAIL .*(?:#{expected.source})/ : nil
    Bc2cppMutantPool.run(env, [RbConfig.ruby, File.join(ROOT, 'scripts/bc2cpp/native_array_transforms_check.rb')], stop_on: stop)
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
  puts 'bc2cpp native array transforms mutation check: PASS'
else
  warn "bc2cpp native array transforms mutation check: #{failures.size} surviving mutant(s)"
  exit 1
end
