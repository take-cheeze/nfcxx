#!/usr/bin/env ruby
# frozen_string_literal: true

# Candidate provenance comments and the ranked unknown-reason report, from hand-built facts (no MRBC needed).
require 'json'
require 'open3'
require 'rbconfig'
require 'tmpdir'
require 'rbs'
require_relative '../../tools/bc2cpp/type_check_rbs'
require_relative '../../tools/bc2cpp/type_check_report'

ROOT = File.expand_path('../..', __dir__)

def method_fact(owner, name, file, line, source:, type: nil, visibility: nil, contracts: nil, scope: 'engine')
  ret = { 'type' => type, 'source' => source, 'reason' => type ? nil : 'no_exit' }
  ret['contracts'] = contracts if contracts
  { 'owner' => owner, 'name' => name, 'file' => file, 'line' => line, 'col' => 1, 'scope' => scope,
    'req' => 0, 'opt' => 0, 'rest' => false, 'key' => 0, 'kdict' => false, 'visibility' => visibility,
    'params' => [], 'optional_params' => [], 'keyword_params' => [], 'return' => ret, 'annotated' => false }
end

def exit_row(owner, method, file, line, status:, type: 'Integer', contracts: [])
  { 'owner' => owner, 'method' => method, 'kind' => 'return', 'detail' => 'return', 'file' => file,
    'line' => line, 'col' => 1, 'scope' => 'engine', 'status' => status, 'type' => type, 'expected' => nil,
    'compatibility' => nil, 'contracts' => contracts, 'reason' => nil }
end

def unknown_row(reason, file, line, scope: 'engine')
  { 'owner' => 'Base', 'method' => 'probe', 'kind' => 'receiver', 'detail' => 'probe', 'file' => file,
    'line' => line, 'col' => 1, 'scope' => scope, 'status' => 'unknown', 'type' => nil, 'expected' => nil,
    'compatibility' => nil, 'contracts' => [], 'reason' => reason }
end

base = 'lib/base.rb'
child = 'lib/child.rb'
facts = {
  'version' => 1,
  'classes' => [{ 'name' => 'Base', 'kind' => 'class', 'superclass' => nil },
                { 'name' => 'Child', 'kind' => 'class', 'superclass' => 'Base' }],
  'methods' => [
    method_fact('Base', 'items', base, 2, source: 'inferred:bytecode-ir', type: 'Array[String]'),
    method_fact('Base', 'pick', base, 10, source: 'inferred:bytecode-ir', type: 'Integer'),
    method_fact('Base', 'pick', base, 20, source: 'inferred:bytecode-ir', type: 'Integer | String'),
    method_fact('Child', 'items', child, 3, source: 'derived:contracts', type: 'Integer',
                contracts: ['Base#items', 'Base#size', 'Base#extra', 'Base#more']),
    method_fact('Child', 'helper', child, 12, source: 'inferred:return-analysis', type: 'String', visibility: 'private'),
    method_fact('Child', 'blank', child, 15, source: nil),
    method_fact('Child', 'named', child, 18, source: 'signature', type: 'Integer'),
    method_fact('Base', 'other_scope', 'lib/other.rb', 1, source: nil, scope: 'core')
  ],
  'ivars' => [{ 'owner' => 'Base', 'name' => '@items', 'type' => 'Array[String]', 'source' => 'signature',
                'file' => base, 'line' => 2, 'col' => 1, 'scope' => 'engine', 'reason' => nil }],
  'constants' => [], 'contradictions' => [], 'annotations' => [], 'nilable_index' => [], 'signature_diagnostics' => [],
  'ir_feedback' => [
    exit_row('Base', 'items', base, 4, status: 'inferred', type: 'Array[String]'),
    exit_row('Base', 'pick', base, 12, status: 'inferred', type: 'Integer'),
    exit_row('Base', 'pick', base, 23, status: 'possible_mismatch', type: 'Integer | String'),
    exit_row('Child', 'items', child, 5, status: 'declared', contracts: ['Base#items']),
    # Ranking input: reasons tie on count (sorted by name), one reason has no recorded reason, and one
    # unknown row sits outside the engine scope.
    unknown_row('unsupported:RETURN_BLK', 'lib/a.rb', 2), unknown_row('unsupported:RETURN_BLK', 'lib/a.rb', 9),
    unknown_row('unsupported:RETURN_BLK', 'lib/b.rb', 3),
    unknown_row('unsupported:block-exit-or-handler', 'lib/c.rb', 1), unknown_row('unsupported:block-exit-or-handler', 'lib/c.rb', 2),
    unknown_row('unsupported:block-exit-or-handler', 'lib/c.rb', 3), unknown_row('unsupported:block-exit-or-handler', 'lib/d.rb', 1),
    unknown_row('unsupported:block-exit-or-handler', 'lib/e.rb', 1), unknown_row('unsupported:block-exit-or-handler', 'lib/g.rb', 1),
    unknown_row('beta:x', 'lib/f.rb', 1), unknown_row('beta:x', 'lib/f.rb', 2),
    unknown_row('alpha:y', 'lib/g.rb', 4), unknown_row('alpha:y', 'lib/g.rb', 5),
    unknown_row(nil, 'lib/h.rb', 1),
    unknown_row('excluded:core-row', 'lib/other.rb', 1, scope: 'core')
  ]
}

# The comment line directly above each emitted def, per class.
expected = {
  'Base' => { 'items' => ['# bc2cpp: return from lib/base.rb:4 (inferred)'],
              'pick' => ['# bc2cpp: return from lib/base.rb:12 (inferred)',
                         '# bc2cpp: return from lib/base.rb:23 (inferred; possible_mismatch)'] },
  'Child' => { 'items' => ['# bc2cpp: return from lib/child.rb:5 (derived: contracts Base#items, Base#size, Base#extra, +1 more)'],
               'helper' => ['# bc2cpp: return from def at lib/child.rb:12 (inferred: return-analysis)'],
               'blank' => ['# bc2cpp: return from def at lib/child.rb:15 (untyped)'],
               'named' => ['# bc2cpp: return from def at lib/child.rb:18 (declared: signature)'] }
}

# The declarations of a parsed signature: parse_signature returns [buffer, directives, declarations].
def decls_of(text)
  RBS::Parser.parse_signature(text)[2]
end

# The parsed shape of a candidate, without comments or locations.
def shape(decls)
  decls.map do |decl|
    members = decl.members.map do |m|
      case m
      when RBS::AST::Members::MethodDefinition then [:def, m.name, m.kind, m.overloads.map { |o| o.method_type.to_s }]
      when RBS::AST::Members::Private then [:private]
      when RBS::AST::Members::InstanceVariable then [:ivar, m.name, m.type.to_s]
      else [m.class.name]
      end
    end
    [decl.class.name, decl.name.to_s, decl.respond_to?(:super_class) ? decl.super_class&.name&.to_s : nil, members]
  end
end

failures = []
check = ->(label, ok) { failures << label unless ok }

Dir.mktmpdir('type-check-provenance') do |dir|
  candidates = File.join(dir, 'candidates')
  emitted = TypeCheckRbs.emit(facts, candidates, scope: 'engine')
  check.call("all seven engine methods emitted (got #{emitted[:methods]})", emitted[:methods] == 7)

  expected.each do |owner, methods|
    path = File.join(candidates, "#{owner}.rbs")
    text = File.read(path)
    lines = text.lines.map(&:chomp)
    methods.each do |name, comments|
      defs = lines.each_index.select { |i| lines[i].match?(/\A\s*def #{Regexp.escape(name)}:/) }
      check.call("#{owner}##{name} is emitted #{comments.size} time(s)", defs.size == comments.size)
      defs.zip(comments).each do |index, comment|
        check.call("#{owner}##{name} has its comment directly above: #{comment}", lines[index - 1]&.strip == comment)
      end
    end
    parsed = decls_of(text)
    bare = decls_of(text.lines.reject { |line| line.include?('# bc2cpp:') }.join)
    check.call("#{owner}.rbs parses as RBS", parsed.size == 1)
    check.call("#{owner}.rbs parse is unchanged by the comments", shape(parsed) == shape(bare))
    attached = parsed.first.members.filter_map { |m| m.comment&.string&.strip if m.respond_to?(:comment) && m.comment }
    check.call("#{owner}.rbs attaches each comment to its method", attached.size == methods.values.flatten.size &&
                                                                  attached.all? { |c| c.start_with?('bc2cpp: return from ') })
  end

  # Suggestion candidates use the same provenance; a derived return is never an independent suggestion.
  suggestions = File.join(dir, 'suggestions')
  TypeCheckRbs.emit(TypeCheckRbs.suggestion_facts(facts, scope: 'engine'), suggestions, scope: 'engine')
  check.call('suggestion candidate names the possible_mismatch exit',
             File.read(File.join(suggestions, 'Base.rbs')).include?('# bc2cpp: return from lib/base.rb:23 (inferred; possible_mismatch)'))

  # The command line renders the same facts and writes the suggestion candidates without MRBC.
  facts_path = File.join(dir, 'facts.json')
  File.write(facts_path, JSON.generate(facts))
  cli_out = File.join(dir, 'cli-suggestions')
  stdout, stderr, status = Open3.capture3(RbConfig.ruby, File.join(ROOT, 'scripts/bc2cpp/type_check.rb'), '--facts', facts_path,
                                          '--no-sends', '--emit-rbs-suggestions', cli_out, chdir: ROOT)
  check.call("CLI renders and emits (status #{status.exitstatus}: #{stderr.lines.first.to_s.strip})", status.success?)
  check.call('CLI suggestion candidate for Base keeps the inferred provenance',
             File.read(File.join(cli_out, 'Base.rbs')).include?('# bc2cpp: return from lib/base.rb:4 (inferred)'))
  check.call('CLI candidate for Child keeps the derived provenance',
             File.read(File.join(cli_out, 'Child.rbs')).include?(expected['Child']['items'].first))

  # Unknown reasons, most frequent first (ties by name), each with the files it hits; engine rows only.
  expected_block = <<~TEXT
    -- IR queries left unknown, ranked by reason (count; files hit) --
         6  unsupported:block-exit-or-handler
            in lib/c.rb (3), lib/d.rb (1), lib/e.rb (1), +1 more
         3  unsupported:RETURN_BLK
            in lib/a.rb (2), lib/b.rb (1)
         2  alpha:y
            in lib/g.rb (2)
         2  beta:x
            in lib/f.rb (2)
         1  (none)
            in lib/h.rb (1)
  TEXT
  check.call('CLI text output carries the ranked block', stdout.include?(expected_block))
  summary = TypeCheckReport.summary(facts)
  text = TypeCheckReport.text(facts, [], TypeCheckReport.diagnostics(facts, []), summary, sends: false)
  check.call('report text carries the ranked block', text.include?(expected_block))
  check.call('core-scope unknown rows stay out of the engine ranking', !text.include?('excluded:core-row'))
  json = JSON.parse(TypeCheckReport.json(facts, [], TypeCheckReport.diagnostics(facts, []), summary))
  check.call('JSON keeps its key set',
             json.keys.sort == %w[annotations constants diagnostics ir_feedback ivars methods native_direct_forms rbs_suggestions scope suggestions summary version])
end

if failures.empty?
  puts 'type-check candidate provenance, parse-equivalence and unknown-reason ranking checks passed'
else
  warn "type-check provenance checks failed:\n  #{failures.join("\n  ")}"
  exit 1
end
