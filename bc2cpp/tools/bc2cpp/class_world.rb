# frozen_string_literal: true

# CLASS_WORLD: the class graph of the closed world as the mrblib source states it, without running anything. For
# every class and module a body opens: its superclass, the modules it includes and prepends (the ancestors in
# order), its singleton class's chain, whether a subclass exists, whether more than one body opens it, and which of
# those bodies a load can evaluate statically (ClassBodyScan's COMPILABLE statements) and which keep bytecode.
#
# This is a fact file, not an input to code generation: nothing in bc2cpp reads it yet. scripts/bc2cpp/class_body_check.rb
# compares it with the graph the interpreted load builds, so the day a dispatch decision consumes it, "exact" is
# something a test has already held to. A class is exact when every statement of every body that opens it, and of
# every ancestor's, is one this file models. A computed constant PureEval folds to data is modeled as a constant (the
# same decision LoadCompile makes); a superclass that is a C-defined core class (NATIVE) is known. Anything else (a DSL
# call, `extend self`, a `Class.new` with a computed superclass, `X.include(Y)` inside a method, a lambda constant) makes
# it unknown, with the reason named, and unknown spreads to the
# classes that inherit from it.
require 'json'
require 'prism'
require 'set'
require_relative 'class_body_scan'
require_relative 'pure_eval'

module ClassWorld
  module_function

  # What the runtime defines before any mrblib loads (the C side): name => [ancestors, kind]. The classes Ruby
  # reopens are the ones that matter; a native class missing here is taken as a plain Object subclass.
  NATIVE = {
    'BasicObject' => [%w[BasicObject], :class], 'Kernel' => [%w[Kernel], :module],
    'Object' => [%w[Object Kernel BasicObject], :class], 'Module' => [%w[Module Object Kernel BasicObject], :class],
    'Class' => [%w[Class Module Object Kernel BasicObject], :class], 'Comparable' => [%w[Comparable], :module],
    'Enumerable' => [%w[Enumerable], :module],
    'NilClass' => [%w[NilClass Object Kernel BasicObject], :class], 'TrueClass' => [%w[TrueClass Object Kernel BasicObject], :class],
    'FalseClass' => [%w[FalseClass Object Kernel BasicObject], :class],
    'Numeric' => [%w[Numeric Comparable Object Kernel BasicObject], :class],
    'Integer' => [%w[Integer Numeric Comparable Object Kernel BasicObject], :class],
    'Float' => [%w[Float Numeric Comparable Object Kernel BasicObject], :class],
    'String' => [%w[String Comparable Object Kernel BasicObject], :class],
    'Symbol' => [%w[Symbol Comparable Object Kernel BasicObject], :class],
    'Array' => [%w[Array Enumerable Object Kernel BasicObject], :class],
    'Hash' => [%w[Hash Enumerable Object Kernel BasicObject], :class],
    'Range' => [%w[Range Enumerable Object Kernel BasicObject], :class],
    'Struct' => [%w[Struct Enumerable Object Kernel BasicObject], :class],
    'Proc' => [%w[Proc Object Kernel BasicObject], :class],
    'Exception' => [%w[Exception Object Kernel BasicObject], :class],
    'StandardError' => [%w[StandardError Exception Object Kernel BasicObject], :class],
    # mrb_init_exception (3rd/mruby/src/error.c) defines it under StandardError in every build; it is C-defined, so
    # its chain is fixed. scripts/bc2cpp/class_world_check.rb reads error.c to hold this entry to that.
    'RuntimeError' => [%w[RuntimeError StandardError Exception Object Kernel BasicObject], :class],
    'Enumerator' => [%w[Enumerator Enumerable Object Kernel BasicObject], :class]
  }.freeze
  CLASS_CREATORS = %w[Class Struct Module Data].freeze
  MIXINS = ClassBodyScan::MIXINS
  # Calls that change the class graph when a method runs them.
  GRAPH_CALLS = (MIXINS + %w[define_method class_eval instance_eval module_eval class_exec include_module]).freeze

  Fact = Struct.new(:name, :kind, :superclass, :includes, :prepends, :extends, :bodies, :reasons, :created_by,
                    keyword_init: true)

  # World#classes: name => Fact. #unknown_sites: [{file:, line:, call:, receiver:}] graph calls inside methods whose
  # receiver is not a class this file can name. #subclass_unknown: true when a `Class.new(<computed>)` could have made
  # a subclass of anything.
  World = Struct.new(:classes, :unknown_sites, :subclass_unknown, :facts, keyword_init: true)

  # The class world of a build from its load world (BC2CPP_LOAD_WORLD, JSON {gem symbol => [mrblib files]}), the
  # gems in that order. Nil without one. Shared by the stub proof and the load plan, so both read one graph.
  def from_load_world(json)
    return nil unless json

    build(JSON.parse(json).values.map { |files| ClassBodyScan.scan(files) })
  end

  # `roots`: [ClassBodyScan root, ...] in load order.
  def build(roots)
    defined = Set.new(NATIVE.keys)
    roots.each { |root| root.each_body { |b| defined << b.path if %i[class module].include?(b.kind) } }
    world = World.new(classes: {}, unknown_sites: [], subclass_unknown: false, facts: {})
    NATIVE.each_key { |name| world.classes[name] = native_fact(name) }
    roots.each { |root| walk_body(root, world, defined) }
    roots.each { |root| dynamic_sites(root, world, defined) }
    finish(world)
  end

  # A native class: its superclass is the first class after it in its ancestors, the modules between are its includes.
  def native_fact(name)
    anc, kind = NATIVE.fetch(name)
    sup = kind == :class ? anc.drop(1).find { |a| NATIVE.fetch(a).last == :class } : nil
    mods = sup ? anc[1...anc.index(sup)] : []
    Fact.new(name: name, kind: kind, superclass: sup, includes: mods.reverse, prepends: [], extends: [], bodies: [], reasons: [],
             created_by: :native)
  end

  # The full name of constant `text` seen from lexical scope `scope`, or nil.
  def resolve(text, scope, defined)
    return (defined.include?(text.delete_prefix('::')) ? text.delete_prefix('::') : nil) if text.start_with?('::')

    first, rest = text.split('::', 2)
    parts = scope.split('::')
    until parts.empty?
      cand = (parts + [first]).join('::')
      return [cand, rest].compact.join('::').then { |full| defined.include?(full) ? full : nil } if defined.include?(cand)

      parts.pop
    end
    defined.include?(text) ? text : nil
  end

  def lexical_scope(body) = body.path.sub(/\.singleton\z/, '')

  def walk_body(body, world, defined, target = nil, entry = nil)
    scope = lexical_scope(body)
    case body.kind
    when :class, :module then target, entry = open_body(body, world, defined)
    when :sclass then target = [target, :sclass]
    end
    body.statements.each_with_index do |stmt, index|
      # A statement the compiler does not take keeps this body (and `class << self` inside it) as bytecode, unless
      # PureEval folds it: a computed constant that is data at build time is compiled as a constant (LoadCompile).
      if entry && !ClassBodyScan::COMPILABLE.include?(stmt.category)
        if (folded = folded_constant(body, index))
          entry[:folded] << folded
        else
          entry[:blockers] << stmt.label
        end
      end
      case stmt.category
      when :declarative then declarative(stmt, body, scope, world, defined, target)
      when :const_computed, :const_pure, :dsl_call then creator(stmt, scope, world, defined)
      end
      walk_body(stmt.child, world, defined, target, entry) if stmt.child
    end
  end

  # The label of statement `index` of `body` when it is a computed constant PureEval folds (the same decision as
  # LoadCompile's, with the same `frozen_string_literal` reading), else nil. A folded value is data, so it cannot
  # change the class graph; the statement is then static like a literal constant.
  def folded_constant(body, index)
    stmt = body.statements[index]
    return nil unless stmt.category == :const_computed

    _value, why, _source = PureEval.fold(body.statements, index, magic: frozen_magic?(stmt.file))
    why.nil? ? stmt.label : nil
  end

  def frozen_magic?(file) = File.foreach(file).first(5).any? { |l| l.match?(/\A#\s*frozen_string_literal:\s*true/) }

  # Opens (creating on first sight) the class or module `body` is; returns [Fact, this body's entry].
  def open_body(body, world, defined)
    fact = world.classes[body.path]
    if fact.nil?
      sup = nil
      reasons = []
      if body.kind == :class
        sup = body.superclass ? resolve(body.superclass, lexical_outer(body), defined) : 'Object'
        if sup.nil?
          reasons << "superclass #{body.superclass}"
          sup = :unknown
        end
      end
      fact = Fact.new(name: body.path, kind: body.kind, superclass: sup, includes: [], prepends: [], extends: [], bodies: [],
                      reasons: reasons, created_by: :body)
      world.classes[body.path] = fact
    end
    entry = { file: body.file, line: body.line, blockers: [], folded: [] }
    fact.bodies << entry
    [fact, entry]
  end

  # The scope a header reads its superclass in: the nesting around the body, not the body itself.
  def lexical_outer(body)
    parts = body.path.split('::')
    parts.pop
    parts.join('::')
  end

  def declarative(stmt, body, scope, world, defined, target)
    node = stmt.node
    return unless node.is_a?(Prism::CallNode) && MIXINS.include?(node.name.to_s)

    fact, sclass = target.is_a?(Array) ? target : [target, nil]
    return unless fact

    names = node.arguments.arguments.map { |arg| resolve(arg.slice, scope, defined) || (fact.reasons << "#{node.name} #{arg.slice}"; nil) }.compact
    kind = node.name.to_s
    list = if sclass || kind == 'extend' then fact.extends
           elsif kind == 'prepend' then fact.prepends
           else fact.includes
           end
    # `include A, B` includes B first, then A: the first argument ends up nearest.
    names.reverse_each { |name| list << name }
  end

  # `X = Struct.new(...)` / `Class.new(Base)` as a constant: a class made by a call.
  def creator(stmt, scope, world, defined)
    node = stmt.node
    return unless node.is_a?(Prism::ConstantWriteNode)

    call = node.value
    call = call.receiver while call.is_a?(Prism::CallNode) && call.receiver.is_a?(Prism::CallNode) && call.name != :new
    return unless call.is_a?(Prism::CallNode) && call.name == :new && call.receiver

    recv = call.receiver.slice
    return unless CLASS_CREATORS.include?(recv)

    name = [scope, node.name.to_s].reject(&:empty?).join('::')
    sup = case recv
          when 'Struct' then 'Struct'
          when 'Class'
            arg = call.arguments&.arguments&.first
            arg ? (resolve(arg.slice, scope, defined) || :unknown) : 'Object'
          end
    world.subclass_unknown = true if sup == :unknown
    world.classes[name] ||= Fact.new(name: name, kind: recv == 'Module' ? :module : :class, superclass: recv == 'Module' ? nil : sup,
                                     includes: [], prepends: [], extends: [], bodies: [], reasons: [], created_by: "#{recv}.new")
  end

  # Graph calls in method bodies and blocks: they run later, and can change a class this file thought was done.
  def dynamic_sites(root, world, defined)
    files = Set.new
    root.each_body { |b| files << b.file }
    files.each do |file|
      visit = lambda do |node, scope, inside|
        next unless node

        case node
        when Prism::ClassNode, Prism::ModuleNode
          visit.(node.body, node.constant_path.slice, false)
        when Prism::DefNode
          visit.(node.body, scope, true)
        else
          if inside && node.is_a?(Prism::CallNode) && GRAPH_CALLS.include?(node.name.to_s) && node.receiver
            target = node.receiver.is_a?(Prism::SelfNode) ? scope : resolve(node.receiver.slice, scope, defined)
            if target && world.classes[target]
              world.classes[target].reasons << "#{node.name} at run time (#{File.basename(file)}:#{node.location.start_line})"
            else
              world.unknown_sites << { file: file, line: node.location.start_line, call: node.name.to_s, receiver: node.receiver.slice }
            end
          end
          if inside && node.is_a?(Prism::CallNode) && node.name == :new && node.receiver&.slice == 'Class'
            arg = node.arguments&.arguments&.first
            world.subclass_unknown = true if arg && !resolve(arg.slice, scope, defined)
            (world.facts[:anonymous] ||= []) << (arg && resolve(arg.slice, scope, defined)) if arg
          end
          node.compact_child_nodes.each { |c| visit.(c, scope, inside) }
        end
      end
      visit.(Prism.parse(File.read(file)).value, '', false)
    end
  end

  # ---- derived facts ---------------------------------------------------------------------------------------

  # Final: ancestors, singleton chain, final, reopened, exact. Returns the world.
  def finish(world)
    classes = world.classes
    anonymous = world.facts[:anonymous] || []
    classes.each_value { |f| f.bodies.each { |b| b[:evaluated] = b[:blockers].empty? ? :static : :bytecode } }
    out = {}
    classes.each do |name, fact|
      anc = ancestors(name, classes, {})
      out[name] = {
        'kind' => fact.kind.to_s, 'superclass' => fact.superclass == :unknown ? nil : fact.superclass,
        'ancestors' => anc, 'includes' => fact.includes, 'prepends' => fact.prepends,
        'singleton_chain' => singleton_chain(name, classes),
        'final' => fact.kind == :module ? nil : final?(name, classes, anonymous, world),
        'reopened' => reopened?(fact),
        'created_by' => fact.created_by.to_s,
        'bodies' => fact.bodies.map do |b|
          { 'file' => b[:file], 'line' => b[:line], 'evaluated' => b[:evaluated].to_s, 'blockers' => b[:blockers], 'folded' => b[:folded] }
        end,
        'reasons' => fact.reasons.uniq
      }
    end
    out.each { |name, h| h['exact'] = exact?(name, classes, out, {}) }
    world.facts = out
    world
  end

  def reopened?(fact) = fact.bodies.size > 1 || (fact.created_by == :native && fact.bodies.size.positive?)

  def final?(name, classes, anonymous, world)
    return nil if world.subclass_unknown

    classes.none? { |n, f| n != name && f.superclass == name } && !anonymous.include?(name)
  end

  # Ancestors in Ruby's order: prepends (the latest first), the class, includes (the latest first, each module's own
  # chain), the superclass's. A module already further up the chain is not added again.
  def ancestors(name, classes, memo)
    return memo[name] if memo.key?(name)

    fact = classes[name]
    return memo[name] = [name] unless fact

    supers = fact.superclass.is_a?(String) ? ancestors(fact.superclass, classes, memo) : []
    mods = []
    fact.includes.each do |inc|
      ancestors(inc, classes, memo).each { |m| mods.unshift(m) unless mods.include?(m) || supers.include?(m) }
    end
    pre = []
    fact.prepends.each do |inc|
      ancestors(inc, classes, memo).each { |m| pre.unshift(m) unless pre.include?(m) }
    end
    memo[name] = pre + [name] + mods + supers
  end

  def singleton_chain(name, classes)
    fact = classes[name]
    return [] unless fact

    own = ["#<Class:#{name}>"]
    fact.extends.each { |m| ancestors(m, classes, {}).reverse_each { |a| own.insert(1, a) unless own.include?(a) } }
    tail = if fact.kind == :module then %w[Module Object Kernel BasicObject]
           elsif fact.superclass.is_a?(String) then singleton_chain(fact.superclass, classes)
           else %w[Class Module Object Kernel BasicObject]
           end
    own + tail.reject { |c| own.include?(c) && !c.start_with?('#<') && fact.kind != :module }
  end

  # Exact: nothing that opens this class, or any ancestor of it, is outside what this file models.
  def exact?(name, classes, out, seen)
    return seen[name] if seen.key?(name)

    seen[name] = true
    h = out[name]
    return false unless h

    ok = h['reasons'].empty? && h['bodies'].all? { |b| b['evaluated'] == 'static' }
    ok &&= h['superclass'].nil? || classes[name].kind == :module || exact?(h['superclass'], classes, out, seen)
    ok &&= (h['includes'] + h['prepends']).all? { |m| exact?(m, classes, out, seen) }
    seen[name] = ok
  end

  # [exact count, unknown count, reasons tally] for the report.
  def summary(world)
    exact = world.facts.count { |_, h| h['exact'] }
    reasons = Hash.new(0)
    world.facts.each_value { |h| h['bodies'].each { |b| b['blockers'].each { |r| reasons[r] += 1 } } }
    { 'classes' => world.facts.size, 'exact' => exact, 'unknown' => world.facts.size - exact,
      'bodies_static' => world.facts.sum { |_, h| h['bodies'].count { |b| b['evaluated'] == 'static' } },
      'bodies_bytecode' => world.facts.sum { |_, h| h['bodies'].count { |b| b['evaluated'] == 'bytecode' } },
      'unknown_sites' => world.unknown_sites.size, 'subclass_unknown' => world.subclass_unknown, 'blockers' => reasons }
  end

  def to_json(world) = JSON.pretty_generate('summary' => summary(world), 'unknown_sites' => world.unknown_sites, 'classes' => world.facts)
end
