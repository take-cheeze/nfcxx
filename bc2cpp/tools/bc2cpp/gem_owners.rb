# frozen_string_literal: true

# GEM_OWNERS: the owners each compiled gem compiles, read from its base gem's mrblib instead of a hand list. An owner
# is the lexical owner of a plain `def` (`Owner`, or `Owner.singleton` for `def self.` and `class << self`), as the
# registry spells it; a module whose body calls `module_function` also owns `Mod.singleton`, the copies. Only engine
# owners count, plus the core classes a gem lists as reopened: an engine file's def on any other core class (Object)
# belongs to the core's code, which calls it on every kind of value.
require 'prism'
require 'set'

module GemOwners
  ENGINE_RE = /\A(?:Game|RPG2k3?|LCF|RGSS)(?:::|\.singleton\z|\z)/

  module_function

  # The sorted owners of the defs in `paths`, engine ones and those in `reopened`.
  def owners(paths, reopened: [])
    finder = Finder.new
    paths.each { |path| Prism.parse_file(path).value.accept(finder) }
    finder.owners.select { |o| o.match?(ENGINE_RE) || reopened.include?(o) }.sort
  end

  class Finder < Prism::Visitor
    attr_reader :owners

    def initialize
      super
      @owners = Set.new
      @nest = []
      @singleton = false
    end

    def visit_module_node(node) = scoped(node.constant_path.slice) { super }
    def visit_class_node(node) = scoped(node.constant_path.slice) { super }

    def visit_singleton_class_node(node)
      return unless node.expression.is_a?(Prism::SelfNode)

      saved = @singleton
      @singleton = true
      super
      @singleton = saved
    end

    # A def in a block or a method body is defined when that code runs, on whatever its self is then.
    def visit_block_node(_node) = nil
    def visit_lambda_node(_node) = nil

    def visit_def_node(node)
      return if node.receiver && !node.receiver.is_a?(Prism::SelfNode)
      return if @nest.empty?

      @owners << (node.receiver || @singleton ? "#{owner}.singleton" : owner)
    end

    def visit_call_node(node)
      @owners << "#{owner}.singleton" if node.name == :module_function && node.receiver.nil? && !@nest.empty? && !@singleton
      super
    end

    private

    def owner = @nest.join('::')

    def scoped(name)
      saved_nest = @nest
      saved_singleton = @singleton
      @nest = name.start_with?('::') ? [name.delete_prefix('::')] : @nest + [name]
      @singleton = false
      yield
    ensure
      @nest = saved_nest
      @singleton = saved_singleton
    end
  end
end
