# frozen_string_literal: true

# Only dependency-free evaluations can outlive one root's fixed-point graph.
class IrContextLeafEvaluations
  LIMIT = 128
  MAX_STATE_CELLS = 4096
  Snapshot = Struct.new(:value, :states, :calls, :arrays, :classes, :shapes, keyword_init: true) do
    def restore(node)
      node.states = states
      node.calls = calls
      node.arrays = arrays
      value
    end
  end

  def initialize
    @entries = {}
  end

  def fetch(key, classes:, shapes:)
    snapshot = @entries[key]
    snapshot if snapshot && snapshot.classes == classes && snapshot.shapes == shapes
  end

  def remember(key, node, value, classes:, shapes:)
    return unless node.states
    return if node.states.sum { |state| state ? state.size : 0 } > MAX_STATE_CELLS

    arrays = node.arrays.transform_values do |shape|
      shape.dup.tap { |copy| copy.elements = shape.elements&.dup&.freeze }.freeze
    end.freeze
    @entries.shift if !@entries.key?(key) && @entries.size >= LIMIT
    @entries[key] = Snapshot.new(value: value,
                                 states: node.states.map { |state| state&.dup&.freeze }.freeze,
                                 calls: node.calls.dup.freeze,
                                 arrays: arrays,
                                 classes: classes, shapes: shapes).freeze
  end
end
