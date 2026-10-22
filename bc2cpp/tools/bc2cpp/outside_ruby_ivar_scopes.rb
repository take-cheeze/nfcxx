# frozen_string_literal: true

require 'set'
require_relative 'native_names'
require_relative 'ruby_parse_cache'

# OUTSIDE_RUBY_IVAR_SCOPES: which classes an outside Ruby source (core mrblib, a gem's mrblib) can write `@name` on.
#
# outside_ivar_names treats every `@name` an outside source spells as writable on any object, so one
# `@size` in mruby-enumerator's Enumerator boxes every engine class's @size. In Ruby, though, a plain
# `@name` in an instance method written lexically inside `class C` reads and writes self, and self there
# is a C (or a subclass of C). Such a spelling is attributed to C only; the consumers then demote just
# the slots of C's family (CodeGen#ivar_scope_owner?).
#
# Everything the lexical rule cannot pin to one class stays global, as before:
#   * a module body (any includer's instances), `class << x`, `def x.m`, the top level;
#   * any block or lambda, since instance_eval / instance_exec / define_method / Class.new can rebind self;
#   * `@name` inside a string, symbol or regexp (instance_variable_get(:@x), eval strings);
#   * a file Prism cannot parse, and any `@name` the text holds that no node accounts for.
module OutsideRubyIvarScopes
  module_function

  # [global_names, { name => Set[class] }] over +paths+; a name in global_names never appears in the map.
  def analyze(paths)
    global = Set.new
    scoped = Hash.new { |h, k| h[k] = Set.new }
    Array(paths).each do |path|
      src = SourceText.read(path, 'outside_ruby_ivar_scopes') or next
      file_global, file_scoped = scan_source(src, path)
      global.merge(file_global)
      file_scoped.each { |name, classes| scoped[name].merge(classes) }
    end
    [global, scoped.reject { |name, _| global.include?(name) }.transform_values(&:freeze)]
  end

  # The parse is RubyParseCache's, shared with the other foreign-Ruby scans.
  def scan_source(src, path)
    text_names = src.b.scan(/@([A-Za-z_][A-Za-z_0-9]*)/).flatten.to_set
    result = RubyParseCache.parse(src, path)
    return [text_names, {}] unless result.errors.empty?

    walker = Walker.new
    walker.visit(result.value)
    seen = walker.global | walker.scoped.keys
    [walker.global | (text_names - seen), walker.scoped]
  end

  class Walker
    IVAR_NODES = %i[instance_variable_read_node instance_variable_write_node instance_variable_operator_write_node
                    instance_variable_and_write_node instance_variable_or_write_node
                    instance_variable_target_node].freeze
    TEXT_NODES = %i[string_node symbol_node x_string_node regular_expression_node].freeze

    attr_reader :global, :scoped

    def initialize
      @global = Set.new
      @scoped = Hash.new { |h, k| h[k] = Set.new }
    end

    # +klass+ is the class a bare `def` here defines on, +owner+ the class whose instances `self` is; either is
    # nil where that is not one known class. A class body's own `@x` is the class object's, so it is global.
    def visit(node, namespace = [], klass = nil, owner = nil)
      return unless node

      case node.type
      when *IVAR_NODES
        name = node.name.to_s.delete_prefix('@')
        owner ? @scoped[name] << owner : @global << name
      when *TEXT_NODES
        node.unescaped.to_s.scan(/@([A-Za-z_][A-Za-z_0-9]*)/) { |(n)| @global << n }
      when :class_node
        path = constant_path(node.constant_path)
        path = path && namespace + path
        visit(node.superclass, namespace, klass, owner)
        return visit_children(node.body, path || [], path && !path.empty? ? path.join('::') : nil, nil)
      when :module_node
        path = constant_path(node.constant_path)
        return visit_children(node.body, path ? namespace + path : [], nil, nil)
      when :singleton_class_node
        visit(node.expression, namespace, klass, owner)
        return visit_children(node.body, namespace, nil, nil)
      when :def_node
        visit(node.receiver, namespace, klass, owner)
        method_owner = node.receiver ? nil : klass
        visit(node.parameters, namespace, nil, method_owner)
        return visit(node.body, namespace, nil, method_owner)
      when :block_node, :lambda_node
        return visit_children(node, namespace, nil, nil)
      end
      visit_children(node, namespace, klass, owner)
    end

    def visit_children(node, namespace, klass, owner)
      node&.compact_child_nodes&.each { |child| visit(child, namespace, klass, owner) }
    end

    # `class A::B` -> %w[A B]; nil for `class ::C` or a computed path, whose body then counts as unscoped.
    def constant_path(node)
      case node.type
      when :constant_read_node then [node.name.to_s]
      when :constant_path_node
        parent = node.parent && constant_path(node.parent)
        parent && parent + [node.name.to_s]
      end
    end
  end
end
