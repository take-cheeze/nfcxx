#!/usr/bin/env ruby
# frozen_string_literal: true

# Mutation test for NUMERIC_CONSTANT_RANGES and NATIVE_INT_ARGS (docs/adr/0318). Each mutant is a copy of tools/bc2cpp with
# one soundness condition broken; scripts/bc2cpp/numeric_constants_check.rb, run against the mutant through BC2CPP_TOOL,
# must FAIL on the check that guards that condition. A mutant that passes means the condition has no negative case. The
# unmutated copy runs first as a control and must pass, so a mutant is never "killed" by a world the copy itself cannot
# generate (the copy sits inside the repository, so the closed world it scans is the real one).
#
# The generated-code half decides every mutant (NC_GENERATED_ONLY), so no mruby build is needed.
#
# Usage: MRBC=path/to/mrbc ruby scripts/bc2cpp/numeric_constants_mutation_check.rb

require 'fileutils'
require 'rbconfig'
require 'tmpdir'
require_relative 'mutant_pool'

ROOT = File.expand_path('../..', __dir__)
abort 'SKIP: set MRBC' unless ENV['MRBC']

RANGES = 'integer_constant_ranges.rb'
INTERVAL = 'codegen_fixnum_ranges.rb'
ARGS = 'codegen_native_int_args.rb'
WORLD = 'closed_world.rb'

# [name, file, pattern, replacement, check label that must FAIL]; a nil pattern is the control.
MUTANTS = [
  ['control (unmutated)', RANGES, nil, nil, nil],
  ['the kill switch is ignored', RANGES, "ENV['BC2CPP_NUMERIC_CONSTANTS'] != '0'", 'true', /kill switch/],
  ['an interval is not required to fit a Fixnum', RANGES, 'range[0] >= FIXNUM_MIN && range[1] <= FIXNUM_MAX ? range : nil', 'range',
   /NEG NcCons#wide|NEG a reassignment out of range/],
  ['a quotient by an interval holding 0 gets an interval', RANGES, 'return nil if right[0] <= 0 && right[1] >= 0', '',
   /NEG NcCons#qq|a constant above 32 bits/],
  ['a constant reading its own bare name is not skipped', RANGES, 'kinds.reject { |kind| kind == [:alias, name] }', 'kinds',
   /NcMap#tile2|reads its own bare name/],
  ['the hull of two definitions is the first one', RANGES, '[ranges.map(&:first).min, ranges.map(&:last).max]', 'ranges.first',
   /NEG a reassignment out of range|the diagnostic lists the intervals/],
  ['a jump landing on the SETCONST is ignored', RANGES, '!entries.include?(insn.addr) ? source_kind(irep, i, src, entries) : nil',
   'source_kind(irep, i, src, entries)', /NEG NcCons#andc/],
  ['a native definition does not poison a constant', RANGES, 'poisoned.merge(native)', '',
   /NEG a native source defining the constant/],
  ['a foreign Ruby definition does not poison a constant', RANGES, 'poisoned.merge(foreign)', '',
   /NEG a foreign Ruby source defining the constant/],
  ['a class or module named like the constant does not poison it', RANGES, "          poisoned << insn.sym_token\n          class_names", '          class_names',
   /NEG a module named like the constant/],
  ['a join of arithmetic definitions is read from one branch', INTERVAL, "next fixnum_interval_fail(why, 'join') unless fixnum_proof_region_ok?(irep, ctx, j, idx)", '',
   /NEG NcCons#join/],
  ['Integer#* may be redefined', INTERVAL, "%w[+ - * /].all? { |op| numeric_op_native?(op) }", 'true', /NEG a redefined Integer#\*/],
  ['a const_missing may answer a lookup', INTERVAL, ' && const_missing_free?', '', /NEG a const_missing/],
  ['a runtime constant rebinding is ignored', WORLD, '!@global_refusal && !@dynamic_constant_mutation
  end

  # The constant +name+ can only name', "true\n  end\n\n  # The constant +name+ can only name",
   /NEG a build gem whose (?:Ruby calls const_set|native code sets a computed constant name)/],
  ['the legacy constant proof vouches for a constant leaf', ARGS, '@fixnum_proof_skip_constants = true', '@fixnum_proof_skip_constants = false',
   # The native world no longer tells it apart: IntegerConstants poisons a native name itself (ADR 0324).
   /NEG a redefined Integer#\*/],
  ['a protected (rescue) range is walked through', INTERVAL, "ctx[:protected].include?(insn.addr) ||\n        ", '', /NEG NcCons#guarded/]
].freeze

# nil when the mutation site is gone, else the run of the check against the mutant.
mutate = lambda do |(_name, file, pattern, replacement, expected)|
  # Inside the repository: bc2cpp.rb finds the engine's gems relative to itself (../..), and a copy elsewhere scans an empty world.
  Dir.mktmpdir('.nc_mutant', ROOT) do |dir|
    Dir.children(ROOT).reject { |entry| entry.start_with?('.') || %w[tools].include?(entry) }.each do |entry|
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
    env = { 'BC2CPP_TOOL' => File.join(dir, 'tools', 'bc2cpp', 'bc2cpp.rb'), 'NC_GENERATED_ONLY' => '1' }
    # A mutant stops at the first FAIL line it is expected to cause (Bc2cppMutantPool.run); the control runs to the end.
    stop = pattern ? /^\s+FAIL .*(?:#{expected.source})/ : nil
    Bc2cppMutantPool.run(env, [RbConfig.ruby, File.join(ROOT, 'scripts/bc2cpp/numeric_constants_check.rb')], stop_on: stop)
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
  failed_lines = run.out.lines.grep(/^\s*FAIL /)
  killed = !run.success && failed_lines.any? { |l| l.match?(expected) }
  puts "  #{killed ? 'ok  ' : 'FAIL'} mutant killed: #{name}"
  unless killed
    puts failed_lines.first(5).join
    puts run.out.lines.last(8).join if failed_lines.empty?
    failures << name
  end
end

if failures.empty?
  puts 'bc2cpp numeric constants mutation check: PASS'
else
  warn "bc2cpp numeric constants mutation check: #{failures.size} surviving mutant(s)"
  exit 1
end
