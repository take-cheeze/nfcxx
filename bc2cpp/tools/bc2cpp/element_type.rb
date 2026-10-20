# frozen_string_literal: true

require_relative 'numeric_flow'

# ElementType: the generic type term `Array[T]` / `Hash[K, V]` one level deep. A type is either a class mask
# (NumericFlow, an Integer) or a Generic term: its container's class bit and one element mask per parameter
# (Array: [elem], Hash: [key, value]). A parameter mask of nil is unknown, so `Array[untyped]`.
#
# Depth is one on purpose: a parameter is a class mask, never another Generic. Joins never grow the term, so the
# fixpoint terminates without a widening rule. Two terms with different containers join to their plain class mask.
module ElementType
  Generic = Struct.new(:container, :params) do
    def arity = params.size
  end

  ARITY = { NumericFlow::ARR => 1, NumericFlow::HSH => 2 }.freeze

  module_function

  # The join of two types. A plain mask absorbs the container bit of a Generic it meets.
  def join(a, b)
    return classes(a) | classes(b) unless a.is_a?(Generic) && b.is_a?(Generic)
    return a.container | b.container unless a.container == b.container

    Generic.new(a.container, a.params.zip(b.params).map { |x, y| join_param(x, y) })
  end

  # The class mask a type can take, with its parameters forgotten.
  def classes(type)
    type.is_a?(Generic) ? type.container : type
  end

  # The mask of parameter +index+ of a type, or nil when the type has none or the parameter is unknown.
  def param(type, index)
    return nil unless type.is_a?(Generic)

    type.params[index]
  end

  # A Generic of +container+ with the given parameter masks; nil parameters are unknown.
  def generic(container, *params)
    raise ArgumentError, "#{container} takes #{ARITY.fetch(container)} parameter(s)" unless params.size == ARITY.fetch(container)
    raise ArgumentError, 'a parameter is a class mask, not a term' if params.any? { |p| p.is_a?(Generic) }

    Generic.new(container, params)
  end

  # Parameters join to unknown when either side is unknown: nil absorbs.
  def join_param(x, y)
    return nil if x.nil? || y.nil?

    x | y
  end
end
