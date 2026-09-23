# frozen_string_literal: true

# CodeGen: lambda, runtime def and exec fallbacks.

class CodeGen
  # LAMBDA_FALLBACK_SUPPORT: `LAMBDA Ra I[b]` (ops.h `R[a] =
  # lambda(Irep[b],L_LAMBDA)`) whose body is lambda_fallback_safe?: a
  # one-instruction region that only builds the proc.
  # CONFINED_LAMBDA_UPVAR_SUPPORT: `available_upvars` as in
  # recognize_block_fallback_regions (empty at method level).
  def recognize_lambda_fallback_regions(irep, available_upvars: [])
    regions = []
    irep.instructions.each do |insn|
      next unless insn.op == 'LAMBDA'

      dest_reg = insn.args[/^R(\d+)/, 1]
      next unless dest_reg

      lambda_irep_idx = insn.args[/I\[(\d+)\]/, 1]
      next unless lambda_irep_idx

      lambda_label = irep.reps[lambda_irep_idx.to_i]
      lambda_irep = lambda_label && @ireps[lambda_label]
      next unless lambda_irep && lambda_fallback_safe?(lambda_irep)

      # CONFINED_LAMBDA_UPVAR_SUPPORT: what does the body need captured
      # (block_upvar_needs), can this level supply it, and (lambda-specific) does
      # the proc provably never escape this frame?
      upvars = block_upvar_needs(lambda_irep)
      next if upvars.nil?
      next unless upvars.all? { |(l, x)| l.zero? || available_upvars.include?([l - 1, x]) }

      call_sites = lambda_confined_call_sites(irep, insn, dest_reg.to_i, lambda_irep)
      next if upvars.any? && call_sites.nil?

      regions << { block_addr: insn.addr, dest_reg: dest_reg, block_irep: lambda_irep,
                   kind: 'lambda_fallback', upvars: upvars, call_sites: call_sites || [] }
    end
    regions
  end

  # CONFINED_LAMBDA_UPVAR_SUPPORT: prove the proc built by `LAMBDA R<d> I[n]`
  # never leaves this frame (never returned, stored or passed on), so the
  # captured `&r<b>` pointers cannot dangle. Anything not accounted for declines
  # (`#error`). The recognized shape (RPG2k::Scene::Menu#draw_status_row, `line =
  # ->(n) { y + n * LINE_H }` then three `line.call(k)`):
  #
  #     531 013 LAMBDA  R6   I[0]
  #     532 022 MOVE    R12  R6      ; R6:line
  #     532 025 LOADI_0 R13  (0)
  #     532 027 SEND    R12  :call   n=1
  #     534 058 MOVE    R9   R6      ; R6:line
  #     534 061 LOADI_1 R10  (1)
  #     534 063 SEND    R9   :call   n=1
  #     541 204 MOVE    R9   R6      ; R6:line
  #     541 207 LOADI_2 R10  (2)
  #     541 209 SEND    R9   :call   n=1
  #
  # Three gates:
  # (1) `d` is a named local (1 <= d < nlocals). mrbc's allocator keeps
  #     temporaries above nlocals (codegen.c push_n_/pop_n_), so no opcode's
  #     implicit register window (`SEND Ra n=N` reading Ra+1..Ra+N, ARRAY, ...)
  #     reaches a named local; every use of R<d> is printed, and `\bR<d>\b`
  #     finds them all.
  # (2) No ARGARY or BLKPUSH in the enclosing irep: they read parameter slots
  #     (named locals) without printing them (vm.c `stack[m1+r+m2]`,
  #     `regs[a] = stack[offset]`), so gate (1) cannot cover them.
  # (3) Every other use of R<d> is `MOVE R<t> R<d>` consumed, on a straight-line
  #     stretch, as the receiver of `:call`. Proc#call is mruby's static
  #     call_proc (one OP_CALL, proc.c mrb_init_proc): synchronous, never
  #     retains the proc, and the SEND overwrites R<t>. R<t> is a temporary, so
  #     an intervening implicit window could cover it (`SSEND R9
  #     :draw_system_text n=7` reads R9..R16); hence only whitelisted opcodes
  #     that touch just the registers they print may sit between.
  LAMBDA_CONFINED_CALL_SETUP_OPS = %w[
    LOADI LOADI_0 LOADI_1 LOADI_2 LOADI_3 LOADI_4 LOADI_5 LOADI_6 LOADI_7
    LOADI__1 LOADI8 LOADI16 LOADI32 LOADINEG LOADL LOADL16
    LOADSYM LOADSYM16 LOADNIL LOADSELF LOADTRUE LOADFALSE
    STRING STRING16 MOVE GETIV GETGV GETCV GETCONST GETMCNST GETUPVAR
    ADDI SUBI
  ].freeze

  #
  # Returns the `.call` sites ({ send_addr:, dest_reg:, n: }) or nil; the
  # emitter needs them (see emit_lambda_confined_call_glue).
  def lambda_confined_call_sites(irep, lambda_insn, d, lambda_irep)
    nlocals = irep.nlocals.to_i
    # (1) a named local, so no implicit register window can alias it.
    return nil unless d >= 1 && d < nlocals
    # (2) the two opcodes that read a named local without printing it.
    return nil if irep.instructions.any? { |i| %w[ARGARY BLKPUSH].include?(i.op) }

    # A child irep capturing R<d> as an upvar would point at it from a scope this
    # proof does not cover; block_upvar_needs propagates deeper needs as
    # [level - 1, idx], so [0, d] covers any depth.
    return nil if (irep.reps || []).any? do |child_label|
      child = child_label && @ireps[child_label]
      needs = child && block_upvar_needs(child)
      needs.nil? || needs.include?([0, d])
    end

    mand = mandatory_arity(lambda_irep)
    sites = []
    insns = irep.instructions
    insns.each_with_index do |insn, i|
      next if insn.equal?(lambda_insn)
      next unless insn.args =~ /\bR#{d}\b/

      # (3) the only permitted consumer: `MOVE R<t> R<d>` into a temporary.
      m = insn.op == 'MOVE' && insn.args.match(/\AR(\d+)\s+R#{d}\b/)
      return nil unless m

      t = m[1].to_i
      return nil unless t >= nlocals

      site = lambda_confined_call_consumes?(irep, i, t)
      return nil unless site
      # A lambda is strict about arity; the direct call cannot raise ArgumentError,
      # so a count other than the lambda's mandatory arity declines.
      return nil unless site[:n] == mand

      sites << site
    end
    sites
  end

  # CONFINED_LAMBDA_UPVAR_SUPPORT: gate (3)'s straight-line half: walk from the
  # MOVE at `i` to the consuming `SEND`/`SEND0 R<t> :call`, allowing only
  # whitelisted setup opcodes, with no jump inside the stretch and no jump target
  # inside it. Then "after the MOVE, the next use of R<t> is the :call receiver,
  # which overwrites it" holds on every execution.
  # Returns { send_addr:, dest_reg:, n: } or nil.
  def lambda_confined_call_consumes?(irep, i, t)
    insns = irep.instructions
    targets = jump_targets(irep)
    ((i + 1)...insns.size).each do |j|
      nxt = insns[j]
      if %w[SEND SEND0].include?(nxt.op) &&
         (m = nxt.args.match(/\AR#{t}\s+:call(?:\s+n=(\d+))?(?:\s|\z)/))
        return { send_addr: nxt.addr, dest_reg: t, n: m[1].to_i }
      end

      return nil unless LAMBDA_CONFINED_CALL_SETUP_OPS.include?(nxt.op)
      return nil if nxt.args =~ /\bR#{t}\b/
      return nil if targets.include?(nxt.addr)
    end
    nil
  end

  # CONFINED_LAMBDA_UPVAR_SUPPORT: a confined `.call` becomes a DIRECT call to
  # the lambda body's `_impl`, never mrb_funcall(..., "call"). This is required:
  # Proc#call is call_proc (one OP_CALL), and vm.c OP_CALL's cfunc branch ends
  # with
  #
  #     ci = cipop(mrb);
  #     ci[1].stack[0] = recv;
  #     irep = ci->proc->body.irep;     /* <-- unconditional deref */
  #
  # When the caller is a C frame (a compiled method registered with
  # mrb_define_method), `ci->proc` is NULL (mrb_funcall_with_block sets
  # `ci->proc = MRB_METHOD_PROC_P(m) ? MRB_METHOD_PROC(m) : NULL`), so this
  # segfaults.
  # The confinement proof supplies everything the direct call needs: the
  # receiver is this lambda, self is the same local captured into env slot 0,
  # the upvar pointers are the same expressions in the same order, and the
  # arguments are R<t+1>..R<t+n> with n equal to the arity. The RProc is still
  # built and stored into R<d>, so the register holds a real Proc.
  def emit_lambda_confined_call_glue(region, fn_name, site)
    dest = site[:dest_reg]
    args = (1..site[:n]).map { |k| "r#{dest + k}" }
    upvar_args = (region[:upvars] || []).map do |(l, b)|
      l.zero? ? "&r#{b}" : upvar_var_name(l - 1, b)
    end
    out = String.new
    out << "  // CONFINED_LAMBDA_CALL -- provably this frame's own lambda (never escapes); " \
           "direct C++ call, not mrb_funcall(:call)\n"
    out << "  r#{dest} = #{fn_name}_impl(M, self#{(upvar_args + args).map { |x| ", #{x}" }.join});\n"
    out
  end

  # LAMBDA_FALLBACK_SUPPORT: build the RProc (emit_rproc_construction) and store
  # it (`mrb_obj_value`); a LAMBDA calls nothing.
  # CONFINED_LAMBDA_UPVAR_SUPPORT: region[:upvars] uses the same construction;
  # non-empty only for a frame-confined lambda.
  def emit_lambda_fallback_glue(region, fn_name)
    dest_reg = region[:dest_reg].to_i
    rproc_var, ctor = emit_rproc_construction(region[:block_addr], fn_name, region[:upvars] || [])
    out = String.new
    out << "  // LAMBDA_FALLBACK -- lambda body compiled as a standalone cfunc, wrapped as a real RProc " \
           "(self captured at construction time), stored -- not dispatched\n"
    out << "  {\n"
    out << ctor
    out << "    r#{dest_reg} = mrb_obj_value(#{rproc_var});\n"
    out << "  }\n"
    out
  end

  # RUNTIME_DEF_FALLBACK_SUPPORT: parse `SDEF R3 :read I[0]` / `TDEF R1 :update
  # I[0]` (both `"%cDEF\t\tR%d\t:%s\tI[%d]\n"`, src/codedump.c) into a region.
  # nil (keep `#error`) for an unmatched line, a child index not in reps[], or a
  # non-mandatory body (runtime_def_body_safe?).
  def runtime_def_region(insn, irep, kind)
    m = insn.args.match(/\AR(\d+)\s+:(\S+)\s+I\[(\d+)\]\z/)
    return nil unless m

    child_label = irep.reps[m[3].to_i]
    return nil unless child_label

    child = @ireps[child_label]
    return nil unless child && runtime_def_body_safe?(child)

    # RUNTIME_DEF_FALLBACK_SUPPORT: the enclosing irep's nregs, so
    # emit_runtime_def_install can tell whether the `a` register exists (it may
    # not; see there).
    { block_irep: child, block_addr: insn.addr, kind: kind, self_source: :receiver,
      dest_reg: m[1].to_i, name: m[2], mand: mandatory_arity(child),
      enclosing_nregs: irep.nregs.to_i }
  end

  def tdef_fallback_region(insn, irep)
    runtime_def_region(insn, irep, 'tdef_fallback')
  end

  # RUNTIME_DEF_DEVIRT_GUARD: class-body sends whose installed names can be read
  # from literal Symbol arguments. Anything else installs an unknown set (see
  # class_body_installed_names).
  CLASS_BODY_INSTALLER_SENDS = {
    'alias_method' => :alias,
    'attr_reader' => :reader,
    'attr_writer' => :writer,
    'attr_accessor' => :accessor
  }.freeze

  # RUNTIME_DEF_DEVIRT_GUARD: opcodes that touch no method table. An allowlist, so
  # an unconsidered opcode lands on "unknown", the safe side.
  CLASS_BODY_INERT_OPS = %w[LOADSYM MOVE LOADNIL LOADSELF ENTER JMP RETURN].freeze

  # RUNTIME_DEF_DEVIRT_GUARD: the `n` literal Symbol arguments of a class-body
  # send, from the `LOADSYM R(dest+k) :name` instructions right before it
  # (`alias_method :a, :b`, `attr_accessor :x`). nil unless the whole set is
  # literal.
  def literal_symbol_args(irep, idx, dest, n)
    return [] if n.zero?
    return nil if idx < n

    # Exactly the n instructions immediately before the send, in ascending
    # register order; a loose search would have to prove nothing in between (e.g.
    # a MOVE) clobbered the register. mrbc emits:
    #
    #   000 LOADSYM R2 :_probe_update
    #   003 LOADSYM R3 :update
    #   006 SSEND   R1 :alias_method  n=2
    #
    # Anything else is nil ("unknown").
    (1..n).map do |k|
      insn = irep.instructions[idx - n + k - 1]
      return nil unless insn && insn.op == 'LOADSYM'

      m = insn.args.to_s.match(/\AR(\d+)\s+:(\S+)\z/)
      return nil unless m && m[1].to_i == dest + k

      m[2]
    end
  end

  # RUNTIME_DEF_DEVIRT_GUARD: every name an EXEC-opened class body installs, or
  # nil ("cannot be bounded").
  # A method installed on an object's SINGLETON class at runtime is invisible to
  # mrb_obj_class (`mrb_class_real(mrb_class(mrb, obj))`, src/class.c, skips
  # SCLASS), so MONO calls, POLY_SMALL_N chains, TYPED and ivar-accessor inlines
  # would call the class's implementation for a patched receiver (`class << a;
  # alias_method :_orig, :shared_name; def shared_name; ...; end; end;
  # a.shared_name` returned the unpatched result when compiled). Compiling the
  # patching method is what exposes this, so it is guarded here, per name: only
  # names the method may install are blocked. nil blocks every name in the
  # method, which still compiles, fully dynamic.
  # Scope: a devirtualized call in some OTHER compiled method can still miss a
  # runtime singleton patch; that is a general limitation, not introduced here.
  def class_body_installed_names(body)
    names = Set.new
    body.instructions.each_with_index do |insn, idx|
      case insn.op
      when 'TDEF'
        m = insn.args.match(/\AR\d+\s+:(\S+)\s+I\[\d+\]\z/)
        return nil unless m

        names << m[1]
      when 'SSEND', 'SSEND0'
        m = insn.args.match(/\AR(\d+)\s+:(\S+?)(?:\s+n=(\d+))?\z/)
        return nil unless m

        kind = CLASS_BODY_INSTALLER_SENDS[m[2]]
        return nil unless kind

        syms = literal_symbol_args(body, idx, m[1].to_i, m[3].to_i)
        return nil unless syms && !syms.empty?

        case kind
        # alias_method(new_name, old_name) installs the FIRST argument
        # (mrb_alias_method).
        when :alias then names << syms.first
        when :reader then names.merge(syms)
        when :writer then names.merge(syms.map { |s| "#{s}=" })
        when :accessor then names.merge(syms).merge(syms.map { |s| "#{s}=" })
        end
      else
        return nil unless CLASS_BODY_INERT_OPS.include?(insn.op)
      end
    end
    names
  end

  # RUNTIME_DEF_DEVIRT_GUARD: every name this method may install at runtime
  # (SDEF names plus EXEC class bodies), or nil if any body is unbounded.
  def runtime_installed_names_for(irep, exec_regions)
    names = Set.new
    irep.instructions.each do |insn|
      next unless insn.op == 'SDEF'

      m = insn.args.match(/\AR\d+\s+:(\S+)\s+I\[\d+\]\z/)
      return nil unless m

      names << m[1]
    end
    exec_regions.each do |region|
      body_names = class_body_installed_names(region[:block_irep])
      return nil unless body_names

      names.merge(body_names)
    end
    names
  end

  # RUNTIME_DEF_DEVIRT_GUARD: may `name` be bound statically in the method being
  # compiled? Always true unless the method patches at runtime
  # (@runtime_installed_names non-nil).
  def devirt_blocked_name?(name)
    return false unless @runtime_installed_names
    return true if @runtime_installed_names == :unknown

    @runtime_installed_names.include?(name.to_s)
  end

  # RUNTIME_DEF_DEVIRT_GUARD: marker kinds that are real dynamic dispatch (runtime
  # lookup honours a singleton patch). Every other `// KIND :name` marker is
  # audited as a static bind, so a new marker kind defaults to the safe side.
  RUNTIME_DEF_DYNAMIC_MARKERS = %w[
    POLY SPLAT KEYWORD_HASH_POSITIONAL EXPLICIT_BLOCK_ARG
    BLOCK_FALLBACK LAMBDA_FALLBACK SDEF_FALLBACK TDEF_FALLBACK
    SCLASS_FALLBACK
  ].freeze

  # RUNTIME_DEF_DEVIRT_GUARD, second line of defense: re-read the FINISHED text of
  # the method and turn any static bind of a blocked name into `#error` (so
  # SKIP_UNSUPPORTED drops the method). Reading the emitted text cannot drift
  # from what codegen did, so a path that bypasses devirt_blocked_name? is still
  # caught. Returns "" for methods that install nothing.
  def runtime_def_devirt_audit(code)
    return '' unless @runtime_installed_names

    # `/` is part of the kind (`IVAR_ACCESSOR/ELEMENT`); stopping at it would skip
    # the line. Compound kinds are not in RUNTIME_DEF_DYNAMIC_MARKERS, so they are
    # audited.
    offenders = code.scan(%r{^\s*// ([A-Z][A-Z_0-9/]*) :(\S+?)(?:\s|,|$)}).reject do |kind, _name|
      RUNTIME_DEF_DYNAMIC_MARKERS.include?(kind)
    end.select { |_kind, name| devirt_blocked_name?(name) }
    return '' if offenders.empty?

    offenders.uniq.map do |kind, name|
      "  #error #{kind} devirtualization of :#{name}, which this method installs on a runtime " \
        "singleton class -- not in this prototype's supported subset\n"
    end.join
  end

  def sdef_fallback_region(insn, irep)
    runtime_def_region(insn, irep, 'sdef_fallback')
  end

  # RUNTIME_DEF_FALLBACK_SUPPORT: the install for SDEF and TDEF.
  # `mrb_define_method_id(M, tc, mid, fn, MRB_ARGS_REQ(n))` is equivalent to
  # OP_SDEF/OP_TDEF (checked against src/class.c mrb_define_method_raw):
  #   * Visibility: the VM passes MRB_METHOD_VDEFAULT_FL, this passes PUBLIC.
  #     mrb_define_method_raw's first branch is `if (c->tt == MRB_TT_SCLASS)
  #     MRB_SET_VISIBILITY_FLAGS(flags, MRB_METHOD_PUBLIC_FL);`, and every
  #     target here is a singleton class (SDEF by definition; TDEF only from an
  #     SCLASS body). A TDEF in a plain `class Foo` body would consult the
  #     `private`/`public` scope, one reason EXEC support is SCLASS-only.
  #   * initialize/initialize_copy/respond_to_missing? are forced private by
  #     mrb_define_method_raw on both paths.
  #   * Arity: MRB_ARGS_REQ(n) matches the entry's `mrb_get_args(M, "o"*n)`;
  #     runtime_def_body_safe? refused anything else.
  # The method_added hook: OP_SDEF/OP_TDEF call mrb_method_added, which is not
  # MRB_API (internal.h), so its SCLASS arm is reproduced with public API:
  #
  #   added = (c->tt == MRB_TT_SCLASS) ? singleton_method_added : method_added;
  #   recv  = (c->tt == MRB_TT_SCLASS) ? mrb_iv_get(.., c, __attached__) : c;
  #   if (!mrb_func_basic_p(mrb, recv, added, mrb_do_nothing))
  #     mrb_funcall_argv(mrb, recv, added, 1, &sym);
  #
  # The mrb_func_basic_p guard is dropped: it only skips a call to
  # mrb_do_nothing (`{ return mrb_nil_value(); }`, the default
  # BasicObject#singleton_method_added), so calling it anyway gives the same
  # state, and an overridden hook is invoked as the interpreter would.
  # mrb_funcall_argv does no visibility check, which matters because the hooks
  # are MRB_MT_PRIVATE.
  # Inherent difference: the installed body is a cfunc, not a bytecode RProc (as
  # for every compiled method).
  def emit_runtime_def_install(target_class_expr, region, fn_name, indent)
    tc_var = "bc2cpp_def_tc_#{region[:block_addr]}"
    mid_var = "bc2cpp_def_mid_#{region[:block_addr]}"
    sym_var = "bc2cpp_def_sym_#{region[:block_addr]}"
    out = String.new
    # Bound to a local: the expression may have a side effect
    # (mrb_singleton_class creates the singleton class), and the hook needs the
    # same class.
    out << "#{indent}struct RClass* #{tc_var} = #{target_class_expr};\n"
    out << "#{indent}mrb_sym #{mid_var} = mrb_intern_cstr(M, \"#{region[:name]}\");\n"
    out << "#{indent}mrb_define_method_id(M, #{tc_var}, #{mid_var}, #{fn_name}, " \
           "MRB_ARGS_REQ(#{region[:mand]}));\n"
    out << "#{indent}mrb_value #{sym_var} = mrb_symbol_value(#{mid_var});\n"
    out << "#{indent}mrb_funcall_argv(M, mrb_iv_get(M, mrb_obj_value(#{tc_var}), " \
           "mrb_intern_cstr(M, \"__attached__\")), mrb_intern_cstr(M, \"singleton_method_added\"), " \
           "1, &#{sym_var});\n"
    # Both opcodes leave the method name Symbol in `a` (vm.c `regs[a] =
    # mrb_symbol_value(mid);`), written after the hook as vm.c does. It is skipped
    # only when `a` is at or beyond the enclosing irep's nregs, which mrbc really
    # emits for a class body whose only statement is a def:
    #
    #   irep ... nregs=1 nlocals=1 pools=0 syms=1 reps=1 ilen=6
    #     000 TDEF  R1  :who  I[0]
    #     004 RETURN  R0
    #
    # The interpreter has slack from OP_EXEC's stack_extend, but compiled code
    # declares exactly nregs locals (writing R1 would not compile). Lossless:
    # nregs bounds every register the irep can read.
    if region[:dest_reg] < region[:enclosing_nregs].to_i
      out << "#{indent}r#{region[:dest_reg]} = #{sym_var};\n"
    else
      out << "#{indent}(void)#{sym_var}; // R#{region[:dest_reg]} is past the enclosing irep's " \
             "nregs=#{region[:enclosing_nregs]} -- dead by construction, see above\n"
    end
    out
  end

  # SDEF_FALLBACK: `def archive.read(name); ...; end` installs on one object's
  # singleton class. vm.c OP_SDEF: `struct RClass *tc =
  # mrb_class_ptr(mrb_singleton_class(mrb, regs[a]));` then install.
  # mrb_singleton_class (public) raises TypeError for objects that cannot have
  # one (Integer, Symbol, Float), so it is used rather than the non-raising
  # _ptr variant. No class body, RProc or VM frame is involved.
  def emit_sdef_fallback_glue(region, fn_name)
    out = String.new
    out << "  // SDEF_FALLBACK :#{region[:name]} -- singleton method body compiled as a standalone cfunc, " \
           "installed on the receiver's real runtime singleton class\n"
    out << "  {\n"
    out << emit_runtime_def_install("mrb_class_ptr(mrb_singleton_class(M, r#{region[:dest_reg]}))",
                                     region, fn_name, '    ')
    out << "  }\n"
    out
  end

  # TDEF_FALLBACK: a def in an EXEC-opened class body. OP_TDEF installs onto
  # check_target_class(mrb), which in an OP_EXEC body is the same object as self
  # (see emit_proc_fallback_fn's self_source), so mrb_class_ptr(self) is exact.
  # check_target_class's NULL case cannot occur: emit_exec_fallback_glue sets the
  # target class.
  def emit_tdef_fallback_glue(region, fn_name)
    out = String.new
    out << "  // TDEF_FALLBACK :#{region[:name]} -- `def` inside a class-reopen body, compiled as a standalone " \
           "cfunc, installed on this body's own target class (== self, per OP_EXEC)\n"
    out << "  {\n"
    out << emit_runtime_def_install('mrb_class_ptr(self)', region, fn_name, '    ')
    out << "  }\n"
    out
  end

  # SCLASS_FALLBACK + EXEC_FALLBACK: `class << Graphics; alias_method
  # :_probe_update, :update; def update; ...; end; end` inside a method body
  # (RGSS.singleton#effect_probe). Only `SCLASS Ra` immediately followed by `EXEC
  # Ra I[c]` on the same register (codegen.c's NODE_SCLASS arm).
  # Not CLASS/MODULE+EXEC: a TDEF there resolves visibility against the
  # enclosing scope (not reproduced by the public install), and CLASS/MODULE
  # create a constant the registry cannot learn about. Neither occurs here.
  # The body is compiled by emit_proc_fallback_fn, so sends (alias_method,
  # attr_*, include, private, ...), nested blocks and rescue regions work as in
  # a block body; `def` is added by its TDEF pass.
  def recognize_exec_fallback_regions(irep)
    regions = []
    irep.instructions.each_with_index do |insn, idx|
      next unless insn.op == 'SCLASS'

      nxt = irep.instructions[idx + 1]
      next unless nxt && nxt.op == 'EXEC'

      reg = insn.args[/\AR(\d+)\z/, 1]
      m = nxt.args.match(/\AR(\d+)\s+I\[(\d+)\]\z/)
      next unless reg && m && m[1] == reg

      child_label = irep.reps[m[2].to_i]
      next unless child_label

      child = @ireps[child_label]
      next unless child

      regions << { block_irep: child, block_addr: insn.addr, exec_addr: nxt.addr,
                   kind: 'exec_fallback', self_source: :receiver, dest_reg: reg.to_i }
    end
    regions
  end

  # SCLASS_FALLBACK + EXEC_FALLBACK glue, translated together:
  #   OP_SCLASS: `regs[a] = mrb_singleton_class(mrb, regs[a]);`, verbatim.
  #   OP_EXEC: run the body with target class and self set to that singleton
  #   class. mrb_yield_with_class (public) does exactly that: yield_with_attr
  #   sets `ci->u.target_class = c; ci->proc = p;` and, for a cfunc proc,
  #   `ci->stack[0] = self; val = MRB_PROC_CFUNC(p)(mrb, self);`. Pushing a real
  #   frame is what makes `private`/`public`/`module_function` in the body see
  #   the right scope (class.c find_visibility_scope reads
  #   mrb_vm_ci_target_class(ci)).
  # MRB_PROC_SCOPE needs no analogue: check_visibility_break treats a SCOPE proc
  # and a proc with no `upper` alike (cfunc procs have none), and OP_RETURN's
  # scope unwinding has no bytecode frame here. mrb_yield_with_class returns the
  # body's value, which is EXEC's result.
  def emit_exec_fallback_glue(region, fn_name)
    dest_reg = region[:dest_reg]
    sc_var = "bc2cpp_sclass_#{region[:block_addr]}"
    proc_var = "bc2cpp_exec_proc_#{region[:block_addr]}"
    out = String.new
    out << "  // SCLASS_FALLBACK + EXEC_FALLBACK -- `class << recv` body compiled as a standalone cfunc, " \
           "executed against the real runtime singleton class (self == target class, per OP_EXEC)\n"
    out << "  {\n"
    out << "    mrb_value #{sc_var} = mrb_singleton_class(M, r#{dest_reg});\n"
    out << "    struct RProc* #{proc_var} = mrb_proc_new_cfunc(M, #{fn_name});\n"
    out << "    r#{dest_reg} = mrb_yield_with_class(M, mrb_obj_value(#{proc_var}), 0, NULL, " \
           "#{sc_var}, mrb_class_ptr(#{sc_var}));\n"
    out << "  }\n"
    out
  end
end
