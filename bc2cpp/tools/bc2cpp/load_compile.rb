# frozen_string_literal: true

# LOAD_COMPILE: the closed build's class and module bodies, evaluated by generated C++ instead of mruby bytecode.
#
# A body runs once, while mrblib loads, and ClassBodyScan found that what runs is declarative: nested bodies,
# include/extend/attr_*, constants built from literals and other constants, and `def`s. This file splits each engine
# gem's mrblib into two parts that together do what the whole did:
#
#   residual   the mrblib the gem still loads as bytecode: every statement the compiler does not take, in the source
#              order and on the original lines, so a backtrace still names the right line. It runs first.
#   compiled   a generated function that the compiled gem's gem_init runs next, before it installs its compiled
#              methods. It opens each body, in source order, and runs the statements the residual left out: a byte
#              program of those statements and one decoder (CLASS_PROGRAM), not a C++ call per statement.
#
# Moving a statement from before a residual statement to after it is sound when the residual one cannot observe it,
# so a residual statement that reads a constant makes that constant's statement residual too (promotion), and so does
# a class header that the residual needs (a superclass, an outer scope). What is left is not observable by a load:
# a `def` the compiled gem replaces never runs as bytecode (MrblibStubs.stubbable), and the other statements only
# define names that nothing residual reads.
#
# A body that cannot be compiled keeps its text and its bytecode, statement by statement: nothing here is
# all-or-nothing. A def stays when the stub proof keeps it (alias source, module_function copy, guard, loaded copy),
# or when a compiled statement names it (`private :x`, `alias_method`), because that statement runs before the
# compiled gem has installed anything.
require 'json'
require 'prism'
require 'set'
require_relative 'class_body_scan'
require_relative 'pure_eval'
require_relative 'class_world'

module LoadCompile
  module_function

  Item = Struct.new(:stmt, :role, :orig_role, :child, :def_key, :def_name, :dropped, :promoted, :ordered, :fold, :fold_why, keyword_init: true)
  UBody = Struct.new(:body, :items, :parent, :header_simple, :forced, :skeleton, :name, :id, keyword_init: true)
  Result = Struct.new(:code, :ranges, :last_file, :marker, :stats, :bodies, :dropped, keyword_init: true)

  MODES = ClassBodyScan::MODES
  BARE_MODE = { 'private' => :private, 'public' => :public, 'protected' => :protected, 'module_function' => :modfunc }.freeze
  # The sends a compiled load makes as written. `include` &c. are made by the VM with self as receiver, so the
  # same method runs; the arguments are constants and symbols.
  MARKER_PREFIX = '$__bc2cpp_residual_'

  # [UBody] for one file, in source order.
  def build_root(path, statements: true)
    root = ClassBodyScan.scan([path])
    ubody(root, nil, statements)
  end

  # `statements`: false leaves every statement but the defs to the residual (only the compiled gem's defs go), so
  # the compiled load has nothing to run.
  def ubody(body, parent, statements = true)
    ub = UBody.new(body: body, items: [], parent: parent, forced: false, skeleton: false, name: body.name)
    ub.header_simple = header_simple?(body)
    mode = :public
    body.statements.each_with_index do |stmt, index|
      role, mode = role_of(stmt, mode)
      fold = nil
      # PURE_CONST_EVAL: a computed constant that is data at build time is a constant of the program.
      if role == :residual && stmt.category == :const_computed
        value, why, source = PureEval.fold(body.statements, index, magic: magic?(stmt.file))
        fold = [value, source] unless why
        role = :const unless why
      end
      # A header whose class cannot be named (`class foo::Bar`) cannot be reopened by the compiled load: it and
      # everything in it stays as written.
      role = :residual if role == :nested && !openable?(stmt.child)
      orig_role = role
      role = :residual if !statements && %i[send alias const ivar].include?(role)
      item = Item.new(stmt: stmt, role: role, orig_role: orig_role, fold: fold)
      item.child = ubody(stmt.child, ub, statements) if role == :nested
      annotate_def(item, ub)
      ub.items << item
    end
    ub
  end

  # Whether the file starts with `# frozen_string_literal: true` (a folded String is frozen iff the source's was).
  def magic?(file)
    @magic ||= {}
    @magic.fetch(file) { @magic[file] = File.foreach(file).first(5).any? { |l| l.match?(/\A#\s*frozen_string_literal:\s*true/) } }
  end

  def openable?(body)
    node = body.node
    case node
    when Prism::ClassNode, Prism::ModuleNode then path_ok?(node.constant_path)
    else true
    end
  end

  # [role, next mode]. Roles: :nested :def :mode :send :alias :const :ivar :residual.
  def role_of(stmt, mode)
    node = stmt.node
    case stmt.category
    when :def then [:def, mode]
    when :const_literal, :const_pure then [:const, mode]
    when :class_ivar then [:ivar, mode]
    when :declarative
      return [:nested, mode] if stmt.child
      return [:alias, mode] if node.is_a?(Prism::AliasMethodNode)

      name = node.name.to_s
      args = node.arguments&.arguments || []
      return [:mode, BARE_MODE.fetch(name)] if args.empty? && BARE_MODE.key?(name)
      # A definition made under a mode other than public takes that mode from the frame the VM runs the body in;
      # a compiled load has no such frame, so it stays where the mode statement stays.
      return [:residual, mode] if ClassBodyScan::ATTRS.include?(name) && mode != :public

      [:send, mode]
    else [:residual, mode]
    end
  end

  def header_simple?(body)
    node = body.node
    case node
    when nil then true
    when Prism::ClassNode
      path_ok?(node.constant_path) && (node.superclass.nil? || ClassBodyScan.const_path?(node.superclass))
    when Prism::ModuleNode then path_ok?(node.constant_path)
    when Prism::SingletonClassNode then node.expression.is_a?(Prism::SelfNode)
    else false
    end
  end

  def path_ok?(path) = path.is_a?(Prism::ConstantReadNode) || (path.is_a?(Prism::ConstantPathNode) && (path.parent.nil? || ClassBodyScan.const_path?(path.parent)))

  # Owner#name of a def statement, spelled as the registry spells it (MrblibStubs::DefFinder).
  def annotate_def(item, ub)
    return unless item.role == :def

    node = item.stmt.node
    node = node.arguments.arguments.first if node.is_a?(Prism::CallNode)
    item.def_name = node.name.to_s
    owner = ub.body.path.empty? ? 'Object' : ub.body.path
    if node.receiver
      return unless node.receiver.is_a?(Prism::SelfNode)

      owner = "#{owner}.singleton"
    end
    # `module_function def x` copies the method: never dropped.
    wrapper = item.stmt.node.is_a?(Prism::CallNode) ? item.stmt.node.name.to_s : nil
    item.def_key = "#{owner}##{item.def_name}" unless wrapper == 'module_function'
  end

  def each_ubody(ub, &block)
    block.call(ub)
    ub.items.each { |item| each_ubody(item.child, &block) if item.child }
  end

  # ---- promotion ---------------------------------------------------------------------------------------------

  # The names a node reads as constants when it is evaluated, not those inside a def or lambda body (run later).
  def reads(node, into = Set.new)
    case node
    when Prism::ConstantReadNode then into << node.name.to_s
    when Prism::ConstantPathNode
      into << node.name.to_s
      reads(node.parent, into) if node.parent
    when Prism::DefNode, Prism::LambdaNode then nil
    else node.compact_child_nodes.each { |child| reads(child, into) } if node
    end
    into
  end

  def header_reads(ub)
    node = ub.body.node
    return Set.new unless node.is_a?(Prism::ClassNode) || node.is_a?(Prism::ModuleNode)

    # The outer scope and the superclass; the body's own name is what it defines.
    path = node.constant_path
    set = path.is_a?(Prism::ConstantPathNode) && path.parent ? reads(path.parent) : Set.new
    set.merge(reads(node.superclass)) if node.respond_to?(:superclass) && node.superclass
    set
  end

  def defined_name(item)
    case item.role
    when :nested
      node = item.stmt.node
      node.respond_to?(:constant_path) ? node.constant_path.slice.split('::').last : nil
    when :const then item.stmt.node.name.to_s
    end
  end

  # The method names a compiled send or alias defines or reads when it runs: `attr_writer :a` defines `a=`,
  # `alias_method :b, :a` defines b and reads a. Visibility sends only read.
  def taken_names(node)
    return [node.new_name.unescaped, node.old_name.unescaped] if node.is_a?(Prism::AliasMethodNode)

    given = (node.arguments&.arguments || []).filter_map { |a| a.unescaped if a.is_a?(Prism::SymbolNode) || a.is_a?(Prism::StringNode) }
    case node.name.to_s
    when 'attr', 'attr_reader' then given
    when 'attr_writer' then given.map { |n| "#{n}=" }
    when 'attr_accessor' then given.flat_map { |n| [n, "#{n}="] }
    else given
    end
  end

  # ORDER: the compiled load runs after every residual statement and the compiled gem installs the dropped defs after
  # the load, so a compiled send or alias keeps the source order only against the defs that come before it and that it
  # does not define over. A def of the same owner and name that comes later in the source (`alias_method :old, :sort!`
  # above a redefined `def sort!`: the alias must hold the method that existed then) keeps the statement residual, in
  # its place among the residual defs. A def that comes earlier, with a statement that defines the same name
  # (`def a; end` then `attr_reader :a`), is kept too (`order_pins`), or the compiled gem would install it over the
  # statement's. Sources are walked in the world's order: gems in order, files in order, statements in order.
  def order!(roots)
    seq = 0
    defs = Hash.new { |h, k| h[k] = [] }
    sends = []
    roots.each do |root|
      each_ubody(root) do |ub|
        owner = ub.body.path.empty? ? 'Object' : ub.body.path
        ub.items.each do |item|
          seq += 1
          defs[item.def_key] << seq if item.role == :def && item.def_key
          sends << [owner, item, seq] if %i[send alias].include?(item.role)
        end
      end
    end
    sends.each do |owner, item, at|
      keys = taken_names(item.stmt.node).map { |n| "#{owner}##{n}" }
      next unless keys.any? { |k| defs[k].any? { |d| d > at } }

      item.role = :residual
      item.ordered = true
    end
    @order_pins = Set.new
    sends.each do |owner, item, at|
      next if item.ordered || !%w[attr attr_reader attr_writer attr_accessor alias_method].include?(item.stmt.node.is_a?(Prism::AliasMethodNode) ? 'alias_method' : item.stmt.node.name.to_s)

      taken_names(item.stmt.node).each do |n|
        key = "#{owner}##{n}"
        @order_pins << key if defs[key].any? { |d| d < at }
      end
    end
  end

  def order_pins = @order_pins || Set.new

  VISIBILITY_SENDS = { 'private' => :instance, 'public' => :instance, 'protected' => :instance,
                       'private_class_method' => :singleton, 'public_class_method' => :singleton }.freeze

  # DEAD_VISIBILITY: `private :x` on a def the compiled gem leaves out of its method tables. Registration removes that
  # def right after the load (`bc2cpp_left_out`), and nothing looks up a method that is not in a table, so the statement
  # acts on something that is gone before anyone can see its visibility: it is not run by anyone, and the def it named
  # is free to leave the mrblib (it was kept only so that this statement found it). Only a visibility send whose every
  # name is such a def (the proof listed it in `unregistered`, the stub proof lets its body go, and the world has
  # exactly one def of that name in that owner) qualifies. `module_function :x` and `alias_method` leave a copy behind,
  # so they are not dead.
  def mark_dead!(mine, all, drop_keys, unregistered)
    return if unregistered.empty?

    count = Hash.new(0)
    all.each { |root| each_ubody(root) { |ub| ub.items.each { |i| count[i.def_key] += 1 if i.role == :def && i.def_key } } }
    mine.each do |root|
      each_ubody(root) do |ub|
        owner = ub.body.path.empty? ? 'Object' : ub.body.path
        ub.items.each do |item|
          next unless item.role == :send

          node = item.stmt.node
          kind = VISIBILITY_SENDS[node.name.to_s] or next
          args = node.arguments&.arguments || []
          next if args.empty? || !args.all? { |a| a.is_a?(Prism::SymbolNode) || a.is_a?(Prism::StringNode) }

          scope = kind == :singleton ? "#{owner}.singleton" : owner
          dead = args.all? do |a|
            key = "#{scope}##{a.unescaped}"
            unregistered.include?(key) && drop_keys.include?(key) && count[key] == 1
          end
          item.role = :dead if dead
        end
      end
    end
  end

  # Fix the roles that must stay residual, over every root of the world (all gems), until nothing changes.
  def promote!(roots)
    order!(roots)
    needed = Set.new
    seed = lambda do |ub|
      # The header of a body whose text may stay (it has a def, a residual statement or a header the compiler cannot
      # run) runs in the residual phase.
      stays = !ub.header_simple || ub.forced || ub.items.any? { |i| %i[def residual].include?(i.role) }
      needed.merge(header_reads(ub)) if stays
    end
    all = []
    roots.each { |root| each_ubody(root) { |ub| all << ub } }
    all.each { |ub| seed.call(ub) }
    all.each { |ub| ub.items.each { |i| needed.merge(reads(i.stmt.node)) if i.role == :residual } }
    loop do
      changed = false
      all.each do |ub|
        ub.items.each do |item|
          name = defined_name(item)
          next unless name && needed.include?(name)

          case item.role
          when :const
            item.role = :residual
            item.promoted = true
            needed.merge(reads(item.stmt.node))
            changed = true
          when :nested
            next if item.child.forced

            item.child.forced = true
            needed.merge(header_reads(item.child))
            changed = true
          end
        end
      end
      break unless changed
    end
  end

  # ---- decisions with the stub proof ------------------------------------------------------------------------

  # The sends that act on a method that must already exist: a name they take cannot be a def the compiled gem
  # installs later. attr_*, include and the like define or extend; they need nothing in place.
  NEEDS_EXISTING = %w[private public protected module_function private_class_method public_class_method alias_method].freeze

  # Symbols a compiled statement names as methods, by name only: they must exist when it runs. With a class graph
  # (`graph`), the source of an alias copy (`alias new old`, `alias_method :new, :old`) pins only the defs of the
  # ancestors of the body it sits in (`sites`, by name: each body's Owner, or :unknown); the new name still pins by
  # name. Without a graph every named symbol pins by name, as before.
  def pinned_names(roots, graph = nil)
    # A hook must exist when the statement it observes runs (HOOK_DEFS).
    names = Set.new(HOOK_DEFS)
    sites = Hash.new { |h, k| h[k] = [] }
    roots.each do |root|
      each_ubody(root) do |ub|
        ub.items.each do |item|
          # By the statement's own form, not by who runs it: a residual `private :x` needs x as much as a compiled one.
          next unless %i[send alias].include?(item.orig_role)
          # A dead statement is not run by anyone.
          next if item.role == :dead

          node = item.stmt.node
          body = %i[class module].include?(ub.body.kind) && !ub.body.path.end_with?('.singleton') ? ub.body.path : :unknown
          if node.is_a?(Prism::AliasMethodNode)
            names << node.new_name.unescaped
            receiver_rule_name?(node.old_name.unescaped, graph) ? sites[node.old_name.unescaped] << body : names << node.old_name.unescaped
          elsif NEEDS_EXISTING.include?(node.name.to_s)
            args = (node.arguments&.arguments || []).select { |arg| arg.is_a?(Prism::SymbolNode) || arg.is_a?(Prism::StringNode) }
            if node.name.to_s == 'alias_method' && args.size == 2 && receiver_rule_name?(args[1].unescaped, graph)
              names << args[0].unescaped
              sites[args[1].unescaped] << body
            else
              args.each { |arg| names << arg.unescaped }
            end
          end
        end
      end
    end
    [names, sites]
  end

  # The copy source of an alias is decided by the class graph only for the staged names (MrblibStubs::RECEIVER_RULE_NAMES).
  def receiver_rule_name?(name, graph) = !graph.nil? && MrblibStubs.receiver_rule_name?(name)

  # Whether the copy sites of a name (pinned_names' sites) may take the def of `def_key` as their source.
  def copy_pinned?(def_key, name, sites, graph)
    list = sites[name]
    return false if list.nil? || list.empty?

    owner = def_key.split('#', 2).first
    list.any? do |site|
      next true if site == :unknown || graph.facts[site].nil? || !graph.facts[site]['exact']

      ClassWorld.ancestors(site, graph.classes, {}).include?(owner)
    end
  end

  def decide!(roots, drop_keys, pinned, stay: false, sites: {}, graph: nil)
    roots.each do |root|
      each_ubody(root) do |ub|
        ub.items.each do |item|
          next unless item.role == :def

          pinned_here = pinned.include?(item.def_name) || (graph && item.def_key && copy_pinned?(item.def_key, item.def_name, sites, graph))
          item.dropped = !item.def_key.nil? && drop_keys.include?(item.def_key) && !pinned_here &&
                         !order_pins.include?(item.def_key)
        end
      end
    end
    roots.each { |root| skeleton!(root, root: true, stay: stay) }
  end

  # A body keeps its header and `end` when anything of it stays: a def, a residual statement, a header the compiler
  # cannot run, a residual need of the class, or a nested body that stays.
  # `stay`: defs only, no compiled load to open a deleted body, so every body keeps its header.
  def skeleton!(ub, root: false, stay: false)
    nested = ub.items.select { |i| i.child }.map { |i| skeleton!(i.child, stay: stay) }
    return true if root

    ub.skeleton = stay || ub.forced || !ub.header_simple || nested.any? ||
                  ub.items.any? { |i| (i.role == :def && !i.dropped) || i.role == :residual }
  end

  # ---- path form ---------------------------------------------------------------------------------------------
  #
  # A nesting header that has no kept text of its own (no def and no residual statement) is in the residual only as
  # the lexical scope of the kept bodies under it. Once the constant it names exists (an earlier residual header
  # created it, of the same kind), the header adds nothing but a lookup scope, so it can go and each kept body under
  # it is written with its full path (`class Outer::Inner`, a constant path from Object). Dropping a scope changes
  # the lookups made from the bodies under it, so a header is removed only when, for every kept body under it:
  #
  #   - its kept text (its defs and residual statements) and its superclass name no constant that a removed scope
  #     defines. The constants a body defines are counted world-wide: nested bodies and class-level constant writes
  #     of every body of that path in every file, in every gem (`table_names`), so a compiled write counts too;
  #   - the first segment of its full path is not a constant of a scope that still encloses it (the path is looked
  #     up from where the header now stands);
  #   - its header is a plain name (`class Inner`, not `class a::Inner`).
  #
  # Also off, for the whole world, when a call reads or writes constants by name (const_set, eval, binding, ...) or
  # a class variable is used: those find a scope some other way. A failing body un-removes its outermost removed
  # scope; the set only shrinks, so the fixpoint ends. The first residual header of a constant is never removed (a
  # removal needs an earlier one), so every constant a removed header named still exists when the residual runs.
  #
  # A header that stays keeps its text, and a body under a removed header with a name that is not plain stays
  # nested (no rewrite): that is a header with `::` in its name, whose lookup this does not model.
  REFLECTION_CALLS = %w[const_set const_get const_defined? class_eval module_eval class_exec module_exec instance_eval
                        instance_exec eval binding const_missing class_variable_get class_variable_set nesting].freeze
  CONST_WRITES = /\AConstant(?:Write|OrWrite|AndWrite|OperatorWrite|Target)Node\z/.freeze

  # Set by path_form! for the gem being planned; empty otherwise, so ranges_for changes nothing in `defs` mode.
  def path_form_sets = [@removed || Set.new.compare_by_identity, @path_form || Set.new.compare_by_identity]

  def path_form!(mine, all, enabled: true)
    @removed = Set.new.compare_by_identity
    @path_form = Set.new.compare_by_identity
    return unless enabled && !reflective_world?(all)

    names = table_names(all)
    plain = plain_scopes(all)
    created = {}
    candidates = Set.new.compare_by_identity
    each_residual_body(mine) do |ub, _ancestors|
      candidates << ub if removable_shape?(ub) && created_before?(ub, created)
      created[ub.body.path] ||= ub.body.kind if %i[class module].include?(ub.body.kind)
    end
    @removed = candidates
    loop do
      failed = path_form_failures(mine, names, plain)
      break if failed.empty?

      failed.each { |ub| @removed.delete(ub) }
    end
    @path_form = Set.new.compare_by_identity
    each_residual_body(mine) { |ub, ancestors| @path_form << ub if !@removed.include?(ub) && ancestors.any? { |a| @removed.include?(a) } }
  end

  # The header is `class Name` or `module Name` with no superclass, and no text of its own in the residual.
  def removable_shape?(ub)
    node = ub.body.node
    return false if kept_text?(ub) || !ub.header_simple || !plain_header?(ub)

    node.is_a?(Prism::ModuleNode) || (node.is_a?(Prism::ClassNode) && node.superclass.nil?)
  end

  # Its constant is created already, with the same kind, and so is every scope that holds it.
  def created_before?(ub, created)
    parts = ub.body.path.split('::')
    created[ub.body.path] == ub.body.kind && (1...parts.size).all? { |n| created.key?(parts[0...n].join('::')) }
  end

  def kept_text?(ub) = ub.items.any? { |i| (i.role == :def && !i.dropped) || i.role == :residual }

  def plain_header?(ub)
    node = ub.body.node
    (node.is_a?(Prism::ClassNode) || node.is_a?(Prism::ModuleNode)) && node.constant_path.is_a?(Prism::ConstantReadNode)
  end

  # Every body whose header runs in the residual, outer first, with the bodies that enclose it (outermost first).
  def each_residual_body(roots, &block)
    roots.each { |root| root.items.each { |item| visit_residual(item.child, [], &block) if item.child } }
  end

  def visit_residual(ub, ancestors, &block)
    return unless ub.skeleton

    block.call(ub, ancestors)
    inner = ancestors + [ub]
    ub.items.each { |item| visit_residual(item.child, inner, &block) if item.child }
  end

  # The bodies to un-remove: a kept body under removed scopes whose lookups would change.
  def path_form_failures(mine, names, plain)
    failed = Set.new.compare_by_identity
    each_residual_body(mine) do |ub, ancestors|
      lost = ancestors.select { |a| @removed.include?(a) }
      next if lost.empty? || @removed.include?(ub)

      outer = lost.first
      # The lookups of a path-form body run through the ancestors of its innermost scope: those must be the same
      # with or without the removed scopes, so every scope around it must be plain (no superclass, no include).
      unless plain_header?(ub) && ancestors.all? { |a| plain[a.body.path] }
        failed << outer
        next
      end
      first = ub.body.path.split('::').first
      remaining = ancestors.reject { |a| @removed.include?(a) }
      if remaining.any? { |a| first_segment_conflict?(first, names[a.body.path]) }
        failed << outer
        next
      end
      refs = Set.new
      ub.items.each { |i| refs.merge(const_refs(i.stmt.node)) if (i.role == :def && !i.dropped) || i.role == :residual }
      node = ub.body.node
      refs.merge(const_refs(node.superclass)) if node.is_a?(Prism::ClassNode) && node.superclass
      lost_names = Set.new(lost.flat_map { |a| names[a.body.path].to_a })
      failed << outer if cref_conflict?(refs, lost_names)
    end
    failed.to_a
  end

  # A reference named in the kept text under a removed scope is one the scope's constants would answer.
  def cref_conflict?(refs, lost_names) = refs.intersect?(lost_names)

  # The path's first segment is looked up from where the rewritten header stands: a constant of a scope that still
  # encloses the body would answer it instead of Object.
  def first_segment_conflict?(first, scope_names) = scope_names.include?(first)

  # Whether every body of a path is a plain scope: a module, or a class with no superclass, and no include or prepend
  # in it (those put constants in the ancestors that a lookup from the scope reaches).
  def plain_scopes(all)
    plain = Hash.new(true)
    all.each do |root|
      each_ubody(root) do |ub|
        node = ub.body.node
        ok = node.is_a?(Prism::ModuleNode) || (node.is_a?(Prism::ClassNode) && node.superclass.nil?)
        ok &&= ub.items.none? { |i| i.stmt.node.is_a?(Prism::CallNode) && %w[include prepend].include?(i.stmt.node.name.to_s) }
        plain[ub.body.path] &&= ok
      end
    end
    plain
  end

  # The constant names a body path defines: nested bodies (their last name), class-level constant writes.
  def table_names(all)
    names = Hash.new { |h, k| h[k] = Set.new }
    all.each do |root|
      each_ubody(root) do |ub|
        ub.items.each do |item|
          if item.child
            names[ub.body.path] << item.child.body.name.to_s.split('::').last
          else
            node = item.stmt.node
            names[ub.body.path] << node.constant_path.slice.split('::').last if node.is_a?(Prism::ClassNode) || node.is_a?(Prism::ModuleNode)
            const_writes(node, names[ub.body.path])
          end
        end
      end
    end
    names
  end

  def const_writes(node, into)
    return into if node.nil? || node.is_a?(Prism::DefNode)

    into << node.name.to_s if node.class.name.split('::').last.match?(CONST_WRITES)
    node.compact_child_nodes.each { |c| const_writes(c, into) }
    into
  end

  # Names a node reads by lexical lookup: a constant read, the first segment of a constant path (`A::B` looks A up),
  # and the constants an operator write reads.
  def const_refs(node, into = Set.new)
    return into if node.nil?

    case node
    when Prism::ConstantReadNode then into << node.name.to_s
    when Prism::ConstantPathNode
      first = node
      first = first.parent while first.is_a?(Prism::ConstantPathNode) && first.parent
      into << first.name.to_s if first.is_a?(Prism::ConstantReadNode)
    when Prism::ConstantOrWriteNode, Prism::ConstantAndWriteNode, Prism::ConstantOperatorWriteNode
      into << node.name.to_s
    end
    node.compact_child_nodes.each { |c| const_refs(c, into) }
    into
  end

  def reflective_world?(all)
    all.any? do |root|
      found = false
      each_ubody(root) do |ub|
        ub.items.each { |item| found ||= reflective?(item.stmt.node) }
      end
      found
    end
  end

  def reflective?(node)
    return false if node.nil?
    return true if node.class.name.split('::').last.start_with?('ClassVariable')
    return true if node.is_a?(Prism::CallNode) && REFLECTION_CALLS.include?(node.name.to_s)

    node.compact_child_nodes.any? { |c| reflective?(c) }
  end

  # The header of a removed body is blanked (its `class`/`module` and name, and its `end`). A kept body under a removed
  # one has its name replaced by its full path.
  def header_ranges(ub, out)
    removed, path_form = path_form_sets
    node = ub.body.node
    if removed.include?(ub)
      out << [node.location.start_offset, node.constant_path.location.end_offset]
      out << [node.end_keyword_loc.start_offset, node.end_keyword_loc.end_offset]
    elsif path_form.include?(ub)
      name = node.constant_path.location
      out << [name.start_offset, name.end_offset, ub.body.path]
    end
  end

  # ---- residual text -----------------------------------------------------------------------------------------

  # Byte ranges of the statements the compiled load takes.
  def ranges_for(ub, out = [])
    ub.items.each do |item|
      loc = item.stmt.node.location
      range = [loc.start_offset, loc.end_offset]
      case item.role
      when :nested
        if item.child.skeleton
          header_ranges(item.child, out)
          ranges_for(item.child, out)
        else out << range end
      when :def then out << range if item.dropped
      when :send, :alias, :const, :ivar, :dead then out << range
      end
    end
    out
  end

  # `text` with the byte `ranges` blanked, newlines kept, so every kept line number is unchanged. A range with a third
  # element is replaced by that text instead (a header written with its full path, PATH_FORM); the ranges do not
  # overlap, so applying them from the last one back leaves every earlier offset where it was.
  def blank(text, ranges)
    out = text.b
    ranges.sort_by(&:first).reverse_each do |s, e, replacement|
      out[s...e] = replacement ? replacement.b : out.byteslice(s...e).gsub(/[^\n]/n, ' '.b)
    end
    out
  end

  def apply(text, ranges, marker: nil)
    out = blank(text, ranges)
    out << "\n#{marker} = true\n".b if marker
    out.force_encoding(text.encoding)
  end

  # ---- C++ ---------------------------------------------------------------------------------------------------

  def cstr(str)
    bytes = str.b.bytes.map do |b|
      case b
      when 0x22 then '\\"'
      when 0x5c then '\\\\'
      when 0x20..0x7e then b.chr
      else format('\\%03o', b)
      end
    end
    "\"#{bytes.join}\""
  end

  # A symbol of a name that outlives the VM (a literal in the binary): interned without a copy.
  def sym(name)
    name = name.to_s
    "mrb_intern_static(M, #{cstr(name)}, #{name.bytesize})"
  end

  # DATA_BLOB: a literal table (Array/Hash of numbers, strings, symbols, constants, ranges) is bytes in .rodata and
  # one decoder, not a call per element. The tags are the decoder's (PRELUDE).
  class Blob
    NIL = 0
    TRUE = 1
    FALSE = 2
    INT = 3
    FLOAT = 4
    SYM = 5
    STR = 6
    FSTR = 7
    ARRAY = 8
    HASH = 9
    RANGE = 10
    CONST = 11
    FREEZE = 12
    SPLAT = 13
    PATH = 14
    TOP = 15
    CALL = 16
    # An Integer past the 32-bit range: its decimal text in the string pool, parsed at load (mruby-bigint).
    BIG = 17
    # A call's arguments are decoded into one array of this size.
    MAX_CALL_ARGS = 8

    def initialize(strings, tableless: Set.new)
      @strings = strings
      @tableless = tableless
    end

    def data?(node)
      case node
      when Prism::IntegerNode then true
      when Prism::FloatNode, Prism::NilNode, Prism::TrueNode, Prism::FalseNode, Prism::SymbolNode,
           Prism::ConstantReadNode then true
      when Prism::StringNode then !ClassBodyScan::Pure.heredoc?(node)
      when Prism::ConstantPathNode then node.parent.nil? || data?(node.parent)
      when Prism::ParenthesesNode then node.body.is_a?(Prism::StatementsNode) && node.body.body.size == 1 && data?(node.body.body.first)
      when Prism::ArrayNode then node.elements.all? { |e| e.is_a?(Prism::SplatNode) ? e.expression && data?(e.expression) : data?(e) }
      when Prism::HashNode then node.elements.all? { |e| e.is_a?(Prism::AssocNode) && data?(e.key) && data?(e.value) }
      when Prism::RangeNode then (node.left.nil? || data?(node.left)) && (node.right.nil? || data?(node.right))
      when Prism::CallNode then freeze_call?(node) || call?(node)
      else false
      end
    end

    def freeze_call?(node) = node.name == :freeze && node.arguments.nil? && node.block.nil? && node.receiver && data?(node.receiver)

    # CALL_TAG: any other pure call (`Color.new(1, 2, 3, 4)`, `OTHER.merge(...)`): receiver, name, arguments in order,
    # sent as the VM's OP_SEND would (ClassBodyScan::Pure.pure_call? has ruled out a block, a splat and a keyword).
    # LOADER_TABLELESS_SEND: a call the decoder sends by name (case 16, mrb_funcall_argv) only when its method stays in
    # the tables. A tableless name (`[]` the method-table elimination unregisters) would raise NoMethodError at gem-init
    # load, aborting the init before the instance-type setup runs. Such a call is not loader data; the compiled class
    # body evaluates it through the proven index dispatch instead.
    def call?(node)
      args = node.arguments&.arguments || []
      return false if @tableless.include?(node.name.to_s)

      ClassBodyScan::Pure.pure_call?(node) && args.size <= MAX_CALL_ARGS && data?(node.receiver) && args.all? { |a| data?(a) }
    end

    # The bytes of `node`.
    def encode(node, out = [])
      case node
      when Prism::NilNode then out << NIL
      when Prism::TrueNode then out << TRUE
      when Prism::FalseNode then out << FALSE
      when Prism::IntegerNode
        if ClassBodyScan::Pure::INT_RANGE.cover?(node.value)
          out << INT
          varint(zigzag(node.value), out)
        else
          out << BIG
          varint(index(node.value.to_s), out)
        end
      when Prism::FloatNode then out << FLOAT
                                 out.concat([node.value].pack('E').bytes)
      when Prism::SymbolNode then out << SYM
                                  varint(index(node.unescaped), out)
      when Prism::StringNode then out << (node.frozen? ? FSTR : STR)
                                  varint(index(node.unescaped), out)
      when Prism::ConstantReadNode then out << CONST
                                        varint(index(node.name.to_s), out)
      when Prism::ConstantPathNode
        if node.parent
          out << PATH
          encode(node.parent, out)
        else
          out << TOP
        end
        varint(index(node.name.to_s), out)
      when Prism::ParenthesesNode then encode(node.body.body.first, out)
      when Prism::ArrayNode
        out << ARRAY
        varint(node.elements.size, out)
        node.elements.each do |e|
          if e.is_a?(Prism::SplatNode)
            out << SPLAT
            encode(e.expression, out)
          else
            encode(e, out)
          end
        end
      when Prism::HashNode
        out << HASH
        varint(node.elements.size, out)
        node.elements.each { |e| encode(e.key, out) && encode(e.value, out) }
      when Prism::RangeNode
        out << RANGE << (node.exclude_end? ? 1 : 0)
        node.left ? encode(node.left, out) : out << NIL
        node.right ? encode(node.right, out) : out << NIL
      when Prism::CallNode
        if freeze_call?(node)
          out << FREEZE
          encode(node.receiver, out)
        else
          args = node.arguments&.arguments || []
          out << CALL
          encode(node.receiver, out)
          varint(index(node.name.to_s), out)
          varint(args.size, out)
          args.each { |a| encode(a, out) }
        end
      else raise "LoadCompile: no blob encoding for #{node.class}"
      end
      out
    end

    # The bytes of a Ruby value PureEval computed (and `PureEval.value_ok?` passed), in the tags above. A frozen
    # container is its bytes under FREEZE; a String carries its own frozen state (STR, FSTR).
    def encode_value(value, out = [])
      freeze = value.frozen? && (value.is_a?(Array) || value.is_a?(Hash))
      out << FREEZE if freeze
      case value
      when nil then out << NIL
      when true then out << TRUE
      when false then out << FALSE
      when Integer
        if ClassBodyScan::Pure::INT_RANGE.cover?(value)
          out << INT
          varint(zigzag(value), out)
        else
          out << BIG
          varint(index(value.to_s), out)
        end
      when Float then out << FLOAT
                      out.concat([value].pack('E').bytes)
      when Symbol then out << SYM
                       varint(index(value.to_s), out)
      when String then out << (value.frozen? ? FSTR : STR)
                       varint(index(value), out)
      when Array
        out << ARRAY
        varint(value.size, out)
        value.each { |e| encode_value(e, out) }
      when Hash
        out << HASH
        varint(value.size, out)
        value.each { |k, v| encode_value(k, out) && encode_value(v, out) }
      when Range
        out << RANGE << (value.exclude_end? ? 1 : 0)
        value.begin.nil? ? out << NIL : encode_value(value.begin, out)
        value.end.nil? ? out << NIL : encode_value(value.end, out)
      else raise "LoadCompile: no blob encoding for #{value.class}"
      end
      out
    end

    def index(str)
      @strings[str.b] ||= @strings.size
    end

    def zigzag(n) = n >= 0 ? n << 1 : ((-n) << 1) - 1

    def varint(n, out)
      loop do
        byte = n & 0x7f
        n >>= 7
        out << (n.zero? ? byte : byte | 0x80)
        break if n.zero?
      end
    end
  end

  # The pure-expression emitter of the statements the program does not fold (legacy). Appends C++ statements to `lines` and returns the C++ name of the value.
  class Expr
    def initialize(lines, counter, scope, tableless: Set.new)
      @lines = lines
      @counter = counter
      @scope = scope
      @tableless = tableless
    end

    # The C++ expression of a node that is one call or immediate (no statements), or nil.
    def simple(node)
      case node
      when Prism::IntegerNode
        node.value.abs < 2**30 ? "mrb_fixnum_value(#{node.value})" : "mrb_int_value(M, (mrb_int)(#{node.value}L))"
      when Prism::FloatNode then "mrb_float_value(M, #{format('%.17g', node.value)})"
      when Prism::NilNode then 'mrb_nil_value()'
      when Prism::TrueNode then 'mrb_true_value()'
      when Prism::FalseNode then 'mrb_false_value()'
      when Prism::SymbolNode then "mrb_symbol_value(#{LoadCompile.sym(node.unescaped)})"
      when Prism::StringNode
        "bc2cpp_ld_str(M, #{LoadCompile.cstr(node.unescaped)}, #{node.unescaped.bytesize}, #{node.frozen? ? 'true' : 'false'})"
      when Prism::ConstantReadNode then "bc2cpp_ld_const(M, &#{@scope}, #{LoadCompile.sym(node.name)})"
      end
    end

    def emit(node)
      if (expr = simple(node))
        return expr.start_with?('mrb_nil', 'mrb_true', 'mrb_false', 'mrb_fixnum', 'mrb_symbol_value') ? expr : temp(expr)
      end

      case node
      when Prism::ConstantPathNode
        base = node.parent ? emit(node.parent) : 'mrb_obj_value(M->object_class)'
        temp("mrb_const_get(M, #{base}, #{LoadCompile.sym(node.name)})")
      when Prism::ParenthesesNode then emit(node.body.body.first)
      when Prism::ArrayNode then array(node)
      when Prism::HashNode then hash(node)
      when Prism::RangeNode
        a = node.left ? emit(node.left) : 'mrb_nil_value()'
        b = node.right ? emit(node.right) : 'mrb_nil_value()'
        temp("mrb_range_new(M, #{a}, #{b}, #{node.exclude_end? ? 'TRUE' : 'FALSE'})")
      when Prism::CallNode then call(node)
      else raise "LoadCompile: no emitter for #{node.class}"
      end
    end

    def temp(expr)
      name = "t#{@counter[0] += 1}"
      @lines << "mrb_value #{name} = #{expr};"
      name
    end

    def array(node)
      arr = temp("mrb_ary_new_capa(M, #{node.elements.size})")
      @lines << "{ const int ai = mrb_gc_arena_save(M);"
      node.elements.each do |el|
        if el.is_a?(Prism::SplatNode)
          @lines << "mrb_ary_concat(M, #{arr}, mrb_ary_splat(M, #{emit(el.expression)}));"
        else
          @lines << "mrb_ary_push(M, #{arr}, #{emit(el)});"
        end
        @lines << 'mrb_gc_arena_restore(M, ai);'
      end
      @lines << '}'
      arr
    end

    def hash(node)
      h = temp("mrb_hash_new_capa(M, #{node.elements.size})")
      @lines << "{ const int ai = mrb_gc_arena_save(M);"
      node.elements.each do |el|
        k = emit(el.key)
        v = emit(el.value)
        @lines << "mrb_hash_set(M, #{h}, #{k}, #{v});"
        @lines << 'mrb_gc_arena_restore(M, ai);'
      end
      @lines << '}'
      h
    end

    def call(node)
      recv = emit(node.receiver)
      args = (node.arguments&.arguments || []).map { |a| emit(a) }
      if @tableless.include?(node.name.to_s) && (helper = tableless_call(node.name.to_s, recv, args))
        return temp(helper)
      end

      temp("mrb_funcall_argv(M, #{recv}, #{LoadCompile.sym(node.name)}, #{args.size}, #{argv(args)})")
    end

    # LOADER_TABLELESS_SEND (the decoder's case 16 twin): a tableless operator (`[]` one key, `[]=` index and value)
    # the residual program kept as a send decodes through the shared index helper, never by name; anything else stays
    # a by-name send (only the names the tables keep reach it).
    def tableless_call(name, recv, args)
      case [name, args.size]
      when ['[]', 1] then "bc2cpp_getidx(M, #{recv}, #{args.first})"
      when ['[]=', 2] then "(bc2cpp_setidx(M, #{recv}, #{args[0]}, #{args[1]}), #{args[1]})"
      end
    end

    # A named array: a compound literal is not C++.
    def argv(args)
      return 'nullptr' if args.empty?

      name = "av#{@counter[0] += 1}"
      @lines << "mrb_value #{name}[] = {#{args.join(', ')}};"
      name
    end
  end

  # ---- the program -------------------------------------------------------------------------------------------

  # CLASS_PROGRAM: the structure statements of the bodies, in source order, as bytes that one decoder
  # (bc2cpp_ld_run, DECODER) runs. A call per statement was most of the load's code; a statement is a few bytes now.
  # The low 3 bits of an op byte are the op:
  #   0 END      leave this body
  #   1 CLASS    name, then flags (bits 3-4: base 0 the body's own class, 1 Object, 2 an expression; bit 5: a
  #              superclass expression follows), the base and the superclass, then the body's ops
  #   2 MODULE   the same without a superclass
  #   3 SCLASS   `class << self` (bits 3-7 zero), or FN (bit 3 set): a statement kept as C++ (hooks, below)
  #   4 CONST    a run: its length, then a name and a value each, set in order (the engine's tables are runs)
  #   5 IVAR     name, value
  #   6 SEND     verb, argument count, then that many values: a send to the body's class (include, alias_method, ...)
  #   7 SENDN    the same with Symbol arguments given as names alone (attr_*, private :a, ...)
  # A name or a verb is an index into the string pool, a value is a Blob.
  OP_END = 0
  OP_CLASS = 1
  OP_MODULE = 2
  OP_SCLASS = 3
  OP_CONST = 4
  OP_IVAR = 5
  OP_SEND = 6
  OP_SENDN = 7
  FN_FLAG = 8
  # Sends are decoded into one array of this size.
  MAX_SEND_ARGS = 64

  # HOOKS: a def with one of these names runs when a statement the program folds is executed (a class with a
  # superclass, an include, an attr or an alias), and it must already exist then. The statements such a world's
  # defs could observe stay C++ statements of their own (`legacy?`), the defs are never dropped, and the hook sees
  # the same state as before. No engine class defines one today.
  HOOK_DEFS = %w[inherited included extended prepended append_features prepend_features extend_object method_added
                 singleton_method_added method_removed singleton_method_removed].freeze
  MIXIN_HOOKS = { 'include' => %w[included append_features], 'extend' => %w[extended extend_object],
                  'prepend' => %w[prepended prepend_features] }.freeze

  def hook_defs(roots)
    names = Set.new
    roots.each { |root| each_ubody(root) { |ub| ub.items.each { |i| names << i.def_name if i.role == :def && HOOK_DEFS.include?(i.def_name) } } }
    names
  end

  # Method names the loader must never send by name: the proof unregisters them from the method tables (`[]`/`[]=`
  # the INDEX_CLOSED verdict admits), so a loader send would raise NoMethodError. Only `[]`/`[]=`-shaped keys enter the
  # set; the helpers reproduce `[]` with one key and `[]=` with index and value.
  def tableless_sends(unregistered)
    unregistered.filter_map { |key| key.split('#', 2).last if key.end_with?('#[]', '#[]=') }.to_set
  end

  # Whether the program must not fold this statement: it can run a hook the world defines.
  def legacy?(item, ctx)
    hooks = ctx[:hooks]
    node = item.stmt.node
    # A value the byte code has no tag for (a call with more than Blob::MAX_CALL_ARGS arguments).
    return !item.fold && !Blob.new({}, tableless: ctx[:tableless]).data?(node.value) if %i[const ivar].include?(item.role)
    return true if item.role == :send && send_args(node).size > MAX_SEND_ARGS
    return false if hooks.empty?

    case item.role
    when :nested then node.is_a?(Prism::ClassNode) && !node.superclass.nil? && hooks.include?('inherited')
    when :alias then hooks.any? { |h| h.end_with?('method_added') }
    when :send
      verb = node.name.to_s
      if MIXIN_HOOKS.key?(verb) then MIXIN_HOOKS.fetch(verb).any? { |h| hooks.include?(h) }
      else hooks.any? { |h| h.end_with?('method_added') }
      end
    else false
    end
  end

  def send_args(node) = node.arguments&.arguments || []

  # The bytes of the statements of `ub`, appended to `out`.
  def program(ub, ctx, out)
    blob = Blob.new(ctx[:strings], tableless: ctx[:tableless])
    run = []
    flush = lambda do
      next if run.empty?

      out << OP_CONST
      blob.varint(run.size, out)
      run.each do |it|
        blob.varint(blob.index(it.stmt.node.name.to_s), out)
        it.fold ? blob.encode_value(it.fold.first, out) : blob.encode(it.stmt.node.value, out)
      end
      run.clear
    end
    ub.items.each do |item|
      # What emits nothing (a def, a mode, a residual statement) does not end a run of constants.
      next if %i[def mode residual dead].include?(item.role)

      legacy = legacy?(item, ctx)
      if item.role == :const && !legacy
        run << item
        next
      end
      flush.call
      if legacy
        out << (OP_SCLASS | FN_FLAG)
        blob.varint(legacy_fn(item, ctx), out)
        next
      end
      node = item.stmt.node
      case item.role
      when :nested then program_nested(item, ctx, blob, out)
      when :ivar
        out << OP_IVAR
        blob.varint(blob.index(node.name.to_s), out)
        blob.encode(node.value, out)
      when :alias
        out << OP_SENDN
        blob.varint(blob.index('alias_method'), out)
        blob.varint(2, out)
        [node.new_name, node.old_name].each { |n| blob.varint(blob.index(n.unescaped), out) }
      when :send then program_send(node, blob, out, ctx)
      end
    end
    flush.call
    out << OP_END
  end

  def program_nested(item, ctx, blob, out)
    node = item.stmt.node
    child = item.child
    if node.is_a?(Prism::SingletonClassNode)
      out << OP_SCLASS
    else
      path = node.constant_path
      base = if path.is_a?(Prism::ConstantReadNode) then 0
             elsif path.parent then 2
             else 1
             end
      superclass = node.is_a?(Prism::ClassNode) && child.header_simple && node.superclass
      out << ((node.is_a?(Prism::ClassNode) ? OP_CLASS : OP_MODULE) | (base << 3) | (superclass ? 0x20 : 0))
      blob.varint(blob.index(path.name.to_s), out)
      blob.encode(path.parent, out) if base == 2
      blob.encode(node.superclass, out) if superclass
    end
    program(child, ctx, out)
  end

  def program_send(node, blob, out, ctx)
    given = send_args(node)
    ctx[:max_send] = [ctx[:max_send], given.size].max
    names = !given.empty? && given.all? { |a| a.is_a?(Prism::SymbolNode) }
    out << (names ? OP_SENDN : OP_SEND)
    blob.varint(blob.index(node.name.to_s), out)
    blob.varint(given.size, out)
    given.each do |a|
      if names then blob.varint(blob.index(a.unescaped), out)
      elsif a.is_a?(Prism::StringNode)
        # `private "x"`: a new unfrozen String, whatever the file's magic comment says.
        out << Blob::STR
        blob.varint(blob.index(a.unescaped), out)
      else blob.encode(a, out)
      end
    end
  end

  # ---- legacy statements -------------------------------------------------------------------------------------

  # A statement the program does not fold, as C++ of its own: a function the program's FN op calls with the body's
  # scope and class. A class statement runs its body's program through bc2cpp_ld_run. These are the statements a
  # hook could observe and the ones with a shape the bytes have no room for (a send of more than MAX_SEND_ARGS
  # arguments, a call of more than MAX_CALL_ARGS): none in the engine today.
  def legacy_fn(item, ctx)
    # Reserved first: a class statement's body can hold statements of its own that are C++ too.
    index = ctx[:legacy].size
    ctx[:legacy] << nil
    fn = "bc2cpp_ld_fn#{index}"
    body = []
    counter = [0]
    case item.role
    when :nested then emit_nested(item, ctx, body, counter)
    when :send then emit_send(item, body, counter, ctx)
    when :alias then emit_alias(item, body)
    when :const, :ivar
      value = Expr.new(body, counter, 'here', tableless: ctx[:tableless]).emit(item.stmt.node.value)
      body << "#{item.role == :const ? 'mrb_const_set' : 'mrb_iv_set'}(M, mrb_obj_value(c), #{sym(item.stmt.node.name)}, #{value});"
      body << 'mrb_gc_arena_restore(M, ai);'
    end
    lines = ["static void #{fn}(mrb_state* M, const bc2cpp_ld_scope* up, struct RClass* c) {",
             '  [[maybe_unused]] const bc2cpp_ld_scope here = {c, up};',
             '  [[maybe_unused]] const int ai = mrb_gc_arena_save(M);']
    body.each { |l| lines << "  #{l}" }
    lines << '}'
    ctx[:legacy][index] = lines.join("\n")
    index
  end

  def emit_nested(item, ctx, body, counter)
    child = item.child
    node = item.stmt.node
    case node
    when Prism::SingletonClassNode
      body << 'struct RClass* c2 = mrb_class_ptr(mrb_singleton_class(M, mrb_obj_value(c)));'
    else
      path = node.constant_path
      ex = Expr.new(body, counter, 'here', tableless: ctx[:tableless])
      base = if path.is_a?(Prism::ConstantReadNode) then 'mrb_obj_value(c)'
             elsif path.parent then ex.emit(path.parent)
             else 'mrb_obj_value(M->object_class)'
             end
      name = sym(path.name)
      if node.is_a?(Prism::ClassNode)
        # A header the compiler cannot run (a call as superclass) ran in the residual phase: reopen without a check.
        sup = child.header_simple && node.superclass ? ex.emit(node.superclass) : 'mrb_nil_value()'
        body << "struct RClass* c2 = mrb_vm_define_class(M, #{base}, #{sup}, #{name});"
      else
        body << "struct RClass* c2 = mrb_vm_define_module(M, #{base}, #{name});"
      end
    end
    sub = []
    program(child, ctx, sub)
    name = "bc2cpp_ld_sub#{ctx[:subs].size}"
    ctx[:subs] << "static const unsigned char #{name}[] = {#{sub.join(',')}};"
    body << "bc2cpp_ld_run(M, &here, c2, #{name});"
    body << 'mrb_gc_arena_restore(M, ai);'
  end

  def emit_send(item, body, counter, ctx)
    node = item.stmt.node
    ex = Expr.new(body, counter, 'here', tableless: ctx[:tableless])
    args = send_args(node).map do |a|
      case a
      when Prism::SymbolNode then ex.temp("mrb_symbol_value(#{sym(a.unescaped)})")
      when Prism::StringNode then ex.temp("mrb_str_new(M, #{cstr(a.unescaped)}, #{a.unescaped.bytesize})")
      else ex.emit(a)
      end
    end
    if ctx[:tableless].include?(node.name.to_s) && (helper = tableless_call(node.name.to_s, 'mrb_obj_value(c)', args))
      body << "#{helper};"
    else
      body << "mrb_funcall_argv(M, mrb_obj_value(c), #{sym(node.name)}, #{args.size}, #{ex.argv(args)});"
    end
    body << 'mrb_gc_arena_restore(M, ai);'
  end

  def emit_alias(item, body)
    node = item.stmt.node
    body << "mrb_value av[] = {mrb_symbol_value(#{sym(node.new_name.unescaped)}), mrb_symbol_value(#{sym(node.old_name.unescaped)})};"
    body << "mrb_funcall_argv(M, mrb_obj_value(c), #{sym('alias_method')}, 2, av);"
    body << 'mrb_gc_arena_restore(M, ai);'
  end

  PRELUDE = <<~'CPP'
    // LOAD_COMPILE (tools/bc2cpp/load_compile.rb): the statements of this gem's class bodies that its residual mrblib
    // leaves out, run in source order.
    #include <mruby.h>
    #include <mruby/array.h>
    #include <mruby/class.h>
    #include <mruby/hash.h>
    #include <mruby/presym.h>
    #include <mruby/range.h>
    #include <mruby/string.h>
    #include <mruby/variable.h>
    extern "C" struct RClass* mrb_vm_define_class(mrb_state*, mrb_value, mrb_value, mrb_sym);
    extern "C" struct RClass* mrb_vm_define_module(mrb_state*, mrb_value, mrb_sym);
    // LOADER_TABLELESS_SEND: the shared index helpers (codegen_ivar_poly.rb) the case-16 decoder calls for `[]`/`[]=`.
    // Weak: the class-body checks link the decoder standalone, without the gem TU that defines them; the real builds
    // resolve the strong definitions. A null check is unnecessary: no check build leaves a `[]`/`[]=` send in loader
    // data without also linking a gem TU (LoadCompile's call? keeps them out of data there too).
    __attribute__((weak)) mrb_value bc2cpp_getidx(mrb_state*, mrb_value, mrb_value);
    __attribute__((weak)) mrb_value bc2cpp_setidx(mrb_state*, mrb_value, mrb_value, mrb_value);
    struct bc2cpp_ld_scope {
      struct RClass* klass;
      const bc2cpp_ld_scope* up;
    };
    // The order of mrb_vm_const_get (3rd/mruby/src/variable.c): the own table of each lexical scope, innermost first,
    // then the ancestors of the innermost scope; a miss runs const_missing on it, as the VM does.
    static inline bool bc2cpp_ld_own(mrb_state* M, mrb_value scope, mrb_sym name, mrb_value* out) {
      if (!(mrb_class_p(scope) || mrb_module_p(scope) || mrb_sclass_p(scope)) || !mrb_iv_defined(M, scope, name)) return false;
      *out = mrb_iv_get(M, scope, name);
      return true;
    }
    static mrb_value bc2cpp_ld_str(mrb_state* M, const char* s, size_t n, bool frozen) {
      mrb_value v = mrb_str_new(M, s, n);
      if (frozen) mrb_obj_freeze(M, v);
      return v;
    }
    static mrb_value bc2cpp_ld_const(mrb_state* M, const bc2cpp_ld_scope* scope, mrb_sym name) {
      mrb_value v;
      for (const bc2cpp_ld_scope* s = scope; s; s = s->up) {
        if (bc2cpp_ld_own(M, mrb_obj_value(s->klass), name, &v)) return v;
      }
      if (bc2cpp_ld_own(M, mrb_obj_value(M->object_class), name, &v)) return v;
      struct RClass* base = scope->klass;
      for (bool retried = false;; retried = true) {
        for (struct RClass* c = retried ? M->object_class : base->super; c; c = c->super) {
          if (MRB_FLAG_TEST(c, MRB_FL_CLASS_IS_PREPENDED)) continue;
          if (bc2cpp_ld_own(M, mrb_obj_value(c->tt == MRB_TT_ICLASS ? c->c : c), name, &v)) return v;
        }
        if (retried || base->tt != MRB_TT_MODULE) break;
      }
      return mrb_const_get(M, mrb_obj_value(base), name);
    }
  CPP

  DECODER = <<~'CPP'
    static mrb_sym bc2cpp_ld_sym(mrb_state* M, unsigned i) {
      return mrb_intern_static(M, bc2cpp_ld_pool + bc2cpp_ld_off[i], bc2cpp_ld_off[i + 1] - bc2cpp_ld_off[i] - 1);
    }
    static unsigned bc2cpp_ld_varint(const unsigned char** p) {
      unsigned v = 0;
      for (int shift = 0;; shift += 7) {
        unsigned char b = *(*p)++;
        v |= (unsigned)(b & 0x7f) << shift;
        if (!(b & 0x80)) return v;
      }
    }
    // DATA_BLOB (tools/bc2cpp/load_compile.rb, Blob): the value a literal table's bytes spell, built as the VM's
    // OP_ARRAY, OP_HASH and OP_RANGE would, in the same order.
    static mrb_value bc2cpp_ld_decode(mrb_state* M, const bc2cpp_ld_scope* scope, const unsigned char** p) {
      const unsigned char tag = *(*p)++;
      switch (tag) {
      case 0: return mrb_nil_value();
      case 1: return mrb_true_value();
      case 2: return mrb_false_value();
      case 3: {
        // 64 bits: the zigzag of -2**31 is 2**32 - 1, and z + 1 wraps in an unsigned.
        const unsigned long long z = bc2cpp_ld_varint(p);
        return mrb_int_value(M, (z & 1) ? -(mrb_int)((z + 1) >> 1) : (mrb_int)(z >> 1));
      }
      case 4: {
        double d;
        memcpy(&d, *p, sizeof d);
        *p += sizeof d;
        return mrb_float_value(M, d);
      }
      case 5: return mrb_symbol_value(bc2cpp_ld_sym(M, bc2cpp_ld_varint(p)));
      case 17: {
        // An Integer past 32 bits: its decimal text, parsed as the VM's integer parse does (mruby-bigint).
        unsigned i = bc2cpp_ld_varint(p);
        mrb_value text = bc2cpp_ld_str(M, bc2cpp_ld_pool + bc2cpp_ld_off[i], bc2cpp_ld_off[i + 1] - bc2cpp_ld_off[i] - 1, false);
        return mrb_str_to_integer(M, text, 10, 1);
      }
      case 6: case 7: {
        unsigned i = bc2cpp_ld_varint(p);
        return bc2cpp_ld_str(M, bc2cpp_ld_pool + bc2cpp_ld_off[i], bc2cpp_ld_off[i + 1] - bc2cpp_ld_off[i] - 1, tag == 7);
      }
      case 8: {
        unsigned n = bc2cpp_ld_varint(p);
        mrb_value a = mrb_ary_new_capa(M, n);
        const int ai = mrb_gc_arena_save(M);
        for (unsigned i = 0; i < n; ++i) {
          if (**p == 13) {
            ++*p;
            mrb_ary_concat(M, a, mrb_ary_splat(M, bc2cpp_ld_decode(M, scope, p)));
          } else {
            mrb_ary_push(M, a, bc2cpp_ld_decode(M, scope, p));
          }
          mrb_gc_arena_restore(M, ai);
        }
        return a;
      }
      case 9: {
        unsigned n = bc2cpp_ld_varint(p);
        mrb_value h = mrb_hash_new_capa(M, n);
        const int ai = mrb_gc_arena_save(M);
        for (unsigned i = 0; i < n; ++i) {
          mrb_value k = bc2cpp_ld_decode(M, scope, p);
          mrb_hash_set(M, h, k, bc2cpp_ld_decode(M, scope, p));
          mrb_gc_arena_restore(M, ai);
        }
        return h;
      }
      case 10: {
        const bool exclusive = *(*p)++;
        mrb_value a = bc2cpp_ld_decode(M, scope, p);
        mrb_value b = bc2cpp_ld_decode(M, scope, p);
        return mrb_range_new(M, a, b, exclusive);
      }
      case 11: return bc2cpp_ld_const(M, scope, bc2cpp_ld_sym(M, bc2cpp_ld_varint(p)));
      case 12: {
        mrb_value v = bc2cpp_ld_decode(M, scope, p);
        mrb_obj_freeze(M, v);
        return v;
      }
      case 14: {
        mrb_value base = bc2cpp_ld_decode(M, scope, p);
        return mrb_const_get(M, base, bc2cpp_ld_sym(M, bc2cpp_ld_varint(p)));
      }
      case 16: {
        // The receiver, the name, then the arguments, in that order.
        mrb_value recv = bc2cpp_ld_decode(M, scope, p);
        const mrb_sym name = bc2cpp_ld_sym(M, bc2cpp_ld_varint(p));
        const unsigned n = bc2cpp_ld_varint(p);
        mrb_value av[@MAX_CALL_ARGS@];
        for (unsigned i = 0; i < n; ++i) av[i] = bc2cpp_ld_decode(M, scope, p);
        // LOADER_TABLELESS_SEND: `[]`/`[]=` never stay loader data (LoadCompile's call?), but the decoder keeps the
        // shape for data the check builds never folded: route the supported arities through the shared index helpers
        // (table-independent), exactly as the compiled send does. Anything else is a build bug: fail loudly instead of
        // raising NoMethodError at gem-init load and aborting the init halfway.
        if (name == MRB_OPSYM(aref) && n == 1) return bc2cpp_getidx(M, recv, av[0]);
        if (name == MRB_OPSYM(aset) && n == 2) { bc2cpp_setidx(M, recv, av[0], av[1]); return av[1]; }
        if (name == MRB_OPSYM(aref) || name == MRB_OPSYM(aset)) {
          mrb_state *mrb = M; // E_NOMETHOD_ERROR names the state `mrb`
          mrb_raisef(M, E_NOMETHOD_ERROR, "tableless loader send '%n' with %d arguments", name, (int)n);
        }
        return mrb_funcall_argv(M, recv, name, n, av);
      }
      default: return mrb_const_get(M, mrb_obj_value(M->object_class), bc2cpp_ld_sym(M, bc2cpp_ld_varint(p)));
      }
    }
    // CLASS_PROGRAM (tools/bc2cpp/load_compile.rb, program): the statements of one body, from `p` to its END, with
    // `c` as the class and `up` as the scopes outside it; returns the byte after the END. What each statement does is
    // what the VM does for it (mrb_vm_define_class/module, SETCONST, a send with the class as receiver), one at a
    // time with the arena given back after each, so an exception or a GC sees the state the bytecode would leave.
    static const unsigned char* bc2cpp_ld_run(mrb_state* M, const bc2cpp_ld_scope* up, struct RClass* c, const unsigned char* p) {
      const bc2cpp_ld_scope here = {c, up};
      const int ai = mrb_gc_arena_save(M);
      for (;;) {
        const unsigned char b = *p++;
        switch (b & 7) {
        case 0: return p;
        case 1: case 2: {
          const mrb_sym name = bc2cpp_ld_sym(M, bc2cpp_ld_varint(&p));
          const unsigned base_kind = (b >> 3) & 3;
          mrb_value base = base_kind == 0 ? mrb_obj_value(c) : base_kind == 1 ? mrb_obj_value(M->object_class) : bc2cpp_ld_decode(M, &here, &p);
          struct RClass* c2;
          if ((b & 7) == 1) {
            mrb_value super = (b & 0x20) ? bc2cpp_ld_decode(M, &here, &p) : mrb_nil_value();
            c2 = mrb_vm_define_class(M, base, super, name);
          } else {
            c2 = mrb_vm_define_module(M, base, name);
          }
          p = bc2cpp_ld_run(M, &here, c2, p);
          break;
        }
        case 3:
    #ifdef BC2CPP_LD_FNS
          if (b & 8) {
            bc2cpp_ld_fn(M, up, c, bc2cpp_ld_varint(&p));
            break;
          }
    #endif
          p = bc2cpp_ld_run(M, &here, mrb_class_ptr(mrb_singleton_class(M, mrb_obj_value(c))), p);
          break;
        case 4:
          for (unsigned n = bc2cpp_ld_varint(&p); n > 0; --n) {
            const mrb_sym name = bc2cpp_ld_sym(M, bc2cpp_ld_varint(&p));
            mrb_const_set(M, mrb_obj_value(c), name, bc2cpp_ld_decode(M, &here, &p));
            mrb_gc_arena_restore(M, ai);
          }
          break;
        case 5: {
          const mrb_sym name = bc2cpp_ld_sym(M, bc2cpp_ld_varint(&p));
          mrb_iv_set(M, mrb_obj_value(c), name, bc2cpp_ld_decode(M, &here, &p));
          break;
        }
        default: {
          const mrb_sym verb = bc2cpp_ld_sym(M, bc2cpp_ld_varint(&p));
          const unsigned n = bc2cpp_ld_varint(&p);
          mrb_value av[@MAX_SEND_ARGS@];
          for (unsigned i = 0; i < n; ++i) {
            av[i] = (b & 7) == 7 ? mrb_symbol_value(bc2cpp_ld_sym(M, bc2cpp_ld_varint(&p))) : bc2cpp_ld_decode(M, &here, &p);
          }
          mrb_funcall_argv(M, mrb_obj_value(c), verb, n, av);
          break;
        }
        }
        mrb_gc_arena_restore(M, ai);
      }
    }
  CPP

  # The plan for one gem of the world.
  #   world:     { gem name => [source files in load order] }, every engine gem of the build
  #   gem:       the gem whose output this is
  #   drop_keys: Owner#name keys of this gem's defs the stub proof lets go (MrblibStubs.stubbable)
  #   symbol:    the compiled gem's out_symbol (names the function and the marker)
  def plan(world, gem:, drop_keys:, symbol:, statements: true, unregistered: Set.new, graph: nil)
    roots = world.transform_values { |files| files.map { |f| build_root(f, statements: statements) } }
    all = roots.values.flatten
    promote!(all)
    mark_dead!(roots.fetch(gem), all, drop_keys, unregistered) if statements
    pinned, sites = pinned_names(all, graph)
    decide!(roots.fetch(gem), drop_keys, pinned, stay: !statements, sites: sites, graph: graph)
    path_form!(roots.fetch(gem), all, enabled: statements)
    mine = roots.fetch(gem)
    files = world.fetch(gem)
    ranges = files.zip(mine).to_h { |file, root| [file, ranges_for(root)] }
    ctx = { legacy: [], subs: [], strings: {}, hooks: hook_defs(all), max_send: 1,
            tableless: tableless_sends(unregistered) }
    prog = []
    # One program for the gem: the files' top-level statements in load order (each ends with its own END).
    mine.each do |root|
      program(root, ctx, prog)
      prog.pop
    end
    prog << OP_END
    marker = "#{MARKER_PREFIX}#{symbol}"
    code = String.new(PRELUDE)
    unless ctx[:legacy].empty?
      code << "#define BC2CPP_LD_FNS 1\n"
      code << "static void bc2cpp_ld_fn(mrb_state* M, const bc2cpp_ld_scope* up, struct RClass* c, unsigned i);\n"
    end
    code << string_pool(ctx[:strings])
    code << DECODER.gsub('@MAX_SEND_ARGS@', ctx[:max_send].to_s).gsub('@MAX_CALL_ARGS@', Blob::MAX_CALL_ARGS.to_s)
    code << ctx[:subs].join("\n") << "\n" unless ctx[:subs].empty?
    code << ctx[:legacy].join("\n\n") << "\n\n" unless ctx[:legacy].empty?
    unless ctx[:legacy].empty?
      code << "static void bc2cpp_ld_fn(mrb_state* M, const bc2cpp_ld_scope* up, struct RClass* c, unsigned i) {\n"
      code << "  static void (* const fns[])(mrb_state*, const bc2cpp_ld_scope*, struct RClass*) = {#{ctx[:legacy].each_index.map { |i| "bc2cpp_ld_fn#{i}" }.join(', ')}};\n"
      code << "  fns[i](M, up, c);\n}\n"
    end
    code << "static const unsigned char bc2cpp_ld_prog[] = {#{prog.join(',')}};\n"
    code << "static void bc2cpp_load_#{symbol}(mrb_state* M) {\n"
    code << "  // Only when the residual mrblib is what loaded: the full mrblib has done all of this.\n"
    code << "  if (!mrb_test(mrb_gv_get(M, #{sym(marker)}))) return;\n"
    code << "  const bc2cpp_ld_scope top = {M->object_class, nullptr};\n"
    code << "  bc2cpp_ld_run(M, &top, M->object_class, bc2cpp_ld_prog);\n"
    code << "}\n"
    # Defs only: nothing for the load to do, so no function and no marker.
    return Result.new(code: '', ranges: ranges, last_file: files.last, marker: nil, stats: stats(mine), bodies: mine,
                      dropped: dropped_defs(mine)) unless statements

    Result.new(code: code, ranges: ranges, last_file: files.last, marker: marker, stats: stats(mine), bodies: mine,
               dropped: dropped_defs(mine))
  end

  # [{owner:, key:, source:}] of the defs the residual no longer has: what the compiled gem's registration supplies.
  def dropped_defs(roots)
    roots.flat_map do |root|
      out = []
      each_ubody(root) do |ub|
        ub.items.each do |i|
          out << { owner: ub.body.path, key: i.def_key, source: i.stmt.node.slice, kind: ub.body.kind } if i.dropped
        end
      end
      out
    end
  end

  # The strings the blobs name: one pool of NUL-terminated strings and the offset of each (plus the end).
  def string_pool(strings)
    ordered = strings.keys
    offsets = [0]
    ordered.each { |str| offsets << offsets.last + str.bytesize + 1 }
    pool = ordered.empty? ? '""' : ordered.map { |str| "#{cstr(str)[0...-1]}\\000\"" }.join("\n  ")
    # 16 bits while the pool is smaller than that (the engine's are some 10 KB).
    type = offsets.last < 2**16 ? 'unsigned short' : 'unsigned'
    "static const char bc2cpp_ld_pool[] =\n  #{pool};\nstatic const #{type} bc2cpp_ld_off[] = {#{offsets.join(', ')}};\n"
  end

  def stats(roots)
    s = Hash.new(0)
    roots.each do |root|
      each_ubody(root) do |ub|
        s[:bodies] += 1
        s[ub.skeleton ? :skeleton_bodies : :deleted_bodies] += 1 unless ub.parent.nil?
        ub.items.each do |i|
          s[:"role_#{i.role}"] += 1
          s[:defs_dropped] += 1 if i.dropped
          s[:defs_kept] += 1 if i.role == :def && !i.dropped
          s[:promoted] += 1 if i.promoted
        end
      end
    end
    s
  end

  # ---- plan files (the manifest the build's rewrite reads) --------------------------------------------------

  def plan_path(out_dir, symbol) = File.join(out_dir, "#{symbol}_load.json")

  # BC2CPP_LOAD_COMPILE: `off` (no plan), `defs` (the residual drops the defs the stub proof lets go and nothing else:
  # no load code, no marker) or `all` (the default: statements compiled too). BC2CPP_LOAD_WORLD: {out_symbol => the gem's mrblib
  # files, as the build loads them}; one build's compiled gems analyse the same world. Nil when off or no world.
  def plan_for_env(env, symbol:, drop_keys:, unregistered: Set.new)
    mode = env.fetch('BC2CPP_LOAD_COMPILE', 'all')
    raise "BC2CPP_LOAD_COMPILE: #{mode.inspect} is not off, defs or all" unless %w[off defs all].include?(mode)
    return nil if mode == 'off' || !env['BC2CPP_LOAD_WORLD']

    world = JSON.parse(env['BC2CPP_LOAD_WORLD'])
    return nil unless world.key?(symbol)

    plan(world, gem: symbol, drop_keys: drop_keys, symbol: symbol, statements: mode == 'all', unregistered: unregistered,
         graph: ClassWorld.from_load_world(env['BC2CPP_LOAD_WORLD']))
  end

  def write_plan(path, result)
    return File.write(path, '{}') if result.nil?

    File.write(path, JSON.generate('marker' => result.marker, 'last' => result.last_file,
                                   'files' => result.ranges.transform_values { |r| r.sort }))
  end

  # { source path => [ranges, marker or nil] } of every plan in `paths`; a missing or empty file adds nothing.
  def read_plans(paths)
    paths.each_with_object({}) do |path, all|
      next unless File.exist?(path)

      data = JSON.parse(File.read(path))
      next if data.empty?

      data.fetch('files').each do |file, ranges|
        all[file] = [ranges, file == data['last'] ? data['marker'] : nil]
      end
    end
  end
end
