# frozen_string_literal: true

require 'set'
require_relative 'numeric_flow'
require_relative 'bytecode_ir'
require_relative 'foreign_definers'

# CALL_FACTS (ADR 0317): what a call that returned normally says about its receiver.
#
# After `r.m(...)` returns, the object in `r` answered `m`, so a later use of the same value (a copy of
# the register, a local) can only be an instance of a class that answers `m`. Flow is the forward "must"
# analysis of those facts; Answers is the closed-world question "which classes answer `m`".
module CallFacts
  # mruby core classes the closed world does not declare, and the modules the core mixes into them.
  CORE_SUPER = { 'BasicObject' => nil, 'Object' => 'BasicObject', 'Module' => 'Object', 'Class' => 'Module',
                 'NilClass' => 'Object', 'TrueClass' => 'Object', 'FalseClass' => 'Object', 'Numeric' => 'Object',
                 'Integer' => 'Numeric', 'Float' => 'Numeric', 'String' => 'Object', 'Symbol' => 'Object',
                 'Array' => 'Object', 'Hash' => 'Object', 'Range' => 'Object', 'Proc' => 'Object',
                 'Exception' => 'Object', 'StandardError' => 'Exception', 'Struct' => 'Object' }.freeze
  CORE_MIXINS = { 'Object' => %w[Kernel], 'Numeric' => %w[Comparable], 'String' => %w[Comparable],
                  'Symbol' => %w[Comparable], 'Array' => %w[Enumerable], 'Hash' => %w[Enumerable],
                  'Range' => %w[Enumerable], 'Struct' => %w[Enumerable] }.freeze
  # A definer on one of these answers every object.
  EVERYTHING = %w[Object Kernel BasicObject].to_set.freeze
  CORE_MODULES = %w[Kernel Comparable Enumerable Math GC ObjectSpace Process Signal Marshal FileTest Errno].freeze
  CLASS_OBJECT = '<ClassObject>'
  CLASS_OR_MODULE = %w[Class Module].to_set.freeze
  # Names whose answer depends on a hook, not on a definition.
  HOOK_NAMES = %w[method_missing respond_to_missing? initialize].freeze

  # The world Answers reads; nil fields make every question "unknown".
  # instance_installed (NATIVE_CLASS_ARMS, ADR 0323) is installed without the names only a class object sees.
  World = Struct.new(:closed_world, :registry, :superclass_of, :included, :prepended, :unknown_mixins,
                     :native_sources, :installed, :instance_installed, keyword_init: true)

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
    end

    def simple(name) = name.to_s.split('::').last

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
    # ignores the definers and installs that only a class or module object sees (ADR 0323); only a question
    # about instances of non-Module classes may ask for it.
    def definers(name, instance: false)
      key = [name, instance]
      return @memo[key] if @memo.key?(key)

      @memo[key] = compute_definers(name, instance)
    end

    def method_missing_classes = @cw.method_missing_classes

    # May an instance of +klass+ answer +name+? true for an unbounded name.
    def answers?(klass, name)
      d = definers(name)
      return true if d.nil?

      if klass == CLASS_OBJECT
        return d[:singleton] || [d[:ruby], d[:native], d[:foreign]].any? { |s| s.intersect?(CLASS_OR_MODULE) }
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

    # NATIVE_CLASS_ARMS (ADR 0323): a send of +name+ to an instance of +klass+ can only reach a Ruby definition
    # of the registry, or none (a NoMethodError): the first definer on its lookup path is such a definition and
    # no native or outside Ruby definer sits at or before it. The Ruby side is judged by full class name, so a
    # namesake class elsewhere cannot stand in for a missing definition.
    def resolves_in_ruby?(klass, name)
      d = definers(name, instance: true)
      return false if d.nil? || method_missing_classes.include?(klass)

      path = lookup_path(klass)
      return false if path.nil?

      ruby = @w.registry.fetch(name, []).reject { |x| x.owner == '<native>' || x.owner.end_with?('.singleton') }
                 .to_set(&:owner)
      outside = ->(owner) { d[:native].include?(simple(owner)) || d[:foreign].include?(simple(owner)) }
      first = path.find { |owner| ruby.include?(owner) || outside.(owner) }
      first.nil? || (ruby.include?(first) && !outside.(first))
    end

    private

    # The owners of +klass+'s method lookup in order (prepends, class, includes, superclass, ...), or nil when
    # part of the chain is unknown.
    def lookup_path(klass)
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

    def compute_definers(name, instance)
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
      return nil if (ruby | native | foreign).intersect?(EVERYTHING)

      { ruby: ruby, modules: modules, native: native, foreign: foreign, singleton: singleton }
    end

    # Owners of the native registrations of +name+; nil when one cannot be read.
    def native_owners(name, defs)
      return Set.new unless defs.any? { |d| d.owner == '<native>' } || !@cw.native_paths_spelling(name).empty?

      owners = registrations.fetch(name, []).map { |e| e[:owner]&.fetch(:class_name, nil) } + opaque_owners.fetch(name, [])
      owners.empty? || owners.include?(nil) ? nil : owners.to_set
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

    CALLS = NumericFlow::CALL_OPS
    NO_WRITE = NumericFlow::NO_WRITE_OPS
    REFINING = %w[SEND SEND0 SENDB].freeze

    # Index -> state (nil when unreached), or nil when the irep is not modelled. +opaque+ are the
    # registers a nested block can write (their value is not the one a call saw).
    def states(irep, opaque)
      program = BytecodeIR.for(irep)
      return nil unless program.resolved?
      return nil if program.handlers? && !program.handlers_resolved?

      insns = irep.instructions
      return nil if insns.empty?
      return nil unless insns.all? { |i| NumericFlow::SUPPORTED_OPS.include?(i.op) || i.op.start_with?('LOADI') }

      n = [irep.nregs.to_i, 1].max
      extra = NumericFlow.enter_edges(irep)
      raises = program.handler_edges.group_by(&:src).transform_values { |edges| edges.map(&:target).uniq }
      ins = Array.new(insns.length)
      outs = Array.new(insns.length)
      ins[0] = [(0...n).to_a, Array.new(n)]
      work = [0]
      queued = Set[0]
      until work.empty?
        i = work.shift
        queued.delete(i)
        out = transfer(insns[i], ins[i], n, opaque)
        raises.fetch(i, []).each do |target|
          edge = join(raise_state(insns[i], ins[i], n), out)
          push(ins, target, edge, work, queued)
        end
        next if outs[i] == out

        outs[i] = out
        succ = program.instruction_at(i).successors
        succ |= extra[i] if extra[i]
        succ.each { |s| push(ins, s, out, work, queued) }
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
      return state if NO_WRITE.include?(op) || op == 'SETIV'

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
      when 'MOVE'
        src = insn.regs[1].to_i
        if src < n && src != a && !opaque.include?(a.to_s) && !opaque.include?(src.to_s)
          attach!(out, a, src)
        else
          detach!(out, a)
        end
      when 'ADDILV', 'SUBILV'
        b = insn.regs[1].to_i
        [a, b, b + 1].each { |r| detach!(out, r) if r < n }
      when 'RESCUE'
        b = insn.regs[1].to_i
        detach!(out, b) if b < n
      else
        detach!(out, a)
      end
      out
    end
  end
end
