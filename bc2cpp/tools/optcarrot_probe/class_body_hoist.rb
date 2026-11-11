# frozen_string_literal: true

require 'prism'
require 'set'

# CLASS_BODY_HOIST: a class body runs once, before OptcarrotBenchmark.run installs the compiled methods, so a constant
# initializer that loops through blocks stays interpreted (PPU::TILE_LUT alone is two million block calls). This
# rewrites such an initializer into a singleton method of the same class, which bc2cpp compiles like any other method,
# and assigns the constant from a call to it once OptcarrotProbe.install_hoisted! has put the compiled body in.
#
# The method body is the initializer's own text, run with the same self (the class) and the same lexical scope, so it
# reads the same constants in the same order. An initializer stays as it is when moving it could change its meaning
# (see SafetyWalk). Everything stays on the initializer's own lines, so later line numbers do not move.
module ClassBodyHoist
  PREFIX = '__bc2cpp_init_'

  module_function

  # [rewritten source, hoisted method names in source order].
  def rewrite(source)
    result = Prism.parse(source)
    raise "ClassBodyHoist: cannot parse the bundle: #{result.errors.first.message}" unless result.success?

    edits = []
    each_body_statement(result.value) do |owner, statement|
      targets, value = constant_initializer(statement)
      next unless value && SafetyWalk.hoistable?(value)

      edits << [owner, statement, value, targets]
    end
    names = Hash.new { |hash, owner| hash[owner] = Set.new }
    planned = edits.map do |owner, statement, value, targets|
      [statement, value, unique_name(names[owner], targets)]
    end
    out = source.b
    planned.reverse_each do |statement, value, name|
      assign = source.byteslice(statement.location.start_offset...value.location.start_offset)
      suffix = "; end; OptcarrotProbe.install_hoisted!(self, :#{name}); #{assign}#{name}"
      out[value.location.end_offset, 0] = suffix
      out[statement.location.start_offset...value.location.start_offset] = "def self.#{name}() "
    end
    [out.force_encoding(source.encoding), planned.map(&:last)]
  end

  # Yields [owner path, statement] for each statement directly in a class or module body. `class << self` bodies are
  # skipped: their self is the singleton class, which a `def self.` in them would not be.
  def each_body_statement(node, path = [], &block)
    case node
    when Prism::ClassNode, Prism::ModuleNode
      inner = path + [node.constant_path.slice]
      Array(node.body&.body).each do |statement|
        yield inner.join('::'), statement
        each_body_statement(statement, inner, &block)
      end
    when Prism::SingletonClassNode, Prism::DefNode
      nil
    else
      node.compact_child_nodes.each { |child| each_body_statement(child, path, &block) }
    end
  end

  # [target names, value] for `NAME = value` or `A, B = value` (plain constant targets only), else nil.
  def constant_initializer(statement)
    case statement
    when Prism::ConstantWriteNode
      [[statement.name.to_s], statement.value]
    when Prism::MultiWriteNode
      return unless statement.rest.nil? && statement.rights.empty?
      return unless statement.lefts.all?(Prism::ConstantTargetNode)

      [statement.lefts.map { |target| target.name.to_s }, statement.value]
    end
  end

  def unique_name(taken, targets)
    base = "#{PREFIX}#{targets.join('_').downcase.gsub(/[^a-z0-9_]/, '_')}"
    name = base
    name = "#{base}_#{taken.size}" while taken.include?(name)
    taken << name
    name
  end

  # Whether an initializer means the same inside `def self.x() ... end` as in the class body. It must loop through a
  # block (the only case worth a compiled method) and must not:
  # - touch a local of the class body (a method cannot see it): a local whose depth reaches past the blocks it sits in;
  # - call without a receiver: the body may define that method after this line, and the class body's private
  #   helpers (`attr_reader`, `include`) are not the singleton method's;
  # - use yield, super, return, block_given?-style keywords, a nested def or class, or a constant assignment (dynamic
  #   in a method);
  # - use __LINE__ or a heredoc, whose text lies outside the value's source range.
  module SafetyWalk
    REFUSED = [
      Prism::YieldNode, Prism::SuperNode, Prism::ForwardingSuperNode, Prism::ReturnNode, Prism::DefNode,
      Prism::ClassNode, Prism::ModuleNode, Prism::SingletonClassNode, Prism::SourceLineNode,
      Prism::ConstantWriteNode, Prism::ConstantPathWriteNode, Prism::ConstantOperatorWriteNode,
      Prism::ConstantOrWriteNode, Prism::ConstantAndWriteNode, Prism::ConstantPathOperatorWriteNode,
      Prism::ConstantPathOrWriteNode, Prism::ConstantPathAndWriteNode, Prism::ConstantTargetNode,
      Prism::ConstantPathTargetNode, Prism::ForwardingArgumentsNode
    ].freeze
    SCOPES = [Prism::BlockNode, Prism::LambdaNode].freeze
    LOCALS = [
      Prism::LocalVariableReadNode, Prism::LocalVariableWriteNode, Prism::LocalVariableTargetNode,
      Prism::LocalVariableOperatorWriteNode, Prism::LocalVariableOrWriteNode, Prism::LocalVariableAndWriteNode
    ].freeze

    module_function

    def hoistable?(value)
      blocks = 0
      safe = walk(value, 0) { blocks += 1 }
      safe && blocks.positive?
    end

    # Yields once per block scope found; false as soon as a refused node turns up.
    def walk(node, scopes, &on_block)
      return false if REFUSED.any? { |klass| node.is_a?(klass) }
      return false if LOCALS.any? { |klass| node.is_a?(klass) } && node.depth >= scopes
      return false if node.is_a?(Prism::CallNode) && node.receiver.nil?
      return false if heredoc?(node)

      inner = scopes
      if SCOPES.any? { |klass| node.is_a?(klass) }
        yield
        inner += 1
      end
      node.compact_child_nodes.all? { |child| walk(child, inner, &on_block) }
    end

    def heredoc?(node)
      (node.is_a?(Prism::StringNode) || node.is_a?(Prism::InterpolatedStringNode) ||
        node.is_a?(Prism::XStringNode) || node.is_a?(Prism::InterpolatedXStringNode)) && node.heredoc?
    end
  end
end
