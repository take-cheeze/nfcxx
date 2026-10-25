# frozen_string_literal: true

# CodeGen: Fixnum, Array and class return proofs.

require_relative 'define_method_sites'
require_relative 'alias_sites'
require_relative 'codegen_declared_returns'
require_relative 'bytecode_ir_returns'
require_relative 'bytecode_ir_containers'
require_relative 'foreign_string_results'

class CodeGen
  class << self
    # NATIVE_RETURN_CLASSES: name -> class, admitted from the native sources (native_return_classes.rb). Empty by default.
    attr_accessor :native_return_classes
  end

  # ---------------------------------------------------------------------------
  # FIXNUM_RETURN_PROOF (proof source 6): bare method names whose
  # SEND/SEND0/SSEND/SSEND0 provably leaves a Fixnum in the destination.
  #
  # Admission, all required:
  #   1. @registry[N] has exactly one MethodDef, with a bytecode body (the MONO
  #      test; a native definition adds a second, irep-nil entry).
  #   2. N is not in foreign_method_names: stricter than MONO on purpose, since
  #      a wrong proof is an unchecked mrb_fixnum() (UB), not a wrong call. Nor is it
  #      renamed by alias/define_method, or a name a computed-name send could build
  #      (numeric_dynamically_named?): another body could then answer under N.
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
    aliased = numeric_aliased_names
    @registry.each do |name, defs|
      next unless defs.size == 1

      d = defs.first
      next if @foreign_method_names.include?(name)
      # A computed-name send/define_method/alias can install another body under N.
      next if aliased.include?(name) || numeric_dynamically_named?(name)

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
    # DECLARED_RETURN_CHECK: checked declarations are seeded the same way (check_declared_returns).
    declared = declared_return_facts(:fixnum)
    cand.reject! { |n, _| declared.include?(n) }
    @fixnum_return_names = Set.new(cand.keys) | accessors | declared
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

    BytecodeIR.for(irep).exit?(:value)
  end

  # Does any nested block/lambda under `irep`, at any depth, contain a non-local exit?
  def subtree_has_nonlocal_exit?(irep)
    BytecodeIR.nested_exit?(irep, :block_return, :break)
  end

  # Every return path of the body holds a Fixnum (see
  # compute_fixnum_return_names for the opcode split).
  def fixnum_return_sites_proven?(d)
    irep = @ireps[d.irep]
    return false unless irep

    BytecodeIR.for(irep).exits.all? do |exit|
      exit.kind == :value && exit.reg && proven_fixnum_operand?(irep, exit.index, exit.reg, d)
    end
  end

  # ---------------------------------------------------------------------------
  # ARRAY_RETURN_PROOF: names whose SEND/SEND0/SSEND/SSEND0 provably leaves an
  # Array in the destination. Same admission rules, greatest fixpoint and
  # soundness argument as compute_fixnum_return_names, with the return-site
  # predicate "holds an Array" (proven_array_operand?):
  #   1. exactly one MethodDef, with a bytecode body;
  #   2. not in foreign_method_names (this refuses values/sort/first/... from
  #      3rd/mruby/mrblib);
  #   3. fixnum_return_analyzable? (the same rule serves an Array return);
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
      next unless irep && fixnum_return_analyzable?(irep)

      cand[name] = d
    end

    declared = declared_return_facts(:array) # DECLARED_RETURN_CHECK, as for Fixnum returns
    cand.reject! { |n, _| declared.include?(n) }
    @array_return_names = Set.new(cand.keys) | declared
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

    BytecodeIR.for(irep).exits.all? do |exit|
      reg = exit.reg
      exit.kind == :value && reg && straightline_return_reg?(irep, exit.index, reg) &&
        proven_array_operand?(irep, exit.index, reg, d.owner, mand, ivar_classes, arg_classes, dominated: dominated)
    end
  end

  # RETCLASS_SELF_CALL_SUPPORT: "every return path of this MONO method
  # holds an instance of exactly THIS class", so an implicit self-call can feed
  # ClassLayout.analyze's SETIV arm like `@x = Klass.new`. Same MONO admission as
  # ARRAY_RETURN_PROOF. RETCLASS_NILABLE_JOIN widens it to agreeing POLY names.
  # Unlike ARRAY_RETURN_PROOF the target class varies and one name's proof can
  # depend on another's, so this GROWS from empty (a name is added once every
  # return site traces to the same class), like ClassLayout's sweep. Terminates:
  # the set only grows.
  # RETCLASS_NILABLE_JOIN: the fact is "K or nil", the contract every
  # ClassLayout hint already has (NIL_TOLERANT_JOIN), so a nil source is no evidence.
  def class_return_sites_proven(d, ret_class_proof)
    irep = @ireps[d.irep]
    return nil unless irep

    ivar_classes = @class_layout[d.owner]
    arg_classes = @class_annotations[irep.label]&.args
    mand = mandatory_arity(irep)

    proven = nil
    BytecodeIR.for(irep).exits.each do |exit|
      case exit.kind
      # RETURN_BLK in a method body is a plain return (methods are strict procs).
      when :value, :block_return
        sources = return_value_sources(irep, exit.index, exit.reg)
        return nil unless sources

        sources.each do |src|
          next if src == :nil

          writer, r = src
          # The writer itself is a reaching definition already; every deeper
          # hop (a `.new`/`.dup`/accessor receiver) must dominate.
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
      when :nil
        next
      else
        return nil
      end
    end
    proven
  end

  # RETCLASS_NILABLE_JOIN: the definitions of `reg` reaching `idx` (`:nil` or `[writer_idx, reg]`), or nil if a path
  # is unaccounted for.
  def return_value_sources(irep, idx, reg)
    BytecodeIR.return_sources(irep, idx, reg, max_states: fixnum_proof_max_states(irep))
  end

  # fixnum_return_analyzable?, but a rescue handler is allowed: its entry is a
  # barrier return_value_sources never crosses. `ensure` stays refused.
  def class_return_analyzable?(irep)
    return false unless (irep.catch_handlers || []).all? { |h| h.type == :rescue }
    return false if subtree_has_nonlocal_exit?(irep)

    BytecodeIR.for(irep).exit?(:value, :block_return)
  end

  # Sends that can give a name a body (or remove one) the registry does not list.
  NAME_INSTALLER_SENDS = %w[alias_method define_method undef_method remove_method].freeze

  # Names the closed world aliases, defines by Symbol or undefines; nil when some
  # such call's names are not literal (or the installer itself is a Symbol).
  def symbol_installed_names
    return @symbol_installed_names if defined?(@symbol_installed_names)

    @symbol_installed_names = collect_installed_names(skip_class_object: false)
  end

  # symbol_installed_names, counting only the name an `alias_method` installs, not the one it copies from
  def symbol_installed_destinations
    return @symbol_installed_destinations if defined?(@symbol_installed_destinations)

    @symbol_installed_destinations = collect_installed_names(skip_class_object: false, destinations_only: true)
  end

  # NATIVE_CLASS_ARMS: symbol_installed_names without the installs that land on a class or module
  # object (`class << Const; alias_method ...`), which no instance of a proven set can see. nil when
  # symbol_installed_names is.
  def symbol_instance_installed_names
    return @symbol_instance_installed_names if defined?(@symbol_instance_installed_names)

    @symbol_instance_installed_names = symbol_installed_names && collect_installed_names(skip_class_object: true)
  end

  def collect_installed_names(skip_class_object:, destinations_only: false)
    names = Set.new
    children = @ireps.values.flat_map(&:reps).compact.to_set
    @ireps.each do |label, irep|
      # mruby's own Ruby is outside this closed world (the aliases in its
      # mrblib rename core methods, not the engine's), as it was before it became
      # compiled input. The root irep spans every file, so it is always scanned.
      next if children.include?(label) && CoreDefs.core_source?(irep.file)

      scoped = skip_class_object && @closed_world&.class_object_body?(label)
      BytecodeIR.for(irep).each_source do |insn, idx|
        case insn.op
        when :ALIAS, :UNDEF
          # ALIAS_SITES: a settled class-body alias is a registry definition of its new name.
          next if insn.op == :ALIAS && AliasSites.settled?(@registry, label, idx)

          names << insn.sym unless scoped
        when :LOADSYM
          return nil if NAME_INSTALLER_SENDS.include?(insn.sym)
        when :SEND, :SEND0, :SENDB, :SSEND, :SSEND0, :SSENDB
          next unless NAME_INSTALLER_SENDS.include?(insn.sym)
          # DEFINE_METHOD_SITES: the registry defines this one, so it names nothing unknown.
          next if insn.sym == 'define_method' && DefineMethodSites.settled?(@registry, irep, idx, @ireps)
          # ALIAS_SITES: so is a settled class-body alias_method, and it leaves `old` as it was.
          next if insn.sym == 'alias_method' && AliasSites.settled?(@registry, label, idx)

          syms = insn.plain_fixed_argc? && literal_symbol_args(irep, idx, insn.reg.to_i, insn.argc)
          return nil unless syms && !syms.empty?

          # An implicit-receiver installer in a class-object body acts on that body's own cref.
          # destinations_only: `alias_method :new, :old` installs `new` and leaves `old` as it was.
          syms = syms.first(1) if destinations_only && insn.sym == 'alias_method'
          names.merge(syms) unless scoped && insn.op.to_s.start_with?('SSEND')
        end
      end
    end
    names
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

  # An explicit call can reach any registered implementation of its name. The
  # fixpoint records a class only when every implementation proves that result.
  def class_return_for_dispatch(name)
    class_return_names[name]
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

    proven = declared_return_facts(:class).dup # DECLARED_RETURN_CHECK: seeded, checked separately
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
    # NATIVE_RETURN_CLASSES (option B): a name whose native registrations all return one class is admitted, with the
    # Ruby definitions of the name (if any) proven to that class. A name the join already proved keeps its proof.
    (self.class.native_return_classes || {}).each do |name, klass|
      next if proven.key?(name) || installed.include?(name)
      next unless native_table_name_visible?(name, klass)

      ruby_defs = (@registry[name] || []).select(&:irep)
      next unless ruby_defs.all? { |d| class_return_sites_proven(d, ret_class_proof) == klass }

      proven[name] = klass
    end
    @class_return_names = proven
  end

  # Whether the native table's +klass+ for +name+ may join the proof. A name an outside Ruby source defines joins only as
  # a String the outside definitions are audited to return (ForeignStringResults); every other outside definition
  # refuses the name, as does an unknown installer or a global refusal (ClosedWorld#name_visible_to_native_table?).
  def native_table_name_visible?(name, klass)
    return !@closed_world || @closed_world.name_visible_to_native_table?(name) unless @foreign_method_names.include?(name)
    return false unless @closed_world && klass == 'String'

    audited = ForeignStringResults.audited_string_paths(name, @closed_world.outside_ruby_paths_defining(name))
    @closed_world.native_return_sources_visible?(name, audited)
  end

  # RETCLASS_SELF_CALL_SUPPORT result, for the diagnostic and ClassLayout's
  # driver call.
  def class_return_names
    @class_return_names || {}
  end

  # ARRAY_RETURN_PROOF's control-flow guard. The backward scans walk
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
    use = idx
    irep.walk_writers(idx - 1, reg, skip_ops: BytecodeIR::Ops::LEAD_READ_ONLY) do |pin, i, r|
      # proven_array_source_scan steps over BLOCK, so it must not end this walk.
      next false if pin.op == :BLOCK
      next false unless return_write_dominates?(irep, i, use, r)
      next true unless pin.op == :MOVE

      use = i
      IrepScans.follow(pin.regs[1])
    end || false
  end

  # Does the write of `reg` at `w_idx` (-1: method entry) reach `use_idx` on every path? JOIN_DOMINANCE over the
  # audited write list, with the body's own nested-block writes opaque (BytecodeIR.write_dominates?).
  def return_write_dominates?(irep, w_idx, use_idx, reg)
    BytecodeIR.write_dominates?(irep, w_idx, use_idx, reg)
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

    n = reg - reg_offset
    n.negative? ? nil : n
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
