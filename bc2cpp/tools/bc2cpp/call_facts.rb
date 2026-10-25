# frozen_string_literal: true

require 'set'
require_relative 'bytecode_ir_ops'
require_relative 'numeric_flow'
require_relative 'bytecode_ir'
require_relative 'foreign_definers'
require_relative 'core_hierarchy_sigs'
require_relative 'native_owner_map'

# CALL_FACTS: what a call that returned normally says about its receiver.
#
# After `r.m(...)` returns, the object in `r` answered `m`, so a later use of the same value (a copy of
# the register, a local) can only be an instance of a class that answers `m`. Flow is the forward "must"
# analysis of those facts; Answers is the closed-world question "which classes answer `m`".
module CallFacts
  # mruby core classes the closed world does not declare (superclass) and the modules the core mixes into them,
  # from sig/bc2cpp/declarations.rbs#core_hierarchy.
  CORE_SUPER, CORE_MIXINS = CoreHierarchySigs.hierarchy
  # A definer on one of these answers every object: Object's ancestors (Object, Kernel, BasicObject).
  EVERYTHING = CoreHierarchySigs.ancestors('Object').to_set.freeze
  CORE_MODULES = %w[Kernel Comparable Enumerable Math GC ObjectSpace Process Signal Marshal FileTest Errno].freeze
  CLASS_OBJECT = '<ClassObject>'
  # Class and its superclasses below Object (Class, Module).
  CLASS_OR_MODULE = CoreHierarchySigs.superclasses_below('Class', 'Object').to_set.freeze
  # Names whose answer depends on a hook, not on a definition.
  HOOK_NAMES = %w[method_missing respond_to_missing? initialize].freeze

  # The world Answers reads; nil fields make every question "unknown".
  # instance_installed is installed without the names only a class object sees.
  World = Struct.new(:closed_world, :registry, :superclass_of, :included, :prepended, :unknown_mixins,
                     :native_sources, :installed, :instance_installed, :compiled_core, keyword_init: true)

  # Which classes answer a method name. A name nothing bounds (installed by computed code, a hook, a
  # definer on Object/Kernel/BasicObject, a native whose owner the scan cannot read) answers for every
  # object, so no fact comes of it.
  class Answers
    def initialize(world)
      @w = world
      @cw = world.closed_world
      @memo = {}
      @ancestors = {}
      @members = {}
      if ENV['BC2CPP_CALL_LOOKUP_INDEX'] != '0'
        @lookup_paths = {}
        @simple_names = {}
        @ruby_owners = {}
      end
    end

    def simple(name)
      return name.to_s.split('::').last unless @simple_names
      return @simple_names[name] if @simple_names.key?(name)

      @simple_names[name] = name.to_s.split('::').last&.freeze
    end

    # Every class an object can be an instance of that this analysis knows: declared, core, native.
    def classes
      @classes ||= (@cw.declared_class_names + CORE_SUPER.keys.reject { |k| k == 'BasicObject' } +
                    (native_class_names - CORE_MODULES) + [CLASS_OBJECT]).uniq
    end

    def native_class_names
      @native_class_names ||= (registrations.each_value.flat_map { |es| es.filter_map { |e| e[:owner]&.fetch(:class_name, nil) } } +
                               opaque_owners.values.flatten.compact).uniq
    end

    def registrations = native_scan[0]

    def opaque_owners = native_scan[1]

    # name => [{owner:, function:, path:, macro:}] of the registrations a class or module object answers
    # (`Array.[]`, a Struct class's `.[]`, module functions), which `registrations` leaves out.
    def class_registrations
      @class_registrations ||= begin
        paths = @w.native_sources ? @w.native_sources.values.flatten.uniq : []
        NativeExpressionDevirt.class_method_registrations(paths)
      end
    end

    def native_scan
      @native_scan ||= begin
        paths = @w.native_sources ? @w.native_sources.values.flatten.uniq : []
        regs, opaque = NativeExpressionDevirt.class_registrations(paths)
        [regs.to_h, opaque.to_h]
      end
    end

    # [simple names of the ancestors of +klass+, true when part of the chain is unknown].
    def ancestors(klass)
      @ancestors[klass] ||= compute_ancestors(klass)
    end

    # What defines +name+: {ruby:, modules:, native:, foreign:, singleton:}, or nil when unbounded. +instance+
    # ignores the definers and installs that only a class or module object sees; only a question
    # about instances of non-Module classes may ask for it.
    def definers(name, instance: false)
      key = [name, instance]
      return @memo[key] if @memo.key?(key)

      @memo[key] = compute_definers(name, instance)
    end

    # definers, also for a name Object, Kernel or BasicObject defines (which `definers` calls unbounded): every
    # definer is still named, so the first one on a class's lookup path can be read. nil as `definers` otherwise.
    def all_definers(name, instance: false)
      key = [name, instance, :everything]
      return @memo[key] if @memo.key?(key)

      @memo[key] = compute_definers(name, instance, everything: true)
    end

    # The names' foreign Ruby definers (mruby's own Ruby the build links) that CodeGen compiled in this run
    # A view next to `definers`, never merged into it: the foreign set still says who may
    # answer, this says whose body a helper may call directly.
    def foreign_definer?(name, owner)
      d = definers(name)
      !d.nil? && d[:foreign].include?(owner)
    end

    def compiled_foreign_owners(name)
      d = definers(name)
      return Set.new if d.nil? || @w.compiled_core.nil?

      d[:foreign] & @w.compiled_core.call(name).keys
    end

    def method_missing_classes = @cw.method_missing_classes

    # May an instance of +klass+ answer +name+? true for an unbounded name.
    def answers?(klass, name)
      d = definers(name)
      return true if d.nil?

      if klass == CLASS_OBJECT
        return d[:singleton] || !d[:class_native].empty? || [d[:ruby], d[:native], d[:foreign]].any? { |s| s.intersect?(CLASS_OR_MODULE) }
      end
      return true if method_missing_classes.include?(klass)

      anc, unknown = ancestors(klass)
      unknown || anc.any? { |a| d[:ruby].include?(a) || d[:native].include?(a) || d[:foreign].include?(a) }
    end

    # The classes that may answer +name+, or nil when every object may.
    def members(name)
      return @members[name] if @members.key?(name)

      @members[name] = definers(name).nil? ? nil : classes.select { |k| answers?(k, name) }.to_set
    end

    # A declared class whose instances are never class or module objects and that no outside source can
    # reopen or subclass, up to Object.
    def user_instance?(klass)
      return false unless @cw.class_declared?(klass) && @cw.instance_class?(klass)

      seen = Set.new
      cur = klass
      while cur.is_a?(String) && cur != 'Object' && seen.add?(cur)
        return false unless @cw.untouched_class?(cur)

        cur = @w.superclass_of[cur]
        cur = nil if cur == :none
      end
      true
    end

    # No native, foreign Ruby, module or method_missing definition of +name+ can reach an instance of
    # +klass+: its lookup ends at a definition of a class in the registry or at nothing.
    def native_free?(klass, name)
      d = definers(name)
      return false if d.nil? || method_missing_classes.include?(klass)

      anc, unknown = ancestors(klass)
      !unknown && anc.none? { |a| d[:native].include?(a) || d[:foreign].include?(a) || d[:modules].include?(a) }
    end

    # NATIVE_CLASS_ARMS: a send of +name+ to an instance of +klass+ can only reach a Ruby definition
    # of the registry, or none (a NoMethodError): the first definer on its lookup path is such a definition and
    # no native or outside Ruby definer sits at or before it. The Ruby side is judged by full class name, so a
    # namesake class elsewhere cannot stand in for a missing definition.
    def resolves_in_ruby?(klass, name)
      d = definers(name, instance: true)
      return false if d.nil? || method_missing_classes.include?(klass)

      path = lookup_path(klass)
      return false if path.nil?

      ruby = ruby_owners(name)
      # A top-level class name is unambiguous; nested declarations require the outside source to spell their path.
      outside = lambda do |owner|
        (d[:native].include?(simple(owner)) || d[:foreign].include?(simple(owner))) &&
          (!@cw.class_declared?(owner) || owner == simple(owner) || @cw.outside_spells_class?(owner))
      end
      first = path.find { |owner| ruby.include?(owner) || outside.(owner) }
      first.nil? || (ruby.include?(first) && !outside.(first))
    end

    private

    def ruby_owners(name)
      return build_ruby_owners(name) unless @ruby_owners
      return @ruby_owners[name] if @ruby_owners.key?(name)

      @ruby_owners[name] = build_ruby_owners(name).freeze
    end

    def build_ruby_owners(name)
      @w.registry.fetch(name, []).reject { |definition| definition.owner == '<native>' || definition.owner.end_with?('.singleton') }
        .to_set(&:owner)
    end

    # The owners of +klass+'s method lookup in order (prepends, class, includes, superclass, ...), or nil when
    # part of the chain is unknown.
    def lookup_path(klass)
      return build_lookup_path(klass) unless @lookup_paths
      return @lookup_paths[klass] if @lookup_paths.key?(klass)

      # The world is settled; only its ordered path and static refusals are shared.
      @lookup_paths[klass] = build_lookup_path(klass)&.map { |owner| owner.dup.freeze }&.freeze
    end

    def build_lookup_path(klass)
      out = []
      seen = Set.new
      cur = klass
      while cur.is_a?(String) && seen.add?(cur)
        return nil if @w.unknown_mixins.include?(cur)

        Array(@w.prepended[cur]).reverse.each { |m| return nil unless module_path(m, out, Set.new) }
        out << cur
        Array(@w.included[cur]).reverse.each { |m| return nil unless module_path(m, out, Set.new) }
        out.concat(CORE_MIXINS.fetch(simple(cur), []))
        sup = superclass_of(cur)
        return nil if sup == :unknown

        cur = sup
      end
      out + EVERYTHING.to_a
    end

    def module_path(mod, out, seen)
      return true unless seen.add?(mod)
      return false if @w.unknown_mixins.include?(mod)

      Array(@w.prepended[mod]).reverse.each { |m| return false unless module_path(m, out, seen) }
      out << mod
      Array(@w.included[mod]).reverse.each { |m| return false unless module_path(m, out, seen) }
      true
    end

    def compute_ancestors(klass)
      out = []
      unknown = false
      seen = Set.new
      cur = klass
      while cur.is_a?(String) && seen.add?(cur)
        unknown = true if @w.unknown_mixins.include?(cur)
        Array(@w.prepended[cur]).reverse.each { |m| mixin_chain(m, out, Set.new) }
        out << simple(cur)
        Array(@w.included[cur]).reverse.each { |m| mixin_chain(m, out, Set.new) }
        CORE_MIXINS.fetch(simple(cur), []).each { |m| out << m }
        sup = superclass_of(cur)
        unknown = true if sup == :unknown
        cur = sup == :unknown ? 'Object' : sup
      end
      EVERYTHING.each { |e| out << e }
      [out.uniq, unknown]
    end

    def superclass_of(cur)
      declared = @w.superclass_of[cur]
      return declared if declared.is_a?(String)
      return CORE_SUPER[simple(cur)] if CORE_SUPER.key?(simple(cur))
      return 'StandardError' if simple(cur).match?(/(?:Error|Exception|Iteration)\z/)
      return 'Object' if declared == :none || native_class_names.include?(simple(cur))

      :unknown
    end

    def mixin_chain(mod, out, seen)
      return unless seen.add?(mod)

      Array(@w.prepended[mod]).reverse.each { |m| mixin_chain(m, out, seen) }
      out << simple(mod)
      Array(@w.included[mod]).reverse.each { |m| mixin_chain(m, out, seen) }
    end

    def compute_definers(name, instance, everything: false)
      installed = instance ? @w.instance_installed : @w.installed
      unknown = instance ? @cw.instance_unknown_def?(name) : @cw.unknown_def?(name)
      return nil if @cw.global_refusal || installed.nil? || installed.include?(name) || unknown
      return nil if HOOK_NAMES.include?(name)

      ruby = Set.new
      modules = Set.new
      singleton = false
      defs = @w.registry.fetch(name, [])
      defs.each do |d|
        next if d.owner == '<native>'
        next singleton = true if d.owner.end_with?('.singleton')

        ruby << simple(d.owner)
        modules << simple(d.owner) if @cw.module_declared?(d.owner)
      end
      native = native_owners(name, defs)
      return nil unless native
      foreign = foreign_owners(name)
      return nil unless foreign
      return nil if !everything && (ruby | native | foreign).intersect?(EVERYTHING)

      # A native singleton method is only seen by a class or module object, never by an instance.
      class_native = class_registrations.fetch(name, []).to_set { |e| e[:owner] || '?' }
      { ruby: ruby, modules: modules, native: native, foreign: foreign, singleton: singleton, class_native: class_native }
    end

    # Owners of the native registrations of +name+; nil when one cannot be read.
    def native_owners(name, defs)
      return Set.new unless defs.any? { |d| d.owner == '<native>' } || !@cw.native_paths_spelling(name).empty?

      entries = registrations.fetch(name, [])
      owners = entries.map { |e| e[:owner]&.fetch(:class_name, nil) } + opaque_owners.fetch(name, [])
      return Set.new if owners.empty? && class_registered_only?(name)
      return owners.to_set unless owners.empty? || owners.include?(nil)

      mapped_native_owners(name, entries.filter_map { |e| e[:path] })
    end

    # NATIVE_OWNER_MAP fallback: a registration whose class is a C local the expression scan cannot resolve
    # (mruby-rpg2k-compiled's `RClass* map_viewer = mrb_class_get_under(M, scene, "MapViewer")`) is attributed by
    # NativeOwnerMap, the proof OUTSIDE_OWNER_CALL rests on, over every file that spells or registers the name. nil
    # when the map is off, cannot attribute a registration (UNKNOWN), or its sources compute or prepend names. The
    # class-object (`.singleton`) registrations are not instance definers; class_registrations answers for those.
    NATIVE_OWNER_MAPS = {}

    def mapped_native_owners(name, registering_paths)
      return nil if ENV['BC2CPP_NATIVE_OWNER_MAP'] == '0'

      paths = (@cw.native_paths_spelling(name) | registering_paths).sort
      return nil if paths.empty?

      map = NATIVE_OWNER_MAPS[paths] ||= NativeOwnerMap.build(paths)
      refusals = map.refusals.to_h
      return nil if map.computed_unknown || refusals.fetch(:native_prepend, 0).positive? ||
                    refusals.fetch(:native_unparsed_form, 0).positive? || !map.computed.to_a.empty?

      found = map.by_name.fetch(name, Set.new).to_a
      return nil if found.empty? || found.include?(NativeOwnerMap::UNKNOWN)

      found.reject { |owner| owner.to_s.end_with?('.singleton') }.to_set { |owner| simple(owner) }
    end

    # Every native source that spells +name+ registers it on a class or module object (`definers[:class_native]`),
    # and the instance scan found no registration or alias of it: the spelling is not an instance definer.
    def class_registered_only?(name)
      paths = @cw.native_paths_spelling(name)
      registered = class_registrations.fetch(name, []).map { |e| e[:path] }
      !registered.empty? && paths.all? { |path| registered.include?(path) }
    end

    # Owners outside Ruby defines +name+ on; nil when a wildcard owner could.
    def foreign_owners(name)
      return Set.new unless @cw.outside_ruby_name?(name)

      scan = ForeignDefiners.scan(@cw.outside_ruby_paths)
      return nil unless scan.wild.empty?

      scan.names.each_with_object(Set.new) { |(owner, names), set| set << simple(owner) if names.include?(name) }
    end
  end

  # Forward "must answer" analysis over one irep. State: [cls, facts]. cls[i] is the smallest register
  # holding the same value as register i; facts[rep] is the sorted names the value answered on every path
  # here (nil for none). A fact is dropped when its register is rewritten, joins intersect, and a handler
  # edge takes the state before the raising instruction, so only the normal-return edge carries a fact.
  module Flow
    module_function

    CALLS = BytecodeIR::Ops::CALLEE_FRAME
    NO_WRITE = NumericFlow::NO_WRITE_OPS
    REFINING = (BytecodeIR::Ops::SEND - BytecodeIR::Ops::SELF_SEND).freeze

    # Index -> state (nil when unreached), or nil when the irep is not modelled. +opaque+ are the
    # registers a nested block can write (their value is not the one a call saw).
    def states(irep, opaque)
      program = BytecodeIR.for(irep)
      return nil unless program.resolved?
      return nil if program.handlers? && !program.handlers_resolved?

      insns = program.each_source.map { |source, _index| source }
      return nil if insns.empty?
      return nil unless insns.all? { |i| NumericFlow::SUPPORTED_OPS.include?(i.op) || BytecodeIR::Ops::LOADI_OPS.include?(i.op) }

      n = [irep.nregs.to_i, 1].max
      raises = program.raise_targets
      succ_lists = program.successor_lists
      ins = Array.new(insns.length)
      outs = Array.new(insns.length)
      ins[0] = [(0...n).to_a, Array.new(n)]
      work = [0]
      queued = Set[0]
      until work.empty?
        i = work.shift
        queued.delete(i)
        out = transfer(insns[i], ins[i], n, opaque)
        raises.fetch(i, NumericFlow::EMPTY).each do |target|
          edge = join(raise_state(insns[i], ins[i], n), out)
          push(ins, target, edge, work, queued)
        end
        next if outs[i] == out

        outs[i] = out
        succ_lists[i].each { |s| push(ins, s, out, work, queued) }
      end
      ins
    end

    def push(ins, target, state, work, queued)
      merged = ins[target] ? join(ins[target], state) : state
      return if merged == ins[target]

      ins[target] = merged
      work << target if queued.add?(target)
    end

    # The names the value of register +reg+ answered on every path to the state, or nil.
    def facts(state, reg)
      return nil unless state && reg < state[0].size

      state[1][state[0][reg]]
    end

    def join(left, right)
      cls = Array.new(left[0].size)
      facts = Array.new(left[0].size)
      groups = {}
      left[0].each_index { |i| cls[i] = (groups[[left[0][i], right[0][i]]] ||= i) }
      groups.each do |(a, b), rep|
        both = left[1][a] && right[1][b] ? left[1][a] & right[1][b] : nil
        facts[rep] = both unless both.nil? || both.empty?
      end
      [cls, facts]
    end

    def detach!(state, i)
      cls, facts = state
      rep = cls[i]
      rest = (0...cls.size).select { |k| cls[k] == rep && k != i }
      if rep == i && !rest.empty?
        new_rep = rest.min
        rest.each { |k| cls[k] = new_rep }
        facts[new_rep] = facts[i]
      end
      cls[i] = i
      facts[i] = nil
    end

    def attach!(state, i, src)
      detach!(state, i)
      cls, facts = state
      rep = cls[src]
      if i < rep
        (0...cls.size).each { |k| cls[k] = i if cls[k] == rep }
        facts[i] = facts[rep]
        facts[rep] = nil
      else
        cls[i] = rep
      end
    end

    def dup_state(state) = [state[0].dup, state[1].dup]

    # A callee's frame starts at R(a) and may reuse every register from there up.
    def clobber!(state, from, n)
      (from...n).each { |r| detach!(state, r) }
    end

    def raise_state(insn, state, n)
      return state unless CALLS.include?(insn.op)

      out = dup_state(state)
      clobber!(out, insn.reg.to_i, n)
      out
    end

    def transfer(insn, state, n, opaque)
      op = insn.op
      return state if NO_WRITE.include?(op) || op == :SETIV

      a = insn.reg&.to_i
      return state if a.nil? || a >= n

      out = dup_state(state)
      if CALLS.include?(op)
        names = state[1][state[0][a]]
        names = ((names || []) | [insn.sym]).sort.freeze if REFINING.include?(op) && a.positive? && !opaque.include?(a.to_s) && insn.sym
        kept = (0...n).select { |k| state[0][k] == state[0][a] && k < a }
        clobber!(out, a, n)
        out[1][out[0][kept.first]] = names unless kept.empty?
        return out
      end
      case op
      when :MOVE
        src = insn.regs[1].to_i
        if src < n && src != a && !opaque.include?(a.to_s) && !opaque.include?(src.to_s)
          attach!(out, a, src)
        else
          detach!(out, a)
        end
      when :ADDILV, :SUBILV
        b = insn.regs[1].to_i
        [a, b, b + 1].each { |r| detach!(out, r) if r < n }
      when :RESCUE
        b = insn.regs[1].to_i
        detach!(out, b) if b < n
      else
        detach!(out, a)
      end
      out
    end
  end
end
