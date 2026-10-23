#!/usr/bin/env ruby
# frozen_string_literal: true

# TYPE_CHECK --iterate: the round loop and its acceptance rule, on a model of the analysis. The model answers the
# two questions the loop asks of the real analysis: whether a return is derived from a declared callee, and what
# the candidate directory declares. Running the real analysis needs MRBC (scripts/bc2cpp/type_check.rb).

require 'tmpdir'
require 'set'
require_relative '../../tools/bc2cpp/type_check_iterate'
require_relative '../../tools/bc2cpp/type_check_rbs'

$failures = []
$checks = 0

def check(label, condition)
  $checks += 1
  puts "#{condition ? 'ok  ' : 'FAIL'} #{label}"
  $failures << label unless condition
end

def method_fact(owner, name, type: nil, source: nil)
  { 'owner' => owner, 'name' => name, 'visibility' => 'public', 'params' => [], 'optional_params' => [],
    'keyword_params' => [], 'opt' => 0, 'rest' => false, 'key' => 0, 'kdict' => false, 'scope' => 'engine',
    'file' => 'calc.rb', 'line' => 1, 'col' => 1, 'return' => { 'type' => type, 'source' => source, 'reason' => nil } }
end

def return_row(owner, method, status, type, contracts)
  { 'owner' => owner, 'method' => method, 'kind' => 'return', 'detail' => 'return', 'file' => 'calc.rb', 'line' => 1,
    'col' => 1, 'scope' => 'engine', 'status' => status, 'type' => type, 'contracts' => contracts, 'reason' => nil }
end

def program(methods, rows)
  { 'classes' => [{ 'name' => 'Calc', 'kind' => 'class', 'superclass' => nil }], 'methods' => methods,
    'ivars' => [], 'constants' => [], 'ir_feedback' => rows }
end

# The return types a candidate directory declares, by method name (one class per fixture).
def declared_returns(dir)
  return {} unless dir

  Dir.glob(File.join(dir, '**', '*.rbs')).each_with_object({}) do |path, found|
    File.read(path).each_line do |line|
      found[Regexp.last_match(1)] = Regexp.last_match(2) if line =~ /def (\w+): .* -> (\w+)\s*\z/
    end
  end
end

# Chain: b returns an Integer literal (inferred); a returns b() and is derived only through b's declared return.
CHAIN = lambda do |candidates|
  declared = declared_returns(candidates)
  b_declared = declared.key?('b')
  methods = [method_fact('Calc', 'b', type: 'Integer', source: b_declared ? 'signature' : 'inferred:bytecode-ir'),
             method_fact('Calc', 'a', type: b_declared ? 'Integer' : nil, source: b_declared ? 'derived:contracts' : nil)]
  rows = [return_row('Calc', 'b', 'inferred', 'Integer', [])]
  rows << (b_declared ? return_row('Calc', 'a', 'declared', 'Integer', ['self-call:b']) : return_row('Calc', 'a', 'unknown', nil, []))
  [program(methods, rows), []]
end

# Cycle: a depends on b's return and b on a's, with no inferred exit anywhere. Nothing may justify either one.
CYCLE = lambda do |candidates|
  declared = declared_returns(candidates)
  methods = [method_fact('Calc', 'a', type: declared.key?('b') ? 'Integer' : nil, source: declared.key?('b') ? 'derived:contracts' : nil),
             method_fact('Calc', 'b', type: declared.key?('a') ? 'Integer' : nil, source: declared.key?('a') ? 'derived:contracts' : nil)]
  rows = [return_row('Calc', 'a', declared.key?('b') ? 'declared' : 'unknown', declared.key?('b') ? 'Integer' : nil,
                     declared.key?('b') ? ['self-call:b'] : []),
          return_row('Calc', 'b', declared.key?('a') ? 'declared' : 'unknown', declared.key?('a') ? 'Integer' : nil,
                     declared.key?('a') ? ['self-call:a'] : [])]
  [program(methods, rows), []]
end

# 1. Round loop on the chain: round 1 accepts b, round 2 adds a, round 3 reproduces round 2.
chain = TypeCheckIterate.iterate(limit: 10, &CHAIN)
check('chain converges', chain.converged)
check('chain takes three rounds (b, then a, then a repeat)', chain.rounds == 3)
check('chain accepts a and b with their types',
      chain.accepted == [['Calc', 'a', 'Integer'], ['Calc', 'b', 'Integer']])
check('converged candidate facts carry both methods with untyped parameters',
      chain.candidate_facts['methods'].map { |m| m['name'] }.sort == %w[a b] &&
      chain.candidate_facts['ivars'].empty? && chain.candidate_facts['constants'].empty?)

# 2. The chain under a limit of two rounds stops before the repeat and writes nothing.
short = TypeCheckIterate.iterate(limit: 2, &CHAIN)
check('limit of two rounds reports not converged', !short.converged && short.rounds == 2)
check('not converged yields no candidate facts', short.candidate_facts.nil?)

# 3. The cycle never justifies itself: nothing is accepted and the loop converges in one round.
cycle = TypeCheckIterate.iterate(limit: 10, &CYCLE)
check('cycle converges in one round', cycle.converged && cycle.rounds == 1)
check('cycle accepts nothing', cycle.accepted.empty? && cycle.candidate_facts['methods'].empty?)

# 4. Acceptance rule on hand-built facts.
owner_b = method_fact('Calc', 'b', type: 'Integer', source: 'inferred:bytecode-ir')
user_arg = program([method_fact('Calc', 'c')], [return_row('Calc', 'c', 'declared', 'Integer', ['argument:R1'])])
check('a derived exit on a user argument contract is refused',
      TypeCheckIterate.suggestions(user_arg, []).empty?)
mixed = program([owner_b, method_fact('Calc', 'a')],
                [return_row('Calc', 'a', 'inferred', 'Integer', []),
                 return_row('Calc', 'a', 'declared', 'Integer', ['call-result:Calc#b'])])
check('one unjustified derived exit refuses the whole method',
      TypeCheckIterate.suggestions(mixed, []).none? { |o, m, _| o == 'Calc' && m == 'a' })
prev = [['Calc', 'b', 'Integer']]
call_result = program([owner_b, method_fact('Calc', 'a')],
                      [return_row('Calc', 'a', 'declared', 'Integer', ['call-result:Calc#b'])])
check('call-result contract is accepted when its target was accepted last round',
      TypeCheckIterate.suggestions(call_result, prev).include?(['Calc', 'a', 'Integer']))
check('call-result contract is refused without the previous round',
      TypeCheckIterate.suggestions(call_result, []).none? { |_, m, _| m == 'a' })
other = method_fact('Other', 'b', type: 'String', source: 'signature')
ambiguous = program([owner_b, other, method_fact('Calc', 'a')],
                    [return_row('Calc', 'a', 'declared', 'Integer', ['self-call:b'])])
check('self-call contract is refused when a user declaration shares the name',
      TypeCheckIterate.suggestions(ambiguous, [['Calc', 'b', 'Integer']]).none? { |_, m, _| m == 'a' })
annotated = program([method_fact('Calc', 'c', type: 'Integer', source: 'annotation')],
                    [return_row('Calc', 'c', 'inferred', 'Integer', [])])
check('a method the user declares is not suggested',
      TypeCheckIterate.suggestions(annotated, []).empty?)

# 5. The candidate directory holds only accepted returns, and its RBS parses.
Dir.mktmpdir('type_check_iterate_check') do |dir|
  facts = program([method_fact('Calc', 'b', type: 'Integer', source: 'inferred:bytecode-ir'),
                   method_fact('Calc', 'a', type: 'Integer', source: 'derived:contracts')],
                  [return_row('Calc', 'b', 'inferred', 'Integer', [])])
  accepted = TypeCheckIterate.suggestions(facts, [])
  emitted = TypeCheckRbs.emit(TypeCheckIterate.candidate_facts(facts, accepted), dir)
  text = emitted[:files].map { |path| File.read(path) }.join
  check('candidate file declares the accepted return', text.include?('def b: () ?{ (*untyped) -> untyped } -> Integer'))
  check('candidate file omits the unaccepted derived return', !text.include?('def a:'))
  check('candidate file declares no ivars', !text.include?('@'))
  check('candidate file has no skipped members', emitted[:skipped].empty?)
  require 'rbs'
  parsed = emitted[:files].all? { |path| RBS::Parser.parse_signature(File.read(path)) && true }
  check('candidate files parse as RBS', parsed)
end

puts "#{$checks - $failures.size} of #{$checks} checks passed"
exit 1 unless $failures.empty?
