#!/usr/bin/env ruby
# frozen_string_literal: true

# Mutation test for the INTEGER_CONSTANT_PROOF poison sources (docs/adr/0324). Each mutant is a copy of tools/bc2cpp with
# one soundness condition broken; scripts/bc2cpp/integer_constants_check.rb, run against the mutant through BC2CPP_TOOL,
# must FAIL on the check that guards that condition. A mutant that passes means the condition has no negative case. The
# unmutated copy runs first as a control and must pass, so a mutant is never "killed" by a world the copy itself cannot
# generate (the copy sits inside the repository, so the closed world it scans is the real one).
#
# The unit and generated-code halves decide every mutant (IC_GENERATED_ONLY), so no mruby build is needed.
#
# Usage: MRBC=path/to/mrbc ruby scripts/bc2cpp/integer_constants_mutation_check.rb

require 'fileutils'
require 'rbconfig'
require 'tmpdir'
require_relative 'mutant_pool'

ROOT = File.expand_path('../..', __dir__)
abort 'SKIP: set MRBC' unless ENV['MRBC']

CONSTS = 'integer_constants.rb'
DEFINE_CONST_SCAN = 'src.scan(/mrb_define_(?:global_)?const(?:_id)?\s*\([^;]{0,200}/m) do'

# [name, file, pattern, replacement, check label that must FAIL]; a nil pattern is the control.
MUTANTS = [
  ['control (unmutated)', CONSTS, nil, nil, nil],
  ['a native definition does not poison a constant', CONSTS, 'poisoned.merge(native_defined_const_names(native_paths))', '',
   /NEG NAT[FNSKI]: not an Integer constant|NEG the diagnostic does not list NAT[FNSKI]/],
  ['the native scan window is too short for a call over several lines', CONSTS, DEFINE_CONST_SCAN,
   'src.scan(/mrb_define_(?:global_)?const(?:_id)?\s*\([^;]{0,20}/m) do', /NEG NATI: not an Integer constant/],
  ['the native scan is lazy and matches no argument', CONSTS, DEFINE_CONST_SCAN,
   'src.scan(/mrb_define_(?:global_)?const(?:_id)?\s*\(.{0,200}?/m) do', /NEG NAT[FNSI]: not an Integer constant/],
  ['mrb_define_global_const is not read', CONSTS, DEFINE_CONST_SCAN,
   'src.scan(/mrb_define_const(?:_id)?\s*\([^;]{0,200}/m) do', /NEG NATS: not an Integer constant/],
  ['a quoted native name is not read', CONSTS, "seg.scan(/\"([A-Z][A-Za-z_0-9]*)\"/) { names << Regexp.last_match(1) }",
   "seg.scan(/\"([a-z][A-Za-z_0-9]*)\"/) { names << Regexp.last_match(1) }", /NEG NAT[FSI]: not an Integer constant/],
  ['an MRB_SYM native name is not read', CONSTS, "seg.scan(/MRB_SYM[A-Z_]*\\(\\s*([A-Za-z_][A-Za-z_0-9]*)\\s*\\)/) { names << Regexp.last_match(1) }",
   '', /NEG NATN: not an Integer constant/],
  ['mrb_const_set is not read', CONSTS, 'src.scan(/mrb_const_set\s*\([^;]{0,200}/m) do', 'src.scan(/mrb_const_set_unread\s*\([^;]{0,200}/m) do',
   /NEG NATK: not an Integer constant/],
  ['a jump landing on the SETCONST is ignored', CONSTS, '!entries.include?(insn.addr) ? const_source_kind(irep, i, src, entries) : nil',
   'const_source_kind(irep, i, src, entries)', /NEG ORC: not an Integer constant|NEG ANDN: not an Integer constant/]
].freeze

# nil when the mutation site is gone, else the run of the check against the mutant.
mutate = lambda do |(_name, file, pattern, replacement, expected)|
  # Inside the repository: bc2cpp.rb finds the engine's gems relative to itself (../..), and a copy elsewhere scans an empty world.
  Dir.mktmpdir('.ic_mutant', ROOT) do |dir|
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
    env = { 'BC2CPP_TOOL' => File.join(dir, 'tools', 'bc2cpp', 'bc2cpp.rb'), 'IC_GENERATED_ONLY' => '1' }
    # A mutant stops at the first FAIL line it is expected to cause (Bc2cppMutantPool.run); the control runs to the end.
    stop = pattern ? /^\s+FAIL .*(?:#{expected.source})/ : nil
    Bc2cppMutantPool.run(env, [RbConfig.ruby, File.join(ROOT, 'scripts/bc2cpp/integer_constants_check.rb')], stop_on: stop)
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
  puts 'bc2cpp integer constants mutation check: PASS'
else
  warn "bc2cpp integer constants mutation check: #{failures.size} surviving mutant(s)"
  exit 1
end
