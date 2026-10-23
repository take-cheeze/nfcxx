#!/usr/bin/env ruby
# frozen_string_literal: true

# Checks tools/bc2cpp/ir_trace_evidence.rb: trace evidence downgrades only a possible_mismatch return whose method the
# trace observed inside the contract, never a mismatch, and never changes a row's status. Host only, no mrbc: the facts
# are written by hand and the CLI runs with --facts.
#
#   ruby scripts/bc2cpp/ir_trace_evidence_check.rb

require 'json'
require 'open3'
require 'tmpdir'
require 'rbconfig'
require_relative '../../tools/bc2cpp/ir_trace_evidence'
require_relative '../../tools/bc2cpp/type_check_report'

ROOT = File.expand_path('../..', __dir__)
failures = []
checks = 0
check = lambda do |what, condition|
  checks += 1
  puts "  #{condition ? 'ok  ' : 'FAIL'} #{what}"
  failures << what unless condition
end

def row(owner, method, status, type, expected, kind: 'return', detail: 'return')
  { 'owner' => owner, 'method' => method, 'kind' => kind, 'detail' => detail, 'file' => 'game.rb', 'line' => 3, 'col' => 1,
    'scope' => 'engine', 'status' => status, 'type' => type, 'expected' => expected, 'compatibility' => 'checked',
    'contracts' => [], 'reason' => nil }
end

ROWS = [
  row('Game::Actor', 'hp', 'possible_mismatch', 'Integer | String', 'Integer'),
  row('Game::Actor', 'name', 'possible_mismatch', 'Integer | String', 'Integer'),
  row('Game::Actor', 'level', 'mismatch', 'String', 'Integer'),
  row('Game::Actor', 'maybe_nil', 'possible_mismatch', 'Integer | nil', 'Integer | nil'),
  row('Game::Actor', 'flag', 'possible_mismatch', 'TrueClass | String', 'bool'),
  row('Game::Actor', 'flag_true', 'possible_mismatch', 'TrueClass | String', 'TrueClass'),
  row('Game::Actor', 'flag_one', 'possible_mismatch', 'TrueClass | String', 'TrueClass'),
  row('Game::Actor', 'untyped_obs', 'possible_mismatch', 'Integer | String', 'Integer'),
  row('Game::Actor', 'iface', 'possible_mismatch', 'Integer | String', 'Integer'),
  row('Game::Actor', 'hp', 'possible_mismatch', 'Integer | String', 'Integer', kind: 'ivar_store', detail: '@hp'),
  row('Game::Actor.singleton', 'make', 'possible_mismatch', 'Integer | String', 'Integer'),
  row('Game::Party', 'size', 'inferred', 'Integer', 'Integer')
]
CANDIDATES = <<~RBS
  class Game::Actor
    def hp: () -> Integer
    def name: () -> (Integer | String)
    def level: () -> Integer
    def maybe_nil: () -> (Integer | nil)
    def flag: () -> bool
    def flag_true: () -> TrueClass
    def flag_one: () -> bool
    def untyped_obs: () -> untyped
    def iface: () -> _Walker
    def self.make: () -> Integer
  end
  class Game::Party
    def size: () -> Integer
  end
  interface _Walker
    def walk: () -> untyped
  end
RBS
facts = { 'ir_feedback' => ROWS, 'contradictions' => [], 'annotations' => [], 'nilable_index' => [],
          'signature_diagnostics' => [], 'methods' => [], 'ivars' => [], 'constants' => [] }

puts 'fixture: which rows the candidates observe inside the contract'
observed = IrTraceEvidence.observed_returns(CANDIDATES)
check.call('an instance return union becomes its class set', observed[['Game::Actor', 'name']] == Set['Integer', 'String'])
check.call('nil and bool are read as their runtime classes', observed[['Game::Actor', 'maybe_nil']] == Set['Integer', 'NilClass'] &&
                                                             observed[['Game::Actor', 'flag']] == Set['TrueClass', 'FalseClass'])
check.call('an untyped or interface return has no observation', !observed.key?(['Game::Actor', 'untyped_obs']) && !observed.key?(['Game::Actor', 'iface']))
check.call('a singleton candidate is not observed as an instance method', !observed.key?(['Game::Actor', 'make']))

puts 'fixture: annotation'
annotated = IrTraceEvidence.annotate(facts, CANDIDATES)
by = lambda { |method, kind = 'return'| annotated['ir_feedback'].find { |r| r['method'] == method && r['kind'] == kind } }
check.call('a possible_mismatch whose observed returns fit the contract gets provenance trace', by.call('hp')['provenance'] == 'trace')
check.call('the trace row names the classes it observed', by.call('hp')['trace_classes'] == ['Integer'])
check.call('the trace row keeps status possible_mismatch (not inferred or declared)', by.call('hp')['status'] == 'possible_mismatch')
check.call('an observed excluded class keeps the row unmarked', by.call('name')['provenance'].nil?)
check.call('a mismatch row is never marked, even when its method was observed', by.call('level')['status'] == 'mismatch' && by.call('level')['provenance'].nil?)
check.call('a nil expectation covers an observed NilClass', by.call('maybe_nil')['provenance'] == 'trace')
check.call('bool covers both TrueClass and FalseClass only when the expectation names both', by.call('flag')['provenance'] == 'trace')
check.call('an expectation naming one of the two bool classes is not evidence', by.call('flag_one')['provenance'].nil?)
check.call('an exact TrueClass observation fitting a TrueClass contract is evidence', by.call('flag_true')['provenance'] == 'trace')
check.call('an untyped observation is not evidence', by.call('untyped_obs')['provenance'].nil?)
check.call('an interface observation is not evidence', by.call('iface')['provenance'].nil?)
check.call('an ivar store row is not a return and is not marked', by.call('hp', 'ivar_store')['provenance'].nil?)
check.call('a singleton owner is not matched by an instance candidate',
           annotated['ir_feedback'].find { |r| r['owner'] == 'Game::Actor.singleton' }['provenance'].nil?)
check.call('a row that is already inferred is untouched', by.call('size')['provenance'].nil? && by.call('size')['status'] == 'inferred')
check.call('the input facts are not mutated', ROWS.none? { |r| r.key?('provenance') })
check.call('no candidates leave the facts unchanged', IrTraceEvidence.annotate(facts, '').equal?(facts))

puts 'fixture: diagnostics'
diags = TypeCheckReport.diagnostics(annotated, [], all: false, top: 20, scope: 'engine')
tc1009 = diags.select { |d| d.code == 'TC1009' }
check.call('a trace-evidenced row is an info note TC1009, not a warning', tc1009.size == 4 && tc1009.all? { |d| d.severity == 'info' })
check.call('the note says the evidence came from a trace run', tc1009.all? { |d| d.message.include?('a trace run observed only') })
check.call('the other possible_mismatch rows stay TC1008 warnings', diags.count { |d| d.code == 'TC1008' } == 6)
check.call('the mismatch row stays TC1007 error', diags.any? { |d| d.code == 'TC1007' && d.message.include?('level') })
check.call('the mismatch row is still an error exit status', TypeCheckReport.exit_status(diags) == 1)
evidence_only = ROWS.select { |r| r['status'] == 'possible_mismatch' && r['kind'] == 'return' && %w[hp maybe_nil flag flag_true].include?(r['method']) }
only = facts.merge('ir_feedback' => evidence_only)
only_diags = TypeCheckReport.diagnostics(IrTraceEvidence.annotate(only, CANDIDATES), [], scope: 'engine')
check.call('trace-evidenced rows alone exit 0', TypeCheckReport.exit_status(only_diags) == 0 && only_diags.all? { |d| d.code == 'TC1009' })
  check.call('the same rows with no trace are warnings', TypeCheckReport.diagnostics(only, [], scope: 'engine').all? { |d| d.code == 'TC1008' })

puts 'fixture: the CLI reads --trace over saved facts'
Dir.mktmpdir('ir-trace-evidence-check') do |dir|
  facts_path = File.join(dir, 'facts.json')
  cand_path = File.join(dir, 'candidates.rbs')
  File.write(facts_path, JSON.generate(facts))
  File.write(cand_path, CANDIDATES)
  script = File.join(ROOT, 'scripts/bc2cpp/type_check.rb')
  out, _err, status = Open3.capture3(RbConfig.ruby, script, '--facts', facts_path, '--no-sends', '--trace', cand_path, '--all', '--format', 'json', '--out', File.join(dir, 'report.json'))
  report = JSON.parse(File.read(File.join(dir, 'report.json')))
  codes = report['diagnostics'].map { |d| d['code'] }
  check.call('the CLI emits TC1009 for the trace-evidenced rows', codes.count('TC1009') == 4)
  check.call('the CLI keeps the TC1007 error', codes.include?('TC1007') && status.exitstatus == 1)
  rows = report['ir_feedback'].select { |r| r['provenance'] == 'trace' }
  check.call('the JSON rows carry provenance trace with status possible_mismatch',
             rows.size == 4 && rows.all? { |r| r['status'] == 'possible_mismatch' })
  out2, _err2, status2 = Open3.capture3(RbConfig.ruby, script, '--facts', facts_path, '--no-sends', '-q')
  check.call('without --trace the same facts keep the TC1008 warnings and no TC1009',
             !out2.include?('TC1009') && out2.scan('TC1008').size == 10 && status2.exitstatus == 1)
end

puts
if failures.empty?
  puts "ir_trace_evidence_check: #{checks} checks passed"
else
  warn "ir_trace_evidence_check: #{failures.size} of #{checks} checks failed"
  exit 1
end
