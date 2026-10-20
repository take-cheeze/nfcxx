#!/usr/bin/env ruby
# frozen_string_literal: true

# bc2cpp type check (docs/adr/0412, docs/bc2cpp-type-check.md): a REPORT-ONLY, TypeScript-like gradual check built on
# bc2cpp's own whole-program inference. It runs the analysis (the same one a build runs, without compiling any C++),
# then prints for every method / ivar / constant the type the analysis proved or the reason it could not, the
# annotations and signatures that contradict the inference, and the declarations whose signature would remove the most
# by-name sends.
#
#   MRBC=path/to/mrbc ruby scripts/bc2cpp/type_check.rb                    # the engine (wio closed world), text
#   MRBC=... ruby scripts/bc2cpp/type_check.rb --format json --out tc.json
#   MRBC=... ruby scripts/bc2cpp/type_check.rb --format tsv  --out tc.tsv
#   MRBC=... ruby scripts/bc2cpp/type_check.rb --files app.rb lib/*.rb      # a program of your own
#   ruby scripts/bc2cpp/type_check.rb --facts tc.facts.json --top 50        # re-render a saved run (no MRBC needed)
#
# Options:
#   --format text|json|tsv   output form (default text); diagnostics are always `file:line:col: severity: message [CODE]`
#   --out FILE               write the report there instead of stdout
#   --files F...             analyse these Ruby files as the whole program (closed world); default is the engine
#   --facts FILE             skip the analysis and render the facts file a previous run kept (--keep)
#   --rows FILE              the receiver-proof rows that go with --facts
#   --keep DIR               keep facts.json, rows.tsv and bc2cpp.stderr of this run in DIR
#   --top N                  how many ranked signature suggestions to print (default 20)
#   --all                    also print one info diagnostic per untyped parameter / return / ivar
#   --scope engine|all       engine sources only (default) or the mruby core mrblib too
#   --sig DIR                RBS signature directory (BC2CPP_SIG_DIRS; default sig/bc2cpp; docs/bc2cpp-type-check.md)
#   TC1017 (ADR 0491, 0522)  an untyped engine constant with no review annotation on its line; judged on the engine run
#                            only, a --files run has no gate
#   --no-sends               skip the by-name send ranking (the fastest run)
#   --what-if                estimate, per suggestion, how many by-name lines a signature removes (recompiles each
#                            send once; several minutes on the engine)
#   --emit-rbs DIR           write the inferred types as RBS files below DIR (docs/bc2cpp-type-check.md)
#   --emit-rbs-suggestions DIR  write reviewable candidates with independently inferred IR returns
#   -q                       no summary: diagnostics only
#
# Exit status: 0 clean, 1 when a declared type contradicts the inference or a signature cannot be used, 2 when the
# analysis itself failed.
# BC2CPP_TOOLS_DIR: another copy of tools/bc2cpp (a mutant of type_check_mutation_check.rb).
TOOLS = ENV['BC2CPP_TOOLS_DIR'] || File.expand_path('../../tools/bc2cpp', __dir__)
$LOAD_PATH.unshift(TOOLS)
require 'json'
require 'optparse'
require 'tmpdir'
require 'fileutils'
require 'type_check_report'
require 'constant_reviewed'

ROOT = File.expand_path('../..', __dir__)

opts = { format: 'text', top: 20, scope: 'engine', sends: true, what_if: false, all: false, quiet: false, files: nil }
parser = OptionParser.new do |o|
  o.banner = "usage: #{File.basename($PROGRAM_NAME)} [options]"
  o.on('--format F', %w[text json tsv]) { |v| opts[:format] = v }
  o.on('--out FILE') { |v| opts[:out] = v }
  o.on('--files', 'treat the remaining arguments as the whole program') { opts[:files] = [] }
  o.on('--facts FILE') { |v| opts[:facts] = v }
  o.on('--rows FILE') { |v| opts[:rows] = v }
  o.on('--keep DIR') { |v| opts[:keep] = v }
  o.on('--top N', Integer) { |v| opts[:top] = v }
  o.on('--all') { opts[:all] = true }
  o.on('--scope S', %w[engine all]) { |v| opts[:scope] = v }
  o.on('--sig DIR') { |v| (opts[:sig] ||= []) << File.expand_path(v) }
  o.on('--no-sends') { opts[:sends] = false }
  o.on('--what-if') { opts[:what_if] = true }
  o.on('--emit-rbs DIR') { |v| opts[:emit_rbs] = v }
  o.on('--emit-rbs-suggestions DIR') { |v| opts[:emit_rbs_suggestions] = v }
  o.on('-q') { opts[:quiet] = true }
end
rest = parser.parse(ARGV)
opts[:files] = rest if opts[:files]
abort 'type_check: --files needs at least one Ruby file' if opts[:files]&.empty?

if opts[:facts]
  facts = JSON.parse(File.read(opts[:facts]))
  rows = TypeCheckReport.load_rows(opts[:rows])
else
  require 'type_check_run'
  mrbc = ENV['MRBC'] || 'mrbc'
  Dir.mktmpdir('bc2cpp_type_check') do |dir|
    work = opts[:keep] ? FileUtils.mkdir_p(opts[:keep]).first : dir
    begin
      result = TypeCheckRun.run(root: ROOT, mrbc: mrbc, workdir: work, sources: opts[:files], sends: opts[:sends],
                                what_if: opts[:what_if], sig_dirs: opts[:sig], display_root: opts[:files] ? Dir.pwd : ROOT,
                                tools_dir: TOOLS)
    rescue RuntimeError => e
      warn "type_check: #{e.message}"
      exit 2
    end
    facts = JSON.parse(File.read(result.facts_path))
    rows = opts[:sends] ? TypeCheckReport.load_rows(result.rows_path) : []
  end
end

suggestions = opts[:sends] ? TypeCheckReport.suggestions(facts, rows, scope: opts[:scope]) : []
# The TC1017 ratchet (ADR 0491, 0522): the engine's constants are judged by their review annotations; a --files run is not.
constant_gate = !opts[:files]
diags = TypeCheckReport.diagnostics(facts, suggestions, all: opts[:all], top: opts[:top], scope: opts[:scope],
                                                       constant_gate: constant_gate)
summary = TypeCheckReport.summary(facts, scope: opts[:scope])

if opts[:emit_rbs]
  require 'type_check_rbs'
  emitted = TypeCheckRbs.emit(facts, opts[:emit_rbs], scope: opts[:scope])
  warn "type_check: wrote #{emitted[:files].size} RBS file(s), #{emitted[:methods]} method signature(s) to #{opts[:emit_rbs]}" \
       "#{emitted[:skipped].empty? ? '' : " (#{emitted[:skipped].size} skipped: #{emitted[:skipped].first(3).map(&:last).join(', ')})"}"
end

if opts[:emit_rbs_suggestions]
  require 'type_check_rbs'
  emitted = TypeCheckRbs.emit(TypeCheckRbs.suggestion_facts(facts, scope: opts[:scope]), opts[:emit_rbs_suggestions], scope: opts[:scope])
  warn "type_check: wrote #{emitted[:files].size} RBS suggestion file(s) to #{opts[:emit_rbs_suggestions]} (review before using as contracts)"
  emitted[:skipped].each { |reason, target| warn "type_check: skipped #{target}: #{reason}" }
end

body = case opts[:format]
       when 'json' then TypeCheckReport.json(facts, suggestions, diags, summary, scope: opts[:scope])
       when 'tsv' then TypeCheckReport.tsv(facts, scope: opts[:scope])
       else
         if opts[:quiet]
           diags.map(&:to_s).join("\n") << (diags.empty? ? '' : "\n")
         else
           TypeCheckReport.text(facts, suggestions, diags, summary, top: opts[:top], scope: opts[:scope], sends: opts[:sends])
         end
       end
opts[:out] ? File.write(opts[:out], body) : $stdout.write(body)
exit(TypeCheckReport.exit_status(diags))
