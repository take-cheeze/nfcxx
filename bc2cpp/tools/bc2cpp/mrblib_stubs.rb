# frozen_string_literal: true

# MRBLIB_STUBS: a closed build ships each engine gem's mrblib with the bodies of compiled methods emptied. Once the
# compiled gems' gem_init has run, such a body never runs again as bytecode: the compiled registration replaces it,
# or bc2cpp_left_out removes it. So its bytecode, and every symbol only it names, need not be in the binary.
#
# A body keeps its bytecode when it may run before that gem_init (StaticDispatchRegistrations.load_phase), when
# loading copies its method (module_function, alias, COPYING_SENDS), when the guard keeps the interpreted method
# (CORE_BLOCK_GUARD), or when its Owner#name is not exactly one plain `def`. A stub that runs anyway raises
# ScriptError, which a `rescue => e` does not catch. See docs/bc2cpp-mrblib-stubs.md.
require 'prism'
require 'set'

module MrblibStubs
  module_function

  STUB_BODY = 'raise ScriptError'
  # Sends that copy a method object while mrblib loads, or take one: a copy keeps the stubbed body after the compiled
  # registration replaced the original.
  COPYING_SENDS = %w[alias_method define_method instance_method method module_function].freeze

  # The Owner#name keys of `compiled` (this run's entries) whose bodies can be stubbed. `all_defs`: every bytecode
  # definition, the core ones the generation's registry no longer holds included. The load phase reads it: a method
  # body missing from it would count as code that runs at load.
  def stubbable(compiled, ireps, registry, all_defs = registry)
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
    defs_of = Hash.new { |h, k| h[k] = [] }
    registry.each { |name, defs| defs.each { |d| defs_of["#{d.owner}##{name}"] << d } }
    compiled.reject { |m| m[:guard] }.filter_map do |m|
      key = "#{m[:owner]}##{m[:name]}"
      defs = defs_of[key]
      next unless defs.size == 1

      d = defs.first
      next if d.irep.nil? || d.kind || d.installer || d.copy_irep
      next if load_bodies.include?(d.irep) || copied.include?(d.irep) || copied_names.include?(m[:name])

      key
    end.to_set
  end

  # By name, whatever the owner: the source of every `alias`, and every Symbol an irep that sends a COPYING_SENDS
  # name loads.
  def copied_names(ireps)
    ireps.each_value.each_with_object(Set.new) do |irep, names|
      ir = BytecodeIR.for(irep)
      ir.instructions_with_op(:ALIAS).each { |insn| (old = insn.first_of(:name)&.value) && names << old.to_s }
      next unless ir.instructions_with_op(*BytecodeIR::Ops::SEND).any? { |insn| COPYING_SENDS.include?(insn.sym.to_s) }

      ir.instructions_with_op(:LOADSYM).each { |insn| names << insn.sym.to_s }
    end
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
