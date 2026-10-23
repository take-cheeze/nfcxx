#!/usr/bin/env ruby
# frozen_string_literal: true

# Class hierarchy, mixins and own method names of Ruby sources, for trace_types.rb candidates and the runtime evidence
# gate (--hierarchy of trace_types.rb and rbs_suggestion_trace_check.rb).
#
#   ruby scripts/bc2cpp/class_hierarchy.rb SRC.rb... > hierarchy.tsv
#
# Rows:
#   CLASS / MODULE<TAB>Name                     each `class` / `module` the sources define
#   SUPER<TAB>Class<TAB>Superclass              each explicit `class Class < Superclass`
#   INCLUDE / PREPEND<TAB>Owner<TAB>Module      each mixin, in the order Ruby applies them (`include A, B` gives B, A)
#   DEF<TAB>Owner<TAB>method                    each instance method the body defines: `def`, define_method, alias,
#                                               attr_*. `*` stands for a computed name, so any method may be defined.
# Names are the lexical constant paths (`Game::Actor`). A superclass or mixin is resolved against the classes and
# modules the sources define (nesting first, then the top level); an unresolvable name is left as written. Top-level
# mixins and defs belong to Object. A mixin or def inside `class << self` is a singleton one and is not recorded.
# Reads source only: bytecode is what bc2cpp uses (superclass_of, registry.rb), so this is an approximation for the
# review-only candidates, not a proof input. `class_eval` with a string and `included` hooks are not read.

require 'prism'
require 'set'

module ClassHierarchy
  Decl = Struct.new(:name, :kind, :super_expr, :nest)
  MIXINS = { include: 'INCLUDE', prepend: 'PREPEND' }.freeze
  # The calls that define a method under the names they are given. attr_writer defines `name=` only.
  NAMED_DEFS = %i[define_method alias_method attr attr_reader attr_writer attr_accessor].freeze

  module_function

  def const_path(node)
    case node
    when Prism::ConstantReadNode then node.name.to_s
    when Prism::ConstantPathNode
      # `::Name` is anchored at the top level, so it is kept with its leading `::` for resolve.
      return "::#{node.child.name}" if node.parent.nil?

      "#{const_path(node.parent)}::#{node.child.name}"
    end
  end

  def scan(path, decls, defs, mixins)
    tree = Prism.parse_file(path).value
    walk(tree, [], decls, defs, mixins, singleton: false)
  end

  def walk(node, nest, decls, defs, mixins, singleton: false)
    case node
    when Prism::ClassNode, Prism::ModuleNode
      name = const_path(node.constant_path)
      full = (nest + [name]).join('::')
      kind = node.is_a?(Prism::ClassNode) ? :class : :module
      decl = (decls[full] ||= Decl.new(full, kind, nil, nest.dup))
      decl.super_expr = const_path(node.superclass) if node.is_a?(Prism::ClassNode) && node.superclass
      node.body&.then { |b| walk(b, nest + [name], decls, defs, mixins) }
      return
    when Prism::SingletonClassNode
      node.body&.then { |b| walk(b, nest, decls, defs, mixins, singleton: true) }
      return
    end
    unless singleton
      owner = nest.empty? ? 'Object' : nest.join('::')
      case node
      when Prism::DefNode
        # `def self.x` is a singleton method, not an instance method of the class.
        defs[owner] << node.name.to_s if node.receiver.nil?
      when Prism::AliasMethodNode
        defs[owner] << literal_or_wild(node.new_name)
      when Prism::CallNode
        record_call(node, owner, nest, defs, mixins) if node.receiver.nil?
      end
    end
    node.compact_child_nodes.each { |child| walk(child, nest, decls, defs, mixins, singleton: singleton) }
  end

  # A mixin call adds a row for its owner; a definer call adds the name it defines, or `*` when the name is computed.
  def record_call(node, owner, nest, defs, mixins)
    args = node.arguments&.arguments || []
    if MIXINS.key?(node.name)
      args.reverse_each { |arg| mixins[owner] << [MIXINS.fetch(node.name), arg.slice.gsub(/\s+/, ' '), nest] }
    elsif NAMED_DEFS.include?(node.name)
      targets = %i[define_method alias_method].include?(node.name) ? args.first(1) : args
      targets.each do |arg|
        name = literal_or_wild(arg)
        if name == '*'
          defs[owner] << name
          next
        end
        defs[owner] << name unless node.name == :attr_writer
        defs[owner] << "#{name}=" if %i[attr_writer attr_accessor].include?(node.name)
      end
    end
  end

  def literal_or_wild(node)
    node.is_a?(Prism::SymbolNode) || node.is_a?(Prism::StringNode) ? node.unescaped : '*'
  end

  def resolve_name(known, nest, expr)
    return expr.delete_prefix('::') if expr.start_with?('::')

    # Lexical lookup: the innermost enclosing namespace first, then the top level.
    scopes = (nest.length.downto(0)).map { |i| (nest[0, i] + [expr]).join('::') }
    scopes.find { |c| known.include?(c) } || expr
  end

  def rows(paths)
    decls = {}
    defs = Hash.new { |h, k| h[k] = [] }
    mixins = Hash.new { |h, k| h[k] = [] }
    paths.each { |path| scan(path, decls, defs, mixins) }
    known = decls.keys.to_set
    out = []
    decls.each_value do |d|
      out << [d.kind == :module ? 'MODULE' : 'CLASS', d.name]
      out << ['SUPER', d.name, resolve_name(known, d.nest, d.super_expr)] if d.super_expr
    end
    mixins.each do |owner, list|
      list.each { |kind, expr, nest| out << [kind, owner, resolve_name(known, nest, expr)] }
    end
    defs.each { |owner, names| names.uniq.each { |m| out << ['DEF', owner, m] } }
    out
  end
end

if $PROGRAM_NAME == __FILE__
  abort 'usage: class_hierarchy.rb SRC.rb...' if ARGV.empty?

  ClassHierarchy.rows(ARGV).each { |row| puts row.join("\t") }
end
