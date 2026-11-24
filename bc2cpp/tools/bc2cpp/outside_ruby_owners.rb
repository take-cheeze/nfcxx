# frozen_string_literal: true

require 'prism'
require 'set'
require_relative 'file_identity'
require_relative 'ruby_parse_cache'
require_relative 'scan_cache'

# OUTSIDE_OWNER_CALL: the class or module each outside Ruby source (the build's mrblib, mruby's own
# Ruby included) defines a method name on, spelled as mruby's `mrb_class_name` spells it at run time: the full
# lexical path (`class Foo; class Bar` is `Foo::Bar`), with `.singleton` for a definition on the class object (`def
# self.x`, `class << self`, `module_function`, `define_singleton_method`). ForeignDefiners keeps only the
# last path segment and no singleton definitions, which is enough to refuse but not to name an owner.
#
# A definition whose owner cannot be named (a `def obj.x` on another object, a `class << expr` that is not `self`)
# makes its name `unknown`; a computed definition, an `*_eval`, a `prepend` or a `refine` makes its owner `wild`
# (every name may be defined there). Over-approximate on purpose: an owner listed here that defines nothing is never
# found by a method lookup, so the call checked against the list behaves the same. Three shapes are read exactly
# instead (PRECISE_REOPENERS): `Const.class_eval do ... end`, a definition-free `send(name) do ... end`, and an
# `each` over a literal name list feeding definer arguments.
module OutsideRubyOwners
  DEFINERS = %w[define_method alias_method attr_reader attr_writer attr_accessor attr remove_method undef_method
                public private protected].freeze
  REOPENERS = %w[class_eval module_eval class_exec module_exec instance_eval instance_exec send __send__ public_send
                 prepend refine].freeze

  Result = Struct.new(:names, :wild, :unknown)

  @cache = {}

  module_function

  def scan(paths)
    files, key = FileIdentity.files_and_key(paths)
    @cache[key] ||= scan_files_cached(files)
  end

  # OUTSIDE_OWNERS_SCAN_CACHE: the walk of every outside Ruby file depends only on the files' contents, and was about
  # 5% of a self-compiled run in every process. ScanCache keeps the names, wild and unknown owners under the files'
  # digests, as plain collections (the collector's default block does not marshal). A scan the cache cannot key is
  # walked as before.
  def scan_files_cached(files)
    names, wild, unknown = ScanCache.fetch('outside_ruby_owners.scan_files', files, cache_absent: false) do
      collector = Collector.new
      files.each do |path|
        parsed = RubyParseCache.parse_file(path)
        raise "outside Ruby source #{path} does not parse: #{parsed.errors.first&.message}" unless parsed.errors.empty?

        collector.visit(parsed.value)
      end
      plain = {}
      collector.names.each { |owner, set| plain[owner] = set }
      [plain, collector.wild, collector.unknown]
    end
    Result.new(names, wild, unknown)
  end

  # One lexical scope: `path` is nil when the scope's object cannot be named.
  # `eval` marks a `Const.class_eval do` block: definitions land on Const, but constants (a nested `class Foo`) still
  # resolve lexically, past it. `module_body` is false where a bare `module_function` raises (a class body).
  Frame = Struct.new(:path, :singleton, :module_function, :eval, :module_body)

  class Collector < Prism::Visitor
    attr_reader :names, :wild, :unknown

    def initialize
      super
      @stack = []
      @names = Hash.new { |hash, key| hash[key] = Set.new }
      @wild = Set.new
      @unknown = Set.new
      @bindings = {}
    end

    def visit_class_node(node)
      scoped(Frame.new(nested(node.constant_path), false, false, false, false)) { super }
    end

    def visit_module_node(node)
      scoped(Frame.new(nested(node.constant_path), false, false, false, true)) { super }
    end

    def visit_singleton_class_node(node)
      frame = @stack.last
      path = node.expression.is_a?(Prism::SelfNode) ? (frame ? frame.path : 'Object') : nil
      path = nil if frame&.singleton
      scoped(Frame.new(path, true, false, false, false)) { super }
    end

    def visit_def_node(node)
      name = node.name.to_s
      case node.receiver
      when nil then record(name)
      when Prism::SelfNode then record(name, singleton: true)
      else @unknown << name
      end
      super
    end

    def visit_alias_method_node(node)
      record(node.new_name.unescaped) if node.new_name.respond_to?(:unescaped)
      super
    end

    def visit_undef_node(node)
      node.names.each { |name| record(name.unescaped) if name.respond_to?(:unescaped) }
      super
    end

    def visit_call_node(node)
      name = node.name.to_s
      path = node.receiver && constant_path(node.receiver)
      return class_eval_block(path, node) if path && CLASS_EVALS.include?(name) && node.arguments.nil? &&
                                             node.block.is_a?(Prism::BlockNode)

      names = each_names(node)
      return each_block(node, names) if names

      if node.receiver.nil?
        definition_call(name, node)
      elsif inert_send?(name, node)
        module_function_reached
      elsif REOPENERS.include?(name) || DEFINERS.include?(name) || name == 'define_singleton_method'
        if path
          @wild << path << "#{path}.singleton"
        elsif name == 'define_singleton_method'
          literal_names(node).each { |sym| @unknown << sym if sym }
        end
      end
      super
    end

    CLASS_EVALS = %w[class_eval module_eval class_exec module_exec].freeze
    SENDS = %w[send __send__ public_send].freeze
    PLAIN_ARGUMENT = ->(node) { !(node.is_a?(Prism::SplatNode) || node.is_a?(Prism::KeywordHashNode) ||
                                  node.is_a?(Prism::BlockArgumentNode) || node.is_a?(Prism::ForwardingArgumentsNode)) }

    private

    # `Const.class_eval do ... end` with no arguments runs the block as Const's body: a `def` (or `def self.x`, or a
    # receiverless definer) lands on Const (Const.singleton) exactly as in `class Const`.
    def class_eval_block(path, node)
      visit(node.receiver)
      scoped(Frame.new(path, false, false, true, true)) { visit(node.block) }
    end

    # A send whose only argument is the method name calls that method with no arguments: define_method,
    # alias_method, define_singleton_method, send and refine then raise, attr_*, remove/undef_method and prepend
    # define nothing, and a reopener only runs the block, so a block with no definition in it defines nothing. A bare
    # module_function is the one name it still reaches (see module_function_reached).
    def inert_send?(name, node)
      return false unless SENDS.include?(name)

      arguments = node.arguments&.arguments || []
      return false unless arguments.size == 1 && PLAIN_ARGUMENT.call(arguments.first)
      return true if node.block.nil?

      node.block.is_a?(Prism::BlockNode) && !defines_anything?(node.block)
    end

    def defines_anything?(node)
      return true if node.is_a?(Prism::DefNode) || node.is_a?(Prism::AliasMethodNode) || node.is_a?(Prism::UndefNode) ||
                     node.is_a?(Prism::SingletonClassNode) || node.is_a?(Prism::ClassNode) ||
                     node.is_a?(Prism::ModuleNode)
      if node.is_a?(Prism::CallNode)
        name = node.name.to_s
        return true if REOPENERS.include?(name) || DEFINERS.include?(name) ||
                       %w[define_singleton_method module_function].include?(name)
      end
      node.compact_child_nodes.any? { |child| defines_anything?(child) }
    end

    # A bare module_function reached through a send turns the rest of the scope's definitions into module functions
    # too; it raises outside a module body, so only a module (or a class_eval'd constant) frame takes the flag.
    def module_function_reached
      frame = @stack.last
      frame.module_function = true if frame&.module_body
    end

    # `[:a, "b"].each do |v| ... end`: inside the block `v` is one of those names, so a definer argument spelled
    # with `v` (`v`, `:"x_#{v}"`) names exactly those. Nil when the shape differs or the block can rebind `v`.
    def each_names(node)
      return nil unless node.name == :each && node.arguments.nil? && node.receiver.is_a?(Prism::ArrayNode) &&
                        node.block.is_a?(Prism::BlockNode)

      values = node.receiver.elements.map do |element|
        return nil unless element.is_a?(Prism::SymbolNode) || element.is_a?(Prism::StringNode)

        element.unescaped
      end
      parameters = node.block.parameters
      params = parameters.is_a?(Prism::BlockParametersNode) ? parameters.parameters : nil
      return nil unless params && parameters.locals.empty? && params.requireds.size == 1 &&
                        params.requireds.first.is_a?(Prism::RequiredParameterNode) && params.optionals.empty? &&
                        params.rest.nil? && params.posts.empty? && params.keywords.empty? &&
                        params.keyword_rest.nil? && params.block.nil?

      variable = params.requireds.first.name
      return nil if node.block.body && rebinds?(node.block.body, variable)

      [variable, values]
    end

    # Any node other than a read that carries the name (a write, a shadowing parameter, a call spelled the same)
    # could make a read of it mean something else.
    def rebinds?(node, variable)
      return true if !node.is_a?(Prism::LocalVariableReadNode) && node.respond_to?(:name) && node.name == variable

      node.compact_child_nodes.any? { |child| rebinds?(child, variable) }
    end

    def each_block(node, (variable, values))
      visit(node.receiver)
      saved = @bindings
      @bindings = saved.merge(variable => values)
      begin
        visit(node.block)
      ensure
        @bindings = saved
      end
    end

    # The names a definer argument can spell: a literal, or a bound each variable alone or interpolated into a
    # symbol or string. Nil when it is anything else.
    def argument_names(argument)
      case argument
      when Prism::SymbolNode, Prism::StringNode then [argument.unescaped]
      when Prism::LocalVariableReadNode then @bindings[argument.name]
      when Prism::InterpolatedSymbolNode, Prism::InterpolatedStringNode
        argument.parts.reduce(['']) do |prefixes, part|
          pieces = part_names(part)
          return nil unless pieces

          prefixes.product(pieces).map(&:join)
        end
      end
    end

    def part_names(part)
      return [part.unescaped] if part.is_a?(Prism::StringNode)
      return nil unless part.is_a?(Prism::EmbeddedStatementsNode) && part.statements&.body&.size == 1

      read = part.statements.body.first
      read.is_a?(Prism::LocalVariableReadNode) ? @bindings[read.name] : nil
    end

    def scoped(frame)
      @stack.push(frame)
      yield
    ensure
      @stack.pop
    end

    # The full path of a class or module body: `::Foo` is absolute, `Foo::Bar` nests under the enclosing body.
    def nested(path_node)
      text = path_node.slice
      return text.delete_prefix('::') if text.start_with?('::')

      outer = @stack.reverse.find { |frame| !frame.singleton && !frame.eval }
      outer&.path ? "#{outer.path}::#{text}" : text
    end

    def constant_path(node)
      return node.slice.delete_prefix('::') if node.is_a?(Prism::ConstantReadNode) || node.is_a?(Prism::ConstantPathNode)

      nil
    end

    # The owner a definition in the current scope lands on, or nil when it cannot be named.
    def owner(singleton)
      frame = @stack.last
      return(singleton ? 'Object.singleton' : 'Object') unless frame
      return nil unless frame.path

      frame.singleton || singleton ? "#{frame.path}.singleton" : frame.path
    end

    def record(name, singleton: false)
      frame = @stack.last
      targets = [owner(singleton)]
      targets << owner(true) if frame&.module_function && !singleton
      if targets.include?(nil)
        @unknown << name
        return
      end
      targets.each { |target| @names[name] << target }
    end

    # Every name the arguments can spell, with a nil for an argument that can spell any name.
    def literal_names(node)
      arguments = (node.arguments&.arguments || []).reject { |argument| argument.is_a?(Prism::DefNode) }
      arguments.flat_map { |argument| argument_names(argument) || [nil] }
    end

    def wild_here
      [owner(false), owner(true)].each { |target| target ? @wild << target : nil }
      @unknown << :all unless owner(false)
    end

    def definition_call(name, node)
      if inert_send?(name, node)
        module_function_reached
        return
      end
      if REOPENERS.include?(name)
        wild_here
        return
      end
      if name == 'module_function'
        symbols = literal_names(node)
        if symbols.empty? && node.arguments.nil?
          @stack.last.module_function = true if @stack.last
        elsif symbols.any?(&:nil?)
          wild_here
        else
          symbols.each { |symbol| record(symbol, singleton: true) }
        end
        return
      end
      return unless DEFINERS.include?(name) || name == 'define_singleton_method'

      symbols = literal_names(node)
      visibility = %w[public private protected].include?(name)
      if symbols.any?(&:nil?) || (symbols.empty? && !visibility && node.arguments.nil?)
        wild_here
        return
      end
      symbols.each do |symbol|
        record(symbol, singleton: name == 'define_singleton_method')
        record("#{symbol}=") if name.start_with?('attr')
      end
    end
  end
end
