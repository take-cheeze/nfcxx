#!/usr/bin/env ruby
# frozen_string_literal: true

# Mutation test for LOOP_INSTALLERS (docs/adr/0304). Each mutant is a copy of tools/bc2cpp with one
# soundness condition of tools/bc2cpp/loop_installers.rb (or of its closed-world hook) broken;
# scripts/bc2cpp/loop_installers_check.rb, run against the mutant, must FAIL on the negative world
# that guards that condition. A mutant that passes means the condition has no negative case.
#
# Usage: MRBC=path/to/mrbc ruby scripts/bc2cpp/loop_installers_mutation_check.rb

require 'fileutils'
require 'rbconfig'
require 'tmpdir'
require_relative 'mutant_pool'

ROOT = File.expand_path('../..', __dir__)
abort 'SKIP: set MRBC' unless ENV['MRBC']

# [name, file, pattern, replacement, check label that must FAIL]
MUTANTS = [
  ['a call no longer taints the constants it could reach by name', 'loop_installers.rb',
   '@consts.each_value { |v| LoopInstallers.poison(v) }', 'nil', /a call between the build and the loop/],
  ['a call no longer poisons the operands it was handed', 'loop_installers.rb',
   '(base..(base + span)).each { |r| LoopInstallers.poison(get(r)) }', 'nil', /a mutated local container/],
  ['a constant read no longer taints the constants', 'loop_installers.rb',
   "      else\n        poison_consts\n        @regs[insn.reg.to_i] = OPAQUE\n      end",
   "      else\n        @regs[insn.reg.to_i] = OPAQUE\n      end", /a constant read between the build and the loop/],
  ['a branch no longer ends the straight-line walk', 'loop_installers.rb',
   'limit = i if insn.op.match?(FLOW_OPS) && i < limit', 'nil', /a loop built and run under a branch/],
  ['a back edge no longer ends the straight-line walk', 'loop_installers.rb',
   "        limit = [limit, landing].min if landing\n      end\n      (@irep.catch_handlers || []).each do |h|",
   "      end\n      [].each do |h|", /a loop retried by a rescue/],
  ['a user definition of an iterator or installer is ignored', 'loop_installers.rb',
   '(MODELED_METHODS + ATTR_SENDS).all? do |name|', '[].all? do |name|', /redefined/],
  ['a private default visibility is ignored', 'loop_installers.rb',
   "unless visibility == :public\n", "unless true\n", /a private default visibility/],
  ['a write into the iterated container is allowed', 'loop_installers.rb',
   "refuse('a write into the container being iterated') if @protected.key?(hash)", 'nil',
   /a write into the iterated Hash inside the loop/],
  ['the attribute name is not checked', 'loop_installers.rb',
   'unless arg.name.match?(ATTR_NAME)', 'unless true', /a name that is not an attribute name/],
  ['the block parameter count is not checked', 'loop_installers.rb',
   'first.enter_fields[0] == args.size &&', '', /a one-parameter block over Hash#each|a two-parameter block over an Array/],
  ['a branch on an unknown value takes a side', 'loop_installers.rb',
   "refuse('a branch on a value the interpreter does not know') if value.equal?(OPAQUE)", 'nil',
   /a branch on a value the walk does not know/],
  ['a branch is taken the wrong way', 'loop_installers.rb',
   "when 'JMPNOT' then return truthy(get.call(insn.reg)) ? pc + 1 : jump(irep, insn)",
   "when 'JMPNOT' then return truthy(get.call(insn.reg)) ? jump(irep, insn) : pc + 1", /as CRuby/],
  ['a reader also registers a writer', 'loop_installers.rb',
   'names << "#{name}=" if %i[writer accessor].include?(kind)', 'names << "#{name}=" if true', /as CRuby/],
  ['the closed world trusts a send the registry does not account for', 'closed_world.rb',
   'return if loop_installer_sites.include?([irep.label, idx])', 'return if true',
   /a computed name: the closed world keeps/]
].freeze

# nil when the mutation site is gone, else the run of the check against the mutant.
mutate = lambda do |(_name, file, pattern, replacement, expected)|
  Dir.mktmpdir do |dir|
    FileUtils.cp_r(File.join(ROOT, 'tools/bc2cpp'), dir)
    path = File.join(dir, 'bc2cpp', file)
    text = File.read(path)
    next nil unless text.include?(pattern)

    File.write(path, text.sub(pattern) { replacement })
    env = { 'LP_REGISTRY_ONLY' => '1', 'BC2CPP_TOOLS_DIR' => File.join(dir, 'bc2cpp'), 'BC2CPP_TOOL' => File.join(dir, 'bc2cpp', 'bc2cpp.rb') }
    # Stops at the first FAIL line the mutant is expected to cause (Bc2cppMutantPool.run).
    Bc2cppMutantPool.run(env, [RbConfig.ruby, File.join(ROOT, 'scripts/bc2cpp/loop_installers_check.rb')],
                         stop_on: /^\s+FAIL .*(?:#{expected.source})/)
  end
end

failures = []
Bc2cppMutantPool.each_ordered(MUTANTS, work: mutate) do |(name, file, _pattern, _replacement, expected), run|
  if run.nil?
    puts "  FAIL #{name}: the mutation site is gone from #{file}"
    failures << name
    next
  end
  failed_lines = run.out.lines.grep(/^\s+FAIL /)
  killed = !run.success && failed_lines.any? { |l| l.match?(expected) }
  puts "  #{killed ? 'ok  ' : 'FAIL'} mutant killed: #{name}"
  unless killed
    puts failed_lines.first(5).join, run.out.lines.last(3).join
    failures << name
  end
end

if failures.empty?
  puts 'bc2cpp loop installers mutation check: PASS'
else
  warn "bc2cpp loop installers mutation check: #{failures.size} surviving mutant(s)"
  exit 1
end
