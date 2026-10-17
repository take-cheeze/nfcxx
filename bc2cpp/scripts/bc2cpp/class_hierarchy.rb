#!/usr/bin/env ruby
# frozen_string_literal: true

# Class hierarchy and own method names of Ruby sources, for trace_types.rb candidates (--hierarchy).
#
#   ruby scripts/bc2cpp/class_hierarchy.rb SRC.rb... > hierarchy.tsv
#
# Rows: `SUPER<TAB>Class<TAB>Superclass` for each `class Class < Superclass`, and `DEF<TAB>Class<TAB>method` for each
# instance method the class body defines. Names are the lexical constant paths (`Game::Actor`), a superclass is resolved
# against the classes the sources define (nesting first, then the top level); an unresolvable superclass is left as
# written. Reads source only: bytecode is what bc2cpp uses (superclass_of, registry.rb), so this is an approximation
# for the review-only candidates, not a proof input.

require 'prism'
require 'set'

module ClassHierarchy
  Decl = Struct.new(:name, :super_expr, :nest, :defs)

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

  def scan(path, decls)
    tree = Prism.parse_file(path).value
    walk(tree, [], decls)
  end

  def walk(node, nest, decls)
    case node
    when Prism::ClassNode
      name = const_path(node.constant_path)
      full = (nest + [name]).join('::')
      decl = (decls[full] ||= Decl.new(full, nil, nest.dup, []))
      decl.super_expr = const_path(node.superclass) if node.superclass
      inner = nest + [name]
      node.body&.then { |b| walk(b, inner, decls) }
      return
    when Prism::ModuleNode
      name = const_path(node.constant_path)
      inner = nest + [name]
      node.body&.then { |b| walk(b, inner, decls) }
      return
    when Prism::DefNode
      # `def self.x` is a singleton method, not an instance method of the class.
      owner = nest.join('::')
      decls[owner]&.defs&.push(node.name.to_s) if decls[owner] && node.receiver.nil?
    end
    node.compact_child_nodes.each { |child| walk(child, nest, decls) }
  end

  def resolve(known, decl)
    expr = decl.super_expr
    return nil unless expr
    return expr.delete_prefix('::') if expr.start_with?('::')

    # Lexical lookup: the innermost enclosing namespace first, then the top level.
    scopes = (decl.nest.length.downto(0)).map { |i| (decl.nest[0, i] + [expr]).join('::') }
    scopes.find { |c| known.include?(c) } || expr
  end

  def rows(paths)
    decls = {}
    paths.each { |path| scan(path, decls) }
    known = decls.keys.to_set
    decls.values.flat_map do |d|
      out = []
      out << ['SUPER', d.name, resolve(known, d)] if d.super_expr
      out.concat(d.defs.uniq.map { |m| ['DEF', d.name, m] })
      out
    end
  end
end

if $PROGRAM_NAME == __FILE__
  abort 'usage: class_hierarchy.rb SRC.rb...' if ARGV.empty?

  ClassHierarchy.rows(ARGV).each { |row| puts row.join("\t") }
end
