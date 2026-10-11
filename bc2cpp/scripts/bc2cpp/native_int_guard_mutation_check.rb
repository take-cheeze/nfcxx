#!/usr/bin/env ruby
# frozen_string_literal: true

# Mutants for scripts/bc2cpp/native_int_guard_check.rb (ADR 0358). Each one weakens a
# condition the proof needs and must be caught; the control must pass.
require 'fileutils'
require 'rbconfig'
require 'tmpdir'
require_relative 'mutant_pool'
ROOT = File.expand_path('../..', __dir__)
abort 'SKIP: set MRBC' unless ENV['MRBC']
MUTANTS = [
  ['control', nil, nil, nil, {}],
  # The switch off: the check is written to pass in this configuration too (it is the
  # measurement control), so the mutant that matters is the gate reading nothing at all.
  ['switch off control', nil, nil, nil, { 'BC2CPP_NATIVE_INT_GUARDS' => '0' }],
  # Every :int position keeps its test whatever the proof says: the arm retains the else the
  # proof exists to remove, and the measured census delta goes back to zero.
  ['test never dropped', 'codegen_native_direct.rb',
   'kinds[i] == :int && native_int_guard_needed?(int_site, argv, i)',
   'kinds[i] == :int', {}],
  # A non-:int argument gains a test, so a Float arm raises where the binding accepted it.
  ['test applied to :float', 'codegen_native_direct.rb',
   'kinds[i] == :int && native_int_guard_needed?(int_site, argv, i)',
   'kinds[i] == :float && native_int_guard_needed?(int_site, argv, i)', {}],
  # The gate stops consulting the proof at all.
  ['gate inverted', 'codegen_native_direct.rb',
   '!native_int_arg_proven?(*int_site, argv, position)',
   'true', {}],
  # The proof answers yes for anything that is not a plain register, which is how a Float
  # expression argument would reach mrb_integer().
  ['non-register arguments accepted', 'codegen_native_int_args.rb',
   'return false unless reg', 'return true unless reg', {}],
  # The gate ignores the position, so an entry's first argument is taken on the second's
  # proof (an `x=` whose value is a parameter but whose receiver read is a Fixnum).
  ['position ignored', 'codegen_native_direct.rb',
   '!native_int_arg_proven?(*int_site, argv, position)',
   '!native_int_arg_proven?(*int_site, argv, 0)', {}]
].freeze
work = lambda do |(_name, file, pattern, replacement, extra)|
  Dir.mktmpdir('native-int-mutant') do |dir|
    FileUtils.cp_r(File.join(ROOT, 'tools'), dir)
    if file
      path = File.join(dir, 'tools/bc2cpp', file)
      source = File.read(path)
      next nil unless source.include?(pattern)

      File.write(path, source.sub(pattern) { replacement })
    end
    env = { 'BC2CPP_TOOL' => File.join(dir, 'tools/bc2cpp/bc2cpp.rb'), 'CC_GENERATED_ONLY' => '1',
           # The copy of tools/ has no scripts/ beside it for the lint cross-check (ADR 0368), as in the other mutation checks.
           'BC2CPP_LINT_CROSSCHECK' => '0' }.merge(extra)
    Bc2cppMutantPool.run(env, [RbConfig.ruby, File.join(ROOT, 'scripts/bc2cpp/native_int_guard_check.rb')],
                        stop_on: /^\s+FAIL /)
  end
end
failures = []
Bc2cppMutantPool.each_ordered(MUTANTS, work: work) do |(name, file, _pattern, _replacement, _extra), run|
  ok = run && (file ? run.out.match?(/^\s+FAIL /) : run.success)
  puts "  #{ok ? 'ok  ' : 'FAIL'} #{name}"
  failures << name unless ok
  warn run&.out unless ok
end
abort "FAILED: #{failures.join(', ')}" unless failures.empty?
puts 'bc2cpp native int guard mutation check: PASS'
