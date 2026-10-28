# frozen_string_literal: true

require 'strscan'
require_relative 'bytecode_ir'

# CodeGen: compile_method and jump targets.

class CodeGen
  # One inlined-loop kind: `recognize`/`emit` are CodeGen methods,
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
    InlineLoopPass.new(:recognize_step_regions, :emit_step_inline, :block_addr, false), # STEP_LOOP_SUPPORT
    InlineLoopPass.new(:recognize_kernel_loop_regions, :emit_kernel_loop_inline, :block_addr, false), # KERNEL_LOOP_INLINE
    InlineLoopPass.new(:recognize_each_regions, :emit_each_inline, :block_addr, true), # EACH_BLOCK_SUPPORT
    InlineLoopPass.new(:recognize_each_index_regions, :emit_each_index_inline, :block_addr, true), # EACH_INDEX_SUPPORT
    InlineLoopPass.new(:recognize_hash_each_regions, :emit_hash_each_inline, :block_addr, true), # HASH_EACH_SUPPORT
    InlineLoopPass.new(:recognize_hash_each_value_regions, :emit_hash_each_value_inline, :block_addr, true),
    InlineLoopPass.new(:recognize_each_key_regions, :emit_each_key_inline, :block_addr, true), # EACH_KEY_SUPPORT
    InlineLoopPass.new(:recognize_range_each_regions, :emit_range_each_inline, :block_addr, true), # INTERP_UNLOCK
    InlineLoopPass.new(:recognize_range_map_regions, :emit_range_map_inline, :block_addr, false), # RANGE_MAP_INLINE
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
    InlineLoopPass.new(:recognize_sort_regions, :emit_sort_inline, :block_addr, true), # SORT_BLOCK_SUPPORT
    InlineLoopPass.new(:recognize_array_new_regions, :emit_array_new_inline, :block_addr, true) # ARRAY_NEW_BLOCK
  ].freeze

  # RESCUE_TRY_INLINE: the passes a rescue try body runs.
  RESCUE_TRY_INLINE_PASSES = (INLINE_LOOP_PASSES.map(&:recognize) - [:recognize_profiler_section_regions]).freeze

  # RESCUE_PROFILER_INLINE: the profiler pass joins them. It was kept out on the belief that the
  # block call it replaces closes the section when the body raises. It does not: prof_section/prof_frame
  # (mruby-rgss/src/profiler.cxx) call profiler_section_end/profiler_frame_end after mrb_yield_argv returns, with no
  # unwinding guard, so a raise skips the end call there exactly as it skips the inlined one.
  # BC2CPP_RESCUE_PROFILER_INLINE=0 keeps the call.
  def rescue_try_pass?(recognize)
    return true if RESCUE_TRY_INLINE_PASSES.include?(recognize)

    recognize == :recognize_profiler_section_regions && ENV['BC2CPP_RESCUE_PROFILER_INLINE'] != '0'
  end

  # INLINE_LOOP_PASSES over one scope: a region not in `claimed` is emitted, its addresses join
  # `suppressed` and its code `glue_at`. `try_range` filters the
  # whole-method regions to a protected range (rescue_try_inlinable?).
  def run_inline_loop_passes(irep, d, mand, claimed, suppressed, glue_at, try_range: nil, guarded: nil)
    return with_guarded_inline_sites { run_inline_loop_passes_in(irep, d, mand, claimed, suppressed, glue_at, guarded) } if guarded && !try_range

    run_inline_loop_passes_in(irep, d, mand, claimed, suppressed, glue_at, nil, try_range: try_range)
  end

  def run_inline_loop_passes_in(irep, d, mand, claimed, suppressed, glue_at, guarded, try_range: nil)
    ctx_ivar = @class_layout[d.owner]
    ctx_args = @class_annotations[irep.label]&.args
    INLINE_LOOP_PASSES.each do |pass|
      next if try_range && !rescue_try_pass?(pass.recognize)

      ctx = pass.context ? [d.owner, mand, ctx_ivar, ctx_args] : []
      send(pass.recognize, irep, *ctx).each do |region|
        anchor = region[pass.anchor]
        next if claimed.include?(anchor) || claimed.include?(region[:sendb_addr])
        next if try_range && !rescue_try_inlinable?(region, anchor, try_range)
        # RANGE_EACH_GUARD: the Range#each loop needs its send kept behind it, which only the guarded glue places.
        next if pass.recognize == :recognize_range_each_regions && !guarded

        pre_start = @inline_nested_pre.length
        # GUARDED_BLOCK_INLINE: a second loop over the same block (another receiver class) keeps its own labels.
        guarded_klass = guarded && GUARDED_INLINE_PASS_CLASS[pass.recognize]
        guarded_klass = nil unless @guarded_inline_sites&.[]([region[:sendb_addr], guarded_klass])
        region[:label_tag] = guarded_klass ? "_#{guarded_klass[0]}" : nil
        # No element-class hint: it describes the elements of a receiver the flow proved, and this one is not.
        region[:elem_class] = nil if guarded_klass
        inlined = send(pass.emit, region, irep, d)
        unless inlined
          next
        end

        inlined = drop_unused_registers(inlined) if single_block?(inlined)

        if try_range && !rescue_try_glue_safe?(inlined, try_range)
          @inline_nested_pre.slice!(pre_start..) # the refused body's nested cfuncs are not used either
          next
        end

        # GUARDED_BLOCK_INLINE: the send stays; the loop runs ahead of it behind a class test, once the
        # send's arms are known (guarded_inline_finish).
        if guarded_klass
          guarded[:pending] << { region: region, inlined: inlined, klass: guarded_klass, anchor: anchor,
                                 pre: @inline_nested_pre[pre_start..].dup }
          next
        end
        if pass.recognize == :recognize_range_each_regions
          @inline_nested_pre.slice!(pre_start..) unless range_each_guarded_glue(region, irep, inlined, anchor, guarded)
          next
        end

        suppressed << anchor << region[:sendb_addr]
        glue_at[anchor] = inlined
      end
    end
  end

  def compile_method(label)
    @ir_inline_remaining = 512
    irep = @ireps.fetch(label)
    d = @owner_of.fetch(label)
    # mruby's own methods are compiled with no closed-world proof (the closed
    # world is the engine's Ruby) and may bind statically only to core definitions.
    if d.core && @closed_world
      saved_world = @closed_world
      @closed_world = nil
      # BLOCK_CORE_DIRECT: the program-wide facts (no outside definer, no installer)
      # hold for core bodies too; only the static-binding proofs are withheld from them.
      @core_program_world = saved_world
      begin
        return compile_method(label)
      ensure
        @closed_world = saved_world
        @core_program_world = nil
      end
    end
    @compiling_core = d.core ? true : false
    enter = irep.enter
    mand = enter ? enter.enter_fields.first : 0

    # RUNTIME_DEF_DEVIRT_GUARD: cleared at the single entry point so no early
    # return can leak one method's blocked-name set into the next compile.
    @runtime_installed_names = nil

    # EXCEPTION_RETURN_SUPPORT: computed early (a pure function of `irep`) so the
    # function body can be wrapped in the try/catch a RETURN_BLK thrown from a
    # region needs; the same list is reused by the region loop below.
    # BLOCK_FALLBACK_YIELD_SUPPORT: `blk_available` is the same condition as
    # `mandatory_ok` below, so a region is never marked `needs_blk` for a method
    # whose wrapper will not extract `bc2cpp_blk`.
    block_fallback_regions = recognize_block_fallback_regions(irep, blk_available: frame_block_available?(irep))
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
    needs_blk_param = yields_block_param?(irep, block_fallback_regions)
    opt, opt_jmp_addrs, opt_jmp_targets = mandatory_ok ? [0, nil, nil] : optional_arg_table(irep)
    # KEYWORD_ARG_SUPPORT / OPTIONAL_KEYWORD_COMBINED_SUPPORT: tried whenever
    # mandatory_ok is false, whether or not the optional table resolved (the
    # KEY_P/KARG scan is whole-irep).
    kw_table = mandatory_ok ? nil : keyword_arg_table(irep)
    # Each of `opt` (jump table) and `kw` must resolve or the whole method is
    # unsupported. Either failure also clears `opt_jmp_targets`, the flag
    # `supported` trusts; otherwise a recognized optional shape with an
    # unrecognized keyword shape would compile with its keywords dropped.
    enter_kw = enter ? enter.enter_fields[4] : 0
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
    # CORE_BLOCK_OPT: optionals and `&blk` together (`any?(pattern = NONE, &block)`). The
    # block sits after the optionals (OP_ENTER blk_pos), so it is the same extra
    # parameter, ahead of `bc2cpp_given_opt`.
    if !mandatory_ok && !opt_jmp_targets && !kw_table && (blk_table = optional_block_arg_table(irep))
      opt, opt_jmp_addrs, opt_jmp_targets = blk_table
      has_blk = true
    end
    supported = mandatory_ok || opt_jmp_targets || kw_table || has_rest || has_blk

    total_args = supported ? mand + opt + (has_rest ? 1 : 0) : mand
    arg_names = irep.lv.first(total_args).each_with_index.map { |n, i| c_param_name(n, i) }
    # NATIVE_ARGS per-position types (see native_arg_types). Optional
    # positions are never retyped; the padding is explicit.
    arg_native_types = native_arg_types(d, mand) + Array.new(total_args - mand)

    impl_name = "#{cpp_name(d.owner, d.name)}#{@entry_spec_suffix}_impl"
    entry_name = cpp_name(d.owner, d.name)
    embedded_ivars = @ivar_layout[d.owner]

    unless supported
      # Not modelled: emit `#error` rather than a signature that disagrees with what
      # callers pass.
      code = "// #{d.owner}##{d.name} (compiled from irep #{label}, #{BytecodeIR.for(irep).size} insns)\n" \
             "#error #{d.owner}##{d.name} has non-mandatory arguments (optional/rest/keyword/block) -- not in this prototype's supported subset\n\n"
      return { label: label, owner: d.owner, name: d.name, entry: entry_name, impl: impl_name,
               arity: arg_names.size, code: code, unsupported: true, visibility: d.visibility }
    end

    resumable = nil
    fiber_guarded = false
    if calls_fiber_yield?(irep) || @fiber_unsafe_methods.include?(label)
      # FIBER_YIELD_UNSAFE_SUPPORT / FIBER_REACHABILITY_UNSAFE_SUPPORT: a method that
      # calls Fiber.yield, or is reachable from a Fiber.new block, is not compiled
      # outright -- unless it is a Fiber.new root that qualifies as a resumable step
      # function, or its own body cannot suspend, in which
      # case it compiles behind a run-time hand-off.
      plan = resumable_plan(label)
      if plan.is_a?(ResumablePlan)
        resumable = plan
      elsif fiber_body_guard?(label, d)
        fiber_guarded = true
      else
        reason = if plan.is_a?(String)
                   warn "bc2cpp: resumable: #{d.owner}##{d.name} stays interpreted: #{plan}" if (@resumable_warned ||= Set.new).add?(label)
                   "is a Fiber.new root that cannot be compiled resumable: #{plan}"
                 else
                   calls_fiber_yield?(irep) ? 'calls Fiber.yield directly' : 'is reachable from a Fiber.new block'
                 end
        code = "// #{d.owner}##{d.name} (compiled from irep #{label}, #{BytecodeIR.for(irep).size} insns)\n" \
               "#error #{d.owner}##{d.name} #{reason} -- not in this prototype's supported subset\n\n"
        return { label: label, owner: d.owner, name: d.name, entry: entry_name, impl: impl_name,
                 arity: arg_names.size, code: code, unsupported: true, visibility: d.visibility }
      end
    end

    # ENTRY_GUARDED_SPECIALIZATION: nil unless BC2CPP_SPECIALIZE names this method.
    entry_spec = entry_specialization(label, d, irep, arg_names, arg_native_types,
                                      entry_specialization_eligibility(mandatory_ok: mandatory_ok, opt: opt, has_rest: has_rest, has_blk: has_blk,
                                                                       needs_blk_param: needs_blk_param, kw_table: kw_table, resumable: resumable,
                                                                       fiber_guarded: fiber_guarded, needs_return_catch: needs_return_catch,
                                                                       block_fallback_regions: block_fallback_regions))
    out = String.new
    out << "// #{d.owner}##{d.name} (compiled from irep #{label}, #{BytecodeIR.for(irep).size} insns)\n"
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
    step_name = "#{cpp_name(d.owner, d.name)}_step"
    step_body_start = nil
    if resumable
      # RESUMABLE_ENTRY: the frame, registers and dispatch open the function once the body has
      # said how many registers it uses(resumable_step_function).
      return resumable_refusal(label, d, irep, entry_name, impl_name, arg_names, 'is initialize') if d.name == 'initialize'
      return resumable_refusal(label, d, irep, entry_name, impl_name, arg_names, 'reads its block') if needs_blk_param || has_blk

      @resumable = ResumableCtx.new(label, resumable.helpers)
      step_body_start = out.length
    else
      out << "mrb_value #{impl_name}(mrb_state* M, #{(['mrb_value self'] + arg_params).join(', ')}) {\n"
      out << errinfo_scope_line(irep)
      out << core_body_fast_prologue(d) if d.core
      # ENTRY_GUARDED_SPECIALIZATION: the entry check; a miss falls through to the generic body below.
      out << "  if (#{entry_spec[:guard]}) return #{entry_spec[:call]}(M, #{(['self'] + arg_names).join(', ')});\n" if entry_spec&.fetch(:guard)
      # EXCEPTION_RETURN_SUPPORT: wrap the body in one try/catch only when a
      # BLOCK_FALLBACK region can throw bc2cpp_method_return. Cheap under zero-cost
      # exceptions but not free, hence the gate. Statements inside the `try` behave
      # the same; only a throw changes control flow.
      # BLOCK_SEMANTICS: the method is a frame a block's `return` may unwind to; the
      # blocks it builds carry the guard's token.
      out << "  Bc2cppFrameGuard bc2cpp_ret_guard(&bc2cpp_return_frames);\n" if needs_return_catch
      out << "  Bc2cppVmMark bc2cpp_ret_mark = bc2cpp_vm_mark(M);\n  try {\n" if needs_return_catch
      # Box arguments in parameter order; the remaining registers start as nil.
      initial = arg_names.each_with_index.map do |arg, i|
        type = arg_native_types[i]
        type ? "#{TYPE_OPS.fetch(type)[:box]}(#{arg})" : arg
      end
      initial[total_args] = 'bc2cpp_blk' if has_blk
      out << emit_register_initializers(irep.nregs, initial)
      out << sealed_int16_declarations(irep)
      out << stack_tuple_declarations(irep)
      out << array_hash_fixnum_prologue(d)
      if embedded_ivars && d.name == 'initialize'
        # At the start of #initialize self is a bare MRB_TT_DATA shell (data == NULL):
        # allocate the struct before any embedded SETIV.
        sname = struct_name(d.owner)
        out << "  {\n"
        out << "    #{sname}* embedded = (#{sname}*)mrb_calloc(M, 1, sizeof(#{sname}));\n"
        embedded_ivars.each do |ivar, type|
          initial = type == :value ? 'mrb_undef_value()' : '{}'
          out << "    embedded->#{ivar_field_name(ivar)} = #{initial};\n"
        end
        out << "    mrb_data_init(self, embedded, &#{type_var(d.owner)});\n"
        out << "  }\n"
      end
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
    exec_fallback_regions = recognize_exec_fallback_regions(irep)
    if BytecodeIR.for(irep).op?(:SDEF) || !exec_fallback_regions.empty?
      @runtime_installed_names = runtime_installed_names_for(irep, exec_fallback_regions) || :unknown
    end

    # OPTIONAL_ARG_SUPPORT: replace the ENTER jump table with a `switch` on
    # `bc2cpp_given_opt` (suppressed/glue_at mechanism); default-value code is
    # untouched and reached by goto, like OP_ENTER's PC skip.
    if opt.positive? && opt_jmp_targets
      opt_jmp_addrs.each { |a| suppressed << a }
      glue_at[opt_jmp_addrs.first] = emit_optional_dispatch(opt_jmp_targets)
    end

    # CORE_BLOCK_YIELD: a `yield` inside a rescue range (Kernel#loop) reads the method's block,
    # which the extracted try body receives as one more captured value.
    blk_field = needs_blk_param || has_blk ? [{ name: 'bc2cpp_blk', c_type: 'mrb_value' }] : []
    @blk_param_name = blk_field.empty? ? nil : 'bc2cpp_blk'
    @blk_param_level = 0
    # REGISTER_FLOW: the outer registers each glue's try body reads, by the same fields the glue
    # initialises (saved copies and `&rN` aliases). The pass checks the glue text names them.
    rescue_glue_reads = {}
    rescue_regions.each_with_index do |region, i|
      suppressed.merge((region[:begin_addr]..region[:end_addr]).to_a)
      suppressed << region[:except_addr]
      try_name = "#{impl_name}_rescue_try#{rescue_regions.size > 1 ? "_#{i}" : ''}"
      saved = rescue_entry_saved_fields(irep, region) + blk_field
      rescue_pre << emit_rescue_try_body(try_name, region, irep, d, arg_names, arg_native_types, extra_fields: saved,
                                                                                                  inline_mand: mand)
      glue_at[region[:begin_addr]] = emit_rescue_glue(try_name, region, arg_names, arg_native_types,
                                                      extra_field_values: saved.map { |f| rescue_field_value(f) })
      rescue_glue_reads[region[:begin_addr]] = saved.filter_map do |f|
        f[:name][/\Abc2cpp_(?:saved|ref)_r(\d+)\z/, 1]&.to_i
      end
    end
    @blk_param_name = nil

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
    # RESCUE_INLINE_BLOCK_FIX: a loop emitted here for an address the rescue loop claimed would run
    # after the rescue glue, on the exception-only path, with the exception as its receiver
    # The range's own loops are inlined in the try body.
    guarded_inline = { at: {}, after: {}, pending: [] }
    run_inline_loop_passes(irep, d, mand, suppressed.dup, suppressed, glue_at, guarded: (@resumable ? nil : guarded_inline))
    proven_inlined = suppressed.dup

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
    guarded_inline_finish(irep, guarded_inline)

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
    irep.each_with_op(:SDEF) do |insn, _idx|
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
    exec_fallback_regions.each do |region|
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
    # ARM_PRUNE (codegen_arm_prune.rb): the instructions no edge reaches. Stage A only counts them.
    arm_prune = arm_prune_analysis(irep, d)
    # BLKPUSH_YIELD_SUPPORT: set for this method's top-level loop only (cleared
    # after). emit_proc_fallback_fn manages its own value.
    # CORE_BLOCK_YIELD: with `&blk` declared, the BLKPUSH slot is that parameter's register.
    @blk_param_name = needs_blk_param ? 'bc2cpp_blk' : (has_blk ? "r#{total_args + 1}" : nil)
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
        # ENSURE_ENTRY_LABEL: a jump onto the first protected instruction lands before the guard's scope opens.
        entry = ensure_region[:entry_label] ? "  L#{ensure_region[:begin_addr]}:;\n" : ''
        prefix_at[ensure_region[:begin_addr]] = entry + open_glue
        targets -= [ensure_region[:begin_addr]] if ensure_region[:entry_label]
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
    # RESUMABLE_ENTRY: the method's own instructions are the flat part of the step function.
    @resumable.flat = true if @resumable
    # REGISTER_FLOW: an ordinary method keeps each instruction's text
    # apart until the whole body exists, so dead copies can be dropped.
    flow_captured = RegisterFlow.captured_registers(irep) if !@resumable && prefix_at.empty? && RegisterFlow.enabled?
    flow_bodies = flow_captured && Array.new(BytecodeIR.for(irep).size, '')
    flow_labels = flow_captured && Array.new(BytecodeIR.for(irep).size, '')
    # ARM_PRUNE stage B (BC2CPP_PRUNE_ARMS=1): the held-back text is restored unless the method has no other emitter that
    # works per instruction (suppressed, glue, prefix, guarded, resumable step). Register flow's captured registers do not
    # refuse it: they are pinned, and an unreachable write never runs, so a live read sees the same value.
    arm_texts = {}
    arm_prune_drop = arm_prune_stage_b_enabled? && arm_prune && !arm_prune.empty? && !@resumable &&
                     suppressed.empty? && glue_at.empty? && prefix_at.empty? && guarded_inline[:at].empty? &&
                     guarded_inline[:after].empty?
    arm_prune_refuse(:ineligible) if arm_prune_stage_b_enabled? && arm_prune && !arm_prune.empty? && !arm_prune_drop
    # SPLAT_SHARED (codegen_computed_send.rb): the ARYCAT's text is handed to the guarded splat send after it.
    splat_blocked = lambda do |addr|
      arm_prune_drop || targets.include?(addr) || suppressed.include?(addr) || glue_at.key?(addr) ||
        prefix_at.key?(addr) || guarded_inline[:at].key?(addr) || guarded_inline[:after].key?(addr)
    end
    pending_splat = nil
    BytecodeIR.for(irep).each_source do |insn, idx|
      stack_tuple_visit(irep, idx, suppressed.include?(insn.addr) || glue_at.key?(insn.addr) || guarded_inline[:at].key?(insn.addr))
      # With REGISTER_FLOW the bodies are written at the end, so a label written here would land before the method's
      # first instruction: the guarded loop's `goto` would then jump back to the top and run the loop again.
      out << guarded_inline[:after][insn.addr] if !flow_bodies && guarded_inline[:after].key?(insn.addr)
      flow_labels[idx] = guarded_inline[:after][insn.addr] if flow_bodies && guarded_inline[:after].key?(insn.addr)
      out << prefix_at[insn.addr] if prefix_at.key?(insn.addr)
      next if suppressed.include?(insn.addr) && !glue_at.key?(insn.addr)

      jump_label = targets.include?(insn.addr) ? "  L#{insn.addr}:;\n" : ''
      # The guarded-inline prefix is part of this instruction's text, so the flow pass sees it as one unit.
      text = if splat_shared_pair?(irep, idx, splat_blocked)
               pending_splat = { irep: irep, idx: idx + 1, reg: insn.reg.to_i, src: insn.paren_reg.to_i,
                                 arycat: compile_insn(insn, irep, d, idx) }
               ''
             elsif pending_splat
               shared_send = splat_shared_send(pending_splat) { compile_insn(insn, irep, d, idx) }
               pending_splat = nil
               shared_send
             else
               (guarded_inline[:at][insn.addr] || '') + (glue_at[insn.addr] || compile_insn(insn, irep, d, idx))
             end
      if arm_prune_drop && arm_prune.include?(idx)
        # A flow body keeps its '' slot until the decision below, so the pass never sees a dropped text.
        arm_texts[idx] = [jump_label, text]
        out << "\x01ARM_PRUNE:#{idx}\x01" unless flow_bodies
        next
      end
      if flow_bodies
        flow_labels[idx] = "#{flow_labels[idx]}#{jump_label}"
        flow_bodies[idx] = text
      else
        out << jump_label << text
      end
    end
    if arm_prune_drop && !arm_texts.empty?
      held = arm_texts.transform_values { |label, text| label + text }
      if !flow_bodies
        out = arm_prune_resolve(out, held)
      elsif !arm_prune_decide(held)
        # Refused: restore the held texts in their slots, as a method with no pruning would have them.
        arm_texts.each do |idx, (label, text)|
          flow_labels[idx] = "#{flow_labels[idx]}#{label}"
          flow_bodies[idx] = text
        end
      end
    end
    if flow_bodies
      flow_handlers = { regions: recognize_rescue_regions(irep).map { |r| r.slice(:begin_addr, :end_addr, :except_addr) },
                        glue_reads: rescue_glue_reads }
      # Reports and eligibility observe #error, not register cleanup. Keep error-bearing and audited texts on the regular pass.
      unless (@clean_probe || @report_only_text) && !@runtime_installed_names && flow_bodies.none? { |text| text.include?('#error') }
        flow_bodies = RegisterFlow.optimize(irep, flow_bodies, flow_captured, handlers: flow_handlers)
      end
      flow_labels.each_with_index { |jump_label, idx| out << jump_label << flow_bodies[idx] }
    end
    @resumable.flat = false if @resumable
    @blk_param_name = nil
    @ensure_except_remaps = nil
    out << fell_off_end("#{d.owner}##{d.name}")
    if @resumable
      body = out.slice!(step_body_start..)
      # A block that stays a separate function throws its `return` to a catch around the whole
      # body, and a try block cannot be jumped into.
      if needs_return_catch && [body, block_fallback_pre, @inline_nested_pre].any? { |code| code.include?('bc2cpp_return_from_block') }
        body << resumable_error('a block that is not inlined returns from the method')
      end
      out << resumable_step_function(step_name, body)
      out << "}\n\n"
    elsif needs_return_catch
      out << "  } catch (bc2cpp_method_return& bc2cpp_ret) {\n"
      out << "    if (bc2cpp_ret.token != bc2cpp_ret_guard.frame.token) throw;\n"
      out << "    bc2cpp_vm_restore(M, bc2cpp_ret_mark);\n"
      out << "    return bc2cpp_ret.value;\n"
      out << "  }\n"
      out << "}\n\n"
    else
      out << "}\n\n"
    end
    # INLINE_NESTED_BLOCK_SUPPORT: `@inline_nested_pre` goes first so a nested
    # block's cfunc is defined before the loop that uses it.
    out = drop_dead_statements(drop_unused_registers(out)) unless @resumable || (@report_only_text && !@runtime_installed_names)
    out = @inline_nested_pre + block_fallback_pre + rescue_pre + out
    @inline_nested_pre = bc2cpp_saved_inline_pre
    out << runtime_def_devirt_audit(out)
    if entry_spec
      # The specialized function goes ahead of `_impl`, after this method's header line.
      header = "// #{d.owner}##{d.name} (compiled from irep #{label}, #{BytecodeIR.for(irep).size} insns)\n"
      at = out.index(header) + header.length
      out = out[0...at] + entry_spec[:code] + out[at..]
    end
    @runtime_installed_names = nil
    if @resumable
      out << resumable_entry_function(impl_name, step_name, "#{d.owner}##{d.name}")
      first_error = @resumable.reasons.first || out[/^\s*#error (.*)$/, 1]
      first_error = 'a block call that is neither an inlined step/upto/downto loop nor a plain block function' if first_error&.match?(/unhandled opcode (BLOCK|SENDB|SSENDB)/)
      if first_error && (@resumable_warned ||= Set.new).add?(label)
        warn "bc2cpp: resumable: #{d.owner}##{d.name} stays interpreted: #{first_error}"
      end
    end
    @resumable = nil

    out << "static mrb_value #{entry_name}(mrb_state* M, mrb_value self) {\n"
    guard = core_block_guard(label, d) || fiber_body_guard_prologue(label, fiber_guarded)
    out << guard[:prologue] if guard
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
      out << "  bc2cpp_check_argc(M, #{mand}, -1);\n"
      out << "  mrb_get_args(M, \"#{fmt}\", #{ptrs});\n"
      out << "  mrb_value #{rest_name} = mrb_ary_new_from_values(M, bc2cpp_rest_len, bc2cpp_rest_ptr);\n"
      call_args = mand_names + [rest_name]
      call_args << 'bc2cpp_blk' if has_blk
      out << "  return #{impl_name}(M, self, #{call_args.join(', ')});\n"
    else
      # Each local's type must match what its mrb_get_args format character writes:
      # 'o' writes an mrb_value, 'i' (NATIVE_ARGS) an mrb_int*/mrb_sym*
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
      # BLOCK_SEMANTICS: OP_ENTER words every arity error `expected <mandatory>`,
      # where mrb_get_args says `1..2`.
      out << "  bc2cpp_check_argc(M, #{mand}, #{mand + opt});\n" if opt.positive?
      out << "  mrb_get_args(M, \"#{fmt}\", #{ptrs});\n"
      if opt.positive?
        # OPTIONAL_ARG_SUPPORT: mrb_get_argc(M) - mand is the quantity OP_ENTER uses to
        # pick the jump-table entry. The clamp to [0, opt] is a formality
        # (mrb_get_args already raised for out-of-range counts).
        out << "  mrb_int bc2cpp_given_opt = mrb_get_argc(M) - #{mand};\n"
        out << "  if (bc2cpp_given_opt < 0) bc2cpp_given_opt = 0;\n"
        out << "  if (bc2cpp_given_opt > #{opt}) bc2cpp_given_opt = #{opt};\n"
        out << "  return #{impl_name}(M, self, #{(has_blk ? arg_names + ['bc2cpp_blk'] : arg_names).join(', ')}, bc2cpp_given_opt);\n"
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
    # DECLARED_RETURN_GUARD: a runtime-checked return declaration checks every value the body returns.
    out = declared_return_guard_wrap(label, out, impl_name)
    { label: label, owner: d.owner, name: d.name, entry: entry_name, impl: impl_name,
      arity: arg_names.size, arg_c_types: arg_c_types, aspec: aspec.join(' | '),
      code: out, visibility: d.visibility, guard: guard&.fetch(:index), resumable: !resumable.nil? }
  end

  # Generated register references are literal r<N> identifiers. Counting comments
  # and strings too only retains extra declarations; address-taken locals count.
  # A declaration is dropped when it is the register's only mention in +code+ and its
  # initializer has no effect (nil, or a plain identifier: self, an argument); an
  # inlined loop's per-iteration frame (inline_block_frame) is covered as well.
  UNUSED_REGISTER_DECLARATION = /^ +mrb_value r(\d+) = (?:mrb_nil_value\(\)|[A-Za-z_]\w*);\n/

  # Whether +code+ is one braced block: every declaration in it is scoped inside it,
  # so drop_unused_registers on the snippet alone is sound (an inlined loop redeclares
  # its frame per loop, and the whole function would see each name more than once).
  # String and character literals are skipped; any other shape answers false.
  # C that a core body runs first, ahead of its compiled instructions (TRANSPOSE_DIRECT adds one); '' by default.
  def core_body_fast_prologue(_definition)
    ''
  end

  def single_block?(code)
    text = code.gsub(/"(?:[^"\\\n]|\\.)*"|'(?:[^'\\\n]|\\.)*'/, '""').strip
    return false unless text.start_with?('{') && text.end_with?('}')

    depth = 0
    # Braces are ASCII bytes even when generated literals or comments contain UTF-8.
    index = 0
    last = text.bytesize - 1
    while index <= last
      byte = text.getbyte(index)
      depth += 1 if byte == 123
      depth -= 1 if byte == 125
      return false if depth.zero? && index != last

      index += 1
    end
    depth.zero?
  end

  def drop_unused_registers(code)
    uses = Hash.new(0)
    # Integer keys avoid allocating each matched token; leading zeros keep their distinct spelling.
    scanner = StringScanner.new(code)
    while scanner.skip_until(/\br\d+\b/)
      first = scanner.pos - scanner.matched_size + 1
      if code.getbyte(first) == 48 && scanner.matched_size > 2
        key = code.byteslice(first, scanner.matched_size - 1)
      else
        key = 0
        while first < scanner.pos
          key = key * 10 + code.getbyte(first) - 48
          first += 1
        end
      end
      uses[key] += 1
    end
    code.gsub(UNUSED_REGISTER_DECLARATION) do |declaration|
      digits = Regexp.last_match(1)
      key = digits.size > 1 && digits.start_with?('0') ? digits : digits.to_i
      uses.fetch(key) == 1 ? '' : declaration
    end
  end

  # Null statements the emitters leave behind: a label nothing names again (a loop's
  # break target with no break, a jump target the register flow removed) and a
  # register copied onto itself. A line goes only after one that ends a statement or
  # opens or closes a block: never the body of an unbraced if, else or loop, nor the
  # only statement after a case label.
  DEAD_LABEL = /\A *(L\w+):;\n\z/
  SELF_COPY = /\A *(r\d+) = \1;\n\z/
  STATEMENT_END = /[;{}]\s*\z/

  def drop_dead_statements(code)
    labels = code.scan(/\bL\w+\b/).tally
    previous = "{\n"
    code.each_line.reject do |line|
      dead = previous.match?(STATEMENT_END) &&
             ((label = line[DEAD_LABEL, 1]) ? labels[label] == 1 : line.match?(SELF_COPY))
      previous = line unless dead || line.strip.empty?
      dead
    end.join
  end

  # mrbc names an anonymous parameter by its sigil (`*`, `**`, `&`, and `...`'s three), which is no C identifier; the
  # prefix keeps it apart from a Ruby parameter spelled `argN`.
  ANONYMOUS_PARAM = /\A[*&]/

  def c_param_name(name, index)
    return "arg#{index + 1}" unless name
    return "bc2cpp_anon_arg#{index + 1}" if name.match?(ANONYMOUS_PARAM)

    sanitize_c_ident(name)
  end

  # R0 stays, unused or not: it is the line ParamTrace instruments (param_trace.rb REG0_RE).
  def emit_register_initializers(nregs, arguments)
    (0...nregs).map do |reg|
      next "  [[maybe_unused]] mrb_value r0 = self;\n" if reg.zero?

      "  mrb_value r#{reg} = #{arguments[reg - 1] || 'mrb_nil_value()'};\n"
    end.join
  end

  # The stub compile_method returns for a Fiber.new root that turned out not to qualify.
  def resumable_refusal(label, d, irep, entry_name, impl_name, arg_names, reason)
    warn "bc2cpp: resumable: #{d.owner}##{d.name} stays interpreted: #{reason}" if (@resumable_warned ||= Set.new).add?(label)
    { label: label, owner: d.owner, name: d.name, entry: entry_name, impl: impl_name, arity: arg_names.size,
      code: "// #{d.owner}##{d.name} (compiled from irep #{label}, #{BytecodeIR.for(irep).size} insns)\n" \
            "#error #{d.owner}##{d.name} is a Fiber.new root that cannot be compiled resumable: #{reason} -- " \
            "not in this prototype's supported subset\n\n",
      unsupported: true, visibility: d.visibility }
  end

  # CORE_BLOCK_GUARD: the entry of a core method that touches a block first
  # checks whether a Fiber is running and, if so, lets the VM run the bytecode instead
  # (bc2cpp_core_interpreted). A compiled frame under a block that calls Fiber.yield
  # cannot be suspended, and a frame in the root context never is: a yield there is a
  # FiberError with or without this frame. Direct `_impl` calls never take a block
  # (pure_mandatory_or_optional_arity?), so the entry is the only way in with one.
  # An Enumerable method also needs an `each` that the core defines, since a block
  # captured by pointer must not outlive the frame (BLOCK_FALLBACK_UPVAR_SAFE_METHODS).
  # Returns { index:, prologue: } or nil for an unguarded method.
  # FIBER_BODY_GUARD: may this Fiber-reachable method compile behind a
  # run-time hand-off instead of staying interpreted?
  #
  # Only when its OWN body cannot suspend. `core_body_relaxable?` is YieldReach
  # answering exactly that, and it is the same question CORE_BLOCK_GUARD
  # already asks of a core body before narrowing its guard condition (below). The
  # yield that matters happens in the block the CALLER supplied, which is not
  # running inside this frame -- and it is not proved yield-free, because it cannot
  # be. That is what the hand-off is for.
  #
  # A method that calls Fiber.yield itself is never admitted: there the yield IS in
  # its own frame, which no hand-off from its own entry can step around.
  #
  # Neither is a method that builds an Enumerator: mruby-enumerator runs a
  # generator on a Fiber (CoreDefs.fiber_gem?), so that block's frame is below a
  # fiber entry by construction, not by a caller. YieldReach marks only
  # `Fiber.new` blocks as fiber bodies (scan_fiber_call), so `body_yield_free?`
  # reads such a builder as yield-free when its block is not. That gap predates
  # this guard -- nothing compiled it before -- and admitting one would put a
  # compiled frame under a Fiber for real.
  #
  # BC2CPP_FIBER_BODY_GUARD=0 restores the blanket refusal.
  def fiber_body_guard?(label, d = nil)
    return false if ENV['BC2CPP_FIBER_BODY_GUARD'] == '0'
    return false if d && calls_fiber_yield?(@ireps.fetch(label))
    return false if @yield_reach&.builds_enumerator?(label)

    core_body_relaxable?(label)
  end

  # The entry half, mirroring core_block_guard: with a Fiber other than the root
  # live, run this method bytecode instead, so no compiled frame is left between
  # the fiber entry and a yield in the caller block.
  def fiber_body_guard_prologue(label, enabled)
    return nil unless enabled

    index = (@core_guard_index[label] ||= @core_guard_index.size)
    { index: index,
      prologue: "  if (mrb_unlikely(M->c != M->root_c)) return bc2cpp_core_interpreted(M, self, #{index});\n" }
  end

  def core_block_guard(label, d)
    return nil unless d.core && self.class.core_guarded&.include?(label)

    index = (@core_guard_index[label] ||= @core_guard_index.size)
    # YIELD_REACH: a body that cannot suspend a Fiber on its own stays compiled under one
    # while the block it runs is provably yield-free too (checked per call, by its env flag).
    condition = if core_body_relaxable?(label)
                  '(M->c != M->root_c && !bc2cpp_block_yield_free(bc2cpp_entry_block(M)))'
                else
                  'M->c != M->root_c'
                end
    condition += ' || !bc2cpp_core_each_is_builtin(M, self)' if d.owner == 'Enumerable'
    { index: index,
      prologue: "  if (mrb_unlikely(#{condition})) return bc2cpp_core_interpreted(M, self, #{index});\n" }
  end

  # OPTIONAL_ARG_SUPPORT: the switch replacing ENTER's jump table (see
  # optional_arg_table); `targets` are the table's target addresses in order.
  # RegisterFlow.dispatch_text builds the text; the pass matches it, so both come from there.
  def emit_optional_dispatch(targets)
    RegisterFlow.dispatch_text(targets)
  end

  # Every address a JMP/JMPNOT/JMPIF/JMPUW can land on needs a C label. JMPUW
  # has JMP's operand shape (ops.h `OPCODE(JMPUW, S)`). Listing it even when
  # jmpuw_is_plain_jump? rejects it only adds a harmless label to a method that
  # will not ship.
  def jump_targets(irep)
    BytecodeIR.for(irep).branch_targets.dup
  end
end
