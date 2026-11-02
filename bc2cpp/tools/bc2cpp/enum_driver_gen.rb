# frozen_string_literal: true

# ENUM_STEP drivers, generated from the body they replace (tools/bc2cpp/codegen_enum_step.rb). A Ruby-only form's driver is
# the owner's own method, with the same parameters and statements, renamed, and each `yield` made a block call on the
# method's &block. Generated from the source the body is compiled from, a driver cannot drift from its body.
#
# Refused, so the body is kept rather than rewritten inexactly: a body that asks for its block some other way (super, a
# def that yields to an outer method, a reassigned block), and one without an &block parameter, whose yield the rewrite
# needs. block_given? is exact in a driver that takes the block as a parameter: it becomes a test of that parameter.
require_relative 'ruby_parse_cache'

module EnumDriverGen
  class Refused < StandardError; end

  # Calls that read the method's frame, and so change meaning once the body is a driver. block_given? is not one of
  # them: the driver's own &block parameter answers it (rewrite).
  FRAME_CALLS = %w[binding __method__].freeze

  module_function

  # The driver source for +method+ of +owner+ in +mrblib_path+, named +driver_method+, reopening +owner+. With +line+, the
  # def must start on that line (the body the compiler saw, when the file has more than one def of the method).
  def driver_source(mrblib_path, owner, method, driver_method, line: nil)
    source = File.read(mrblib_path, encoding: 'UTF-8')
    found = find_def(RubyParseCache.parse(source, mrblib_path).value, owner, method, line) or raise Refused, "no def #{owner}##{method} in #{mrblib_path}"
    def_node, keyword = found
    check_rewritable(def_node, source)
    text = rewrite(source, def_node, driver_method)
    <<~RUBY
      #{keyword} #{owner}
      #{indent(text).rstrip}
        private :#{driver_method}
      end
    RUBY
  end

  # The [DefNode, 'class' | 'module'] of +owner+#+method+ among the top-level bodies of +node+ (no nesting). The owner is
  # matched by its constant path as written ("Enumerable", "Game::Actors"), and the def by its start line when given.
  def find_def(node, owner, method, line = nil)
    found = nil
    walk(node) do |n|
      next unless n.is_a?(Prism::ClassNode) || n.is_a?(Prism::ModuleNode)
      next unless n.constant_path.location.slice == owner

      n.body&.body&.each do |stmt|
        next unless stmt.is_a?(Prism::DefNode) && stmt.name.to_s == method
        next if line && stmt.location.start_line != line

        found = [stmt, n.is_a?(Prism::ModuleNode) ? 'module' : 'class']
      end
    end
    found
  end

  def check_rewritable(def_node, source)
    block = def_node.parameters&.block
    raise Refused, 'no named &block parameter' unless block&.name

    block_name = block.name.to_s
    walk(def_node) do |n|
      case n
      when Prism::DefNode
        raise Refused, "nested def #{n.name}" unless n.equal?(def_node)
      when Prism::SuperNode, Prism::ForwardingSuperNode
        raise Refused, 'super'
      when Prism::CallNode
        raise Refused, "#{n.name} reads the frame" if n.receiver.nil? && FRAME_CALLS.include?(n.name.to_s)
        raise Refused, 'block_given? with arguments' if n.receiver.nil? && n.name.to_s == 'block_given?' && n.arguments
      when Prism::LocalVariableWriteNode
        raise Refused, "#{block_name} is reassigned" if n.name.to_s == block_name
      end
    end
  end

  # The def's text with each yield made a call on its &block parameter, and each block_given? a test of it, under the
  # driver's name.
  def rewrite(source, def_node, driver_method)
    block_name = def_node.parameters.block.name.to_s
    edits = []
    walk(def_node) do |n|
      if n.is_a?(Prism::YieldNode)
        args = n.arguments ? source.byteslice(n.arguments.location.start_offset, n.arguments.location.length) : ''
        edits << [n.location.start_offset, n.location.end_offset, args.empty? ? "#{block_name}.call" : "#{block_name}.call(#{args})"]
      elsif n.is_a?(Prism::CallNode) && n.receiver.nil? && n.name.to_s == 'block_given?'
        edits << [n.location.start_offset, n.location.end_offset, "(!#{block_name}.nil?)"]
      end
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
    # The name is followed by its parameters, a space or the end of the line; \b would not match after ? or !.
    text = lines.join.sub(/\Adef #{Regexp.escape(def_node.name.to_s)}(?=[\s(;]|\z)/) { "def #{driver_method}" }
    raise Refused, "the def of #{def_node.name} was not renamed" unless text.start_with?("def #{driver_method}")

    text
  end

  def indent(text) = text.lines.map { |line| line.strip.empty? ? "\n" : "  #{line}" }.join

  def walk(node, &block)
    return unless node.is_a?(Prism::Node)

    yield node
    node.compact_child_nodes.each { |child| walk(child, &block) }
  end
end
