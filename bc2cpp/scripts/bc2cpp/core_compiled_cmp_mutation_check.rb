#!/usr/bin/env ruby
# frozen_string_literal: true

# ADR 0371: each soundness condition of the compiled Hash comparison arm, broken one at a time in a copy of
# tools/bc2cpp, must make scripts/bc2cpp/core_compiled_cmp_check.rb's generated-code half fail.
require 'fileutils'
require 'rbconfig'
require 'tmpdir'
require_relative 'mutant_pool'

ROOT = File.expand_path('../..', __dir__)
abort 'SKIP: set MRBC' unless ENV['MRBC']
MUTANTS = [
  ['control', nil, nil, nil, {}],
  ['switch ignored', 'codegen_core_compiled_cmp.rb', "ENV['BC2CPP_CORE_COMPILED_CMP'] != '0'", 'true', { 'BC2CPP_CORE_COMPILED_CMP' => '0' }],
  ['yield-free proof omitted', 'codegen_core_compiled_cmp.rb', ' && @yield_reach.yield_free?(target.irep)', '', {}],
  ['exact Hash test omitted', 'codegen_core_compiled_cmp.rb', 'if (mrb_obj_ptr(a)->c != M->hash_class) return', 'if (false) return', {}],
  ['foreign Hash definer not required', 'codegen_core_compiled_cmp.rb', " && call_facts_answers.foreign_definer?(op, 'Hash')", '', {}],
].freeze
work = lambda do |(_name, file, pattern, replacement, extra)|
  Dir.mktmpdir('cc-cmp-mutant') do |dir|
    FileUtils.cp_r(File.join(ROOT, 'tools'), dir)
    if file
      path = File.join(dir, 'tools/bc2cpp', file)
      source = File.read(path)
      next nil unless source.include?(pattern)

      File.write(path, source.sub(pattern) { replacement })
    end
    env = { 'BC2CPP_TOOL' => File.join(dir, 'tools/bc2cpp/bc2cpp.rb'), 'CC_GENERATED_ONLY' => '1',
           'BC2CPP_LINT_CROSSCHECK' => '0' }.merge(extra)
    Bc2cppMutantPool.run(env, [RbConfig.ruby, File.join(ROOT, 'scripts/bc2cpp/core_compiled_cmp_check.rb')], stop_on: /^\s+FAIL /)
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
puts 'bc2cpp compiled core comparison mutation check: PASS'
