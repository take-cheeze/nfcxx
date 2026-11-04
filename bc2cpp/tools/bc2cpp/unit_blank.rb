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

  # The copy of +text+ without the top-level class and module statements named in +paths+.
  def blank(text, paths)
    root = Prism.parse(text).value
    spans = (root.statements&.body || []).filter_map do |stmt|
      next unless stmt.is_a?(Prism::ClassNode) || stmt.is_a?(Prism::ModuleNode)
      next unless paths.include?(stmt.constant_path.slice)

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
