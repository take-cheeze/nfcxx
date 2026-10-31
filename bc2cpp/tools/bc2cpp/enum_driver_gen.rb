# frozen_string_literal: true

# ENUM_STEP drivers, generated from the body they replace (tools/bc2cpp/codegen_enum_step.rb). A Ruby-only form's driver is
# the owner's own method, with the same parameters and statements, renamed, and each `yield` made a block call on the
# method's &block. Generated from the source the body is compiled from, a driver cannot drift from its body.
#
# Refused, so the body is kept rather than rewritten inexactly: a body that asks for its block some other way (block_given?,
# super, a def that yields to an outer method), and one without an &block parameter, whose yield the rewrite needs.
require 'prism'

module EnumDriverGen
  class Refused < StandardError; end

  # Calls that read the method's block or frame, and so change meaning once the body is a driver.
  FRAME_CALLS = %w[block_given? binding __method__].freeze

  module_function

  # The driver source for +method+ of +owner+ in +mrblib_path+, named +driver_method+, as a class reopening +owner+.
  def driver_source(mrblib_path, owner, method, driver_method)
    source = File.read(mrblib_path, encoding: 'UTF-8')
    def_node = find_def(Prism.parse(source).value, owner, method) or raise Refused, "no def #{owner}##{method} in #{mrblib_path}"
    check_rewritable(def_node, source)
    text = rewrite(source, def_node, driver_method)
    <<~RUBY
      class #{owner}
      #{indent(text).rstrip}
        private :#{driver_method}
      end
    RUBY
  end

  # The DefNode of +owner+#+method+ among the top-level class bodies of +node+ (no nesting: the owners here are top-level).
  def find_def(node, owner, method)
    found = nil
    walk(node) do |n|
      next unless n.is_a?(Prism::ClassNode) && n.constant_path.is_a?(Prism::ConstantReadNode) && n.constant_path.name.to_s == owner
      n.body&.body&.each do |stmt|
        found = stmt if stmt.is_a?(Prism::DefNode) && stmt.name.to_s == method
      end
    end
    found
  end

  def check_rewritable(def_node, source)
    raise Refused, 'no &block parameter' unless def_node.parameters&.block

    walk(def_node) do |n|
      case n
      when Prism::DefNode
        raise Refused, "nested def #{n.name}" unless n.equal?(def_node)
      when Prism::SuperNode, Prism::ForwardingSuperNode
        raise Refused, 'super'
      when Prism::CallNode
        raise Refused, "#{n.name} reads the frame" if n.receiver.nil? && FRAME_CALLS.include?(n.name.to_s)
      end
    end
  end

  # The def's text with each yield made a block call, under the driver's name.
  def rewrite(source, def_node, driver_method)
    edits = []
    walk(def_node) do |n|
      next unless n.is_a?(Prism::YieldNode)

      args = n.arguments ? source.byteslice(n.arguments.location.start_offset, n.arguments.location.length) : ''
      edits << [n.location.start_offset, n.location.end_offset, args.empty? ? 'block.call' : "block.call(#{args})"]
    end
    text = source.byteslice(def_node.location.start_offset, def_node.location.length).dup
    base = def_node.location.start_offset
    edits.sort_by { |start, _, _| -start }.each do |start, stop, replacement|
      text = text.byteslice(0, start - base) + replacement + text.byteslice(stop - base, text.bytesize)
    end
    # The body lines sit at the def's column in the file; the driver is re-indented from zero.
    column = def_node.location.start_column
    lines = text.lines
    lines = [lines.first] + lines.drop(1).map { |line| line.sub(/\A {0,#{column}}/, '') }
    lines.join.sub(/\Adef #{def_node.name}\b/) { "def #{driver_method}" }
  end

  def indent(text) = text.lines.map { |line| line.strip.empty? ? "\n" : "  #{line}" }.join

  def walk(node, &block)
    return unless node.is_a?(Prism::Node)

    yield node
    node.compact_child_nodes.each { |child| walk(child, &block) }
  end
end
