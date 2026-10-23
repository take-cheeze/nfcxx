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
#   EXTEND<TAB>Owner<TAB>Module                 each module in Owner's singleton lookup: `extend M` or `extend self` in
#                                               its body, or `include M` in `class << self`. Application order, as
#                                               INCLUDE. `*` as the module: one the sources cannot name (a computed
#                                               argument, an extend inside a def). `*` as the owner: an extend the
#                                               sources cannot attribute to a class (a block, an explicit receiver).
#   DEF<TAB>Owner<TAB>method                    each instance method the body defines: `def`, define_method, alias,
#                                               attr_*. `*` stands for a computed name, so any method may be defined.
#   SDEF<TAB>Owner<TAB>method                   each singleton method the body defines: `def self.x`, a `def` or a named
#                                               definer inside `class << self`. `*` is a computed name; as the owner, a
#                                               `def obj.x` on a receiver the sources cannot name.
# Names are the lexical constant paths (`Game::Actor`). A superclass or mixin is resolved against the classes and
# modules the sources define (nesting first, then the top level); an unresolvable name is left as written. Top-level
# mixins and defs belong to Object. A top-level `extend` or singleton def belongs to `main`, not to a class, so it has
# no row. Reads source only: bytecode is what bc2cpp uses (superclass_of, registry.rb), so this is an approximation for
# the review-only candidates, not a proof input. `class_eval` with a string and `included` hooks are not read.

require 'prism'
require 'set'

module ClassHierarchy
  Decl = Struct.new(:name, :kind, :super_expr, :nest)
  # The gathered rows. decls: name => Decl; defs and sdefs: owner => [method]; mixins: owner => [[kind, expr, nest]];
  # extends: owner => [[expr, nest]], in application order. A `*` owner key is the global unknown.
  Tables = Struct.new(:decls, :defs, :mixins, :extends, :sdefs)
  MIXINS = { include: 'INCLUDE', prepend: 'PREPEND' }.freeze
  # The calls that define a method under the names they are given. attr_writer defines `name=` only.
  NAMED_DEFS = %i[define_method alias_method attr attr_reader attr_writer attr_accessor].freeze
  UNKNOWN = '*'

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

  def new_tables
    Tables.new({}, Hash.new { |h, k| h[k] = [] }, Hash.new { |h, k| h[k] = [] }, Hash.new { |h, k| h[k] = [] },
               Hash.new { |h, k| h[k] = [] })
  end

  def scan(path, t)
    walk(Prism.parse_file(path).value, [], t)
  end

  # ctx is when the code around the node runs: :body (once, as the class is defined), :def (when a method is called) or
  # :block (when a block runs, so self may be another class). singleton is true inside `class << self`.
  def walk(node, nest, t, ctx: :body, singleton: false)
    case node
    when Prism::ClassNode, Prism::ModuleNode
      name = const_path(node.constant_path)
      full = (nest + [name]).join('::')
      kind = node.is_a?(Prism::ClassNode) ? :class : :module
      decl = (t.decls[full] ||= Decl.new(full, kind, nil, nest.dup))
      decl.super_expr = const_path(node.superclass) if node.is_a?(Prism::ClassNode) && node.superclass
      node.body&.then { |b| walk(b, nest + [name], t) }
      return
    when Prism::SingletonClassNode
      node.body&.then { |b| walk(b, nest, t, ctx: ctx, singleton: true) }
      return
    end
    record(node, nest, t, ctx: ctx, singleton: singleton)
    child_ctx = child_context(node, ctx)
    node.compact_child_nodes.each { |child| walk(child, nest, t, ctx: child_ctx, singleton: singleton) }
  end

  def child_context(node, ctx)
    case node
    when Prism::BlockNode, Prism::LambdaNode then :block
    when Prism::DefNode then ctx == :block ? :block : :def
    else ctx
    end
  end

  def record(node, nest, t, ctx:, singleton:)
    owner = nest.empty? ? 'Object' : nest.join('::')
    case node
    when Prism::DefNode then record_def(node, owner, nest, t, singleton)
    when Prism::AliasMethodNode
      name = literal_or_wild(node.new_name)
      singleton ? add_sdef(t, nest, name) : t.defs[owner] << name
    when Prism::CallNode
      record_call(node, owner, nest, t, ctx: ctx, singleton: singleton)
    end
  end

  def record_def(node, owner, nest, t, singleton)
    name = node.name.to_s
    if singleton || node.receiver.is_a?(Prism::SelfNode)
      add_sdef(t, nest, name)
    elsif node.receiver.nil?
      t.defs[owner] << name
    else
      # `def obj.x` may define x on any class, so no class's singleton lookup can be read as complete.
      t.sdefs[UNKNOWN] << UNKNOWN
    end
  end

  # A singleton method of the top-level (`main`'s) is not a class's, so it is not recorded.
  def add_sdef(t, nest, name)
    t.sdefs[nest.join('::')] << name unless nest.empty?
  end

  # A mixin call adds a row for its owner; a definer call adds the name it defines, or `*` when the name is computed.
  def record_call(node, owner, nest, t, ctx:, singleton:)
    # An explicit receiver other than self is an object the sources cannot name: any class's singleton may change.
    if node.receiver && !node.receiver.is_a?(Prism::SelfNode)
      t.extends[UNKNOWN] << [UNKNOWN, []] if node.name == :extend
      return
    end
    args = node.arguments&.arguments || []
    if node.name == :extend
      # Inside `class << self` the receiver is the singleton class, so the module joins its own singleton only.
      add_extend(t, owner, nest, args, ctx) unless singleton
    elsif singleton && %i[include prepend].include?(node.name)
      # `class << self; include M; end` mixes M into the class's singleton lookup, as `extend M` does. A prepend
      # is not read: it places a module in front of the class's own singleton methods.
      node.name == :include ? add_extend(t, owner, nest, args, ctx) : t.extends[owner] << [UNKNOWN, []]
    elsif !singleton && MIXINS.key?(node.name)
      args.reverse_each { |arg| t.mixins[owner] << [MIXINS.fetch(node.name), arg.slice.gsub(/\s+/, ' '), nest] }
    elsif NAMED_DEFS.include?(node.name)
      put = singleton ? ->(name) { add_sdef(t, nest, name) } : ->(name) { t.defs[owner] << name }
      targets = %i[define_method alias_method].include?(node.name) ? args.first(1) : args
      targets.each do |arg|
        name = literal_or_wild(arg)
        if name == '*'
          put.call(name)
          next
        end
        put.call(name) unless node.name == :attr_writer
        put.call("#{name}=") if %i[attr_writer attr_accessor].include?(node.name)
      end
    end
  end

  # The modules an extend (or a singleton include) adds, in application order. At the top level the receiver is main,
  # so nothing is recorded there; inside a def the call happens later, so the owner is unknown in its lookup; inside a
  # block the self is whichever class runs the block, so any class may be affected.
  def add_extend(t, owner, nest, args, ctx)
    case ctx
    when :body
      return if nest.empty?

      args.reverse_each { |arg| t.extends[owner] << module_expr(arg, owner, nest) }
    when :def then t.extends[owner] << [UNKNOWN, []]
    else t.extends[UNKNOWN] << [UNKNOWN, []]
    end
  end

  # [expr, nest] for one extend argument: `self` is the owner itself, a constant path resolves against its nest, and
  # any other expression is a module the sources cannot name.
  def module_expr(arg, owner, nest)
    case arg
    when Prism::SelfNode then [owner, []]
    when Prism::ConstantReadNode, Prism::ConstantPathNode
      path = const_path(arg)
      path ? [path, nest] : [UNKNOWN, []]
    else [UNKNOWN, []]
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
    t = new_tables
    paths.each { |path| scan(path, t) }
    known = t.decls.keys.to_set
    out = []
    t.decls.each_value do |d|
      out << [d.kind == :module ? 'MODULE' : 'CLASS', d.name]
      out << ['SUPER', d.name, resolve_name(known, d.nest, d.super_expr)] if d.super_expr
    end
    t.mixins.each do |owner, list|
      list.each { |kind, expr, nest| out << [kind, owner, resolve_name(known, nest, expr)] }
    end
    t.extends.each do |owner, list|
      list.each { |expr, nest| out << ['EXTEND', owner, resolve_name(known, nest, expr)] }
    end
    t.defs.each { |owner, names| names.uniq.each { |m| out << ['DEF', owner, m] } }
    t.sdefs.each { |owner, names| names.uniq.each { |m| out << ['SDEF', owner, m] } }
    out
  end
end

if $PROGRAM_NAME == __FILE__
  abort 'usage: class_hierarchy.rb SRC.rb...' if ARGV.empty?

  ClassHierarchy.rows(ARGV).each { |row| puts row.join("\t") }
end
