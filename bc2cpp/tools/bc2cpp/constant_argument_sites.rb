# frozen_string_literal: true

require 'set'
require_relative 'alias_sites'
require_relative 'bytecode_ir'
require_relative 'bytecode_ir_ops'
require_relative 'call_site_index'
require_relative 'dynamic_names'
require_relative 'integer_constant_ranges'

# CONSTANT_ARGUMENT_SITES (report only): for each method body, the call sites that pass constant arguments, whether every
# call site passes one constant tuple, whether the body is pure by a conservative allowlist, and how many of its
# conditional jumps the tuple would decide. Nothing is generated; the output is a report for a later value-specialization.
#
# A constant is an Integer literal (LOADI*), nil, true, false, a Symbol literal, or a constant named in +constants+ (a bare
# name => [:int, value] or a Symbol-or-nil value, the ConstantFacts values). A value reaches a call through
# the bytecode reaching definitions, so a MOVE chain is followed. Anything else is UNKNOWN.
#
# Four conditions make a verdict untrustworthy, and each is reported on its own row and counted in the summary:
# Four conditions are reported on their own rows and counted in the summary. Only the first decides whether a tuple is
# complete; the other three decide purity (whether a call may be replaced), and never the jump decisions.
#   1. UNRESOLVED: a call the analysis cannot place by name: send/__send__/public_send, method, define_method or
#      alias_method with a computed name, a to_enum site with a computed name, or an alias AliasSites cannot decode. A
#      literal target names only that method. An alias names both its new and its old name, since they run one body. A
#      computed target names every method DynamicNames.universe spells (a Symbol or identifier String literal, and the
#      setters once any name is computed). A to_enum site with a computed name and an undecodable alias stay global.
#      UNDEF adds no call target and method_missing answers only names no definition answers, so neither is a reason:
#      a call a method_missing body makes is an ordinary call site, or a computed one (condition 1 again).
#      A method with a reason is not a single-tuple candidate.
#   2. REDEFINED (purity only): a Ruby definition in the registry of a name a pure body sends. The receivers of those
#      sends are not known, so a redefinition refuses purity by name; the owner is not checked.
#   3. OPERATOR GATE (purity only): an arithmetic or ordering op needs IntegerConstantRanges.integer_ops_safe? and no
#      redefinition of its name. Otherwise the body is refused as impure.
#   4. MAY RAISE (purity only): a body with an op or send that can raise on some receiver is not pure. It is reported in
#      may_raise. A raising op does not change which branch a decided jump takes: the jump is reached only after the ops
#      before it ran, and the untaken branch is not executed in either case.
#
# Call sites are matched by method name (CallSiteIndex), so a method is "called only with tuple T" only over its name's
# sites. A computed-name site is kept as a caller of every name (CallSiteIndex.sites), which can only add sites.
module ConstantArgumentSites
  UNKNOWN = :unknown
  # Methods a pure body may send. Core operators and predicates; a redefinition of one is refused (condition 2).
  PURE_NAMES = Set.new(%w[+ - * / % == != < > <= >= ! nil? is_a? kind_of? instance_of? respond_to? zero? positive? negative? abs]).freeze
  # Sends that cannot raise on any receiver: identity, equality and the type predicates. Every other pure name may raise
  # (for example `+` on nil, `zero?` on a String), so a body that sends it is may_raise.
  NON_RAISING_NAMES = Set.new(%w[! == != nil? is_a? kind_of? instance_of? respond_to?]).freeze
  # The arithmetic and ordering names the operator gate covers (their ops are ARITH_OPS below).
  ARITH_NAMES = Set.new(%w[+ - * / % < > <= >=]).freeze
  # Opcodes with no side effect of their own and no way to raise. GETCONST/GETMCNST may run const_missing or raise NameError,
  # so they are may_raise (see RAISING_OPS), not here.
  PURE_OPS = Set.new(BytecodeIR::Ops::PURE_LOAD.to_a + BytecodeIR::CONDITIONAL_BRANCHES +
                     %w[NOP STRING ENTER RETURN JMP GETIV GETUPVAR SEND SEND0 SEND1 SENDV]).freeze
  # Arithmetic and ordering ops: gated (condition 3) and may raise on a non-numeric operand (condition 4).
  ARITH_OPS = Set.new(%w[ADD SUB MUL DIV ADDI SUBI LT LE GT GE]).freeze
  RAISING_OPS = Set.new(%w[GETCONST GETMCNST]).freeze
  # Ops that dispatch to a method by name without a SEND (vm.c OP_EQ is `==`, OP_NOT is `!`). They are checked against the
  # redefined names like a send, and they cannot raise.
  DISPATCH_OPS = { 'EQ' => '==', 'NOT' => '!' }.freeze
  # Every send opcode the call-site index reads (SEND0, SENDB, SSEND*), plus the two it does not list.
  SEND_OPS = (CallSiteIndex::SEND_OPS + %w[SEND1 SENDV]).uniq.freeze
  # Sends that install or dispatch a method by a name the argument carries: their target is the first argument.
  DYNAMIC_SENDS = %w[send __send__ public_send method instance_method define_method alias_method].freeze

  module_function

  # Summary and per-method rows for every method definition in +registry+ (name => [definitions]).
  def report(ireps, registry, constants: {})
    index = CallSiteIndex.build(ireps)
    unresolved = unresolved_calls(ireps, registry, index)
    redefined = redefined_names(registry)
    gate_ok = operator_gate_ok?(registry, redefined)
    rows = []
    registry.each do |name, definitions|
      definitions.each do |definition|
        next unless definition.irep

        # The registry names a body by its label; the irep is the one in +ireps+.
        body = ireps.fetch(definition.irep)
        sites = CallSiteIndex.sites(index, name)
        tuples = sites.map { |irep, idx, dest, argc| argc && (1..argc).map { |k| value_at(irep, idx, dest + k, nil, constants) } }
        constant_tuples = tuples.select { |t| t && t.none?(UNKNOWN) }
        unresolved_reason = unresolved_reason_for(name, unresolved)
        single = unresolved_reason.nil? && !tuples.empty? && tuples.all? { |t| t && t.none?(UNKNOWN) } && tuples.uniq.size == 1
        verdict = purity(body, redefined, gate_ok)
        pure = verdict[:impure].empty? && verdict[:may_raise].empty?
        # A jump's decision needs only a complete tuple: its tested value is a constant of the tuple or a literal on every
        # path, and no op in the body changes that value. Purity is not needed to decide it.
        decided = single ? decided_jumps(body, tuples.first, constants) : nil
        rows << { name: name, owner: definition.owner, sites: sites.size, constant_sites: constant_tuples.size,
                  unresolved: unresolved_reason, single_tuple: single, tuple: single ? tuples.first : nil,
                  pure: pure, impure: verdict[:impure], may_raise: verdict[:may_raise],
                  jumps: decided && decided[:total], decided: decided && decided[:decided] }
      end
    end
    rows.sort_by! { |r| [r[:owner].to_s, r[:name].to_s] }
    { rows: rows, summary: summary(rows, unresolved, redefined, gate_ok) }
  end

  def summary(rows, unresolved, redefined, gate_ok)
    {
      methods: rows.size,
      with_constant_sites: rows.count { |r| r[:constant_sites].positive? },
      unresolved_methods: rows.count { |r| r[:unresolved] },
      unresolved_global: unresolved[:global].any?,
      unresolved_names: unresolved[:names].keys.sort,
      computed_dynamic_names: unresolved[:dynamic].size,
      redefined_names: redefined.keys.sort,
      operator_gate_closed: !gate_ok,
      impure_methods: rows.count { |r| !r[:impure].empty? },
      may_raise_methods: rows.count { |r| r[:impure].empty? && !r[:may_raise].empty? },
      single_tuple: rows.count { |r| r[:single_tuple] },
      pure: rows.count { |r| r[:pure] },
      pure_single_tuple: rows.count { |r| r[:pure] && r[:single_tuple] },
      jumps_in_single_tuple: rows.sum { |r| r[:jumps] || 0 },
      jumps_decided: rows.sum { |r| r[:decided] || 0 },
      jumps_decided_pure: rows.sum { |r| r[:pure] ? (r[:decided] || 0) : 0 }
    }
  end

  # Condition 1. { global:, names: { name => [reasons] }, computed:, dynamic: Set }: a dynamic send whose target is a
  # literal names that method. One whose target is computed can reach only a name DynamicNames.universe
  # spells (see unresolved_reason_for), so its reasons and that set are kept apart from the global ones. An alias
  # AliasSites cannot decode and a to_enum site with a computed name can reach any name, so they stay global.
  def unresolved_calls(ireps, _registry, index)
    global = []
    names = Hash.new { |h, k| h[k] = [] }
    computed = []
    ireps.each_value do |irep|
      # The splat ops (SENDV/SENDVB/SSENDV/SSENDVB) carry the name the same way, so every op DynamicNames reads is scanned.
      irep.each_with_op(*(SEND_OPS | BytecodeIR::Ops::SEND_FAMILY.to_a)) do |insn, idx|
        sym = insn.sym
        # SSEND/SENDB carry their name the same way; a super send names the enclosing def, which the index keys.
        next unless DYNAMIC_SENDS.include?(sym)

        if sym == 'alias_method'
          alias_unresolved(irep, idx, names, global)
          next
        end
        target = CallSiteIndex.enum_target(irep, idx, insn, insn.reg.to_i + 1)
        if target.nil?
          computed << "#{sym} with a computed name"
        else
          names[target] << "#{sym} #{target}"
        end
      end
      irep.each_with_op('ALIAS') { |_insn, idx| alias_unresolved(irep, idx, names, global) }
    end
    global << 'to_enum with a computed name' unless index.fetch(CallSiteIndex::UNKNOWN_TARGET, []).empty?
    dynamic = computed.empty? ? Set.new : DynamicNames.universe(ireps).to_set
    { global: global.uniq, names: names, computed: computed.uniq, dynamic: dynamic }
  end

  # An alias makes two names reach one body: the new name, which calls can use with tuples the index does not key under the
  # old name, and the old name, whose body the new name runs. Both are unresolved. An alias AliasSites cannot decode (not
  # straight-line, or a computed name) could be either, so it is global.
  def alias_unresolved(irep, idx, names, global)
    site = AliasSites.site(irep, idx)
    if site.nil?
      global << 'alias with a name not decoded'
      return
    end

    reason = "alias #{site.new_name} #{site.old_name}"
    [site.new_name, site.old_name].each { |name| names[name] << reason }
  end

  # The reason +name+ is unresolved, or nil. A global reason covers every name; a computed-name send covers the names
  # DynamicNames spells.
  def unresolved_reason_for(name, unresolved)
    return unresolved[:global].join('; ') if unresolved[:global].any?

    reasons = unresolved[:names].key?(name) ? unresolved[:names][name].dup : []
    reasons.concat(unresolved[:computed]) if unresolved[:dynamic].include?(name)
    reasons.empty? ? nil : reasons.uniq.join('; ')
  end

  # Condition 2: name => owners of its Ruby definitions in the registry, for the names a pure body may send.
  def redefined_names(registry)
    (PURE_NAMES | ARITH_NAMES).each_with_object({}) do |name, out|
      owners = Array(registry[name]).select(&:irep).map { |d| d.owner.to_s }.uniq
      out[name] = owners unless owners.empty?
    end
  end

  # Condition 3: the Integer operator precondition (IntegerConstantRanges.integer_ops_safe?, with no included or prepended
  # modules and no unknown mixins recorded here: the closed world's own facts are not passed in, see the check), and no
  # redefinition of an arithmetic or ordering name.
  def operator_gate_ok?(registry, redefined)
    IntegerConstantRanges.integer_ops_safe?(registry, {}, {}, Set.new) && ARITH_NAMES.none? { |n| redefined.key?(n) }
  end

  # [verdict] with :impure (side effects, unsupported ops, redefined names, a closed operator gate) and :may_raise (ops or
  # sends that can raise on some receiver). A body is pure when both lists are empty.
  def purity(irep, redefined, gate_ok)
    impure = []
    may_raise = []
    BytecodeIR.for(irep).instructions.each do |ins|
      op = ins.op
      if SEND_OPS.include?(op)
        name = ins.source.sym
        if !PURE_NAMES.include?(name) then impure << "send #{name}"
        elsif redefined.key?(name) then impure << "redefined #{name}"
        elsif ARITH_NAMES.include?(name) && !gate_ok then impure << "operator gate #{name}"
        elsif !NON_RAISING_NAMES.include?(name) then may_raise << "send #{name}"
        end
      elsif (name = DISPATCH_OPS[op])
        impure << "redefined #{name}" if redefined.key?(name)
      elsif ARITH_OPS.include?(op)
        impure << "operator gate #{op}" unless gate_ok
        may_raise << op
      elsif RAISING_OPS.include?(op)
        may_raise << op
      elsif BytecodeIR::Ops::LOADI_OPS.include?(op) || PURE_OPS.include?(op)
        next
      else
        impure << op
      end
    end
    { impure: impure.uniq, may_raise: may_raise.uniq }
  end

  # The jumps of +irep+ decided by parameters holding +tuple+ (one value per parameter): a jump is decided when the value of
  # its tested register is known. JMPNIL is decided by whether the value is nil; JMPIF/JMPNOT by its truthiness.
  def decided_jumps(irep, tuple, constants)
    total = 0
    decided = 0
    BytecodeIR.for(irep).each_with_op(*BytecodeIR::CONDITIONAL_BRANCHES) do |ins, idx|
      total += 1
      value = value_at(irep, idx, ins.reg.to_i, tuple, constants)
      decided += 1 unless value == UNKNOWN
    end
    { total: total, decided: decided }
  end

  # The value of register +reg+ read at instruction +index+ of +irep+: UNKNOWN unless every reaching definition gives the
  # same constant. +tuple+ supplies the parameters (entry definitions of R1..Rn); nil means the caller's values are unknown.
  def value_at(irep, index, reg, tuple, constants, depth = 0)
    return UNKNOWN if depth > 32

    defs = BytecodeIR.reaching_definitions(irep, index, reg.to_s, shared: true)
    return UNKNOWN if defs.nil? || defs.empty?

    values = defs.map { |d| definition_value(irep, d, tuple, constants) }
    values.uniq.size == 1 ? values.first : UNKNOWN
  end

  def definition_value(irep, definition, tuple, constants)
    if definition.entry?
      slot = definition.reg.to_i - 1
      return UNKNOWN if tuple.nil? || slot.negative? || slot >= tuple.size

      return tuple[slot]
    end
    return UNKNOWN if definition.built

    literal_value(irep, BytecodeIR.for(irep).source_at(definition.index), constants)
  end

  # The value of a LOADI* literal, decoded as the numeric pass does (bytecode_ir_types.rb#integer_literal).
  def integer_literal(insn)
    case insn.op
    when :LOADI__1 then -1
    when BytecodeIR::Ops::LOADI_SLOT then insn.op.delete_prefix('LOADI_').to_i
    when :LOADI8, :LOADI16, :LOADI32, :LOADINEG
      value = insn.imm_operand&.to_i
      value && insn.op == :LOADINEG ? -value.abs : value
    end
  end

  def literal_value(irep, insn, constants)
    return UNKNOWN if insn.nil?

    op = insn.op
    if BytecodeIR::Ops::LOADI_OPS.include?(op)
      value = integer_literal(insn)
      return value.nil? ? UNKNOWN : [:int, value]
    end
    case op
    when :LOADNIL then nil
    when :LOADTRUE then true
    when :LOADFALSE then false
    when :LOADSYM then insn.sym_token ? [:sym, insn.sym_token.to_s] : UNKNOWN
    when :GETCONST then constants.fetch(insn.const_name.to_s, UNKNOWN)
    else UNKNOWN
    end
  end
end
