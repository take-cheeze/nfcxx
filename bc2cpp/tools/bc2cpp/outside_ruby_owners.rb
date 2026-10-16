# frozen_string_literal: true

require 'prism'
require 'set'
require_relative 'ruby_parse_cache'

# OUTSIDE_OWNER_CALL (docs/adr/0468): the class or module each outside Ruby source (the build's mrblib, mruby's own
# Ruby included) defines a method name on, spelled as mruby's `mrb_class_name` spells it at run time: the full
# lexical path (`class Foo; class Bar` is `Foo::Bar`), with `.singleton` for a definition on the class object (`def
# self.x`, `class << self`, `module_function`, `define_singleton_method`). ForeignDefiners (ADR 0257) keeps only the
# last path segment and no singleton definitions, which is enough to refuse but not to name an owner.
#
# A definition whose owner cannot be named (a `def obj.x` on another object, a `class << expr` that is not `self`)
# makes its name `unknown`; a computed definition, an `*_eval`, a `prepend` or a `refine` makes its owner `wild`
# (every name may be defined there). Over-approximate on purpose: an owner listed here that defines nothing is never
# found by a method lookup, so the call checked against the list behaves the same.
module OutsideRubyOwners
  DEFINERS = %w[define_method alias_method attr_reader attr_writer attr_accessor attr remove_method undef_method
                public private protected].freeze
  REOPENERS = %w[class_eval module_eval class_exec module_exec instance_eval instance_exec send __send__ public_send
                 prepend refine].freeze

  Result = Struct.new(:names, :wild, :unknown)

  @cache = {}

  module_function

  def scan(paths)
    files = Array(paths).select { |path| File.file?(path) }
    key = files.map { |path| stat = File.stat(path); [path, stat.mtime, stat.size] }
    @cache[key] ||= begin
      collector = Collector.new
      files.each do |path|
        parsed = RubyParseCache.parse_file(path)
        raise "outside Ruby source #{path} does not parse: #{parsed.errors.first&.message}" unless parsed.errors.empty?

        collector.visit(parsed.value)
      end
      Result.new(collector.names, collector.wild, collector.unknown)
    end
  end

  # One lexical scope: `path` is nil when the scope's object cannot be named.
  Frame = Struct.new(:path, :singleton, :module_function)

  class Collector < Prism::Visitor
    attr_reader :names, :wild, :unknown

    def initialize
      super
      @stack = []
      @names = Hash.new { |hash, key| hash[key] = Set.new }
      @wild = Set.new
      @unknown = Set.new
    end

    def visit_class_node(node)
      scoped(Frame.new(nested(node.constant_path), false, false)) { super }
    end

    def visit_module_node(node)
      scoped(Frame.new(nested(node.constant_path), false, false)) { super }
    end

    def visit_singleton_class_node(node)
      frame = @stack.last
      path = node.expression.is_a?(Prism::SelfNode) ? (frame ? frame.path : 'Object') : nil
      path = nil if frame&.singleton
      scoped(Frame.new(path, true, false)) { super }
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
      if node.receiver.nil?
        definition_call(name, node)
      elsif REOPENERS.include?(name) || DEFINERS.include?(name) || name == 'define_singleton_method'
        path = constant_path(node.receiver)
        if path
          @wild << path << "#{path}.singleton"
        elsif name == 'define_singleton_method'
          literal_names(node).each { |sym| @unknown << sym if sym }
        end
      end
      super
    end

    private

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

      outer = @stack.reverse.find { |frame| !frame.singleton }
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

    def literal_names(node)
      arguments = (node.arguments&.arguments || []).reject { |argument| argument.is_a?(Prism::DefNode) }
      arguments.map do |argument|
        argument.unescaped if argument.is_a?(Prism::SymbolNode) || argument.is_a?(Prism::StringNode)
      end
    end

    def wild_here
      [owner(false), owner(true)].each { |target| target ? @wild << target : nil }
      @unknown << :all unless owner(false)
    end

    def definition_call(name, node)
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
