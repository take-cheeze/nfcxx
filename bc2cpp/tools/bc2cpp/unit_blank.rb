# frozen_string_literal: true

require 'prism'
require 'set'

# UNIT_BLANK: the residual mrblib a compiled gem's VM loads. A top-level class or module statement whose unit the gem's
# generation emitted (CodeGen#compile_top_class_units, listed in the gem's *_units.txt manifest) is removed from the copy,
# because the unit creates and fills that class from gem_init. Every other statement is kept byte for byte.
module UnitBlank
  module_function

  def manifest_paths(manifest)
    return Set.new unless File.exist?(manifest)

    File.readlines(manifest, chomp: true).reject(&:empty?).to_set
  end

  # Core classes the closed build defines natively, so `Object.const_defined?(:X)` is true for them at load: a guarded
  # class statement whose guard names one of these is constant-folded to its class statement (FOLDED_GUARD).
  NATIVE_CORE = %w[Object Integer Float Numeric Array Hash Range String Symbol Comparable Enumerable Kernel].freeze

  # The class or module a top-level statement opens, when it is one: a plain `class X ... end`, or
  # `class X ... end if Object.const_defined?(:Y)` with Y a native core class (FOLDED_GUARD: the guard is true, so the
  # statement is the class). nil for anything else.
  def opened_class(stmt)
    case stmt
    when Prism::ClassNode, Prism::ModuleNode
      stmt.constant_path.slice
    when Prism::IfNode
      return nil unless stmt.subsequent.nil? && stmt.statements&.body&.size == 1

      body = stmt.statements.body.first
      return nil unless body.is_a?(Prism::ClassNode) || body.is_a?(Prism::ModuleNode)
      return nil unless guard_true?(stmt.predicate)

      body.constant_path.slice
    end
  end

  # `Object.const_defined?(:Y)` with Y a native core class.
  def guard_true?(node)
    return false unless node.is_a?(Prism::CallNode) && node.name == :const_defined? && node.arguments
    return false unless node.receiver.is_a?(Prism::ConstantReadNode) && node.receiver.name == :Object

    arg = node.arguments.arguments.first
    arg.is_a?(Prism::SymbolNode) && NATIVE_CORE.include?(arg.unescaped)
  end

  # The copy of +text+ without the top-level class and module statements named in +paths+.
  def blank(text, paths)
    root = Prism.parse(text).value
    spans = (root.statements&.body || []).filter_map do |stmt|
      name = opened_class(stmt)
      next unless name && paths.include?(name)

      [stmt.location.start_offset, stmt.location.end_offset]
    end
    bytes = text.b.dup
    spans.sort.reverse_each { |from, to| bytes[from...to] = '' }
    bytes
  end

  def write(src, dst, manifest)
    text = File.binread(src)
    File.binwrite(dst, blank(text, manifest_paths(manifest)))
  end
end
