# frozen_string_literal: true

# CLASS_BODY_SCAN: what the statements of a gem's class and module bodies are. A body is the code between
# `class X` and its `end` (and a gem's top level, its root); the VM runs it once while the mrblib loads. Whether a
# body can be compiled (LoadCompile) rests on its statements alone, so this file names the forms the compiler
# understands and sorts every other statement into the reason it blocks:
#
#   declarative       nested class/module/`class << self` bodies, include/extend/prepend of constants,
#                     attr_*, alias/alias_method, private/public/protected/module_function, private_constant
#   def               a method definition (compiled, stubbed or kept bytecode: LoadCompile decides by name)
#   const_literal     `X = <literal>`: Integer, Float, String, Symbol, nil/true/false, and Array/Hash/Range of
#                     those, with or without `.freeze`
#   const_pure        `X = <pure expression>`: constants, literals and block-less calls on them (`A::B * 2`,
#                     `Color.new(1, 2, 3, 4)`, `OTHER.merge(...)`): everything LoadCompile can evaluate in order
#   class_ivar        `@x = <pure expression>` in a class body
#   const_computed    `X = <anything else>`
#   dsl_call          any other call: a registration helper, define_method, `Foo.bar`
#   proc              a statement that builds a block, lambda or proc
#   runtime           reads the environment: ENV, File, a global, RUBY_PLATFORM
#   control           if/unless/case/while around other statements
#   other             anything else (a local variable, an instance variable of the class)
#
# The statements are the direct children of a body; method bodies are not entered. Statement#node keeps the Prism
# node for the emitter.
require 'prism'
require 'set'

module ClassBodyScan
  module_function

  Statement = Struct.new(:category, :detail, :file, :line, :node, :child, keyword_init: true) do
    def label = detail ? "#{category}(#{detail})" : category.to_s
  end
  # kind: :root, :class, :module, :sclass. path: the lexical nesting as a constant path, "" for the root.
  Body = Struct.new(:kind, :path, :file, :line, :superclass, :statements, :children, :node, keyword_init: true) do
    def each_body(&block)
      block.call(self)
      children.each { |c| c.each_body(&block) }
    end

    def name = path.empty? ? '<root>' : path
  end

  # Statements of these categories can be compiled; the others keep the body bytecode.
  COMPILABLE = %i[declarative def const_literal const_pure class_ivar].freeze
  MIXINS = %w[include extend prepend].freeze
  ATTRS = %w[attr attr_reader attr_writer attr_accessor].freeze
  MODES = %w[private public protected module_function].freeze
  CONST_VISIBILITY = %w[private_constant public_constant private_class_method public_class_method].freeze
  # Reading any of these ties the load to the machine it runs on.
  RUNTIME_CONSTS = %w[ENV ARGV File Dir IO Process RUBY_PLATFORM RUBY_ENGINE RUBY_VERSION ObjectSpace Time Random
                      Kernel STDIN STDOUT STDERR].freeze

  # [Body] for the root of `paths` (one gem's mrblib files, in load order).
  def scan(paths)
    root = Body.new(kind: :root, path: '', file: paths.first, line: 1, statements: [], children: [])
    paths.each do |path|
      result = Prism.parse(File.read(path), filepath: path)
      raise "#{path}: #{result.errors.map(&:message).join(', ')}" unless result.errors.empty?

      statements(result.value.statements, root, path)
    end
    root
  end

  def statements(node, body, file)
    return unless node

    node.body.each { |stmt| statement(stmt, body, file) }
  end

  def statement(node, body, file)
    case node
    when Prism::StatementsNode then statements(node, body, file)
    when Prism::ParenthesesNode, Prism::BeginNode
      # `begin ... end` with rescue/ensure is control flow; plain wrappers are transparent.
      if node.is_a?(Prism::BeginNode) && (node.rescue_clause || node.ensure_clause || node.else_clause)
        add(body, :control, 'begin/rescue', file, node)
      else
        statements(node.is_a?(Prism::BeginNode) ? node.statements : node.body, body, file)
      end
    when Prism::ClassNode then nested(node, :class, node.constant_path.slice, body, file, node.superclass)
    when Prism::ModuleNode then nested(node, :module, node.constant_path.slice, body, file, nil)
    when Prism::SingletonClassNode
      if node.expression.is_a?(Prism::SelfNode)
        nested(node, :sclass, 'singleton', body, file, nil)
      else
        add(body, :dsl_call, "class << #{node.expression.slice}", file, node)
      end
    when Prism::DefNode
      add(body, :def, node.receiver ? "self.#{node.name}" : node.name.to_s, file, node)
    when Prism::AliasMethodNode then add(body, :declarative, 'alias', file, node)
    when Prism::AliasGlobalVariableNode, Prism::UndefNode then add(body, :other, node.class.name.split('::').last, file, node)
    when Prism::ConstantWriteNode
      category = if literal?(node.value) then :const_literal
                 elsif Pure.pure?(node.value) then :const_pure
                 else :const_computed
                 end
      add(body, category, node.name.to_s, file, node)
    when Prism::ConstantPathWriteNode
      add(body, :const_computed, node.target.slice, file, node)
    when Prism::InstanceVariableWriteNode
      add(body, Pure.pure?(node.value) ? :class_ivar : :other, node.name.to_s, file, node)
    when Prism::CallNode then call(node, body, file)
    when Prism::IfNode, Prism::UnlessNode, Prism::CaseNode, Prism::WhileNode, Prism::UntilNode, Prism::ForNode
      add(body, :control, node.class.name.split('::').last.delete_suffix('Node'), file, node)
    else
      add(body, :other, node.class.name.split('::').last.delete_suffix('Node'), file, node)
    end
  end

  def nested(node, kind, name, body, file, superclass)
    # `class ::Top` names a top-level constant whatever the nesting; the registry spells it without the colons.
    path = if kind == :sclass then "#{body.path}.singleton"
           elsif name.start_with?('::') then name.delete_prefix('::')
           else [body.path, name].reject(&:empty?).join('::')
           end
    child = Body.new(kind: kind, path: path, file: file, line: node.location.start_line, statements: [],
                     children: [], superclass: superclass&.slice, node: node)
    body.children << child
    add(body, :declarative, "#{kind} #{name}", file, node).child = child
    statements(node.body, child, file)
  end

  def call(node, body, file)
    name = node.name.to_s
    args = node.arguments&.arguments || []
    if node.receiver.nil? && node.block.nil?
      return add(body, :declarative, name, file, node) if MIXINS.include?(name) && !args.empty? && args.all? { |a| const_path?(a) }
      return add(body, :declarative, name, file, node) if ATTRS.include?(name) && !args.empty? && args.all? { |a| name_literal?(a) }
      return add(body, :declarative, name, file, node) if name == 'alias_method' && args.size == 2 && args.all? { |a| name_literal?(a) }
      return add(body, :declarative, name, file, node) if MODES.include?(name) && args.all? { |a| name_literal?(a) }
      return add(body, :declarative, name, file, node) if CONST_VISIBILITY.include?(name) && !args.empty? && args.all? { |a| name_literal?(a) }
      # `private def x`, `module_function def x`: the def with a visibility.
      return add(body, :def, "#{name} #{args.first.name}", file, node) if MODES.include?(name) && args.size == 1 && args.first.is_a?(Prism::DefNode)
    end
    category = if runtime?(node) then :runtime
               elsif block_inside?(node) then :proc
               else :dsl_call
               end
    add(body, category, name, file, node)
  end

  # A statement of these categories may also read the environment, which blocks it for a different reason.
  RUNTIME_CHECKED = %i[const_computed const_pure dsl_call proc other control].freeze

  def add(body, category, detail, file, node)
    category = :runtime if RUNTIME_CHECKED.include?(category) && runtime?(node)
    Statement.new(category: category, detail: detail, file: file, line: node.location.start_line, node: node).tap do |statement|
      body.statements << statement
    end
  end

  def const_path?(node)
    case node
    when Prism::ConstantReadNode then true
    when Prism::ConstantPathNode then node.parent.nil? || const_path?(node.parent)
    else false
    end
  end

  def name_literal?(node) = node.is_a?(Prism::SymbolNode) || node.is_a?(Prism::StringNode)

  # A value with no run-time input that the compiler can rebuild: nothing is evaluated, only allocated.
  def literal?(node)
    case node
    # An Integer outside the 32-bit range is a bignum on the targets whose mrb_int is 32 bits wide and stays in the
    # irep's literal pool (LCF::INT32_WRAP); the compiled load builds only what every target builds the same way.
    when Prism::IntegerNode then Pure::INT_RANGE.cover?(node.value)
    when Prism::FloatNode, Prism::StringNode, Prism::SymbolNode, Prism::NilNode, Prism::TrueNode, Prism::FalseNode then true
    when Prism::ParenthesesNode then node.body.nil? || (node.body.body.size == 1 && literal?(node.body.body.first))
    when Prism::ArrayNode then node.elements.all? { |e| literal?(e) }
    when Prism::HashNode then node.elements.all? { |e| e.is_a?(Prism::AssocNode) && literal?(e.key) && literal?(e.value) }
    when Prism::RangeNode then (node.left.nil? || literal?(node.left)) && (node.right.nil? || literal?(node.right))
    when Prism::CallNode
      node.name == :freeze && node.arguments.nil? && node.block.nil? && node.receiver && literal?(node.receiver)
    else false
    end
  end

  def block_inside?(node)
    found = false
    walk(node) { |n| found = true if n.is_a?(Prism::BlockNode) || n.is_a?(Prism::LambdaNode) || n.is_a?(Prism::BlockArgumentNode) }
    found
  end

  def runtime?(node)
    found = false
    walk(node) do |n|
      found = true if n.is_a?(Prism::GlobalVariableReadNode) || n.is_a?(Prism::GlobalVariableWriteNode) ||
                      (n.is_a?(Prism::ConstantReadNode) && RUNTIME_CONSTS.include?(n.name.to_s))
    end
    found
  end

  # Every node under `node` except method bodies, which run later.
  def walk(node, &block)
    block.call(node)
    return if node.is_a?(Prism::DefNode)

    node.compact_child_nodes.each { |child| walk(child, &block) }
  end
end

module ClassBodyScan
  # PURE_EXPRESSION: what LoadCompile evaluates at load time, in source order, with no frame of its own: literals,
  # constants (looked up lexically), Array/Hash/Range of those, and block-less calls on them. A call may run any
  # code, but it takes no block or local, so it reads only what an earlier statement or gem defined, and the
  # compiled load keeps the statements in order. This module is the one definition of "pure": LoadCompile's emitter
  # raises on any node it does not accept, so the classification and the compiler cannot disagree.
  module Pure
    module_function

    # Ruby methods that run arbitrary code or read the environment: never at load time.
    DENIED = %w[eval instance_eval class_eval module_eval instance_exec class_exec module_exec send public_send __send__
                require load system exec fork exit abort raise method instance_method define_method binding
                `].freeze
    INT_RANGE = (-2**31..2**31 - 1)

    def pure?(node)
      case node
      when Prism::IntegerNode then INT_RANGE.cover?(node.value)
      when Prism::FloatNode, Prism::NilNode, Prism::TrueNode, Prism::FalseNode, Prism::SymbolNode then true
      when Prism::StringNode then !heredoc?(node)
      when Prism::ConstantReadNode then true
      when Prism::ConstantPathNode then node.parent.nil? || pure?(node.parent)
      when Prism::ParenthesesNode then node.body.is_a?(Prism::StatementsNode) && node.body.body.size == 1 && pure?(node.body.body.first)
      when Prism::ArrayNode then node.elements.all? { |e| e.is_a?(Prism::SplatNode) ? e.expression && pure?(e.expression) : pure?(e) }
      when Prism::HashNode then node.elements.all? { |e| e.is_a?(Prism::AssocNode) && pure?(e.key) && pure?(e.value) }
      when Prism::RangeNode then (node.left.nil? || pure?(node.left)) && (node.right.nil? || pure?(node.right))
      when Prism::CallNode then pure_call?(node)
      else false
      end
    end

    def pure_call?(node)
      return false if node.receiver.nil? || node.block || node.safe_navigation? || DENIED.include?(node.name.to_s)
      return false unless pure?(node.receiver)

      args = node.arguments&.arguments || []
      args.all? { |a| pure?(a) && !a.is_a?(Prism::SplatNode) && !a.is_a?(Prism::KeywordHashNode) }
    end

    # A heredoc's body lies outside its node, so deleting or moving the node would strand the text.
    def heredoc?(node) = node.opening_loc&.slice&.start_with?('<<')
  end
end
