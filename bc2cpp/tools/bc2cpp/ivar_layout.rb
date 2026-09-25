# frozen_string_literal: true

# Step 6b: which ivars embed into typed C struct fields.

# Opcodes that print a READ-only register as their first `R<n>` operand --
# see IvarLayout.trace_type's own `when *READ_ONLY_OPCODE_SKIP` arm.
READ_ONLY_OPCODE_SKIP = %w[RETURN RETURN_BLK BREAK JMPIF JMPNOT JMPNIL RAISEIF MATCHERR SETUPVAR].freeze

# ---------------------------------------------------------------------------
# Step 6b: ivar embedding: which ivars can move out of iv_tbl into typed C
# struct fields on an RData payload.
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
          enter = irep.instructions.find { |i| i.op == 'ENTER' }
          mand = enter ? enter.args.split(':').first.to_i : 0
          irep.instructions.each_with_index do |insn, idx|
            next unless insn.op == 'SETIV'
            ivar = insn.args[/@(\w+)/, 1]
            # Not `$`-anchored: "SETIV @x R1 ; R1:v" carries a trailing local-name comment
            # whenever the source is a named local.
            src_reg = insn.args[/R(\d+)/, 1]
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
            # argument, and it is why the ADD arm now recurses into both
            # operands (see that arm's comment): without that, `ary + ary`
            # reads UNKNOWN here and a declaration would admit the Array field
            # as Integer-or-nil. `readable_but_other` is exactly the set the
            # analysis has already resolved to a different concrete type.
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
    types.each_with_object({}) do |(klass, ivars), out|
      embeddable = ivars.select { |_, t| EMBEDDABLE.include?(t) }
      out[klass] = embeddable unless embeddable.empty?
    end
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
    return b if a.nil?                       # no fact yet
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
    (idx - 1).downto(0) do |i|
      insn = irep.instructions[i]
      case insn.op
      when 'MOVE'
        d, s = insn.args.scan(/R(\d+)/).flatten
        next unless d == src_reg

        src_reg = s
      when /^LOADI/
        d = insn.args[/^R(\d+)/, 1]
        next unless d == src_reg

        return false # a literal Integer: readable, and a Fixnum
      when 'LOADNIL'
        d = insn.args[/^R(\d+)/, 1]
        next unless d == src_reg

        return false # nil: legal in the type
      when 'LOADSYM', 'LOADTRUE', 'LOADFALSE', 'STRING', 'ARRAY', 'ARRAY2', 'HASH', 'RANGE_INC', 'RANGE_EXC'
        d = insn.args[/^R(\d+)/, 1]
        next unless d == src_reg

        return true # positively another kind of value
      when 'ADD', 'ADDI', 'SUB', 'SUBI', 'MUL', 'DIV'
        # An arithmetic site is a Fixnum only when its operands prove (see the
        # ADD arm); it was refused here, so the value is not readable.
        next
      else
        d = insn.args[/^R(\d+)/, 1]
        return false if d == src_reg # an unmodeled writer: unreadable, not "other"

        next
      end
    end
    false
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

  # Walk back from `idx` for the last writer of `reg`, following MOVEs, until a
  # type-determining opcode or the top of the body (an incoming argument).
  def self.trace_type(irep, idx, reg, known_ivar_types, arg_types = nil, mand = 0, method_name = nil, annotations = nil,
                       registry = nil, integer_constants = nil, fixnum_return_names = nil)
    (idx - 1).downto(0) do |i|
      insn = irep.instructions[i]
      case insn.op
      when 'MOVE'
        d, s = insn.args.scan(/R(\d+)/).flatten
        next unless d == reg

        reg = s
      when /^LOADI/
        d = insn.args[/^R(\d+)/, 1]
        next unless d == reg

        return :fixnum
      when 'LOADSYM'
        d = insn.args[/^R(\d+)/, 1]
        next unless d == reg
        # A Symbol is as safe to embed as a Fixnum: an mrb_sym is an interned id, not a
        # GC object (symbol.c frees the table only at mrb_close). See CodeGen::TYPE_OPS.
        return :symbol
      when 'LOADNIL'
        d = insn.args[/^R(\d+)/, 1]
        next unless d == reg

        # NILABLE_EMBED_SUPPORT: nil is a concrete value, so it is a contribution
        # the join can widen (NIL + :fixnum -> FIXNUM_NIL) instead of the UNKNOWN
        # this used to return, which poisoned every nilable ivar.
        return NIL
      when 'LOADTRUE', 'LOADFALSE'
        # BOOL_EMBED_SUPPORT: LOADT/LOADF. true/false are immediates in every boxing
        # this project targets (word, no-float, nan), so an mrb_bool field needs no GC
        # keep-alive. See CodeGen::TYPE_OPS :bool.
        d = insn.args[/^R(\d+)/, 1]
        next unless d == reg

        return :bool
      when 'GETCONST', 'GETMCNST'
        # INTEGER_CONST_EMBED_SUPPORT: `@x = SOME_CONST` is Fixnum when
        # IntegerConstants.analyze admitted the bare name (the proof GETCONST's fast
        # path trusts). `integer_constants` is nil for callers that never ran the scan
        # (ArgTypes), and then nothing is proven. GETMCNST keys on the bare name after
        # `::`; see IntegerConstants.analyze for why that is required.
        d = insn.args[/^R(\d+)/, 1]
        next unless d == reg

        name = insn.op == 'GETCONST' ? insn.args.split(/\s+/)[1] : insn.args[/::(\S+)/, 1]
        return :fixnum if name && integer_constants&.include?(name)

        return UNKNOWN
      when 'ADDI'
        d = insn.args[/^R(\d+)/, 1]
        next unless d == reg
        # ADDI is `+= <literal>`: OP_ADDI is a plain integer add on the
        # destination, so it keeps the destination's own type. When the
        # destination is not known to be a Fixnum the value is not one either
        # (`1 + []` would not reach here, but `@x = @y += 1` with an Array
        # `@y` would), so trace the destination rather than assume.
        return trace_type(irep, i, d, known_ivar_types, arg_types, mand, method_name, annotations, registry, integer_constants, fixnum_return_names)
      when 'ADD'
        d = insn.args[/^R(\d+)/, 1]
        next unless d == reg
        # ADD is `+`, which is Integer#+ ONLY when both operands are Integers;
        # for two Arrays it is Array#+ and yields an Array. This is the same
        # rule codegen_insn's own ADD arm uses before it emits the bare
        # `mrb_fixnum_value(a + b)` fast path (codegen_insn.rb:177,
        # proven_fixnum_pair?), so inference here and the emitted fast path
        # cannot disagree.
        #
        # This is what makes inferred fixnum_nil sound. Returning an
        # unconditional :fixnum here was a real pre-existing hole -- it typed
        # `ary + ary` as a Fixnum -- which stayed invisible only because a
        # nilable field's nil write used to poison the join (RPG2k::Scene::
        # EquipMenu#@candidates, `@candidates = real + [[0, 0]]`, hit it once
        # NILABLE_EMBED_SUPPORT stopped poisoning). A nonnil Array field
        # still escapes through some other writer's own evidence, so this
        # arm is a missed embedding, not a wrong one.
        s = insn.args[/\(R(\d+)\)/, 1]
        if s
          left = trace_type(irep, i, d, known_ivar_types, arg_types, mand, method_name, annotations, registry, integer_constants, fixnum_return_names)
          right = trace_type(irep, i, s, known_ivar_types, arg_types, mand, method_name, annotations, registry, integer_constants, fixnum_return_names)
          return :fixnum if left == :fixnum && right == :fixnum
        end
        return UNKNOWN
      when 'SUB', 'MUL'
        d = insn.args[/^R(\d+)/, 1]
        next unless d == reg

        # FIXNUM_SUBMUL_EMBED_SUPPORT: SUB/MUL (vm.c OP_MATH) dispatch on both operand
        # types, so they are Fixnum only when both operands are proven Fixnum
        # recursively. Overflow could make the value wrong but not the type, and the
        # embedded SETIV re-checks the type before storing (TypeError, not memory
        # corruption).
        s = insn.args[/\(R(\d+)\)/, 1]
        if s
          left = trace_type(irep, i, d, known_ivar_types, arg_types, mand, method_name, annotations, registry, integer_constants, fixnum_return_names)
          right = trace_type(irep, i, s, known_ivar_types, arg_types, mand, method_name, annotations, registry, integer_constants, fixnum_return_names)
          return :fixnum if left == :fixnum && right == :fixnum
        end
        return UNKNOWN
      when 'SUBI'
        d = insn.args[/^R(\d+)/, 1]
        next unless d == reg

        # FIXNUM_SUBMUL_EMBED_SUPPORT for the immediate form: only the destination's
        # prior value needs proving.
        return trace_type(irep, i, d, known_ivar_types, arg_types, mand, method_name, annotations, registry, integer_constants, fixnum_return_names)
      when 'GETIV'
        d = insn.args[/^R(\d+)/, 1]
        next unless d == reg

        other_ivar = insn.args[/@(\w+)/, 1]
        known = known_ivar_types[other_ivar]
        # EMBED_TYPE_SAFETY: a nilable (or unknown) source is not a concrete
        # scalar, so it never propagates a type to the copy (NILABLE_EMBED_SUPPORT).
        return known if EMBEDDABLE.include?(known)

        return UNKNOWN
      when 'SEND', 'SEND0', 'SSEND', 'SSEND0'
        d = insn.args[/^R(\d+)/, 1]
        next unless d == reg

        # FIXNUM_BINOP_EMBED_SUPPORT: %, &, |, ^ never promote to Bignum (like
        # compile_send's FIXNUM_BINARY fast path; +/-/* and << can overflow). Sound only
        # when both operands are proven Fixnum AND the operator has no override
        # anywhere (native_only_mono?).
        name = insn.args[/:([\w+\-*\/<>=!?\[\]&|^~%@]+)/, 1]
        n = insn.args[/n=(\d+)/, 1]
        if registry && %w[% & | ^].include?(name) && n == '1' && native_only_mono?(registry, name)
          arg_reg = (d.to_i + 1).to_s
          left = trace_type(irep, i, d, known_ivar_types, arg_types, mand, method_name, annotations, registry, integer_constants, fixnum_return_names)
          right = trace_type(irep, i, arg_reg, known_ivar_types, arg_types, mand, method_name, annotations, registry, integer_constants, fixnum_return_names)
          return :fixnum if left == :fixnum && right == :fixnum
        end

        # FIXNUM_RETURN_IVAR_HINT: a send of a name in FIXNUM_RETURN_PROOF's set
        # leaves a Fixnum in its destination for any receiver: that proof already
        # requires exactly one MethodDef, so the call either raises NoMethodError or
        # reaches that definition. No native_only_mono? re-check needed.
        # `fixnum_return_names` is nil for callers without a CodeGen (ArgTypes).
        return :fixnum if name && fixnum_return_names&.include?(name)

        return UNKNOWN
      when *READ_ONLY_OPCODE_SKIP
        # READ_ONLY_OPCODE_SKIP: these opcodes print a register as their first `R%d`
        # token but only READ it (mruby/ops.h: RETURN/RETURN_BLK "return R[a]", BREAK,
        # JMPIF/JMPNOT/JMPNIL "if R[a] ...", RAISEIF, MATCHERR, SETUPVAR
        # "uvset(b,c,R[a])"; codedump.c prints them that way). Skipping a non-writer is
        # as sound as skipping a MOVE to another register. Without this an early
        # `return v if v == @flag` stopped the trace for a later `@flag = v`.
        # SETUPVAR's `b`/`c` are slot/level numbers in an ancestor frame, not this
        # irep's registers, so its only `R` token is a same-frame read.
      when 'RESCUE'
        # RESCUE is `R[b] = R[a].isa?(R[b])` (ops.h), printed `RESCUE\tR%d\tR%d`: the
        # write lands on the SECOND register. `a` is a read; `b` is a real write and
        # must stop the trace like the generic `else`.
        a, b = insn.args.scan(/R(\d+)/).flatten
        return UNKNOWN if b == reg
        next unless a == reg
      else
        # Any other opcode's first operand is almost always its destination, so stop
        # at UNKNOWN. Skipping an unrecognized writer could reach an unrelated earlier
        # write to a reused register and misattribute its type.
        d = insn.args[/^R(\d+)/, 1]
        return UNKNOWN if d == reg
      end
    end
    # Never written in this block: an incoming argument. Register N is argument N
    # for N <= mand (as in CodeGen#compile_method). Use ArgTypes' whole-program
    # inference if it has one; otherwise the value is opaque.
    pos = reg.to_i
    if pos.between?(1, mand)
      # An annotation is per-definition (keyed by irep), so it is trusted whether
      # the name is MONO or POLY; tried first.
      # EMBED_TYPE_SAFETY: only :fixnum and :symbol pass. Other tokens (:array) have
      # no TYPE_OPS entry, and letting them through surfaced later as a KeyError in
      # GETIV/SETIV codegen of an unrelated owner.
      t = annotations && annotations[irep.label]&.args&.[](pos - 1)
      return t if t == :fixnum || t == :symbol

      t = arg_types && method_name && arg_types[method_name]&.[](pos - 1)
      return t if t
    end
    UNKNOWN
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
