# frozen_string_literal: true

# CodeGen: Fixnum, Array and class return proofs.

class CodeGen
  # ---------------------------------------------------------------------------
  # FIXNUM_RETURN_PROOF (proof source 6): bare method names whose
  # SEND/SEND0/SSEND/SSEND0 provably leaves a Fixnum in the destination.
  #
  # Admission, all required:
  #   1. @registry[N] has exactly one MethodDef, with a bytecode body (the MONO
  #      test; a native definition adds a second, irep-nil entry).
  #   2. N is not in foreign_method_names: stricter than MONO on purpose, since
  #      a wrong proof is an unchecked mrb_fixnum() (UB), not a wrong call.
  #   3. The body is return-analyzable (fixnum_return_analyzable?): no catch
  #      handlers, no child ireps, at least one RETURN.
  #   4. Every return site proves (fixnum_return_sites_proven?) against the
  #      callee's own irep and MethodDef.
  #
  # Only SEND/SEND0/SSEND/SSEND0, never SENDB/SSENDB: a `break` in the caller's
  # block makes the BREAK operand the send's result (ops.h OP_BREAK), whatever
  # the callee returns. The four admitted opcodes cannot carry a block.
  #
  # Greatest fixpoint: start from names passing 1-3 and drop names whose return
  # sites stop proving, which admits self and mutual recursion. Induction over
  # the dynamic call tree of one completed call: the returned register came from
  # a Fixnum source or from a call to an admitted name that returned earlier in
  # the same tree. A cycle that never returns raises SystemStackError, so it is
  # vacuous.
  #
  # Only `RETURN R[a]` is accepted. RETURN_BLK, BREAK, RETSELF, RETNIL, RETTRUE,
  # RETFALSE (and STOP) refuse, and every RETURN in the body is checked.
  # ---------------------------------------------------------------------------
  def compute_fixnum_return_names
    @fixnum_return_names = Set.new
    # No foreign scan means poison source 2 is missing: prove nothing.
    return @fixnum_return_names unless @foreign_method_names

    cand = {}
    accessors = Set.new
    @registry.each do |name, defs|
      next unless defs.size == 1

      d = defs.first
      next if @foreign_method_names.include?(name)

      # ADMISSION VARIANT B: a MONO attr_reader/attr_accessor whose ivar is embedded
      # as :fixnum (no irep; proof source 3 moved to the callee's return).
      # drop_unsafe_embeddings keeps such an ivar embedded only when
      # ATTR_STRUCT_DEVIRT replaces the native accessor program-wide with
      # emit_ivar_accessor_pair's getter, `return
      # mrb_fixnum_value(((Owner_ivars*)DATA_PTR(self))->name);` over an mrb_int
      # field; the same gate guarantees the struct is allocated and every write went
      # through SETIV's mrb_integer_p guard. The name is MONO, so another receiver
      # raises NoMethodError. Not iterated: a field read depends on no other return
      # type.
      if d.irep.nil?
        accessors << name if d.kind == :ivar_accessor && embed_type(d.owner, name) == :fixnum
        next
      end

      irep = @ireps[d.irep]
      next unless irep && fixnum_return_analyzable?(irep)

      cand[name] = d
    end

    # Greatest fixpoint from every candidate. Variant B accessors are seeded and
    # never re-examined, but are visible to the bytecode candidates' proofs (a
    # method returning `other.code`).
    @fixnum_return_names = Set.new(cand.keys) | accessors
    loop do
      dropped = cand.keys.select do |n|
        @fixnum_return_names.include?(n) && !fixnum_return_sites_proven?(cand[n])
      end
      break if dropped.empty?

      dropped.each { |n| @fixnum_return_names.delete(n) }
    end
    @fixnum_return_names
  end

  # Structural preconditions for reading a body's return sites.
  # Catch handlers refuse: a rescue arm is an extra return path (and its range
  # is extracted into a separate function).
  # Child ireps are allowed (fixnum_proof_ctx already refuses registers a nested
  # SETUPVAR writes), but a descendant RETURN_BLK is a return from THIS method
  # not in this instruction list (`ary.each { return "x" }`), so it refuses.
  # BREAK refuses too, conservatively: it only affects a block-carrying send's
  # result, and SENDB/SSENDB are not proof sources anyway.
  def fixnum_return_analyzable?(irep)
    return false unless (irep.catch_handlers || []).empty?
    return false if subtree_has_nonlocal_exit?(irep)

    irep.instructions.any? { |i| i.op == 'RETURN' }
  end

  # Does any nested block/lambda under `irep` contain a non-local exit? All
  # depths, `seen`-guarded.
  def subtree_has_nonlocal_exit?(irep, seen = Set.new)
    (irep.reps || []).any? do |label|
      next false if seen.include?(label)

      seen << label
      child = @ireps[label]
      next false unless child

      child.instructions.any? { |i| i.op == 'RETURN_BLK' || i.op == 'BREAK' } ||
        subtree_has_nonlocal_exit?(child, seen)
    end
  end

  # Every return path of the body holds a Fixnum (see
  # compute_fixnum_return_names for the opcode split).
  def fixnum_return_sites_proven?(d)
    irep = @ireps[d.irep]
    return false unless irep

    irep.instructions.each_with_index do |insn, idx|
      case insn.op
      when 'RETURN'
        # `"RETURN\tR%d"` -- the returned register is the first operand.
        reg = insn.args[/\AR(\d+)/, 1]
        return false unless reg
        return false unless proven_fixnum_operand?(irep, idx, reg, d)
      when 'RETURN_BLK', 'BREAK', 'RETSELF', 'RETNIL', 'RETTRUE', 'RETFALSE', 'STOP'
        return false
      end
    end
    true
  end

  # ---------------------------------------------------------------------------
  # ARRAY_RETURN_PROOF: names whose SEND/SEND0/SSEND/SSEND0 provably leaves an
  # Array in the destination. Same admission rules, greatest fixpoint and
  # soundness argument as compute_fixnum_return_names, with the return-site
  # predicate "holds an Array" (proven_array_operand?):
  #   1. exactly one MethodDef, with a bytecode body;
  #   2. not in foreign_method_names (this refuses values/sort/first/... from
  #      3rd/mruby/mrblib);
  #   3. array_return_analyzable? (= fixnum_return_analyzable?);
  #   4. every `RETURN R[a]` proves; any other exit opcode refuses.
  # Rules 1+2 mean the name has one body in the whole program, so no receiver
  # can reach another definition, and one that lacks the method raises before
  # returning (as for CORE_ARRAY_RETURN_METHODS).
  # Trust level: the predicate is exactly what the loop recognizers apply to
  # their own receiver, including trace_new_target's ClassLayout-hint terminal
  # (a whole-program agreement fact), and every consumer is a loop emitter with
  # an mrb_array_p raise-tripwire, so a wrong fact raises TypeError, never UB.
  # No compiles_clean? requirement (see annotated_array_return).
  # ---------------------------------------------------------------------------
  def compute_array_return_names
    @array_return_names = Set.new
    # No foreign scan means rule 2 is missing: prove nothing.
    return @array_return_names unless @foreign_method_names

    cand = {}
    @registry.each do |name, defs|
      next unless defs.size == 1

      d = defs.first
      next if @foreign_method_names.include?(name)
      # attr_* defs (no irep) are refused: unlike FIXNUM_RETURN_PROOF variant B,
      # an Array ivar is never embedded, so there is nothing to fall back on.
      next unless d.irep

      irep = @ireps[d.irep]
      next unless irep && array_return_analyzable?(irep)

      cand[name] = d
    end

    @array_return_names = Set.new(cand.keys)
    loop do
      dropped = cand.keys.select do |n|
        @array_return_names.include?(n) && !array_return_sites_proven?(cand[n])
      end
      break if dropped.empty?

      dropped.each { |n| @array_return_names.delete(n) }
    end
    @array_return_names
  end

  # ARRAY_RETURN_PROOF result, for the diagnostic.
  def array_return_names
    @array_return_names || Set.new
  end

  # fixnum_return_analyzable?'s rule, reused (the question is type-independent).
  def array_return_analyzable?(irep)
    return false unless (irep.catch_handlers || []).empty?
    return false if subtree_has_nonlocal_exit?(irep)

    irep.instructions.any? { |i| i.op == 'RETURN' }
  end

  # Every return path holds an Array; same opcode split as
  # fixnum_return_sites_proven?.
  def array_return_sites_proven?(d)
    irep = @ireps[d.irep]
    return false unless irep

    # The same context compile_method builds for the loop recognizers, so the
    # question is identical, asked of the callee's body.
    ivar_classes = @class_layout[d.owner]
    arg_classes = @class_annotations[irep.label]&.args
    mand = mandatory_arity(irep)
    dominated = ->(w_idx, use_idx, r) { return_write_dominates?(irep, w_idx, use_idx, r) }

    irep.instructions.each_with_index do |insn, idx|
      case insn.op
      when 'RETURN'
        # `"RETURN\tR%d"` -- the returned register is the first operand.
        reg = insn.args[/\AR(\d+)/, 1]
        return false unless reg
        return false unless straightline_return_reg?(irep, idx, reg)
        return false unless proven_array_operand?(irep, idx, reg, d.owner, mand, ivar_classes, arg_classes,
                                                  dominated: dominated)
      when 'RETURN_BLK', 'BREAK', 'RETSELF', 'RETNIL', 'RETTRUE', 'RETFALSE', 'STOP'
        return false
      end
    end
    true
  end

  # RETCLASS_SELF_CALL_SUPPORT (ADR 0194): "every return path of this MONO method
  # holds an instance of exactly THIS class", so an implicit self-call can feed
  # ClassLayout.analyze's SETIV arm like `@x = Klass.new`. Same MONO admission as
  # ARRAY_RETURN_PROOF. RETCLASS_NILABLE_JOIN widens it to agreeing POLY names.
  # Unlike ARRAY_RETURN_PROOF the target class varies and one name's proof can
  # depend on another's, so this GROWS from empty (a name is added once every
  # return site traces to the same class), like ClassLayout's sweep. Terminates:
  # the set only grows.
  # RETCLASS_NILABLE_JOIN (ADR 0199): the fact is "K or nil", the contract every
  # ClassLayout hint already has (NIL_TOLERANT_JOIN), so a nil source is no evidence.
  def class_return_sites_proven(d, ret_class_proof)
    irep = @ireps[d.irep]
    return nil unless irep

    ivar_classes = @class_layout[d.owner]
    arg_classes = @class_annotations[irep.label]&.args
    mand = mandatory_arity(irep)

    proven = nil
    irep.instructions.each_with_index do |insn, idx|
      case insn.op
      # RETURN_BLK in a method body is a plain return (methods are strict procs).
      when 'RETURN', 'RETURN_BLK'
        reg = insn.args[/\AR(\d+)/, 1]
        return nil unless reg

        sources = return_value_sources(irep, idx, reg)
        return nil unless sources

        sources.each do |src|
          next if src == :nil

          writer, r = src
          # The writer itself is a reaching definition already; every deeper
          # hop (a `.new`/`.dup`/accessor receiver) must dominate (ADR 0198).
          dominated = lambda do |w_idx, use_idx, hop_reg|
            (w_idx == writer && use_idx == writer + 1) || return_write_dominates?(irep, w_idx, use_idx, hop_reg)
          end
          klass = trace_new_target(irep, writer + 1, r, ivar_classes, mand, arg_classes, owner: d.owner,
                                    class_layout: @class_layout, registry: @registry,
                                    container_constants: @container_constants,
                                    ret_class_proof: ret_class_proof, dominated: dominated)
          return nil unless klass
          return nil if proven && proven != klass

          proven = klass
        end
      when 'RETNIL'
        next
      when 'BREAK', 'RETSELF', 'RETTRUE', 'RETFALSE', 'STOP'
        return nil
      end
    end
    proven
  end

  # A Ruby callee's frame starts at R(a), so it may overwrite every register above a.
  RETURN_SOURCE_CALLS = Set['SEND', 'SEND0', 'SENDB', 'SSEND', 'SSEND0', 'SSENDB', 'SUPER', 'EXEC'].freeze

  # RETCLASS_NILABLE_JOIN: the definitions of `reg` reaching `idx` (`:nil` or
  # `[writer_idx, reg]`), or nil if a path is unaccounted for. JOIN_REACHING_DEFS'
  # walk and barriers with ADR 0198's level-aware block-write barrier, minus the
  # protected range (a codegen concern, not a value one).
  def return_value_sources(irep, idx, reg)
    preds = fixnum_proof_preds(irep)
    return nil unless preds

    ctx = fixnum_proof_ctx(irep)
    block_written = own_upvar_written_regs(irep)
    out = []
    seen = Set.new
    work = [[idx, reg.to_s]]
    until work.empty?
      state = work.pop
      next unless seen.add?(state)
      return nil if seen.size > FIXNUM_PROOF_REACHING_MAX_STATES

      i, r = state
      return nil if block_written.include?(r)
      return nil if ctx[:catch_targets].include?(irep.instructions[i].addr)

      ps = preds[i]
      return nil if ps.nil? || ps.empty?

      ps.each do |p|
        return nil if p.negative?

        insn = irep.instructions[p]
        # vm.c only falls through a `RAISEIF Ra` when regs[a] is nil.
        if insn.op == 'RAISEIF'
          if insn.args[/\AR(\d+)/, 1] == r
            out << :nil
          else
            work << [p, r]
          end
          next
        end
        return nil unless FIXNUM_PROOF_STEP_OVER_OPS.include?(insn.op) || insn.op.start_with?('LOADI')
        return nil if RETURN_SOURCE_CALLS.include?(insn.op) && insn.args[/\AR(\d+)/, 1].to_i < r.to_i

        if !fixnum_proof_writes_reg?(insn, r)
          work << [p, r]
        elsif insn.op == 'MOVE'
          src = insn.args.scan(/R(\d+)/).flatten[1]
          return nil unless src

          work << [p, src]
        elsif insn.op == 'LOADNIL'
          out << :nil
        else
          out << [p, r]
        end
      end
    end
    out
  end

  # array_return_analyzable?, but a rescue handler is allowed: its entry is a
  # barrier return_value_sources never crosses. `ensure` stays refused.
  def class_return_analyzable?(irep)
    return false unless (irep.catch_handlers || []).all? { |h| h.type == :rescue }
    return false if subtree_has_nonlocal_exit?(irep)

    irep.instructions.any? { |i| i.op == 'RETURN' || i.op == 'RETURN_BLK' }
  end

  # Sends that can give a name a body (or remove one) the registry does not list.
  NAME_INSTALLER_SENDS = %w[alias_method define_method undef_method remove_method].freeze

  # Names the closed world aliases, defines by Symbol or undefines; nil when some
  # such call's names are not literal (or the installer itself is a Symbol).
  def symbol_installed_names
    return @symbol_installed_names if defined?(@symbol_installed_names)

    names = Set.new
    @ireps.each_value do |irep|
      irep.instructions.each_with_index do |insn, idx|
        operands = entry_arg_operands(insn)
        case insn.op
        when 'ALIAS', 'UNDEF'
          operands.scan(ENTRY_ARG_NAME_RE) { |m| names << m[0] }
        when 'LOADSYM'
          return @symbol_installed_names = nil if NAME_INSTALLER_SENDS.include?(operands[ENTRY_ARG_NAME_RE, 1])
        when 'SEND', 'SEND0', 'SENDB', 'SSEND', 'SSEND0', 'SSENDB'
          m = operands.match(/\AR(\d+)\s+:(\S+?)(?:\s+n=(\S+))?\s*\z/)
          next unless m && NAME_INSTALLER_SENDS.include?(m[2])

          syms = m[3]&.match?(/\A\d+\z/) && literal_symbol_args(irep, idx, m[1].to_i, m[3].to_i)
          return @symbol_installed_names = nil unless syms && !syms.empty?

          names.merge(syms)
        end
      end
    end
    @symbol_installed_names = names
  end

  # A self-call from `owner` never reaches method_missing when `owner`'s own
  # superclass chain defines `name`; anything found earlier is a registry def too.
  def self_call_reaches_def?(name, owner)
    def_owners = @registry.fetch(name, []).map(&:owner)
    seen = Set.new
    o = owner
    while o.is_a?(String) && seen.add?(o)
      return true if def_owners.include?(o)

      o = @superclass_of[o]
    end
    false
  end

  # The fact ClassLayout.analyze consumes at a self-call SETIV site.
  def class_return_for_self_call(name, owner)
    klass = class_return_names[name]
    klass if klass && self_call_reaches_def?(name, owner)
  end

  # RETCLASS_SELF_CALL_SUPPORT fixpoint. Every registry def of the name needs a
  # bytecode body (no native/attr_*); a POLY name is admitted when all of its
  # defs prove the same class, since a self-call may reach any.
  def compute_class_return_names
    @class_return_names = {}
    return @class_return_names unless @foreign_method_names

    installed = symbol_installed_names
    return @class_return_names unless installed

    cand = {}
    @registry.each do |name, defs|
      next if @foreign_method_names.include?(name)
      next if installed.include?(name)
      next unless defs.all? { |d| d.irep && @ireps[d.irep] && class_return_analyzable?(@ireps[d.irep]) }

      cand[name] = defs
    end

    proven = {}
    ret_class_proof = lambda do |n, owner|
      proven[n] if self_call_reaches_def?(n, owner)
    end
    loop do
      changed = false
      cand.each do |name, defs|
        next if proven.key?(name)

        classes = defs.map { |d| class_return_sites_proven(d, ret_class_proof) }
        klass = classes.first
        next unless klass && classes.all? { |c| c == klass }

        proven[name] = klass
        changed = true
      end
      break unless changed
    end
    @class_return_names = proven
  end

  # RETCLASS_SELF_CALL_SUPPORT result, for the diagnostic and ClassLayout's
  # driver call.
  def class_return_names
    @class_return_names || {}
  end

  # ARRAY_RETURN_PROOF's control-flow guard (ADR 0198). The backward scans walk
  # the instruction array linearly and see only the textually preceding writer,
  # not the other predecessors of a join. At a receiver site that is backed by
  # the mrb_array_p tripwire; for a claim about EVERY return path it is unsound:
  # `def extensions; @extensions || EXTENSIONS; end` would be proved from the
  # GETCONST arm alone.
  # Rule: walking back from the RETURN (following MOVEs), every write must
  # dominate the instruction that reads it (return_write_dominates?), and the
  # same test is passed to trace_new_target as `dominated:` for its deeper hops.
  # "Only one writer" is not enough: method entry is an invisible second
  # definition, so `x = Foo.new if c; bar; x` must be refused. Falling off the
  # front is refused.
  def straightline_return_reg?(irep, idx, reg)
    r = reg
    use = idx
    (idx - 1).downto(0) do |i|
      pin = irep.instructions[i]
      next if READ_ONLY_OPCODE_SKIP.include?(pin.op) || pin.args[/^R(\d+)/, 1] != r
      # proven_array_source_scan steps over BLOCK, so it must not end this walk.
      return false if pin.op == 'BLOCK'
      return false unless return_write_dominates?(irep, i, use, r)
      return true unless pin.op == 'MOVE'

      r = pin.args.scan(/R(\d+)/).flatten[1]
      return false unless r

      use = i
    end
    false
  end

  # Does the write of `reg` at `w_idx` (-1: method entry) reach `use_idx` on
  # every path? FIXNUM_OPERAND_PROOF's own region test, over its audited
  # step-over whitelist (a hidden writer such as RESCUE/APOST refuses).
  def return_write_dominates?(irep, w_idx, use_idx, reg)
    ctx = fixnum_proof_ctx(irep)
    return false if own_upvar_written_regs(irep).include?(reg)

    stepped = ((w_idx + 1)...use_idx).all? do |k|
      op = irep.instructions[k].op
      FIXNUM_PROOF_STEP_OVER_OPS.include?(op) || op.start_with?('LOADI')
    end
    stepped && fixnum_proof_region_ok?(irep, ctx, w_idx, use_idx)
  end

  # Registers of `irep` ITSELF that a nested block writes: unlike
  # subtree_upvar_written_regs, a SETUPVAR `depth` blocks down counts only
  # when its level is `depth - 1` (vm.c's `uvenv` walks that many uppers).
  def own_upvar_written_regs(irep)
    @own_upvar_written_regs ||= {}
    @own_upvar_written_regs[irep.label] ||= collect_own_upvar_writes(irep, 1, Set.new)
  end

  def collect_own_upvar_writes(irep, depth, acc)
    (irep.reps || []).each do |label|
      child = @ireps[label]
      next unless child

      child.instructions.each do |insn|
        next unless insn.op == 'SETUPVAR'

        _src, b, lv = insn.args.split(/\s+/)
        # An unparsable level is kept: over-collecting only costs a proof.
        acc << b if b =~ /\A\d+\z/ && !(lv =~ /\A\d+\z/ && lv.to_i != depth - 1)
      end
      collect_own_upvar_writes(child, depth + 1, acc)
    end
    acc
  end

  # "Is `reg` at `idx` provably an Array?": recognize_each_regions' two-step
  # receiver gate, shared so the two cannot drift.
  def proven_array_operand?(irep, idx, reg, owner_name, mand, ivar_classes, arg_classes, dominated: nil)
    traced = trace_new_target(irep, idx, reg, ivar_classes, mand, arg_classes, owner: owner_name,
                               class_layout: @class_layout, registry: @registry,
                               container_constants: @container_constants, dominated: dominated)
    return true if traced == 'Array'

    !proven_array_source(irep, idx, reg).nil?
  end

  # BLOCK_BODY_INDEX_SUPPORT: map a register number compile_insn extracted back
  # to `irep`'s own numbering. Identity (offset 0) for method bodies, rescue try
  # bodies and BLOCK/LAMBDA_FALLBACK bodies. compile_block_body_insn splices an
  # inlined block into the enclosing function and shifts its `R<n>` to
  # `R<n + offset>` to keep the frames' `r<n>` disjoint; the proofs read
  # block_irep.instructions, so they must be asked about `n`. Every register in
  # the instruction is shifted, so a negative result means a malformed
  # extraction and returns nil (not provable).
  def unshift_proof_reg(reg, reg_offset)
    return reg if reg_offset.zero?
    return nil if reg.nil?

    n = reg.to_i - reg_offset
    n.negative? ? nil : n.to_s
  end

  # Both operand registers of one binary opcode, proven at the same point.
  def proven_fixnum_pair?(irep, idx, dreg, sreg, owner_def)
    return false unless dreg && sreg

    proven_fixnum_operand?(irep, idx, dreg, owner_def) &&
      proven_fixnum_operand?(irep, idx, sreg, owner_def)
  end

  # Emitted above a devirtualized arithmetic/comparison op, like the embedded
  # ivar `// @x embedded` marker, so the generated body says why it has no
  # fallback.
  FIXNUM_PROOF_NOTE = "  // operands proven Fixnum -- no runtime check, no mrb_funcall fallback\n"
end
