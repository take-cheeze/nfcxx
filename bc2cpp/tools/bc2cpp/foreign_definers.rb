# frozen_string_literal: true

require 'prism'
require 'set'

# FOREIGN_DEFINERS (docs/adr/0257): which method names outside Ruby (the build's
# mrblib sources) defines, aliases, undefines or re-scopes on which class. The
# closed world only knows such names globally (`foreign_method_names`), which
# refuses `inspect` for Integer because Rational#inspect exists. NativeCoreDirect
# needs the class, so this walks the syntax tree with a lexical class stack.
#
# Deliberately over-approximate: a nested `Foo::Array` counts as `Array`, and a
# dynamic definition (a non-literal name, `class_eval`, `prepend`) marks the whole
# class as wild so every name on it is treated as defined.
module ForeignDefiners
  DEFINERS = %w[define_method alias_method attr_reader attr_writer attr_accessor attr
                remove_method undef_method public private protected].freeze
  REOPENERS = %w[class_eval module_eval class_exec module_exec instance_eval instance_exec
                 send __send__ public_send prepend refine].freeze

  Result = Struct.new(:names, :wild)

  @cache = {}

  module_function

  # Memoized on file identity: a check that rewrites a fixture never sees stale text.
  def scan(paths)
    files = Array(paths).select { |path| File.file?(path) }
    key = files.map { |path| stat = File.stat(path); [path, stat.mtime, stat.size] }
    @cache.fetch(key) do
      @cache.clear
      @cache[key] = scan_files(files)
    end
  end

  def scan_files(files)
    collector = Collector.new
    files.each do |path|
      parsed = Prism.parse_file(path)
      raise "foreign Ruby source #{path} does not parse: #{parsed.errors.first&.message}" unless parsed.errors.empty?

      collector.visit(parsed.value)
    end
    Result.new(collector.names, collector.wild)
  end

  # True when some foreign definition could sit on `owner` under `name`.
  def defines?(paths, owner, name)
    result = scan(paths)
    result.wild.include?(owner) || result.names.fetch(owner, Set.new).include?(name)
  end

  class Collector < Prism::Visitor
    attr_reader :names, :wild

    def initialize
      super
      @stack = []
      @names = Hash.new { |hash, key| hash[key] = Set.new }
      @wild = Set.new
    end

    def visit_class_node(node)
      scoped(constant_name(node.constant_path)) { super }
    end

    def visit_module_node(node)
      scoped(constant_name(node.constant_path)) { super }
    end

    def visit_singleton_class_node(node)
      scoped(:singleton) { super }
    end

    def visit_def_node(node)
      record(node.name.to_s) if node.receiver.nil?
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
      receiver = node.receiver
      if receiver.nil?
        definition_call(name, node)
      elsif REOPENERS.include?(name) || DEFINERS.include?(name)
        owner = receiver_owner(receiver)
        @wild << owner if owner
      end
      if node.receiver.nil? && %w[prepend refine].include?(name)
        @wild << @stack.last if @stack.last.is_a?(String)
      end
      super
    end

    private

    def scoped(name)
      @stack.push(name)
      yield
    ensure
      @stack.pop
    end

    def constant_name(path)
      path.slice.split('::').last
    end

    def receiver_owner(receiver)
      return unless receiver.is_a?(Prism::ConstantReadNode) || receiver.is_a?(Prism::ConstantPathNode)

      constant_name(receiver)
    end

    def current_owner
      owner = @stack.last
      owner.is_a?(String) ? owner : nil
    end

    def record(name)
      owner = current_owner
      @names[owner] << name if owner
    end

    def definition_call(name, node)
      owner = current_owner
      return unless owner
      return unless DEFINERS.include?(name) || REOPENERS.include?(name)

      arguments = node.arguments&.arguments || []
      # `private def x` names its method through the DefNode visited below.
      arguments = arguments.reject { |argument| argument.is_a?(Prism::DefNode) }
      symbols = arguments.map do |argument|
        argument.unescaped if argument.is_a?(Prism::SymbolNode) || argument.is_a?(Prism::StringNode)
      end
      visibility = %w[public private protected].include?(name)
      if REOPENERS.include?(name) || symbols.any?(&:nil?) || (symbols.empty? && !visibility && node.arguments.nil?)
        @wild << owner
        return
      end
      symbols.each do |symbol|
        @names[owner] << symbol
        @names[owner] << "#{symbol}=" if name.start_with?('attr')
      end
    end
  end
end
