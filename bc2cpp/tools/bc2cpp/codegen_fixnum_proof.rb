# frozen_string_literal: true

# CodeGen: FIXNUM_OPERAND_PROOF and entry-argument facts.

class CodeGen
  # ---------------------------------------------------------------------------
  # FIXNUM_OPERAND_PROOF: is THIS register provably a Fixnum at THIS point? When
  # both operands of ADD/ADDI/SUB/SUBI/MUL/DIV/EQ/LT/LE/GT/GE prove, compile_insn
  # emits only the native computation, with no mrb_funcall fallback.
  #
  # Proof sources (facts this file already relies on, not a general prover):
  #   1. A LOADI-family literal within the Fixnum range (see
  #      LOADI_FIXNUM_RANGE).
  #   2. A NATIVE_ARG_TARGETS :fixnum mandatory argument not reassigned since
  #      entry: the C++ parameter is an mrb_int (fixnum_proof_entry_arg?).
  #   3. A GETIV of an ivar embedded as :fixnum: an mrb_int struct field whose
  #      every write is guarded by mrb_integer_p.
  #   4. ADD/SUB/MUL/ADDI/SUBI whose operands prove (bounded by
  #      FIXNUM_PROOF_MAX_DEPTH): such an op is emitted as a bare
  #      mrb_fixnum_value(a <op> b). DIV is not a source: mrb_div_int_value's
  #      result type is not audited.
  #   5. GETCONST/GETMCNST of an IntegerConstants name.
  #   (6. FIXNUM_RETURN_PROOF and 7. ENTRY_ARG_CALLSITE_PROOF, below.)
  # MOVE chains are followed (`regs[a] = regs[b]`).
  #
  # The backward "most recent write" is only meaningful if control cannot enter
  # between the write and the use. Entry points, all honoured:
  #   - goto targets (jump_targets). REGION_DOMINANCE (fixnum_proof_region_ok?,
  #     with the edge map from fixnum_proof_edge_sources) lets the walk step
  #     past a label when every branch to it lies inside the write..use region.
  #     JOIN_REACHING_DEFS: when no single write dominates (`x = c ? 5 : 7`),
  #     fixnum_proof_reaching_defs? requires every reaching definition to prove.
  #   - exception handlers: each catch handler's target is an entry, and its
  #     whole begin_addr..end_addr range refuses outright, at the use and at
  #     every step. RESCUE_SUPPORT extracts that range into a separate function
  #     whose registers are re-initialized, yet compile_insn is called there
  #     with the enclosing irep, so the walk must not step back out of it.
  #   - nested blocks writing an enclosing local: SETUPVAR compiles to a write
  #     of r<b> (inlined bodies) or *bc2cpp_upvar_<b> (BLOCK_FALLBACK), outside
  #     this instruction list. Every SETUPVAR destination in the child subtree
  #     (any level) is refused.
  # Anything else declines and keeps the dual-path codegen.
  # ---------------------------------------------------------------------------

  # Opcodes the backward scan may STEP OVER: verified (ops.h, vm.c) to write at
  # most the register named by their first `R<n>` operand and to create no entry
  # point. Everything else ends the scan with a refusal, e.g. RESCUE (writes its
  # second operand), APOST (a range), ARGARY (a and a+1), ASET, SETUPVAR (an
  # enclosing frame), EXCEPT/RAISEIF/MATCHERR/JMPUW (exception edges), EXT*,
  # CALL, ERR, and any future opcode. A whitelist: an over-approximated write
  # only costs a proof, an under-approximated one is a wrong answer.
  FIXNUM_PROOF_STEP_OVER_OPS = Set[
    'NOP', 'MOVE', 'LOADL', 'LOADSYM', 'LOADNIL', 'LOADSELF', 'LOADTRUE', 'LOADFALSE',
    'GETGV', 'SETGV', 'GETSV', 'SETSV', 'GETIV', 'SETIV', 'GETCV', 'SETCV',
    'GETCONST', 'SETCONST', 'GETMCNST', 'SETMCNST', 'GETUPVAR',
    'GETIDX', 'GETIDX0', 'SETIDX',
    'JMP', 'JMPIF', 'JMPNOT', 'JMPNIL',
    'SSEND', 'SSEND0', 'SSENDB', 'SEND', 'SEND0', 'SENDB', 'SUPER', 'BLKCALL', 'BLKPUSH',
    'ENTER', 'KEY_P', 'KEYEND', 'KARG',
    'RETURN', 'RETURN_BLK', 'RETSELF', 'RETNIL', 'RETTRUE', 'RETFALSE', 'BREAK',
    'ADD', 'ADDI', 'SUB', 'SUBI', 'ADDILV', 'SUBILV', 'MUL', 'DIV',
    'EQ', 'LT', 'LE', 'GT', 'GE',
    'ARRAY', 'ARRAY2', 'ARYCAT', 'ARYPUSH', 'ARYSPLAT', 'AREF',
    'INTERN', 'SYMBOL', 'STRING', 'STRCAT', 'HASH', 'HASHADD', 'HASHCAT',
    'LAMBDA', 'BLOCK', 'METHOD', 'RANGE_INC', 'RANGE_EXC',
    'OCLASS', 'CLASS', 'MODULE', 'EXEC', 'DEF', 'TDEF', 'SDEF', 'ALIAS', 'UNDEF',
    'SCLASS', 'TCLASS', 'DEBUG', 'STOP'
  ].freeze

  # Members of FIXNUM_PROOF_STEP_OVER_OPS whose leading register is READ, not
  # written: ops.h gives JMPIF/JMPNOT/JMPNIL the BS format (register first), and
  # vm.c's handlers only test regs[a] (`if (mrb_test(regs[a])) { ci->pc += b;
  # ... }`). Treating them as writes was safe but stopped the walk at `a && 5`,
  # `a || 7`, `h&.size || 3`, where the condition register is the result. This
  # affects only the write test; they stay steppable and remain branch sources
  # for the dominance and reaching-definition machinery.
  FIXNUM_PROOF_READONLY_REG_OPS = Set['JMPIF', 'JMPNOT', 'JMPNIL'].freeze

  # Does `insn` write register `reg`? Shared by the single-path walk and the
  # JOIN_REACHING_DEFS worklist. For every whitelisted op except the three
  # read-only ones, the leading `R<n>` is the destination (the audited
  # property). Under-reporting a write would be a wrong answer, so this is an
  # explicit exception list, nothing inferred.
  def fixnum_proof_writes_reg?(insn, reg)
    return false if FIXNUM_PROOF_READONLY_REG_OPS.include?(insn.op)

    !(insn.args =~ /\AR#{reg}\b/).nil?
  end

  # Nested proven-arithmetic hops for source 4. `(a + b) * (c - d)` needs two;
  # unbounded recursion could go exponential on long chains.
  FIXNUM_PROOF_MAX_DEPTH = 4

  # Per-irep, memoized: entry addresses (goto targets and catch targets),
  # protected-range addresses, SETUPVAR destinations, and (REGION_DOMINANCE)
  # the branch-edge map and catch-target set.
  def fixnum_proof_ctx(irep)
    @fixnum_proof_ctx ||= {}
    return @fixnum_proof_ctx[irep.label] if @fixnum_proof_ctx.key?(irep.label)

    entries = jump_targets(irep).dup
    protected_addrs = Set.new
    catch_targets = Set.new
    (irep.catch_handlers || []).each do |ch|
      entries << ch.target
      catch_targets << ch.target
      protected_addrs.merge(ch.begin_addr..ch.end_addr)
    end
    edges = fixnum_proof_edge_sources(irep)
    entries.merge(edges.keys)
    @fixnum_proof_ctx[irep.label] =
      { entries: entries, protected: protected_addrs, upvars: subtree_upvar_written_regs(irep),
        edge_sources: edges, catch_targets: catch_targets }
  end

  # REGION_DOMINANCE: target address -> addresses branching to it. Exactly five
  # opcodes move pc within a frame (ops.h): JMP/JMPUW (S, target only) and
  # JMPIF/JMPNOT/JMPNIL (BS, register then target). OP_ENTER does not branch
  # (optional-argument dispatch is an ordinary JMP table after it).
  # RETURN/RETURN_BLK/BREAK/STOP leave the frame; RAISEIF/ERR/EXCEPT reach a
  # handler only through a catch entry, which has no source instruction, so
  # catch targets always refuse.
  # JMPUW is included although jump_targets omits it: the proof still runs in
  # such a body during a compiles_clean? probe, and an unmodelled edge is the
  # one miss this test cannot afford.
  def fixnum_proof_edge_sources(irep)
    edges = Hash.new { |h, k| h[k] = Set.new }
    irep.instructions.each do |insn|
      case insn.op
      when 'JMP', 'JMPUW'
        edges[insn.args.strip[/\d+/].to_i] << insn.addr
      when 'JMPIF', 'JMPNOT', 'JMPNIL'
        edges[jmp_target_after_reg(insn.args)] << insn.addr
      end
    end
    edges
  end

  # REGION_DOMINANCE: does the write at `w_idx` dominate the use at `u_idx`?
  # The region [w_idx, u_idx] is contiguous (the walk only steps back, and
  # addresses grow with index). The forward walk checked that nothing in
  # (w_idx, u_idx] writes the register, so a path reaching the use can only have
  # entered the region by falling into w_idx (the write ran) or by branching to
  # a label inside (w_idx, u_idx] (skipping it). So W dominates U iff every
  # source of every entry address inside the region lies within [lo, hi]. A
  # source below lo skips the write; a source above hi is a back-edge that could
  # bring a later write around to U.
  #
  #     x = 5          # W  -- LOADI_5
  #     if cond        #    -- JMPNOT ... L1
  #       ...
  #     end            # L1:
  #     y = x + 1      # U  -- ADD, operand x
  #
  # A loop wholly between W and U is admitted; a loop whose back-edge follows U
  # is refused. A catch target, or an entry with no recorded in-edge (an
  # unmodelled edge), refuses. `w_idx` -1 means "the method preamble wrote it":
  # the region is the whole body up to the use, and back-edges from below still
  # refuse.
  def fixnum_proof_region_ok?(irep, ctx, w_idx, u_idx)
    lo = irep.instructions[[w_idx, 0].max].addr
    hi = irep.instructions[u_idx].addr
    ((w_idx + 1)..u_idx).each do |k|
      addr = irep.instructions[k].addr
      next unless ctx[:entries].include?(addr)
      return false if ctx[:catch_targets].include?(addr)

      srcs = ctx[:edge_sources][addr]
      return false if srcs.nil? || srcs.empty?
      return false unless srcs.all? { |s| s >= lo && s <= hi }
    end
    true
  end

  # SETUPVAR destinations (operand B) anywhere in the child subtree. The level is
  # ignored: over-collecting only costs a proof.
  def subtree_upvar_written_regs(irep, acc = Set.new, seen = Set.new)
    (irep.reps || []).each do |label|
      next if seen.include?(label)

      seen << label
      child = @ireps[label]
      next unless child

      child.instructions.each do |insn|
        next unless insn.op == 'SETUPVAR'

        b = insn.args.split(/\s+/)[1]
        acc << b if b =~ /\A\d+\z/
      end
      subtree_upvar_written_regs(child, acc, seen)
    end
    acc
  end

  # FIXNUM_OPERAND_PROOF entry point (see the header). `reg` is a register
  # number string. true only for an exact proof; false means "not provable",
  # not "not a Fixnum".
  def proven_fixnum_operand?(irep, idx, reg, owner_def, depth = 0)
    return false unless irep && idx && reg && owner_def
    return false if depth > FIXNUM_PROOF_MAX_DEPTH

    ctx = fixnum_proof_ctx(irep)
    return false unless ctx

    cur = reg.to_s
    return false if ctx[:upvars].include?(cur)

    # JOIN_REACHING_DEFS: where `cur` is actually READ. It moves back to each MOVE
    # crossed, since `MOVE Ra Rb` reads Rb at its own address; asking at the
    # original use would ask about a register later code may overwrite.
    need_idx = idx
    j = idx
    while j >= 0
      insn = irep.instructions[j]
      return false unless insn
      # Inside a protected range: compiled into a separate function with
      # re-initialized registers, so neither using nor stepping here means anything.
      return false if ctx[:protected].include?(insn.addr)
      # An unaudited opcode could write `cur` from an operand this test does not
      # read: refuse.
      return false unless FIXNUM_PROOF_STEP_OVER_OPS.include?(insn.op) || insn.op.start_with?('LOADI')

      if j < idx && fixnum_proof_writes_reg?(insn, cur)
        if insn.op == 'MOVE'
          # `regs[a] = regs[b]`: continue with the source register.
          src = insn.args.scan(/R(\d+)/).flatten[1]
          return false unless src
          return false if ctx[:upvars].include?(src)

          cur = src
          need_idx = j
        else
          # REGION_DOMINANCE: the write is found; check nothing enters the region except
          # through it.
          if fixnum_proof_region_ok?(irep, ctx, j, idx)
            return fixnum_proof_source?(irep, j, insn, cur, owner_def, depth)
          end

          # JOIN_REACHING_DEFS: the write does not dominate, so ask the multi-path
          # question: every reaching definition must prove.
          return fixnum_proof_reaching_defs?(irep, ctx, need_idx, cur, owner_def, depth)
        end
      end

      j -= 1
    end

    # Fell off the top: `cur` holds the preamble's value. REGION_DOMINANCE with -1
    # still rejects a back-edge from below the use.
    unless fixnum_proof_region_ok?(irep, ctx, -1, idx)
      return fixnum_proof_reaching_defs?(irep, ctx, need_idx, cur, owner_def, depth)
    end

    fixnum_proof_entry_arg?(irep, cur, owner_def)
  end

  # JOIN_REACHING_DEFS -------------------------------------------------------
  # Cap on (index, register) states the multi-path walk expands. Refusing on
  # exhaustion is safe and keeps codegen linear.
  FIXNUM_PROOF_REACHING_MAX_STATES = 400

  # Predecessor map: index -> indices control can come from (-1 = method entry).
  # An extra predecessor only costs a proof; a missing one is a wrong answer. So
  # fall-through is assumed for every opcode except those that never fall
  # through (JMP/JMPUW; RETURN/RETURN_BLK/RETSELF/RETNIL/RETTRUE/RETFALSE/BREAK/
  # STOP), and branch edges are the five JMP* opcodes. A jump to an address with
  # no instruction makes the whole map nil, so every query refuses.
  FIXNUM_PROOF_NO_FALLTHROUGH_OPS = Set[
    'JMP', 'JMPUW',
    'RETURN', 'RETURN_BLK', 'RETSELF', 'RETNIL', 'RETTRUE', 'RETFALSE', 'BREAK', 'STOP'
  ].freeze

  def fixnum_proof_preds(irep)
    @fixnum_proof_preds ||= {}
    return @fixnum_proof_preds[irep.label] if @fixnum_proof_preds.key?(irep.label)

    @fixnum_proof_preds[irep.label] = build_fixnum_proof_preds(irep)
  end

  def build_fixnum_proof_preds(irep)
    insns = irep.instructions
    addr_to_idx = {}
    insns.each_with_index { |ins, k| addr_to_idx[ins.addr] = k }
    preds = Hash.new { |h, k| h[k] = Set.new }
    preds[0] << -1
    insns.each_with_index do |ins, k|
      unless FIXNUM_PROOF_NO_FALLTHROUGH_OPS.include?(ins.op)
        preds[k + 1] << k if k + 1 < insns.size
      end
      t =
        case ins.op
        when 'JMP', 'JMPUW' then ins.args.strip[/\d+/].to_i
        when 'JMPIF', 'JMPNOT', 'JMPNIL' then jmp_target_after_reg(ins.args)
        end
      next if t.nil?

      ti = addr_to_idx[t]
      return nil if ti.nil?

      preds[ti] << k
    end
    preds
  end

  # JOIN_REACHING_DEFS: does EVERY definition of `reg` reaching the read at
  # `need_idx` prove Fixnum? Handles joins no single write dominates, e.g.
  # `x = c ? 5 : 7; x + 1`:
  #
  #     007 JMPNOT  R4  016
  #     011 LOADI_5 R4  (5)
  #     013 JMP     018
  #     016 LOADI_7 R4  (7)
  #     018 MOVE    R3  R4        <- the join
  #
  # A backward worklist of (index, register) states meaning "the value flowing
  # into index i must be a Fixnum". For each predecessor p: if p writes r it is
  # a reaching definition (MOVE continues with the source register, anything
  # else must satisfy fixnum_proof_source?); otherwise ask (p, r). Method entry
  # uses the entry-argument test.
  # Each state is expanded once and true is only returned once the worklist is
  # empty, so re-reaching a state over a loop back-edge is memoization, not an
  # optimistic assumption. The single-path barriers all apply: protected ranges,
  # catch targets, unaudited opcodes, SETUPVAR destinations.
  def fixnum_proof_reaching_defs?(irep, ctx, need_idx, reg, owner_def, depth)
    return false if depth > FIXNUM_PROOF_MAX_DEPTH

    preds = fixnum_proof_preds(irep)
    return false if preds.nil?

    seen = Set.new
    work = [[need_idx, reg.to_s]]
    until work.empty?
      state = work.pop
      next if seen.include?(state)

      seen << state
      return false if seen.size > FIXNUM_PROOF_REACHING_MAX_STATES

      i, r = state
      return false if ctx[:upvars].include?(r)

      here = irep.instructions[i]
      return false unless here
      return false if ctx[:catch_targets].include?(here.addr)
      return false if ctx[:protected].include?(here.addr)

      ps = preds[i]
      return false if ps.nil? || ps.empty?

      ps.each do |p|
        if p < 0
          # Method entry: the preamble's value; use the entry-argument proof.
          return false unless fixnum_proof_entry_arg?(irep, r, owner_def)

          next
        end

        insn = irep.instructions[p]
        return false unless insn
        return false if ctx[:protected].include?(insn.addr)
        return false unless FIXNUM_PROOF_STEP_OVER_OPS.include?(insn.op) || insn.op.start_with?('LOADI')

        if fixnum_proof_writes_reg?(insn, r)
          if insn.op == 'MOVE'
            src = insn.args.scan(/R(\d+)/).flatten[1]
            return false unless src
            return false if ctx[:upvars].include?(src)

            work << [p, src]
          else
            return false unless fixnum_proof_source?(irep, p, insn, r, owner_def, depth)
          end
        else
          work << [p, r]
        end
      end
    end

    true
  end

  # LOADI_FIXNUM_RANGE: the narrowest Fixnum range of any shipped target (the
  # proof runs once, in the host diagnostic). mrb_int is 32-bit on
  # Emscripten/Wio/PSP and word boxing (no build uses nan boxing) tags one bit:
  # MRB_FIXNUM_MIN/MAX = (INT32_MIN>>1)..(INT32_MAX>>1) (mruby/boxing_word.h,
  # TYPED_FIXABLE in mruby/numeric.h).
  # Every LOADI form but LOADI32 runs SET_FIXNUM_VALUE (vm.c). LOADI32 runs
  # SET_INT_VALUE -> mrb_boxing_int_value (src/etc.c), which returns a heap
  # Integer for non-FIXABLE literals (`z = 2000000000` emits LOADI32), and the
  # proof's codegen would apply a bare mrb_fixnum() to it: silent UB. Hence the
  # range check.
  LOADI_FIXNUM_MIN = -1_073_741_824
  LOADI_FIXNUM_MAX = 1_073_741_823

  # A LOADI* literal, or nil: the second whitespace-separated token
  # (`LOADI32\tR1\t9999999\t; R1:x`). LOADINEG prints the negated value.
  def loadi_literal(insn)
    tok = insn.args.split(/\s+/)[1]
    tok && tok.match?(/\A-?\d+\z/) ? tok.to_i : nil
  end

  def loadi_proven_fixnum?(insn)
    # LOADI8/LOADI16/LOADINEG/LOADI_n stay within +-2^15, FIXABLE everywhere. Only
    # LOADI32 needs the bound check.
    return true unless insn.op == 'LOADI32'

    lit = loadi_literal(insn)
    !lit.nil? && lit >= LOADI_FIXNUM_MIN && lit <= LOADI_FIXNUM_MAX
  end

  # Classify the instruction found writing `reg` (MOVE is handled by the caller).
  def fixnum_proof_source?(irep, j, insn, reg, owner_def, depth)
    return loadi_proven_fixnum?(insn) if insn.op.start_with?('LOADI')

    case insn.op
    when 'GETIV'
      ivar = insn.args[/@(\w+)/, 1]
      !ivar.nil? && embed_type(owner_def.owner, ivar) == :fixnum
    when 'ADD', 'SUB', 'MUL'
      s = insn.args[/\(R(\d+)\)/, 1]
      !s.nil? && proven_fixnum_operand?(irep, j, reg, owner_def, depth + 1) &&
        proven_fixnum_operand?(irep, j, s, owner_def, depth + 1)
    when 'ADDI', 'SUBI'
      proven_fixnum_operand?(irep, j, reg, owner_def, depth + 1)
    when 'GETCONST'
      # "GETCONST R4 WEAPON_SLOT": register first, bare name second
      # (`"GETCONST\tR%d\t%s"`); a trailing print_lv_a comment follows the name.
      @integer_constants.include?(insn.args.split(/\s+/)[1])
    when 'GETMCNST'
      # "GETMCNST R4 (R4)::DEPTH": only the bare name after `::`, as IntegerConstants
      # keys on (the scope register is not modelled).
      @integer_constants.include?(insn.args[/::(\S+)/, 1])
    when 'SEND', 'SEND0', 'SSEND', 'SSEND0'
      # FIXNUM_RETURN_PROOF (source 6): see compute_fixnum_return_names. SENDB/SSENDB
      # are excluded: a `break` in the caller's block becomes the send's result.
      nm = insn.args[/:([\w+\-*\/<>=!?\[\]&|^~%@]+)/, 1]
      !nm.nil? && @fixnum_return_names.include?(nm)
    else
      false
    end
  end

  # Proof source 2: a mandatory argument register of THIS method's own irep whose
  # NATIVE_ARG_TARGETS parameter is mrb_int (boxed by the preamble).
  # `owner_def.irep == irep.label` is load-bearing: compile_insn also runs on a
  # BLOCK_FALLBACK child irep with the enclosing method's owner_def, and there
  # r1.. are block parameters. pure_mandatory_arity? likewise: with optionals the
  # registers no longer map 1:1 onto native_arg_types.
  def fixnum_proof_entry_arg?(irep, reg, owner_def)
    return false unless owner_def.irep == irep.label
    return false unless pure_mandatory_arity?(irep)

    enter = irep.instructions.find { |i| i.op == 'ENTER' }
    mand = enter ? enter.args.split(':').first.to_i : 0
    r = reg.to_i
    return false unless r >= 1 && r <= mand

    return true if native_arg_types(owner_def, mand)[r - 1] == :fixnum

    # ENTRY_ARG_CALLSITE_PROOF (source 7): every call site passes a Fixnum here
    # (compute_entry_arg_fixnum). nil until that fixpoint runs.
    !@entry_arg_fixnum.nil? && @entry_arg_fixnum.include?([irep.label, r])
  end

  # ---------------------------------------------------------------------------
  # ENTRY_ARG_CALLSITE_PROOF (proof source 7): a mandatory argument register
  # holds a Fixnum on entry because EVERY call site that can reach the method
  # passes a proven Fixnum there (unlike source 2, which is the hand-vetted
  # NATIVE_ARG_TARGETS retyping).
  #
  # The enumeration must be exhaustive: a wrong operand proof emits an unchecked
  # mrb_fixnum(), i.e. silent UB. Why it can be:
  #   - No Ruby runs that the compiler cannot see: mrb_load_string/file/irep/
  #     nstring are not called by mruby-rgss/rpg2k/lcf native code, so all Ruby
  #     is closed-world mrblib (parsed here) or foreign mrblib (poisoned).
  #   - The closed world has no send/__send__/public_send/method(:x)/
  #     define_method/*_eval; alias_method and `&:sym` materialize as LOADSYM,
  #     which poisons anyway.
  # So a call into M under name N can only be:
  #   (a) a bytecode SEND-family instruction naming `:N` -- enumerated;
  #   (b) symbol-mediated dispatch -- `:N` in a non-call opcode poisons N;
  #   (c) native C++ or foreign mrblib -- poisons N if the token appears in
  #       NATIVE_SRCS or FOREIGN_RUBY_SRCS at all (outside_world_tokens);
  #   (d) `super` into M -- impossible, N must be MONO (native definitions add a
  #       second registry entry);
  #   (e) `X.new` reaching #initialize -- no SEND :initialize exists, so
  #       `initialize` is refused by name and at least one real site is
  #       required;
  #   (f) method_missing -- only fires when no method is found.
  # The opcodes that can carry a `:name` operand were inventoried:
  # SEND/SEND0/SENDB/SSEND/SSEND0/SSENDB, DEF/SDEF/TDEF, LOADSYM, KARG/KEY_P,
  # CLASS/MODULE, and ARGARY/BLKPUSH/ENTER/GETMCNST (numeric fields or `::`).
  # Only the four positional call opcodes are sites; the rest poison. Any other
  # opcode naming something raises (ENTRY_ARG_CLASSIFIED_OPS), fail-loud.
  #
  # ADMISSION: (method M named N, argument position k) is admitted only when:
  #   1. @registry[N] has exactly one MethodDef, with a bytecode body.
  #   2. N is not in foreign_method_names.
  #   3. N is not in outside_tokens.
  #   4. N starts with a letter or underscore (operator names cannot be
  #      tokenized for rule 3).
  #   5. N is not `initialize`.
  #   6. pure_mandatory_arity? on M, and 1 <= k <= mand.
  #   7. N is not poisoned: no LOADSYM :N, no other DEF/SDEF/TDEF :N, no
  #      SEND0/SSEND0 :N (a zero-argument call to a mand >= 1 method means this
  #      model is wrong), no `:N` in any other opcode.
  #   8. At least one site exists, and every site is SEND/SENDB/SSEND/SSENDB
  #      with a literal `n=` equal to mand (`n=*` refuses), in an irep
  #      attributable to a known method body.
  #   9. At every site, argument k's register R[a+k] (OP_SEND's
  #      regs[a+1..a+n]) is proven_fixnum_operand?.
  #
  # Greatest fixpoint: start from every (M, k) passing 1-8 and drop pairs whose
  # sites stop proving. This admits recursion (`def f(n); n <= 0 ? 0 : f(n -
  # 1); end`). Soundness is by induction over the events of one real run in
  # time order ("invocation of M begins" / "invocation of P returns"): an entry
  # event's argument was proven from unconditional sources, from the caller's
  # own entry arguments (an earlier event), or from a FIXNUM_RETURN_PROOF'd
  # call's return (an earlier event); a return event likewise. So this proof and
  # FIXNUM_RETURN_PROOF can alternate to convergence, each trusting the other's
  # current set. A non-terminating cycle produces no events (it raises
  # SystemStackError), so it is vacuous.
  #
  # Not done on purpose:
  #   - Block parameters: filled by whatever the callee yields (each, times, a
  #     native mrb_yield), a different enumeration problem.
  #   - Trusting `# bc2cpp: (fixnum, ...)` alone: other consumers re-check at
  #     runtime (mrb_integer_p guards, the NATIVE_ARG_TARGETS FFI TypeError);
  #     this proof has no check by design, so a wrong comment would be silent
  #     UB. Use NATIVE_ARG_TARGETS after its per-entry review instead.
  # ---------------------------------------------------------------------------

  # Bound on the ENTRY_ARG_CALLSITE_PROOF <-> FIXNUM_RETURN_PROOF alternation.
  # Both sets grow monotonically; stopping early only proves less.
  ENTRY_ARG_ALTERNATION_LIMIT = 4

  # Call opcodes an enumerable site may use. SEND0/SSEND0 pass no arguments, so
  # one aimed at a mand >= 1 method means the model is wrong; they poison.
  ENTRY_ARG_CALL_OPS = Set['SEND', 'SENDB', 'SSEND', 'SSENDB'].freeze

  # Opcodes that DEFINE a method (`DEF R1 :name (R2)`, SDEF, TDEF). Neutral, not
  # poison: a definition is not a call path, and a second definition already
  # fails rule 1. Treating them as poison would make every method poison itself.
  ENTRY_ARG_DEF_OPS = Set['DEF', 'SDEF', 'TDEF'].freeze

  # Every opcode verified (from the real instruction stream) to carry a `:token`
  # operand. Any other one that does raises.
  ENTRY_ARG_CLASSIFIED_OPS = Set[
    'SEND', 'SEND0', 'SENDB', 'SSEND', 'SSEND0', 'SSENDB',
    'DEF', 'SDEF', 'TDEF', 'LOADSYM', 'KARG', 'KEY_P', 'CLASS', 'MODULE',
    'ARGARY', 'BLKPUSH', 'ENTER', 'GETMCNST'
  ].freeze

  # Same method-name charset as every SEND-name extraction.
  ENTRY_ARG_NAME_RE = %r{:([\w+\-*/<>=!?\[\]&|^~%@]+)}

  # codedump.c appends "\t; R<n>:<local>" (or "\t; <literal>") comments; a local
  # named `tile` must not count as the method `tile`. Operands end at the first
  # "\t;".
  def entry_arg_operands(insn)
    insn.args.to_s.split(/\t;/, 2).first.to_s
  end

  # irep label -> the MethodDef whose body it is, following `reps` into nested
  # blocks/lambdas (a call site in a block is proven against the enclosing
  # method, as compile_insn does for BLOCK_FALLBACK). An uncovered label (root,
  # class body) poisons its call sites.
  def entry_arg_body_owner
    @entry_arg_body_owner ||= begin
      map = {}
      @registry.each_value do |defs|
        defs.each do |d|
          next unless d.irep

          stack = [d.irep]
          until stack.empty?
            label = stack.pop
            next if map.key?(label)

            map[label] = d
            child = @ireps[label]
            (child&.reps || []).each { |c| stack << c }
          end
        end
      end
      map
    end
  end

  # One pass over every irep, splitting each `:name` mention into a call site or
  # a poison. Memoized (@ireps/@registry are fixed).
  def entry_arg_call_index
    @entry_arg_call_index ||= begin
      sites = Hash.new { |h, k| h[k] = [] }
      poisoned = Set.new
      owner_of_body = entry_arg_body_owner
      @ireps.each_value do |irep|
        owner = owner_of_body[irep.label]
        irep.instructions.each_with_index do |insn, i|
          operands = entry_arg_operands(insn)
          name = operands[ENTRY_ARG_NAME_RE, 1]
          next unless name

          unless ENTRY_ARG_CLASSIFIED_OPS.include?(insn.op)
            raise "ENTRY_ARG_CALLSITE_PROOF: opcode #{insn.op} names :#{name} " \
                  "(#{operands.inspect}) but is not classified -- refusing to " \
                  'guess whether that is a call site'
          end

          # A def naming itself is neither a site nor poison (ENTRY_ARG_DEF_OPS).
          next if ENTRY_ARG_DEF_OPS.include?(insn.op)

          unless ENTRY_ARG_CALL_OPS.include?(insn.op) && owner
            poisoned << name
            next
          end

          recv = operands[/\AR(\d+)/, 1]
          argc = operands[/\bn=(\d+)\b/, 1]
          # `n=*` (packed arguments): argument k has no register, so it poisons.
          if recv.nil? || argc.nil?
            poisoned << name
            next
          end

          sites[name] << [irep, i, recv.to_i, argc.to_i, owner]
        end
      end
      [sites, poisoned]
    end
  end

  # ENTRY_ARG_CALLSITE_PROOF greatest fixpoint (see the header). Returns a Set
  # of [irep label, mandatory argument register].
  def compute_entry_arg_fixnum
    @entry_arg_fixnum = Set.new
    # A missing scan is a missing poison source: prove nothing.
    return @entry_arg_fixnum unless @foreign_method_names && @outside_tokens

    sites, poisoned = entry_arg_call_index
    cand = {}
    @registry.each do |name, defs|
      next unless defs.size == 1                       # rule 1
      next if @foreign_method_names.include?(name)     # rule 2
      next if @outside_tokens.include?(name)           # rule 3
      next unless name =~ /\A[A-Za-z_]/                # rule 4
      next if name == 'initialize'                     # rule 5
      next if poisoned.include?(name)                  # rule 7

      d = defs.first
      next unless d.irep

      irep = @ireps[d.irep]
      next unless irep && pure_mandatory_arity?(irep)  # rule 6

      mand = mandatory_arity(irep)
      next if mand.zero?

      here = sites[name]
      next if here.empty?                              # rule 8
      next unless here.all? { |(_ir, _i, _a, argc, _own)| argc == mand }

      (1..mand).each { |k| cand[[d.irep, k]] = [here, k] }
    end

    @entry_arg_fixnum = Set.new(cand.keys)
    loop do
      dropped = cand.keys.select do |key|
        @entry_arg_fixnum.include?(key) && !entry_arg_sites_proven?(*cand[key])
      end
      break if dropped.empty?

      dropped.each { |key| @entry_arg_fixnum.delete(key) }
    end
    @entry_arg_fixnum
  end

  # Admission rule 9: R[a+k] at every site proves (OP_SEND regs[a+1..a+n]).
  def entry_arg_sites_proven?(sites, k)
    sites.all? do |(irep, idx, recv, _argc, owner)|
      proven_fixnum_operand?(irep, idx, (recv + k).to_s, owner)
    end
  end

  # ENTRY_ARG_CALLSITE_PROOF's own result, for the whole-program diagnostic.
  def entry_arg_fixnum_facts
    @entry_arg_fixnum || Set.new
  end
end
