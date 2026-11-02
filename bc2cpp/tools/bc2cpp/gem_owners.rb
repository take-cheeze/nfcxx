# frozen_string_literal: true

# GEM_OWNERS: the owners each compiled gem compiles, read from its base gem's mrblib instead of a hand list. An owner
# is the lexical owner of a plain `def` (`Owner`, or `Owner.singleton` for `def self.` and `class << self`), as the
# registry spells it; a module whose body calls `module_function` also owns `Mod.singleton`, the copies. Every owner
# the mrblib reopens counts (StringIO, Array, NameError, ...) except the universal ones (UNIVERSAL): an engine file's
# def on Object or Kernel belongs to the core's code, which calls it on every kind of value.
require_relative 'ruby_parse_cache'
require 'set'
require_relative 'scan_cache'

module GemOwners
  ENGINE_RE = /\A(?:Game|RPG2k3?|LCF|RGSS)(?:::|\.singleton\z|\z)/
  UNIVERSAL = %w[BasicObject Object Kernel Module Class].freeze

  module_function

  # The sorted owners of the defs in `paths`, but for the universal ones (and their singletons).
  def owners(paths)
    ScanCache.fetch("gem_owners.owners.prism#{Prism::VERSION}", paths) do
      finder = Finder.new
      paths.each { |path| RubyParseCache.parse_file(path).value.accept(finder) }
      finder.owners.reject { |o| UNIVERSAL.include?(o.delete_suffix('.singleton')) }.sort
    end
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
