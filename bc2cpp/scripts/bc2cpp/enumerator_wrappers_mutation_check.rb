#!/usr/bin/env ruby
# frozen_string_literal: true

require 'fileutils'
require 'rbconfig'
require 'tmpdir'
require_relative 'mutant_pool'

ROOT = File.expand_path('../..', __dir__)
abort 'SKIP: set MRBC' unless ENV['MRBC']
MUTANTS = [
  ['control', nil, nil, nil, {}],
  ['switch ignored', 'core_methods.rb', "return false if ENV['BC2CPP_ENUMERATOR_WRAPPERS'] == '0'", 'return false if false', { 'BC2CPP_ENUMERATOR_WRAPPERS' => '0' }],
  ['guard omitted', 'core_methods.rb', ' || enumerator_wrapper?(d, ireps)', '', {}],
  ['guard relaxed', 'codegen_yield_free.rb', 'return false if CoreMethods.enumerator_wrapper?(@owner_of[label], @ireps)', 'return true if CoreMethods.enumerator_wrapper?(@owner_of[label], @ireps)', {}],
  ['block gate omitted', 'core_methods.rb', '!CoreDefs.touches_block?(body, ireps) && ', '', {}],
  ['whitelist omitted', 'core_methods.rb', 'ENUMERATOR_WRAPPERS.include?(definition.name)', 'true', {}],
  ['source gate omitted', 'core_methods.rb', "body.file.to_s.end_with?('/mruby-enumerator/mrblib/enumerator.rb')", 'true', {}],
  ['Fiber gate omitted', 'core_methods.rb', '!CoreDefs.references_fiber?(body, ireps)', 'true', {}]
].freeze
work = lambda do |(_name, file, pattern, replacement, extra)|
  Dir.mktmpdir('enumerator-mutant') do |dir|
    FileUtils.cp_r(File.join(ROOT, 'tools'), dir)
    if file
      path = File.join(dir, 'tools/bc2cpp', file)
      source = File.read(path)
      next nil unless source.include?(pattern)

      File.write(path, source.sub(pattern) { replacement })
    end
    env = { 'BC2CPP_TOOL' => File.join(dir, 'tools/bc2cpp/bc2cpp.rb'), 'EW_GENERATED_ONLY' => '1' }.merge(extra)
    Bc2cppMutantPool.run(env, [RbConfig.ruby, File.join(ROOT, 'scripts/bc2cpp/enumerator_wrappers_check.rb')], stop_on: /^\s+FAIL /)
  end
end
failures = []
Bc2cppMutantPool.each_ordered(MUTANTS, work: work) do |(name, file, _pattern, _replacement, _extra), run|
  ok = run && (file ? !run.success && run.out.match?(/^\s+FAIL /) : run.success)
  puts "  #{ok ? 'ok  ' : 'FAIL'} #{name}"
  failures << name unless ok
  warn run&.out unless ok
end
abort "FAILED: #{failures.join(', ')}" unless failures.empty?
puts 'bc2cpp Enumerator wrappers mutation check: PASS'
