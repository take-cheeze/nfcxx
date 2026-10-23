# frozen_string_literal: true

require 'set'
require_relative 'trace_merge'

# IR_TRACE_EVIDENCE: runtime evidence for `possible_mismatch` return rows. The static may-set of such a row holds
# allowed and excluded classes, and inference cannot tell whether the excluded ones are feasible. When the trace
# candidates (scripts/bc2cpp/trace_types.rb candidates) say the method's runtime returns were only ever instances of
# classes the contract allows, the row is marked `provenance: trace` and reported as an info note (TC1009).
#
# The row keeps status `possible_mismatch`: a trace run is evidence, not proof, so it never becomes `inferred` or
# `declared`. `mismatch` rows are never touched, so a class the static analysis proves excluded still raises TC1007.
#
# The join is by method (owner and name), not by site: the trace records no file or line for a return, and the
# candidates already drop overflowed sites and interfaces, so only a complete observation of the method counts.
module IrTraceEvidence
  CLASS_NAME = /\A[A-Z]\w*(?:::[A-Z]\w*)*\z/
  # The RBS spelling of a runtime class set (trace_types.rb RBS_CLASS): nil and bool stand for two classes each.
  RBS_NAMES = { 'nil' => %w[NilClass], 'bool' => %w[TrueClass FalseClass] }.freeze

  module_function

  # { [owner, method] => Set of runtime class names } for instance methods whose observed return is a plain union of
  # classes. An untyped, interface or generic return has no entry.
  def observed_returns(candidates_text)
    found, _interfaces = TraceMerge.members(candidates_text)
    found.each_with_object({}) do |member, observed|
      next if member.singleton

      classes = return_classes(member.signature)
      observed[[member.owner, member.name]] = classes if classes
    end
  end

  # The classes named by a candidate's return, or nil when any atom is not a class (or nil / bool).
  def return_classes(signature)
    text = signature.rpartition(' -> ').last.strip
    text = text[1..-2] if text.start_with?('(') && text.end_with?(')')
    atoms = text.split(' | ')
    return nil unless atoms.all? { |atom| RBS_NAMES.key?(atom) || atom.match?(CLASS_NAME) }

    atoms.flat_map { |atom| RBS_NAMES.fetch(atom, [atom]) }.to_set.freeze
  end

  # The runtime classes a row's nominal contract allows, from its `expected` text (BytecodeIR::Types.type_name).
  def expected_classes(text)
    text.split(' | ').flat_map { |atom| RBS_NAMES.fetch(atom, [atom]) }.to_set
  end

  # Returns facts whose possible_mismatch return rows carry `provenance: trace` and `trace_classes` where the trace
  # observed only contract classes for that method. Every other row, and the input itself, is left as it was.
  def annotate(facts, candidates_text)
    observed = observed_returns(candidates_text)
    return facts if observed.empty?

    rows = Array(facts['ir_feedback']).map do |row|
      next row unless row['status'] == 'possible_mismatch' && row['kind'] == 'return' && row['expected']

      classes = observed[[row['owner'], row['method']]]
      next row unless classes && classes.subset?(expected_classes(row['expected']))

      row.merge('provenance' => 'trace', 'trace_classes' => classes.to_a.sort)
    end
    facts.merge('ir_feedback' => rows)
  end
end
