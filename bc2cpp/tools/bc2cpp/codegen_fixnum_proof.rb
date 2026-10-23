# frozen_string_literal: true

require_relative 'bytecode_ir_containers'

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
  #   4. (retired: an ADD/SUB/MUL/ADDI/SUBI result can leave the Fixnum range,
  #      so it is an Integer -- see NumericFlow -- not a proven Fixnum.)
  #   5. GETCONST/GETMCNST of an IntegerConstants name.
  #   (6. FIXNUM_RETURN_PROOF and 7. ENTRY_ARG_CALLSITE_PROOF, below.)
  # MOVE chains are followed (`regs[a] = regs[b]`).
  #
  # The proof asks BytecodeIR's reaching definitions: the SET of
  # writes that can supply the register at the use, through joins and loops,
  # over the normal-flow CFG. Every one must prove. Entry points, all honoured:
  #   - goto targets: the CFG's predecessor lists (a join contributes each arm's
  #     write, `x = c ? 5 : 7` proves when both literals do). A predecessor no
  #     execution reaches supplies nothing; an unplain JMPUW refuses.
  #   - exception handlers: each catch handler's target and its whole protected
  #     range (end included) refuse outright, at the use and at every step.
  #     RESCUE_SUPPORT extracts that range into a separate function whose
  #     registers are re-initialized, yet compile_insn is called there with the
  #     enclosing irep, so the walk must not step back out of it.
  #   - nested blocks writing an enclosing local: SETUPVAR compiles to a write
  #     of r<b> (inlined bodies) or *bc2cpp_upvar_<b> (BLOCK_FALLBACK), outside
  #     this instruction list. A register some nested block's SETUPVAR reaches
  #     at its level is refused (BytecodeIR.own_upvar_written_regs, opaque_regs).
  #   - a callee frame or a vm.c fallback send based below the register may
  #     overwrite it: refused (BytecodeIR::Ops::CALLEE_FRAME, ORIGIN_FRAME_OPS).
  # Anything else declines and keeps the dual-path codegen. The single-path
  # walks (fixnum_interval, guarded_game_integer_range) ask
  # BytecodeIR.write_dominates? per hop, as return_write_dominates? does.
  # ---------------------------------------------------------------------------

  # Opcodes a backward scan may STEP OVER: verified (ops.h, vm.c) to write at
  # most the register named by their first `R<n>` operand and to create no entry
  # point. Everything else ends the scan with a refusal, e.g. RESCUE (writes its
  # second operand), APOST (a range), ARGARY (a and a+1), ASET, SETUPVAR (an
  # enclosing frame), EXCEPT/RAISEIF/MATCHERR/JMPUW (exception edges), EXT*,
  # CALL, ERR, and any future opcode. A whitelist: an over-approximated write
  # only costs a proof, an under-approximated one is a wrong answer. It is
  # BytecodeIR's audited list itself, not a copy kept equal to it.
  FIXNUM_PROOF_STEP_OVER_OPS = BytecodeIR::WRITES_LEADING_REG_OPS

  # Members of FIXNUM_PROOF_STEP_OVER_OPS whose leading register is READ, not
  # written: ops.h gives JMPIF/JMPNOT/JMPNIL the BS format (register first), and
  # vm.c's handlers only test regs[a] (`if (mrb_test(regs[a])) { ci->pc += b;
  # ... }`). Treating them as writes was safe but stopped the walk at `a && 5`,
  # `a || 7`, `h&.size || 3`, where the condition register is the result. This
  # affects only the write test; they stay steppable and remain branch sources
  # for the dominance and reaching-definition machinery.
  # They are exactly the steppable members of BytecodeIR::Ops::READS_LEAD.
  FIXNUM_PROOF_READONLY_REG_OPS = (BytecodeIR::Ops::READS_LEAD & FIXNUM_PROOF_STEP_OVER_OPS).freeze

  # Nested proven-arithmetic hops for source 4. `(a + b) * (c - d)` needs two;
  # unbounded recursion could go exponential on long chains.
  FIXNUM_PROOF_MAX_DEPTH = 4

  # Per-irep, memoized: protected-range addresses, catch targets and the
  # registers a nested block writes (BytecodeIR.own_upvar_written_regs).
  def fixnum_proof_ctx(irep)
    @fixnum_proof_ctx ||= {}
    return @fixnum_proof_ctx[irep.label] if @fixnum_proof_ctx.key?(irep.label)

    program = BytecodeIR.for(irep)
    # Inclusive end: the instruction after a range is refused too, which is
    # more than the VM's half-open range needs.
    @fixnum_proof_ctx[irep.label] =
      { protected: program.handler_protected_addrs(inclusive_end: true),
        upvars: BytecodeIR.own_upvar_written_regs(irep), catch_targets: program.handler_target_addrs }
  end

  # FIXNUM_OPERAND_PROOF entry point (see the header). `reg` is a register
  # number string. true only for an exact proof; false means "not provable",
  # not "not a Fixnum".
  #
  # JOIN_REACHING_DEFS: every definition of `reg` reaching the read
  # at `idx` must prove, through joins and loops (BytecodeIR's
  # reaching_definitions, which follows MOVE chains). Its barriers are this
  # proof's: an op outside the audited write list, a catch target or protected
  # instruction (the inclusive range end included) on the way, a register a
  # nested block writes (own_upvar_written_regs, opaque_regs), a callee frame
  # or vm.c fallback that may overwrite the register, and the state cap. A
  # write that dominates the read is the one-definition case, so the old
  # single-path walk and its REGION_DOMINANCE test are subsumed.
  def proven_fixnum_operand?(irep, idx, reg, owner_def, depth = 0)
    return false unless irep && idx && reg && owner_def
    return false if depth > FIXNUM_PROOF_MAX_DEPTH

    ctx = fixnum_proof_ctx(irep)
    return false unless ctx

    cur = reg.to_s
    return false if ctx[:upvars].include?(cur)

    # The use itself must be an audited op outside a protected range: that range
    # compiles into a separate function with re-initialized registers.
    use_insn = idx >= 0 && BytecodeIR.for(irep).source_at(idx)
    return false unless use_insn
    return false if ctx[:protected].include?(use_insn.addr) ||
                    !(FIXNUM_PROOF_STEP_OVER_OPS.include?(use_insn.op) || use_insn.op.start_with?('LOADI'))

    BytecodeIR.for(irep).every_reaching_definition(idx, cur, opaque_regs: ctx[:upvars],
                                                        max_states: fixnum_proof_max_states(irep)) do |definition|
      if definition.entry?
        fixnum_proof_entry_arg?(irep, definition.reg, owner_def)
      else
        fixnum_proof_source?(irep, definition.index, BytecodeIR.for(irep).source_at(definition.index), definition.reg, owner_def,
                             depth)
      end
    end || false
  end

  # The single-path walk this proof used to run first was unbounded (one step
  # per instruction); the cap grows with the body so a long straight-line
  # method keeps its proofs, and stays linear in it.
  def fixnum_proof_max_states(irep)
    [BytecodeIR::DATAFLOW_MAX_STATES, 2 * BytecodeIR.for(irep).size].max
  end

  # Predecessor map: index -> indices control can come from (-1 = method entry),
  # nil when a jump targets a non-instruction so every query refuses. Extra
  # predecessors only cost a proof; see BytecodeIR::NO_FALLTHROUGH.
  def fixnum_proof_preds(irep)
    BytecodeIR.for(irep).instruction_predecessors
  end

  # LOADI_FIXNUM_RANGE: the narrowest Fixnum range of any shipped target (the
  # proof runs once, in the host diagnostic). mrb_int is 32-bit on
  # Emscripten and word boxing (no build uses nan boxing) tags one bit:
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
    BytecodeIR::OperandModel.imm_operand(insn)&.to_i
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
      ivar = insn.ivar
      !ivar.nil? && embed_type(owner_def.owner, ivar) == :fixnum
    when 'GETCONST'
      # "GETCONST R4 WEAPON_SLOT": register first, bare name second
      # (`"GETCONST\tR%d\t%s"`); a trailing print_lv_a comment follows the name.
      !@fixnum_proof_skip_constants &&
        (@integer_constants.include?(insn.const_name) || fixnum_interval_const?(insn.const_name))
    when 'GETMCNST'
      # "GETMCNST R4 (R4)::DEPTH": only the bare name after `::`, as IntegerConstants
      # keys on (the scope register is not modelled).
      !@fixnum_proof_skip_constants &&
        (@integer_constants.include?(insn.mcnst_name) || fixnum_interval_const?(insn.mcnst_name))
    when *FIXNUM_INTERVAL_OPS
      # NUMERIC_INTERVAL_OPERANDS: `HEADER_H * 3 + 2` is a Fixnum when its interval fits.
      !@fixnum_proof_skip_constants && numeric_intervals_on? &&
        !fixnum_interval_source(irep, j, insn, reg, owner_def, 0, nil).nil?
    when 'GETIDX', 'GETIDX0'
      # SEALED_INT16 (sealed_int16_locals.rb): an in-range read of a proven int16 array is a Fixnum (its interval
      # is the int16 hull of the array's stored values).
      numeric_intervals_on? && !sealed_element_range(irep, j).nil?
    when 'SEND', 'SEND0', 'SSEND', 'SSEND0'
      # FIXNUM_RETURN_PROOF (source 6): see compute_fixnum_return_names. SENDB/SSENDB
      # are excluded: a `break` in the caller's block becomes the send's result.
      nm = insn.sym
      !nm.nil? && (@fixnum_return_names.include?(nm) || native_fixnum_result?(irep, j, insn))
    else
      false
    end
  end

  # GUARDED_GAME_VARIABLE_RANGE: derive an interval from literals, Game::Variables
  # reads, and integer arithmetic. Consumers guard actual mrb_values before
  # unboxing because replace/to_h can bypass Variables#[]=.
  GAME_VARIABLE_RANGE_MIN = -9_999_999
  GAME_VARIABLE_RANGE_MAX = 9_999_999

  def guarded_game_integer_range(irep, idx, reg, owner_def, depth = 0)
    return nil unless irep && idx && reg && owner_def
    return nil if depth > FIXNUM_PROOF_MAX_DEPTH

    # An unaudited opcode or one inside a protected range refuses (see
    # FIXNUM_PROOF_STEP_OVER_OPS).
    unaudited = lambda do |insn, _cur|
      !(FIXNUM_PROOF_STEP_OVER_OPS.include?(insn.op) || insn.op.start_with?('LOADI')) ||
        fixnum_proof_ctx(irep)[:protected].include?(insn.addr)
    end
    irep.walk_dominating_writers(idx - 1, reg.to_s, use: idx, skip_ops: FIXNUM_PROOF_READONLY_REG_OPS,
                                                    barrier: unaudited, follow_moves: true) do |insn, j, cur|
      case insn.op
      when /^LOADI/
        value = loadi_literal(insn)
        next [value, value] if value && value.between?(LOADI_FIXNUM_MIN, LOADI_FIXNUM_MAX)

        next nil
      when 'GETIDX', 'GETIDX0', 'SEND', 'SEND0'
        name = insn.sym
        next nil if %w[SEND SEND0].include?(insn.op) && name != '[]'
        recv = if insn.op == 'GETIDX'
                 cur
               else
                 insn.regs[1]
               end
        next nil unless recv && game_variables_index_receiver?(irep, j, recv, owner_def)

        next [GAME_VARIABLE_RANGE_MIN, GAME_VARIABLE_RANGE_MAX]
      when 'ADD', 'SUB', 'MUL'
        regs = insn.regs
        next nil unless regs.size >= 2
        left = guarded_game_integer_range(irep, j, regs[0], owner_def, depth + 1)
        right = guarded_game_integer_range(irep, j, regs[1], owner_def, depth + 1)
        next nil unless left && right

        next guarded_integer_binary_range(insn.op, left, right) ||
          (insn.op == 'MUL' ? [LOADI_FIXNUM_MIN, LOADI_FIXNUM_MAX] : nil)
      when 'ADDI', 'SUBI'
        literal = BytecodeIR::OperandModel.imm_operand(insn).to_i
        left = guarded_game_integer_range(irep, j, cur, owner_def, depth + 1)
        next nil unless left

        next guarded_integer_binary_range(insn.op == 'ADDI' ? 'ADD' : 'SUB', left, [literal, literal])
      when 'DIV'
        regs = insn.regs
        next nil unless regs.size >= 2
        left = guarded_game_integer_range(irep, j, regs[0], owner_def, depth + 1)
        right = guarded_game_integer_range(irep, j, regs[1], owner_def, depth + 1)
        next nil unless left && right

        bound = [left[0].abs, left[1].abs].max
        next nil if -bound < LOADI_FIXNUM_MIN || bound > LOADI_FIXNUM_MAX

        next [-bound, bound]
      else
        IrepScans::KEEP
      end
    end
  end

  def game_variables_index_receiver?(irep, idx, reg, owner_def)
    return true if static_indexable_class(irep, idx, reg, owner_def) == 'Game::Variables'
    return false unless owner_def.owner == 'Game::Variables'

    # Every value reaching the read must be self: a join with any other writer, or the frame entry, refuses.
    defs = BytecodeIR.reaching_definitions(irep, idx, reg.to_s)
    return false if defs.nil? || defs.empty? || defs.any?(&:entry?)

    program = BytecodeIR.for(irep)
    defs.all? { |d| program.source_at(d.index).op == 'LOADSELF' }
  end

  def guarded_integer_binary_range(op, left, right)
    values = case op
             when 'ADD' then [left[0] + right[0], left[1] + right[1]]
             when 'SUB' then [left[0] - right[1], left[1] - right[0]]
             when 'MUL'
               products = [left[0] * right[0], left[0] * right[1], left[1] * right[0], left[1] * right[1]]
               [products.min, products.max]
             end
    return nil unless values && values[0] >= LOADI_FIXNUM_MIN && values[1] <= LOADI_FIXNUM_MAX

    values
  end

  def guarded_game_integer_pair(op, irep, idx, left_reg, right_reg, owner_def)
    left = guarded_game_integer_range(irep, idx, left_reg, owner_def)
    right = guarded_game_integer_range(irep, idx, right_reg, owner_def)
    return nil unless left && right

    result = if op == 'DIV'
               bound = [left[0].abs, left[1].abs].max
               [-bound, bound]
             else
               guarded_integer_binary_range(op, left, right)
             end
    result = [LOADI_FIXNUM_MIN, LOADI_FIXNUM_MAX] if result.nil? && op == 'MUL'
    return nil unless result
    return nil unless result[0] >= LOADI_FIXNUM_MIN && result[1] <= LOADI_FIXNUM_MAX

    range_guard = lambda do |reg, range|
      "mrb_fixnum_p(r#{reg}) && mrb_fixnum(r#{reg}) >= #{range[0]} && " \
        "mrb_fixnum(r#{reg}) <= #{range[1]}"
    end
    condition = "(#{range_guard.call(left_reg, left)}) && (#{range_guard.call(right_reg, right)})"
    condition += " && mrb_fixnum(r#{right_reg}) != 0" if op == 'DIV'
    if op == 'MUL'
      a = "mrb_fixnum(r#{left_reg})"
      b = "mrb_fixnum(r#{right_reg})"
      product_fits = "(#{a} == 0 || #{b} == 0 || " \
        "(#{a} > 0 ? (#{b} > 0 ? #{a} <= MRB_FIXNUM_MAX / #{b} : #{b} >= MRB_FIXNUM_MIN / #{a}) : " \
        "(#{b} > 0 ? #{a} >= MRB_FIXNUM_MIN / #{b} : #{a} >= MRB_FIXNUM_MAX / #{b})))"
      condition += " && #{product_fits}"
    end
    { condition: condition,
      result: result }
  end

  def guarded_game_integer_immediate(op, irep, idx, reg, literal, owner_def)
    input = guarded_game_integer_range(irep, idx, reg, owner_def)
    return nil unless input

    result = guarded_integer_binary_range(op, input, [literal, literal])
    return nil unless result

    condition = "mrb_fixnum_p(r#{reg}) && mrb_fixnum(r#{reg}) >= #{input[0]} && " \
      "mrb_fixnum(r#{reg}) <= #{input[1]}"
    { condition: condition, result: result }
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

    enter = irep.enter
    mand = enter ? enter.enter_fields.first : 0
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
  #   - A literal `:sym` (send(:x), method(:x), alias_method, `&:sym`) is a LOADSYM,
  #     which poisons. A name computed from a String or an interpolation is not
  #     visible that way: numeric_dynamically_named? refuses every name a program
  #     spells as a string (and the setter `stem=` of one) once any computed-name
  #     send exists.
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
  # CLASS/MODULE, ALIAS, and ARGARY/BLKPUSH/ENTER/GETMCNST (numeric fields or
  # `::`). Only the six positional call opcodes are sites; the rest poison (rule
  # 7). Any other opcode naming something raises (ENTRY_ARG_CLASSIFIED_OPS),
  # fail-loud.
  #
  # UNDEF (`undef NAME`) removes a method, not a call: like ALIAS it poisons its name.
  # ALIAS is a definition opcode, not a call (vm.c OP_ALIAS:
  # `mrb_alias_method(mrb, target, irep->syms[a], irep->syms[b])`), so it is in
  # the same category as DEF/SDEF/TDEF and poisons its name. It became reachable
  # only when core mrblib entered the closed world: mruby-enum-ext's enum.rb
  # aliases `append` onto `push` (`:append\tpush`).
  #
  # ADMISSION: (method M named N, argument position k) is admitted only when:
  #   1. @registry[N] has exactly one MethodDef, with a bytecode body.
  #   2. N is not in foreign_method_names.
  #   3. N is not in outside_tokens.
  #   4. N starts with a letter or underscore (operator names cannot be
  #      tokenized for rule 3).
  #   5. N is not `initialize` (CONSTRUCTOR_POOLS enumerates its sites by class instead).
  #   6. pure_mandatory_arity? on M, and 1 <= k <= mand.
  #   7. N is not poisoned: no LOADSYM :N, no other DEF/SDEF/TDEF :N, no
  #      SEND0/SSEND0 :N (a zero-argument call to a mand >= 1 method means this
  #      model is wrong), no `:N` in any other opcode, and N is not a name a
  #      computed-name send could reach (numeric_dynamically_named?).
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
    'ALIAS', 'UNDEF', 'ARGARY', 'BLKPUSH', 'ENTER', 'GETMCNST'
  ].freeze

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
        BytecodeIR.for(irep).each_source do |insn, i|
          name = insn.sym
          next unless name

          unless ENTRY_ARG_CLASSIFIED_OPS.include?(insn.op)
            raise "ENTRY_ARG_CALLSITE_PROOF: opcode #{insn.op} names :#{name} " \
                  "(#{insn.args.inspect}) but is not classified -- refusing to " \
                  'guess whether that is a call site'
          end

          # A def naming itself is neither a site nor poison (ENTRY_ARG_DEF_OPS).
          next if ENTRY_ARG_DEF_OPS.include?(insn.op)

          # `alias new old` reaches old's body through a call to `new`, a site of no
          # registry name; its second token is the body's own name.
          old_name = insn.first_of(:name)&.value if insn.op == 'ALIAS'
          poisoned << old_name if old_name

          unless ENTRY_ARG_CALL_OPS.include?(insn.op) && owner
            poisoned << name
            next
          end

          recv = insn.reg
          argc = insn.argc
          # `n=*` (packed arguments): argument k has no register, so it poisons.
          if recv.nil? || argc.nil?
            poisoned << name
            next
          end

          sites[name] << [irep, i, recv.to_i, argc, owner]
        end
      end
      [sites, poisoned]
    end
  end

  # ENTRY_ARG_CALLSITE_PROOF admission rules 1-8 (see the header): (irep label,
  # argument register) -> [sites, k] for every argument that could be proven from
  # its call sites. Shared with NUMERIC_ENTRY_ARG_PROOF, which asks a weaker
  # question of the same sites. Empty unless both outside scans ran (a missing
  # scan is a missing poison source).
  def entry_arg_candidates
    return {} unless @foreign_method_names && @outside_tokens

    sites, poisoned = entry_arg_call_index
    cand = {}
    @registry.each do |name, defs|
      next unless defs.size == 1                       # rule 1
      next if @foreign_method_names.include?(name)     # rule 2
      next if @outside_tokens.include?(name)           # rule 3
      next unless name =~ /\A[A-Za-z_]/                # rule 4
      next if name == 'initialize'                     # rule 5
      next if poisoned.include?(name)                  # rule 7
      next if numeric_dynamically_named?(name)         # rule 7b

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
    # CONSTRUCTOR_POOLS: rule 5 refuses initialize by name; its sites are enumerated by class.
    cand.merge!(constructor_pool_candidates)
  end

  # ENTRY_ARG_CALLSITE_PROOF greatest fixpoint (see the header). Returns a Set
  # of [irep label, mandatory argument register].
  def compute_entry_arg_fixnum
    @entry_arg_fixnum = Set.new
    # A missing scan is a missing poison source: prove nothing.
    return @entry_arg_fixnum unless @foreign_method_names && @outside_tokens

    cand = entry_arg_candidates
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
