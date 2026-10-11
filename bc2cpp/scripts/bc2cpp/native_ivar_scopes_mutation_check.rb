#!/usr/bin/env ruby
# frozen_string_literal: true

# ADR 0332: each audit or family-poisoning mutant must fail its withdrawal
# case. The unmutated copy is a control; all cases use generated code only.
# Usage: MRBC=path/to/mrbc ruby scripts/bc2cpp/native_ivar_scopes_mutation_check.rb

require 'fileutils'
require 'rbconfig'
require 'tmpdir'
require_relative 'mutant_pool'

ROOT = File.expand_path('../..', __dir__)
abort 'SKIP: set MRBC' unless ENV['MRBC']

AUDIT = 'native_ivar_scopes.rb'
POOLS = 'codegen_numeric_ivars.rb'
MUTANTS = [
  ['control (unmutated)', AUDIT, nil, nil, nil],
  ['the digest is ignored', AUDIT,
   'text && Digest::SHA256.hexdigest(text) == digest', 'text', /changed input withdraws/],
  ['missing scanned inputs are trusted', AUDIT,
   'unless paths.include?(path)', 'unless true', /missing input withdraws/],
  ['outside helper callers are ignored', AUDIT,
   'if text.match?(references)', 'if false', /outside helper caller withdraws/],
  ['outside ivar spellings are ignored', AUDIT,
   'globally_spelled = outside_ivar_names(outside)', 'globally_spelled = Set.new', /outside presym write|foreign Ruby keeps/],
  ['the kill switch is ignored', AUDIT,
   "if ENV['BC2CPP_NATIVE_IVAR_SCOPES'] == '0'", 'if false', /kill switch withdraws/],
  ['Sprite viewport family is omitted', AUDIT,
   'RGSS::Sprite RGSS::Plane RGSS::Tilemap RGSS::Window', 'RGSS::Plane RGSS::Tilemap RGSS::Window', /native viewport family remains unknown: RGSS::Sprite/],
  ['Sprite bitmap family omitted', AUDIT,
   "'bitmap' => %w[RGSS::Sprite RGSS::Plane]", "'bitmap' => %w[RGSS::Plane]", /native bitmap family remains unknown: RGSS::Sprite/],
  ['Plane bitmap family omitted', AUDIT,
   "'bitmap' => %w[RGSS::Sprite RGSS::Plane]", "'bitmap' => %w[RGSS::Sprite]", /native bitmap family remains unknown: RGSS::Plane/],
  ['bitmap kill switch ignored', AUDIT,
   "name == 'bitmap' && ENV['BC2CPP_NATIVE_BITMAP_IVAR_SCOPE'] == '0'", 'false', /bitmap kill switch withdraws only bitmap/],
  ['native Window families are unpoisoned', POOLS,
   'group.failed = native_family || poisoned.include?(group.name)', 'group.failed = poisoned.include?(group.name)', /Window remains unknown|Window subclass remains unknown/],
  ['reflection no longer poisons the pooled name', POOLS,
   'group.failed = native_family || poisoned.include?(group.name)', 'group.failed = native_family || false', /withdrawal: reflection/]
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
    env = { 'BC2CPP_TOOL' => File.join(dir, 'tools', 'bc2cpp', 'bc2cpp.rb'), 'NIS_GENERATED_ONLY' => '1',
            'NIS_AUDIT_TOOL' => File.join(dir, 'tools', 'bc2cpp', AUDIT) }
    # A mutant stops at the first FAIL line it is expected to cause (Bc2cppMutantPool.run); the control runs to the end.
    stop = pattern ? /^\s+FAIL .*(?:#{expected.source})/ : nil
    Bc2cppMutantPool.run(env, [RbConfig.ruby, File.join(ROOT, 'scripts/bc2cpp/native_ivar_scopes_check.rb')], stop_on: stop)
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
  puts 'bc2cpp native ivar scopes mutation check: PASS'
else
  warn "bc2cpp native ivar scopes mutation check: #{failures.size} surviving mutant(s)"
  exit 1
end
