# frozen_string_literal: true

# MRBLIB_STUBS: a closed build ships each engine gem's mrblib with the bodies of compiled methods emptied. Once the
# compiled gems' gem_init has run, such a body never runs again as bytecode: the compiled registration replaces it,
# or bc2cpp_left_out removes it. So its bytecode, and every symbol only it names, need not be in the binary.
#
# A body keeps its bytecode when it may run before that gem_init (StaticDispatchRegistrations.load_phase), when
# loading copies its method (module_function, alias, COPYING_SENDS), when the guard keeps the interpreted method
# (CORE_BLOCK_GUARD), or when its Owner#name is not exactly one plain `def`. A stub that runs anyway raises
# ScriptError, which a `rescue => e` does not catch. See docs/bc2cpp-mrblib-stubs.md.
require 'json'
require 'prism'
require 'set'
require 'shellwords'
require_relative 'bytecode_ir_classes'
require_relative 'class_world'
require_relative 'codegen_enum_step'

module MrblibStubs
  module_function

  STUB_BODY = 'raise ScriptError'
  # Sends that copy a method object while mrblib loads, or take one: a copy keeps the stubbed body after the compiled
  # registration replaced the original.
  COPYING_SENDS = %w[alias_method define_method instance_method method module_function].freeze
  # The visibilities bc2cpp_register_owner_methods registers (codegen_emit.rb emit_owner_registration_lines).
  REGISTERED_VISIBILITY = %i[public private].freeze

  # BC2CPP_STUB_LOG=<file>: why a compiled method's body is kept in the residual (one line per kept method).
  def stub_keep_reason(m, key, defs, load_bodies, copied, copied_names, copy_sites, world)
    # A guarded body is the fallback of the Fiber path. Under ENUM_STEP only a form that covers it lets it go.
    return 'guarded' if m[:guard] && !EnumStep.stubs_body?(m, m[:owner].end_with?('.singleton'))
    return "defs=#{defs.size}" unless defs.size == 1

    d = defs.first
    return 'native or attr or installer' if d.irep.nil? || d.kind || d.installer
    return 'copied source' if d.copy_irep
    return 'runs at load' if load_bodies.include?(d.irep)
    return 'loaded copy' if copied.include?(d.irep)
    return 'copy by name' if copied_names.include?(m[:name]) && copy_source?(d.owner, m[:name], copy_sites[m[:name]], world)

    nil
  end

  def stub_keep_log(key, reason)
    path = ENV['BC2CPP_STUB_LOG']
    return if path.nil? || path.empty?

    File.write(path, "#{reason}\t#{key}\n", mode: 'a')
  end

  # The Owner#name keys of `compiled` (this run's entries) whose bodies can be stubbed. `all_defs`: every bytecode
  # definition, the core ones the generation's registry no longer holds included. The load phase reads it: a method
  # body missing from it would count as code that runs at load.
  def stubbable(compiled, ireps, registry, all_defs = registry, world: nil)
    require_relative 'static_dispatch_registrations'
    body_of = {}
    all_defs.each { |name, defs| defs.each { |d| body_of[d.irep] = [d.owner, name] if d.irep } }
    parent = {}
    ireps.each_value { |irep| irep.reps.each { |c| parent[c.respond_to?(:label) ? c.label : c] = irep.label } }
    method_of = ireps.keys.to_h do |label|
      up = label
      up = parent[up] until up.nil? || body_of.key?(up)
      [label, up]
    end
    # Every plain engine def counts as overridden, a superset of the registered ones: load_phase only reads it to
    # decide which classes' instances matter, so more owners can only keep more bodies.
    overridden = body_of.each_value.map { |owner, name| "#{owner}##{name}" }.to_set
    load_bodies, = StaticDispatchRegistrations.load_phase(ireps, body_of, method_of, overridden)
    copied = [registry, all_defs].flat_map { |r| r.values.flatten.filter_map(&:copy_irep) }.to_set
    copied_names = copied_names(ireps)
    copy_sites = copy_sites(ireps, parent)
    defs_of = Hash.new { |h, k| h[k] = [] }
    registry.each { |name, defs| defs.each { |d| defs_of["#{d.owner}##{name}"] << d } }
    all_of = Hash.new { |h, k| h[k] = [] }
    all_defs.each { |name, defs| defs.each { |d| all_of["#{d.owner}##{name}"] << d } }
    compiled.filter_map do |m|
      key = "#{m[:owner]}##{m[:name]}"
      defs = defs_of[key]
      # CORE_VISIBILITY: a core def whose name a native shares, or an operator name, is no registry definition, yet it
      # is compiled and registered (bc2cpp_register_owner_methods), so the registration replaces its one bytecode def
      # at gem_init just as a registry def's is. Judge that def. Any other visibility is not registered that way.
      defs = all_of[key] if defs.empty? && REGISTERED_VISIBILITY.include?(m[:visibility])
      reason = stub_keep_reason(m, key, defs, load_bodies, copied, copied_names, copy_sites, world)
      next key if reason.nil?

      stub_keep_log(key, reason)
      nil
    end.to_set
  end

  # COPY SITES. A copy by name takes its source from the receiver's method lookup. A site in a class body whose
  # receiver is that body's own class R (`self`) copies from R's ancestors: so a def whose owner is not one of them
  # cannot be the copied method. Every other site (a method or block, a singleton class, the top level, a receiver
  # other than self, `method`, `define_method`) may copy from anywhere: :unknown.
  COPY_FROM_SELF = %w[alias_method module_function instance_method].freeze
  # The names the receiver rule decides: nil, every copied name. A copy takes the def of an ancestor of the class it runs in
  # only, so a def of an unrelated class (`RPG2k#push` next to `alias append push` in Array) is not its source.
  RECEIVER_RULE_NAMES = nil

  # Whether the receiver rule decides a copied +name+ (load_compile.rb asks the same question).
  def receiver_rule_name?(name) = RECEIVER_RULE_NAMES.nil? || RECEIVER_RULE_NAMES.include?(name)

  # A rep is an Irep, or its label (the parent map below reads both).
  def rep_label(rep) = rep.respond_to?(:label) ? rep.label : rep

  # { label => class path of the irep when it is a class or module body whose path bytecode states, else nil }.
  # A body whose opener's outer scope is not a known namespace has no path, and neither do its nested bodies.
  def class_body_paths(ireps, parent)
    paths = {}
    stack = ireps.keys.reject { |l| parent.key?(l) }.map { |l| [l, nil] }
    until stack.empty?
      label, ns = stack.pop
      irep = ireps.fetch(label)
      openers = BytecodeIR.class_bodies(irep, :CLASS, :MODULE)
      body_labels = openers.values.map { |child| rep_label(child) }.to_set
      openers.each do |idx, child|
        path = ns == :unknown ? nil : BytecodeIR.class_body_path(irep, idx, ns)
        paths[rep_label(child)] = path
        stack << [rep_label(child), path || :unknown]
      end
      irep.reps.each do |child|
        next if body_labels.include?(rep_label(child))

        stack << [rep_label(child), :unknown]
      end
    end
    paths
  end

  # { name => [class path String or :unknown, ...] }: the receiver of every site that may copy `name`.
  def copy_sites(ireps, parent)
    paths = class_body_paths(ireps, parent)
    sites = Hash.new { |h, k| h[k] = [] }
    ireps.each do |label, irep|
      own = paths[label] || :unknown
      ir = BytecodeIR.for(irep)
      ir.instructions_with_op(:ALIAS).each do |insn|
        old = insn.first_of(:name)&.value
        sites[old.to_s] << own if old
      end
      copies = ir.instructions_with_op(*BytecodeIR::Ops::SEND).select { |insn| COPYING_SENDS.include?(insn.sym.to_s) }
      next if copies.empty?

      self_copy = own != :unknown && copies.all? do |insn|
        BytecodeIR::Ops::SELF_SEND.include?(insn.op) && COPY_FROM_SELF.include?(insn.sym.to_s)
      end
      ir.instructions_with_op(:LOADSYM).each { |insn| sites[insn.sym.to_s] << (self_copy ? own : :unknown) }
    end
    sites
  end

  # Whether a copy at one of +sites+ (the copy_sites entries of a name) may take the def of +owner+ as its source.
  # Without a class world, or for a site whose class is not exact, every copy may. Otherwise: only a site whose
  # class's ancestors (ClassWorld.ancestors, every ancestor of an exact class exact too) include +owner+.
  def copy_source?(owner, name, sites, world)
    return true if world.nil? || sites.nil? || sites.empty? || !receiver_rule_name?(name)

    class_owner = class_owner?(owner, world)
    sites.any? do |site|
      next true if site == :unknown || world.facts[site].nil?
      # A class is an ancestor only through a superclass link, and a run-time include adds modules, never a superclass:
      # for a class owner the static superclass chain is enough.
      next true unless (class_owner && superclass_chain_known?(site, world)) || world.facts[site]['exact']

      ClassWorld.ancestors(site, world.classes, {}).include?(owner)
    end
  end

  # Whether +owner+ is a plain class (not a module, not a singleton class) in the class world.
  def class_owner?(owner, world)
    fact = world.facts[owner]
    !fact.nil? && fact['kind'] == 'class' && !owner.include?('.singleton')
  end

  # Whether every class on +name+'s superclass chain is known: its bodies are static, its only reasons are run-time
  # includes (`include at run time`: they add modules, not superclasses), and its superclass is in the world too.
  def superclass_chain_known?(name, world)
    seen = Set.new
    until name.nil?
      return false unless seen.add?(name)

      fact = world.facts[name]
      return false unless fact && fact['kind'] == 'class'
      return false unless fact['bodies'].all? { |b| b['evaluated'] == 'static' }
      return false unless fact['reasons'].all? { |r| r.start_with?('include at run time') }

      name = fact['superclass']
    end
    true
  end

# The class world of a build: the engine gems' mrblib as the load world names them (BC2CPP_LOAD_WORLD, JSON
# {gem symbol => [files]}), plus the core mrblib the program loads (FOREIGN_RUBY_SRCS): a copy's site may be a core
# class (IO, say) whose facts only the core files give. Nil without a load world (the rule then keeps every copied name).
# Only the stub decision reads this world: codegen and LoadCompile keep the load world alone.
def class_world_from_env(env)
  return nil unless env['BC2CPP_LOAD_WORLD']

  world = JSON.parse(env['BC2CPP_LOAD_WORLD'])
  core = Shellwords.split(env.fetch('FOREIGN_RUBY_SRCS', ''))
  world['core'] = core.map { |f| File.expand_path(f) } unless core.empty?
  ClassWorld.from_load_world(JSON.generate(world))
end

  # By name, whatever the owner: the source of every `alias`, and every Symbol an irep that sends a COPYING_SENDS
  # name loads.
  def copied_names(ireps)
    ireps.each_value.each_with_object(Set.new) do |irep, names|
      ir = BytecodeIR.for(irep)
      ir.instructions_with_op(:ALIAS).each { |insn| (old = insn.first_of(:name)&.value) && names << old.to_s }
      sends = copying_sends(ir)
      next if sends.empty?

      # The names the copying sends take, when each argument is pinned to one symbol literal. Otherwise every symbol
      # literal of the body counts (the conservative reading this used to take everywhere).
      literal = copy_argument_names(ir, sends)
      if literal
        names.merge(literal)
      else
        ir.instructions_with_op(:LOADSYM).each { |insn| names << insn.sym.to_s }
      end
    end
  end

  # [index, insn] of each send in +ir+ whose method is a copying one (COPYING_SENDS).
  def copying_sends(ir)
    found = []
    ir.each_source do |insn, idx|
      found << [idx, insn] if BytecodeIR::Ops::SEND.include?(insn.op) && COPYING_SENDS.include?(insn.sym.to_s)
    end
    found
  end

  # The symbols the copying sends take, from the symbol literals loaded into their argument registers. Nil unless every
  # argument register has exactly one mention in the body (the send's own uses aside), and that mention is a LOADSYM
  # before the send: then the register holds that symbol on every path that reaches the send, so no other literal can
  # be the argument. A splat, a keyword argument or any other use of the register makes it nil.
  def copy_argument_names(ir, sends)
    mentions = Hash.new { |h, k| h[k] = [] }
    ir.each_source { |insn, idx| insn.regs.each { |reg| mentions[reg] << idx } }
    names = Set.new
    sends.each do |send_idx, send|
      return nil if send.positional_splat? || send.keyword_arguments? || send.argc.nil?

      (1..send.argc.to_i).each do |k|
        reg = send.reg.to_i + k
        uses = mentions[reg] - [send_idx]
        return nil unless uses.size == 1 && uses.first < send_idx

        writer = ir.source_at(uses.first)
        return nil unless writer.op == :LOADSYM && writer.reg == reg

        names << writer.sym.to_s
      end
    end
    names
  end

  # `src` with the body of every def whose lexical Owner#name is in `keys` replaced by STUB_BODY. Only defs directly
  # in a class or module body (also under `class << self` and in conditionals) count; one in a block or a method is
  # not lexically owned. A key matched twice in one file stays as it is. Returns [source, stubbed keys].
  def rewrite(src, keys)
    finder = DefFinder.new(keys, src.b)
    Prism.parse(src).value.accept(finder)
    once = finder.hits.group_by(&:first).select { |_k, hits| hits.size == 1 }
    out = src.b
    once.values.flatten(1).sort_by { |_k, range| -range.first }.each do |_k, range|
      out[range] = STUB_BODY.b
    end
    # Every def the file owned must still be there: a range that took a def line would drop the method at load.
    after = DefFinder.new(Set.new, out)
    Prism.parse(out).value.accept(after)
    raise "MRBLIB_STUBS: the rewrite changed the file's defs" unless after.seen == finder.seen

    [out, once.keys.to_set]
  end

  # The defs of a parsed file, with the owner the registry gives each (Owner, Owner.singleton).
  class DefFinder < Prism::Visitor
    attr_reader :hits, :seen

    def initialize(keys, src)
      super()
      @keys = keys
      @src = src
      @nest = []
      @singleton = false
      @hits = []
      @seen = []
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

    def visit_block_node(_node) = nil
    def visit_lambda_node(_node) = nil

    def visit_def_node(node)
      return if node.receiver && !node.receiver.is_a?(Prism::SelfNode)

      owner = @nest.join('::')
      owner += '.singleton' if node.receiver || @singleton
      key = "#{owner}##{node.name}"
      @seen << key
      @hits << [key, body_range(node)] if node.body && @keys.include?(key)
      # A def inside a method body is defined when that method runs, not here.
    end

    private

    # A def with rescue/else/ensure has an implicit begin as its body, located from `def` to `end`: the range runs
    # from its first clause to the whitespace before `end` instead.
    def body_range(node)
      body = node.body
      return body.location.start_offset...body.location.end_offset unless body.is_a?(Prism::BeginNode)

      first = [body.statements, body.rescue_clause, body.else_clause, body.ensure_clause].compact.first
      stop = node.end_keyword_loc.start_offset
      stop -= 1 while stop > first.location.start_offset && @src.getbyte(stop - 1).chr.match?(/\s/)
      first.location.start_offset...stop
    end

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

  # The manifest each compiled gem's generation writes beside its code, one Owner#name per line.
  def manifest_path(out_dir, symbol) = File.join(out_dir, "#{symbol}_stubs.txt")

  def read_manifests(paths) = paths.flat_map { |p| File.readlines(p, chomp: true) }.reject(&:empty?).to_set

  # Writes `dst`, the stubbed copy of mrblib file `src`, from the compiled gems' manifests. `plans`: the load plans
  # (LoadCompile.read_plans) -- the statements and defs the compiled load takes are blanked first, so the stub rewrite
  # sees the residual, and the file the load ends on sets the marker that turns the compiled load on.
  def write_stubbed(src, dst, manifests, plans = {})
    text = File.binread(src)
    ranges, marker = plans[File.expand_path(src)]
    if ranges
      require_relative 'load_compile'
      text = LoadCompile.apply(text, ranges, marker: marker)
    end
    out, = rewrite(text, read_manifests(manifests))
    File.binwrite(dst, out)
  end
end
