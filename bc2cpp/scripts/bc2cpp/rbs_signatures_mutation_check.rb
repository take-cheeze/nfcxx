#!/usr/bin/env ruby
# frozen_string_literal: true

# Mutation test for RBS_SIGNATURES (docs/adr/0413). Each mutant is a copy of tools/bc2cpp with one defect;
# scripts/bc2cpp/rbs_signatures_check.rb, run against the mutant through BC2CPP_TOOLS_DIR, must FAIL on the check that
# guards the behaviour. The loader mutants need no MRBC (`--unit-only`); the others compile fixtures.
#
# Usage: [MRBC=path/to/mrbc] ruby scripts/bc2cpp/rbs_signatures_mutation_check.rb

require 'fileutils'
require 'rbconfig'
require 'tmpdir'
require_relative 'mutant_pool'

ROOT = File.expand_path('../..', __dir__)

# [name, file, pattern, replacement, check label that must FAIL, needs the fixture half]
MUTANTS = [
  ['an overloaded def is accepted', 'rbs_signatures.rb', 'if m.overloads.size != 1', 'if m.overloads.empty?',
   /overloaded def is TC1002|overload message/, false],
  ['a parse error gets another code', 'rbs_signatures.rb', "code: 'TC1002', message: \"RBS syntax error", "code: 'TC9999', message: \"RBS syntax error",
   /parse error is TC1002/, false],
  ['a singleton def is read as an instance method', 'rbs_signatures.rb', 'if m.kind != :instance', 'if false', /singleton def is noted/, false],
  ['optional and block parameters are not noted', 'rbs_signatures.rb', 'accepted but give no hint") unless extras.empty?',
   'accepted but give no hint") if false', /optional \/ rest \/ block parameters are noted/, false],
  ['Array[C] loses its element class', 'rbs_signatures.rb', 'elem = args.size == 1 ? class_name_of(args.first) : nil', 'elem = nil',
   /element class of Array\[C\]|ivars: Integer, Array/, false],
  ['a stale signature is silent', 'rbs_signatures.rb', "note(ap, sig.loc, 'warning', 'TC1003', \"\#{sig.owner}\#\#{sig.name}: no such method in the program\")",
   'nil', /TC1003 warning/, true],
  ['a wrong parameter count is applied', 'rbs_signatures.rb', 'if sig.args.size != mand', 'if false', /wrong parameter count is a TC1004/, true],
  ['the comment does not win silently', 'rbs_signatures.rb', 'if comment_has && (fix || cls) &&', 'if false && (fix || cls) &&', /TC1006 names the slot/, true],
  ['Symbol is read as Integer', 'rbs_signatures.rb', 'when :sym then [:symbol, nil, nil, nil]', 'when :sym then [:fixnum, nil, nil, nil]',
   /fixnum\/symbol argument/, true],
  ['a signature-sourced hint reports as an annotation', 'rbs_signatures.rb', "ap.origins[d.irep] = 'signature'", "ap.origins[d.irep] = 'annotation'",
   /fixnum\/symbol argument|typed from the signature/, true],
  ['a class argument hint is not applied', 'rbs_signatures.rb', 'cann_args[i] ||= cls if cls && !fix', 'nil', /identical C\+\+ to the equivalent/, true],
  ['an unusable signature does not stop a build', 'bc2cpp.rb', 'abort "\\n[bc2cpp] RBS_SIGNATURES', 'warn "\\n[bc2cpp] RBS_SIGNATURES',
   /bc2cpp aborts naming RBS_SIGNATURES/, true],
  ['the ivar contradiction is not looked for', 'type_facts.rb', '    ivar_contradictions(ctx, out)', '', /ivar class/, true]
].freeze

failures = []
mutate = lambda do |(_name, file, pattern, replacement, expected, needs_analysis)|
  next :skip if needs_analysis && !ENV['MRBC']

  # The copy sits in tools/ with its files at the top, so the generator's root is this repository; a copy in a temp
  # directory cannot find the mruby sources it reads (compiled_gems.rb).
  Dir.mktmpdir('bc2cpp-mutant-', File.join(ROOT, 'tools')) do |dir|
    FileUtils.cp_r(File.join(ROOT, 'tools/bc2cpp/.'), dir)
    path = File.join(dir, file)
    text = File.read(path)
    next :site_gone unless text.include?(pattern)

    File.write(path, text.sub(pattern) { replacement })
    # BC2CPP_TOOL: the generator-driven checks compile through fixture_runtime, which reads it, not BC2CPP_TOOLS_DIR.
    env = { 'BC2CPP_TOOLS_DIR' => dir, 'BC2CPP_TOOL' => File.join(dir, 'bc2cpp.rb') }
    argv = [RbConfig.ruby, File.join(ROOT, 'scripts/bc2cpp/rbs_signatures_check.rb')]
    argv << '--unit-only' unless needs_analysis
    Bc2cppMutantPool.run(env, argv, stop_on: /^\s+FAIL .*(?:#{expected.source})/)
  end
end

Bc2cppMutantPool.each_ordered(MUTANTS, work: mutate) do |(name, file, _pattern, _replacement, expected, _needs), run|
  if run == :skip
    puts "  SKIP #{name} (set MRBC)"
    next
  end
  if run == :site_gone
    puts "  FAIL #{name}: the mutation site is gone from #{file}"
    failures << name
    next
  end
  failed_lines = run.out.lines.grep(/^\s+FAIL /)
  killed = !run.success && (failed_lines.any? { |l| l.match?(expected) } || false)
  puts "  #{killed ? 'ok  ' : 'FAIL'} mutant killed: #{name}"
  unless killed
    puts failed_lines.first(5).join
    puts run.out.lines.last(8).join if failed_lines.empty?
    failures << name
  end
end

if failures.empty?
  puts 'bc2cpp rbs signatures mutation check: PASS'
else
  warn "bc2cpp rbs signatures mutation check: #{failures.size} surviving mutant(s)"
  exit 1
end
