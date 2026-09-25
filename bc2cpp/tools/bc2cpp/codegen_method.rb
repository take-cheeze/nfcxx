# frozen_string_literal: true

# CodeGen: compile_method and jump targets.

class CodeGen
  # One inlined-loop kind (ADR 0152): `recognize`/`emit` are CodeGen methods,
  # `anchor` is the region key the glue lands at (with :sendb_addr, the
  # addresses claimed and checked against the rescue range), and `context`
  # says the recognizer takes (owner, mand, ivar layout, annotated args).
  InlineLoopPass = Struct.new(:recognize, :emit, :anchor, :context)

  # The order is part of the output: emitters append nested cfunc code
  # (@inline_nested_pre) in pass order, and a later pass would overwrite an
  # earlier one's glue at a shared address (the recognizers' receiver and
  # method-name gates keep regions disjoint). Every pass skips rescue-claimed
  # regions (#1909, RESCUE_INLINE_BLOCK_FIX in compile_method).
  INLINE_LOOP_PASSES = [
    InlineLoopPass.new(:recognize_times_regions, :emit_times_inline, :block_addr, false), # BLOCK_SUPPORT
    InlineLoopPass.new(:recognize_each_regions, :emit_each_inline, :block_addr, true), # EACH_BLOCK_SUPPORT
    InlineLoopPass.new(:recognize_each_index_regions, :emit_each_index_inline, :block_addr, true), # EACH_INDEX_SUPPORT
    InlineLoopPass.new(:recognize_hash_each_regions, :emit_hash_each_inline, :block_addr, true), # HASH_EACH_SUPPORT
    InlineLoopPass.new(:recognize_hash_each_value_regions, :emit_hash_each_value_inline, :block_addr, true),
    InlineLoopPass.new(:recognize_each_key_regions, :emit_each_key_inline, :block_addr, true), # EACH_KEY_SUPPORT
    InlineLoopPass.new(:recognize_range_each_regions, :emit_range_each_inline, :block_addr, true), # INTERP_UNLOCK
    # `&:sym` has no BLOCK instruction; its glue replaces the symbol load.
    InlineLoopPass.new(:recognize_sym_regions, :emit_sym_inline, :sym_addr, true), # EACH_BLOCK_SUPPORT
    InlineLoopPass.new(:recognize_collect_regions, :emit_collect_inline, :block_addr, true), # MAP_BLOCK_SUPPORT
    InlineLoopPass.new(:recognize_accum_regions, :emit_accum_inline, :block_addr, true), # ACCUM_BLOCK_SUPPORT
    # PROFILER_SECTION_SUPPORT: `RGSS::Profiler.section("n") { ... }` /
    # `Profiler.frame { ... }` -- a native block-taking method, not a loop, but
    # the same BLOCK+block-send shape and the same suppress-and-glue mechanism.
    # Placed before recognize_sort_regions: its gate is a literal receiver path
    # plus a literal name, so the two cannot claim the same site, and keeping the
    # passes in a fixed order is what the emitters' shared nested-pre buffer
    # depends on.
    InlineLoopPass.new(:recognize_profiler_section_regions, :emit_profiler_section_inline, :block_addr, false),
    InlineLoopPass.new(:recognize_sort_regions, :emit_sort_inline, :block_addr, true) # SORT_BLOCK_SUPPORT
  ].freeze

  def compile_method(label)
    irep = @ireps.fetch(label)
    d = @owner_of.fetch(label)
    enter = irep.instructions.find { |i| i.op == 'ENTER' }
    mand = enter ? enter.args.split(':').first.to_i : 0

    # RUNTIME_DEF_DEVIRT_GUARD: cleared at the single entry point so no early
    # return can leak one method's blocked-name set into the next compile.
    @runtime_installed_names = nil

    # EXCEPTION_RETURN_SUPPORT: computed early (a pure function of `irep`) so the
    # function body can be wrapped in the try/catch a RETURN_BLK thrown from a
    # region needs; the same list is reused by the region loop below.
    # BLOCK_FALLBACK_YIELD_SUPPORT: `blk_available` is the same condition as
    # `mandatory_ok` below, so a region is never marked `needs_blk` for a method
    # whose wrapper will not extract `bc2cpp_blk`.
    block_fallback_regions = recognize_block_fallback_regions(irep, blk_available: pure_mandatory_arity?(irep))
    # NESTED_BLOCK_FALLBACK_SUPPORT: a RETURN_BLK nested at any depth throws
    # bc2cpp_method_return out to this same top-level catch (the per-call-site
    # catches only match bc2cpp_block_break), so search regions recursively.
    needs_return_catch = block_fallback_regions.any? { |region| block_fallback_region_has_return_blk?(region) }

    # OPTIONAL_ARG_SUPPORT: `opt` > 0 only for the recognized optional-only shape
    # (see optional_arg_table); other non-mandatory shapes get the `#error` stub.
    # `mandatory_ok` skips that scan in the common case.
    mandatory_ok = pure_mandatory_arity?(irep)
    # BLKPUSH_YIELD_SUPPORT: a bare `yield` (BLKCALL) needs the call's block
    # fetched by `BLKPUSH R7 2:0:0:0 (0)`. Only lv == 0 (vm.c OP_BLKPUSH: `if (lv
    # == 0) stack = regs + 1`, this frame's block) is modelled, and only for
    # mandatory_ok methods, so the opt/kw/rest wrapper branches are unaffected.
    # BLOCK_FALLBACK_YIELD_SUPPORT: the same parameter also supplies a block
    # forwarded from inside a BLOCK_FALLBACK body (`BLKPUSH R4 0:0:0:0 (1)` in
    # LCF::Array2D#each), found by block_fallback_regions and read by
    # emit_rproc_construction. Both stay gated on mandatory_ok, so this is
    # exclusive with `has_blk`.
    needs_blk_param = mandatory_ok &&
                      (irep.instructions.any? { |i| i.op == 'BLKPUSH' && i.args[/\((\d+)\)/, 1] == '0' } ||
                       block_fallback_regions.any? { |r| r[:needs_blk] })
    opt, opt_jmp_addrs, opt_jmp_targets = mandatory_ok ? [0, nil, nil] : optional_arg_table(irep)
    # KEYWORD_ARG_SUPPORT / OPTIONAL_KEYWORD_COMBINED_SUPPORT: tried whenever
    # mandatory_ok is false, whether or not the optional table resolved (the
    # KEY_P/KARG scan is whole-irep).
    kw_table = mandatory_ok ? nil : keyword_arg_table(irep)
    # Each of `opt` (jump table) and `kw` must resolve or the whole method is
    # unsupported. Either failure also clears `opt_jmp_targets`, the flag
    # `supported` trusts; otherwise a recognized optional shape with an
    # unrecognized keyword shape would compile with its keywords dropped.
    enter_kw = enter ? enter.args.split(':').map { |f| f[/\d+/].to_i }[4] : 0
    if (opt.positive? && !opt_jmp_targets) || (enter_kw.positive? && !kw_table)
      opt_jmp_targets = nil
      kw_table = nil
    end
    # REST_ARG_SUPPORT: one more contiguous `total_args` slot (see
    # rest_only_arity?).
    # REST_BLOCK_COMBINED_SUPPORT: `has_rest` and `has_blk` can both hold (`def
    # method_missing(name, *args, &block)`); both are exclusive with
    # mandatory_ok/opt_jmp_targets/kw_table, whose predicates require rest and
    # block to be zero.
    has_rest = (mandatory_ok || opt_jmp_targets || kw_table) ? false : rest_only_arity?(irep)
    has_blk = (mandatory_ok || opt_jmp_targets || kw_table) ? false : block_param_arity?(irep)
    supported = mandatory_ok || opt_jmp_targets || kw_table || has_rest || has_blk

    total_args = supported ? mand + opt + (has_rest ? 1 : 0) : mand
    arg_names = irep.lv.first(total_args).each_with_index.map { |n, i| n ? sanitize_c_ident(n) : "arg#{i + 1}" }
    # NATIVE_ARG_TARGETS per-position types (see native_arg_types). Optional
    # positions are never retyped; the padding is explicit.
    arg_native_types = native_arg_types(d, mand) + Array.new(total_args - mand)

    impl_name = "#{cpp_name(d.owner, d.name)}_impl"
    entry_name = cpp_name(d.owner, d.name)
    embedded_ivars = @ivar_layout[d.owner]

    unless supported
      # Not modelled: emit `#error` rather than a signature that disagrees with what
      # callers pass.
      code = "// #{d.owner}##{d.name} (compiled from irep #{label}, #{irep.instructions.size} insns)\n" \
             "#error #{d.owner}##{d.name} has non-mandatory arguments (optional/rest/keyword/block) -- not in this prototype's supported subset\n\n"
      return { label: label, owner: d.owner, name: d.name, entry: entry_name, impl: impl_name,
               arity: arg_names.size, code: code, unsupported: true, visibility: d.visibility }
    end

    if calls_fiber_yield?(irep) || @fiber_unsafe_methods.include?(label)
      # FIBER_YIELD_UNSAFE_SUPPORT / FIBER_REACHABILITY_UNSAFE_SUPPORT: never compile
      # a method that calls Fiber.yield or is reachable from a Fiber.new block (see
      # those methods).
      reason = calls_fiber_yield?(irep) ? 'calls Fiber.yield directly' : 'is reachable from a Fiber.new block'
      code = "// #{d.owner}##{d.name} (compiled from irep #{label}, #{irep.instructions.size} insns)\n" \
             "#error #{d.owner}##{d.name} #{reason} -- not in this prototype's supported subset\n\n"
      return { label: label, owner: d.owner, name: d.name, entry: entry_name, impl: impl_name,
               arity: arg_names.size, code: code, unsupported: true, visibility: d.visibility }
    end

    out = String.new
    out << "// #{d.owner}##{d.name} (compiled from irep #{label}, #{irep.instructions.size} insns)\n"
    # Not `static`: another gem's generated code may call it (OTHER_DECLS_HEADER;
    # see emit_decls_header).
    # Mandatory parameter types come from arg_native_types; `self` is never
    # retyped.
    arg_params = arg_names.each_with_index.map { |a, i| "#{native_c_type(arg_native_types[i])} #{a}" }
    # BLKPUSH_YIELD_SUPPORT / EXPLICIT_BLOCK_PARAM_SUPPORT: one extra parameter,
    # the call's block (Proc or nil), extracted by the wrapper with mrb_get_args
    # `&`. BLKPUSH reads it directly; `&blk` stores it into register mand+1 below.
    # Never both for one method (needs_blk_param requires ENTER's block field to
    # be zero, has_blk requires it non-zero).
    arg_params << 'mrb_value bc2cpp_blk' if needs_blk_param || has_blk
    # OPTIONAL_ARG_SUPPORT: `bc2cpp_given_opt`, how many optionals this call
    # supplied (0..opt), read by emit_optional_dispatch's switch. Unsupplied
    # slots still get a placeholder argument.
    arg_params << 'mrb_int bc2cpp_given_opt' if opt.positive?
    # KEYWORD_ARG_SUPPORT: one mrb_value per keyword, plus an mrb_int "given" flag
    # per optional keyword (mrb_get_args already raises for a missing required
    # one). Bytecode declaration order, matching the wrapper.
    kw_table&.each do |kw|
      arg_params << "mrb_value #{kwarg_param_name(kw[:name])}"
      arg_params << "mrb_int #{kw_given_param_name(kw[:name])}" unless kw[:required]
    end
    out << "mrb_value #{impl_name}(mrb_state* M, #{(['mrb_value self'] + arg_params).join(', ')}) {\n"
    # EXCEPTION_RETURN_SUPPORT: wrap the body in one try/catch only when a
    # BLOCK_FALLBACK region can throw bc2cpp_method_return. Cheap under zero-cost
    # exceptions but not free, hence the gate. Statements inside the `try` behave
    # the same; only a throw changes control flow.
    out << "  Bc2cppVmMark bc2cpp_ret_mark = bc2cpp_vm_mark(M);\n  try {\n" if needs_return_catch
    (0...irep.nregs).each { |i| out << "  mrb_value r#{i}" << (i.zero? ? ' = self;' : ' = mrb_nil_value();') << "\n" }
    # A native-typed argument's register is still an mrb_value (NATIVE_ARG_TARGETS
    # moves the coercion, it does not specialize registers), so box it with
    # TYPE_OPS[:box] on entry.
    arg_names.each_with_index do |a, i|
      t = arg_native_types[i]
      out << if t
                "  r#{i + 1} = #{TYPE_OPS.fetch(t)[:box]}(#{a});\n"
              else
                "  r#{i + 1} = #{a};\n"
              end
    end
    # EXPLICIT_BLOCK_PARAM_SUPPORT: store the block into its register once, where
    # ENTER would put it: mand+1, or mand+rest+1 with a rest parameter (ENTER
    # 1:0:1:0:0:0:1:0 puts it in R3); `total_args + 1` covers both. The following
    # MOVE etc. is ordinary bytecode.
    out << "  r#{total_args + 1} = bc2cpp_blk;\n" if has_blk
    if embedded_ivars && d.name == 'initialize'
      # At the start of #initialize self is a bare MRB_TT_DATA shell (data == NULL):
      # allocate the struct before any embedded SETIV.
      sname = struct_name(d.owner)
      out << "  {\n"
      out << "    #{sname}* embedded = (#{sname}*)mrb_calloc(M, 1, sizeof(#{sname}));\n"
      out << "    mrb_data_init(self, embedded, &#{type_var(d.owner)});\n"
      out << "  }\n"
    end
    # Goto-threaded control flow: every JMP/JMPNOT/JMPIF target gets a C label and
    # jumps become `goto`, reproducing any control flow without rebuilding a CFG.
    # All registers are declared before any label, so no goto skips an
    # initialization.
    # RESCUE_SUPPORT: each recognized region (recognize_rescue_regions) gets an
    # extracted try-body function, emitted ahead of this one. Its [begin_addr,
    # end_addr] range and the EXCEPT address are skipped here; emit_rescue_glue
    # emits the mrb_protect_error call and early-out at begin_addr and folds
    # EXCEPT's capture into its last line. Everything else continues through the
    # normal loop.
    rescue_regions = top_level_rescue_regions(recognize_rescue_regions(irep))
    rescue_pre = String.new
    suppressed = Set.new
    glue_at = {}

    # RUNTIME_DEF_DEVIRT_GUARD: set before any code is emitted, since every nested
    # fallback body and the main loop reach compile_send through this ivar. nil
    # (no SDEF and no SCLASS+EXEC) makes devirt_blocked_name? always false;
    # :unknown blocks devirtualization of every name in this method.
    # recognize_exec_fallback_regions is pure and is simply called again later.
    if irep.instructions.any? { |i| i.op == 'SDEF' } || !recognize_exec_fallback_regions(irep).empty?
      @runtime_installed_names =
        runtime_installed_names_for(irep, recognize_exec_fallback_regions(irep)) || :unknown
    end

    # OPTIONAL_ARG_SUPPORT: replace the ENTER jump table with a `switch` on
    # `bc2cpp_given_opt` (suppressed/glue_at mechanism); default-value code is
    # untouched and reached by goto, like OP_ENTER's PC skip.
    if opt.positive? && opt_jmp_targets
      opt_jmp_addrs.each { |a| suppressed << a }
      glue_at[opt_jmp_addrs.first] = emit_optional_dispatch(opt_jmp_targets)
    end

    rescue_regions.each_with_index do |region, i|
      suppressed.merge((region[:begin_addr]..region[:end_addr]).to_a)
      suppressed << region[:except_addr]
      try_name = "#{impl_name}_rescue_try#{rescue_regions.size > 1 ? "_#{i}" : ''}"
      saved = rescue_entry_saved_fields(irep, region)
      rescue_pre << emit_rescue_try_body(try_name, region, irep, d, arg_names, arg_native_types, extra_fields: saved)
      glue_at[region[:begin_addr]] = emit_rescue_glue(try_name, region, arg_names, arg_native_types,
                                                      extra_field_values: saved.map { |f| f[:name].sub('bc2cpp_saved_', '') })
    end

    # BLOCK_SUPPORT: each INLINE_LOOP_PASSES region replaces its anchor and SENDB
    # with one inlined loop at the anchor. A failed gate or an unclean body (nil)
    # leaves both to the normal loop, which emits `#error`.
    # INLINE_NESTED_BLOCK_SUPPORT: file-scope code for cfuncs backing blocks nested
    # inside inlined loops (inline_nested_block_pass). It must land at file scope
    # ahead of this function, like block_fallback_pre/rescue_pre. Saved and
    # restored (not just cleared) because compile_method can be re-entered from
    # the emitter loops via compiles_clean?/compile_send, and the inner call must
    # not drop the outer one's code.
    bc2cpp_saved_inline_pre = @inline_nested_pre
    @inline_nested_pre = String.new
    # RESCUE_INLINE_BLOCK_FIX: the inlined-loop passes below must skip regions
    # whose addresses the rescue loop above already claimed. That range lives in
    # the extracted try body; here, a loop registered at its block_addr would be
    # emitted after the rescue glue, on the exception-only path, with its receiver
    # register holding whatever that path left (possibly the exception), not the
    # value the recognizer proved (scripts/bc2cpp_rescue_inline_block_check.rb).
    rescue_claimed = suppressed.dup
    each_ctx_ivar = @class_layout[d.owner]
    each_ctx_args = @class_annotations[irep.label]&.args
    INLINE_LOOP_PASSES.each do |pass|
      ctx = pass.context ? [d.owner, mand, each_ctx_ivar, each_ctx_args] : []
      send(pass.recognize, irep, *ctx).each do |region|
        anchor = region[pass.anchor]
        next if rescue_claimed.include?(anchor) || rescue_claimed.include?(region[:sendb_addr])

        inlined = send(pass.emit, region, irep, d)
        next unless inlined

        suppressed << anchor << region[:sendb_addr]
        glue_at[anchor] = inlined
      end
    end

    # BLOCK_CFUNC_FALLBACK_SUPPORT: the catch-all, run last, for BLOCK/SENDB pairs
    # no named inliner claimed (checked via `suppressed`). A qualifying region
    # (see block_fallback_safe?) gets a standalone cfunc (emit_proc_fallback_fn)
    # plus glue that builds an RProc and dispatches dynamically.
    # EXPLICIT_BLOCK_ARG_SUPPORT: `&expr` has no BLOCK instruction, so only
    # sendb_addr is suppressed.
    # RESCUE_BODY_BLOCK_SUPPORT: shared with emit_rescue_try_body (see
    # emit_block_fallback_glue_pass).
    block_fallback_pre = emit_block_fallback_glue_pass(block_fallback_regions, recognize_explicit_block_arg_regions(irep),
                                                        d, suppressed, glue_at)

    # LAMBDA_FALLBACK_SUPPORT: like BLOCK_CFUNC_FALLBACK_SUPPORT, but the RProc is
    # stored into the destination register with no dispatch
    # (emit_lambda_fallback_glue). LAMBDA is disjoint from BLOCK/SENDB, so the
    # order and the `suppressed` check are defensive only. See
    # lambda_fallback_safe? for why RETURN_BLK/BREAK are allowed.
    recognize_lambda_fallback_regions(irep).each do |region|
      next if suppressed.include?(region[:block_addr])

      fn_result = emit_proc_fallback_fn(region, d)
      next unless fn_result

      fn_name, fn_code = fn_result
      block_fallback_pre << fn_code
      suppressed << region[:block_addr]
      glue_at[region[:block_addr]] = emit_lambda_fallback_glue(region, fn_name)
      # CONFINED_LAMBDA_UPVAR_SUPPORT: replace this lambda's proven `.call` sites
      # with direct calls to the emitted body; this is required, not an
      # optimization (see emit_lambda_confined_call_glue). Escaping lambdas claim
      # nothing.
      region[:call_sites].each do |site|
        next if suppressed.include?(site[:send_addr])

        suppressed << site[:send_addr]
        glue_at[site[:send_addr]] = emit_lambda_confined_call_glue(region, fn_name, site)
      end
    end

    # RUNTIME_DEF_FALLBACK_SUPPORT: SDEF and SCLASS+EXEC fallbacks, same
    # suppressed/glue_at mechanism and emit_proc_fallback_fn; nil keeps the
    # `#error`. Disjoint opcodes, so order is convention only. SDEF first: one
    # method onto one singleton class, no class body (see
    # emit_sdef_fallback_glue).
    irep.instructions.each do |insn|
      next unless insn.op == 'SDEF'
      next if suppressed.include?(insn.addr)

      region = sdef_fallback_region(insn, irep)
      next unless region

      fn_result = emit_proc_fallback_fn(region, d)
      next unless fn_result

      fn_name, fn_code = fn_result
      block_fallback_pre << fn_code
      suppressed << insn.addr
      glue_at[insn.addr] = emit_sdef_fallback_glue(region, fn_name)
    end

    # SCLASS+EXEC: `block_addr` is the SCLASS (where the replacement starts, so it
    # keeps any label; see JUMP_TARGET_GLUE_FIX) and the EXEC is suppressed with no
    # glue, like a BLOCK_FALLBACK sendb_addr.
    recognize_exec_fallback_regions(irep).each do |region|
      next if suppressed.include?(region[:block_addr]) || suppressed.include?(region[:exec_addr])

      fn_result = emit_proc_fallback_fn(region, d)
      next unless fn_result

      fn_name, fn_code = fn_result
      block_fallback_pre << fn_code
      suppressed << region[:block_addr] << region[:exec_addr]
      glue_at[region[:block_addr]] = emit_exec_fallback_glue(region, fn_name)
    end

    # JUMP_TARGET_GLUE_FIX: only drop labels for suppressed addresses WITHOUT
    # replacement code. A suppressed block_addr with glue_at code can be a real
    # jump target (`(h[:x] || {}).each { }`: the `||` JMPIF lands on the BLOCK),
    # and dropping its label left `goto L68;` with no `L68:;`, a g++ error that no
    # `#error` check catches. Only the interior of a suppressed range (e.g. a
    # rescue region minus its begin_addr) loses its label.
    targets = jump_targets(irep) - (suppressed - glue_at.keys)
    # BLKPUSH_YIELD_SUPPORT: set for this method's top-level loop only (cleared
    # after). emit_proc_fallback_fn manages its own value.
    @blk_param_name = needs_blk_param ? 'bc2cpp_blk' : nil
    # BLOCK_FALLBACK_YIELD_SUPPORT: in a METHOD body only lv == 0 can be answered
    # (vm.c `if (lv == 0) stack = regs + 1`). codegen_yield stops at the first
    # method scope, so a method's own yield is always level 0.
    @blk_param_level = 0
    # ENSURE_RAII_SUPPORT: an ensure needs code emitted AROUND instructions: the
    # guard and `{` before the protected range's first instruction, and `}`
    # before the handler (the `}` runs the ensure body via the guard's
    # destructor). glue_at REPLACES an address's code, so `prefix_at` is emitted
    # ahead of the suppression check and the label.
    prefix_at = {}
    ensure_region = recognize_ensure_region(irep)
    if ensure_region
      open_glue, ok = emit_ensure_guard(ensure_region, irep, d)
      if ok
        prefix_at[ensure_region[:begin_addr]] = open_glue
        prefix_at[ensure_region[:except_addr]] = "  } // ensure guard leaves scope: runs the ensure body\n"
        # ENSURE_DISPATCH_MERGE_SUPPORT: jumps landing exactly on the handler address
        # (see recognize_ensure_region) become `goto L<raiseif_addr>`: leave the guard
        # scope (running the ensure body) and continue past the folded handler. The
        # remap is keyed on this irep object, so a nested block's irep with the same
        # numeric address is unaffected. The label is emitted as a prefix at the
        # RAISEIF address because the suppressed handler range skips the normal label.
        # Jumping OUT of a scope with goto is legal and runs the destructor.
        unless ensure_region[:except_jump_srcs].empty?
          prefix_at[ensure_region[:raiseif_addr]] = "  L#{ensure_region[:raiseif_addr]}:;\n"
          @ensure_except_remaps = { irep => { ensure_region[:except_addr] => ensure_region[:raiseif_addr] } }
        end
        # EXCEPT, the ensure body, and the terminating RAISEIF are all
        # folded into the guard above -- none of them is emitted inline.
        suppressed.merge((ensure_region[:except_addr]..ensure_region[:raiseif_addr]).to_a)
        targets -= (ensure_region[:except_addr]..ensure_region[:raiseif_addr]).to_a
      end
    end
    irep.instructions.each_with_index do |insn, idx|
      out << prefix_at[insn.addr] if prefix_at.key?(insn.addr)
      next if suppressed.include?(insn.addr) && !glue_at.key?(insn.addr)

      out << "  L#{insn.addr}:;\n" if targets.include?(insn.addr)
      out << (glue_at[insn.addr] || compile_insn(insn, irep, d, idx))
    end
    @blk_param_name = nil
    @ensure_except_remaps = nil
    out << "  return mrb_nil_value(); // unreachable if every path RETURNs\n"
    if needs_return_catch
      out << "  } catch (bc2cpp_method_return& bc2cpp_ret) {\n"
      out << "    bc2cpp_vm_restore(M, bc2cpp_ret_mark);\n"
      out << "    return bc2cpp_ret.value;\n"
      out << "  }\n"
    end
    out << "}\n\n"
    # INLINE_NESTED_BLOCK_SUPPORT: `@inline_nested_pre` goes first so a nested
    # block's cfunc is defined before the loop that uses it.
    out = @inline_nested_pre + block_fallback_pre + rescue_pre + out
    @inline_nested_pre = bc2cpp_saved_inline_pre
    out << runtime_def_devirt_audit(out)
    @runtime_installed_names = nil

    out << "static mrb_value #{entry_name}(mrb_state* M, mrb_value self) {\n"
    if arg_names.empty? && !kw_table && !needs_blk_param && !has_blk
      out << "  return #{impl_name}(M, self);\n"
    elsif arg_names.empty? && (needs_blk_param || has_blk)
      # BLKPUSH_YIELD_SUPPORT/EXPLICIT_BLOCK_PARAM_SUPPORT with zero mandatory
      # arguments: a standalone mrb_get_args("&") call.
      out << "  mrb_value bc2cpp_blk = mrb_nil_value();\n"
      out << "  mrb_get_args(M, \"&\", &bc2cpp_blk);\n"
      out << "  return #{impl_name}(M, self, bc2cpp_blk);\n"
    elsif kw_table
      # KEYWORD_ARG_SUPPORT: mrb_get_args ":" with mrb_kwargs (mruby.h). `required`
      # counts the leading required entries in `table`; an omitted optional keyword
      # comes back mrb_undef_p and is replaced by mrb_nil_value() below. `rest:
      # NULL` makes an unknown keyword raise ArgumentError here, which KEYEND relies
      # on. Positional arguments are unpacked as in the plain case.
      # OPTIONAL_KEYWORD_COMBINED_SUPPORT: with opt > 0, optional positions get the
      # same mrb_nil_value() default and `|` marker as the plain optional branch;
      # `|` and `:` are independent mrb_get_args markers.
      arg_names.each_with_index do |a, i|
        default = i >= mand ? ' = mrb_nil_value()' : ''
        out << "  #{native_c_type(arg_native_types[i])} #{a}#{default};\n"
      end
      required_kws = kw_table.select { |kw| kw[:required] }
      optional_kws = kw_table.reject { |kw| kw[:required] }
      ordered_kws = required_kws + optional_kws
      table_entries = ordered_kws.map { |kw| "mrb_intern_cstr(M, \"#{kw[:name]}\")" }.join(', ')
      out << "  mrb_sym bc2cpp_kw_table[#{ordered_kws.size}] = { #{table_entries} };\n"
      out << "  mrb_value bc2cpp_kw_values[#{ordered_kws.size}];\n"
      out << "  mrb_kwargs bc2cpp_kwargs = { #{ordered_kws.size}, #{required_kws.size}, " \
             "bc2cpp_kw_table, bc2cpp_kw_values, NULL };\n"
      fmt = arg_native_types.each_with_index.map do |t, i|
        ch = t == :fixnum ? 'i' : (t == :symbol ? 'n' : 'o')
        i == mand && opt.positive? ? "|#{ch}" : ch
      end.join + ':'
      ptrs = (arg_names.map { |a| "&#{a}" } + ['&bc2cpp_kwargs']).join(', ')
      out << "  mrb_get_args(M, \"#{fmt}\", #{ptrs});\n"
      ordered_kws.each_with_index do |kw, i|
        var = kwarg_param_name(kw[:name])
        if kw[:required]
          out << "  mrb_value #{var} = bc2cpp_kw_values[#{i}];\n"
        else
          out << "  mrb_value #{var} = mrb_undef_p(bc2cpp_kw_values[#{i}]) ? mrb_nil_value() : bc2cpp_kw_values[#{i}];\n"
          out << "  mrb_int #{kw_given_param_name(kw[:name])} = mrb_undef_p(bc2cpp_kw_values[#{i}]) ? 0 : 1;\n"
        end
      end
      call_args = arg_names.dup
      if opt.positive?
        # mrb_get_argc counts positional arguments only, independent of keywords.
        out << "  mrb_int bc2cpp_given_opt = mrb_get_argc(M) - #{mand};\n"
        out << "  if (bc2cpp_given_opt < 0) bc2cpp_given_opt = 0;\n"
        out << "  if (bc2cpp_given_opt > #{opt}) bc2cpp_given_opt = #{opt};\n"
        call_args << 'bc2cpp_given_opt'
      end
      call_args += kw_table.flat_map do |kw|
        kw[:required] ? [kwarg_param_name(kw[:name])] : [kwarg_param_name(kw[:name]), kw_given_param_name(kw[:name])]
      end
      out << "  return #{impl_name}(M, self, #{call_args.join(', ')});\n"
    elsif has_rest
      # REST_ARG_SUPPORT: mrb_get_args `*` returns a pointer into the live VM stack,
      # so copy it into an Array (mrb_ary_new_from_values) right away, matching the
      # Array the interpreter puts in the rest register.
      mand_names = arg_names.first(mand)
      rest_name = arg_names.last
      mand_names.each_with_index { |a, i| out << "  #{native_c_type(arg_native_types[i])} #{a};\n" }
      out << "  const mrb_value* bc2cpp_rest_ptr;\n"
      out << "  mrb_int bc2cpp_rest_len;\n"
      fmt = arg_native_types.first(mand).map { |t| t == :fixnum ? 'i' : (t == :symbol ? 'n' : 'o') }.join + '*'
      ptrs = (mand_names.map { |a| "&#{a}" } + ['&bc2cpp_rest_ptr', '&bc2cpp_rest_len']).join(', ')
      # REST_BLOCK_COMBINED_SUPPORT: `*` and `&` combine in one mrb_get_args call.
      if has_blk
        out << "  mrb_value bc2cpp_blk = mrb_nil_value();\n"
        fmt += '&'
        ptrs += ', &bc2cpp_blk'
      end
      out << "  mrb_get_args(M, \"#{fmt}\", #{ptrs});\n"
      out << "  mrb_value #{rest_name} = mrb_ary_new_from_values(M, bc2cpp_rest_len, bc2cpp_rest_ptr);\n"
      call_args = mand_names + [rest_name]
      call_args << 'bc2cpp_blk' if has_blk
      out << "  return #{impl_name}(M, self, #{call_args.join(', ')});\n"
    else
      # Each local's type must match what its mrb_get_args format character writes:
      # 'o' writes an mrb_value, 'i'/'n' (NATIVE_ARG_TARGETS) an mrb_int*/mrb_sym*
      # (src/class.c mrb_get_args). One declaration per argument, since types can
      # differ.
      # OPTIONAL_ARG_SUPPORT: optional positions start as mrb_nil_value(): `|` leaves
      # an omitted out-param untouched, and reading uninitialized memory would be UB
      # even though the default-value code overwrites it.
      arg_names.each_with_index do |a, i|
        default = i >= mand ? ' = mrb_nil_value()' : ''
        out << "  #{native_c_type(arg_native_types[i])} #{a}#{default};\n"
      end
      # 'i' is mrb_as_int, 'n' is mrb_obj_to_sym: the same coercions compile_send
      # applies at a devirtualized call site; keep them in lockstep. The `|` marker
      # goes at the mandatory/optional boundary.
      fmt = arg_native_types.each_with_index.map do |t, i|
        ch = t == :fixnum ? 'i' : (t == :symbol ? 'n' : 'o')
        i == mand && opt.positive? ? "|#{ch}" : ch
      end.join
      ptrs = arg_names.map { |a| "&#{a}" }.join(', ')
      # BLKPUSH_YIELD_SUPPORT: mrb_get_args `&` is this call's block (src/class.c
      # `case '&':`), nil when none (plain `&`, not `&!`), appended to the same call.
      # Neither needs_blk_param nor has_blk methods have optionals.
      if needs_blk_param || has_blk
        out << "  mrb_value bc2cpp_blk = mrb_nil_value();\n"
        fmt += '&'
        ptrs += ', &bc2cpp_blk'
      end
      out << "  mrb_get_args(M, \"#{fmt}\", #{ptrs});\n"
      if opt.positive?
        # OPTIONAL_ARG_SUPPORT: mrb_get_argc(M) - mand is the quantity OP_ENTER uses to
        # pick the jump-table entry. The clamp to [0, opt] is a formality
        # (mrb_get_args already raised for out-of-range counts).
        out << "  mrb_int bc2cpp_given_opt = mrb_get_argc(M) - #{mand};\n"
        out << "  if (bc2cpp_given_opt < 0) bc2cpp_given_opt = 0;\n"
        out << "  if (bc2cpp_given_opt > #{opt}) bc2cpp_given_opt = #{opt};\n"
        out << "  return #{impl_name}(M, self, #{arg_names.join(', ')}, bc2cpp_given_opt);\n"
      else
        call_args = (needs_blk_param || has_blk) ? arg_names + ['bc2cpp_blk'] : arg_names
        out << "  return #{impl_name}(M, self, #{call_args.join(', ')});\n"
      end
    end
    out << "}\n\n"
    # arg_c_types: the emitted per-position parameter types, read by decl_line so
    # every forward declaration (same gem or OTHER_DECLS_HEADER) matches.
    arg_c_types = arg_names.each_index.map { |i| native_c_type(arg_native_types[i]) }
    # BLKPUSH_YIELD_SUPPORT/EXPLICIT_BLOCK_PARAM_SUPPORT: must appear in the
    # declaration too. No devirtualized direct call passes it today (callers are
    # block-carrying sends, never devirtualized), but a mismatch must be a
    # compile error, not a wrong signature.
    arg_c_types << 'mrb_value' if needs_blk_param || has_blk
    # OPTIONAL_ARG_SUPPORT: `bc2cpp_given_opt` is part of the signature, so the
    # declaration needs it too.
    arg_c_types << 'mrb_int' if opt.positive?
    # KEYWORD_ARG_SUPPORT: the keyword parameters, in the same order as
    # arg_params, for the declaration.
    kw_table&.each do |kw|
      arg_c_types << 'mrb_value'
      arg_c_types << 'mrb_int' unless kw[:required]
    end
    # REGISTRATION_ASPEC: the mrb_aspec a registration of this entry needs, built
    # from the very variables the wrapper above was generated from (mand/opt/rest/
    # keywords/block), so it cannot drift from the arguments the wrapper actually
    # binds. The count of keywords is all an aspec can carry (mruby has no
    # required-keyword field); the wrapper itself enforces which are required.
    aspec = mand.zero? && opt.to_i.zero? && !has_rest && !kw_table && !needs_blk_param && !has_blk ? ['MRB_ARGS_NONE()'] : ["MRB_ARGS_REQ(#{mand})"]
    aspec << "MRB_ARGS_OPT(#{opt})" if opt.to_i.positive?
    aspec << 'MRB_ARGS_REST()' if has_rest
    aspec << "MRB_ARGS_KEY(#{kw_table.size}, 0)" if kw_table
    aspec << 'MRB_ARGS_BLOCK()' if needs_blk_param || has_blk
    { label: label, owner: d.owner, name: d.name, entry: entry_name, impl: impl_name,
      arity: arg_names.size, arg_c_types: arg_c_types, aspec: aspec.join(' | '),
      code: out, visibility: d.visibility }
  end

  # OPTIONAL_ARG_SUPPORT: the switch replacing ENTER's jump table (see
  # optional_arg_table); `targets` are the table's target addresses in order.
  def emit_optional_dispatch(targets)
    out = String.new
    out << "  switch (bc2cpp_given_opt) {\n"
    targets.each_with_index do |addr, i|
      out << (i == targets.size - 1 ? "    default: goto L#{addr};\n" : "    case #{i}: goto L#{addr};\n")
    end
    out << "  }\n"
    out
  end

  # Every address a JMP/JMPNOT/JMPIF/JMPUW can land on needs a C label. JMPUW
  # has JMP's operand shape (ops.h `OPCODE(JMPUW, S)`). Listing it even when
  # jmpuw_is_plain_jump? rejects it only adds a harmless label to a method that
  # will not ship.
  def jump_targets(irep)
    targets = Set.new
    irep.instructions.each do |insn|
      case insn.op
      when 'JMP', 'JMPUW'
        targets << insn.args.strip[/\d+/].to_i
      when 'JMPNOT', 'JMPIF', 'JMPNIL'
        targets << jmp_target_after_reg(insn.args)
      end
    end
    targets
  end
end
