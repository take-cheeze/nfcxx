# frozen_string_literal: true

require_relative 'core_fact_sigs'
require_relative 'bytecode_ir_numeric'
require_relative 'bytecode_ir_ops'

# Shared index for analyses that need to visit every call to one method name.
# Build once per bc2cpp invocation rather than rescanning all instructions for
# every monomorphic name.
class CallSiteIndex
  SEND_OPS = BytecodeIR::Ops::SEND.to_a.freeze
  # Kernel#to_enum / enum_for (sig/bc2cpp/declarations.rbs#core_enumerators): `to_enum(:meth, *args)` later runs `meth(*args)` on
  # the receiver, so the site is a caller of `meth` although no SEND spells it.
  ENUM_SENDS = CoreFactSigs.enumerator_makers
  # Key of the sites whose method name is not a literal: any name could be their target. It is no
  # method name, so no registry entry collides with it. Read every list through .sites.
  UNKNOWN_TARGET = '(to_enum with a computed name)'
  # OP_SUPER (vm.c) is `goto L_SENDB_SYM` with mid = ci->mid, the ENCLOSING method's name, and the
  # same a/c operand layout as SENDB (args at R[a+1..], count c). It has no :name operand, so
  # `build` keys it by the name of the nearest enclosing `def` body. Without it the one `def set` a
  # `Class.new(A) { def set(x) = super("s") }` super call reaches (that def is in a block, so not
  # in the registry: `set` stays MONO) would look fed by its direct callers only.
  SUPER_OP = :SUPER

  def self.build(ireps)
    by_name = Hash.new { |hash, name| hash[name] = [] }
    super_names = nil
    ireps.each_value do |irep|
      irep.each_with_op(*SEND_OPS, SUPER_OP) do |insn, idx|
        name = insn.op == SUPER_OP ? (super_names ||= enclosing_def_names(ireps))[irep.label] : insn.sym
        next unless name

        dest = insn.reg.to_i
        # A packed send (`f(*a)`, n=*, vm.c CALL_MAXARGS) has no count: nil, so no consumer reads it as 0 args.
        argc = insn.n_spec == '*' || (insn.nk_spec && insn.nk_spec != '0') ? nil : insn.argc.to_i
        by_name[name] << [irep, idx, dest, argc]
        add_enum_site(by_name, irep, idx, insn, dest, argc) if ENUM_SENDS.include?(name)
      end
    end
    by_name
  end

  # The call sites a consumer must treat as reaching +name+: its own plus every to_enum site whose target
  # name is computed. A computed-name site is kept as a caller of EVERY name (same arity matching as any
  # other caller), the conservative choice over refusing the whole analysis: it only ever adds callers.
  def self.sites(index, name)
    index.fetch(name, []) + index.fetch(UNKNOWN_TARGET, [])
  end

  # `to_enum(:meth, a, b)` is a call `meth(a, b)`. Register dest + 1 holds :meth, so the entry is anchored at
  # dest + 1 and counts one fewer argument: a consumer's register dest' + k is then argument k of meth. A
  # keyword (nk) or packed (n=*) site has no count, exactly like a direct send, which blocks the facts of
  # meth. A block is to_enum's size block, not an argument of meth. No arguments at all means `:each`.
  def self.add_enum_site(by_name, irep, idx, insn, dest, argc)
    forwarded = argc && (argc - 1)
    if argc == 0
      by_name['each'] << [irep, idx, dest + 1, 0]
      return
    end
    targets = enum_targets(irep, idx, insn, dest + 1)
    (targets || [UNKNOWN_TARGET]).each do |target|
      by_name[target] << [irep, idx, dest + 1, forwarded]
    end
  end

  # A singleton name for consumers whose contract cannot represent alternatives.
  def self.enum_target(irep, idx, insn, reg)
    names = enum_targets(irep, idx, insn, reg)
    names.first if names && names.size == 1
  end

  # Every possible literal Symbol name, or nil when any reaching value is unknown.
  def self.enum_targets(irep, idx, insn, reg)
    return packed_enum_targets(irep, idx, reg) if insn.n_spec == '*'

    symbol_targets(irep, idx, reg)
  end

  def self.symbol_targets(irep, idx, reg)
    writers = BytecodeIR.reaching_writer_indices(irep, idx, reg)
    return nil unless writers

    program = BytecodeIR.for(irep)
    names = writers.map do |index|
      writer = program.source_at(index)
      case writer.op
      when :LOADSYM then writer.sym
      when :SYMBOL
        value = irep.pool[writer.pool_index]
        value if value.is_a?(String)
      end
    end
    names.all?(String) ? names.uniq : nil
  end

  # A fresh nonempty prefix retains its head across append instructions only while
  # no alias can expose it (including a closure read during ARYCAT's to_a callback).
  def self.packed_enum_targets(irep, idx, reg)
    program = BytecodeIR.for(irep)
    at = idx
    origin = nil
    idx.times do
      writers = BytecodeIR.reaching_definitions(irep, at, reg, follow_moves: false, through_handlers: true, shared: true)
      return nil unless writers && writers.size == 1 && !writers.first.entry?

      writer = writers.first.index
      source = program.source_at(writer)
      if source.op == :ARRAY
        origin = writer
        break
      end
      return nil unless %i[ARYCAT ARYPUSH].include?(source.op) && source.reg == reg

      at = writer
    end
    return nil unless origin && program.linear_corridor?(origin, idx, include_handlers: true)

    literal = program.container_literal(origin)
    return nil unless literal && literal.kind == :array && literal.count.positive?
    return nil if packed_register_captured?(irep, reg)
    return nil unless (origin + 1...idx).all? do |index|
      source = program.source_at(index)
      if %i[ARYCAT ARYPUSH].include?(source.op)
        source.reg == reg
      elsif source.op == :NOP
        true
      else
        quiet = %i[MOVE LOADL LOADSYM LOADNIL LOADSELF LOADTRUE LOADFALSE STRING SYMBOL GETUPVAR].include?(source.op) ||
                BytecodeIR::Ops::LOADI_OPS.include?(source.op)
        quiet && !source.regs.include?(reg)
      end
    end

    symbol_targets(irep, origin, literal.base)
  end

  def self.packed_register_captured?(irep, reg)
    return false if Array(irep.reps).empty?
    return true unless irep.tree

    captured = false
    lookup = ->(label) { irep.tree.fetch(label) }
    Array(irep.reps).each do |label|
      BytecodeIR.each_nested_insn(lookup.call(label), lookup) do |source, depth|
        next unless %i[GETUPVAR SETUPVAR].include?(source.op)

        index, level = source.upvar_ref
        captured = true if index.to_s == reg && level == depth
      end
    end
    captured
  end

  # irep label -> name of its nearest enclosing `def` body (the irep itself when it is one), from the
  # def instructions themselves (TDEF, SDEF, METHOD+DEF) rather than the registry, which omits defs
  # inside blocks. Unresolvable (a block never under a `def`, e.g. `define_method(:n) { super }`): no
  # entry, and that name is a DynamicNames literal, which the joins already refuse.
  def self.enclosing_def_names(ireps)
    body_name = {}
    parent = {}
    ireps.each_value do |irep|
      (irep.reps || []).each { |child| parent[child] = irep.label }
      irep.each_with_op(:TDEF, :SDEF, :DEF) do |insn, idx|
        case insn.op
        when :TDEF, :SDEF
          child = irep.reps[insn.block_index]
          body_name[child] = insn.sym if child && insn.sym
        when :DEF
          mi = irep.previous_real_index(idx - 1)
          meth = mi >= 0 ? BytecodeIR.for(irep).source_at(mi) : nil
          next unless meth && meth.op == :METHOD && insn.paren_reg == meth.reg

          child = irep.reps[meth.block_index]
          body_name[child] = insn.sym if child && insn.sym
        end
      end
    end
    ireps.each_key.each_with_object({}) do |label, out|
      up = label
      up = parent[up] until up.nil? || body_name.key?(up)
      out[label] = body_name[up] if up
    end
  end
end
