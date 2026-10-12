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
  ['switch', 'codegen_numeric_native_direct.rb', "ENV['BC2CPP_NUMERIC_NATIVE_DIRECT'] == '0'", 'false', { 'BC2CPP_NUMERIC_NATIVE_DIRECT' => '0' }],
  ['world gate', 'codegen_numeric_native_direct.rb', '@closed_world&.exact_instances_singleton_free?', 'true', {}],
  ['visibility', 'codegen_numeric_native_direct.rb', '@closed_world.visibility_stable?(name)', 'true', {}],
  ['blocked name', 'codegen_numeric_native_direct.rb', '!devirt_blocked_name?(name)', 'true', {}],
  ['mask', 'codegen_numeric_native_direct.rb', 'numeric_operand_mask(irep, index, reg, owner_def) == NumericFlow::INT', 'true', {}],
  ['lookup', 'codegen_numeric_native_direct.rb', 'entry = numeric_conversion_entries(name).first', 'entry = NativeCoreDirect::NUMERIC_CONVERSION_ENTRIES.find { |row| row.name == name }', {}],
  ['arity', 'codegen_send.rb', '!@call_block_expr && n.zero?', '!@call_block_expr', {}],
  ['body audit', 'native_core_direct.rb', 'return mrb_integer_to_str(mrb, self, base);', 'return mrb_integer_to_str(mrb, self, 16);', {}],
  ['decimal ABI', 'native_core_direct.rb', "expression: 'mrb_integer_to_str(M, recv, 10)'", "expression: 'mrb_integer_to_str(M, recv, 16)'", {}]
].freeze
work = lambda do |(_name, file, pattern, replacement, extra)|
  Dir.mktmpdir('numeric-native-mutant') do |dir|
    FileUtils.cp_r(File.join(ROOT, 'tools'), dir)
    if file
      path = File.join(dir, 'tools/bc2cpp', file)
      source = File.read(path)
      next nil unless source.include?(pattern)

      File.write(path, source.sub(pattern) { replacement })
    end
    env = { 'BC2CPP_TOOL' => File.join(dir, 'tools/bc2cpp/bc2cpp.rb'), 'CC_GENERATED_ONLY' => '1' }.merge(extra)
    Bc2cppMutantPool.run(env, [RbConfig.ruby, File.join(ROOT, 'scripts/bc2cpp/numeric_native_direct_check.rb')])
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
puts 'bc2cpp numeric native direct mutation check: PASS'
