# frozen_string_literal: true

# CodeGen: emitters of inlined block loops.

class CodeGen
  # INLINE_NESTED_BLOCK_SUPPORT: the result of the BLOCK_FALLBACK recognize ->
  # emit -> suppress pipeline on ONE inlined body (inline_nested_block_pass).
  # `pre` is file-scope code for the cfuncs; `suppressed`/`glue` drive the
  # emitter's loop like compile_method's suppressed/glue_at. InlineNested.none
  # (nothing claimed) leaves the emitted code unchanged.
  InlineNested = Struct.new(:pre, :suppressed, :glue) do
    def self.none = new(String.new, [], {})

    # JUMP_TARGET_GLUE_FIX's rule: a suppressed address that still carries glue
    # keeps its label; one without code loses it.
    def targets(all) = all - (suppressed - glue.keys)

    def skip?(addr) = suppressed.include?(addr) && !glue.key?(addr)
  end

  # inline_nested_block_pass (below), INLINE_NESTED_BLOCK_SUPPORT:
  # recognize/emit/suppress the BLOCK/SENDB regions NESTED in one inlined loop
  # body, so an already-proven outer region is no longer abandoned just because
  # its body contains another block call (compile_insn has no BLOCK case, so the
  # body got `#error` and the whole loop fell back to BLOCK_FALLBACK). The same
  # pipeline NESTED_BLOCK_FALLBACK_SUPPORT runs inside emit_proc_fallback_fn.
  # E.g. Game::ChipsetLayout.quads_from_quarters:
  #     out = []
  #     2.times do |j|
  #       2.times do |i|
  #         qc, qr = quarters[j][i]
  #         out << [i * HTS, j * HTS, qc * TS + i * HTS, qr * TS + j * HTS, HTS, HTS]
  #       end
  #     end
  # where the inner block has `GETUPVAR R5 1 1` (the method's `quarters`) and
  # `GETUPVAR R6 1 0` (the outer block's `j`).
  # Both levels are directly addressable without pointer forwarding: an inlined
  # body is emitted into the method's own `_impl`, where the method's registers
  # are `r0 .. r<nregs-1>` and the inlined block's are `r<offset> ..` with
  # offset == irep.nregs. So level 0 is `&r<x + offset>` and level 1 is
  # `&r<x>`. Sound only because the inlined-loop emitters are called from
  # compile_method and nowhere else (so `irep` is a method body); re-verify
  # before calling one from a nested context. `available_upvars` = [0, x] for
  # every method register expresses this: the recognizer admits levels 0 and 1
  # and refuses >= 2.
  # RETURN_BLK is refused: it would throw bc2cpp_method_return, and
  # needs_return_catch (which arms the catch) is computed before these emitters
  # run, so nothing would catch it (std::terminate).
  # `blk_available: false`: forwarding the method's block through a nested
  # yield depends on BLKPUSH level counts over real VM frames, which inlining
  # collapses.
  # All-or-nothing: an unclaimable nested region leaves `#error`, and the loop
  # falls back as before.
  #
  # inline_nested_region_has_break?: does the nested region's body contain a
  # BREAK at any depth? Refused: a BLOCK_FALLBACK `break` throws
  # bc2cpp_block_break through the VM frames mrb_funcall_with_block pushed, and
  # that unwind is already broken (mruby's mrb_vm_run callinfo assertion fires
  # for `rows.each { |row| acc << row.each { |v| break v * 100 if v > 1 } }`),
  # so nothing newly admitted may depend on it. MRB_CATCH (mruby/throw.h) does
  # not swallow the foreign type; the VM state is what breaks.
  # `available_upvars` must match the real emit pass (see
  # block_fallback_region_has_return_blk?).
  def inline_nested_region_has_break?(region, available_upvars)
    block_irep = region[:block_irep]
    return true if block_irep.instructions.any? { |i| i.op == 'BREAK' }

    recognize_block_fallback_regions(block_irep, available_upvars: region[:upvars] || available_upvars)
      .any? { |nregion| inline_nested_region_has_break?(nregion, available_upvars) }
  end

  def inline_nested_block_pass(block_irep, irep, d, offset, outer_addr)
    host_upvars = (0...irep.nregs).map { |x| [0, x] }
    regions = recognize_block_fallback_regions(block_irep, available_upvars: host_upvars)
    return InlineNested.none if regions.empty?

    fn_prefix = "#{cpp_name(d.owner, d.name)}_inline_#{outer_addr}"
    nested = InlineNested.none
    regions.each do |nregion|
      next if block_fallback_region_has_return_blk?(nregion)
      next if inline_nested_region_has_break?(nregion, host_upvars)

      fn_result = emit_proc_fallback_fn(nregion, d, fn_prefix)
      next unless fn_result

      nfn_name, nfn_code = fn_result
      nested.pre << nfn_code
      nested.suppressed << nregion[:block_addr] << nregion[:sendb_addr]
      nested.glue[nregion[:block_addr]] = emit_block_fallback_glue(nregion, nfn_name, inline_offset: offset)
    end
    nested
  end

  # INLINE_NESTED_BLOCK_SUPPORT: the compiled body of one inlined block, or nil
  # if any instruction is unclean (a loop is never emitted partially; the caller
  # then leaves BLOCK/SENDB as `#error`). Nested block calls are claimed first
  # (inline_nested_block_pass) and consumed by compile_block_body_insn through
  # `@inline_nested`, which is saved and restored, not cleared: compile_method is
  # re-entrant (compiles_clean? -> monomorphic_target -> compile_send ->
  # compile_insn can re-enter it from the body loop), and clearing would disarm
  # an enclosing body's map. The nested cfunc code reaches @inline_nested_pre
  # only on success; a failed region would leave it unreferenced.
  # `break_label` wires BREAK to the destination register; `result_var` and
  # `broke_flag` select compile_collect_body_insn; `elem_reg` is the block
  # register bound to the loop element (ELEMENT_CLASS_SUPPORT); `hash_capture`
  # scopes inline_hash_capture_hints over the instructions only, not the nested
  # pass.
  def compile_inline_block_body(region, irep, d, iter_label, break_label: nil, result_var: nil, broke_flag: nil,
                                elem_reg: nil, hash_capture: false)
    block_irep = region[:block_irep]
    offset = irep.nregs
    break_dest = break_label ? region[:dest_reg] : nil
    label_prefix = "LBLK#{region[:block_addr]}_"
    compile_insn = lambda do |insn, i|
      if result_var
        compile_collect_body_insn(insn, block_irep, d, offset, iter_label, label_prefix,
                                  result_var: result_var, break_dest: break_dest, break_label: break_label,
                                  broke_flag: broke_flag, idx: i)
      else
        compile_block_body_insn(insn, block_irep, d, offset, iter_label, label_prefix,
                                break_dest: break_dest, break_label: break_label, idx: i)
      end
    end

    saved_nested = @inline_nested
    @inline_nested = inline_nested_block_pass(block_irep, irep, d, offset, region[:block_addr])
    body_targets = @inline_nested.targets(jump_targets(block_irep))
    body = String.new
    compile_all = lambda do
      block_irep.instructions.each_with_index do |insn, i|
        next if insn.op == 'ENTER'

        body << "    #{label_prefix}#{insn.addr}:;\n" if body_targets.include?(insn.addr)
        code = if elem_reg
                 with_element_hint(block_irep, insn, i, elem_reg, region[:elem_class]) { compile_insn.call(insn, i) }
               else
                 compile_insn.call(insn, i)
               end
        body << '  ' << code
      end
    end
    if hash_capture
      with_block_hash_capture_hints(inline_hash_capture_hints(irep, region), &compile_all)
    else
      compile_all.call
    end
    nested_pre = @inline_nested.pre
    @inline_nested = saved_nested
    return nil if body.include?('#error')

    @inline_nested_pre << nested_pre
    body
  end

  # The declarations opening every iteration: block registers reset to nil, as
  # a fresh block activation would be, and R0 (the block's self, never
  # renumbered) aliased to `self`, which GETIV/SETIV codegen names directly.
  def inline_block_frame(block_irep, offset)
    out = String.new
    (1...block_irep.nregs).each { |i| out << "      mrb_value r#{i + offset} = mrb_nil_value();\n" }
    out << "      mrb_value r#{offset} = self;\n"
  end

  # Not E_TYPE_ERROR: that macro hardcodes `mrb`; generated code names it `M`.
  def inline_raise(exc_class, message)
    "mrb_raise(M, mrb_exc_get_id(M, mrb_intern_lit(M, \"#{exc_class}\")), \"bc2cpp: #{message}\");"
  end

  # A tripwire, not a fallback: the recognizer's gate should make it unreachable,
  # and mrb_funcall cannot pass a block (why ADR 0147 rejected proc-wrapping).
  def inline_receiver_guard(predicate, recv_expr, expected)
    "    if (!#{predicate}(#{recv_expr})) { #{inline_raise('TypeError', "expected #{expected}")} }\n"
  end

  # SSENDB (a self-receiver call) iterates `self`, not a register.
  def inline_recv_expr(region) = region[:ssendb] ? 'self' : "r#{region[:dest_reg]}"

  # BLOCK_SUPPORT: the inlined loop for one `.times` region, or nil if the body
  # is not clean. `offset` (the method's nregs) keeps block registers apart.
  def emit_times_inline(region, irep, d)
    block_irep = region[:block_irep]
    offset = irep.nregs
    dest_reg = region[:dest_reg]
    param_reg = 1 + offset # the block's own single mandatory arg, R1 in its own numbering.
    addr = region[:block_addr]
    iter_label = "Lbc2cpp_times_iter_#{addr}"
    body = compile_inline_block_body(region, irep, d, iter_label)
    return nil unless body

    out = String.new
    out << "  {\n"
    out << inline_receiver_guard('mrb_integer_p', "r#{dest_reg}", 'Integer receiver for inlined #times')
    out << "    mrb_int bc2cpp_times_n_#{addr} = mrb_integer(r#{dest_reg});\n"
    out << "    for (mrb_int bc2cpp_times_i_#{addr} = 0; " \
           "bc2cpp_times_i_#{addr} < bc2cpp_times_n_#{addr}; " \
           "++bc2cpp_times_i_#{addr}) {\n"
    out << inline_block_frame(block_irep, offset)
    out << "      r#{param_reg} = mrb_fixnum_value(bc2cpp_times_i_#{addr});\n"
    out << body
    out << "      #{iter_label}:;\n"
    out << "    }\n"
    out << "  }\n"
    # Integer#times returns the receiver, which r<dest_reg> still holds.
    out
  end

  # EACH_BLOCK_SUPPORT: the inlined loop for one `ary.each` region (nil if not
  # clean). Differences from times:
  #   - LIVE length: `i < RARRAY_LEN(recv)` every iteration, as array.c does;
  #     Array#each visits elements pushed during iteration. Elements via
  #     mrb_ary_ref.
  #   - An mrb_array_p guard (inline_receiver_guard). Unproven sites stay
  #     interpreted.
  #   - BREAK wired (break_dest/break_label). A completed loop leaves the
  #     receiver in the destination, which is what Array#each returns.
  def emit_each_inline(region, irep, d)
    block_irep = region[:block_irep]
    offset = irep.nregs
    recv_expr = inline_recv_expr(region)
    param_reg = 1 + offset # the block's own single mandatory arg, R1 in its own numbering.
    addr = region[:block_addr]
    iter_label = "Lbc2cpp_each_iter_#{addr}"
    break_label = "Lbc2cpp_each_end_#{addr}"
    # ELEMENT_CLASS_SUPPORT: the block's single parameter R1 is bound to the
    # element below, so R1 is the loop element.
    body = compile_inline_block_body(region, irep, d, iter_label, break_label: break_label, elem_reg: '1',
                                                                  hash_capture: true)
    return nil unless body

    out = String.new
    out << "  {\n"
    out << inline_receiver_guard('mrb_array_p', recv_expr, 'Array receiver for inlined #each')
    out << "    for (mrb_int bc2cpp_each_i_#{addr} = 0; " \
           "bc2cpp_each_i_#{addr} < RARRAY_LEN(#{recv_expr}); " \
           "++bc2cpp_each_i_#{addr}) {\n"
    out << inline_block_frame(block_irep, offset)
    out << "      r#{param_reg} = bc2cpp_ary_entry(M, #{recv_expr}, bc2cpp_each_i_#{addr});\n"
    out << body
    out << "      #{iter_label}:;\n"
    out << "    }\n"
    out << "    #{break_label}:;\n"
    out << "  }\n"
    out
  end

  # EACH_INDEX_SUPPORT: emit_each_inline's live-length loop, but the parameter is
  # the counter (`mrb_fixnum_value(i)`): Array#each_index yields idx, not
  # self[idx]. No element hint (the value is an Integer). Returns the receiver.
  def emit_each_index_inline(region, irep, d)
    block_irep = region[:block_irep]
    offset = irep.nregs
    recv_expr = inline_recv_expr(region)
    param_reg = 1 + offset # the block's own single mandatory arg, R1 in its own numbering.
    addr = region[:block_addr]
    iter_label = "Lbc2cpp_eachidx_iter_#{addr}"
    break_label = "Lbc2cpp_eachidx_end_#{addr}"
    body = compile_inline_block_body(region, irep, d, iter_label, break_label: break_label)
    return nil unless body

    out = String.new
    out << "  {\n"
    out << inline_receiver_guard('mrb_array_p', recv_expr, 'Array receiver for inlined #each_index')
    out << "    for (mrb_int bc2cpp_eachidx_i_#{addr} = 0; " \
           "bc2cpp_eachidx_i_#{addr} < RARRAY_LEN(#{recv_expr}); " \
           "++bc2cpp_eachidx_i_#{addr}) {\n"
    out << inline_block_frame(block_irep, offset)
    out << "      r#{param_reg} = mrb_fixnum_value(bc2cpp_eachidx_i_#{addr});\n"
    out << body
    out << "      #{iter_label}:;\n"
    out << "    }\n"
    out << "    #{break_label}:;\n"
    out << "  }\n"
    out
  end

  def emit_hash_each_value_inline(region, irep, d)
    block_irep = region[:block_irep]
    offset = irep.nregs
    recv_expr = inline_recv_expr(region)
    value_reg = 1 + offset
    addr = region[:block_addr]
    iter_label = "Lbc2cpp_heval_iter_#{addr}"
    break_label = "Lbc2cpp_heval_end_#{addr}"
    body = compile_inline_block_body(region, irep, d, iter_label, break_label: break_label, elem_reg: '1')
    return nil unless body

    out = String.new
    out << "  {\n"
    out << "    if (!mrb_hash_p(#{recv_expr}) || mrb_obj_ptr(#{recv_expr})->c != M->hash_class) {\n"
    out << "      #{inline_raise('TypeError', 'expected exact Hash receiver for inlined #each_value')}\n"
    out << "    }\n"
    out << "    mrb_value bc2cpp_heval_values_#{addr} = mrb_hash_values(M, #{recv_expr});\n"
    out << "    for (mrb_int bc2cpp_heval_i_#{addr} = 0; " \
           "bc2cpp_heval_i_#{addr} < RARRAY_LEN(bc2cpp_heval_values_#{addr}); " \
           "++bc2cpp_heval_i_#{addr}) {\n"
    out << inline_block_frame(block_irep, offset)
    out << "      r#{value_reg} = bc2cpp_ary_entry(M, bc2cpp_heval_values_#{addr}, bc2cpp_heval_i_#{addr});\n"
    out << body
    out << "      #{iter_label}:;\n"
    out << "    }\n"
    out << "    #{break_label}:;\n"
    out << "  }\n"
    out
  end

  # HASH_EACH_SUPPORT: the inlined loop for `hash.each` (nil if not clean).
  # Differences from emit_each_inline (mrblib/hash.rb):
  #   - SNAPSHOT: Hash#each takes keys/values/size once. mrb_hash_keys and
  #     mrb_hash_values (public MRB_API) return fresh Arrays, so mutation during
  #     iteration cannot affect the loop.
  #   - Key and value are assigned directly to the block's R1/R2 (as the
  #     reduce/inject fold does).
  # An mrb_hash_p guard; BREAK wired; returns the receiver.
  def emit_hash_each_inline(region, irep, d)
    block_irep = region[:block_irep]
    offset = irep.nregs
    recv_expr = inline_recv_expr(region)
    key_reg = 1 + offset
    val_reg = 2 + offset # the block's own two mandatory args, R1/R2 in its own numbering.
    addr = region[:block_addr]
    iter_label = "Lbc2cpp_heach_iter_#{addr}"
    break_label = "Lbc2cpp_heach_end_#{addr}"
    # HASH_ELEMENT_SUPPORT: R2 is bound to the value below, so R2 is the loop value
    # (values only; see HashElementLayout).
    body = compile_inline_block_body(region, irep, d, iter_label, break_label: break_label, elem_reg: '2')
    return nil unless body

    out = String.new
    out << "  {\n"
    out << inline_receiver_guard('mrb_hash_p', recv_expr, 'Hash receiver for inlined #each')
    out << "    mrb_value bc2cpp_heach_keys_#{addr} = mrb_hash_keys(M, #{recv_expr});\n"
    out << "    mrb_value bc2cpp_heach_vals_#{addr} = mrb_hash_values(M, #{recv_expr});\n"
    out << "    mrb_int bc2cpp_heach_len_#{addr} = mrb_hash_size(M, #{recv_expr});\n"
    out << "    for (mrb_int bc2cpp_heach_i_#{addr} = 0; " \
           "bc2cpp_heach_i_#{addr} < bc2cpp_heach_len_#{addr}; " \
           "++bc2cpp_heach_i_#{addr}) {\n"
    out << inline_block_frame(block_irep, offset)
    out << "      r#{key_reg} = bc2cpp_ary_entry(M, bc2cpp_heach_keys_#{addr}, bc2cpp_heach_i_#{addr});\n"
    out << "      r#{val_reg} = bc2cpp_ary_entry(M, bc2cpp_heach_vals_#{addr}, bc2cpp_heach_i_#{addr});\n"
    out << body
    out << "      #{iter_label}:;\n"
    out << "    }\n"
    out << "    #{break_label}:;\n"
    out << "  }\n"
    out
  end

  # EACH_KEY_SUPPORT: emit_hash_each_inline's snapshot loop over keys only
  # (Hash#each_key never calls values); one value bound. Same guard; returns the
  # receiver.
  def emit_each_key_inline(region, irep, d)
    block_irep = region[:block_irep]
    offset = irep.nregs
    recv_expr = inline_recv_expr(region)
    key_reg = 1 + offset # the block's own single mandatory arg, R1 in its own numbering.
    addr = region[:block_addr]
    iter_label = "Lbc2cpp_ekey_iter_#{addr}"
    break_label = "Lbc2cpp_ekey_end_#{addr}"
    body = compile_inline_block_body(region, irep, d, iter_label, break_label: break_label)
    return nil unless body

    out = String.new
    out << "  {\n"
    out << inline_receiver_guard('mrb_hash_p', recv_expr, 'Hash receiver for inlined #each_key')
    out << "    mrb_value bc2cpp_ekey_keys_#{addr} = mrb_hash_keys(M, #{recv_expr});\n"
    out << "    mrb_int bc2cpp_ekey_len_#{addr} = mrb_hash_size(M, #{recv_expr});\n"
    out << "    for (mrb_int bc2cpp_ekey_i_#{addr} = 0; " \
           "bc2cpp_ekey_i_#{addr} < bc2cpp_ekey_len_#{addr}; " \
           "++bc2cpp_ekey_i_#{addr}) {\n"
    out << inline_block_frame(block_irep, offset)
    out << "      r#{key_reg} = bc2cpp_ary_entry(M, bc2cpp_ekey_keys_#{addr}, bc2cpp_ekey_i_#{addr});\n"
    out << body
    out << "      #{iter_label}:;\n"
    out << "    }\n"
    out << "    #{break_label}:;\n"
    out << "  }\n"
    out
  end

  # INTERP_UNLOCK: the inlined loop for Range#each (nil if not clean), following
  # mrblib/range.rb's integer fast path:
  #   - the element is the counter (`mrb_fixnum_value(i)`);
  #   - beg/end/excl are read once (Ranges are frozen by range_initialize);
  #   - `excl ? i < e : i <= e` instead of mrblib's `lim = end + 1`, which
  #     overflows at MRB_INT_MAX;
  #   - the guard is mrb_range_p AND Integer beg/end: Float edges, the `succ`
  #     path and endless ranges (an infinite loop) raise instead. The real excl
  #     flag (mrb_range_excl_p) is used, never `begin == end`.
  # Returns the receiver; BREAK, RETURN_BLK, upvars and jumps as in
  # compile_block_body_insn.
  def emit_range_each_inline(region, irep, d)
    block_irep = region[:block_irep]
    offset = irep.nregs
    recv = "r#{region[:dest_reg]}"
    param_reg = 1 + offset
    addr = region[:block_addr]
    iter_label = "Lbc2cpp_range_iter_#{addr}"
    break_label = "Lbc2cpp_range_end_#{addr}"
    body = compile_inline_block_body(region, irep, d, iter_label, break_label: break_label)
    return nil unless body

    out = String.new
    out << "  {\n"
    out << inline_receiver_guard('mrb_range_p', recv, 'Range receiver for inlined #each')
    out << "    mrb_value bc2cpp_range_b_#{addr} = mrb_range_beg(M, #{recv});\n"
    out << "    mrb_value bc2cpp_range_e_#{addr} = mrb_range_end(M, #{recv});\n"
    out << "    if (!mrb_integer_p(bc2cpp_range_b_#{addr}) || !mrb_integer_p(bc2cpp_range_e_#{addr})) { " \
           "#{inline_raise('TypeError', 'non-Integer Range#each left to interpreter')} }\n"
    out << "    mrb_int bc2cpp_range_a_#{addr} = mrb_integer(bc2cpp_range_b_#{addr});\n"
    out << "    mrb_int bc2cpp_range_z_#{addr} = mrb_integer(bc2cpp_range_e_#{addr});\n"
    out << "    mrb_bool bc2cpp_range_x_#{addr} = mrb_range_excl_p(M, #{recv});\n"
    out << "    for (mrb_int bc2cpp_range_i_#{addr} = bc2cpp_range_a_#{addr}; " \
           "bc2cpp_range_x_#{addr} ? bc2cpp_range_i_#{addr} < bc2cpp_range_z_#{addr} : bc2cpp_range_i_#{addr} <= bc2cpp_range_z_#{addr}; " \
           "++bc2cpp_range_i_#{addr}) {\n"
    out << inline_block_frame(block_irep, offset)
    out << "      r#{param_reg} = mrb_fixnum_value(bc2cpp_range_i_#{addr});\n"
    out << body
    out << "      #{iter_label}:;\n"
    out << "    }\n"
    out << "    #{break_label}:;\n"
    out << "  }\n"
    out
  end

  # MAP_BLOCK_SUPPORT: the inlined loop for a collection-block region (nil if not
  # clean). Differences from emit_each_inline:
  #   - result: map pushes each yielded value into a fresh accumulator (the
  #     destination gets it, not the receiver); select/reject push the element
  #     on a truthy/falsy result; find takes the first truthy element and exits
  #     (nil otherwise); each_with_index binds a second parameter to the index.
  #   - the yielded value (RETURN/RETNIL/RETFALSE/RETTRUE, i.e. `next`) is
  #     stored into the per-iteration result by compile_collect_body_insn; a
  #     bare `next` collects nil, as in Ruby.
  #   - `break v` sets the destination and jumps past the loop.
  #   - live RARRAY_LEN and mrb_array_p guard as in each.
  def emit_collect_inline(region, irep, d)
    block_irep = region[:block_irep]
    offset = irep.nregs
    dest_reg = region[:dest_reg]
    recv_expr = inline_recv_expr(region)
    meth = region[:method_name]
    param_reg = 1 + offset
    param2_reg = 2 + offset # each_with_index's own index arg, R2 in block numbering.
    addr = region[:block_addr]
    iter_label = "Lbc2cpp_collect_iter_#{addr}"
    break_label = "Lbc2cpp_collect_end_#{addr}"
    result_var = "bc2cpp_collect_v_#{addr}"
    # ELEMENT_CLASS_SUPPORT: R1 is the element for every admitted method;
    # each_with_index's R2 (the index) is not hinted.
    body = compile_inline_block_body(region, irep, d, iter_label, break_label: break_label, result_var: result_var,
                                                                  broke_flag: "bc2cpp_collect_broke_#{addr}", elem_reg: '1')
    return nil unless body

    out = String.new
    out << "  {\n"
    out << inline_receiver_guard('mrb_array_p', recv_expr, "Array receiver for inlined ##{meth}")
    out << "    mrb_value bc2cpp_collect_acc_#{addr} = mrb_ary_new(M);\n" if %w[map select reject flat_map filter_map].include?(meth)
    out << "    mrb_value bc2cpp_collect_found_#{addr} = mrb_nil_value();\n" if meth == 'find'
    out << "    mrb_bool bc2cpp_collect_broke_#{addr} = FALSE;\n" if meth != 'each_with_index'
    out << "    for (mrb_int bc2cpp_collect_i_#{addr} = 0; " \
           "bc2cpp_collect_i_#{addr} < RARRAY_LEN(#{recv_expr}); " \
           "++bc2cpp_collect_i_#{addr}) {\n"
    out << inline_block_frame(block_irep, offset)
    out << "      mrb_value #{result_var} = mrb_nil_value();\n"
    out << "      r#{param_reg} = bc2cpp_ary_entry(M, #{recv_expr}, bc2cpp_collect_i_#{addr});\n"
    out << "      r#{param2_reg} = mrb_fixnum_value(bc2cpp_collect_i_#{addr});\n" if meth == 'each_with_index'
    out << body
    out << "      #{iter_label}:;\n"
    case meth
    when 'map'
      out << "      mrb_ary_push(M, bc2cpp_collect_acc_#{addr}, #{result_var});\n"
    when 'flat_map'
      # INTERP_UNLOCK: mruby's flat_map (mruby-enum-ext enum.rb) pushes a yielded
      # value whole unless it responds to `each`, else pushes its elements (one
      # level). The same respond_to? test is used, but expansion goes through
      # RARRAY_LEN only after an mrb_array_p tripwire: a Hash/Range yielder responds
      # to `each` without being an Array, and RARRAY_LEN on it would misread memory.
      # So yielding a non-Array each-responder raises here where the VM would
      # expand it: a deliberate narrowing (the game's flat_map blocks yield Arrays).
      out << "      if (mrb_test(mrb_funcall(M, #{result_var}, \"respond_to?\", 1, mrb_symbol_value(mrb_intern_cstr(M, \"each\"))))) {\n"
      out << "      if (!mrb_array_p(#{result_var})) { #{inline_raise('TypeError', 'flat_map yielded non-Array')} }\n"
      out << "      mrb_int bc2cpp_collect_fm_n_#{addr} = RARRAY_LEN(#{result_var});\n"
      out << "      for (mrb_int bc2cpp_collect_fm_i_#{addr} = 0; bc2cpp_collect_fm_i_#{addr} < bc2cpp_collect_fm_n_#{addr}; ++bc2cpp_collect_fm_i_#{addr}) {\n"
      out << "        mrb_ary_push(M, bc2cpp_collect_acc_#{addr}, bc2cpp_ary_entry(M, #{result_var}, bc2cpp_collect_fm_i_#{addr}));\n"
      out << "      }\n"
      out << "      } else {\n"
      out << "        mrb_ary_push(M, bc2cpp_collect_acc_#{addr}, #{result_var});\n"
      out << "      }\n"
    when 'select'
      out << "      if (mrb_test(#{result_var})) mrb_ary_push(M, bc2cpp_collect_acc_#{addr}, r#{param_reg});\n"
    when 'reject'
      out << "      if (!mrb_test(#{result_var})) mrb_ary_push(M, bc2cpp_collect_acc_#{addr}, r#{param_reg});\n"
    when 'find'
      out << "      if (mrb_test(#{result_var})) { bc2cpp_collect_found_#{addr} = r#{param_reg}; goto #{break_label}; }\n"
    when 'filter_map'
      # filter_map pushes the block's RESULT when truthy (Enumerable#filter_map
      # reassigns `x = blk.call(*x)` before `ary.push x if x`).
      out << "      if (mrb_test(#{result_var})) mrb_ary_push(M, bc2cpp_collect_acc_#{addr}, #{result_var});\n"
    end
    out << "    }\n"
    out << "    #{break_label}:;\n"
    # A BREAK jumps here with the destination already holding the break value, so
    # the final accumulator assignment must not run on that path. A dedicated
    # flag set only by BREAK is used: comparing the loop index fails when
    # elements are popped during iteration. each_with_index needs neither the flag
    # nor the assignment.
    if meth != 'each_with_index'
      out << "    if (!bc2cpp_collect_broke_#{addr}) {\n"
      case meth
      when 'map', 'select', 'reject', 'flat_map', 'filter_map'
        out << "    r#{dest_reg} = bc2cpp_collect_acc_#{addr};\n"
      when 'find'
        out << "    r#{dest_reg} = bc2cpp_collect_found_#{addr};\n"
      end
      out << "    }\n"
    end
    out << "  }\n"
    out
  end

  # ACCUM_BLOCK_SUPPORT: the inlined loop for an accumulator/predicate region
  # (nil if not clean), cloned from emit_collect_inline:
  #   - any?/all?/none?: boolean destination with early exit (defaults and
  #     exits as in recognize_accum_regions); `break v` overrides via the
  #     broke flag; empty arrays get the defaults.
  #   - count: a fixnum tally, no early exit; `break v` overrides.
  #   - reduce/inject(init): the accumulator is seeded ONCE from R(dest+1)
  #     before the loop, bound to param 1 with the element in param 2, and
  #     replaced by the yielded value. Reading init before the loop makes a
  #     later level-0 SETUPVAR to that register irrelevant.
  def emit_accum_inline(region, irep, d)
    block_irep = region[:block_irep]
    offset = irep.nregs
    dest_reg = region[:dest_reg]
    recv_expr = inline_recv_expr(region)
    meth = region[:method_name]
    is_fold = !region[:init_reg].nil?
    param_reg = 1 + offset
    param2_reg = 2 + offset
    addr = region[:block_addr]
    acc_var = "bc2cpp_accum_acc_#{addr}"
    iter_label = "Lbc2cpp_accum_iter_#{addr}"
    break_label = "Lbc2cpp_accum_end_#{addr}"
    result_var = "bc2cpp_accum_v_#{addr}"
    # ELEMENT_CLASS_SUPPORT: predicates take the element in R1; a fold takes the
    # accumulator in R1 and the element in R2. Read from the same `is_fold` flag
    # as the binding below.
    body = compile_inline_block_body(region, irep, d, iter_label, break_label: break_label, result_var: result_var,
                                                                  broke_flag: "bc2cpp_accum_broke_#{addr}",
                                                                  elem_reg: is_fold ? '2' : '1')
    return nil unless body

    out = String.new
    out << "  {\n"
    out << inline_receiver_guard('mrb_array_p', recv_expr, "Array receiver for inlined ##{meth}")
    out << "    mrb_bool bc2cpp_accum_broke_#{addr} = FALSE;\n"
    case meth
    when 'any?'
      out << "    mrb_value bc2cpp_accum_res_#{addr} = mrb_false_value();\n"
    when 'all?', 'none?'
      out << "    mrb_value bc2cpp_accum_res_#{addr} = mrb_true_value();\n"
    when 'count'
      out << "    mrb_int bc2cpp_accum_n_#{addr} = 0;\n"
    when 'reduce', 'inject'
      out << "    mrb_value #{acc_var} = r#{region[:init_reg]};\n"
    end
    out << "    for (mrb_int bc2cpp_accum_i_#{addr} = 0; " \
           "bc2cpp_accum_i_#{addr} < RARRAY_LEN(#{recv_expr}); " \
           "++bc2cpp_accum_i_#{addr}) {\n"
    out << inline_block_frame(block_irep, offset)
    out << "      mrb_value #{result_var} = mrb_nil_value();\n"
    if is_fold
      out << "      r#{param_reg} = #{acc_var};\n"
      out << "      r#{param2_reg} = bc2cpp_ary_entry(M, #{recv_expr}, bc2cpp_accum_i_#{addr});\n"
    else
      out << "      r#{param_reg} = bc2cpp_ary_entry(M, #{recv_expr}, bc2cpp_accum_i_#{addr});\n"
    end
    out << body
    out << "      #{iter_label}:;\n"
    case meth
    when 'any?'
      out << "      if (mrb_test(#{result_var})) { bc2cpp_accum_res_#{addr} = mrb_true_value(); goto #{break_label}; }\n"
    when 'all?'
      out << "      if (!mrb_test(#{result_var})) { bc2cpp_accum_res_#{addr} = mrb_false_value(); goto #{break_label}; }\n"
    when 'none?'
      out << "      if (mrb_test(#{result_var})) { bc2cpp_accum_res_#{addr} = mrb_false_value(); goto #{break_label}; }\n"
    when 'count'
      out << "      if (mrb_test(#{result_var})) ++bc2cpp_accum_n_#{addr};\n"
    when 'reduce', 'inject'
      out << "      #{acc_var} = #{result_var};\n"
    end
    out << "    }\n"
    out << "    #{break_label}:;\n"
    out << "    if (!bc2cpp_accum_broke_#{addr}) {\n"
    case meth
    when 'any?', 'all?', 'none?'
      out << "    r#{dest_reg} = bc2cpp_accum_res_#{addr};\n"
    when 'count'
      out << "    r#{dest_reg} = mrb_fixnum_value(bc2cpp_accum_n_#{addr});\n"
    when 'reduce', 'inject'
      out << "    r#{dest_reg} = #{acc_var};\n"
    end
    out << "    }\n"
    out << "  }\n"
    out
  end

  # MAP_BLOCK_SUPPORT: compile_block_body_insn, except the ordinary return forms
  # (`next`, with or without a value) store their value into `result_var` before
  # jumping to iter-end, since collection methods use it. RETURN_BLK is still a
  # plain C++ return.
  def compile_collect_body_insn(insn, block_irep, owner_def, offset, iter_end_label, label_prefix,
                                result_var:, break_dest:, break_label:, broke_flag:, idx: nil)
    case insn.op
    when 'RETURN', 'RETNIL', 'RETFALSE', 'RETTRUE'
      r = insn.op == 'RETURN' ? (insn.args.strip.empty? ? '0' : insn.args[/^R(\d+)/, 1]) : nil
      store = case insn.op
              when 'RETURN' then "r#{r.to_i + offset}"
              when 'RETNIL' then 'mrb_nil_value()'
              when 'RETFALSE' then 'mrb_false_value()'
              when 'RETTRUE' then 'mrb_true_value()'
              end
      "  #{result_var} = #{store};\n  goto #{iter_end_label};\n"
    when 'BREAK'
      # Same value semantics as compile_block_body_insn's BREAK, plus the broke
      # flag so the post-loop accumulator assignment is skipped.
      r = insn.args.strip.empty? ? '0' : insn.args[/^R(\d+)/, 1]
      "  r#{break_dest} = r#{r.to_i + offset};\n  #{broke_flag} = TRUE;\n  goto #{break_label};\n"
    else
      compile_block_body_insn(insn, block_irep, owner_def, offset, iter_end_label, label_prefix,
                              break_dest: break_dest, break_label: break_label, idx: idx)
    end
  end

  # EACH_BLOCK_SUPPORT: the inlined loop for a `&:sym` site. Each iteration does
  # `mrb_funcall(M, elem, "<sym>", 0)`, which is what Symbol#to_proc does, and
  # accumulates per method:
  #   each: discard (destination keeps the receiver);
  #   map: push each result into a fresh Array;
  #   select/reject: push the ELEMENT when the result is truthy/falsy;
  #   find: first element with a truthy result (else nil), early exit;
  #   any?/all?/none?: boolean with early exit (all?/none? default true);
  #   count: tally of truthy results.
  # Live length and mrb_array_p guard as in emit_each_inline.
  def emit_sym_inline(region, _irep, _d)
    dest_reg = region[:dest_reg]
    recv_expr = inline_recv_expr(region)
    meth = region[:method_name]
    sym = region[:sym_name]
    return nil unless SYM_BLOCK_METHODS.include?(meth)

    iter_label = "Lbc2cpp_sym_iter_#{region[:sym_addr]}"
    end_label = "Lbc2cpp_sym_end_#{region[:sym_addr]}"
    out = String.new
    out << "  {\n"
    out << inline_receiver_guard('mrb_array_p', recv_expr, "Array receiver for inlined &:#{sym}")
    case meth
    when 'map', 'select', 'reject'
      out << "    mrb_value bc2cpp_sym_acc_#{region[:sym_addr]} = mrb_ary_new(M);\n"
    when 'find'
      out << "    mrb_value bc2cpp_sym_acc_#{region[:sym_addr]} = mrb_nil_value();\n"
    when 'any?', 'none?'
      out << "    mrb_value bc2cpp_sym_acc_#{region[:sym_addr]} = mrb_false_value();\n"
    when 'all?'
      out << "    mrb_value bc2cpp_sym_acc_#{region[:sym_addr]} = mrb_true_value();\n"
    when 'count'
      out << "    mrb_int bc2cpp_sym_acc_#{region[:sym_addr]} = 0;\n"
    end
    out << "    for (mrb_int bc2cpp_sym_i_#{region[:sym_addr]} = 0; " \
           "bc2cpp_sym_i_#{region[:sym_addr]} < RARRAY_LEN(#{recv_expr}); " \
           "++bc2cpp_sym_i_#{region[:sym_addr]}) {\n"
    out << "      mrb_value bc2cpp_sym_e_#{region[:sym_addr]} = " \
           "bc2cpp_ary_entry(M, #{recv_expr}, bc2cpp_sym_i_#{region[:sym_addr]});\n"
    if meth == 'each'
      out << "      #{sym_call_line(sym, "bc2cpp_sym_e_#{region[:sym_addr]}")}\n"
    else
      out << "      #{sym_call_value(sym, "bc2cpp_sym_e_#{region[:sym_addr]}", "bc2cpp_sym_r_#{region[:sym_addr]}")}\n"
      case meth
      when 'map'
        out << "      mrb_ary_push(M, bc2cpp_sym_acc_#{region[:sym_addr]}, bc2cpp_sym_r_#{region[:sym_addr]});\n"
      when 'select'
        out << "      if (mrb_test(bc2cpp_sym_r_#{region[:sym_addr]})) " \
               "mrb_ary_push(M, bc2cpp_sym_acc_#{region[:sym_addr]}, bc2cpp_sym_e_#{region[:sym_addr]});\n"
      when 'reject'
        out << "      if (!mrb_test(bc2cpp_sym_r_#{region[:sym_addr]})) " \
               "mrb_ary_push(M, bc2cpp_sym_acc_#{region[:sym_addr]}, bc2cpp_sym_e_#{region[:sym_addr]});\n"
      when 'find'
        out << "      if (mrb_test(bc2cpp_sym_r_#{region[:sym_addr]})) { " \
               "bc2cpp_sym_acc_#{region[:sym_addr]} = bc2cpp_sym_e_#{region[:sym_addr]}; " \
               "goto #{end_label}; }\n"
      when 'any?'
        out << "      if (mrb_test(bc2cpp_sym_r_#{region[:sym_addr]})) { " \
               "bc2cpp_sym_acc_#{region[:sym_addr]} = mrb_true_value(); goto #{end_label}; }\n"
      when 'all?'
        out << "      if (!mrb_test(bc2cpp_sym_r_#{region[:sym_addr]})) { " \
               "bc2cpp_sym_acc_#{region[:sym_addr]} = mrb_false_value(); goto #{end_label}; }\n"
      when 'none?'
        out << "      if (mrb_test(bc2cpp_sym_r_#{region[:sym_addr]})) { " \
               "bc2cpp_sym_acc_#{region[:sym_addr]} = mrb_false_value(); goto #{end_label}; }\n"
      when 'count'
        out << "      if (mrb_test(bc2cpp_sym_r_#{region[:sym_addr]})) ++bc2cpp_sym_acc_#{region[:sym_addr]};\n"
      end
    end
    out << "      #{iter_label}:;\n"
    out << "    }\n"
    out << "    #{end_label}:;\n"
    case meth
    when 'each'
      # `each` returns the receiver, already in the destination register.
    when 'count'
      out << "    r#{dest_reg} = mrb_fixnum_value(bc2cpp_sym_acc_#{region[:sym_addr]});\n"
    else
      out << "    r#{dest_reg} = bc2cpp_sym_acc_#{region[:sym_addr]};\n"
    end
    out << "  }\n"
    out
  end

  # SYM_DEVIRT: the per-element call for a `&:sym` site, devirtualized where
  # sym_call_target allows. sym_call_value declares `mrb_value <result_var> =
  # ...`; sym_call_line emits the discarded call for `each`. The element is the
  # loop's `bc2cpp_sym_e_N` local.
  # A POLY chain is an if/else-if/else statement (C has no if-expression), hence
  # two helpers.
  # Sound: the mrb_funcall fallback is exactly Symbol#to_proc (no closure to
  # lose); MONO needs no guard (one def); each POLY branch guards exact class.
  def sym_call_value(sym, elem_expr, result_var)
    kind, target = sym_call_target(sym) || [nil, nil]
    fallback = "mrb_funcall(M, #{elem_expr}, \"#{sym}\", 0)"
    return "mrb_value #{result_var} = #{fallback};" unless kind

    if kind == :mono
      impl = cpp_name(target.owner, target.name) + '_impl'
      return "// MONO &:#{sym} -> #{target.owner}##{target.name}, direct C++ call (no mrb_funcall)\n" \
             "      mrb_value #{result_var} = #{impl}(M, #{elem_expr});"
    end

    out = String.new
    out << "// POLY &:#{sym} (#{target.size} defs) -- per-element exact-class guard chain, mrb_funcall fallback\n"
    out << "      mrb_value #{result_var} = mrb_nil_value();\n"
    target.each_with_index do |d, i|
      impl = cpp_name(d.owner, d.name) + '_impl'
      check = "#{owner_class_ptr_expr(d.owner)} == mrb_obj_class(M, #{elem_expr})"
      out << (i.zero? ? '      ' : '      else ')
      out << "if (#{check}) { #{result_var} = #{impl}(M, #{elem_expr}); }\n"
    end
    out << "      else { #{result_var} = #{fallback}; }\n"
    out
  end

  def sym_call_line(sym, elem_expr)
    kind, target = sym_call_target(sym) || [nil, nil]
    fallback = "mrb_funcall(M, #{elem_expr}, \"#{sym}\", 0);"
    return fallback unless kind

    if kind == :mono
      impl = cpp_name(target.owner, target.name) + '_impl'
      return "// MONO &:#{sym} -> #{target.owner}##{target.name}, direct C++ call (no mrb_funcall)\n" \
             "      #{impl}(M, #{elem_expr});"
    end

    out = String.new
    out << "// POLY &:#{sym} (#{target.size} defs) -- per-element exact-class guard chain, mrb_funcall fallback\n"
    target.each_with_index do |d, i|
      impl = cpp_name(d.owner, d.name) + '_impl'
      check = "#{owner_class_ptr_expr(d.owner)} == mrb_obj_class(M, #{elem_expr})"
      out << (i.zero? ? '      ' : '      else ')
      out << "if (#{check}) { #{impl}(M, #{elem_expr}); }\n"
    end
    out << "      else { #{fallback} }\n"
    out
  end

  # SORT_BLOCK_SUPPORT: the inlined replacement for a sort-family region (nil if
  # not clean).
  # - `sort { |a, b| ... }`: returns nil (stays interpreted): the comparator runs
  #   inside the native sort, which cannot be reproduced as a loop. Bare `sort`
  #   is an ordinary SEND.
  # - `sort_by`/`uniq` with a key block: a Schwartzian transform:
  #     1. keys[i] = block(elem[i]) (compile_collect_body_insn: `next` collects
  #        nil, `break` overrides via the broke flag);
  #     2. pairs[i] = [keys[i], i, elem[i]]; the index keeps the sort stable
  #        (mruby's sort is not, CRuby's sort_by is);
  #     3. sort pairs by (key, index) with mrb_cmp (public; -2 when
  #        incomparable, like the native sort);
  #     4. dest[i] = pairs[i][2].
  #   `uniq` keeps the first element per key (drop adjacent equal keys,
  #   mrb_cmp == 0, after the stable sort). All temporaries are fresh arrays;
  #   the receiver is only read.
  def emit_sort_inline(region, irep, d)
    return nil if region[:method_name] == 'sort'

    block_irep = region[:block_irep]
    offset = irep.nregs
    dest_reg = region[:dest_reg]
    recv_expr = inline_recv_expr(region)
    meth = region[:method_name]
    param_reg = 1 + offset
    addr = region[:block_addr]
    iter_label = "Lbc2cpp_sort_iter_#{addr}"
    break_label = "Lbc2cpp_sort_end_#{addr}"
    result_var = "bc2cpp_sort_v_#{addr}"
    # ELEMENT_CLASS_SUPPORT: a sort_by/uniq key block takes the element as R1.
    body = compile_inline_block_body(region, irep, d, iter_label, break_label: break_label, result_var: result_var,
                                                                  broke_flag: "bc2cpp_sort_broke_#{addr}", elem_reg: '1')
    return nil unless body

    out = String.new
    out << "  {\n"
    out << inline_receiver_guard('mrb_array_p', recv_expr, "Array receiver for inlined ##{meth}")
    out << "    mrb_bool bc2cpp_sort_broke_#{addr} = FALSE;\n"
    out << "    mrb_int bc2cpp_sort_n_#{addr} = RARRAY_LEN(#{recv_expr});\n"
    out << "    mrb_value bc2cpp_sort_keys_#{addr} = mrb_ary_new_capa(M, bc2cpp_sort_n_#{addr});\n"
    out << "    for (mrb_int bc2cpp_sort_i_#{addr} = 0; bc2cpp_sort_i_#{addr} < RARRAY_LEN(#{recv_expr}); ++bc2cpp_sort_i_#{addr}) {\n"
    out << inline_block_frame(block_irep, offset)
    out << "      mrb_value #{result_var} = mrb_nil_value();\n"
    out << "      r#{param_reg} = bc2cpp_ary_entry(M, #{recv_expr}, bc2cpp_sort_i_#{addr});\n"
    out << body
    out << "      #{iter_label}:;\n"
    out << "      mrb_ary_push(M, bc2cpp_sort_keys_#{addr}, #{result_var});\n"
    out << "    }\n"
    # The key loop re-checks live RARRAY_LEN (the same live-length rule as the
    # other emitters), so keys are 1:1 with visited elements. The sort phase loops
    # over the key array's length and fetches elements with mrb_ary_ref (nil if
    # the receiver shrank). Only a body that mutates the receiver can make them
    # differ, and the native sort raises "array modified during sort" there anyway.
    out << "    #{break_label}:;\n"
    out << "    if (!bc2cpp_sort_broke_#{addr}) {\n"
    out << "    mrb_int bc2cpp_sort_m_#{addr} = RARRAY_LEN(bc2cpp_sort_keys_#{addr});\n"
    out << "    mrb_value bc2cpp_sort_pairs_#{addr} = mrb_ary_new_capa(M, bc2cpp_sort_m_#{addr});\n"
    out << "    for (mrb_int bc2cpp_sort_j_#{addr} = 0; bc2cpp_sort_j_#{addr} < bc2cpp_sort_m_#{addr}; ++bc2cpp_sort_j_#{addr}) {\n"
    out << "      mrb_value bc2cpp_sort_e_#{addr} = bc2cpp_ary_entry(M, #{recv_expr}, bc2cpp_sort_j_#{addr});\n"
    out << "      mrb_value bc2cpp_sort_k_#{addr} = bc2cpp_ary_entry(M, bc2cpp_sort_keys_#{addr}, bc2cpp_sort_j_#{addr});\n"
    out << "      mrb_value bc2cpp_sort_trip_#{addr} = mrb_ary_new_capa(M, 3);\n"
    out << "      mrb_ary_push(M, bc2cpp_sort_trip_#{addr}, bc2cpp_sort_k_#{addr});\n"
    out << "      mrb_ary_push(M, bc2cpp_sort_trip_#{addr}, mrb_fixnum_value(bc2cpp_sort_j_#{addr}));\n"
    out << "      mrb_ary_push(M, bc2cpp_sort_trip_#{addr}, bc2cpp_sort_e_#{addr});\n"
    out << "      mrb_ary_push(M, bc2cpp_sort_pairs_#{addr}, bc2cpp_sort_trip_#{addr});\n"
    out << "    }\n"
    # Insertion sort on (key, index): O(n^2) but these arrays are small, and the
    # index tiebreak makes it stable at any size. mrb_cmp returns 1/0/-1, or -2 when
    # incomparable (the native sort_cmp contract; incomparable keys raise). The
    # decorated index is always our own fixnum, so mrb_integer cannot fail.
    out << "    for (mrb_int bc2cpp_sort_a_#{addr} = 1; bc2cpp_sort_a_#{addr} < bc2cpp_sort_m_#{addr}; ++bc2cpp_sort_a_#{addr}) {\n"
    out << "      mrb_value bc2cpp_sort_tmp_#{addr} = bc2cpp_ary_entry(M, bc2cpp_sort_pairs_#{addr}, bc2cpp_sort_a_#{addr});\n"
    out << "      mrb_int bc2cpp_sort_b_#{addr} = bc2cpp_sort_a_#{addr} - 1;\n"
    out << "      while (bc2cpp_sort_b_#{addr} >= 0) {\n"
    out << "        mrb_value bc2cpp_sort_pa_#{addr} = bc2cpp_ary_entry(M, bc2cpp_sort_pairs_#{addr}, bc2cpp_sort_b_#{addr});\n"
    out << "        mrb_value bc2cpp_sort_ka_#{addr} = bc2cpp_ary_entry(M, bc2cpp_sort_pa_#{addr}, 0);\n"
    out << "        mrb_value bc2cpp_sort_ia_#{addr} = bc2cpp_ary_entry(M, bc2cpp_sort_pa_#{addr}, 1);\n"
    out << "        mrb_value bc2cpp_sort_kb_#{addr} = bc2cpp_ary_entry(M, bc2cpp_sort_tmp_#{addr}, 0);\n"
    out << "        mrb_value bc2cpp_sort_ib_#{addr} = bc2cpp_ary_entry(M, bc2cpp_sort_tmp_#{addr}, 1);\n"
    out << "        mrb_int bc2cpp_sort_c_#{addr} = mrb_cmp(M, bc2cpp_sort_kb_#{addr}, bc2cpp_sort_ka_#{addr});\n"
    out << "        if (bc2cpp_sort_c_#{addr} == -2) { #{inline_raise('ArgumentError', 'sort_by comparison failed')} }\n"
    out << "        if (bc2cpp_sort_c_#{addr} == 0) { bc2cpp_sort_c_#{addr} = (mrb_integer(bc2cpp_sort_ib_#{addr}) < mrb_integer(bc2cpp_sort_ia_#{addr})) ? -1 : 1; }\n"
    out << "        if (bc2cpp_sort_c_#{addr} >= 0) break;\n"
    out << "        mrb_ary_set(M, bc2cpp_sort_pairs_#{addr}, bc2cpp_sort_b_#{addr} + 1, bc2cpp_sort_pa_#{addr});\n"
    out << "        --bc2cpp_sort_b_#{addr};\n"
    out << "      }\n"
    out << "      mrb_ary_set(M, bc2cpp_sort_pairs_#{addr}, bc2cpp_sort_b_#{addr} + 1, bc2cpp_sort_tmp_#{addr});\n"
    out << "    }\n"
    out << "    r#{dest_reg} = mrb_ary_new_capa(M, bc2cpp_sort_m_#{addr});\n"
    if meth == 'uniq'
      out << "    mrb_value bc2cpp_sort_lastk_#{addr} = mrb_nil_value();\n"
      out << "    mrb_bool bc2cpp_sort_havek_#{addr} = FALSE;\n"
      out << "    for (mrb_int bc2cpp_sort_u_#{addr} = 0; bc2cpp_sort_u_#{addr} < bc2cpp_sort_m_#{addr}; ++bc2cpp_sort_u_#{addr}) {\n"
      out << "      mrb_value bc2cpp_sort_pu_#{addr} = bc2cpp_ary_entry(M, bc2cpp_sort_pairs_#{addr}, bc2cpp_sort_u_#{addr});\n"
      out << "      mrb_value bc2cpp_sort_ku_#{addr} = bc2cpp_ary_entry(M, bc2cpp_sort_pu_#{addr}, 0);\n"
      out << "      mrb_int bc2cpp_sort_eq_#{addr} = (bc2cpp_sort_havek_#{addr} && mrb_cmp(M, bc2cpp_sort_ku_#{addr}, bc2cpp_sort_lastk_#{addr}) == 0) ? 1 : 0;\n"
      out << "      if (!bc2cpp_sort_eq_#{addr}) { mrb_ary_push(M, r#{dest_reg}, bc2cpp_ary_entry(M, bc2cpp_sort_pu_#{addr}, 2)); }\n"
      out << "      bc2cpp_sort_lastk_#{addr} = bc2cpp_sort_ku_#{addr};\n"
      out << "      bc2cpp_sort_havek_#{addr} = TRUE;\n"
      out << "    }\n"
    else
      out << "    for (mrb_int bc2cpp_sort_u_#{addr} = 0; bc2cpp_sort_u_#{addr} < bc2cpp_sort_m_#{addr}; ++bc2cpp_sort_u_#{addr}) {\n"
      out << "      mrb_ary_push(M, r#{dest_reg}, bc2cpp_ary_entry(M, bc2cpp_ary_entry(M, bc2cpp_sort_pairs_#{addr}, bc2cpp_sort_u_#{addr}), 2));\n"
      out << "    }\n"
    end
    out << "    }\n"
    out << "  }\n"
    out
  end
end
