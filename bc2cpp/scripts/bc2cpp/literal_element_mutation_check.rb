#!/usr/bin/env ruby
# frozen_string_literal: true

require 'fileutils'
require 'rbconfig'
require 'tmpdir'
require_relative 'mutant_pool'
ROOT = File.expand_path('../..', __dir__)
MUTANTS = [
  ['control', nil, nil, {}],
  ['switch', "ENV['BC2CPP_LITERAL_ELEMENT_PROOF'] == '0'", 'false', { 'BC2CPP_LITERAL_ELEMENT_PROOF' => '0' }],
  ['captured writes', 'return nil if opaque.include?(element.to_s)', 'return nil if false', {}],
  ['bounds', 'literal_index.between?(-count, count - 1)', 'true', {}],
  ['effects', 'return nil unless pure?(writer)', 'return nil if false', {}],
  ['branches', 'return nil unless linear?(program, cursor, index)', 'return nil if false', {}],
  ['element mask', "when 'STRING' then NumericFlow::STR", "when 'STRING' then NumericFlow::ARR", {}]
].freeze
work = lambda do |(_name, pattern, replacement, extra)|
  Dir.mktmpdir('literal-mutant') do |dir|
    FileUtils.cp_r(File.join(ROOT, 'tools'), dir)
    if pattern
      path = File.join(dir, 'tools/bc2cpp/literal_element_proof.rb')
      source = File.read(path)
      next nil unless source.include?(pattern)

      File.write(path, source.sub(pattern) { replacement })
    end
    env = { 'BC2CPP_TOOL' => File.join(dir, 'tools/bc2cpp/bc2cpp.rb'), 'CC_GENERATED_ONLY' => '1' }.merge(extra)
    Bc2cppMutantPool.run(env, [RbConfig.ruby, File.join(ROOT, 'scripts/bc2cpp/literal_element_check.rb')])
  end
end
failures = []
Bc2cppMutantPool.each_ordered(MUTANTS, work: work) do |(name, pattern, _replacement, _extra), run|
  ok = run && (pattern ? !run.success && run.out.match?(/^\s+FAIL /) : run.success)
  puts "  #{ok ? 'ok  ' : 'FAIL'} #{name}"
  failures << name unless ok
  warn run&.out unless ok
end
abort "FAILED: #{failures.join(', ')}" unless failures.empty?
puts 'bc2cpp literal element mutation check: PASS'
