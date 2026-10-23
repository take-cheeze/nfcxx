# frozen_string_literal: true

require 'fileutils'
require 'set'
require 'tmpdir'
require_relative 'type_check_rbs'

# TYPE_CHECK --iterate: each round's accepted returns are the candidate contracts of the next round. The rules are
# in docs/bc2cpp-ir-feedback.md#fixed-point-rounds-iterate-n.
module TypeCheckIterate
  Result = Struct.new(:rounds, :converged, :accepted, :analysis, :candidate_facts, keyword_init: true)
  # Derived exits may depend on return contracts only: `self-call:NAME` and `call-result:OWNER#NAME`.
  RETURN_CONTRACT = /\A(?:self-call:(?<sym>[^#:]+)|call-result:(?<owner>[^#]+)#(?<call>.+))\z/
  # Return sources that are inferred or derived by the analysis itself; any other source is a declaration.
  NOT_DECLARED = %w[inferred:bytecode-ir inferred:return-analysis derived:contracts].freeze

  module_function

  # Accepted return suggestions, [owner, method, type] sorted. `previous` is the set of [owner, method] accepted in the
  # previous round (empty in round 1).
  #
  # Soundness condition: a derived exit is accepted only when every contract it depends on is a return contract naming
  # a method accepted in the previous round. Round 1 has no candidates, and each round is built from the previous one,
  # so a cycle is never accepted from nothing.
  def suggestions(facts, previous, scope: 'engine')
    previous_keys = previous.to_set { |owner, method, _type| [owner, method] }
    declared = user_declared(facts, previous_keys)
    rows = Array(facts['ir_feedback']).select { |row| row['kind'] == 'return' && (scope == 'all' || row['scope'] == scope) }
    rows.group_by { |row| [row['owner'], row['method']] }.filter_map do |(owner, method), exits|
      next if declared.include?([owner, method])
      next unless exits.all? { |row| row['type'] && accepted_exit?(row, previous_keys, declared) }

      types = exits.flat_map { |row| row['type'].split(' | ') }.uniq.sort
      [owner, method, types.join(' | ')]
    end.sort
  end

  def accepted_exit?(row, previous_keys, declared)
    if row['status'] == 'declared'
      contracts = Array(row['contracts'])
      !contracts.empty? && contracts.all? { |contract| return_contract_accepted?(contract, previous_keys, declared) }
    else
      %w[inferred mismatch possible_mismatch].include?(row['status'])
    end
  end

  # `self-call:` names no owner: accepted only when a previous-round method has the name and no user declaration does.
  def return_contract_accepted?(contract, previous_keys, declared)
    match = RETURN_CONTRACT.match(contract)
    return false unless match

    if match[:sym]
      sym = match[:sym]
      previous_keys.any? { |_owner, method| method == sym } &&
        declared.none? { |_owner, method| method == sym }
    else
      previous_keys.include?([match[:owner], match[:call]])
    end
  end

  def user_declared(facts, previous_keys)
    Array(facts['methods']).each_with_object(Set.new) do |method, set|
      source = method.dig('return', 'source')
      next if source.nil? || NOT_DECLARED.include?(source)

      key = [method['owner'], method['name']]
      set << key unless previous_keys.include?(key)
    end
  end

  # Only accepted methods, with untyped parameters and no ivars or constants: nothing unaccepted can become a contract.
  def candidate_facts(facts, accepted)
    types = accepted.to_h { |owner, method, type| [[owner, method], type] }
    untyped = ->(param) { param.merge('type' => nil) }
    methods = Array(facts['methods']).filter_map do |method|
      type = types[[method['owner'], method['name']]]
      next unless type

      method.merge('params' => Array(method['params']).map(&untyped),
                   'optional_params' => Array(method['optional_params']).map(&untyped),
                   'keyword_params' => Array(method['keyword_params']).map(&untyped),
                   'return' => { 'type' => type, 'source' => 'iterate', 'reason' => nil })
    end
    facts.merge('methods' => methods, 'ivars' => [], 'constants' => [])
  end

  # The block gets the candidate directory (nil in round 1) and returns [facts, rows] of one analysis.
  def iterate(limit:, scope: 'engine')
    Dir.mktmpdir('bc2cpp_type_check_rounds') do |scratch|
      previous = []
      candidates = nil
      analysis = nil
      facts = nil
      rounds = 0
      loop do
        rounds += 1
        analysis = yield(candidates)
        facts = analysis.first
        accepted = suggestions(facts, previous, scope: scope)
        candidate = candidate_facts(facts, accepted)
        if accepted == previous
          return Result.new(rounds: rounds, converged: true, accepted: accepted, analysis: analysis, candidate_facts: candidate)
        end
        return Result.new(rounds: rounds, converged: false, accepted: accepted, analysis: analysis, candidate_facts: nil) if rounds >= limit

        previous = accepted
        candidates = File.join(scratch, "round-#{rounds}")
        FileUtils.mkdir_p(candidates)
        TypeCheckRbs.emit(candidate, candidates, scope: scope)
      end
    end
  end
end
