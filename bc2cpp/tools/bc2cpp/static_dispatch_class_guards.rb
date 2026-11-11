# frozen_string_literal: true

require 'set'
require_relative 'bytecode_ir'

# CLASS_GUARD_REACH (closed only): a send on a value a class test has just passed looks its name up on that class's
# relatives only, not on every owner of the name. After `x.is_a?(C)` (or `kind_of?`) is true, `x.name` runs the
# entry of an owner that is C, an ancestor of C or a subclass of C. StaticDispatchRegistrations records exactly that
# owner set for the name (the way SUPER_REACH does for a `super`), instead of making the name dynamic.
#
# The proof is bytecode-local and refuses anything it cannot see whole:
#   * the tested value is one register no instruction of the irep ever writes (its method or block argument), so
#     the test and the send read the same object;
#   * the test is the SEND right before the JMPIF/JMPNOT that branches on it, and nothing else jumps to that branch;
#   * every path from the irep's entry to the send takes the true edge of that branch, a `raise` ending its path
#     (Kernel#raise is the only one);
#   * the irep has no rescue/ensure handler;
#   * the tested constant names classes of the closed world only (an engine namespace, no module or native owner
#     of the same name), each with a fully known superclass chain;
#   * `is_a?`, `kind_of?` and `raise` have no definition but the core natives, and no class derives from
#     BasicObject (whose `is_a?` would be a method_missing).
class StaticDispatchClassGuards
  TESTS = %w[is_a? kind_of?].to_set.freeze
  BRANCHES = %i[JMPIF JMPNOT].freeze
  # The sends whose receiver is a register (not self) and that pass no splat.
  RECEIVER_SENDS = %i[SEND SEND0 SENDB].freeze
  RAISE_SENDS = %i[SSEND SSEND0].freeze
  DEFINITION_TEXT = /\b(?:def|alias|undef|alias_method|undef_method|define_method|remove_method)\b[^\n]*(?:\bis_a\?|\bkind_of\?|\braise\b)|<\s*BasicObject\b/
  GATED_NAMES = %w[is_a? kind_of? raise].freeze
  ENGINE_RE = /\A(?:Game|RPG2k3?|LCF|RGSS)(?:::|\z)/

  # +superclass_of+: the closed world's class => superclass. +owner_names+: every owner (class, module, singleton)
  # a Ruby or native definition names. +ruby_texts+: the Ruby the closed binary may load, outside the closed world.
  # +native_owners+: name => owners of the native registrations of that name. +ancestors+: lambda(class) => the
  # Set of its superclasses, or nil when the chain is not fully known. Returns nil when a gate fails.
  def self.build(superclass_of:, registry:, owner_names:, ruby_texts:, native_owners:, ancestors:)
    return nil if GATED_NAMES.any? { |name| registry.key?(name) }
    return nil if GATED_NAMES.any? { |name| native_owners.fetch(name, []).any? { |owner| owner != 'Kernel' } }
    return nil if ruby_texts.any? { |text| text.match?(DEFINITION_TEXT) }
    return nil if superclass_of.values.include?('BasicObject')

    new(superclass_of, owner_names, ancestors)
  end

  def initialize(superclass_of, owner_names, ancestors)
    @superclass_of = superclass_of
    @ancestors = ancestors
    @by_leaf = Hash.new { |h, k| h[k] = [] }
    superclass_of.each_key { |klass| @by_leaf[klass.split('::').last] << klass }
    @foreign_leaves = owner_names.reject { |o| superclass_of.key?(o) }.to_set { |o| o.sub(/\.singleton\z/, '').split('::').last }
    @reach = {}
    @narrowed = {}
  end

  # index of a send => the Set of owners its name may be looked up on, for the sends the irep's class tests narrow.
  def narrowed(irep)
    @narrowed[irep.label] ||= compute(irep)
  end

  private

  def compute(irep)
    program = BytecodeIR.for(irep)
    return {} unless program.resolved? && Array(irep.catch_handlers).empty?

    preds = program.instruction_predecessors
    return {} unless preds

    out = {}
    opaque = BytecodeIR.own_upvar_written_regs(irep)
    count = program.instructions.length
    (0...count).each do |t|
      test = program.instruction_at(t).source
      next unless test.op == :SEND && TESTS.include?(test.sym) && test.argc == 1 && !test.keyword_arguments?

      branch_index = t + 1
      branch = branch_index < count && program.instruction_at(branch_index).source
      next unless branch && BRANCHES.include?(branch.op) && branch.reg == test.reg && preds[branch_index] == [t]

      var = argument_register(irep, t, test.reg, opaque)
      reach = var && reach_of(constant_name(irep, program, t, test.reg + 1, opaque))
      next unless reach

      target = program.address_to_index[branch.branch_target]
      fall = branch_index + 1
      next if target.nil? || target == fall || fall >= count

      true_to = branch.op == :JMPIF ? target : fall
      open_set = reachable_without(program, count, branch_index, true_to)
      (0...count).each do |s|
        next if open_set[s]

        send = program.instruction_at(s).source
        next unless RECEIVER_SENDS.include?(send.op) && send.sym && s != t
        next unless argument_register(irep, s, send.reg, opaque) == var

        out[s] = reach if out[s].nil? || reach.size < out[s].size
      end
    end
    out
  end

  # The one register an argument or local nothing ever writes holds the value read at +index+ in +reg+, or nil.
  def argument_register(irep, index, reg, opaque)
    defs = BytecodeIR.reaching_definitions(irep, index, reg, opaque_regs: opaque, shared: true)
    return nil unless defs && defs.size == 1

    d = defs.first
    d.entry? && d.reg >= 1 ? d.reg : nil
  end

  # The bare constant name every definition reaching +reg+ at +index+ loads, or nil.
  def constant_name(irep, program, index, reg, opaque)
    defs = BytecodeIR.reaching_definitions(irep, index, reg, opaque_regs: opaque, shared: true)
    return nil unless defs && !defs.empty? && defs.none?(&:entry?)

    names = defs.map do |definition|
      insn = program.source_at(definition.index)
      %i[GETCONST GETMCNST].include?(insn.op) ? insn.const_name : nil
    end.uniq
    names.size == 1 ? names.first : nil
  end

  # Instructions the entry reaches without the edge from +from+ to +to+, and without going on past a `raise`.
  def reachable_without(program, count, from, to)
    seen = Array.new(count, false)
    stack = [0]
    seen[0] = true
    succ = program.successor_lists
    until stack.empty?
      i = stack.pop
      source = program.instruction_at(i).source
      next if RAISE_SENDS.include?(source.op) && source.sym == 'raise'

      succ[i].each do |n|
        next if i == from && n == to
        next if seen[n]

        seen[n] = true
        stack << n
      end
    end
    seen
  end

  # The owners a send on a value of class +name+ (or a subclass of it) may run: the classes of that name, their
  # superclasses and their subclasses; nil unless every class that name can mean is one of the closed world's.
  def reach_of(name)
    return nil unless name
    return @reach[name] if @reach.key?(name)

    classes = @by_leaf[name]
    ok = !classes.empty? && !@foreign_leaves.include?(name) && classes.all? { |k| k.match?(ENGINE_RE) && @ancestors.call(k) }
    @reach[name] = ok ? related(classes) : nil
  end

  def related(classes)
    reach = classes.to_set
    classes.each { |k| reach.merge(@ancestors.call(k)) }
    @superclass_of.each_key do |k|
      chain = @ancestors.call(k)
      reach << k if chain && classes.any? { |c| chain.include?(c) }
    end
    reach.freeze
  end
end
