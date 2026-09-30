# frozen_string_literal: true

require_relative 'numeric_flow'

# CodeGen: NUMERIC_RETURN_PROOF (ADR 0276).
#
# What class set can a call to `name` return? FIXNUM_RETURN_PROOF answers "a
# small Integer" for a name with ONE bytecode definition; this joins every
# definition of the name, so a getter defined in several classes (or an
# attr_reader) still yields a class set, and it reasons in NumericFlow's
# lattice, so Float, nil, and exact Array/Hash/String results count.
#
# A name is tracked only when a call can reach nothing but the definitions the
# registry lists (ClosedWorld#name_fully_visible?: no native or foreign source
# defines it, no runtime installer or method_missing hook exists) and no alias
# gives its body another name. Every definition then must be a bytecode body
# whose return sites the flow models, or a plain attr_reader of an ivar with a
# tracked group. SENDB/SSENDB never use the result: a `break` in the caller's
# block becomes the call's value.
#
# Least fixpoint with the other numeric facts (compute_numeric_facts): each name
# starts empty and only grows, so a recursive getter proves itself the way the
# base case does.
#
# The result of a send NO tracked name covers comes from numeric_send_mask below:
# core bodies whose result class follows from the receiver's proven class.
class CodeGen
  NUMERIC_RETURN_NAME = /\A[A-Za-z_]\w*[?!]?\z/

  def setup_numeric_returns
    @numeric_return = {}
    @numeric_return_send_ireps = Hash.new { |h, k| h[k] = Set.new }
    return unless @foreign_method_names && @closed_world && @closed_world.global_refusal.nil?

    aliased = numeric_aliased_names
    @registry.each do |name, defs|
      next unless name.match?(NUMERIC_RETURN_NAME) && name != 'initialize'
      next if defs.empty? || @foreign_method_names.include?(name) || aliased.include?(name)
      next unless @closed_world.name_fully_visible?(name)
      next unless defs.all? { |d| numeric_return_def_usable?(d) }

      @numeric_return[name] = 0
    end
    @ireps.each_value do |irep|
      irep.instructions.each do |insn|
        next unless %w[SEND SEND0 SSEND SSEND0].include?(insn.op) && @numeric_return.key?(insn.sym)

        @numeric_return_send_ireps[insn.sym] << irep.label
      end
    end
  end

  def numeric_return_def_usable?(d)
    return false if d.owner.start_with?('<') || (d.owner.end_with?('.singleton') && d.irep.nil?)
    return d.kind == :ivar_accessor && !d.name.end_with?('=') if d.irep.nil?

    !@ireps[d.irep].nil?
  end

  # Names an `alias`/`alias_method`/`define_method` gives a body another name:
  # the registry lists the body under its original name only.
  def numeric_aliased_names
    names = Set.new
    @ireps.each_value do |irep|
      insns = irep.instructions
      aliasing = insns.any? do |i|
        i.op == 'ALIAS' || (i.op.include?('SEND') && %w[alias_method alias define_method define_singleton_method].include?(i.sym))
      end
      next unless aliasing

      insns.each { |i| names << i.sym if i.sym && (i.op == 'ALIAS' || i.op == 'LOADSYM') }
    end
    names
  end

  # Class set of the value one definition returns, or OTHER.
  def numeric_return_def_mask(d)
    return numeric_accessor_return_mask(d) if d.irep.nil?

    irep = @ireps[d.irep]
    return NumericFlow::OTHER if subtree_has_nonlocal_exit?(irep)

    states = numeric_states_for(irep)
    return NumericFlow::OTHER unless states

    joined = 0
    irep.instructions.each_with_index do |insn, idx|
      state = states[idx]
      next unless state

      case insn.op
      when 'RETURN', 'RETURN_BLK'
        joined |= state[insn.reg.to_i] || NumericFlow::OTHER
      when 'RETNIL'
        joined |= NumericFlow::NIL
      when 'RETSELF', 'RETTRUE', 'RETFALSE', 'BREAK', 'STOP'
        joined |= NumericFlow::OTHER
      end
    end
    joined
  end

  def numeric_accessor_return_mask(d)
    return NumericFlow::INT if embed_type(d.owner, d.name) == :fixnum

    group = @numeric_ivar_groups && @numeric_ivar_groups[[numeric_family(d.owner), d.name]]
    return NumericFlow::OTHER unless group && !group.failed

    group.mask | (numeric_ivar_assured?(d.owner, d.name) ? 0 : NumericFlow::NIL)
  end

  # One growth pass: a name's mask is the join of what each definition returns;
  # the name is untracked for good when a definition may return an unmodelled
  # class.
  def grow_numeric_returns
    changed = false
    @numeric_return.keys.each do |name|
      current = @numeric_return[name]
      joined = 0
      @registry[name].each { |d| joined |= numeric_return_def_mask(d) }
      if (joined & NumericFlow::OTHER) != 0
        @numeric_return.delete(name)
      elsif (joined | current) == current
        next
      else
        @numeric_return[name] = current | joined
      end
      @numeric_return_send_ireps[name].each { |label| numeric_invalidate(label) }
      changed = true
    end
    changed
  end

  # Class each receiver bit stands for, when its core body is what a send runs.
  NUMERIC_SEND_OWNERS = { NumericFlow::ARR => 'Array', NumericFlow::HSH => 'Hash', NumericFlow::STR => 'String',
                          NumericFlow::INT => 'Integer', NumericFlow::FLT => 'Float' }.freeze
  # Zero-argument sends on a numeric receiver whose result class is fixed.
  NUMERIC_TO_INT_SENDS = %w[to_i to_int floor ceil round truncate].freeze

  # Class set a SEND-family result holds, given the flow state at the call. It
  # is a union over the receiver's possible classes, so it is monotone: a class
  # this file has no rule for contributes OTHER. Tracked names come from
  # NUMERIC_RETURN_PROOF, the rest are core bodies whose result class is fixed by
  # the receiver's proven class and gated by builtin_class_send_safe? (no Ruby
  # override, no prepend).
  def numeric_send_mask(_irep, _index, insn, state)
    name = insn.sym
    return NumericFlow::OTHER unless name

    tracked = @numeric_return && @numeric_return[name]
    return tracked if tracked
    return NumericFlow::INT if @fixnum_return_names.include?(name)
    return NumericFlow::ARR if @array_return_names.include?(name)
    return NumericFlow::OTHER if insn.op.start_with?('SS')

    recv = state[insn.reg.to_i]
    return NumericFlow::OTHER unless recv

    # SEND0 carries no operand count; a keyword or splat form has no plain count.
    argc = insn.op.end_with?('0') ? 0 : (insn.plain_fixed_argc? ? insn.argc : nil)
    mask = 0
    NUMERIC_SEND_OWNERS.each_key do |bit|
      mask |= numeric_send_on_class(bit, name, argc, insn, state) if (recv & bit).nonzero?
    end
    mask |= NumericFlow::OTHER if (recv & ~NUMERIC_SEND_OWNERS.keys.sum).nonzero?
    mask
  end

  def numeric_send_on_class(bit, name, argc, insn, state)
    other = NumericFlow::OTHER
    owners = bit.anybits?(NumericFlow::NUM) ? NUMERIC_OP_OWNERS : [NUMERIC_SEND_OWNERS.fetch(bit)]
    return other unless builtin_class_send_safe?(name, owners)

    if bit.anybits?(NumericFlow::CONTAINERS)
      counted = name == 'count' ? bit != NumericFlow::STR : %w[size length].include?(name)
      return argc == 0 && counted ? NumericFlow::INT : other
    end
    numeric_send_on_number(bit, name, argc, insn, state)
  end

  # +bit+ is INT or FLT.
  def numeric_send_on_number(bit, name, argc, insn, state)
    if argc == 0
      return NumericFlow::INT if NUMERIC_TO_INT_SENDS.include?(name)
      return NumericFlow::FLT if name == 'to_f'
      return bit if %w[abs -@].include?(name)
    elsif argc == 1 && %w[% fdiv].include?(name)
      arg = state[insn.reg.to_i + 1]
      return NumericFlow::OTHER unless arg

      return name == 'fdiv' ? NumericFlow::FLT : NumericFlow.arith(bit, arg, numeric_nil_raises?(name))
    end
    NumericFlow::OTHER
  end
end
