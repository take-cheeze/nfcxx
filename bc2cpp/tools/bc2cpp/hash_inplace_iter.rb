# frozen_string_literal: true

# HASH_INPLACE_ITER: an inlined loop over a Hash's keys or values reads them from one walk of the Hash
# (mrb_hash_foreach) into a C buffer, not from the Array mrb_hash_keys/mrb_hash_values builds:
#   - `hash.each`, `each_value` and `each_key` regions (emit_hash_each_inline and the two after it);
#   - an Array loop region (any?/all?/none?/count/index/find, map/select/reject, their `&:sym` forms) whose receiver
#     is the result of `values`/`keys` on the instruction before its block, which the region then absorbs.
# Soundness:
#   - snapshot: mrblib's Hash#each/#each_key/#each_value and Hash#keys/#values read every entry once, before the
#     first yield; the buffer holds the same entries in the same order, so a body that mutates the Hash sees what
#     it saw before;
#   - roots: each buffered heap value is rooted in the arena (bc2cpp_root), where the Array it replaces was, so a
#     value the body unlinks from the Hash lives as long as before;
#   - receiver: the absorbed send's receiver is proven Hash by the flow or the trace (no run-time guarded proof), and
#     `values`/`keys` on Hash is the core C method (hash_source_defs_core?); the loop runs behind an exact-Hash test
#     whose else raises, as the region emitters' own receiver tests do;
#   - a Hash too large for the buffer goes to one fresh Array, as before.
# BC2CPP_HASH_INPLACE_ITER=0 keeps the Arrays; BC2CPP_HASH_INPLACE_ITER_VERIFY=1 compares every snapshot with the
# Arrays it replaces and aborts on a difference.
module HashInplaceIter
  MODES = { values: 1, keys: 2, pairs: 3 }.freeze
  # The Array loop regions that may absorb the send, and the methods among them whose result is not the receiver.
  FUSED_PASSES = %i[recognize_accum_regions recognize_sym_regions recognize_collect_regions].freeze
  FUSED_METHODS = %w[any? all? none? count index find map select reject filter_map].freeze
  SOURCE_NAMES = { 'values' => :values, 'keys' => :keys }.freeze

  module_function

  def on?
    ENV['BC2CPP_HASH_INPLACE_ITER'] != '0'
  end

  def verify?
    ENV['BC2CPP_HASH_INPLACE_ITER_VERIFY'] == '1'
  end

  RUNTIME = <<~'CPP'
    // HASH_INPLACE_ITER (hash_inplace_iter.rb): an exact Hash's values (mode 1), keys (2) or key/value pairs (3),
    // read once in entry order as Hash#keys/#values do. They go to +buf+ when they fit, each heap value rooted in the
    // arena as the Array they replace would keep it; else to one fresh Array. *n is the entry count.
    #ifndef BC2CPP_HASH_SNAP_CAP
    #define BC2CPP_HASH_SNAP_CAP 16
    #endif
    struct bc2cpp_hash_snap_fill { mrb_value* buf; mrb_value ary; int mode; mrb_int i; };
    static inline void bc2cpp_hash_snap_put(mrb_state* M, bc2cpp_hash_snap_fill* f, mrb_value x) {
      if (mrb_nil_p(f->ary)) f->buf[f->i++] = x;
      else mrb_ary_push(M, f->ary, x);
    }
    [[gnu::noinline]] inline const mrb_value* bc2cpp_hash_snapshot(mrb_state* M, mrb_value h, int mode, mrb_value* buf,
                                                                   mrb_int* n) {
      mrb_int size = mrb_hash_size(M, h);
      mrb_int len = mode == 3 ? size * 2 : size;
      *n = size;
      bc2cpp_hash_snap_fill f = {buf, mrb_nil_value(), mode, 0};
      // The Array is made before the walk: the walk itself allocates nothing, so no GC step sees a half-read Hash.
      if (len > BC2CPP_HASH_SNAP_CAP) f.ary = mrb_ary_new_capa(M, len);
      if (size > 0) {
        mrb_hash_foreach(M, mrb_hash_ptr(h), [](mrb_state* M, mrb_value k, mrb_value v, void* p) -> int {
          bc2cpp_hash_snap_fill* f = static_cast<bc2cpp_hash_snap_fill*>(p);
          if (f->mode != 1) bc2cpp_hash_snap_put(M, f, k);
          if (f->mode != 2) bc2cpp_hash_snap_put(M, f, v);
          return 0;
        }, &f);
      }
      if (!mrb_nil_p(f.ary)) return RARRAY_PTR(f.ary);
      for (mrb_int i = 0; i < f.i; i++) bc2cpp_root(M, buf[i]);
      return buf;
    }
  CPP

  VERIFY_RUNTIME = <<~'CPP'
    // HASH_INPLACE_ITER_VERIFY: the snapshot is what mrb_hash_keys/mrb_hash_values return, element for element.
    [[gnu::noinline]] inline void bc2cpp_hash_snapshot_verify(mrb_state* M, mrb_value h, int mode, const mrb_value* v,
                                                              mrb_int n, const char* message) {
      int ai = mrb_gc_arena_save(M);
      mrb_value keys = mrb_hash_keys(M, h);
      mrb_value vals = mrb_hash_values(M, h);
      mrb_int w = mode == 3 ? 2 : 1;
      bool ok = RARRAY_LEN(keys) == n && RARRAY_LEN(vals) == n;
      for (mrb_int i = 0; ok && i < n; i++) {
        if (mode != 1 && !mrb_obj_eq(M, v[i * w], RARRAY_PTR(keys)[i])) ok = false;
        if (mode != 2 && !mrb_obj_eq(M, v[i * w + (mode == 3 ? 1 : 0)], RARRAY_PTR(vals)[i])) ok = false;
      }
      mrb_gc_arena_restore(M, ai);
      if (!ok) mrb_bug(M, message);
    }
  CPP
end

class CodeGen
  # The lines opening a snapshot of the Hash in +recv+ (already tested) under locals named +tag+_buf/_n/_v.
  def hash_snapshot_lines(recv, mode, tag, irep)
    out = String.new
    out << "    mrb_value #{tag}_buf[BC2CPP_HASH_SNAP_CAP];\n"
    out << "    mrb_int #{tag}_n;\n"
    out << "    const mrb_value* #{tag}_v = bc2cpp_hash_snapshot(M, #{recv}, #{HashInplaceIter::MODES.fetch(mode)}, " \
           "#{tag}_buf, &#{tag}_n); // HASH_INPLACE_ITER #{mode}\n"
    if HashInplaceIter.verify?
      message = "HASH_INPLACE_ITER_VERIFY: snapshot differs from the Hash (#{File.basename(irep.file.to_s)} " \
                "#{irep.label} #{tag})"
      out << "    bc2cpp_hash_snapshot_verify(M, #{recv}, #{HashInplaceIter::MODES.fetch(mode)}, #{tag}_v, #{tag}_n, " \
             "\"#{message}\");\n"
    end
    out
  end

  # The region's absorbed source ({addr:, mode:, name:}) when its receiver register is the result of `values` or
  # `keys` on the instruction before its block, on a receiver proven Hash; nil otherwise. The block (or symbol) load
  # and the send must not be jump targets, so the register holds that result on every path into the send.
  def hash_fused_source(irep, region, owner_name, mand, ivar_classes, arg_classes)
    return nil unless HashInplaceIter.on? && !region[:ssendb] && !region[:init_reg]
    return nil unless HashInplaceIter::FUSED_METHODS.include?(region[:method_name])

    prog = BytecodeIR.for(irep)
    sendb_idx = irep.index_of_addr(region[:sendb_addr])
    return nil unless sendb_idx && sendb_idx >= 2

    send = prog.source_at(sendb_idx - 2)
    mode = HashInplaceIter::SOURCE_NAMES[send.sym]
    return nil unless mode && send.reg == region[:dest_reg]
    return nil unless send.op == :SEND0 || (send.op == :SEND && send.plain_fixed_argc? && send.argc.zero?)

    targets = prog.branch_target_addrs
    return nil if [prog.source_at(sendb_idx - 1).addr, region[:sendb_addr]].any? { |a| targets.include?(a) }
    return nil unless hash_source_defs_core?(send.sym)
    return nil unless hash_source_receiver?(irep, sendb_idx - 2, send.reg, owner_name, mand, ivar_classes, arg_classes)

    { addr: send.addr, mode: mode, name: send.sym }
  end

  # `values`/`keys` on an exact Hash is the core C method: no Ruby definition, copy or installer on its chain (an
  # unknown chain is nil).
  def hash_source_defs_core?(name)
    (@hash_source_defs_core ||= {}).fetch(name) do
      list = escape_analyzer&.world&.defs_for(name, ['Hash'], true)
      @hash_source_defs_core[name] = !list.nil? &&
                                     list.all? { |d| d.core && d.irep.nil? && d.copy_irep.nil? && !d.installer }
    end
  end

  # region_receiver? without its run-time (guarded) answer: the flow mask or the trace proves the register a Hash.
  def hash_source_receiver?(irep, idx, reg, owner_name, mand, ivar_classes, arg_classes)
    mask = exact_flow_mask(irep, idx, reg)
    if mask.is_a?(Integer) && mask.positive? && (mask & ~RETURN_CORE_MASK).zero?
      return RETURN_CORE_CLASS[mask] == 'Hash'
    end

    trace_new_target(irep, idx, reg, ivar_classes, mand, arg_classes, owner: owner_name,
                                                                      class_layout: @class_layout, registry: @registry,
                                                                      container_constants: @container_constants) == 'Hash'
  end

  # The element source an Array-loop emitter iterates: the receiver Array, or the snapshot of an absorbed source.
  # +guard+ is the emitter's own receiver test for the Array case. Returns [open lines, size expr, entry lambda].
  def loop_element_source(region, recv_expr, tag, irep, guard)
    src = region[:hash_source]
    unless src
      return [guard, "ary_size(#{recv_expr})", ->(i) { "bc2cpp_ary_entry(M, #{recv_expr}, #{i})" }]
    end

    lead = String.new(hash_exact_guard(recv_expr, src[:name], "Hash receiver for absorbed ##{src[:name]}"))
    lead << hash_snapshot_lines(recv_expr, src[:mode], tag, irep)
    [lead, "#{tag}_n", ->(i) { "#{tag}_v[#{i}]" }]
  end

  # The exact-Hash test the snapshot runs behind; nil runs the send's own NoMethodError.
  def hash_exact_guard(recv_expr, name, expected)
    "    if (!mrb_hash_p(#{recv_expr}) || mrb_obj_ptr(#{recv_expr})->c != M->hash_class) {\n" \
      "      #{inline_nil_arm(recv_expr, name)}#{inline_raise('TypeError', "expected exact #{expected}")}\n" \
      "    }\n"
  end
end
