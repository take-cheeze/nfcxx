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
    numeric_return_candidates.each { |name| @numeric_return[name] = 0 }
    @ireps.each_value do |irep|
      irep.instructions.each do |insn|
        next unless %w[SEND SEND0 SSEND SSEND0].include?(insn.op) && @numeric_return.key?(insn.sym)

        @numeric_return_send_ireps[insn.sym] << irep.label
      end
    end
  end

  # Names a call can reach only through the definitions the registry lists (see the header), each a
  # bytecode body or a plain attr_reader. Shared with the exact-class table (RETURN_CLASS_TABLE).
  def numeric_return_candidates
    return [] unless @foreign_method_names && @closed_world && @closed_world.global_refusal.nil?

    aliased = numeric_aliased_names
    @registry.filter_map do |name, _definitions|
      defs = return_table_definitions(name)
      next unless name.match?(NUMERIC_RETURN_NAME) && name != 'initialize'
      next if defs.empty?
      string_native = name == 'to_s' && native_result_name_kinds(name)
      next if @foreign_method_names.include?(name) && !string_native
      next if aliased.include?(name) && !(string_native && native_struct_string_alias_safe?)
      next unless @closed_world.name_fully_visible?(name) || native_result_name_kinds(name)
      next unless defs.all? { |d| numeric_return_def_usable?(d) }

      name
    end
  end

  # ADR 0333: a registry placeholder is not a runtime definition when the
  # build's complete closed-world scan proves that no native defines the name.
  def return_table_definitions(name)
    definitions = @registry[name] || []
    return definitions if ENV['BC2CPP_ABSENT_NATIVE_RETURNS'] == '0'
    return definitions unless @native_name_sources && @foreign_method_names && @closed_world&.name_fully_visible?(name)

    definitions.reject { |definition| definition.owner == '<native>' && definition.irep.nil? }
  end

  def numeric_return_def_usable?(d)
    return d.irep.nil? && !native_result_name_kinds(d.name).nil? if d.owner == '<native>'
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
    return native_result_def_mask(d, classes: false) if d.owner == '<native>'
    return numeric_accessor_return_mask(d) if d.irep.nil?

    irep = @ireps[d.irep]
    states = numeric_states_for(irep)
    return NumericFlow::OTHER unless states

    joined = numeric_block_return_mask(irep)
    return NumericFlow::OTHER if joined.nil?

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

  # What a `return` inside a block nested in +irep+ hands back from the method (RETURN_BLK, at
  # any depth), or nil when a block the flow does not model has one. A `break` is the result of
  # the call that took the block, which SENDB never reads, so it adds nothing. A lambda's own
  # RETURN_BLK is counted too: a superset of the classes, never a subset.
  def numeric_block_return_mask(irep, seen = Set.new)
    joined = 0
    (irep.reps || []).each do |label|
      next unless seen.add?(label)

      child = @ireps[label]
      next unless child

      if child.instructions.any? { |i| i.op == 'RETURN_BLK' }
        states = numeric_states_for(child)
        return nil unless states

        child.instructions.each_with_index do |insn, idx|
          next unless insn.op == 'RETURN_BLK' && states[idx]

          joined |= states[idx][insn.reg.to_i] || NumericFlow::OTHER
        end
      end
      nested = numeric_block_return_mask(child, seen)
      return nil if nested.nil?

      joined |= nested
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
      return_table_definitions(name).each { |d| joined |= numeric_return_def_mask(d) }
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
  def numeric_send_mask(irep, index, insn, state)
    name = insn.sym
    return NumericFlow::OTHER unless name

    lcf = lcf_new_mask(irep, index, insn) if name == 'new'
    return lcf if lcf

    # A literal frozen in place: the kind of its slots (FROZEN_TABLES, ADR 0306).
    table = name == 'freeze' && insn.op == 'SEND0' && frozen_table_freeze_site(irep, index)
    return (state[insn.reg.to_i] || 0).zero? ? 0 : table if table

    tracked = @numeric_return && @numeric_return[name]
    return tracked if tracked
    return NumericFlow::INT if @fixnum_return_names.include?(name)
    return NumericFlow::ARR if @array_return_names.include?(name)
    return NumericFlow::OTHER if insn.op.start_with?('SS')

    native = native_result_numeric_mask(irep, index, insn)
    return native if native

    recv = state[insn.reg.to_i]
    return NumericFlow::OTHER unless recv

    # SEND0 carries no operand count; a keyword or splat form has no plain count.
    argc = insn.op.end_with?('0') ? 0 : (insn.plain_fixed_argc? ? insn.argc : nil)
    mask = 0
    tables = @frozen_tables ? @frozen_tables.tables(recv) : 0
    if tables.nonzero?
      mask |= frozen_table_send_mask(tables, name, argc)
      recv &= ~tables
    end
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
