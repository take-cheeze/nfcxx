#!/usr/bin/env ruby
# frozen_string_literal: true

# Mutation test for the bc2cpp type check (docs/adr/0412). Each mutant is a copy of tools/bc2cpp with one defect;
# scripts/bc2cpp/type_check_check.rb, run against the mutant through BC2CPP_TOOLS_DIR, must FAIL on the check that
# guards the behaviour. A mutant that passes means the behaviour has no negative case.
#
# The first group breaks the report front-end (ranking, filters, exit status, diagnostic text): the check's
# hand-written facts half catches them without MRBC (`--render-only`). The second breaks the analysis side (annotation
# line numbers, class contradictions, the build abort the facts mode must not take, the ignored-token scan, inferred
# types) and needs MRBC.
#
# Usage: [MRBC=path/to/mrbc] ruby scripts/bc2cpp/type_check_mutation_check.rb

require 'fileutils'
require 'rbconfig'
require 'tmpdir'
require_relative 'mutant_pool'

ROOT = File.expand_path('../..', __dir__)

# [name, file, pattern, replacement, check label that must FAIL, needs the analysis half]
MUTANTS = [
  ['the ranking puts the fewest by-name lines first', 'type_check_report.rb',
   "sort_by { |s| [-s['by_name_lines'], -s['sites'], s['target']] }", "sort_by { |s| [s['by_name_lines'], -s['sites'], s['target']] }",
   /ranked list is ordered|JSON suggestions are ranked/, false],
  ['a receiver the flow already proves is still a suggestion', 'type_check_report.rb',
   "next if r['existing'] != '-' # the flow already proves the receiver", '', /not suggestions/, false],
  ['an already typed parameter is still a suggestion', 'type_check_report.rb',
   "return nil if p['type'] # already typed", 'nil # already typed', /typed parameter is not a suggestion/, false],
  ['a block parameter is a suggestion', 'type_check_report.rb',
   "return nil if r['why'].to_s == 'no_candidate:block_param'", 'nil', /block parameter is not a suggestion/, false],
  ['a warning fails the run', 'type_check_report.rb',
   "diags.any? { |d| d.severity == 'error' } ? 1 : 0", "diags.any? { |d| d.severity != 'info' } ? 1 : 0", /no error diagnostics: exit status 0/, false],
  ['an error does not fail the run', 'type_check_report.rb',
   "diags.any? { |d| d.severity == 'error' } ? 1 : 0", '0', /exit status 1 with an error/, false],
  ['diagnostics are not ordered by severity', 'type_check_report.rb',
   "out.sort_by { |d| [d.severity == 'error' ? 0 : d.severity == 'warning' ? 1 : 2, d.file.to_s, d.line, d.col, d.code, d.message] }",
   'out.sort_by { |d| [d.file.to_s, d.line, d.col, d.code, d.message] }', /errors come before warnings/, false],
  ['the declared type source is dropped from the contradiction text', 'type_check_report.rb',
   %(message: "\#{c['message']} (\#{c['source']})"), %(message: c['message']), /contradiction is an exact tsc-style line/, false],
  ['the column is dropped from a diagnostic', 'type_check_report.rb',
   %("\#{file}:\#{line}:\#{col}: \#{severity}: \#{message} [\#{code}]"), %("\#{file}:\#{line}: \#{severity}: \#{message} [\#{code}]"),
   /every diagnostic matches/, false],
  ['core methods are counted in the engine summary', 'type_check_report.rb',
   "methods = facts['methods'].select { |m| scope == 'all' || m['scope'] == scope }\n    ivars = facts['ivars'].select { |i| scope == 'all' || i['scope'] == scope }\n    consts = facts['constants'].select { |c| scope == 'all' || c['scope'] == scope }\n    params = methods",
   "methods = facts['methods']\n    ivars = facts['ivars'].select { |i| scope == 'all' || i['scope'] == scope }\n    consts = facts['constants'].select { |c| scope == 'all' || c['scope'] == scope }\n    params = methods",
   /summary counts engine scope only|typed parameter percentage/, false],
  ['an ignored annotation token is not reported', 'type_check_report.rb',
   "a['ignored'].each do |tok|", "[].each do |tok|", /ignored annotation token is a warning/, false],
  ['the annotation line is one below the comment', 'type_facts.rb',
   'idx >= 0 ? idx + 1 : nil', 'idx >= 0 ? idx + 2 : nil', /argument contradiction, exact text|class argument contradiction|class return contradiction/, true],
  ['the return class annotation is never compared', 'type_facts.rb',
   'if eann&.ret_class', 'if false', /class return contradiction/, true],
  ['the type check aborts on a contradiction like a build', 'bc2cpp.rb',
   'unless type_facts_path', '', /clean fixture exits 0|exit status 1|class argument contradiction/, true],
  ['unknown annotation tokens are not scanned', 'type_facts.rb',
   'ignored = tokens.reject(&known)', 'ignored = []', /unknown class token is a warning/, true],
  ['call-site argument types are not read', 'type_facts.rb',
   "    if mono\n      t = (ctx.arg_types[name] || [])[k - 1]", "    if false\n      t = (ctx.arg_types[name] || [])[k - 1]",
   /Fixnum is typed Integer from call-sites/, true],
  ['an embedded ivar type is not reported', 'type_facts.rb',
   "elsif row['embedded']", 'elsif false', /ivar only ever assigned a Fixnum is typed Integer/, true],
  ['the facts mode changes generated code', 'bc2cpp.rb',
   "skipped, compiled = compiled.partition { |m| m[:code].include?('#error') }",
   "compiled.each { |m| m[:code] = \"/* facts */\\n\#{m[:code]}\" } if ENV['BC2CPP_TYPE_FACTS']\n  skipped, compiled = compiled.partition { |m| m[:code].include?('#error') }", /byte-identical C\+\+/, true]
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
    # BC2CPP_TOOL: the byte-identical check compiles through fixture_runtime, which reads it, not BC2CPP_TOOLS_DIR.
    env = { 'BC2CPP_TOOLS_DIR' => dir, 'BC2CPP_TOOL' => File.join(dir, 'bc2cpp.rb') }
    argv = [RbConfig.ruby, File.join(ROOT, 'scripts/bc2cpp/type_check_check.rb')]
    argv << '--render-only' unless needs_analysis
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
  killed = !run.success && (failed_lines.any? { |l| l.match?(expected) } || (name.include?('aborts') && failed_lines.any?))
  puts "  #{killed ? 'ok  ' : 'FAIL'} mutant killed: #{name}"
  unless killed
    puts failed_lines.first(5).join
    puts run.out.lines.last(8).join if failed_lines.empty?
    failures << name
  end
end

if failures.empty?
  puts 'bc2cpp type check mutation check: PASS'
else
  warn "bc2cpp type check mutation check: #{failures.size} surviving mutant(s)"
  exit 1
end
