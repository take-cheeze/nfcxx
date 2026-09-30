# frozen_string_literal: true

require 'set'
require_relative 'bytecode_ir'

# Step 6b: which statically named ivars use compiler-managed RData slots.

# Opcodes that print a READ-only register as their first `R<n>` operand.
# mruby/ops.h: RETURN/RETURN_BLK "return R[a]", BREAK, JMPIF/JMPNOT/JMPNIL
# "if R[a] ...", RAISEIF, MATCHERR, SETUPVAR "uvset(b,c,R[a])"; codedump.c prints
# them that way. Skipping a non-writer is as sound as skipping a MOVE to another
# register; without it an early `return v if v == @flag` stopped the trace for a
# later `@flag = v`. SETUPVAR's `b`/`c` are slot/level numbers in an ancestor
# frame, not this irep's registers, so its only `R` token is a same-frame read.
READ_ONLY_OPCODE_SKIP = %w[RETURN RETURN_BLK BREAK JMPIF JMPNOT JMPNIL RAISEIF MATCHERR SETUPVAR].freeze
# IvarLayout.trace_type also steps over RESCUE's read operand; its write is a barrier.
TRACE_TYPE_SKIP_OPS = (READ_ONLY_OPCODE_SKIP + %w[RESCUE]).freeze

# ---------------------------------------------------------------------------
# Step 6b: ivar embedding: which ivars can move out of iv_tbl into C struct
# fields on an RData payload. `all` builds the universal mrb_value
# layout used by generated code; `analyze` remains the narrower type proof
# consumed by arithmetic and return analysis.
#
# An ivar is embeddable as type T when EVERY SETIV of it, in every method of
# every class (closed world), traces (through MOVEs, within one method body)
# to a source that is always T: a literal, a proven arithmetic result, or an
# ivar already known to be T. One opaque source or a type mismatch makes it
# permanently dynamic.
#
# A fixed point: `@count = @count + 1` needs initialize's `@count = 0` to be
# known first, so all methods are swept until the type map stops changing.
class IvarLayout
  UNKNOWN = :unknown
  # NILABLE_EMBED_SUPPORT: `@x = nil` is evidence of one more concrete value, not
  # of an unreadable one. The join below widens it into FIXNUM_NIL rather than
  # poisoning the field, which is what kept every nilable ivar in iv_tbl.
  NIL = :nil_literal
  # The only nullable embeddable type: Integer or nil. Both arms are immediates,
  # so the payload needs no GC rooting (see CodeGen::C_TYPE).
  FIXNUM_NIL = :fixnum_nil

  # A field declared for an embedding type is claimed by one analysis only; the
  # caller-supplied declaration names it explicitly (see bc2cpp.rb's
  # FIXNUM_NIL_DECLARATION), so a claimed field that the sweep cannot type at
  # all is the declaration's own claim, not a silent inference.
  EMBEDDABLE = %i[fixnum symbol bool fixnum_nil].freeze

  # A field that widens to FIXNUM_NIL is claimed by the ordinary join, like
  # every other concrete type here. FIXNUM_NIL_DECLARATION (the env var) no
  # longer gates it -- it is an additional allowance for a field the sweep
  # cannot type at all, kept because it is how the Optcarrot probe names a
  # field whose only Fixnum write is an opaque send. A field the sweep CAN
  # type is now inferred either way.
  def self.fixnum_nil_fields(declaration)
    # NOT String#split, for either separator: Ruby splits on a whitespace-
    # delimited "#" COMMENT marker, so both split(',') and split('#', 2)
    # silently drop the "@ivar" from "Owner#@ivar" and leave just the owner
    # (measured, not assumed). Scan for the literal separator instead.
    (declaration || '').scan(/[^,]+/).each_with_object(Hash.new { |h, k| h[k] = Set.new }) do |entry, out|
      entry = entry.strip
      next if entry.empty?

      at = entry.index('#')
      next unless at

      owner = entry[0...at]
      ivar = entry[(at + 1)..]
      next if owner.empty? || ivar.to_s.empty?

      out[owner] << ivar.delete_prefix('@')
    end
  end

  # Every statically named instance variable uses an mrb_value slot in the
  # compiler-managed RData payload. Dynamic names keep the ordinary iv_tbl.
  def self.all(ireps, registry)
    ivars = Hash.new { |h, owner| h[owner] = Set.new }
    registry.each_value do |defs|
      defs.each do |d|
        next if d.owner.end_with?('.singleton')

        if d.irep
          ireps.fetch(d.irep).instructions.each do |insn|
            next unless %w[GETIV SETIV].include?(insn.op)

            name = insn.ivar
            ivars[d.owner] << name if name
          end
        elsif d.kind == :ivar_accessor
          ivars[d.owner] << d.name.chomp('=')
        end
      end
    end
    ivars.each_with_object({}) do |(owner, names), layout|
      layout[owner] = names.to_a.sort.to_h { |name| [name, :value] } unless names.empty?
    end
  end

  # `arg_types` (ArgTypes.analyze) and `annotations` (Annotations.extract) can
  # only make more ivars embeddable, never fewer. Annotations also reach
  # #initialize, which ArgTypes cannot.
  def self.analyze(ireps, registry, arg_types = {}, annotations = {}, integer_constants = nil,
                    fixnum_return_names = nil, fixnum_nil = {})
    fixnum_nil = self.fixnum_nil_fields(fixnum_nil) if fixnum_nil.is_a?(String)
    # class -> labels of its leaf methods. Native MethodDefs have no irep and are
    # skipped.
    methods_of = Hash.new { |h, k| h[k] = [] }
    registry.each_value { |defs| defs.each { |d| methods_of[d.owner] << d.irep if d.irep } }
    # irep label -> MethodDef, so a trace ending at an incoming argument can look
    # up that method's name/arity.
    def_of_irep = {}
    registry.each_value { |defs| defs.each { |d| def_of_irep[d.irep] = d if d.irep } }

    types = Hash.new { |h, k| h[k] = {} } # class_name -> {ivar_name => type or UNKNOWN}
    # FIXNUM_NIL_DECLARATION: the set of concrete types a field was ever SEEN to
    # hold, kept separately from `types` because `types` stores UNKNOWN once a
    # single arm is unreadable -- and a later nil write must still be able to
    # read that back as "Integer or nil" on a declared field. Joining
    # in-place made the answer depend on which SETIV the sweep visited first
    # (measured: the opaque-send fixture embedded only on one order).
    seen = Hash.new { |h, k| h[k] = {} }

    10.times do
      changed = false
      methods_of.each do |klass, irep_labels|
        irep_labels.each do |label|
          irep = ireps.fetch(label)
          d = def_of_irep[label]
          enter = irep.enter
          mand = enter ? enter.enter_fields.first : 0
          irep.each_with_op('SETIV') do |insn, idx|
            ivar = insn.ivar
            # Not `$`-anchored: "SETIV @x R1 ; R1:v" carries a trailing local-name comment
            # whenever the source is a named local.
            src_reg = insn.regs.first
            inferred = trace_type(irep, idx, src_reg, types[klass], arg_types, mand, d&.name, annotations, registry,
                                   integer_constants, fixnum_return_names)
            before = types[klass][ivar]
            # NILABLE_EMBED_SUPPORT: inferred, like every other concrete type
            # here -- a field written only Integers and nil widens by the
            # ordinary join, with no declaration.
            #
            # FIXNUM_NIL_DECLARATION additionally lets a DECLARED field survive
            # a contribution trace_type cannot READ -- the Optcarrot
            # CPU#@opcode shape, whose only Fixnum write is `fetch(@_pc)`. A
            # declaration supplies the Integer half in that one case.
            #
            # It must NOT excuse a contribution the analysis can read and finds
            # to be something else. That distinction is the whole safety
            # argument: `ary + ary` reads UNKNOWN here (an arithmetic write is
            # never a Fixnum, ADR 0279), and readable_but_other steps over the
            # ADD to the Array literal, so a declaration cannot admit the Array
            # field as Integer-or-nil. `readable_but_other` is exactly the set
            # the analysis has already resolved to a different concrete type.
            unreadable = inferred == UNKNOWN && !readable_but_other(irep, idx, src_reg)
            seen[klass][ivar] = infer_join(seen[klass][ivar], inferred) if inferred != UNKNOWN
            merged = if fixnum_nil[klass]&.include?(ivar) && unreadable
                       join(seen[klass][ivar] || NIL, :fixnum)
                     else
                       join(before, inferred)
                     end
            if merged != before
              types[klass][ivar] = merged
              changed = true
            end
          end
        end
      end
      break unless changed

    end

    # Only embeddable (non-UNKNOWN) entries matter to codegen. NIL is excluded by
    # EMBEDDABLE, not by an UNKNOWN test: a nil-only field has a known type and
    # simply has no storage representation (NILABLE_EMBED_SUPPORT).
    embeddable = types.each_with_object({}) do |(klass, ivars), out|
      subset = ivars.select { |_, t| EMBEDDABLE.include?(t) }
      out[klass] = subset unless subset.empty?
    end

    # SEEN_BUT_NOT_EMBEDDED: the ivars the sweep EXAMINED and did not embed.
    # analyze returns only the embeddable subset, so a field that stayed UNKNOWN
    # is absent from its result and indistinguishable from one never analysed --
    # which is what made "how many more ivars are embeddable?" unanswerable
    # without instrumenting the fixed point and reading one pass as if it were
    # the settled result (which produced four wrong numbers).
    #
    # Recorded for the diagnostic only. The return value is unchanged, so no
    # caller and no generated byte can depend on it.
    if ENV['BC2CPP_SEEN_IVARS']
      types.each do |klass, ivars|
        ivars.each do |ivar, type|
          next if EMBEDDABLE.include?(type)

          warn format('  SEEN_UNEMBEDDED  %s#@%s  (%s)', klass, ivar, type)
        end
      end
    end

    embeddable
  end

  # Two contributions must agree or the ivar is poisoned to UNKNOWN, and UNKNOWN
  # joins to UNKNOWN from either side. The sweep has no fixed order across
  # methods, so dropping an UNKNOWN because a concrete type arrived first would
  # make the result order-dependent and unsound (it wrongly embedded ivars in
  # Game::Screen and Game::State; see ADR 0139).
  #
  # NILABLE_EMBED_SUPPORT: the one non-unanimous join is NIL against
  # :fixnum, in either order, producing FIXNUM_NIL: both values are immediates,
  # so the pair is representable. A nil-only field stays NIL, which is not
  # embeddable (C_TYPE has no entry), so `@x = nil` alone still leaves it in
  # iv_tbl. Everything else that disagrees still poisons.
  def self.join(a, b)
    return b if a.nil? || a == BOTTOM        # no fact yet
    return a if b == BOTTOM
    return UNKNOWN if a == UNKNOWN || b.nil?
    return UNKNOWN if b == UNKNOWN
    return a if a == b                      # the ordinary agreement
    return FIXNUM_NIL if nullable_pair?(a, b)

    UNKNOWN
  end

  # `join` without the UNKNOWN stickiness, for the `seen` table only: it keeps
  # the CONCRETE types a field was ever written with, so a declared field can be
  # re-read as "Integer or nil" after an unreadable arm has already poisoned
  # `types`. The result is never used as an embedding decision on its own.
  def self.infer_join(a, b)
    return b if a.nil?
    return a if b.nil?
    return a if a == b
    return FIXNUM_NIL if nullable_pair?(a, b)

    UNKNOWN
  end

  # FIXNUM_NIL_DECLARATION's safety test: is this SETIV's source a value the
  # analysis could READ and resolved to something that is NOT a Fixnum? Such a
  # site contradicts a fixnum_nil claim outright and must keep poisoning, while
  # an unreadable one (an opaque send, a call whose result the analysis cannot
  # type) is exactly what the declaration exists to tolerate.
  #
  # Deliberately coarse and conservative: it returns true only for a site whose
  # value the analysis positively resolved to a non-Fixnum, so a false "readable"
  # can only cost an embedding, never admit a wrong one.
  def self.readable_but_other(irep, idx, src_reg)
    # An arithmetic site is never a Fixnum (see the ADD arm of trace_type), so the
    # value is not readable and the walk steps over it.
    irep.walk_writers(idx - 1, src_reg, skip_ops: %w[ADD ADDI SUB SUBI MUL DIV], follow_moves: true) do |insn|
      case insn.op
      when /^LOADI/, 'LOADNIL'
        false # a literal Integer (readable, and a Fixnum) or nil (legal in the type)
      when 'LOADSYM', 'LOADTRUE', 'LOADFALSE', 'STRING', 'ARRAY', 'ARRAY2', 'HASH', 'RANGE_INC', 'RANGE_EXC'
        true # positively another kind of value
      else
        false # an unmodeled writer: unreadable, not "other"
      end
    end || false
  end

  # NILABLE_EMBED_SUPPORT: the only disagreeing pairs that are still
  # representable, since nil and an mrb_int are both immediates. Commutative
  # in both arguments and absorbing on both sides, so the sweep's method order
  # cannot change the answer -- the same property `join`'s sticky-UNKNOWN rule
  # above exists to guarantee (ADR 0139).
  NULLABLE_PAIRS = [
    %i[fixnum nil_literal].freeze,
    %i[fixnum_nil nil_literal].freeze,
    %i[fixnum fixnum_nil].freeze
  ].freeze

  def self.nullable_pair?(a, b)
    NULLABLE_PAIRS.any? { |left, right| (a == left && b == right) || (a == right && b == left) }
  end

  # A hop whose write does not dominate its read (ADR 0261): join every reaching definition.
  JOIN_BREAK = :join_break

  # A query already being answered (a loop-carried value): the identity of the
  # join, the least fixed point of `x = join(init, x + 1)`. Never a final answer.
  BOTTOM = :bottom

  TRACE_STATE = { depth: 0, active: Set.new }

  # The type of `reg` at `idx`: the nearest writer's when it dominates the read,
  # else the join over every reaching definition, UNKNOWN when they cannot be
  # accounted for.
  def self.trace_type(irep, idx, reg, known_ivar_types, arg_types = nil, mand = 0, method_name = nil, annotations = nil,
                       registry = nil, integer_constants = nil, fixnum_return_names = nil)
    args = [known_ivar_types, arg_types, mand, method_name, annotations, registry, integer_constants,
            fixnum_return_names]
    TRACE_STATE[:depth] += 1
    begin
      type = trace_type_joined(irep, idx, reg, args)
    ensure
      TRACE_STATE[:depth] -= 1
    end
    type == BOTTOM && TRACE_STATE[:depth].zero? ? UNKNOWN : type
  end

  def self.trace_type_joined(irep, idx, reg, args)
    walked = trace_type_walk(irep, idx, reg, *args)
    return walked unless walked == JOIN_BREAK

    key = [irep.label, idx, reg.to_s]
    return BOTTOM unless TRACE_STATE[:active].add?(key)

    begin
      defs = BytecodeIR.reaching_definitions(irep, idx, reg.to_s)
      return UNKNOWN if defs.nil? || defs.empty?

      defs.map do |d|
        # An entry definition has no write to walk back to: index 0 reaches the top of the body.
        trace_type_walk(irep, d.entry? ? 0 : d.index + 1, d.reg, *args, trusted: true)
      end.reduce { |a, b| join(a, b) }
    ensure
      TRACE_STATE[:active].delete(key)
    end
  end

  # `% & | ^` are Fixnum only when both operands are (they never leave the Fixnum range);
  # a cyclic one is BOTTOM. ADD/SUB/MUL/ADDI/SUBI are never Fixnum (ADR 0279).
  def self.fixnum_operands(left, right)
    fix = ->(t) { t == :fixnum || t == BOTTOM }
    return nil unless fix.call(left) && fix.call(right)

    left == BOTTOM && right == BOTTOM ? BOTTOM : :fixnum
  end

  # Walk back from `idx` for the last writer of `reg`, following MOVEs, until a
  # type-determining opcode or the top of the body (an incoming argument);
  # JOIN_BREAK when a hop does not dominate its read. `trusted`: the walk starts
  # at a reaching definition, whose first hop needs no proof.
  def self.trace_type_walk(irep, idx, reg, known_ivar_types, arg_types = nil, mand = 0, method_name = nil,
                            annotations = nil, registry = nil, integer_constants = nil, fixnum_return_names = nil,
                            trusted: false)
    use = idx
    # RESCUE is `R[b] = R[a].isa?(R[b])` (ops.h), printed `RESCUE\tR%d\tR%d`: the
    # write lands on the SECOND register. `a` is a read (skipped); `b` is a real
    # write and must stop the trace like the generic `else`.
    rescue_write = ->(insn, cur) { insn.op == 'RESCUE' && insn.regs[1] == cur }
    at_entry = lambda do |last|
      # Never written in this block: an incoming argument. Register N is argument N
      # for N <= mand (as in CodeGen#compile_method). Use ArgTypes' whole-program
      # inference if it has one; otherwise the value is opaque.
      pos = last.to_i
      if pos.between?(1, mand)
        # An annotation is per-definition (keyed by irep), so it is trusted whether
        # the name is MONO or POLY; tried first.
        # EMBED_TYPE_SAFETY: only :fixnum and :symbol pass. Other tokens (:array) have
        # no TYPE_OPS entry, and letting them through surfaced later as a KeyError in
        # GETIV/SETIV codegen of an unrelated owner.
        t = annotations && annotations[irep.label]&.args&.[](pos - 1)
        next t if t == :fixnum || t == :symbol

        t = arg_types && method_name && arg_types[method_name]&.[](pos - 1)
        next t if t
      end
      UNKNOWN
    end
    entry_checked = lambda do |last|
      type = at_entry.call(last)
      type == UNKNOWN || trusted || BytecodeIR.write_dominates?(irep, BytecodeIR::ENTRY, use, last) ? type : JOIN_BREAK
    end
    irep.walk_writers(idx - 1, reg, skip_ops: TRACE_TYPE_SKIP_OPS, barrier: rescue_write, barrier_result: UNKNOWN,
                                    exhausted: entry_checked) do |insn, i, cur|
      return JOIN_BREAK unless (trusted && i == idx - 1) || BytecodeIR.write_dominates?(irep, i, use, cur)

      use = i
      case insn.op
      when 'MOVE'
        next IrepScans.follow(insn.regs[1])
      when /^LOADI/
        next :fixnum
      when 'LOADSYM'
        # A Symbol is as safe to embed as a Fixnum: an mrb_sym is an interned id, not a
        # GC object (symbol.c frees the table only at mrb_close). See CodeGen::TYPE_OPS.
        next :symbol
      when 'LOADNIL'
        # NILABLE_EMBED_SUPPORT: nil is a concrete value, so it is a contribution
        # the join can widen (NIL + :fixnum -> FIXNUM_NIL) instead of the UNKNOWN
        # this used to return, which poisoned every nilable ivar.
        next NIL
      when 'LOADTRUE', 'LOADFALSE'
        # BOOL_EMBED_SUPPORT: LOADT/LOADF. true/false are immediates in every boxing
        # this project targets (word, no-float, nan), so an mrb_bool field needs no GC
        # keep-alive. See CodeGen::TYPE_OPS :bool.
        next :bool
      when 'GETCONST', 'GETMCNST'
        # INTEGER_CONST_EMBED_SUPPORT: `@x = SOME_CONST` is Fixnum when
        # IntegerConstants.analyze admitted the bare name (the proof GETCONST's fast
        # path trusts). `integer_constants` is nil for callers that never ran the scan
        # (ArgTypes), and then nothing is proven. GETMCNST keys on the bare name after
        # `::`; see IntegerConstants.analyze for why that is required.
        name = insn.const_name
        next :fixnum if name && integer_constants&.include?(name)

        next UNKNOWN
      when 'ADD', 'SUB', 'MUL', 'ADDI', 'SUBI'
        # ADR 0279: the result can leave the Fixnum range, where Integer#+ (and the
        # compiled arm) builds a bigint that a mrb_int field cannot hold. An
        # arithmetic write therefore keeps the ivar an ordinary :value slot.
        next UNKNOWN
      when 'GETIV'
        other_ivar = insn.ivar
        known = known_ivar_types[other_ivar]
        # EMBED_TYPE_SAFETY: a nilable (or unknown) source is not a concrete
        # scalar, so it never propagates a type to the copy (NILABLE_EMBED_SUPPORT).
        next known if EMBEDDABLE.include?(known)

        next UNKNOWN
      when 'SEND', 'SEND0', 'SSEND', 'SSEND0'
        # FIXNUM_BINOP_EMBED_SUPPORT: %, &, |, ^ never promote to Bignum (like
        # compile_send's FIXNUM_BINARY fast path; +/-/* and << can overflow). Sound only
        # when both operands are proven Fixnum AND the operator has no override
        # anywhere (native_only_mono?).
        name = insn.sym
        if registry && %w[% & | ^].include?(name) && insn.argc == 1 && native_only_mono?(registry, name)
          arg_reg = (cur.to_i + 1).to_s
          left = trace_type(irep, i, cur, known_ivar_types, arg_types, mand, method_name, annotations, registry, integer_constants, fixnum_return_names)
          right = trace_type(irep, i, arg_reg, known_ivar_types, arg_types, mand, method_name, annotations, registry, integer_constants, fixnum_return_names)
          fixnum = fixnum_operands(left, right)
          next fixnum if fixnum
        end

        # FIXNUM_RETURN_IVAR_HINT: a send of a name in FIXNUM_RETURN_PROOF's set
        # leaves a Fixnum in its destination for any receiver: that proof already
        # requires exactly one MethodDef, so the call either raises NoMethodError or
        # reaches that definition. No native_only_mono? re-check needed.
        # `fixnum_return_names` is nil for callers without a CodeGen (ArgTypes).
        next :fixnum if name && fixnum_return_names&.include?(name)

        next UNKNOWN
      else
        # Any other opcode's first operand is almost always its destination, so stop
        # at UNKNOWN. Skipping an unrecognized writer could reach an unrelated earlier
        # write to a reused register and misattribute its type.
        UNKNOWN
      end
    end
  end

  # Same guarantee as CodeGen#native_only_mono?, duplicated because that one
  # reads CodeGen's @registry. `fetch`, not `[]`: the default proc would insert
  # `name` while analyze iterates the registry (a name can have no def since
  # docs/adr/0203).
  def self.native_only_mono?(registry, name)
    defs = registry.fetch(name) { return false }
    defs.size == 1 && defs.first.irep.nil?
  end
end
