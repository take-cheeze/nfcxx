#!/usr/bin/env ruby
# frozen_string_literal: true

require 'fileutils'
require 'rbconfig'
require 'tmpdir'
require_relative 'mutant_pool'

ROOT = File.expand_path('../..', __dir__)
abort 'SKIP: set MRBC' unless ENV['MRBC']
MUTANTS = [
  ['control', nil, nil, {}],
  ['switch ignored', "ENV['BC2CPP_USER_RECEIVER_UNIONS'] == '0'", 'false', { 'BC2CPP_USER_RECEIVER_UNIONS' => '0' }],
  ['constructor lookup ignored', '&& stable_standard_constructor_class?(klass)', '', {}],
  ['family bound omitted', 'classes.size <= 8', 'true', {}],
  ['member agreement omitted', 'return nil if result && result != mask', 'return nil if false', {}],
  ['unknown bits discarded', 'bits.reduce(0, :|) == receiver', 'true', {}],
  ['only first member analyzed', 'bits.each do |bit|', 'bits.first(1).each do |bit|', {}],
  ['member receiver not substituted', 'inputs[insn.reg.to_i] = bit', 'inputs[insn.reg.to_i] = NumericFlow::OTHER', {}],
  ['case class guard ignored', '#{owner_class_ptr_expr(klass)} == bc2cpp_union_class', 'true', { 'UF_GENERATED_ONLY' => '0' }],
  ['emitted owner gate ignored', 'return nil if @only_owners && !@only_owners.include?(candidate.owner) && !@other_owners&.include?(candidate.owner)', 'return nil if false', {}],
  ['outside lookup ignored', 'definition = closed_world_exact_target(name, receiver_class, accessor: argc == 0)', 'definition = @registry.fetch(name, []).find { |d| d.owner == receiver_class }', {}]
].freeze
work = lambda do |(_name, pattern, replacement, extra)|
  Dir.mktmpdir('user-union-mutant') do |dir|
    FileUtils.cp_r(File.join(ROOT, 'tools'), dir)
    if pattern
      path = File.join(dir, 'tools/bc2cpp/codegen_return_classes.rb')
      source = File.read(path)
      next nil unless source.include?(pattern)

      source = source.gsub(pattern) { replacement }
      source = source.gsub('(2..8).cover?(bits.size)', 'bits.size >= 2') if pattern == 'classes.size <= 8'
      File.write(path, source)
    end
    env = { 'BC2CPP_TOOL' => File.join(dir, 'tools/bc2cpp/bc2cpp.rb'), 'UF_GENERATED_ONLY' => '1' }.merge(extra)
    Bc2cppMutantPool.run(env, [RbConfig.ruby, File.join(ROOT, 'scripts/bc2cpp/user_receiver_unions_check.rb')])
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
puts 'bc2cpp user receiver unions mutation check: PASS'
