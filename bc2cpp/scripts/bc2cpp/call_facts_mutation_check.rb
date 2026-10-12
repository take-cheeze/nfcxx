#!/usr/bin/env ruby
# frozen_string_literal: true

# Mutation test for CALL_FACTS (docs/adr/0317). Each mutant is a copy of tools/bc2cpp with one soundness condition
# broken; scripts/bc2cpp/call_facts_check.rb, run against the mutant through BC2CPP_TOOL, must FAIL on the check
# that guards that condition. A mutant that passes means the condition has no negative case. An unmutated copy runs
# first and must pass: it proves the harness runs the same check the mutants run.
#
# The mutant tree lives inside the repository (.mutants/, removed on exit): bc2cpp.rb finds the engine's gems
# relative to itself (../..), so a copy elsewhere would read a different layout.
#
# Three gates have no mutant because another gate covers them in every world a fixture can build: ClosedWorld's
# `native_free` lift (a native, outside or module definer is already refused as :opaque_definer), the set-size cap,
# and the singleton-free test in `call_facts_enabled?` (an instance-only definition is either a `.singleton` definer,
# which puts the class object in the set, or an installer, which makes the name unbounded).
#
# Usage: MRBC=path/to/mrbc [BC2CPP_MRUBY_FULL=dir] ruby scripts/bc2cpp/call_facts_mutation_check.rb

require 'fileutils'
require 'rbconfig'
require 'tmpdir'
require_relative 'mutant_pool'

ROOT = File.expand_path('../..', __dir__)
abort 'SKIP: set MRBC' unless ENV['MRBC']

# [name, file, pattern, replacement, check label that must FAIL, needs the run half]
MUTANTS = [
  ['a register rewritten by an ordinary op keeps its fact', 'call_facts.rb',
   "      else\n        detach!(out, a)\n      end\n      out\n", "      else\n      end\n      out\n",
   /NEG neg_global/, false],
  ['a join keeps a fact only one side has', 'call_facts.rb',
   'both = left[1][a] && right[1][b] ? left[1][a] & right[1][b] : nil', 'both = (left[1][a].to_a | right[1][b].to_a)',
   /NEG neg_branch|NEG neg_after_rescue/, false],
  ['a call leaves the registers its callee reuses attached to the receiver', 'call_facts.rb',
   "        clobber!(out, a, n)\n        out[1][out[0][kept.first]] = names unless kept.empty?",
   "        out[1][out[0][kept.first]] = names unless kept.empty?",
   /NEG neg_result/, false],
  ['a local a block writes still takes the fact', 'call_facts.rb',
   'if src < n && src != a && !opaque.include?(a.to_s) && !opaque.include?(src.to_s)', 'if src < n && src != a',
   /NEG neg_block_write/, false],
  ['an included module is not an ancestor', 'call_facts.rb',
   "        Array(@w.included[cur]).reverse.each { |m| mixin_chain(m, out, Set.new) }\n        CORE_MIXINS",
   "        CORE_MIXINS",
   /NEG a module gives Array the fact name/, false],
  ['the native owners of a name are ignored', 'call_facts.rb',
   "      native = native_owners(name, defs)\n      return nil unless native\n", "      native = Set.new\n",
   /NEG neg_native/, false],
  ['a method_missing class does not answer every name', 'call_facts.rb',
   "      return true if method_missing_classes.include?(klass)\n\n      anc, unknown = ancestors(klass)\n      unknown ||",
   "      anc, unknown = ancestors(klass)\n      unknown ||",
   /NEG a method_missing class/, false],
  ['a class an outside source subclasses is still an instance class', 'call_facts.rb',
   "        return false unless @cw.untouched_class?(cur)\n\n", '',
   /NEG an outside Ruby source subclasses a class of the set/, false],
  ['the kill switch is ignored', 'codegen_call_facts.rb',
   "ENV['BC2CPP_CALL_FACTS'] != '0' && ", '',
   /kill switch \(BC2CPP_CALL_FACTS=0\)/, false],
  ['a name an alias or a computed definition installs is still bounded', 'call_facts.rb',
   "installed.nil? || installed.include?(name) || ", '',
   /NEG an alias of the fact name|NEG a name defined from a computed list/, false]
].freeze

mutate = lambda do |(_name, file, pattern, replacement, _expected, needs_run)|
  FileUtils.mkdir_p(File.join(ROOT, '.mutants'))
  dir = Dir.mktmpdir('m', File.join(ROOT, '.mutants'))
  begin
    # Every other entry of the repository root is linked, so the copy keeps the layout bc2cpp.rb expects.
    Dir.children(ROOT).reject { |entry| %w[.git tools .mutants].include?(entry) }.each do |entry|
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
    env = { 'BC2CPP_TOOL' => File.join(dir, 'tools', 'bc2cpp', 'bc2cpp.rb') }
    env['CF_GENERATED_ONLY'] = '1' unless needs_run
    Bc2cppMutantPool.run(env, [RbConfig.ruby, File.join(ROOT, 'scripts/bc2cpp/call_facts_check.rb')])
  ensure
    FileUtils.rm_rf(dir)
    Dir.rmdir(File.join(ROOT, '.mutants')) if Dir.empty?(File.join(ROOT, '.mutants'))
  end
end

failures = []
# The control run needs the run half only if some mutant does.
control = [['unmutated control', nil, nil, nil, nil, MUTANTS.any? { |m| m.last }]]
Bc2cppMutantPool.each_ordered(control, work: mutate) do |(name, *), run|
  passed = run.success
  puts "  #{passed ? 'ok  ' : 'FAIL'} #{name} passes the check"
  unless passed
    puts run.out.lines.grep(/^\s+FAIL /).first(5).join
    failures << name
  end
end

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
    puts failed_lines.first(5).join
    failures << name
  end
end

if failures.empty?
  puts 'bc2cpp call facts mutation check: PASS'
else
  warn "bc2cpp call facts mutation check: #{failures.size} failure(s)"
  exit 1
end
