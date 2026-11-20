#include <mruby.h>
#include <stddef.h>
#include <initializer_list>
#include <string>
#include <string.h>
#include <math.h>
#include <mruby/numeric.h>
#include <mruby/string.h>
#include <mruby/variable.h>
#include <mruby/data.h>
#include <mruby/hash.h>
#include <mruby/array.h>
#include "mrb_array_access.hxx"
#include <mruby/class.h>
static inline struct RClass* bc2cpp_obj_class(mrb_state* M, mrb_value v) {
  if (!mrb_immediate_p(v)) {
    struct RClass* c = mrb_obj_ptr(v)->c;
    if (c->tt == MRB_TT_CLASS) return c;
  }
  return mrb_obj_class(M, v);
}
static inline bool bc2cpp_class_is(mrb_state* M, mrb_value v, struct RClass* cls) {
  if (!mrb_immediate_p(v) && mrb_obj_ptr(v)->c == cls) return true;
  return cls == bc2cpp_obj_class(M, v);
}
#ifndef MRB_NO_FLOAT
static inline struct RClass* bc2cpp_float_class(mrb_state* M) { return M->float_class; }
#else
static inline struct RClass* bc2cpp_float_class(mrb_state* M) { (void)M; return NULL; }
#endif
#ifndef BC2CPP_FIND_METHOD
#define BC2CPP_FIND_METHOD 1
static inline mrb_method_t bc2cpp_find_method(mrb_state* M, struct RClass** c, mrb_sym mid) { return mrb_method_search_vm(M, c, mid); }
#endif
#ifndef BC2CPP_FIND_PROVEN
#define BC2CPP_FIND_PROVEN 1
// CORE_ROWS: a call whose receiver the compiler proved also finds a row (MRB_MT_CTOR_ROW), where a full table would.
#ifdef MRB_MT_ROWS
static inline mrb_method_t bc2cpp_find_proven(mrb_state* M, struct RClass** c, mrb_sym mid) { return mrb_method_search_rows(M, c, mid); }
#else
static inline mrb_method_t bc2cpp_find_proven(mrb_state* M, struct RClass** c, mrb_sym mid) { return bc2cpp_find_method(M, c, mid); }
#endif
#endif
#include <mruby/range.h>
#include <mruby/error.h>
#ifdef HAVE_MRUBY_IO_GEM
extern "C" mrb_bool mrb_io_puts_direct(mrb_state*, mrb_value, mrb_int, const mrb_value*, mrb_value*);
#endif
#include <mruby/proc.h>
// The runtime's one arena root: every other root (the keeps below, a numeric slow path's result) goes through it.
static inline void bc2cpp_root(mrb_state* M, mrb_value v) {
  if (mrb_immediate_p(v)) return;
  // Persistent ROM objects need no arena entry (mrb_gc_protect's own
  // fast path). Keep it inline for compiled constant-table reads.
  #ifdef MRB_GC_RED
  if (mrb_basic_ptr(v)->gc_color == MRB_GC_RED) return;
  #endif
  // A consecutive keep needs no second slot. Read the current arena, so a
  // restore (including one in a nested call) cannot leave a stale hit.
  int ai = M->gc.arena_idx;
  if (ai > 0 && M->gc.arena[ai - 1] == mrb_basic_ptr(v)) return;
  // The common case of mrb_gc_protect only appends to the arena. Leave
  // growth and fixed-arena overflow handling to mruby's API.
  #ifdef MRB_GC_RED
  #ifdef MRB_GC_FIXED_ARENA
  if (ai < MRB_GC_ARENA_SIZE) {
  #else
  if (ai < M->gc.arena_capa) {
  #endif
    M->gc.arena[ai] = mrb_basic_ptr(v);
    M->gc.arena_idx = ai + 1;
    return;
  }
  #endif
  mrb_gc_protect(M, v);
}
// Drop the arena entries a body made, then root its result: what the by-name call leaves.
static inline mrb_value bc2cpp_arena_keep(mrb_state* M, int ai, mrb_value v) {
  mrb_gc_arena_restore(M, ai);
  bc2cpp_root(M, v);
  return v;
}
// A by-name call's result, rooted. mruby's funcall restores the arena before it returns, so a bare result is
// unprotected until something stores it: the next allocation can collect it (tests/bc2cpp/run_pathb_borrowck.sh).
template <class F> static inline mrb_value bc2cpp_keep_call(mrb_state* M, F call) {
  int ai = mrb_gc_arena_save(M);
  return bc2cpp_arena_keep(M, ai, call());
}
#define bc2cpp_funcall_keep(M, ...) bc2cpp_keep_call(M, [&] { return mrb_funcall(M, __VA_ARGS__); })
// STACK_TUPLES promotion: a placed array's buffer becomes a heap Array at the instruction where it escapes. Rooted
// like any new object, since the escaping store or return holds it only in a C local until then.
static inline mrb_value bc2cpp_promote_array(mrb_state* M, const mrb_value* v, mrb_int n) {
  mrb_value a = mrb_ary_new_from_values(M, n, v);
  bc2cpp_root(M, a);
  return a;
}
// NUMERIC_SLOW: the Float arms of a binary operator, shared by every site of that operator (one copy per link).
// Returns mrb_undef when the pair has no Float arm, and the caller sends. Values in and out, so no register is
// address-taken (a step function keeps its registers local).
[[gnu::noinline]] inline mrb_value bc2cpp_num_add_float(mrb_state* M, mrb_value d, mrb_value s) {
#ifndef MRB_NO_FLOAT
      if (mrb_float_p(d) && mrb_integer_p(s)) return mrb_float_value(M, mrb_float(d) + mrb_integer(s));
      if (mrb_integer_p(d) && mrb_float_p(s)) return mrb_float_value(M, mrb_integer(d) + mrb_float(s));
      if (mrb_float_p(d) && mrb_float_p(s)) return mrb_float_value(M, mrb_float(d) + mrb_float(s));
#else
  (void)M; (void)d; (void)s;
#endif
  return mrb_undef_value();
}
// NUMERIC_SLOW: the Float arms of a binary operator, shared by every site of that operator (one copy per link).
// Returns mrb_undef when the pair has no Float arm, and the caller sends. Values in and out, so no register is
// address-taken (a step function keeps its registers local).
[[gnu::noinline]] inline mrb_value bc2cpp_num_sub_float(mrb_state* M, mrb_value d, mrb_value s) {
#ifndef MRB_NO_FLOAT
      if (mrb_float_p(d) && mrb_integer_p(s)) return mrb_float_value(M, mrb_float(d) - mrb_integer(s));
      if (mrb_integer_p(d) && mrb_float_p(s)) return mrb_float_value(M, mrb_integer(d) - mrb_float(s));
      if (mrb_float_p(d) && mrb_float_p(s)) return mrb_float_value(M, mrb_float(d) - mrb_float(s));
#else
  (void)M; (void)d; (void)s;
#endif
  return mrb_undef_value();
}
// NUMERIC_SLOW: the Float arms of a binary operator, shared by every site of that operator (one copy per link).
// Returns mrb_undef when the pair has no Float arm, and the caller sends. Values in and out, so no register is
// address-taken (a step function keeps its registers local).
[[gnu::noinline]] inline mrb_value bc2cpp_num_mul_float(mrb_state* M, mrb_value d, mrb_value s) {
#ifndef MRB_NO_FLOAT
      if (mrb_float_p(d) && mrb_integer_p(s)) return mrb_float_value(M, mrb_float(d) * mrb_integer(s));
      if (mrb_integer_p(d) && mrb_float_p(s)) return mrb_float_value(M, mrb_integer(d) * mrb_float(s));
      if (mrb_float_p(d) && mrb_float_p(s)) return mrb_float_value(M, mrb_float(d) * mrb_float(s));
#else
  (void)M; (void)d; (void)s;
#endif
  return mrb_undef_value();
}
// NUMERIC_SLOW: the Float arms of a binary operator, shared by every site of that operator (one copy per link).
// Returns mrb_undef when the pair has no Float arm, and the caller sends. Values in and out, so no register is
// address-taken (a step function keeps its registers local).
[[gnu::noinline]] inline mrb_value bc2cpp_num_div_float(mrb_state* M, mrb_value d, mrb_value s) {
#ifndef MRB_NO_FLOAT
      if (mrb_integer_p(d) && mrb_float_p(s)) return mrb_float_value(M, mrb_div_float((mrb_float)mrb_integer(d), mrb_float(s)));
      if (mrb_float_p(d) && mrb_integer_p(s)) return mrb_float_value(M, mrb_div_float(mrb_float(d), (mrb_float)mrb_integer(s)));
      if (mrb_float_p(d) && mrb_float_p(s)) return mrb_float_value(M, mrb_div_float(mrb_float(d), mrb_float(s)));
#else
  (void)M; (void)d; (void)s;
#endif
  return mrb_undef_value();
}
static inline mrb_value bc2cpp_keep_removed(mrb_state* M, mrb_value v) {
  bc2cpp_root(M, v);
  return v;
}
static inline mrb_value bc2cpp_mrb_ary_pop(mrb_state* M, mrb_value a) { return bc2cpp_keep_removed(M, mrb_ary_pop(M, a)); }
static inline mrb_value bc2cpp_mrb_ary_shift(mrb_state* M, mrb_value a) { return bc2cpp_keep_removed(M, mrb_ary_shift(M, a)); }
static inline mrb_value bc2cpp_mrb_hash_delete_key(mrb_state* M, mrb_value h, mrb_value k) {
  return bc2cpp_keep_removed(M, mrb_hash_delete_key(M, h, k));
}
#define mrb_ary_pop bc2cpp_mrb_ary_pop
#define mrb_ary_shift bc2cpp_mrb_ary_shift
#define mrb_hash_delete_key bc2cpp_mrb_hash_delete_key
// ELEMENT_READ_ROOTS: the caller side. An element a compiled read keeps in a local, while a call may unlink it.
static inline void bc2cpp_keep(mrb_state* M, mrb_value v) { bc2cpp_root(M, v); }
static inline void bc2cpp_keep_old(mrb_state* M, mrb_value old) { bc2cpp_root(M, old); }
// The elements ary[head, len) an Array store is about to drop, with mrb_ary_splice's own clamping.
static inline void bc2cpp_keep_old_range(mrb_state* M, mrb_value ary, mrb_int head, mrb_int len) {
  if (!mrb_array_p(ary)) return;
  mrb_int alen = RARRAY_LEN(ary);
  if (head < 0) head += alen;
  if (head < 0 || head >= alen || len <= 0) return;
  if (len > alen - head) len = alen - head;
  const mrb_value* p = RARRAY_PTR(ary) + head;
  for (mrb_int i = 0; i < len; i++) bc2cpp_keep_old(M, p[i]);
}
// Stores that look the old value up first. mrb_hash_fetch, not mrb_hash_get: a default proc must not run.
static inline void bc2cpp_iv_set(mrb_state* M, mrb_value obj, mrb_sym id, mrb_value v) {
#ifndef BC2CPP_NO_GC_KEEP_OVERWRITTEN
  bc2cpp_keep_old(M, mrb_iv_get(M, obj, id));
#endif
  mrb_iv_set(M, obj, id, v);
}
static inline void bc2cpp_gv_set(mrb_state* M, mrb_sym id, mrb_value v) {
#ifndef BC2CPP_NO_GC_KEEP_OVERWRITTEN
  bc2cpp_keep_old(M, mrb_gv_get(M, id));
#endif
  mrb_gv_set(M, id, v);
}
static inline void bc2cpp_hash_aset(mrb_state* M, mrb_value h, mrb_value k, mrb_value v) {
#ifndef BC2CPP_NO_GC_KEEP_OVERWRITTEN
  if (mrb_hash_size(M, h) > 0) bc2cpp_keep_old(M, mrb_hash_fetch(M, h, k, mrb_nil_value()));
#endif
  mrb_hash_set(M, h, k, v);
}
// mrb_ary_set without the root, for stores that only move values around inside a fresh temporary.
static inline void bc2cpp_raw_ary_set(mrb_state* M, mrb_value ary, mrb_int n, mrb_value v) { mrb_ary_set(M, ary, n, v); }
static inline void bc2cpp_mrb_ary_set(mrb_state* M, mrb_value ary, mrb_int n, mrb_value v) {
  bc2cpp_keep_old(M, mrb_ary_entry(ary, n));
  mrb_ary_set(M, ary, n, v);
}
static inline mrb_value bc2cpp_mrb_ary_splice(mrb_state* M, mrb_value ary, mrb_int head, mrb_int len, mrb_value rpl) {
  bc2cpp_keep_old_range(M, ary, head, len);
  return mrb_ary_splice(M, ary, head, len, rpl);
}
static inline mrb_value bc2cpp_mrb_ary_clear(mrb_state* M, mrb_value ary) {
  bc2cpp_keep_old_range(M, ary, 0, RARRAY_LEN(ary));
  return mrb_ary_clear(M, ary);
}
static inline void bc2cpp_mrb_ary_replace(mrb_state* M, mrb_value ary, mrb_value other) {
  bc2cpp_keep_old_range(M, ary, 0, RARRAY_LEN(ary));
  mrb_ary_replace(M, ary, other);
}
#ifndef BC2CPP_NO_GC_KEEP_OVERWRITTEN
#define mrb_ary_set bc2cpp_mrb_ary_set
#define mrb_ary_splice bc2cpp_mrb_ary_splice
#define mrb_ary_clear bc2cpp_mrb_ary_clear
#define mrb_ary_replace bc2cpp_mrb_ary_replace
#endif
#if defined(__GNUC__) && !defined(__OPTIMIZE_SIZE__)
#define BC2CPP_HOT_INLINE __attribute__((always_inline))
#else
#define BC2CPP_HOT_INLINE
#endif
#ifndef BC2CPP_TAGGED_FIXNUM
#define BC2CPP_TAGGED_FIXNUM 0
#if defined(MRB_WORD_BOXING) && defined(__GNUC__)
// MRB_FIXNUM_SHIFT is 0 for a 64-bit word with MRB_INT32, where the word range is not the fixnum range.
#if MRB_FIXNUM_SHIFT == 1 && WORDBOX_FIXNUM_FLAG == 1 && WORDBOX_FIXNUM_MASK == 1 && MRB_INT_MAX == INTPTR_MAX && MRB_INT_MIN == INTPTR_MIN
#undef BC2CPP_TAGGED_FIXNUM
#define BC2CPP_TAGGED_FIXNUM 1
#endif
#endif
#endif
#if BC2CPP_TAGGED_FIXNUM
// The fixnum range is the word range less one bit, so a word op overflows exactly when the result is not FIXABLE.
static_assert(MRB_FIXNUM_MAX == (INTPTR_MAX >> 1) && MRB_FIXNUM_MIN == (INTPTR_MIN >> 1), "TAGGED_FIXNUM range");
#define BC2CPP_FIXNUM_PAIR_P(a, b) ((((a).w & (b).w) & 1) != 0)
#define BC2CPP_FIXNUM_WORD(v) ((intptr_t)(v).w)
static inline mrb_value bc2cpp_fixnum_word_value(uintptr_t w) {
  mrb_value v;
  v.w = w;
  return v;
}
// Both tag bits are 1: & and | keep it, ^ clears it.
#define BC2CPP_FIXNUM_AND(a, b) bc2cpp_fixnum_word_value((a).w & (b).w)
#define BC2CPP_FIXNUM_OR(a, b) bc2cpp_fixnum_word_value((a).w | (b).w)
#define BC2CPP_FIXNUM_XOR(a, b) bc2cpp_fixnum_word_value(((a).w ^ (b).w) | 1)
// (2a+1) + 2b = 2(a+b)+1, and likewise for -; true (result untouched) when a+b leaves the fixnum range.
// FIXNUM_TAG_BIT: the word is already odd, but the compiler loses that through the overflow builtin; the `| 1`
// restates it, so an immediate test on the result (the write barrier of an ivar store) folds away.
static inline bool bc2cpp_fixnum_add(mrb_value a, mrb_value b, mrb_value& z) {
  intptr_t w;
  if (__builtin_add_overflow((intptr_t)a.w, (intptr_t)(b.w - 1), &w)) return true;
  z.w = (uintptr_t)w | 1;
  return false;
}
static inline bool bc2cpp_fixnum_sub(mrb_value a, mrb_value b, mrb_value& z) {
  intptr_t w;
  if (__builtin_sub_overflow((intptr_t)a.w, (intptr_t)(b.w - 1), &w)) return true;
  z.w = (uintptr_t)w | 1;
  return false;
}
// 2a * b = 2ab is even, so `| 1` is the +1 and cannot overflow (and states the tag bit, see FIXNUM_TAG_BIT).
static inline bool bc2cpp_fixnum_mul(mrb_value a, mrb_value b, mrb_value& z) {
  intptr_t w;
  if (__builtin_mul_overflow((intptr_t)(a.w - 1), (intptr_t)b.w >> 1, &w)) return true;
  z.w = (uintptr_t)w | 1;
  return false;
}
#else
#define BC2CPP_FIXNUM_PAIR_P(a, b) (mrb_fixnum_p(a) && mrb_fixnum_p(b))
#define BC2CPP_FIXNUM_WORD(v) mrb_fixnum(v)
#define BC2CPP_FIXNUM_AND(a, b) mrb_fixnum_value(mrb_fixnum(a) & mrb_fixnum(b))
#define BC2CPP_FIXNUM_OR(a, b) mrb_fixnum_value(mrb_fixnum(a) | mrb_fixnum(b))
#define BC2CPP_FIXNUM_XOR(a, b) mrb_fixnum_value(mrb_fixnum(a) ^ mrb_fixnum(b))
static inline bool bc2cpp_fixnum_add(mrb_value a, mrb_value b, mrb_value& z) {
  mrb_int r;
  if (mrb_int_add_overflow(mrb_fixnum(a), mrb_fixnum(b), &r) || !FIXABLE(r)) return true;
  z = mrb_fixnum_value(r);
  return false;
}
static inline bool bc2cpp_fixnum_sub(mrb_value a, mrb_value b, mrb_value& z) {
  mrb_int r;
  if (mrb_int_sub_overflow(mrb_fixnum(a), mrb_fixnum(b), &r) || !FIXABLE(r)) return true;
  z = mrb_fixnum_value(r);
  return false;
}
static inline bool bc2cpp_fixnum_mul(mrb_value a, mrb_value b, mrb_value& z) {
  mrb_int r;
  if (mrb_int_mul_overflow(mrb_fixnum(a), mrb_fixnum(b), &r) || !FIXABLE(r)) return true;
  z = mrb_fixnum_value(r);
  return false;
}
#endif
#define BC2CPP_RESPOND_TO_PHANTOM 1
// Keyed by the symbol's number, which hashes by value under every boxing and every mruby pin.
[[maybe_unused]] static mrb_value bc2cpp_phantom_table(mrb_state* M) {
  return mrb_iv_get(M, mrb_obj_value(M->kernel_module), mrb_intern_lit(M, "__bc2cpp_left_out__"));
}
[[maybe_unused]] static mrb_bool bc2cpp_phantom_responds(mrb_state* M, mrb_value obj, mrb_sym id) {
  mrb_value table = bc2cpp_phantom_table(M);
  if (!mrb_hash_p(table)) return FALSE;
  mrb_value owners = mrb_hash_fetch(M, table, mrb_int_value(M, (mrb_int)id), mrb_nil_value());
  if (!mrb_array_p(owners)) return FALSE;
  for (mrb_int i = 0; i < RARRAY_LEN(owners); i++) {
    if (mrb_obj_is_kind_of(M, obj, mrb_class_ptr(RARRAY_PTR(owners)[i]))) return TRUE;
  }
  return FALSE;
}
[[maybe_unused]] static inline mrb_bool bc2cpp_mrb_respond_to(mrb_state* M, mrb_value obj, mrb_sym id) {
  return mrb_respond_to(M, obj, id) || bc2cpp_phantom_responds(M, obj, id);
}
// The first gem's install keeps mruby's own Kernel#respond_to? (kernel.c obj_respond_to) and answers with it,
// then with the table; a later gem only adds to the table.
static mrb_func_t bc2cpp_original_respond_to = nullptr;
[[maybe_unused]] static mrb_value bc2cpp_kernel_respond_to(mrb_state* M, mrb_value self) {
  mrb_value answer = bc2cpp_original_respond_to(M, self);
  if (mrb_test(answer)) return answer;
  mrb_sym id;
  mrb_bool priv = FALSE;
  mrb_get_args(M, "n|b", &id, &priv);
  return mrb_bool_value(bc2cpp_phantom_responds(M, self, id));
}
[[maybe_unused]] static void bc2cpp_phantom_add(mrb_state* M, struct RClass* owner, mrb_sym id) {
  mrb_value kernel = mrb_obj_value(M->kernel_module);
  mrb_value table = bc2cpp_phantom_table(M);
  if (!mrb_hash_p(table)) {
    struct RClass* k = M->kernel_module;
    mrb_method_t m = bc2cpp_find_method(M, &k, mrb_intern_lit(M, "respond_to?"));
    if (MRB_METHOD_UNDEF_P(m) || !MRB_METHOD_CFUNC_P(m)) {
      mrb_raise(M, mrb_exc_get_id(M, mrb_intern_lit(M, "RuntimeError")), "bc2cpp: RESPOND_TO_PHANTOM: Kernel#respond_to? is not mruby's native");
    }
    bc2cpp_original_respond_to = MRB_METHOD_CFUNC(m);
    table = mrb_hash_new(M);
    mrb_iv_set(M, kernel, mrb_intern_lit(M, "__bc2cpp_left_out__"), table);
#ifdef BC2CPP_ROM_METHOD_TABLES
    static const mrb_mt_entry respond_to_rom[] = {
      MRB_MT_ENTRY(bc2cpp_kernel_respond_to, MRB_SYM_Q(respond_to), MRB_ARGS_ARG(1, 1))
    };
    bc2cpp_mt_install(M, M->kernel_module, respond_to_rom, 1, false);
#else
    mrb_define_method(M, M->kernel_module, "respond_to?", bc2cpp_kernel_respond_to, MRB_ARGS_ARG(1, 1));
#endif
  }
  mrb_value owners = mrb_hash_fetch(M, table, mrb_int_value(M, (mrb_int)id), mrb_nil_value());
  if (!mrb_array_p(owners)) {
    owners = mrb_ary_new(M);
    mrb_hash_set(M, table, mrb_int_value(M, (mrb_int)id), owners);
  }
  mrb_ary_push(M, owners, mrb_obj_value(owner));
}
#define mrb_respond_to bc2cpp_mrb_respond_to
struct bc2cpp_block_break { mrb_value value; mrb_int token; };
struct bc2cpp_method_return { mrb_value value; mrb_int token; };
struct bc2cpp_proc_exit { mrb_value value; };
extern "C" mrb_value mrb_funcall_with_method(mrb_state*, mrb_value, mrb_sym, const mrb_method_t*, struct RClass*, mrb_int, const mrb_value*, mrb_value);
static inline mrb_value bc2cpp_call_found(mrb_state* M, mrb_value recv, mrb_sym mid, const mrb_method_t* m, struct RClass* c,
                                          mrb_int argc, const mrb_value* argv, mrb_value blk) {
  return mrb_funcall_with_method(M, recv, mid, m, c, argc, argv, blk);
}
static inline void bc2cpp_frame_free_install(mrb_state*) {}
static inline bool bc2cpp_frame_free_wrappers(const mrb_func_t*, size_t) { return false; }
    struct Bc2cppVmMark { struct mrb_jmpbuf* jmp; ptrdiff_t ci_index; };
    static inline Bc2cppVmMark bc2cpp_vm_mark(mrb_state* M) {
      return { M->jmp, M->c->ci - M->c->cibase };
    }
    // A frame-local block (Bc2cppBlock) dies with its C++ frame, but the callinfo naming it stays until a catch site pops it, and
    // popping a frame allocates (env unshare). GC stays off from the catch's start until the stale frames are gone, so
    // mark_context never reads a dead ci->proc.
    struct Bc2cppGcPause {
      mrb_state* M;
      mrb_bool was;
      explicit Bc2cppGcPause(mrb_state* m) : M(m), was(m->gc.disabled) { m->gc.disabled = TRUE; }
      ~Bc2cppGcPause() { M->gc.disabled = was; }
      Bc2cppGcPause(const Bc2cppGcPause&) = delete;
      Bc2cppGcPause& operator=(const Bc2cppGcPause&) = delete;
    };
    // The VM's cipop: unshare the frame's env, orphan its block, drop the frame.
    static void bc2cpp_ci_pop(mrb_state* M) {
      struct mrb_context* c = M->c;
      mrb_callinfo* ci = c->ci;
      mrb_vm_ci_env_clear(M, ci);
      struct RProc* blk = ci->blk;
      if (blk && !MRB_PROC_STRICT_P(blk) && MRB_PROC_ENV(blk) == mrb_vm_ci_env(&ci[-1])) {
        blk->flags |= MRB_PROC_ORPHAN;
      }
      c->ci--;
    }
    static void bc2cpp_vm_restore(mrb_state* M, const Bc2cppVmMark& mark) {
      M->jmp = mark.jmp;
      struct mrb_context* c = M->c;
      {
        Bc2cppGcPause pause(M);
        while (c->ci - c->cibase > mark.ci_index) bc2cpp_ci_pop(M);
      }
      if (M->errinfo && (c->ci - c->cibase) < M->errinfo_ci_depth) M->errinfo = NULL;
    }
    // ADR 0266: a break or return may only unwind to a frame still on the C++
    // stack; the frames that can be one are chained, each with a token that a
    // block keeps in its env. A block outliving its frame (a stored or returned
    // proc) finds no live token and raises LocalJumpError, as the VM does.
    // Tokens are 30-bit serials, so a stale one matches a live frame only after
    // 2^30 frames.
    struct Bc2cppFrame { mrb_int token; Bc2cppFrame* parent; };
    static Bc2cppFrame* bc2cpp_break_frames = nullptr;
    static Bc2cppFrame* bc2cpp_return_frames = nullptr;
    static mrb_int bc2cpp_frame_serial = 0;
    struct Bc2cppFrameGuard {
      Bc2cppFrame frame;
      Bc2cppFrame** head;
      explicit Bc2cppFrameGuard(Bc2cppFrame** h) : head(h) {
        bc2cpp_frame_serial = bc2cpp_frame_serial % 0x3fffffff + 1;
        frame.token = bc2cpp_frame_serial;
        frame.parent = *h;
        *h = &frame;
      }
      ~Bc2cppFrameGuard() { *head = frame.parent; }
      Bc2cppFrameGuard(const Bc2cppFrameGuard&) = delete;
      Bc2cppFrameGuard& operator=(const Bc2cppFrameGuard&) = delete;
    };
    static bool bc2cpp_frame_live(const Bc2cppFrame* head, mrb_value token) {
      if (!mrb_integer_p(token)) return false;
      for (const Bc2cppFrame* f = head; f; f = f->parent) if (f->token == mrb_integer(token)) return true;
      return false;
    }
    // The method frame a block built right now returns to; 0 (never live) if none.
    static inline mrb_value bc2cpp_return_token(mrb_state* M) {
      return mrb_int_value(M, bc2cpp_return_frames ? bc2cpp_return_frames->token : 0);
    }
    [[noreturn]] static void bc2cpp_break(mrb_state* M, mrb_value value, mrb_value token) {
      if (!bc2cpp_frame_live(bc2cpp_break_frames, token)) {
        mrb_raise(M, mrb_exc_get_id(M, mrb_intern_lit(M, "LocalJumpError")), "break from proc-closure");
      }
      throw bc2cpp_block_break{ value, mrb_integer(token) };
    }
    [[noreturn, maybe_unused]] static void bc2cpp_return_from_block(mrb_state* M, mrb_value value, mrb_value token) {
      if (!bc2cpp_frame_live(bc2cpp_return_frames, token)) {
        mrb_raise(M, mrb_exc_get_id(M, mrb_intern_lit(M, "LocalJumpError")), "unexpected return");
      }
      throw bc2cpp_method_return{ value, mrb_integer(token) };
    }
    // ADR 0266: OP_ENTER reports every positional arity error as `expected
    // <mandatory>` (vm.c argnum_error); mrb_get_args would say `1+` or `1..2`.
    // A call carrying keywords is left to mrb_get_args, which folds them in.
    static inline void bc2cpp_check_argc(mrb_state* M, mrb_int min, mrb_int max) {
      mrb_int argc = mrb_get_argc(M);
      if (M->c->ci->nk == 0 && (argc < min || (max >= 0 && argc > max))) mrb_argnum_error(M, argc, min, min);
    }
    // CFUNC_RESULT_ROOT: the VM's cfunc epilogue drops the arena to its saved index and, if the arena grew, reallocs it
    // (a quarter per call) before storing the result; a GC there (MRB_GC_STRESS) would free a fresh result, and the later
    // steps would free the result of an unrelated cfunc. So a grown arena is dropped to the entry index and shrunk to its
    // floor here, with the result rooted in a global meanwhile; the VM's epilogue then has nothing left to realloc.
    struct Bc2cppCfuncExit { mrb_state* M; int ai; mrb_value v; };
    [[maybe_unused]] static inline mrb_value bc2cpp_cfunc_result(Bc2cppCfuncExit e) {
    #ifndef MRB_GC_FIXED_ARENA
      if (mrb_unlikely(e.M->gc.arena_capa > MRB_GC_ARENA_SIZE)) {
        mrb_state* M = e.M;
        if (!mrb_immediate_p(e.v)) mrb_gv_set(M, mrb_intern_lit(M, "$__bc2cpp_result"), e.v);
        mrb_gc* gc = &M->gc;
        gc->arena_idx = e.ai;
        while (gc->arena_capa > MRB_GC_ARENA_SIZE && e.ai < gc->arena_capa / 4) {
          int capa = gc->arena_capa / 4;
          if (capa < MRB_GC_ARENA_SIZE) capa = MRB_GC_ARENA_SIZE;
          gc->arena = (struct RBasic**)mrb_realloc(M, gc->arena, sizeof(struct RBasic*) * capa);
          gc->arena_capa = capa;
        }
      }
    #endif
      return e.v;
    }
    // STEP_KEYWORDS: the same check for a method that takes keywords, whose keyword Hash is never a positional argument.
    // vm.c argnum_error counts a lone keyword Hash as the one argument given.
    static inline void bc2cpp_check_argc_kw(mrb_state* M, mrb_int min, mrb_int max) {
      mrb_int argc = mrb_get_argc(M);
      if (argc >= min && (max < 0 || argc <= max)) return;
      mrb_callinfo* ci = M->c->ci;
      if (argc == 0 && ci->nk != 0 && mrb_hash_p(ci->stack[1]) && !mrb_hash_empty_p(M, ci->stack[1])) argc++;
      mrb_argnum_error(M, argc, min, min);
    }
    // DECLARED_RETURN_GUARD (ADR 0455): a declared return or parameter type was trusted as a fact, and the value is
    // another type. Log, then raise BC2cppDeclarationViolation < StandardError (not a NoMethodError, so a program's
    // `rescue NoMethodError` cannot hide it). Never dispatches. -DBC2CPP_NOMETHOD_VERIFY aborts instead.
    #ifdef BC2CPP_NOMETHOD_VERIFY
    #include <stdio.h>
    #include <stdlib.h>
    #endif
    // STDERR_REPORT: the one place a failure report is printed, as `$stderr.puts prefix + msg`. An IO whose #puts is the
    // gem's own is written directly; any other $stderr (a StringIO, a user object) is sent `puts` by name, once, here.
    [[maybe_unused, gnu::cold, gnu::noinline]] static void bc2cpp_stderr_report(mrb_state* M, const char* prefix, mrb_value msg) {
      mrb_value err = mrb_gv_get(M, mrb_intern_lit(M, "$stderr"));
      mrb_value line = mrb_str_plus(M, mrb_str_new_cstr(M, prefix), msg);
      mrb_gc_protect(M, line);
    #ifdef HAVE_MRUBY_IO_GEM
      mrb_value written;
      if (mrb_io_puts_direct(M, err, 1, &line, &written)) return;
    #endif
      mrb_sym puts_id = mrb_intern_lit(M, "puts");
      if (mrb_respond_to(M, err, puts_id)) mrb_funcall_id(M, err, puts_id, 1, line);
    }
    [[maybe_unused, noreturn, gnu::cold, gnu::noinline]] static void bc2cpp_declaration_violation(mrb_state* M, mrb_value msg) {
      bc2cpp_stderr_report(M, "[RPG2k] ", msg);
      struct RClass* klass = mrb_define_class(M, "BC2cppDeclarationViolation", M->eStandardError_class);
      mrb_exc_raise(M, mrb_exc_new_str(M, klass, msg));
    }
    [[maybe_unused, noreturn, gnu::cold, gnu::noinline]] static void bc2cpp_declared_return_violation(mrb_state* M, mrb_value value, const char* method, const char* declared) {
    #ifdef BC2CPP_NOMETHOD_VERIFY
      fprintf(stderr, "bc2cpp: NOMETHOD_VERIFY: declared return violated: %s returned %s, declared -> %s\n", method, mrb_obj_classname(M, value), declared);
      fflush(stderr);
      abort();
    #endif
      bc2cpp_declaration_violation(M, mrb_format(M, "declaration violation: %s returned %T, declared -> %s", method, value, declared));
    }
    [[maybe_unused, noreturn, gnu::cold, gnu::noinline]] static void bc2cpp_declared_param_violation(mrb_state* M, mrb_value value, const char* method, int position, const char* declared) {
    #ifdef BC2CPP_NOMETHOD_VERIFY
      fprintf(stderr, "bc2cpp: NOMETHOD_VERIFY: declared parameter violated: %s argument %d is %s, declared %s\n", method, position, mrb_obj_classname(M, value), declared);
      fflush(stderr);
      abort();
    #endif
      bc2cpp_declaration_violation(M, mrb_format(M, "declaration violation: %s argument %d is %T, declared %s", method, position, value, declared));
    }
    [[maybe_unused, noreturn, gnu::cold, gnu::noinline]] static void bc2cpp_declared_ivar_violation(mrb_state* M, mrb_value value, const char* ivar, const char* declared) {
    #ifdef BC2CPP_NOMETHOD_VERIFY
      fprintf(stderr, "bc2cpp: NOMETHOD_VERIFY: declared instance variable violated: %s was assigned %s, declared %s\n", ivar, mrb_obj_classname(M, value), declared);
      fflush(stderr);
      abort();
    #endif
      bc2cpp_declaration_violation(M, mrb_format(M, "declaration violation: %s was assigned %T, declared %s", ivar, value, declared));
    }
    // Kernel#lambda flags a copy of the RProc strict after the block was built.
    static inline bool bc2cpp_proc_strict_p(mrb_state* M) {
      const struct RProc* p = M->c->ci->proc;
      return p && MRB_PROC_STRICT_P(p);
    }
    // BLOCK_DIRECT_ENTRY (ADR 0271): a compiled block without break or return has a direct entry
    // taking its captured environment and arguments. Its proc is a cfunc proc over this one
    // function (inline: one address in every translation unit of the link) with the entry as the
    // second-to-last env slot, so a yield from compiled code calls the entry without a VM frame, and
    // anything else (an interpreted iterator, a Fiber) reaches it through the VM like any cfunc.
    typedef mrb_value (*Bc2cppBlockEntry)(mrb_state*, struct REnv*, bool, mrb_int, const mrb_value*);
    static inline Bc2cppBlockEntry bc2cpp_block_entry(struct REnv* e) {
      return reinterpret_cast<Bc2cppBlockEntry>(static_cast<uintptr_t>(mrb_integer(e->stack[MRB_ENV_LEN(e) - 2])));
    }
    // BLOCK_SELF_WORLD (ADR 0477): a compiled block body reads `self` from its env (slot 0, the self of the frame
    // that built it), whatever self the VM passes the cfunc. The VM passes, for a cfunc proc:
    //   * a yield (mrb_yield/mrb_yield_argv via mrb_proc_get_self): nil, with Object as the target class;
    //   * Proc#call (OP_CALL) and OP_BLKCALL: the proc itself, with the proc's own target class;
    //   * a rebinder (mrb_yield_with_class: instance_eval/exec, class_eval/exec, Class.new, Struct.new, ...): the new
    //     self, with its singleton class or the module (nil's is NilClass, never Object);
    //   * a method dispatch of a define_method body: the receiver, with the method's owner; the body is a strict
    //     copy of the proc, which only the method table holds.
    // The last two run the body under another object, which the compiled body cannot honour: a closed-world
    // violation, raised before the body runs. A nil receiver of a method defined on Object looks like a yield, so a
    // strict proc there is told apart by the method table. Emitted only where the world does not prove that no
    // rebinder ever receives a compiled block (BlockSelfWorld).
    [[maybe_unused, noreturn, gnu::cold, gnu::noinline]] static void bc2cpp_block_self_violation(mrb_state* M, mrb_value self, const struct RProc* p, const char* block) {
      const struct REnv* e = MRB_PROC_ENV(p);
      const char* where = block ? block : mrb_sym_name(M, e->mid);
    #ifdef BC2CPP_NOMETHOD_VERIFY
      fprintf(stderr, "bc2cpp: NOMETHOD_VERIFY: compiled block of %s run under another self (%s)\n", where ? where : "?", mrb_obj_classname(M, self));
      fflush(stderr);
      abort();
    #endif
      mrb_value msg = mrb_format(M, "closed-world guard violation: compiled block of %s run under %T instead of its creator's self (BLOCK_SELF_WORLD)", where ? where : "?", self);
      bc2cpp_stderr_report(M, "[RPG2k] ", msg);
      struct RClass* klass = mrb_define_class(M, "BC2cppGuardViolation", mrb_exc_get_id(M, mrb_intern_lit(M, "NoMethodError")));
      mrb_exc_raise(M, mrb_exc_new_str(M, klass, msg));
    }
    static inline bool bc2cpp_proc_method_body_p(mrb_state* M, mrb_value self, mrb_sym mid, const struct RProc* p) {
      struct RClass* c = mrb_class(M, self);
      mrb_method_t m = bc2cpp_find_method(M, &c, mid);
      return !MRB_METHOD_UNDEF_P(m) && MRB_METHOD_PROC_P(m) && MRB_METHOD_PROC(m) == p;
    }
    static inline void bc2cpp_block_self_check(mrb_state* M, mrb_value self, const char* block) {
      const mrb_callinfo* ci = M->c->ci;
      const struct RProc* p = ci->proc;
      if (mrb_obj_eq(M, self, MRB_PROC_ENV(p)->stack[0])) return;
      struct RClass* tc = mrb_vm_ci_target_class(ci);
      if (mrb_nil_p(self) && tc == M->object_class &&
          (!MRB_PROC_STRICT_P(p) || !bc2cpp_proc_method_body_p(M, self, ci->mid, p))) return;
      if (mrb_proc_p(self) && mrb_proc_ptr(self) == p && tc == MRB_PROC_TARGET_CLASS(p)) return;
      bc2cpp_block_self_violation(M, self, p, block);
    }
    // The last env slot of a direct-entry block: bit 0 YIELD_FREE (ADR 0283), bit 1 the BLOCK_SELF_WORLD check.
    static const mrb_int BC2CPP_BLOCK_YIELD_FREE = 1;
    static const mrb_int BC2CPP_BLOCK_SELF_CHECK = 2;
    inline mrb_value bc2cpp_block_thunk(mrb_state* M, mrb_value self) {
      const struct RProc* p = M->c->ci->proc;
      const struct REnv* e = MRB_PROC_ENV(p);
      if (mrb_integer(e->stack[MRB_ENV_LEN(e) - 1]) & BC2CPP_BLOCK_SELF_CHECK) bc2cpp_block_self_check(M, self, nullptr);
      mrb_value* argv;
      mrb_int argc;
      mrb_get_args(M, "*", &argv, &argc);
      return bc2cpp_block_entry(MRB_PROC_ENV(p))(M, MRB_PROC_ENV(p), MRB_PROC_STRICT_P(p), argc, argv);
    }
    // The one place a compiled block site makes a heap RProc (an escaping block; Bc2cppBlock::proc is the lazy form).
    static inline struct RProc* bc2cpp_heap_proc(mrb_state* M, mrb_func_t fn, mrb_int len, const mrb_value* env) {
      return mrb_proc_new_cfunc_with_env(M, fn, len, env);
    }
    // Bc2cppBlock (docs/bc2cpp-stack-blocks.md, "The C++ block"): a direct-entry block as a C++ value, a red RProc and
    // REnv laid out as mrb_proc_new_cfunc_with_env builds them, over the env array of the site (entry, self and captured
    // slots), in the caller's frame: no allocation. A callee that only calls its block takes value(). The RProc
    // wrapper is made on demand, where the block is handed to code that may keep it: proc(). Red, so the GC never
    // marks, gray-lists or sweeps it. Under ASan (or BC2CPP_STACK_BLOCK_MALLOC) the storage is malloc'd and freed at the
    // end of the scope, so a reference that outlives it is a heap-use-after-free that ASan reports with the free site.
#if defined(BC2CPP_STACK_BLOCK_MALLOC) || defined(__SANITIZE_ADDRESS__)
#define BC2CPP_BLOCK_MALLOC 1
#elif defined(__has_feature)
#if __has_feature(address_sanitizer)
#define BC2CPP_BLOCK_MALLOC 1
#endif
#endif
    static mrb_value bc2cpp_env_block(mrb_state* M, mrb_value blk);
    struct Bc2cppBlock {
      mrb_state* M_;
      mrb_func_t fn_;
      mrb_int len_;
      const mrb_value* env_vals_;
#ifdef BC2CPP_BLOCK_MALLOC
      struct RProc* proc_;
      struct REnv* env_;
      mrb_value* vals_;
      Bc2cppBlock(mrb_state* M, mrb_func_t fn, mrb_int len, mrb_value* stack) : M_(M), fn_(fn), len_(len), env_vals_(stack) {
        proc_ = static_cast<struct RProc*>(calloc(1, sizeof(struct RProc)));
        env_ = static_cast<struct REnv*>(calloc(1, sizeof(struct REnv)));
        vals_ = static_cast<mrb_value*>(malloc(sizeof(mrb_value) * (len > 0 ? len : 1)));
        if (len > 0) memcpy(static_cast<void*>(vals_), static_cast<const void*>(stack), sizeof(mrb_value) * len);
        init(M, *proc_, *env_, vals_, len, fn);
      }
      ~Bc2cppBlock() { free(proc_); free(env_); free(vals_); }
      mrb_value value() { return mrb_obj_value(proc_); }
#else
      struct RProc proc_;
      struct REnv env_;
      Bc2cppBlock(mrb_state* M, mrb_func_t fn, mrb_int len, mrb_value* stack) : M_(M), fn_(fn), len_(len), env_vals_(stack) {
        memset(static_cast<void*>(&proc_), 0, sizeof(proc_));
        memset(static_cast<void*>(&env_), 0, sizeof(env_));
        init(M, proc_, env_, stack, len, fn);
      }
      mrb_value value() { return mrb_obj_value(&proc_); }
#endif
      // A direct-entry block runs through bc2cpp_block_thunk; a block that breaks or returns is a plain cfunc over the same env.
      Bc2cppBlock(mrb_state* M, mrb_int len, mrb_value* stack) : Bc2cppBlock(M, bc2cpp_block_thunk, len, stack) {}
      static void init(mrb_state* M, struct RProc& proc, struct REnv& env, mrb_value* stack, mrb_int len, mrb_func_t fn) {
        env.tt = MRB_TT_ENV;
        env.gc_color = MRB_GC_RED;
        env.c = mrb_vm_ci_target_class(M->c->ci);
        env.mid = M->c->ci->mid;
        env.stack = stack;
        MRB_ENV_SET_LEN(&env, len);
        MRB_ENV_CLOSE(&env);
        proc.tt = MRB_TT_PROC;
        proc.gc_color = MRB_GC_RED;
        proc.c = M->proc_class;
        proc.flags = MRB_PROC_CFUNC_FL | MRB_PROC_ENVSET;
        proc.body.func = fn;
        proc.e.env = &env;
      }
      // The wrapper for code that may keep the block or run it by name: a heap RProc over a copy of the env values.
      mrb_value proc() {
        struct RProc* p = bc2cpp_heap_proc(M_, fn_, len_, env_vals_);
        mrb_value v = mrb_obj_value(p);
        struct REnv* e = MRB_PROC_ENV(p);
        for (mrb_int i = 0; i < len_; i++) e->stack[i] = bc2cpp_env_block(M_, e->stack[i]);
        return v;
      }
      Bc2cppBlock(const Bc2cppBlock&) = delete;
      Bc2cppBlock& operator=(const Bc2cppBlock&) = delete;
    };
    // A frame-local block (a Bc2cppBlock, red) must not go into a heap env: the frame ends with the call, but the
    // env can outlive it (the arena keeps the heap RProc that holds it), and mrb_gc_mark would read the dead frame. A
    // frame-local block is copied to a heap RProc with the same entry and env values; a heap block is returned as is.
    static mrb_value bc2cpp_env_block(mrb_state* M, mrb_value blk) {
      if (mrb_type(blk) != MRB_TT_PROC) return blk;
      const struct RProc* p = mrb_proc_ptr(blk);
      if (p->gc_color != MRB_GC_RED || !MRB_PROC_CFUNC_P(p) || !MRB_PROC_ENV_P(p)) return blk;
      const struct REnv* e = MRB_PROC_ENV(p);
      struct RProc* copy = bc2cpp_heap_proc(M, p->body.func, MRB_ENV_LEN(e), e->stack);
      if (MRB_PROC_STRICT_P(p)) copy->flags |= MRB_PROC_STRICT;
      mrb_value copy_v = mrb_obj_value(copy);
      struct REnv* ce = MRB_PROC_ENV(copy);
      for (mrb_int i = 0; i < MRB_ENV_LEN(ce); i++) ce->stack[i] = bc2cpp_env_block(M, ce->stack[i]);
      return copy_v;
    }
    // YIELD_REACH (ADR 0283): the last env slot of a direct-entry block says its body, and everything
    // it can call, provably never suspends a Fiber. A compiled core iterator running such a block
    // may then stay compiled under a Fiber (its frame cannot be crossed by a yield).
    static inline bool bc2cpp_block_yield_free(mrb_value blk) {
      if (mrb_type(blk) != MRB_TT_PROC) return false;
      const struct RProc* p = mrb_proc_ptr(blk);
      if (!MRB_PROC_CFUNC_P(p) || MRB_PROC_CFUNC(p) != bc2cpp_block_thunk) return false;
      const struct REnv* e = MRB_PROC_ENV(p);
      return (mrb_integer(e->stack[MRB_ENV_LEN(e) - 1]) & BC2CPP_BLOCK_YIELD_FREE) != 0;
    }
    // PROC_SPEC: a compiled block is a C function proc, so Proc#arity would answer -1 and Proc#parameters []. Each compiled
    // block registers its ENTER word and local names under its entry (bc2cpp_proc_spec_register); the two methods answer for a
    // registered block from a stand-in irep proc that holds them, and for any other proc as mruby does.
    #include <unordered_map>
    #include <mruby/irep.h>
    #include <mruby/opcode.h>
    struct Bc2cppProcSpec {
      const mrb_code* iseq;
      uint16_t ilen;
      uint16_t nlocals;
      const char* const* names;  // nlocals - 1 local names, then a null
    };
    extern "C" mrb_int mrb_proc_arity(const struct RProc* p);
    inline std::unordered_map<const void*, Bc2cppProcSpec>& bc2cpp_proc_specs() {
      static std::unordered_map<const void*, Bc2cppProcSpec> specs;
      return specs;
    }
    [[maybe_unused]] static int bc2cpp_proc_spec_register(const void* key, const mrb_code* iseq, uint16_t ilen,
                                                          uint16_t nlocals, const char* const* names) {
      bc2cpp_proc_specs()[key] = Bc2cppProcSpec{iseq, ilen, nlocals, names};
      return 0;
    }
    static const Bc2cppProcSpec* bc2cpp_proc_spec_of(const struct RProc* p) {
      if (!MRB_PROC_CFUNC_P(p) || bc2cpp_proc_specs().empty()) return nullptr;
      const void* key = (const void*)MRB_PROC_CFUNC(p);
      if (MRB_PROC_CFUNC(p) == bc2cpp_block_thunk) {
        const struct REnv* e = MRB_PROC_ENV(p);
        if (!e || MRB_ENV_LEN(e) < 3) return nullptr;
        key = (const void*)bc2cpp_block_entry(const_cast<struct REnv*>(e));
      }
      auto it = bc2cpp_proc_specs().find(key);
      return it == bc2cpp_proc_specs().end() ? nullptr : &it->second;
    }
    static mrb_value bc2cpp_proc_spec_stand_in(mrb_state* M, const struct RProc* p, const Bc2cppProcSpec& spec) {
      mrb_irep* irep = mrb_add_irep(M);
      irep->iseq = spec.iseq;
      irep->ilen = spec.ilen;
      irep->nlocals = spec.nlocals;
      irep->nregs = spec.nlocals + 1;
      irep->flags |= MRB_ISEQ_NO_FREE;
      mrb_int named = 0;
      while (spec.names[named]) ++named;
      if (named > 0) {
        mrb_sym* lv = (mrb_sym*)mrb_malloc(M, sizeof(mrb_sym) * named);
        for (mrb_int i = 0; i < named; ++i) lv[i] = mrb_intern_cstr(M, spec.names[i]);
        irep->lv = lv;
      }
      struct RProc* stand_in = mrb_proc_new(M, irep);
      mrb_irep_decref(M, irep);
      if (MRB_PROC_STRICT_P(p)) stand_in->flags |= MRB_PROC_STRICT;
      return mrb_obj_value(stand_in);
    }
    static mrb_value bc2cpp_proc_arity_m(mrb_state* M, mrb_value self) {
      const Bc2cppProcSpec* spec = bc2cpp_proc_spec_of(mrb_proc_ptr(self));
      // The stand-in is a plain irep Proc: Proc#arity of it is mrb_proc_arity, so no by-name send.
      const struct RProc* p = spec ? mrb_proc_ptr(bc2cpp_proc_spec_stand_in(M, mrb_proc_ptr(self), *spec)) : mrb_proc_ptr(self);
      return mrb_int_value(M, mrb_proc_arity(p));
    }
    static mrb_func_t bc2cpp_orig_proc_parameters;
    static mrb_value bc2cpp_proc_parameters_m(mrb_state* M, mrb_value self) {
      const Bc2cppProcSpec* spec = bc2cpp_proc_spec_of(mrb_proc_ptr(self));
      if (!spec) return bc2cpp_orig_proc_parameters(M, self);
      mrb_value* argv; mrb_int argc;
      mrb_get_args(M, "*!", &argv, &argc);
      (void)argv; (void)argc;
      // The stand-in has no spec, so Proc#parameters on it is the original cfunc; call it directly.
      return bc2cpp_orig_proc_parameters(M, bc2cpp_proc_spec_stand_in(M, mrb_proc_ptr(self), *spec));
    }
    // Called once per state from the owner registration, before any compiled block runs.
    static void bc2cpp_proc_specs_install(mrb_state* M) {
      if (bc2cpp_proc_specs().empty()) return;
      mrb_sym done = mrb_intern_lit(M, "$__bc2cpp_proc_specs");
      if (mrb_test(mrb_gv_get(M, done))) return;
      mrb_gv_set(M, done, mrb_true_value());
    #ifdef BC2CPP_ROM_METHOD_TABLES
      static const mrb_mt_entry arity_rom[] = {
        MRB_MT_ENTRY(bc2cpp_proc_arity_m, MRB_SYM(arity), MRB_ARGS_NONE())
      };
      static const mrb_mt_entry parameters_rom[] = {
        MRB_MT_ENTRY(bc2cpp_proc_parameters_m, MRB_SYM(parameters), MRB_ARGS_OPT(1))
      };
      bc2cpp_mt_install(M, M->proc_class, arity_rom, 1, false);
    #else
      mrb_define_method(M, M->proc_class, "arity", bc2cpp_proc_arity_m, MRB_ARGS_NONE());
    #endif
      struct RClass* found = M->proc_class;
      mrb_method_t method = bc2cpp_find_method(M, &found, mrb_intern_lit(M, "parameters"));
      if (!MRB_METHOD_UNDEF_P(method) && MRB_METHOD_CFUNC_P(method)) {
        bc2cpp_orig_proc_parameters = MRB_METHOD_CFUNC(method);
    #ifdef BC2CPP_ROM_METHOD_TABLES
        bc2cpp_mt_install(M, M->proc_class, parameters_rom, 1, false);
    #else
        mrb_define_method(M, M->proc_class, "parameters", bc2cpp_proc_parameters_m, MRB_ARGS_OPT(1));
    #endif
      }
    }
    // STEP_CLOSURES: a function whose captured registers live in a cells Array re-grays the Array whenever it exits, so a
    // value written through a raw pointer after the Array was marked is scanned again (no write barrier sits at those stores).
    struct Bc2cppCellsGuard {
      mrb_state* M;
      mrb_value ary;
      ~Bc2cppCellsGuard() { mrb_write_barrier(M, mrb_basic_ptr(ary)); }
    };
    // SETUPVAR writes into the enclosing compiled frame, which the GC cannot see; the arena that
    // held the value is restored when the block returns (ADR 0272). Roots stay per slot address.
    static inline void bc2cpp_upvar_root(mrb_state* M, mrb_value* slot, mrb_value v) {
      if (mrb_immediate_p(v)) return;
      mrb_sym id = mrb_intern_lit(M, "$__bc2cpp_upvar_roots");
      mrb_value roots = mrb_gv_get(M, id);
      if (!mrb_hash_p(roots)) {
        roots = mrb_hash_new(M);
        mrb_gv_set(M, id, roots);
      }
      mrb_hash_set(M, roots, mrb_int_value(M, (mrb_int)((uintptr_t)slot >> 2)), v);
    }
    // The one VM entry for a proc that is not a compiled block (a native cfunc proc, a Symbol#to_proc, an irep proc).
    static inline mrb_value bc2cpp_yield_foreign(mrb_state* M, mrb_value blk, mrb_int argc, const mrb_value* argv) {
      return mrb_yield_argv(M, blk, argc, argv);
    }
    // PROC_CALL_DIRECT: one table for the whole link (C linkage, so the per-gem namespaces do not split it). Slot 0 is the
    // cfunc behind the builtin Proc#call (proc_call, static in proc.c); the rest are each gem's bc2cpp_block_thunk, since a
    // block built by one gem is called from another's code. Filled at registration, before user code can redefine `call`.
    extern "C" inline mrb_func_t* bc2cpp_proc_call_slots() {
      static mrb_func_t slots[16];
      return slots;
    }
    static void bc2cpp_proc_call_capture(mrb_state* M) {
      mrb_func_t* slots = bc2cpp_proc_call_slots();
      if (!slots[0]) {
        struct RClass* found = M->proc_class;
        mrb_method_t m = bc2cpp_find_method(M, &found, mrb_intern_lit(M, "call"));
        if (!MRB_METHOD_UNDEF_P(m) && MRB_METHOD_FUNC_P(m) && found == M->proc_class) slots[0] = MRB_METHOD_FUNC(m);
      }
      int i = 1;
      while (i < 15 && slots[i] && slots[i] != bc2cpp_block_thunk) ++i;
      if (!slots[i] && i < 15) slots[i] = bc2cpp_block_thunk;
    }
    // A direct-entry block of any compiled gem (the entry sits in its env, whichever gem built it).
    static inline bool bc2cpp_compiled_block_p(const struct RProc* p) {
      if (!MRB_PROC_CFUNC_P(p)) return false;
      const mrb_func_t* slots = bc2cpp_proc_call_slots();
      for (int i = 1; i < 16 && slots[i]; ++i) {
        if (slots[i] == MRB_PROC_CFUNC(p)) return true;
      }
      return false;
    }
    // bc2cpp_yield_foreign, minus the frame when `blk` is a compiled block with a direct entry (a lambda's entry checks
    // its arity, as the thunk's does). The arena is restored and the result protected as mrb_yield_with_class does.
    static inline mrb_value bc2cpp_yield_argv(mrb_state* M, mrb_value blk, mrb_int argc, const mrb_value* argv) {
      if (mrb_type(blk) == MRB_TT_PROC) {
        struct RProc* p = mrb_proc_ptr(blk);
        if (bc2cpp_compiled_block_p(p)) {
          struct REnv* e = MRB_PROC_ENV(p);
          int ai = mrb_gc_arena_save(M);
          return bc2cpp_arena_keep(M, ai, bc2cpp_block_entry(e)(M, e, MRB_PROC_STRICT_P(p), argc, argv));
        }
      }
      // mrb_yield_argv leaves its result in no root (no arena slot, past the live stack): restore the arena and root it.
      int ai = mrb_gc_arena_save(M);
      return bc2cpp_arena_keep(M, ai, bc2cpp_yield_foreign(M, blk, argc, argv));
    }
    // True when `recv.mid` is the builtin Proc#call (or its alias `[]`) on a compiled block with a direct entry, so the
    // call is that entry. An override (Ruby-level, singleton, prepended), a private builtin or any other proc kind
    // (Method#to_proc, Symbol#to_proc, curry, a block or lambda that breaks or returns) takes the generic route.
    static inline bool bc2cpp_cfunc_proc_call_p(mrb_state* M, mrb_value recv, mrb_sym mid) {
      const struct RProc* p = mrb_proc_ptr(recv);
      mrb_func_t builtin = bc2cpp_proc_call_slots()[0];
      if (!builtin || !bc2cpp_compiled_block_p(p)) return false;
      struct RClass* c = mrb_class(M, recv);
      mrb_method_t m = bc2cpp_find_method(M, &c, mid);
      return !MRB_METHOD_UNDEF_P(m) && MRB_METHOD_FUNC_P(m) && MRB_METHOD_FUNC(m) == builtin &&
             !(m.flags & (MRB_METHOD_PRIVATE_FL | MRB_METHOD_PROTECTED_FL));
    }
    #ifdef BC2CPP_SEND_COUNT
    // SEND_COUNT (diagnostic, off by default): by-name sends tallied per (translation unit, call kind, method name) over a
    // run and appended to $BC2CPP_SEND_COUNT_FILE (stderr when unset) at exit, to rank what still dispatches by name.
    // One table for the link (C linkage), like the proc-call slots. Kinds: `send` (a dynamic call site) and `argv` (every
    // other by-name helper caller: self sends, include hooks, splat sends, ...).
    #include <stdio.h>
    #include <stdlib.h>
    #include <unordered_map>
    extern "C" inline void bc2cpp_send_counts_dump();
    // The dump is registered here, once for the link and after the table is built, so it runs before the table is destroyed.
    extern "C" inline std::unordered_map<std::string, unsigned long long>& bc2cpp_send_counts() {
      static std::unordered_map<std::string, unsigned long long> counts;
      static const bool registered = (atexit(bc2cpp_send_counts_dump), true);
      (void)registered;
      return counts;
    }
    extern "C" inline bool& bc2cpp_send_counting_inner() {
      static bool inner;
      return inner;
    }
    extern "C" inline void bc2cpp_send_counts_dump() {
      FILE* out = stderr;
      if (const char* path = getenv("BC2CPP_SEND_COUNT_FILE")) {
        if (FILE* f = fopen(path, "a")) out = f;
      }
      for (const auto& kv : bc2cpp_send_counts()) fprintf(out, "%llu\t%s\n", kv.second, kv.first.c_str());
      if (out != stderr) fclose(out);
    }
    static void bc2cpp_send_hit(mrb_state* M, const char* unit, const char* kind, mrb_sym mid) {
      mrb_int len = 0;
      const char* name = mrb_sym_name_len(M, mid, &len);
      bc2cpp_send_counts()[std::string(unit) + "\t" + kind + "\t" + std::string(name ? name : "?", name ? (size_t)len : 1)]++;
    }
    #define BC2CPP_SEND_HIT(M, kind, mid) bc2cpp_send_hit((M), __FILE__, (kind), (mid))
    #else
    #define BC2CPP_SEND_HIT(M, kind, mid) ((void)0)
    #endif
    // `explicit_recv`: CHECKED_SEND for a splat send, which OP_SEND refuses a private method (and a protected one unless
    // `caller_self` is a kind_of its class or module) that the by-name funcall would run.
    static inline mrb_value bc2cpp_funcall_argv(mrb_state* M, mrb_value recv, mrb_sym mid, mrb_int argc, const mrb_value* argv,
                                                bool explicit_recv = false, mrb_value caller_self = mrb_nil_value()) {
      #ifdef BC2CPP_SEND_COUNT
      if (!bc2cpp_send_counting_inner()) BC2CPP_SEND_HIT(M, "argv", mid);
      #endif
      if (mrb_type(recv) == MRB_TT_PROC && bc2cpp_cfunc_proc_call_p(M, recv, mid)) return bc2cpp_yield_argv(M, recv, argc, argv);
      if (explicit_recv) {
        struct RClass* c = mrb_class(M, recv);
        mrb_method_t m = bc2cpp_find_method(M, &c, mid);
        if (!MRB_METHOD_UNDEF_P(m) && (m.flags & MRB_METHOD_PRIVATE_FL)) {
          mrb_no_method_error(M, mid, mrb_ary_new_from_values(M, argc, argv), "%s method '%n' called for %T", "private", mid, recv);
        }
        if (!MRB_METHOD_UNDEF_P(m) && (m.flags & MRB_METHOD_PROTECTED_FL) && !mrb_obj_is_kind_of(M, caller_self, c)) {
          mrb_no_method_error(M, mid, mrb_ary_new_from_values(M, argc, argv), "%s method '%n' called for %T", "protected", mid, recv);
        }
      }
      return bc2cpp_keep_call(M, [&] { return mrb_funcall_argv(M, recv, mid, argc, argv); });
    }
    // SSEND_HELPER: a class body's other by-name self send (extend, ...): visibility is ignored, as mrb_funcall does.
    [[maybe_unused]] static mrb_value bc2cpp_ssend(mrb_state* M, mrb_value self, mrb_sym mid, std::initializer_list<mrb_value> args) {
      return bc2cpp_funcall_argv(M, self, mid, (mrb_int)args.size(), args.begin());
    }
    // CLASS_BODY_INCLUDE: Module#include (class.c mrb_mod_include) without the by-name send of `include`. Last module
    // first; each module is then sent its `included` hook (a Ruby method, possibly compiled) unless that is still
    // class.c's default no-op, as mrb_mod_include tests it. Returns the class.
    extern "C" mrb_value mrb_do_nothing(mrb_state*, mrb_value);
    [[maybe_unused]] static mrb_value bc2cpp_mod_include(mrb_state* M, mrb_value self, std::initializer_list<mrb_value> args) {
      struct RClass* c = mrb_class_ptr(self);
      mrb_sym included = mrb_intern_lit(M, "included");
      for (mrb_int i = (mrb_int)args.size(); i-- > 0;) {
        mrb_value m = args.begin()[i];
        mrb_check_type(M, m, MRB_TT_MODULE);
        mrb_include_module(M, c, mrb_class_ptr(m));
        if (!mrb_func_basic_p(M, m, included, mrb_do_nothing)) bc2cpp_funcall_argv(M, m, included, 1, &self);
      }
      return self;
    }
    // CLASS_BODY_ATTR: Module#attr_reader / attr_writer (class.c mod_attr_define): a public cfunc method over the ivar name
    // in its env, as mruby builds it (visibility is not applied to it there either). Returns nil.
    static mrb_value bc2cpp_attr_get(mrb_state* M, mrb_value obj) {
      return mrb_iv_get(M, obj, mrb_obj_to_sym(M, mrb_proc_cfunc_env_get(M, 0)));
    }
    static mrb_value bc2cpp_attr_set(mrb_state* M, mrb_value obj) {
      mrb_value val = mrb_get_arg1(M);
      mrb_iv_set(M, obj, mrb_obj_to_sym(M, mrb_proc_cfunc_env_get(M, 0)), val);
      return val;
    }
    [[maybe_unused]] static mrb_value bc2cpp_mod_attr(mrb_state* M, mrb_value self, bool reader, bool writer, std::initializer_list<mrb_value> args) {
      struct RClass* c = mrb_class_ptr(self);
      // The root context gets its frame stack with the first send, and the env of a cfunc proc needs `ci`: a class body
      // can run this before any send (the default `included` is no longer one).
      if (!M->c->ci) mrb_funcall_argv(M, mrb_nil_value(), mrb_intern_lit(M, "nil?"), 0, nullptr);
      int ai = mrb_gc_arena_save(M);
      for (int pass = 0; pass < 2; pass++) {
        if (!(pass == 0 ? reader : writer)) continue;
        for (const mrb_value* a = args.begin(); a != args.end(); a++) {
          mrb_sym method = mrb_obj_to_sym(M, *a);
          mrb_int len;
          const char* nm = mrb_sym_name_len(M, method, &len);
          std::string ivar = "@" + std::string(nm, (size_t)len);
          mrb_sym ivsym = mrb_intern(M, ivar.data(), (mrb_int)ivar.size());
          mrb_iv_name_sym_check(M, ivsym);
          mrb_value name = mrb_symbol_value(ivsym);
          if (pass == 1) method = mrb_intern(M, (std::string(nm, (size_t)len) + "=").c_str(), len + 1);
          struct RProc* p = bc2cpp_heap_proc(M, pass == 0 ? bc2cpp_attr_get : bc2cpp_attr_set, 1, &name);
          p->flags |= pass == 0 ? MRB_PROC_NOARG : 0;
          mrb_method_t m;
          MRB_METHOD_FROM_PROC(m, p);
          mrb_define_method_raw(M, c, method, m);
          mrb_gc_arena_restore(M, ai);
        }
      }
      return mrb_nil_value();
    }
    // PROC_CALL_HELPER: `x.call(*args)` in a core body. A plain Proc is yielded to; any other receiver has `call` looked
    // up once and the found method run with no second lookup (visibility as OP_SEND checks it; a missing method goes
    // through method_missing / the NoMethodError of mrb_funcall_with_method).
    extern "C" mrb_value mrb_funcall_with_method(mrb_state*, mrb_value, mrb_sym, const mrb_method_t*, struct RClass*, mrb_int, const mrb_value*, mrb_value);
    [[maybe_unused]] static mrb_value bc2cpp_proc_call_argv(mrb_state* M, mrb_value caller_self, mrb_value recv, mrb_int argc, const mrb_value* argv) {
      if (mrb_proc_p(recv) && mrb_class(M, recv) == M->proc_class) return bc2cpp_yield_argv(M, recv, argc, argv);
      // Interned by name: a presym id is only valid in the library the header came from (fixture builds mix them).
      mrb_sym call_id = mrb_intern_lit(M, "call");
      struct RClass* c = mrb_class(M, recv);
      mrb_method_t m = bc2cpp_find_method(M, &c, call_id);
      if (!MRB_METHOD_UNDEF_P(m)) {
        if (m.flags & MRB_METHOD_PRIVATE_FL) {
          mrb_no_method_error(M, call_id, mrb_ary_new_from_values(M, argc, argv), "%s method '%n' called for %T", "private", call_id, recv);
        }
        if ((m.flags & MRB_METHOD_PROTECTED_FL) && !mrb_obj_is_kind_of(M, caller_self, c)) {
          mrb_no_method_error(M, call_id, mrb_ary_new_from_values(M, argc, argv), "%s method '%n' called for %T", "protected", call_id, recv);
        }
      }
      return bc2cpp_keep_call(M, [&] { return bc2cpp_call_found(M, recv, call_id, &m, c, argc, argv, mrb_nil_value()); });
    }
    // KEYWORD_SPLAT_DYNAMIC: a `**v` value as a Hash. nil means no keywords; anything else converts with to_hash, as
    // a Ruby call does, and a value that does not convert raises TypeError.
    static inline mrb_value bc2cpp_kwsplat_hash(mrb_state* M, mrb_value v) {
      if (mrb_nil_p(v) || mrb_hash_p(v)) return v;
      mrb_value h = mrb_check_hash_type(M, v);
      if (mrb_nil_p(h)) mrb_raise(M, mrb_class_get(M, "TypeError"), "no implicit conversion into Hash");
      return h;
    }
static inline mrb_value bc2cpp_io_puts(mrb_state* M, mrb_value recv, mrb_sym mid, mrb_int argc, const mrb_value* argv) {
#ifdef HAVE_MRUBY_IO_GEM
  mrb_value result;
  if (mrb_io_puts_direct(M, recv, argc, argv, &result)) return result;
#endif
  return bc2cpp_funcall_argv(M, recv, mid, argc, argv);
}
#include <mruby/throw.h>
#include <exception>
#include <type_traits>
[[maybe_unused]] static mrb_value bc2cpp_protect(mrb_state* M, mrb_value (*body)(mrb_state*, void*), void* ud,
                                                 mrb_bool* error) {
  struct mrb_jmpbuf* prev_jmp = M->jmp;
  struct mrb_jmpbuf c_jmp;
  mrb_value result;
  int ai = mrb_gc_arena_save(M);
  struct mrb_context* c = M->c;
  ptrdiff_t ci_index = c->ci - c->cibase;
  if (error) *error = FALSE;
  try {
    M->jmp = &c_jmp;
    result = body(M, ud);
    M->jmp = prev_jmp;
  } catch (mrb_jmpbuf* e) {
    if (e != &c_jmp) throw;
    Bc2cppGcPause pause(M);
    M->jmp = prev_jmp;
    result = mrb_obj_value(M->exc);
    M->exc = NULL;
    bc2cpp_root(M, result);  // M->exc no longer holds it, and popping a frame can allocate
    if (error) *error = TRUE;
    if (M->c == c) {
      while (c->ci - c->cibase > ci_index) bc2cpp_ci_pop(M);
    } else {
      // The context was switched under the raise: drop the frames C code called directly (vm.c CINFO_DIRECT).
      c = M->c;
      while (c->ci > c->cibase && c->ci->cci == 2) bc2cpp_ci_pop(M);
    }
  }
  return bc2cpp_arena_keep(M, ai, result);
}
// The same boundary around a callable (a lambda or functor returning an mrb_value, or void for nil).
template <class Body>
[[maybe_unused]] static mrb_value bc2cpp_protect_call(mrb_state* M, Body& body, mrb_bool* error) {
  return bc2cpp_protect(M, [](mrb_state*, void* ud) -> mrb_value {
    if constexpr (std::is_void_v<decltype((*(Body*)ud)())>) {
      (*(Body*)ud)();
      return mrb_nil_value();
    } else {
      return (*(Body*)ud)();
    }
  }, &body, error);
}
struct bc2cpp_jmp_restore {
  mrb_state* M;
  struct mrb_jmpbuf* prev;
  ~bc2cpp_jmp_restore() { M->jmp = prev; }
};
[[maybe_unused]] static mrb_value bc2cpp_loop_rescue(mrb_state* M, const Bc2cppVmMark& mark) {
  M->jmp = mark.jmp;
  mrb_value exc = M->exc ? mrb_obj_value(M->exc) : mrb_nil_value();
  if (mrb_nil_p(exc) || mrb_break_p(exc) ||
      !mrb_obj_is_kind_of(M, exc, mrb_class_get(M, "StopIteration"))) {
    if (!M->jmp) { mrb_print_error(M); abort(); }
    MRB_THROW(M->jmp);
  }
  bc2cpp_vm_restore(M, mark);
  M->exc = NULL;
  return bc2cpp_funcall_argv(M, exc, mrb_intern_lit(M, "result"), 0, nullptr);
}
template <class F>
struct bc2cpp_ensure_guard {
  mrb_state* M;
  F fn;
  mrb_int depth = M->c->ci - M->c->cibase;
  struct mrb_context* ctx = M->c;
  ~bc2cpp_ensure_guard() noexcept(false) {
    /* A C++ unwind leaves the callinfo of every VM frame it crossed (a cfunc block's yield) on the stack, and a
       frame-local block's RProc that such a frame names is already dead: the ensure body's VM calls (mrb_ci_nregs)
       must not see it. Pop back to the guard's own frame, as the catch site would. */
    {
      Bc2cppGcPause pause(M);
      while (M->c == ctx && M->c->ci - M->c->cibase > depth) bc2cpp_ci_pop(M);
    }
    struct RObject* saved = M->exc;
    M->exc = NULL;
    /* OP_EXCEPT's `$!`. The frame depth is the guard's own: a C++ unwind
       has not popped the raiser's callinfo yet. */
    if (saved && saved->tt == MRB_TT_EXCEPTION) {
      M->errinfo = saved;
      M->errinfo_ci_depth = depth;
    }
    /* M->exc is itself a GC root (src/gc.c's own mrb_gc_mark of it in
       both mark phases). Clearing it just above therefore removed the
       ONLY root keeping the in-flight exception alive -- the object
       may long since have been dropped from the GC arena by the
       ordinary mrb_gc_arena_restore every VM send already does. The
       ensure body allocates and so can trigger a real GC, which would
       then collect the very exception this guard is about to put
       back. Re-root it in the arena for the duration, BELOW the index
       bc2cpp_protect saves and restores internally, so its own
       restore cannot drop this entry either.

       Found by the differential test, not by reading: it shows up
       only once enough allocation has happened to make a GC actually
       fire inside the ensure body, which is exactly the kind of
       silent, load-dependent corruption a wrong `ensure` translation
       produces. */
    int bc2cpp_ai = mrb_gc_arena_save(M);
    if (saved) bc2cpp_root(M, mrb_obj_value(saved));
    mrb_bool err = FALSE;
    mrb_value raised = bc2cpp_protect_call(M, fn, &err);
    if (!err) {
      /* Restore the real root FIRST, then drop our arena entry. */
      M->exc = saved;
      mrb_gc_arena_restore(M, bc2cpp_ai);
      return;
    }
    /* The ensure body itself raised. Real Ruby semantics: that
       exception SUPERSEDES whatever was already propagating. */
    M->exc = mrb_obj_ptr(raised);
    mrb_gc_arena_restore(M, bc2cpp_ai);
    if (std::uncaught_exceptions() == 0 && M->jmp != NULL) {
      /* Nothing was unwinding yet (normal or `return` exit), so
         nothing will carry this exception outward unless we start
         the unwind ourselves. Throwing here is safe for exactly
         that reason -- hence noexcept(false).

         The test is std::uncaught_exceptions(), NOT "was M->exc
         set": this file's OWN bc2cpp_block_break/
         bc2cpp_method_return unwind the C++ stack while M->exc
         stays NULL, so keying off M->exc would throw straight into
         an in-flight exception and std::terminate -- the classic
         throwing-destructor hazard, and a real one here rather than
         a hypothetical, since those two types cross exactly these
         frames. */
      MRB_THROW(M->jmp);
    }
    /* Otherwise an unwind is already in progress and simply
       continues, now carrying the superseding exception in M->exc. */
  }
};
static inline void bc2cpp_set_errinfo(mrb_state* M, mrb_value exc) {
  if (mrb_type(exc) == MRB_TT_EXCEPTION) {
    M->errinfo = mrb_obj_ptr(exc);
    M->errinfo_ci_depth = M->c->ci - M->c->cibase;
  }
}
struct Bc2cppErrinfoScope {
  mrb_state* M;
  struct RObject* prev;
  mrb_int prev_depth;
  explicit Bc2cppErrinfoScope(mrb_state* m) : M(m), prev(m->errinfo), prev_depth(m->errinfo_ci_depth) {}
  ~Bc2cppErrinfoScope() {
    if (M->errinfo != prev || M->errinfo_ci_depth != prev_depth) M->errinfo = NULL;
  }
  Bc2cppErrinfoScope(const Bc2cppErrinfoScope&) = delete;
  Bc2cppErrinfoScope& operator=(const Bc2cppErrinfoScope&) = delete;
};
extern "C" mrb_value mrb_str_aref(mrb_state*, mrb_value, mrb_value, mrb_value);
extern "C" mrb_bool mrb_num_shift(mrb_state*, mrb_int, mrb_int, mrb_int*);
extern "C" mrb_value mrb_div_int_value(mrb_state*, mrb_int, mrb_int);
#ifdef MRB_USE_BIGINT
extern "C" mrb_value mrb_bint_new_str(mrb_state*, const char*, mrb_int, mrb_int);
#endif
extern "C" mrb_noreturn void mrb_method_missing(mrb_state*, mrb_sym, mrb_value, mrb_value);
static inline bool bc2cpp_kwsplat_has(mrb_state* M, mrb_value h, const char* name) {
  return mrb_hash_key_p(M, h, mrb_symbol_value(mrb_intern_cstr(M, name)));
}
static inline mrb_value bc2cpp_kwsplat_value(mrb_state* M, mrb_value h, const char* name, bool required) {
  mrb_value key = mrb_symbol_value(mrb_intern_cstr(M, name));
  if (mrb_hash_key_p(M, h, key)) return mrb_hash_get(M, h, key);
  if (required) mrb_raisef(M, mrb_class_get(M, "ArgumentError"), "missing keyword: :%s", name);
  return mrb_nil_value();
}
static inline void bc2cpp_kwsplat_check(mrb_state* M, mrb_value h, const char* const* names, mrb_int count) {
  mrb_value keys = mrb_hash_keys(M, h);
  for (mrb_int i = 0; i < RARRAY_LEN(keys); i++) {
    mrb_value k = mrb_ary_ref(M, keys, i);
    bool known = false;
    for (mrb_int j = 0; j < count && !known; j++) {
      known = mrb_symbol_p(k) && mrb_symbol(k) == mrb_intern_cstr(M, names[j]);
    }
    if (!known) mrb_raisef(M, mrb_class_get(M, "ArgumentError"), "unknown keyword: %S", k);
  }
}
[[maybe_unused]] static mrb_value bc2cpp_super_call(mrb_state* M, mrb_value self, struct RClass* owner, mrb_sym mid,
                                                    mrb_int argc, const mrb_value* argv, mrb_value blk) {
  struct RClass* c = owner;
  MRB_CLASS_ORIGIN(c);
  // A module has no superclass: OP_SUPER continues after the module's include-class in self's chain.
  if (c->tt == MRB_TT_MODULE) {
    for (struct RClass* k = mrb_class(M, self); k; k = k->super) {
      if (k->tt == MRB_TT_ICLASS && k->c == c) { c = k; break; }
    }
  }
  c = c->super;
  mrb_method_t m = bc2cpp_find_method(M, &c, mid);
  if (MRB_METHOD_UNDEF_P(m)) mrb_method_missing(M, mid, self, mrb_ary_new_from_values(M, argc, argv));
  return bc2cpp_keep_call(M, [&] { return mrb_funcall_with_method(M, self, mid, &m, c, argc, argv, blk); });
}
extern "C" mrb_value mrb_funcall_send_with_method(mrb_state*, mrb_value, mrb_sym, const mrb_method_t*, struct RClass*, mrb_int, const mrb_value*, mrb_value, mrb_value);
[[maybe_unused]] static mrb_value bc2cpp_super_call_kw(mrb_state* M, mrb_value self, struct RClass* owner, mrb_sym mid,
                                                       mrb_int argc, const mrb_value* argv, mrb_value kdict, mrb_value blk) {
  struct RClass* c = owner;
  MRB_CLASS_ORIGIN(c);
  if (c->tt == MRB_TT_MODULE) {
    for (struct RClass* k = mrb_class(M, self); k; k = k->super) {
      if (k->tt == MRB_TT_ICLASS && k->c == c) { c = k; break; }
    }
  }
  c = c->super;
  mrb_method_t m = bc2cpp_find_method(M, &c, mid);
  if (MRB_METHOD_UNDEF_P(m)) mrb_method_missing(M, mid, self, mrb_ary_new_from_values(M, argc, argv));
  return bc2cpp_keep_call(M, [&] { return mrb_funcall_send_with_method(M, self, mid, &m, c, argc, argv, kdict, blk); });
}
extern "C" mrb_value mrb_funcall_send(mrb_state*, mrb_value, mrb_sym, mrb_int, const mrb_value*, mrb_value, mrb_value);
[[maybe_unused]] static mrb_value bc2cpp_funcall_kw(mrb_state* M, mrb_value self, mrb_sym mid, mrb_int argc,
                                                    const mrb_value* argv, mrb_value kdict, mrb_value blk) {
  if (mrb_hash_p(kdict) && !mrb_hash_empty_p(M, kdict)) return bc2cpp_keep_call(M, [&] { return mrb_funcall_send(M, self, mid, argc, argv, kdict, blk); });
  return bc2cpp_keep_call(M, [&] { return mrb_funcall_with_block(M, self, mid, argc, argv, blk); });
}
[[maybe_unused]] static mrb_value bc2cpp_send_kw(mrb_state* M, mrb_value self, mrb_sym mid, mrb_int argc,
                                                 const mrb_value* argv, mrb_value kdict, bool explicit_receiver,
                                                 mrb_value caller_self) {
  if (explicit_receiver) {
    struct RClass* c = mrb_class(M, self);
    mrb_method_t m = bc2cpp_find_method(M, &c, mid);
    if (!MRB_METHOD_UNDEF_P(m)) {
      bool priv = (m.flags & MRB_METHOD_PRIVATE_FL) != 0;
      if (priv || ((m.flags & MRB_METHOD_PROTECTED_FL) && !mrb_obj_is_kind_of(M, caller_self, c))) {
        mrb_no_method_error(M, mid, mrb_ary_new_from_values(M, argc, argv), "%s method '%n' called for %T",
                            priv ? "private" : "protected", mid, self);
      }
    }
  }
  return bc2cpp_keep_call(M, [&] { return mrb_funcall_send(M, self, mid, argc, argv, kdict, mrb_nil_value()); });
}

struct Foo_ivars {
  mrb_int ivar_v;
};
static void Foo_ivars_free(mrb_state* mrb, void* p) {
  if (!p) return;
  static_cast<Foo_ivars*>(p)->~Foo_ivars();
  mrb_free(mrb, p);
}
static const mrb_data_ivar Foo_bc2cpp_ivar_slot_table[] = {
  { "@v", offsetof(Foo_ivars, ivar_v), MRB_DATA_IVAR_INT },
};
static const uint16_t Foo_ivar_hash[] = { 65535, 0 };
static const mrb_data_type Foo_ivars_type = { "Foo_ivars", Foo_ivars_free, Foo_bc2cpp_ivar_slot_table, 1, sizeof(Foo_ivars), Foo_ivar_hash, 1 };

// The order of mrb_vm_const_get (3rd/mruby/src/variable.c): the own table of each lexical scope, innermost
// first and Object last, then the ancestors of the innermost scope (const_get with skip). A miss is answered
// without raising until the end, where mrb_const_get runs const_missing on the innermost scope as the VM does.
static inline bool bc2cpp_const_own(mrb_state* M, mrb_value scope, mrb_sym name, mrb_value* out) {
  if (!(mrb_class_p(scope) || mrb_module_p(scope) || mrb_sclass_p(scope)) || !mrb_iv_defined(M, scope, name)) {
    return false;
  }
  *out = mrb_iv_get(M, scope, name);
  return true;
}
static mrb_value bc2cpp_const_inherited(mrb_state* M, mrb_value scope, mrb_sym name) {
  if (mrb_class_p(scope) || mrb_module_p(scope) || mrb_sclass_p(scope)) {
    struct RClass* base = mrb_class_ptr(scope);
    struct RClass* c = base->super;
    for (bool retried = false;; retried = true, c = M->object_class) {
      for (; c; c = c->super) {
        if (MRB_FLAG_TEST(c, MRB_FL_CLASS_IS_PREPENDED)) continue;
        mrb_value v;
        if (bc2cpp_const_own(M, mrb_obj_value(c->tt == MRB_TT_ICLASS ? c->c : c), name, &v)) return v;
      }
      if (retried || base->tt != MRB_TT_MODULE) break;
    }
  }
  return mrb_const_get(M, scope, name);
}

// A generic replacement for Class#new's own `self.allocate` step,
// correct for ANY class C regardless of its own MRB_INSTANCE_TT --
// including one with an embedded MRB_TT_DATA ivar struct, since
// MRB_INSTANCE_TT(c) reads the class's OWN stored instance type
// (set once, at gem-init time, by MRB_SET_INSTANCE_TT), never
// guesses it from the class's shape. This is exactly what
// mrb_instance_alloc (3rd/mruby/src/class.c, Class#allocate's own
// real implementation) does internally -- confirmed by reading that
// function directly -- just reimplemented here since it is `static`
// (no external linkage, so this generated file -- a different
// translation unit -- cannot call it directly) using only the two
// PUBLIC mruby APIs for allocating with MRB_INSTANCE_TT(c) and
// mrb_obj_alloc (mruby.h), preserving mrb_instance_alloc's tag and
// allocator checks. Called directly in
// place of Class#new's own real allocate+initialize dispatch chain
// when a `.new` call site's receiver is a compiled class with a
// proven standard constructor chain (compile_send's direct
// compiled-construction path).
// -- #initialize's own already-compiled _impl function is called
// right after, for its side effects only (its own return value is
// discarded, never assigned to the result register: real Ruby
// Class#new always returns the newly allocated object, never
// whatever #initialize itself returns).
static inline mrb_value bc2cpp_direct_alloc(mrb_state* M, RClass* c) {
  enum mrb_vtype ttype = MRB_INSTANCE_TT(c);
  if (c->tt == MRB_TT_SCLASS) mrb_raise(M, mrb_exc_get_id(M, mrb_intern_lit(M, "TypeError")), "can't create instance of singleton class");
  if (c == M->nil_class || c == M->false_class) {
    mrb_assert(ttype == 0);
  } else if (ttype == 0) {
    ttype = MRB_TT_OBJECT;
  }
  if (MRB_UNDEF_ALLOCATOR_P(c)) mrb_raisef(M, mrb_exc_get_id(M, mrb_intern_lit(M, "TypeError")), "allocator undefined for %v", mrb_obj_value(c));
  if (ttype <= MRB_TT_CPTR) mrb_raisef(M, mrb_exc_get_id(M, mrb_intern_lit(M, "TypeError")), "can't create instance of %v", mrb_obj_value(c));
  return mrb_obj_value(mrb_obj_alloc(M, ttype, c));
}

// Class-identity accessors for explicitly listed target classes
// their owning gem's generated code defines (mirroring
// NATIVE_CONSTRUCT_TARGETS' own class_fn precedent) -- a real,
// durable RClass* captured once at that gem's own gem-init time, NOT
// a second mrb_const_get/mrb_class_get_under lookup (see
// compile_send's own comment on why: that would just observe
// whatever the constant currently names, exactly what a
// reassignment would already have changed, so it could never
// actually detect one happened).

mrb_value Foo_initialize_impl(mrb_state*, mrb_value);
[[maybe_unused]] static mrb_value Foo_initialize(mrb_state*, mrb_value);
mrb_value Foo_size2_impl(mrb_state*, mrb_value);
[[maybe_unused]] static mrb_value Foo_size2(mrb_state*, mrb_value);
mrb_value Menu_pick_impl(mrb_state*, mrb_value, mrb_value, mrb_value, mrb_int);
[[maybe_unused]] static mrb_value Menu_pick(mrb_state*, mrb_value);
mrb_value Menu_add_impl(mrb_state*, mrb_value, mrb_value, mrb_value, mrb_int);
[[maybe_unused]] static mrb_value Menu_add(mrb_state*, mrb_value);
mrb_value Menu_computed_impl(mrb_state*, mrb_value, mrb_value, mrb_value, mrb_int);
[[maybe_unused]] static mrb_value Menu_computed(mrb_state*, mrb_value);
mrb_value Menu_later_impl(mrb_state*, mrb_value, mrb_value, mrb_value, mrb_value, mrb_int);
[[maybe_unused]] static mrb_value Menu_later(mrb_state*, mrb_value);
mrb_value Menu_loose_impl(mrb_state*, mrb_value, mrb_value, mrb_value, mrb_int);
[[maybe_unused]] static mrb_value Menu_loose(mrb_state*, mrb_value);
mrb_value Menu_sorted_impl(mrb_state*, mrb_value, mrb_value, mrb_value, mrb_int);
[[maybe_unused]] static mrb_value Menu_sorted(mrb_state*, mrb_value);
mrb_value Menu_keys_of_impl(mrb_state*, mrb_value, mrb_value);
[[maybe_unused]] static mrb_value Menu_keys_of(mrb_state*, mrb_value);
mrb_value Menu_shout_impl(mrb_state*, mrb_value, mrb_value);
[[maybe_unused]] static mrb_value Menu_shout(mrb_state*, mrb_value);
mrb_value Menu_run_impl(mrb_state*, mrb_value);
[[maybe_unused]] static mrb_value Menu_run(mrb_state*, mrb_value);
mrb_value Menu_wrong_sorted_impl(mrb_state*, mrb_value);
[[maybe_unused]] static mrb_value Menu_wrong_sorted(mrb_state*, mrb_value);
mrb_value Menu_wrong_impl(mrb_state*, mrb_value);
[[maybe_unused]] static mrb_value Menu_wrong(mrb_state*, mrb_value);
mrb_value Menu_wrong_add_impl(mrb_state*, mrb_value);
[[maybe_unused]] static mrb_value Menu_wrong_add(mrb_state*, mrb_value);

// INSTANCE_TT_SETUP -- see bc2cpp.rb's own emit_instance_tt_setup comment.
struct Bc2cppInstanceTtRoots { struct RClass** classes; int count; };
static int bc2cpp_instance_tt_subclass(mrb_state*, struct RBasic* obj, void* data) {
  if (obj->tt != MRB_TT_CLASS) return MRB_EACH_OBJ_OK;
  struct RClass* c = (struct RClass*)obj;
  if (MRB_INSTANCE_TT(c) != MRB_TT_OBJECT) return MRB_EACH_OBJ_OK;
  const Bc2cppInstanceTtRoots* roots = (const Bc2cppInstanceTtRoots*)data;
  for (struct RClass* s = c->super; s; s = s->super) {
    for (int i = 0; i < roots->count; ++i) {
      if (s == roots->classes[i]) { MRB_SET_INSTANCE_TT(c, MRB_TT_DATA); return MRB_EACH_OBJ_OK; }
    }
  }
  return MRB_EACH_OBJ_OK;
}
static void bc2cpp_set_instance_tts(mrb_state* M) {
  static const char* const paths[][6] = {
    { "Foo", nullptr },
    { nullptr },
  };
struct RClass* found_classes[sizeof(paths) / sizeof(paths[0])];
Bc2cppInstanceTtRoots roots = { found_classes, 0 };
bool switched = false, inherited = false;
for (const auto& path : paths) {
  if (!path[0]) break;
  mrb_value scope = mrb_obj_value(M->object_class);
  bool found = true;
  for (int i = 0; path[i]; ++i) {
    mrb_sym name = mrb_intern_cstr(M, path[i]);
    if (!mrb_const_defined_at(M, scope, name)) { found = false; break; }
    scope = mrb_const_get(M, scope, name);
  }
  if (!found || mrb_type(scope) != MRB_TT_CLASS) continue;
  struct RClass* c = mrb_class_ptr(scope);
  switched = switched || MRB_INSTANCE_TT(c) != MRB_TT_DATA;
  inherited = inherited || (c->flags & MRB_FL_CLASS_IS_INHERITED);
  MRB_SET_INSTANCE_TT(c, MRB_TT_DATA);
  found_classes[roots.count++] = c;
}
// INSTANCE_TT_SUBCLASSES (codegen_emit.rb): a later call with nothing new to switch has nothing new to find.
if (switched && inherited) mrb_objspace_each_objects(M, bc2cpp_instance_tt_subclass, &roots);
}
// OWNER_CLASS_CACHE -- see bc2cpp.rb's own owner_class_ptr_expr comment.
static mrb_state* bc2cpp_owner_class_state = nullptr;
static struct RClass* bc2cpp_owner_class_slots[2] = {};
static void bc2cpp_reset_owner_classes() {
  bc2cpp_owner_class_state = nullptr;
  for (struct RClass*& c : bc2cpp_owner_class_slots) c = nullptr;
}
[[gnu::cold, gnu::noinline]] static void bc2cpp_owner_class_bind_conflict(mrb_state* M) {
  mrb_bug(M, "bc2cpp OWNER_CLASS_CACHE: compiled code ran in a second live mrb_state; the slots hold one VM's values");
}
static inline void bc2cpp_owner_class_bind(mrb_state* M) {
  if (bc2cpp_owner_class_state == M) return;
  if (bc2cpp_owner_class_state) bc2cpp_owner_class_bind_conflict(M);
  bc2cpp_owner_class_state = M;
}
[[gnu::noinline]] static struct RClass* bc2cpp_owner_class_lookup(mrb_state* M, const char* const* path, int n) {
  bc2cpp_owner_class_bind(M);
  mrb_value v = mrb_obj_value(M->object_class);
  for (int i = 0; i < n; ++i) {
    mrb_sym s = mrb_intern_cstr(M, path[i]);
    if (!mrb_const_defined_at(M, v, s)) return nullptr;
    v = mrb_const_get(M, v, s);
  }
  return mrb_class_ptr(v);
}
static inline struct RClass* bc2cpp_owner_class_0(mrb_state* M) {
  struct RClass* c = bc2cpp_owner_class_slots[0];
  if (!c) {
    static const char* const path[] = {"Foo"};
    c = bc2cpp_owner_class_slots[0] = bc2cpp_owner_class_lookup(M, path, 1);
  }
  return c;
}
static inline struct RClass* bc2cpp_owner_class_1(mrb_state* M) {
  struct RClass* c = bc2cpp_owner_class_slots[1];
  if (!c) {
    static const char* const path[] = {"Menu"};
    c = bc2cpp_owner_class_slots[1] = bc2cpp_owner_class_lookup(M, path, 1);
  }
  return c;
}
// DIRECT_CONSTRUCT_ACCESSORS -- see emit_direct_construct_accessors.
static void bc2cpp_capture_direct_construct_classes([[maybe_unused]] mrb_state* M) {
}
static void bc2cpp_reset_direct_construct_classes() {
}

// OWNER_METHOD_REGISTRATION -- see bc2cpp.rb's own emit_owner_registrations comment.
static void bc2cpp_register_core_owner_methods([[maybe_unused]] mrb_state* M) {
}
static void bc2cpp_register_program_owner_methods([[maybe_unused]] mrb_state* M) {
  struct RClass* bc2cpp_owner_reg_Foo = mrb_class_ptr(mrb_const_get(M, mrb_obj_value(M->object_class), mrb_intern_cstr(M, "Foo")));
  mrb_define_private_method(M, bc2cpp_owner_reg_Foo, "\x69\x6e\x69\x74\x69\x61\x6c\x69\x7a\x65", Foo_initialize, MRB_ARGS_NONE());
  mrb_define_method(M, bc2cpp_owner_reg_Foo, "\x73\x69\x7a\x65\x32", Foo_size2, MRB_ARGS_NONE());
  struct RClass* bc2cpp_owner_reg_Menu = mrb_class_ptr(mrb_const_get(M, mrb_obj_value(M->object_class), mrb_intern_cstr(M, "Menu")));
  mrb_define_method(M, bc2cpp_owner_reg_Menu, "\x70\x69\x63\x6b", Menu_pick, MRB_ARGS_REQ(1) | MRB_ARGS_OPT(1));
  mrb_define_method(M, bc2cpp_owner_reg_Menu, "\x61\x64\x64", Menu_add, MRB_ARGS_REQ(1) | MRB_ARGS_OPT(1));
  mrb_define_method(M, bc2cpp_owner_reg_Menu, "\x63\x6f\x6d\x70\x75\x74\x65\x64", Menu_computed, MRB_ARGS_REQ(1) | MRB_ARGS_OPT(1));
  mrb_define_method(M, bc2cpp_owner_reg_Menu, "\x6c\x61\x74\x65\x72", Menu_later, MRB_ARGS_REQ(1) | MRB_ARGS_OPT(2));
  mrb_define_method(M, bc2cpp_owner_reg_Menu, "\x6c\x6f\x6f\x73\x65", Menu_loose, MRB_ARGS_REQ(1) | MRB_ARGS_OPT(1));
  mrb_define_method(M, bc2cpp_owner_reg_Menu, "\x73\x6f\x72\x74\x65\x64", Menu_sorted, MRB_ARGS_REQ(1) | MRB_ARGS_OPT(1));
  mrb_define_method(M, bc2cpp_owner_reg_Menu, "\x6b\x65\x79\x73\x5f\x6f\x66", Menu_keys_of, MRB_ARGS_REQ(1));
  mrb_define_method(M, bc2cpp_owner_reg_Menu, "\x73\x68\x6f\x75\x74", Menu_shout, MRB_ARGS_REQ(1));
  mrb_define_method(M, bc2cpp_owner_reg_Menu, "\x72\x75\x6e", Menu_run, MRB_ARGS_NONE());
  mrb_define_method(M, bc2cpp_owner_reg_Menu, "\x77\x72\x6f\x6e\x67\x5f\x73\x6f\x72\x74\x65\x64", Menu_wrong_sorted, MRB_ARGS_NONE());
  mrb_define_method(M, bc2cpp_owner_reg_Menu, "\x77\x72\x6f\x6e\x67", Menu_wrong, MRB_ARGS_NONE());
  mrb_define_method(M, bc2cpp_owner_reg_Menu, "\x77\x72\x6f\x6e\x67\x5f\x61\x64\x64", Menu_wrong_add, MRB_ARGS_NONE());
}
static void bc2cpp_register_owner_methods(mrb_state* M) {
  bc2cpp_proc_call_capture(M);
  bc2cpp_register_core_owner_methods(M);
  bc2cpp_register_program_owner_methods(M);
  bc2cpp_proc_specs_install(M);
}

mrb_value rgss_obj_dispose_direct(mrb_state* M, mrb_value self);
mrb_value rgss_tilemap_dispose_direct(mrb_state* M, mrb_value self);
mrb_value rgss_row_audio_s_bgm_play(mrb_state* M, mrb_value self);
mrb_value rgss_row_audio_s_bgs_play(mrb_state* M, mrb_value self);
mrb_value rgss_row_audio_s_me_play(mrb_state* M, mrb_value self);
mrb_value rgss_row_audio_s_se_play(mrb_state* M, mrb_value self);
mrb_value rgss_row_audio_s_bgm_play_mem(mrb_state* M, mrb_value self);
mrb_value rgss_row_audio_s_bgs_play_mem(mrb_state* M, mrb_value self);
mrb_value rgss_row_audio_s_me_play_mem(mrb_state* M, mrb_value self);
mrb_value rgss_row_audio_s_se_play_mem(mrb_state* M, mrb_value self);
mrb_value rgss_row_audio_bgm_play(mrb_state* M, mrb_value self);
mrb_value rgss_row_audio_bgs_play(mrb_state* M, mrb_value self);
mrb_value rgss_row_audio_me_play(mrb_state* M, mrb_value self);
mrb_value rgss_row_audio_se_play(mrb_state* M, mrb_value self);
mrb_value rgss_row_audio_bgm_play_mem(mrb_state* M, mrb_value self);
mrb_value rgss_row_audio_bgs_play_mem(mrb_state* M, mrb_value self);
mrb_value rgss_row_audio_me_play_mem(mrb_state* M, mrb_value self);
mrb_value rgss_row_audio_se_play_mem(mrb_state* M, mrb_value self);
mrb_value rgss_row_sprite_opacity_set(mrb_state* M, mrb_value self);
mrb_value rgss_row_plane_opacity_set(mrb_state* M, mrb_value self);
mrb_value rgss_row_window_opacity_set(mrb_state* M, mrb_value self);
mrb_value rgss_row_bitmap_init_memory(mrb_state* M, mrb_value self);
mrb_value rgss_row_bitmap_init_file(mrb_state* M, mrb_value self);
mrb_value rgss_row_bitmap_transition_alpha(mrb_state* M, mrb_value self);
mrb_value rgss_row_bitmap_hue_change(mrb_state* M, mrb_value self);
mrb_value rgss_row_bitmap_get_pixel(mrb_state* M, mrb_value self);
mrb_value rgss_row_bitmap_blt_quads(mrb_state* M, mrb_value self);
mrb_value rgss_row_bitmap_tone_blt(mrb_state* M, mrb_value self);
mrb_value rgss_row_bitmap_mosaic_blt(mrb_state* M, mrb_value self);
mrb_value rgss_row_bitmap_wave_blt(mrb_state* M, mrb_value self);
mrb_value rgss_row_bitmap_blend_text(mrb_state* M, mrb_value self);
mrb_value rgss_row_input_s_poll(mrb_state* M, mrb_value self);
mrb_value rgss_row_input_poll(mrb_state* M, mrb_value self);
mrb_value lcf_row_s_utf8_to_cp932(mrb_state* M, mrb_value self);
mrb_value lcf_row_utf8_to_cp932(mrb_state* M, mrb_value self);
// BC2CPP_NOIPA: GCC's noipa keeps a slow-path call in place (see bc2cpp_nomethod). Clang has no such
// attribute and warns on it. maybe_unused: a translation unit may call only some of these helpers.
#ifndef BC2CPP_NOIPA
#if defined(__clang__)
#define BC2CPP_NOIPA [[maybe_unused]]
#else
#define BC2CPP_NOIPA [[gnu::noipa, maybe_unused]]
#endif
#endif
#ifndef BC2CPP_COLD_ARM
#if defined(__GNUC__) && !defined(__clang__)
#define BC2CPP_COLD_ARM_(n) bc2cpp_cold_##n: __attribute__((cold, unused));
#define BC2CPP_COLD_ARM_N(n) BC2CPP_COLD_ARM_(n)
#define BC2CPP_COLD_ARM BC2CPP_COLD_ARM_N(__COUNTER__)
#else
#define BC2CPP_COLD_ARM
#endif
#endif
// A bytecode pool string's value. Its own helper, so the static dispatch proof can tell it from a folded
// constant's value (static_dispatch_registrations.rb, POOL_STRING_VALUE).
template<size_t N> static inline mrb_value bc2cpp_pool_str(mrb_state* M, const char (&s)[N]) {
  return mrb_str_new(M, s, N - 1);
}
// SYMBOL_CACHE -- see tools/bc2cpp/symbol_cache.rb.
static mrb_state* bc2cpp_sym_state = nullptr;
static mrb_sym bc2cpp_syms[24] = {};
static const uint32_t bc2cpp_sym_entry[24] = { 0x80000000u | 0u, 0x80000000u | 1u, 0x80000000u | 2u, 0x80000000u | 3u, 0x80000000u | 4u, 0x80000000u | 5u, 0x80000000u | 6u, 0x80000000u | 7u, 0x80000000u | 8u, 0x80000000u | 9u, 0x80000000u | 10u, 0x80000000u | 11u, 0x80000000u | 12u, 0x80000000u | 13u, 0x80000000u | 14u, 0x80000000u | 15u, 0x80000000u | 16u, 0x80000000u | 17u, 0x80000000u | 18u, 0x80000000u | 19u, 0x80000000u | 20u, 0x80000000u | 21u, 0x80000000u | 22u, 0x80000000u | 23u };
static const char* const bc2cpp_sym_names[24] = {
  "TypeError",
  "RuntimeError",
  "size2",
  "c",
  "sort",
  "size",
  "upcase",
  "a",
  "initialize",
  "Foo",
  "pick",
  "add",
  "computed",
  "later",
  "loose",
  "sorted",
  "keys_of",
  "shout",
  "run",
  "wrong_sorted",
  "wrong",
  "wrong_add",
  "Menu",
  "+",
};

// OUTSIDE_OWNER_CALL: bumped with the symbol table, so no owner set outlives its VM.
static unsigned bc2cpp_owner_epoch = 1;
static void bc2cpp_reset_symbol_cache() {
  bc2cpp_sym_state = nullptr;
  for (mrb_sym& s : bc2cpp_syms) s = 0;

  ++bc2cpp_owner_epoch;
}
static inline mrb_sym bc2cpp_sym(mrb_state* M, int i) {
  if (bc2cpp_sym_state != M) {
    bc2cpp_reset_symbol_cache();
    bc2cpp_sym_state = M;
  }
  // The VM check comes first: it also bumps the epochs of the caches keyed on this table.
  uint32_t e = bc2cpp_sym_entry[i];
  if (!(e & 0x80000000u)) return (mrb_sym)e;
  mrb_sym& s = bc2cpp_syms[e & 0x7fffffffu];
  if (!s) s = mrb_intern_cstr(M, bc2cpp_sym_names[i]);
  return s;
}

// mrb_funcall_id with the symbol lookup folded in, so a dynamic call site is one
// call. Same argc limit and error as mruby's (MRB_FUNCALL_ARGC_MAX, src/vm.c).
static mrb_value bc2cpp_send(mrb_state* M, mrb_value recv, int i, mrb_int argc, ...) {
  mrb_value argv[16];
  if (argc > 16) mrb_raise(M, mrb_exc_get_id(M, mrb_intern_lit(M, "ArgumentError")), "Too long arguments. (limit=16)");
  va_list ap;
  va_start(ap, argc);
  for (mrb_int k = 0; k < argc; k++) argv[k] = va_arg(ap, mrb_value);

  va_end(ap);

  #ifdef BC2CPP_SEND_COUNT
  BC2CPP_SEND_HIT(M, "send", bc2cpp_sym(M, i));
  struct SendInner { SendInner() { bc2cpp_send_counting_inner() = true; } ~SendInner() { bc2cpp_send_counting_inner() = false; } } send_inner;
  #endif
  return bc2cpp_funcall_argv(M, recv, bc2cpp_sym(M, i), argc, argv);
}
#include <string.h>
#include <stdlib.h>
#ifdef BC2CPP_NOMETHOD_VERIFY
#include <stdio.h>
#include <stdlib.h>
#endif
#if !defined(MRB_NO_METHOD_CACHE) && !defined(BC2CPP_NO_OWNER_ICACHE)
#define BC2CPP_OWNER_ICACHE 1
#endif
// OWNER_CALL_DIRECT (owner_call_direct.rb): a listed owner's compiled entry, called without a method-table lookup
// (owner path, the entry wrapper, the flags its registration gives it: aspec and visibility), and a call's rows
// with each owner's class in `state` (null: not defined there).
struct bc2cpp_owner_direct {
  const char* owner;
  mrb_func_t func;
  uint32_t flags;
};
// OWNER_CALL_DESC: what never changes is const (rodata); `cls` and `epoch` point at the zeroed run-time state.
// The epoch alone dates `cls`: bc2cpp_sym bumps it for another VM, and gem_final for a reused one.
struct bc2cpp_owner_directs {
  const bc2cpp_owner_direct* rows;
  struct RClass** cls;
  unsigned* epoch;
  int count;
};
// The run-time state of an owner set, zero-initialised (.bss: an initialised one would be a .data image in flash).
// OWNER_SET_EPOCH: the set is valid while `epoch` is bc2cpp_owner_epoch. It keeps no mrb_state: every use follows
// a bc2cpp_sym(M, ...) of the same call, which bumps the epoch whenever the gem's VM changes (or the gem is
// finalised), so a current epoch names the calling VM. Narrow fields sit last, for padding.
struct bc2cpp_owner_set {
  // Owners already matched: up to 32, allocated on the first miss (an inline 32-slot array was most of a site's bytes).
  struct RClass** seen;
  // OWNER_CALL_ICACHE: the last call that passed every check (hit_klass null: none).
  struct RClass* hit_klass;
  struct RClass* hit_c;
  mrb_method_t hit_m;
  unsigned epoch;
#ifdef MRB_MT_ROWS
  uint32_t hit_mt_epoch;
#endif
  uint8_t seen_count;
  // A call of more arguments is not kept (see bc2cpp_owner_call_argv).
  uint8_t hit_argc;
};
// OWNER_CALL_DESC: a site's constant descriptor: its owner list, direct rows, state and the call's symbol slot and
// level, so the call passes one pointer. The narrowing of a brace initialiser keeps a slot past 16 bits from
// compiling.
struct bc2cpp_owner_desc {
  const char* const* names;
  const bc2cpp_owner_directs* direct;
  bc2cpp_owner_set* set;
  uint16_t mid;
  uint8_t level;
};
#ifdef BC2CPP_OWNER_ICACHE_STATS
// Hits and full lookups, for scripts/bc2cpp/owner_call_icache_check.rb; printed at exit.
#include <stdio.h>
static unsigned long bc2cpp_owner_icache_hits = 0;
static unsigned long bc2cpp_owner_icache_misses = 0;
static struct bc2cpp_owner_icache_report {
  ~bc2cpp_owner_icache_report() { fprintf(stderr, "bc2cpp: OWNER_ICACHE hits=%lu lookups=%lu\n", bc2cpp_owner_icache_hits, bc2cpp_owner_icache_misses); }
} bc2cpp_owner_icache_report_at_exit;
#endif
#ifdef BC2CPP_OWNER_ICACHE
static inline bool bc2cpp_method_eq(const mrb_method_t& a, const mrb_method_t& b) {
  uintptr_t x, y;
  memcpy(&x, &a.as, sizeof x);
  memcpy(&y, &b.as, sizeof y);
  return a.flags == b.flags && x == y;
}
// The site's kept call, while mruby's method cache still holds the same entry for (klass, mid). A fork with rows
// (MRB_MT_ROWS) bumps mt_epoch wherever it clears that cache, and a row is never cached: the epoch decides there.
static inline bool bc2cpp_owner_icache_hit(mrb_state* M, const bc2cpp_owner_set& s, struct RClass* klass, mrb_sym mid, mrb_int argc) {
  if (s.hit_klass != klass || (mrb_int)s.hit_argc != argc || s.epoch != bc2cpp_owner_epoch) return false;
#ifdef MRB_MT_ROWS
  (void)mid;
  if (s.hit_mt_epoch != M->mt_epoch) return false;
#else
  int h = mrb_int_hash_func(M, ((intptr_t)klass) ^ mid) & (MRB_METHOD_CACHE_SIZE - 1);
  const struct mrb_cache_entry* mc = &M->cache[h];
  if (mc->c != klass || mc->mid != mid || mc->c0 != s.hit_c || !bc2cpp_method_eq(mc->m, s.hit_m)) return false;
#endif
#ifdef BC2CPP_OWNER_ICACHE_STATS
  ++bc2cpp_owner_icache_hits;
#endif
  return true;
}
#endif
// I is the call's symbol slot, L its level, then the owner list.
#define BC2CPP_OWNERS(I, L, ...) ([]() -> const bc2cpp_owner_desc* { static const char* const names[] = { __VA_ARGS__, nullptr }; static bc2cpp_owner_set s; static const bc2cpp_owner_desc d = { names, nullptr, &s, I, L }; return &d; }())
// OWNER_CALL_DIRECT: DIRECTS is a run of BC2CPP_OWNER_DIRECT(owner, entry, aspec, visibility), no commas between.
#define BC2CPP_OWNER_DIRECT(owner, fn, aspec, vis) { owner, fn, (uint32_t)(aspec) | (uint32_t)(vis) },
#define BC2CPP_OWNERS_D(I, L, DIRECTS, ...) ([]() -> const bc2cpp_owner_desc* { static const char* const names[] = { __VA_ARGS__, nullptr }; static const bc2cpp_owner_direct rows[] = { DIRECTS }; static struct RClass* cls[sizeof rows / sizeof rows[0]]; static unsigned ep; static const bc2cpp_owner_directs dr = { rows, cls, &ep, (int)(sizeof rows / sizeof rows[0]) }; static bc2cpp_owner_set s; static const bc2cpp_owner_desc d = { names, &dr, &s, I, L }; return &d; }())
// OWNER_SET_SHARE (owner_set_share.rb): the descriptor every site with key K shares, defined once below; the
// site's slot, level and owner list stay spelled for the reader.
#define BC2CPP_SHARED(K, ...) (&bc2cpp_owner_sd_##K)
[[noreturn, gnu::cold, gnu::noinline]] static void bc2cpp_owner_violation(mrb_state* M, mrb_value recv, mrb_sym mid, const char* what) {
#ifdef BC2CPP_NOMETHOD_VERIFY
  fprintf(stderr, "bc2cpp: NOMETHOD_VERIFY: owner-call violation: %s", mrb_class_name(M, mrb_obj_class(M, recv)));
  fprintf(stderr, "#%s: %s\n", mrb_sym_name(M, mid), what);
  fflush(stderr);
  abort();
#endif
  mrb_value msg = mrb_format(M, "closed-world owner violation: %T#%n %s", recv, mid, what);
  struct RClass* klass = mrb_define_class(M, "BC2cppGuardViolation", mrb_exc_get_id(M, mrb_intern_lit(M, "NoMethodError")));
  mrb_exc_raise(M, mrb_exc_new_str(M, klass, msg));
}
// The singleton class of an object that is no class or module: the registry names it `Const.singleton` after the
// constant its `def Const.x` was written on (resolve_singleton_receiver), so it is listed when that constant holds
// the very object. The path is walked with mrb_const_defined_at first, so no const_missing runs.
static bool bc2cpp_owner_listed_object(mrb_state* M, mrb_value attached, const char* const* names) {
  for (int k = 0; names[k]; ++k) {
    size_t n = strlen(names[k]);
    if (n <= 10 || strcmp(names[k] + n - 10, ".singleton") != 0) continue;
    size_t end = n - 10;
    mrb_value cur = mrb_obj_value(M->object_class);
    bool found = true;
    for (size_t pos = 0; pos < end;) {
      size_t stop = pos;
      while (stop < end && names[k][stop] != ':') ++stop;
      mrb_sym id = mrb_intern(M, names[k] + pos, stop - pos);
      if ((mrb_type(cur) != MRB_TT_CLASS && mrb_type(cur) != MRB_TT_MODULE) || !mrb_const_defined_at(M, cur, id)) {
        found = false;
        break;
      }
      cur = mrb_const_get(M, cur, id);
      pos = stop + 2;
    }
    if (found && mrb_obj_eq(M, cur, attached)) return true;
  }
  return false;
}
// Is `c` (a method's owner, an iclass already resolved to its module) one of `names`?
static bool bc2cpp_owner_listed(mrb_state* M, struct RClass* c, const char* const* names) {
  bool singleton = false;
  if (c->tt == MRB_TT_SCLASS) {
    mrb_value attached = mrb_iv_get(M, mrb_obj_value(c), mrb_intern_lit(M, "__attached__"));
    if (mrb_type(attached) != MRB_TT_CLASS && mrb_type(attached) != MRB_TT_MODULE) {
      return bc2cpp_owner_listed_object(M, attached, names);
    }
    c = mrb_class_ptr(attached);
    singleton = true;
  }
  if (c->tt != MRB_TT_CLASS && c->tt != MRB_TT_MODULE) return false;
  const char* path = mrb_class_name(M, c);
  if (!path) return false;
  size_t len = strlen(path);
  for (int k = 0; names[k]; ++k) {
    size_t n = strlen(names[k]);
    bool listed_singleton = n > 10 && strcmp(names[k] + n - 10, ".singleton") == 0;
    if (listed_singleton != singleton) continue;
    if ((listed_singleton ? n - 10 : n) == len && memcmp(names[k], path, len) == 0) return true;
  }
  return false;
}
// OWNER_CALL_DIRECT: the class or module at "A::B" (".singleton": its singleton class), or null when a segment is
// not defined; walked with mrb_const_defined_at first, so no const_missing runs.
static struct RClass* bc2cpp_owner_direct_class(mrb_state* M, const char* path) {
  size_t end = strlen(path);
  bool singleton = end > 10 && strcmp(path + end - 10, ".singleton") == 0;
  if (singleton) end -= 10;
  mrb_value cur = mrb_obj_value(M->object_class);
  for (size_t pos = 0; pos < end;) {
    size_t stop = pos;
    while (stop < end && path[stop] != ':') ++stop;
    mrb_sym id = mrb_intern(M, path + pos, stop - pos);
    if ((mrb_type(cur) != MRB_TT_CLASS && mrb_type(cur) != MRB_TT_MODULE) || !mrb_const_defined_at(M, cur, id)) return nullptr;
    cur = mrb_const_get(M, cur, id);
    pos = stop + 2;
  }
  if (mrb_type(cur) != MRB_TT_CLASS && mrb_type(cur) != MRB_TT_MODULE) return nullptr;
  return singleton ? mrb_class_ptr(mrb_singleton_class(M, cur)) : mrb_class_ptr(cur);
}
// OWNER_CALL_DIRECT: what mruby's lookup would find if every direct owner's entry were registered. The receiver's
// ancestors are walked in lookup order up to where the table lookup found the name (`*c`; the whole chain when it
// found none): the first direct owner met there answers with its entry, as its registration would have. A
// prepended class keeps the table lookup (its origin reorders the chain; the closed world prepends into none).
static void bc2cpp_owner_direct_pick(mrb_state* M, const bc2cpp_owner_directs& t, struct RClass* klass, mrb_method_t* m, struct RClass** c) {
  if (*t.epoch != bc2cpp_owner_epoch) {
    for (int d = 0; d < t.count; ++d) t.cls[d] = bc2cpp_owner_direct_class(M, t.rows[d].owner);
    *t.epoch = bc2cpp_owner_epoch;
  }
  struct RClass* found = MRB_METHOD_UNDEF_P(*m) ? nullptr : *c;
  for (struct RClass* k = klass; k; k = k->super) {
    if (MRB_FLAG_TEST(k, MRB_FL_CLASS_IS_PREPENDED)) return;
    struct RClass* o = k->tt == MRB_TT_ICLASS ? k->c : k;
    for (int d = 0; d < t.count; ++d) {
      if (t.cls[d] != o) continue;
      MRB_METHOD_FROM_FUNC(*m, t.rows[d].func);
      m->flags |= t.rows[d].flags;
      *c = k;
      return;
    }
    if (k == found) return;
  }
}
// The argv form: a splat site passes the Array's own items, as mrb_funcall_with_block would (both reach vm.c's
// funcall_with_block_m, whose funcall_args_capture copies them and packs a long list as OP_SEND does).
// CALLER_SELF: a level 2 call passes the caller's self (the generated code's `self`) for the protected check.
static mrb_value bc2cpp_owner_call_argv(mrb_state* M, mrb_value recv, const bc2cpp_owner_desc* d, mrb_value blk, mrb_int argc, const mrb_value* argv,
                                        mrb_value caller_self = mrb_nil_value()) {
  bc2cpp_owner_set& s = *d->set;
  int level = d->level;
  mrb_sym mid = bc2cpp_sym(M, d->mid);
  // As bc2cpp_funcall_argv: Proc#call and its aliases on a compiled block are a yield, not an OP_CALL in a C frame.
  if (mrb_nil_p(blk) && mrb_type(recv) == MRB_TT_PROC && bc2cpp_cfunc_proc_call_p(M, recv, mid)) return bc2cpp_yield_argv(M, recv, argc, argv);
  struct RClass* klass = mrb_class(M, recv);
#ifdef BC2CPP_OWNER_ICACHE
  if (bc2cpp_owner_icache_hit(M, s, klass, mid, argc)) return bc2cpp_keep_call(M, [&] { return bc2cpp_call_found(M, recv, mid, &s.hit_m, s.hit_c, argc, argv, blk); });
#endif
#ifdef BC2CPP_OWNER_ICACHE_STATS
  ++bc2cpp_owner_icache_misses;
#endif
  struct RClass* c = klass;
  mrb_method_t m = bc2cpp_find_proven(M, &c, mid);
  if (d->direct) bc2cpp_owner_direct_pick(M, *d->direct, klass, &m, &c);
  if (MRB_METHOD_UNDEF_P(m)) {
    if (mrb_nil_p(blk)) bc2cpp_funcall_argv(M, recv, mid, argc, argv);
    else mrb_funcall_with_block(M, recv, mid, argc, argv, blk);
    bc2cpp_owner_violation(M, recv, mid, "was proven to raise NoMethodError but dispatched");
  }
  struct RClass* owner = c->tt == MRB_TT_ICLASS ? c->c : c;
  if (s.epoch != bc2cpp_owner_epoch) {
    s.epoch = bc2cpp_owner_epoch;
    s.seen_count = 0;
    s.hit_klass = nullptr;
  }
  bool seen = false;
  for (int k = 0; k < s.seen_count; ++k) seen = seen || s.seen[k] == owner;
  if (!seen) {
    if (!bc2cpp_owner_listed(M, owner, d->names)
#ifdef BC2CPP_FIBER_RUNTIME
        && !bc2cpp_fiber_definer_p(m)
#endif
    ) bc2cpp_owner_violation(M, recv, mid, "resolves to a definer the closed world does not list");
    if (!s.seen) s.seen = (struct RClass**)malloc(32 * sizeof(struct RClass*));
    if (s.seen && s.seen_count < 32) s.seen[s.seen_count++] = owner;
  }
  if (level >= 2) {
    // vm.c OP_SEND: an explicit receiver may not call a private method, nor a protected one unless the caller's
    // self is a kind_of the class or module the method was found on.
    if (m.flags & MRB_METHOD_PRIVATE_FL) {
      mrb_no_method_error(M, mid, mrb_ary_new_from_values(M, argc, argv), "%s method '%n' called for %T", "private", mid, recv);
    }
    if ((m.flags & MRB_METHOD_PROTECTED_FL) && !mrb_obj_is_kind_of(M, caller_self, c)) {
      mrb_no_method_error(M, mid, mrb_ary_new_from_values(M, argc, argv), "%s method '%n' called for %T", "protected", mid, recv);
    }
  }
  if (level >= 1) {
    if (MRB_METHOD_PROC_P(m)) {
      const struct RProc* p = MRB_METHOD_PROC(m);
      if (MRB_PROC_ALIAS_P(p)) p = p->upper;
      if (MRB_PROC_CFUNC_P(p) && MRB_PROC_NOARG_P(p) && argc > 0) mrb_argnum_error(M, argc, 0, 0);
    } else {
      // vm.c check_argument_count: a raw C function's registered aspec, before the call.
      mrb_aspec aspec = MRB_MT_ASPEC(m.flags);
      int min = MRB_ASPEC_REQ(aspec) + MRB_ASPEC_POST(aspec);
      int max = MRB_ASPEC_REST(aspec) ? -1 : min + MRB_ASPEC_OPT(aspec);
      if (argc < min || (max >= 0 && argc > max)) mrb_argnum_error(M, argc, min, max);
    }
  }
#ifdef BC2CPP_OWNER_ICACHE
  if (!(m.flags & MRB_METHOD_PROTECTED_FL) && argc <= UINT8_MAX) {
    s.hit_klass = klass;
    s.hit_c = c;
    s.hit_m = m;
    s.hit_argc = (uint8_t)argc;
#ifdef MRB_MT_ROWS
    s.hit_mt_epoch = M->mt_epoch;
#endif
  }
#endif
  return bc2cpp_keep_call(M, [&] { return bc2cpp_call_found(M, recv, mid, &m, c, argc, argv, blk); });
}
static mrb_value bc2cpp_owner_call(mrb_state* M, mrb_value recv, const bc2cpp_owner_desc* d, mrb_value blk, mrb_int argc, ...) {
  mrb_value argv[16];
  va_list ap;
  va_start(ap, argc);
  for (mrb_int k = 0; k < argc && k < 16; k++) argv[k] = va_arg(ap, mrb_value);
  for (mrb_int k = 16; k < argc; k++) (void)va_arg(ap, mrb_value);
  mrb_value caller_self = d->level >= 2 ? va_arg(ap, mrb_value) : mrb_nil_value();
  va_end(ap);
  return bc2cpp_owner_call_argv(M, recv, d, blk, argc, argv, caller_self);
}

#ifdef BC2CPP_NOMETHOD_VERIFY
#include <stdio.h>
#include <stdlib.h>
#endif
[[noreturn, gnu::cold, gnu::noinline]] static void bc2cpp_nomethod_argv(mrb_state* M, mrb_value recv, int i, mrb_int argc, const mrb_value* argv) {
  mrb_sym mid = bc2cpp_sym(M, i);
#ifdef BC2CPP_NOMETHOD_VERIFY
  // ADR 0275: reaching a site the closed world proved dead is the finding. Dispatching
  // first would let a wrong proof run a method, and a rescue hide the raise, so abort.
  // Two calls: mrb_class_name and mrb_sym_name may share one scratch buffer.
  fprintf(stderr, "bc2cpp: NOMETHOD_VERIFY: dead site reached: %s", mrb_class_name(M, mrb_obj_class(M, recv)));
  fprintf(stderr, "#%s (%d arg(s))\n", mrb_sym_name(M, mid), (int)argc);
  fflush(stderr);
  abort();
#endif
#ifdef BC2CPP_FAIL_FAST_TYPE
  // FAIL_FAST_TYPE (compile-time, see BC2CPP_FAIL_FAST_TYPE in compiled_gems.rb): the receiver is not one the closed
  // world proved answers the name, so the fallback is a type error. Raised here instead of dispatching.
  mrb_raisef(M, mrb_exc_get_id(M, mrb_intern_lit(M, "TypeError")), "bc2cpp: fail-fast: %T does not answer %n", recv, mid);
#endif
  bc2cpp_funcall_argv(M, recv, mid, argc, argv);
  // The dispatch above found a method: the proof was wrong (ADR 0262). A
  // NoMethodError here would look like an ordinary user error.
  mrb_raisef(M, mrb_exc_get_id(M, mrb_intern_lit(M, "RuntimeError")),
             "bc2cpp: closed-world proof violated: %T#%n was proven undefined but dispatched", recv, mid);
}
// Typed as returning so GCC keeps the call site in place: a known-noreturn
// call is moved to the end of its function, which costs more than it saves.
BC2CPP_NOIPA static mrb_value bc2cpp_nomethod(mrb_state* M, mrb_value recv, int i) {
  bc2cpp_nomethod_argv(M, recv, i, 0, nullptr);
}
BC2CPP_NOIPA static mrb_value bc2cpp_nomethod(mrb_state* M, mrb_value recv, int i, mrb_int argc, ...) {
  mrb_value argv[16];
  va_list ap;
  va_start(ap, argc);
  for (mrb_int k = 0; k < argc; k++) argv[k] = va_arg(ap, mrb_value);
  va_end(ap);
  bc2cpp_nomethod_argv(M, recv, i, argc, argv);
}
// DIRECT_RAISE (ADR 0226): a reviewed dead site, which the closed world proves answers the name
// neither by a method nor by method_missing. Dispatch would find nothing and reach mruby's basic
// method_missing (mrb_method_missing), which raises this NoMethodError; the format is that function's.
[[noreturn, gnu::cold, gnu::noinline]] static void bc2cpp_nomethod_raise_argv(mrb_state* M, mrb_value recv, int i, mrb_int argc, const mrb_value* argv) {
  mrb_sym mid = bc2cpp_sym(M, i);
#ifdef BC2CPP_NOMETHOD_VERIFY
  fprintf(stderr, "bc2cpp: NOMETHOD_VERIFY: dead site reached: %s", mrb_class_name(M, mrb_obj_class(M, recv)));
  fprintf(stderr, "#%s (%d arg(s))\n", mrb_sym_name(M, mid), (int)argc);
  fflush(stderr);
  abort();
#endif
  mrb_no_method_error(M, mid, mrb_ary_new_from_values(M, argc, argv), "undefined method '%n' for %T", mid, recv);
}
BC2CPP_NOIPA static mrb_value bc2cpp_nomethod_raise(mrb_state* M, mrb_value recv, int i) {
  bc2cpp_nomethod_raise_argv(M, recv, i, 0, nullptr);
}
BC2CPP_NOIPA static mrb_value bc2cpp_nomethod_raise(mrb_state* M, mrb_value recv, int i, mrb_int argc, ...) {
  mrb_value argv[16];
  va_list ap;
  va_start(ap, argc);
  for (mrb_int k = 0; k < argc; k++) argv[k] = va_arg(ap, mrb_value);
  va_end(ap);
  bc2cpp_nomethod_raise_argv(M, recv, i, argc, argv);
}

#ifdef BC2CPP_NOMETHOD_VERIFY
#include <stdio.h>
#include <stdlib.h>
#endif
[[noreturn, gnu::cold, gnu::noinline]] static void bc2cpp_guard_violation_raise(mrb_state* M, mrb_value recv, mrb_sym mid, const char* site) {
#ifdef BC2CPP_NOMETHOD_VERIFY
  fprintf(stderr, "bc2cpp: NOMETHOD_VERIFY: guard violation reached: %s", mrb_class_name(M, mrb_obj_class(M, recv)));
  fprintf(stderr, "#%s at %s\n", mrb_sym_name(M, mid), site);
  fflush(stderr);
  abort();
#endif
  mrb_value msg = mrb_format(M, "closed-world guard violation: %T#%n at %s", recv, mid, site);
  bc2cpp_stderr_report(M, "[RPG2k] ", msg);
  struct RClass* klass = mrb_define_class(M, "BC2cppGuardViolation", mrb_exc_get_id(M, mrb_intern_lit(M, "NoMethodError")));
  mrb_exc_raise(M, mrb_exc_new_str(M, klass, msg));
}
// Typed as returning, like bc2cpp_nomethod, so GCC keeps the call in place.
BC2CPP_NOIPA static mrb_value bc2cpp_guard_violation(mrb_state* M, mrb_value recv, int i, const char* site, mrb_int argc, ...) {
#ifdef BC2CPP_GUARD_VIOLATION_DISPATCH
  mrb_value argv[16];
  va_list ap;
  va_start(ap, argc);
  for (mrb_int k = 0; k < argc && k < 16; k++) argv[k] = va_arg(ap, mrb_value);
  va_end(ap);
  return bc2cpp_funcall_argv(M, recv, bc2cpp_sym(M, i), argc, argv);
#else
  (void)argc;
  bc2cpp_guard_violation_raise(M, recv, bc2cpp_sym(M, i), site);
#endif
}


static mrb_value bc2cpp_const_scope_0(mrb_state* M, mrb_sym name) {
  mrb_value scope0 = mrb_const_get(M, mrb_obj_value(M->object_class), bc2cpp_sym(M, 22));
  mrb_value result;
  if (bc2cpp_const_own(M, scope0, name, &result)) return result;
  if (bc2cpp_const_own(M, mrb_obj_value(M->object_class), name, &result)) return result;
  return bc2cpp_const_inherited(M, scope0, name);
}
// CONST_SITE_CACHE -- see tools/bc2cpp/const_site_cache.rb.
static mrb_state* bc2cpp_cconst_state = nullptr;
static mrb_value bc2cpp_cconst_slots[1];
static bool bc2cpp_cconst_have[1] = {};
static struct RClass* bc2cpp_mcnst_from[1];
static mrb_value bc2cpp_mcnst_slots[1];
static void bc2cpp_reset_const_site_cache() {
  bc2cpp_cconst_state = nullptr;
  for (bool& h : bc2cpp_cconst_have) h = false;
  for (struct RClass*& f : bc2cpp_mcnst_from) f = nullptr;
}
[[gnu::cold, gnu::noinline]] static void bc2cpp_cconst_bind_conflict(mrb_state* M) {
  mrb_bug(M, "bc2cpp CONST_SITE_CACHE: compiled code ran in a second live mrb_state; the slots hold one VM's values");
}
static inline void bc2cpp_cconst_bind(mrb_state* M) {
  if (bc2cpp_cconst_state == M) return;
  if (bc2cpp_cconst_state) bc2cpp_cconst_bind_conflict(M);
  bc2cpp_cconst_state = M;
}
[[gnu::noinline]] static mrb_value bc2cpp_cconst_fill_0(mrb_state* M) {
  bc2cpp_cconst_bind(M);
  mrb_value r0 = mrb_nil_value();
    r0 = bc2cpp_const_scope_0(M, bc2cpp_sym(M, 9));
  if (mrb_type(r0) == MRB_TT_CLASS || mrb_type(r0) == MRB_TT_MODULE) {
    bc2cpp_cconst_slots[0] = r0;
    bc2cpp_cconst_have[0] = true;
  }
  return r0;
}
static inline mrb_value bc2cpp_cconst_0(mrb_state* M) {
  return bc2cpp_cconst_have[0] ? bc2cpp_cconst_slots[0] : bc2cpp_cconst_fill_0(M);
}
// NUMERIC_SLOW_PATH (ADR 0292): mruby's bigint entry points are declared only in
// mruby/internal.h, which has no C linkage guard.
#ifdef MRB_USE_BIGINT
extern "C" mrb_value mrb_bint_div(mrb_state*, mrb_value, mrb_value);
extern "C" mrb_value mrb_bint_mod(mrb_state*, mrb_value, mrb_value);
extern "C" mrb_value mrb_bint_and(mrb_state*, mrb_value, mrb_value);
extern "C" mrb_value mrb_bint_or(mrb_state*, mrb_value, mrb_value);
extern "C" mrb_value mrb_bint_xor(mrb_state*, mrb_value, mrb_value);
extern "C" mrb_value mrb_bint_lshift(mrb_state*, mrb_value, mrb_int);
extern "C" mrb_value mrb_bint_rshift(mrb_state*, mrb_value, mrb_int);
extern "C" mrb_value mrb_bint_new_int(mrb_state*, mrb_int);
extern "C" mrb_value mrb_bint_add_ii(mrb_state*, mrb_int, mrb_int);
extern "C" mrb_value mrb_bint_sub_ii(mrb_state*, mrb_int, mrb_int);
extern "C" mrb_value mrb_bint_mul_ii(mrb_state*, mrb_int, mrb_int);
extern "C" mrb_value mrb_as_bint(mrb_state*, mrb_value);
#endif
// Whole bodies of Integer#% and Float#% (the pinned fork commit (mruby-expose-misc-bodies, docs/patch-fork-tracking.md), ADR 0367).
extern "C" mrb_value mrb_int_mod_impl(mrb_state*, mrb_value, mrb_value);
extern "C" mrb_value mrb_str_mod_impl(mrb_state*, mrb_value, mrb_value);
#ifndef MRB_NO_FLOAT
extern "C" mrb_value mrb_flo_mod_impl(mrb_state*, mrb_value, mrb_value);
#endif
// mrb_bigint_p and mrb_float_p are FALSE in a build without them.
static inline mrb_bool bc2cpp_slow_int_p(mrb_value v) { return mrb_integer_p(v) || mrb_bigint_p(v); }
static inline mrb_bool bc2cpp_slow_num_p(mrb_value v) { return bc2cpp_slow_int_p(v) || mrb_float_p(v); }

static mrb_value bc2cpp_slow_add_f(mrb_state* M, mrb_value a, mrb_value b) {
  if (!((bc2cpp_slow_int_p(a) && bc2cpp_slow_num_p(b)) || (mrb_float_p(a) && bc2cpp_slow_num_p(b)))) return bc2cpp_owner_call(M, a, BC2CPP_OWNERS(23, 0, "Array", "Float", "Integer", "String", "Time"), mrb_nil_value(), 1, b) /* CLOSED_WORLD owner-call: + */;
  if (mrb_integer_p(a) && mrb_integer_p(b)) {
    mrb_int x = mrb_integer(a), y = mrb_integer(b), z;
    if (!mrb_int_add_overflow(x, y, &z)) return mrb_int_value(M, z);
#ifdef MRB_USE_BIGINT
    int ai = mrb_gc_arena_save(M);
    mrb_value r = mrb_bint_add_ii(M, x, y);
    return bc2cpp_arena_keep(M, ai, r);
#else
    mrb_state* mrb = M;  // E_RANGE_ERROR names the state `mrb`
    mrb_raise(M, E_RANGE_ERROR, "integer overflow");
#endif
  }
  int ai = mrb_gc_arena_save(M);
  mrb_value r = mrb_num_add(M, a, b);
  return bc2cpp_arena_keep(M, ai, r);
}

extern "C" struct RClass* mrb_vm_define_class(mrb_state*, mrb_value, mrb_value, mrb_sym);
extern "C" struct RClass* mrb_vm_define_module(mrb_state*, mrb_value, mrb_sym);
static mrb_value bc2cpp_class_body_Foo_0(mrb_state* M) {
  mrb_value self = mrb_obj_value(bc2cpp_owner_class_0(M));
  [[maybe_unused]] mrb_value r0 = self;
  mrb_value r1 = mrb_nil_value();
  mrb_define_private_method(M, mrb_class_ptr(self), "\x69\x6e\x69\x74\x69\x61\x6c\x69\x7a\x65", Foo_initialize, MRB_ARGS_NONE());
  r1 = mrb_symbol_value(bc2cpp_sym(M, 8));
  mrb_define_method(M, mrb_class_ptr(self), "\x73\x69\x7a\x65\x32", Foo_size2, MRB_ARGS_NONE());
  r1 = mrb_symbol_value(bc2cpp_sym(M, 2));
  return r0;
}
static void bc2cpp_top_unit_Foo_0(mrb_state* M) {
  (void)mrb_vm_define_class(M, mrb_obj_value(M->object_class), mrb_nil_value(), bc2cpp_sym(M, 9));
  (void)bc2cpp_class_body_Foo_0(M);
}
extern "C" struct RClass* mrb_vm_define_class(mrb_state*, mrb_value, mrb_value, mrb_sym);
extern "C" struct RClass* mrb_vm_define_module(mrb_state*, mrb_value, mrb_sym);
static mrb_value bc2cpp_class_body_Menu_0(mrb_state* M) {
  mrb_value self = mrb_obj_value(bc2cpp_owner_class_1(M));
  [[maybe_unused]] mrb_value r0 = self;
  mrb_value r1 = mrb_nil_value();
  mrb_define_method(M, mrb_class_ptr(self), "\x70\x69\x63\x6b", Menu_pick, MRB_ARGS_REQ(1) | MRB_ARGS_OPT(1));
  r1 = mrb_symbol_value(bc2cpp_sym(M, 10));
  mrb_define_method(M, mrb_class_ptr(self), "\x61\x64\x64", Menu_add, MRB_ARGS_REQ(1) | MRB_ARGS_OPT(1));
  r1 = mrb_symbol_value(bc2cpp_sym(M, 11));
  mrb_define_method(M, mrb_class_ptr(self), "\x63\x6f\x6d\x70\x75\x74\x65\x64", Menu_computed, MRB_ARGS_REQ(1) | MRB_ARGS_OPT(1));
  r1 = mrb_symbol_value(bc2cpp_sym(M, 12));
  mrb_define_method(M, mrb_class_ptr(self), "\x6c\x61\x74\x65\x72", Menu_later, MRB_ARGS_REQ(1) | MRB_ARGS_OPT(2));
  r1 = mrb_symbol_value(bc2cpp_sym(M, 13));
  mrb_define_method(M, mrb_class_ptr(self), "\x6c\x6f\x6f\x73\x65", Menu_loose, MRB_ARGS_REQ(1) | MRB_ARGS_OPT(1));
  r1 = mrb_symbol_value(bc2cpp_sym(M, 14));
  mrb_define_method(M, mrb_class_ptr(self), "\x73\x6f\x72\x74\x65\x64", Menu_sorted, MRB_ARGS_REQ(1) | MRB_ARGS_OPT(1));
  r1 = mrb_symbol_value(bc2cpp_sym(M, 15));
  mrb_define_method(M, mrb_class_ptr(self), "\x6b\x65\x79\x73\x5f\x6f\x66", Menu_keys_of, MRB_ARGS_REQ(1));
  r1 = mrb_symbol_value(bc2cpp_sym(M, 16));
  mrb_define_method(M, mrb_class_ptr(self), "\x73\x68\x6f\x75\x74", Menu_shout, MRB_ARGS_REQ(1));
  r1 = mrb_symbol_value(bc2cpp_sym(M, 17));
  mrb_define_method(M, mrb_class_ptr(self), "\x72\x75\x6e", Menu_run, MRB_ARGS_NONE());
  r1 = mrb_symbol_value(bc2cpp_sym(M, 18));
  mrb_define_method(M, mrb_class_ptr(self), "\x77\x72\x6f\x6e\x67\x5f\x73\x6f\x72\x74\x65\x64", Menu_wrong_sorted, MRB_ARGS_NONE());
  r1 = mrb_symbol_value(bc2cpp_sym(M, 19));
  mrb_define_method(M, mrb_class_ptr(self), "\x77\x72\x6f\x6e\x67", Menu_wrong, MRB_ARGS_NONE());
  r1 = mrb_symbol_value(bc2cpp_sym(M, 20));
  mrb_define_method(M, mrb_class_ptr(self), "\x77\x72\x6f\x6e\x67\x5f\x61\x64\x64", Menu_wrong_add, MRB_ARGS_NONE());
  r1 = mrb_symbol_value(bc2cpp_sym(M, 21));
  return r1;
}
static void bc2cpp_top_unit_Menu_0(mrb_state* M) {
  (void)mrb_vm_define_class(M, mrb_obj_value(M->object_class), mrb_nil_value(), bc2cpp_sym(M, 22));
  (void)bc2cpp_class_body_Menu_0(M);
}
// Foo#initialize (compiled from irep 3, 4 insns)
mrb_value Foo_initialize_impl(mrb_state* M, mrb_value self) {
  [[maybe_unused]] mrb_value r0 = self;
  mrb_value r2 = mrb_nil_value();
  {
    Foo_ivars* embedded = (Foo_ivars*)mrb_calloc(M, 1, sizeof(Foo_ivars));
    embedded->ivar_v = {};
    mrb_data_init(self, embedded, &Foo_ivars_type);
  }
  // 2 000 ENTER		0:0:0:0:0:0:0:0 (0x0) (args already bound above)
  r2 = mrb_fixnum_value(1);
  // @v embedded (fixnum) -- direct struct field write, no mrb_iv_set
  if (!mrb_fixnum_p(r2)) mrb_raise(M, mrb_exc_get_id(M, bc2cpp_sym(M, 0)), "@v: expected Integer");
  ((Foo_ivars*)DATA_PTR(self))->ivar_v = mrb_fixnum(r2);
  return mrb_nil_value();
  mrb_raise(M, mrb_exc_get_id(M, bc2cpp_sym(M, 1)), "bc2cpp: Foo#initialize fell off the end of its body");
}

static mrb_value Foo_initialize(mrb_state* M, mrb_value self) {
  return bc2cpp_cfunc_result({M, M->gc.arena_idx, Foo_initialize_impl(M, self)});
}

mrb_value bc2cpp_xrow_Foo_initialize(mrb_state* M, mrb_value self) { return Foo_initialize(M, self); }

// Foo#size2 (compiled from irep 4, 4 insns)
static inline mrb_value Foo_size2_impl_unguarded(mrb_state* M, mrb_value self) {
  [[maybe_unused]] mrb_value r0 = self;
  mrb_value r2 = mrb_nil_value();
  // 7 000 ENTER		0:0:0:0:0:0:0:0 (0x0) (args already bound above)
  // @v embedded (fixnum) -- direct struct field read, no mrb_iv_get
  r2 = mrb_fixnum_value(((Foo_ivars*)DATA_PTR(self))->ivar_v);
  // operands proven Fixnum -- no runtime check, no by-name send fallback
  if (mrb_unlikely(bc2cpp_fixnum_add(r2, mrb_fixnum_value(1), r2))) { r2 = mrb_num_add(M, r2, mrb_fixnum_value(1)); }
  return r2;
  mrb_raise(M, mrb_exc_get_id(M, bc2cpp_sym(M, 1)), "bc2cpp: Foo#size2 fell off the end of its body");
}

static mrb_value Foo_size2(mrb_state* M, mrb_value self) {
  return bc2cpp_cfunc_result({M, M->gc.arena_idx, Foo_size2_impl(M, self)});
}

mrb_value Foo_size2_impl(mrb_state* M, mrb_value self) {
  mrb_value bc2cpp_declared_ret = Foo_size2_impl_unguarded(M, self);
  if (mrb_unlikely(!(mrb_fixnum_p(bc2cpp_declared_ret)))) bc2cpp_declared_return_violation(M, bc2cpp_declared_ret, "Foo#size2", "Integer"); /* DECLARED_RETURN_GUARD Foo#size2 -> Integer */
  return bc2cpp_declared_ret;
}

mrb_value bc2cpp_xrow_Foo_size2(mrb_state* M, mrb_value self) { return Foo_size2(M, self); }

// Menu#pick (compiled from irep 9, 13 insns)
static inline mrb_value Menu_pick_impl_unguarded(mrb_state* M, mrb_value self, mrb_value a, mrb_value b, mrb_int bc2cpp_given_opt) {
  [[maybe_unused]] mrb_value r0 = self;
  mrb_value r1 = a;
  mrb_value r2 = b;
  mrb_value r4 = mrb_nil_value();
  // 13 000 ENTER		1:1:0:0:0:0:0:0 (0x42000) (args already bound above)
  switch (bc2cpp_given_opt) {
    case 0: goto L10;
    default: goto L12;
  }
  L10:;
  r2 = mrb_nil_value();
  L12:;
  if (mrb_nil_p(r2)) goto L22;
  goto L30;
  L22:;
  r4 = r1;
  // MONO_EXACT_FLOW :size2 -> Foo#size2 (receiver proven exactly Foo), direct C++ call with no class guard
  r4 = Foo_size2_impl(M, r4);
  return r4;
  L30:;
  r4 = r2;
  // MONO_EXACT_FLOW :size2 -> Foo#size2 (receiver proven exactly Foo), direct C++ call with no class guard
  r4 = Foo_size2_impl(M, r4);
  return r4;
  mrb_raise(M, mrb_exc_get_id(M, bc2cpp_sym(M, 1)), "bc2cpp: Menu#pick fell off the end of its body");
}

static mrb_value Menu_pick(mrb_state* M, mrb_value self) {
  mrb_value a;
  mrb_value b = mrb_nil_value();
  bc2cpp_check_argc(M, 1, 2);
  mrb_get_args(M, "o|o", &a, &b);
  mrb_int bc2cpp_given_opt = mrb_get_argc(M) - 1;
  if (bc2cpp_given_opt < 0) bc2cpp_given_opt = 0;
  if (bc2cpp_given_opt > 1) bc2cpp_given_opt = 1;
  return bc2cpp_cfunc_result({M, M->gc.arena_idx, Menu_pick_impl(M, self, a, b, bc2cpp_given_opt)});
}

mrb_value Menu_pick_impl(mrb_state* M, mrb_value self, mrb_value a, mrb_value b, mrb_int bc2cpp_given_opt) {
  if (mrb_unlikely(!(bc2cpp_class_is(M, a, bc2cpp_owner_class_0(M))))) bc2cpp_declared_param_violation(M, a, "Menu#pick", 1, "Foo"); /* DECLARED_PARAM_GUARD Menu#pick arg 1 */
  if (mrb_unlikely(!(bc2cpp_given_opt <= 0 || (mrb_nil_p(b) || (bc2cpp_class_is(M, b, bc2cpp_owner_class_0(M))))))) bc2cpp_declared_param_violation(M, b, "Menu#pick", 2, "Foo?"); /* DECLARED_PARAM_GUARD Menu#pick arg 2 */
  mrb_value bc2cpp_declared_ret = Menu_pick_impl_unguarded(M, self, a, b, bc2cpp_given_opt);
  return bc2cpp_declared_ret;
}

mrb_value bc2cpp_xrow_Menu_pick(mrb_state* M, mrb_value self) { return Menu_pick(M, self); }

// Menu#add (compiled from irep 10, 9 insns)
static inline mrb_value Menu_add_impl_unguarded(mrb_state* M, mrb_value self, mrb_value a, mrb_value b, mrb_int bc2cpp_given_opt) {
  [[maybe_unused]] mrb_value r0 = self;
  mrb_value r1 = a;
  mrb_value r2 = b;
  mrb_value r4 = mrb_nil_value();
  mrb_value r5 = mrb_nil_value();
  // 19 000 ENTER		1:1:0:0:0:0:0:0 (0x42000) (args already bound above)
  switch (bc2cpp_given_opt) {
    case 0: goto L10;
    default: goto L12;
  }
  L10:;
  r2 = mrb_fixnum_value(2);
  L12:;
  r4 = r1;
  // MONO_EXACT_FLOW :size2 -> Foo#size2 (receiver proven exactly Foo), direct C++ call with no class guard
  r4 = Foo_size2_impl(M, r4);
  r5 = r2;
{ mrb_value bc2cpp_nt;
  if (mrb_likely(BC2CPP_FIXNUM_PAIR_P(r4, r5))) {
  if (mrb_unlikely(bc2cpp_fixnum_add(r4, r5, r4))) { r4 = mrb_num_add(M, r4, r5); }
} else if (mrb_integer_p(r4) && mrb_integer_p(r5)) {
  r4 = mrb_num_add(M, r4, r5);
} else if (!mrb_undef_p(bc2cpp_nt = bc2cpp_num_add_float(M, r4, r5))) {
  r4 = bc2cpp_nt;
} else {
    // FIXNUM_ARITHMETIC :+ -- NUMERIC_SLOW_PATH (ADR 0292): mruby's own Integer/Float body, by-name call only inside the helper
  r4 = bc2cpp_slow_add_f(M, r4, r5);

}

}
  return r4;
  mrb_raise(M, mrb_exc_get_id(M, bc2cpp_sym(M, 1)), "bc2cpp: Menu#add fell off the end of its body");
}

static mrb_value Menu_add(mrb_state* M, mrb_value self) {
  mrb_value a;
  mrb_value b = mrb_nil_value();
  bc2cpp_check_argc(M, 1, 2);
  mrb_get_args(M, "o|o", &a, &b);
  mrb_int bc2cpp_given_opt = mrb_get_argc(M) - 1;
  if (bc2cpp_given_opt < 0) bc2cpp_given_opt = 0;
  if (bc2cpp_given_opt > 1) bc2cpp_given_opt = 1;
  return bc2cpp_cfunc_result({M, M->gc.arena_idx, Menu_add_impl(M, self, a, b, bc2cpp_given_opt)});
}

mrb_value Menu_add_impl(mrb_state* M, mrb_value self, mrb_value a, mrb_value b, mrb_int bc2cpp_given_opt) {
  if (mrb_unlikely(!(bc2cpp_class_is(M, a, bc2cpp_owner_class_0(M))))) bc2cpp_declared_param_violation(M, a, "Menu#add", 1, "Foo"); /* DECLARED_PARAM_GUARD Menu#add arg 1 */
  if (mrb_unlikely(!(bc2cpp_given_opt <= 0 || (mrb_fixnum_p(b))))) bc2cpp_declared_param_violation(M, b, "Menu#add", 2, "Integer"); /* DECLARED_PARAM_GUARD Menu#add arg 2 */
  mrb_value bc2cpp_declared_ret = Menu_add_impl_unguarded(M, self, a, b, bc2cpp_given_opt);
  if (mrb_unlikely(!(mrb_fixnum_p(bc2cpp_declared_ret)))) bc2cpp_declared_return_violation(M, bc2cpp_declared_ret, "Menu#add", "Integer"); /* DECLARED_RETURN_GUARD Menu#add -> Integer */
  return bc2cpp_declared_ret;
}

mrb_value bc2cpp_xrow_Menu_add(mrb_state* M, mrb_value self) { return Menu_add(M, self); }

// Menu#computed (compiled from irep 11, 12 insns)
static inline mrb_value Menu_computed_impl_unguarded(mrb_state* M, mrb_value self, mrb_value a, mrb_value b, mrb_int bc2cpp_given_opt) {
  [[maybe_unused]] mrb_value r0 = self;
  mrb_value r1 = a;
  mrb_value r2 = b;
  mrb_value r4 = mrb_nil_value();
  // 23 000 ENTER		1:1:0:0:0:0:0:0 (0x42000) (args already bound above)
  switch (bc2cpp_given_opt) {
    case 0: goto L10;
    default: goto L13;
  }
  L10:;
  r2 = r1;
  L13:;
  if (mrb_nil_p(r2)) goto L23;
  goto L27;
  L23:;
  r4 = mrb_fixnum_value(0);
  return r4;
  L27:;
  r4 = r2;
  // MONO_EMBED_GUARD :size2 -> Foo#size2 (embeds ivars; method_missing elsewhere could otherwise mistarget this), runtime-class-checked direct C++ call, by-name send fallback
  if (mrb_likely(bc2cpp_class_is(M, r4, bc2cpp_owner_class_0(M)))) {
    r4 = Foo_size2_impl(M, r4);
  } else {
    r4 = bc2cpp_nomethod(M, r4, 2); /* CLOSED_WORLD nomethod: recv.size2 @ /mnt/data/cache/claude-work/tmp/nix-shell.PNxmaD/declared-optional-param20261120-2882979-jpvyds/fixture.rb:26 */
  }
  return r4;
  mrb_raise(M, mrb_exc_get_id(M, bc2cpp_sym(M, 1)), "bc2cpp: Menu#computed fell off the end of its body");
}

static mrb_value Menu_computed(mrb_state* M, mrb_value self) {
  mrb_value a;
  mrb_value b = mrb_nil_value();
  bc2cpp_check_argc(M, 1, 2);
  mrb_get_args(M, "o|o", &a, &b);
  mrb_int bc2cpp_given_opt = mrb_get_argc(M) - 1;
  if (bc2cpp_given_opt < 0) bc2cpp_given_opt = 0;
  if (bc2cpp_given_opt > 1) bc2cpp_given_opt = 1;
  return bc2cpp_cfunc_result({M, M->gc.arena_idx, Menu_computed_impl(M, self, a, b, bc2cpp_given_opt)});
}

mrb_value Menu_computed_impl(mrb_state* M, mrb_value self, mrb_value a, mrb_value b, mrb_int bc2cpp_given_opt) {
  if (mrb_unlikely(!(bc2cpp_class_is(M, a, bc2cpp_owner_class_0(M))))) bc2cpp_declared_param_violation(M, a, "Menu#computed", 1, "Foo"); /* DECLARED_PARAM_GUARD Menu#computed arg 1 */
  mrb_value bc2cpp_declared_ret = Menu_computed_impl_unguarded(M, self, a, b, bc2cpp_given_opt);
  return bc2cpp_declared_ret;
}

mrb_value bc2cpp_xrow_Menu_computed(mrb_state* M, mrb_value self) { return Menu_computed(M, self); }

// Menu#later (compiled from irep 12, 15 insns)
static inline mrb_value Menu_later_impl_unguarded(mrb_state* M, mrb_value self, mrb_value a, mrb_value b, mrb_value c, mrb_int bc2cpp_given_opt) {
  [[maybe_unused]] mrb_value r0 = self;
  mrb_value r3 = c;
  mrb_value r5 = mrb_nil_value();
  // 29 000 ENTER		1:2:0:0:0:0:0:0 (0x44000) (args already bound above)
  switch (bc2cpp_given_opt) {
    case 0: goto L13;
    case 1: goto L19;
    default: goto L21;
  }
  L13:;
  // POLY_DIAG path=dynamic_no_registered_definition receiver=implicit_self_unresolved name="c" arity=0 candidates=0 excluded=no_registered_definition=1
  // POLY :c -- real dynamic dispatch, receiver's runtime class decides
  r5 = bc2cpp_send(M, self, 3, 0);
  L19:;
  r3 = mrb_nil_value();
  L21:;
  if (mrb_nil_p(r3)) goto L31;
  goto L35;
  L31:;
  r5 = mrb_fixnum_value(1);
  return r5;
  L35:;
  r5 = r3;
  // MONO_EMBED_GUARD :size2 -> Foo#size2 (embeds ivars; method_missing elsewhere could otherwise mistarget this), runtime-class-checked direct C++ call, by-name send fallback
  if (mrb_likely(bc2cpp_class_is(M, r5, bc2cpp_owner_class_0(M)))) {
    r5 = Foo_size2_impl(M, r5);
  } else {
    r5 = bc2cpp_nomethod(M, r5, 2); /* CLOSED_WORLD nomethod: recv.size2 @ /mnt/data/cache/claude-work/tmp/nix-shell.PNxmaD/declared-optional-param20261120-2882979-jpvyds/fixture.rb:32 */
  }
  return r5;
  mrb_raise(M, mrb_exc_get_id(M, bc2cpp_sym(M, 1)), "bc2cpp: Menu#later fell off the end of its body");
}

static mrb_value Menu_later(mrb_state* M, mrb_value self) {
  mrb_value a;
  mrb_value b = mrb_nil_value();
  mrb_value c = mrb_nil_value();
  bc2cpp_check_argc(M, 1, 3);
  mrb_get_args(M, "o|oo", &a, &b, &c);
  mrb_int bc2cpp_given_opt = mrb_get_argc(M) - 1;
  if (bc2cpp_given_opt < 0) bc2cpp_given_opt = 0;
  if (bc2cpp_given_opt > 2) bc2cpp_given_opt = 2;
  return bc2cpp_cfunc_result({M, M->gc.arena_idx, Menu_later_impl(M, self, a, b, c, bc2cpp_given_opt)});
}

mrb_value Menu_later_impl(mrb_state* M, mrb_value self, mrb_value a, mrb_value b, mrb_value c, mrb_int bc2cpp_given_opt) {
  if (mrb_unlikely(!(bc2cpp_class_is(M, a, bc2cpp_owner_class_0(M))))) bc2cpp_declared_param_violation(M, a, "Menu#later", 1, "Foo"); /* DECLARED_PARAM_GUARD Menu#later arg 1 */
  mrb_value bc2cpp_declared_ret = Menu_later_impl_unguarded(M, self, a, b, c, bc2cpp_given_opt);
  return bc2cpp_declared_ret;
}

mrb_value bc2cpp_xrow_Menu_later(mrb_state* M, mrb_value self) { return Menu_later(M, self); }

// Menu#loose (compiled from irep 13, 12 insns)
static inline mrb_value Menu_loose_impl_unguarded(mrb_state* M, mrb_value self, mrb_value a, mrb_value b, mrb_int bc2cpp_given_opt) {
  [[maybe_unused]] mrb_value r0 = self;
  mrb_value r2 = b;
  mrb_value r4 = mrb_nil_value();
  // 35 000 ENTER		1:1:0:0:0:0:0:0 (0x42000) (args already bound above)
  switch (bc2cpp_given_opt) {
    case 0: goto L10;
    default: goto L12;
  }
  L10:;
  r2 = mrb_nil_value();
  L12:;
  if (mrb_nil_p(r2)) goto L22;
  goto L26;
  L22:;
  r4 = mrb_fixnum_value(0);
  return r4;
  L26:;
  r4 = r2;
  // MONO_EMBED_GUARD :size2 -> Foo#size2 (embeds ivars; method_missing elsewhere could otherwise mistarget this), runtime-class-checked direct C++ call, by-name send fallback
  if (mrb_likely(bc2cpp_class_is(M, r4, bc2cpp_owner_class_0(M)))) {
    r4 = Foo_size2_impl(M, r4);
  } else {
    r4 = bc2cpp_nomethod(M, r4, 2); /* CLOSED_WORLD nomethod: recv.size2 @ /mnt/data/cache/claude-work/tmp/nix-shell.PNxmaD/declared-optional-param20261120-2882979-jpvyds/fixture.rb:38 */
  }
  return r4;
  mrb_raise(M, mrb_exc_get_id(M, bc2cpp_sym(M, 1)), "bc2cpp: Menu#loose fell off the end of its body");
}

static mrb_value Menu_loose(mrb_state* M, mrb_value self) {
  mrb_value a;
  mrb_value b = mrb_nil_value();
  bc2cpp_check_argc(M, 1, 2);
  mrb_get_args(M, "o|o", &a, &b);
  mrb_int bc2cpp_given_opt = mrb_get_argc(M) - 1;
  if (bc2cpp_given_opt < 0) bc2cpp_given_opt = 0;
  if (bc2cpp_given_opt > 1) bc2cpp_given_opt = 1;
  return bc2cpp_cfunc_result({M, M->gc.arena_idx, Menu_loose_impl(M, self, a, b, bc2cpp_given_opt)});
}

mrb_value Menu_loose_impl(mrb_state* M, mrb_value self, mrb_value a, mrb_value b, mrb_int bc2cpp_given_opt) {
  if (mrb_unlikely(!(bc2cpp_class_is(M, a, bc2cpp_owner_class_0(M))))) bc2cpp_declared_param_violation(M, a, "Menu#loose", 1, "Foo"); /* DECLARED_PARAM_GUARD Menu#loose arg 1 */
  mrb_value bc2cpp_declared_ret = Menu_loose_impl_unguarded(M, self, a, b, bc2cpp_given_opt);
  return bc2cpp_declared_ret;
}

mrb_value bc2cpp_xrow_Menu_loose(mrb_state* M, mrb_value self) { return Menu_loose(M, self); }

// Menu#sorted (compiled from irep 14, 13 insns)
static inline mrb_value Menu_sorted_impl_unguarded(mrb_state* M, mrb_value self, mrb_value a, mrb_value xs, mrb_int bc2cpp_given_opt) {
  [[maybe_unused]] mrb_value r0 = self;
  mrb_value r1 = a;
  mrb_value r2 = xs;
  mrb_value r4 = mrb_nil_value();
  mrb_value r5 = mrb_nil_value();
  // 41 000 ENTER		1:1:0:0:0:0:0:0 (0x42000) (args already bound above)
  switch (bc2cpp_given_opt) {
    case 0: goto L10;
    default: goto L13;
  }
  L10:;
  r2 = mrb_ary_new(M);
  L13:;
  r4 = r2;
  if (mrb_test(r4)) goto L23;
  r4 = mrb_ary_new(M);
  L23:;
  // OUTSIDE_OWNER_CALL :sort -- no guard chain; every class answering it is a named outside owner (ADR 0468)
  r4 = bc2cpp_owner_call(M, r4, BC2CPP_OWNERS(4, 2, "Array", "Enumerable"), mrb_nil_value(), 0, self); /* CLOSED_WORLD owner-call: sort */
// size -- generated from native registrations and C method bodies
{

if (mrb_array_p(r4) && mrb_obj_ptr(r4)->c == M->array_class) {
  r4 = mrb_int_value(M, ARY_LEN((mrb_ary_ptr(r4))));
} else
if (mrb_hash_p(r4) && mrb_obj_ptr(r4)->c == M->hash_class) {
  r4 = mrb_int_value(M, (mrb_hash_size(M, r4)));
} else {
  r4 = bc2cpp_owner_call(M, r4, BC2CPP_OWNERS(5, 2, "Array", "File", "File.singleton", "FileTest.singleton", "Hash", "Integer", "Range", "String", "StringIO", "Symbol"), mrb_nil_value(), 0, self); /* CLOSED_WORLD owner-call: size */
}
}
  r5 = r1;
  // MONO_EXACT_FLOW :size2 -> Foo#size2 (receiver proven exactly Foo), direct C++ call with no class guard
  r5 = Foo_size2_impl(M, r5);
{ mrb_value bc2cpp_nt;
  if (mrb_likely(BC2CPP_FIXNUM_PAIR_P(r4, r5))) {
  if (mrb_unlikely(bc2cpp_fixnum_add(r4, r5, r4))) { r4 = mrb_num_add(M, r4, r5); }
} else if (mrb_integer_p(r4) && mrb_integer_p(r5)) {
  r4 = mrb_num_add(M, r4, r5);
} else if (!mrb_undef_p(bc2cpp_nt = bc2cpp_num_add_float(M, r4, r5))) {
  r4 = bc2cpp_nt;
} else {
    // FIXNUM_ARITHMETIC :+ -- NUMERIC_SLOW_PATH (ADR 0292): mruby's own Integer/Float body, by-name call only inside the helper
  r4 = bc2cpp_slow_add_f(M, r4, r5);

}

}
  return r4;
  mrb_raise(M, mrb_exc_get_id(M, bc2cpp_sym(M, 1)), "bc2cpp: Menu#sorted fell off the end of its body");
}

static mrb_value Menu_sorted(mrb_state* M, mrb_value self) {
  mrb_value a;
  mrb_value xs = mrb_nil_value();
  bc2cpp_check_argc(M, 1, 2);
  mrb_get_args(M, "o|o", &a, &xs);
  mrb_int bc2cpp_given_opt = mrb_get_argc(M) - 1;
  if (bc2cpp_given_opt < 0) bc2cpp_given_opt = 0;
  if (bc2cpp_given_opt > 1) bc2cpp_given_opt = 1;
  return bc2cpp_cfunc_result({M, M->gc.arena_idx, Menu_sorted_impl(M, self, a, xs, bc2cpp_given_opt)});
}

mrb_value Menu_sorted_impl(mrb_state* M, mrb_value self, mrb_value a, mrb_value xs, mrb_int bc2cpp_given_opt) {
  if (mrb_unlikely(!(bc2cpp_class_is(M, a, bc2cpp_owner_class_0(M))))) bc2cpp_declared_param_violation(M, a, "Menu#sorted", 1, "Foo"); /* DECLARED_PARAM_GUARD Menu#sorted arg 1 */
  if (mrb_unlikely(!(bc2cpp_given_opt <= 0 || (mrb_nil_p(xs) || (mrb_array_p(xs)))))) bc2cpp_declared_param_violation(M, xs, "Menu#sorted", 2, "Array[Integer]?"); /* DECLARED_PARAM_GUARD Menu#sorted arg 2 */
  mrb_value bc2cpp_declared_ret = Menu_sorted_impl_unguarded(M, self, a, xs, bc2cpp_given_opt);
  if (mrb_unlikely(!(mrb_fixnum_p(bc2cpp_declared_ret)))) bc2cpp_declared_return_violation(M, bc2cpp_declared_ret, "Menu#sorted", "Integer"); /* DECLARED_RETURN_GUARD Menu#sorted -> Integer */
  return bc2cpp_declared_ret;
}

mrb_value bc2cpp_xrow_Menu_sorted(mrb_state* M, mrb_value self) { return Menu_sorted(M, self); }

// Menu#keys_of (compiled from irep 15, 5 insns)
static inline mrb_value Menu_keys_of_impl_unguarded(mrb_state* M, mrb_value self, mrb_value h) {
  [[maybe_unused]] mrb_value r0 = self;
  mrb_value r1 = h;
  mrb_value r3 = mrb_nil_value();
  // 45 000 ENTER		1:0:0:0:0:0:0:0 (0x40000) (args already bound above)
  r3 = r1;
// CLOSED_WORLD_NATIVE_EXACT :keys -> Hash registered body; exact receiver (unguarded proof), no dispatch fallback
  r3 = mrb_hash_keys(M, r3);
// CLOSED_WORLD_NATIVE_EXACT :size -> Array registered body; exact receiver (unguarded proof), no dispatch fallback
  r3 = mrb_int_value(M, ARY_LEN((mrb_ary_ptr(r3))));
  return r3;
  mrb_raise(M, mrb_exc_get_id(M, bc2cpp_sym(M, 1)), "bc2cpp: Menu#keys_of fell off the end of its body");
}

static mrb_value Menu_keys_of(mrb_state* M, mrb_value self) {
  mrb_value h;
  mrb_get_args(M, "o", &h);
  return bc2cpp_cfunc_result({M, M->gc.arena_idx, Menu_keys_of_impl(M, self, h)});
}

mrb_value Menu_keys_of_impl(mrb_state* M, mrb_value self, mrb_value h) {
  if (mrb_unlikely(!(mrb_hash_p(h)))) bc2cpp_declared_param_violation(M, h, "Menu#keys_of", 1, "Hash[Symbol, Integer]"); /* DECLARED_PARAM_GUARD Menu#keys_of arg 1 */
  mrb_value bc2cpp_declared_ret = Menu_keys_of_impl_unguarded(M, self, h);
  if (mrb_unlikely(!(mrb_fixnum_p(bc2cpp_declared_ret)))) bc2cpp_declared_return_violation(M, bc2cpp_declared_ret, "Menu#keys_of", "Integer"); /* DECLARED_RETURN_GUARD Menu#keys_of -> Integer */
  return bc2cpp_declared_ret;
}

mrb_value bc2cpp_xrow_Menu_keys_of(mrb_state* M, mrb_value self) { return Menu_keys_of(M, self); }

// Menu#shout (compiled from irep 16, 4 insns)
static inline mrb_value Menu_shout_impl_unguarded(mrb_state* M, mrb_value self, mrb_value s) {
  [[maybe_unused]] mrb_value r0 = self;
  mrb_value r1 = s;
  mrb_value r3 = mrb_nil_value();
  // 49 000 ENTER		1:0:0:0:0:0:0:0 (0x40000) (args already bound above)
  r3 = r1;
  // OUTSIDE_OWNER_CALL :upcase -- no guard chain; every class answering it is a named outside owner (ADR 0468)
  r3 = bc2cpp_owner_call(M, r3, BC2CPP_OWNERS(6, 2, "String"), mrb_nil_value(), 0, self); /* CLOSED_WORLD owner-call: upcase */
  return r3;
  mrb_raise(M, mrb_exc_get_id(M, bc2cpp_sym(M, 1)), "bc2cpp: Menu#shout fell off the end of its body");
}

static mrb_value Menu_shout(mrb_state* M, mrb_value self) {
  mrb_value s;
  mrb_get_args(M, "o", &s);
  return bc2cpp_cfunc_result({M, M->gc.arena_idx, Menu_shout_impl(M, self, s)});
}

mrb_value Menu_shout_impl(mrb_state* M, mrb_value self, mrb_value s) {
  if (mrb_unlikely(!(mrb_string_p(s)))) bc2cpp_declared_param_violation(M, s, "Menu#shout", 1, "String"); /* DECLARED_PARAM_GUARD Menu#shout arg 1 */
  mrb_value bc2cpp_declared_ret = Menu_shout_impl_unguarded(M, self, s);
  return bc2cpp_declared_ret;
}

mrb_value bc2cpp_xrow_Menu_shout(mrb_state* M, mrb_value self) { return Menu_shout(M, self); }

// Menu#run (compiled from irep 17, 55 insns)
mrb_value Menu_run_impl(mrb_state* M, mrb_value self) {
  [[maybe_unused]] mrb_value r0 = self;
  mrb_value r2 = mrb_nil_value();
  mrb_value r3 = mrb_nil_value();
  mrb_value r4 = mrb_nil_value();
  mrb_value r5 = mrb_nil_value();
  mrb_value r6 = mrb_nil_value();
  mrb_value r7 = mrb_nil_value();
  // 53 000 ENTER		0:0:0:0:0:0:0:0 (0x0) (args already bound above)
  r3 = bc2cpp_cconst_0(M);
  // INITIALIZER_SITE 17:2
  // MONO :new -> Foo, direct compiled construct (bc2cpp_direct_alloc + Foo_initialize_impl) -- skips Class#new's own allocate+initialize dispatch chain entirely; Foo#initialize's own return value is discarded (real Ruby .new always returns the new object, never whatever #initialize itself returns).
  // Foo#initialize declares arity [0, 0] and this call passes 0.  // CLOSED_WORLD_STABLE_CLASS: the class constant and constructor lookup cannot be reassigned or intercepted, so the class identity guard is omitted.
  // INITIALIZER_DIRECT 17:2 Foo
  r3 = bc2cpp_direct_alloc(M, bc2cpp_owner_class_0(M));
  Foo_initialize_impl(M, r3);
  r2 = r3;
  r4 = r2;
  // MONO :pick -> Menu#pick, direct C++ call (no by-name send)
  r3 = Menu_pick_impl(M, self, r4, mrb_nil_value(), 0);
  r5 = r2;
  r6 = r2;
  // MONO :pick -> Menu#pick, direct C++ call (no by-name send)
  r4 = Menu_pick_impl(M, self, r5, r6, 1);
  // operands proven Fixnum -- no runtime check, no by-name send fallback
  if (mrb_unlikely(bc2cpp_fixnum_add(r3, r4, r3))) { r3 = mrb_num_add(M, r3, r4); }
  r5 = r2;
  // MONO :add -> Menu#add, direct C++ call (no by-name send)
  r4 = Menu_add_impl(M, self, r5, mrb_nil_value(), 0);
{ mrb_value bc2cpp_nt;
  if (mrb_likely(BC2CPP_FIXNUM_PAIR_P(r3, r4))) {
  if (mrb_unlikely(bc2cpp_fixnum_add(r3, r4, r3))) { r3 = mrb_num_add(M, r3, r4); }
} else if (mrb_integer_p(r3) && mrb_integer_p(r4)) {
  r3 = mrb_num_add(M, r3, r4);
} else if (!mrb_undef_p(bc2cpp_nt = bc2cpp_num_add_float(M, r3, r4))) {
  r3 = bc2cpp_nt;
} else {
    // NUMERIC_OPERAND_PROOF :+ -- both operands proven Integer/Float; core body, no dynamic send
  r3 = mrb_num_add(M, r3, r4);

}

}
  r5 = r2;
  r6 = mrb_fixnum_value(5);
  // MONO :add -> Menu#add, direct C++ call (no by-name send)
  r4 = Menu_add_impl(M, self, r5, r6, 1);
{ mrb_value bc2cpp_nt;
  if (mrb_likely(BC2CPP_FIXNUM_PAIR_P(r3, r4))) {
  if (mrb_unlikely(bc2cpp_fixnum_add(r3, r4, r3))) { r3 = mrb_num_add(M, r3, r4); }
} else if (mrb_integer_p(r3) && mrb_integer_p(r4)) {
  r3 = mrb_num_add(M, r3, r4);
} else if (!mrb_undef_p(bc2cpp_nt = bc2cpp_num_add_float(M, r3, r4))) {
  r3 = bc2cpp_nt;
} else {
    // NUMERIC_OPERAND_PROOF :+ -- both operands proven Integer/Float; core body, no dynamic send
  r3 = mrb_num_add(M, r3, r4);

}

}
  r5 = r2;
  // MONO :computed -> Menu#computed, direct C++ call (no by-name send)
  r4 = Menu_computed_impl(M, self, r5, mrb_nil_value(), 0);
{ mrb_value bc2cpp_nt;
  if (mrb_likely(BC2CPP_FIXNUM_PAIR_P(r3, r4))) {
  if (mrb_unlikely(bc2cpp_fixnum_add(r3, r4, r3))) { r3 = mrb_num_add(M, r3, r4); }
} else if (mrb_integer_p(r3) && mrb_integer_p(r4)) {
  r3 = mrb_num_add(M, r3, r4);
} else if (!mrb_undef_p(bc2cpp_nt = bc2cpp_num_add_float(M, r3, r4))) {
  r3 = bc2cpp_nt;
} else {
    // NUMERIC_OPERAND_PROOF :+ -- both operands proven Integer/Float; core body, no dynamic send
  r3 = mrb_num_add(M, r3, r4);

}

}
  r5 = r2;
  // MONO :later -> Menu#later, direct C++ call (no by-name send)
  r4 = Menu_later_impl(M, self, r5, mrb_nil_value(), mrb_nil_value(), 0);
{ mrb_value bc2cpp_nt;
  if (mrb_likely(BC2CPP_FIXNUM_PAIR_P(r3, r4))) {
  if (mrb_unlikely(bc2cpp_fixnum_add(r3, r4, r3))) { r3 = mrb_num_add(M, r3, r4); }
} else if (mrb_integer_p(r3) && mrb_integer_p(r4)) {
  r3 = mrb_num_add(M, r3, r4);
} else if (!mrb_undef_p(bc2cpp_nt = bc2cpp_num_add_float(M, r3, r4))) {
  r3 = bc2cpp_nt;
} else {
    // NUMERIC_OPERAND_PROOF :+ -- both operands proven Integer/Float; core body, no dynamic send
  r3 = mrb_num_add(M, r3, r4);

}

}
  r5 = r2;
  r6 = mrb_fixnum_value(1);
  r7 = r2;
  // MONO :later -> Menu#later, direct C++ call (no by-name send)
  r4 = Menu_later_impl(M, self, r5, r6, r7, 2);
{ mrb_value bc2cpp_nt;
  if (mrb_likely(BC2CPP_FIXNUM_PAIR_P(r3, r4))) {
  if (mrb_unlikely(bc2cpp_fixnum_add(r3, r4, r3))) { r3 = mrb_num_add(M, r3, r4); }
} else if (mrb_integer_p(r3) && mrb_integer_p(r4)) {
  r3 = mrb_num_add(M, r3, r4);
} else if (!mrb_undef_p(bc2cpp_nt = bc2cpp_num_add_float(M, r3, r4))) {
  r3 = bc2cpp_nt;
} else {
    // NUMERIC_OPERAND_PROOF :+ -- both operands proven Integer/Float; core body, no dynamic send
  r3 = mrb_num_add(M, r3, r4);

}

}
  r5 = r2;
  r6 = r2;
  // MONO :loose -> Menu#loose, direct C++ call (no by-name send)
  r4 = Menu_loose_impl(M, self, r5, r6, 1);
{ mrb_value bc2cpp_nt;
  if (mrb_likely(BC2CPP_FIXNUM_PAIR_P(r3, r4))) {
  if (mrb_unlikely(bc2cpp_fixnum_add(r3, r4, r3))) { r3 = mrb_num_add(M, r3, r4); }
} else if (mrb_integer_p(r3) && mrb_integer_p(r4)) {
  r3 = mrb_num_add(M, r3, r4);
} else if (!mrb_undef_p(bc2cpp_nt = bc2cpp_num_add_float(M, r3, r4))) {
  r3 = bc2cpp_nt;
} else {
    // NUMERIC_OPERAND_PROOF :+ -- both operands proven Integer/Float; core body, no dynamic send
  r3 = mrb_num_add(M, r3, r4);

}

}
  r5 = r2;
  // MONO :sorted -> Menu#sorted, direct C++ call (no by-name send)
  r4 = Menu_sorted_impl(M, self, r5, mrb_nil_value(), 0);
{ mrb_value bc2cpp_nt;
  if (mrb_likely(BC2CPP_FIXNUM_PAIR_P(r3, r4))) {
  if (mrb_unlikely(bc2cpp_fixnum_add(r3, r4, r3))) { r3 = mrb_num_add(M, r3, r4); }
} else if (mrb_integer_p(r3) && mrb_integer_p(r4)) {
  r3 = mrb_num_add(M, r3, r4);
} else if (!mrb_undef_p(bc2cpp_nt = bc2cpp_num_add_float(M, r3, r4))) {
  r3 = bc2cpp_nt;
} else {
    // NUMERIC_OPERAND_PROOF :+ -- both operands proven Integer/Float; core body, no dynamic send
  r3 = mrb_num_add(M, r3, r4);

}

}
  r5 = r2;
  r6 = mrb_fixnum_value(3);
  r7 = mrb_fixnum_value(1);
  {
    mrb_value elems[] = { r6, r7 };
    r6 = mrb_ary_new_from_values(M, 2, elems);
  }
  // MONO :sorted -> Menu#sorted, direct C++ call (no by-name send)
  r4 = Menu_sorted_impl(M, self, r5, r6, 1);
{ mrb_value bc2cpp_nt;
  if (mrb_likely(BC2CPP_FIXNUM_PAIR_P(r3, r4))) {
  if (mrb_unlikely(bc2cpp_fixnum_add(r3, r4, r3))) { r3 = mrb_num_add(M, r3, r4); }
} else if (mrb_integer_p(r3) && mrb_integer_p(r4)) {
  r3 = mrb_num_add(M, r3, r4);
} else if (!mrb_undef_p(bc2cpp_nt = bc2cpp_num_add_float(M, r3, r4))) {
  r3 = bc2cpp_nt;
} else {
    // NUMERIC_OPERAND_PROOF :+ -- both operands proven Integer/Float; core body, no dynamic send
  r3 = mrb_num_add(M, r3, r4);

}

}
  r5 = r2;
  r6 = mrb_nil_value();
  // MONO :sorted -> Menu#sorted, direct C++ call (no by-name send)
  r4 = Menu_sorted_impl(M, self, r5, r6, 1);
{ mrb_value bc2cpp_nt;
  if (mrb_likely(BC2CPP_FIXNUM_PAIR_P(r3, r4))) {
  if (mrb_unlikely(bc2cpp_fixnum_add(r3, r4, r3))) { r3 = mrb_num_add(M, r3, r4); }
} else if (mrb_integer_p(r3) && mrb_integer_p(r4)) {
  r3 = mrb_num_add(M, r3, r4);
} else if (!mrb_undef_p(bc2cpp_nt = bc2cpp_num_add_float(M, r3, r4))) {
  r3 = bc2cpp_nt;
} else {
    // NUMERIC_OPERAND_PROOF :+ -- both operands proven Integer/Float; core body, no dynamic send
  r3 = mrb_num_add(M, r3, r4);

}

}
  r5 = mrb_symbol_value(bc2cpp_sym(M, 7));
  r6 = mrb_fixnum_value(1);
  {
    mrb_value h = mrb_hash_new_capa(M, 1);
    mrb_hash_set(M, h, r5, r6);
    r5 = h;
  }
  // MONO :keys_of -> Menu#keys_of, direct C++ call (no by-name send)
  r4 = Menu_keys_of_impl(M, self, r5);
{ mrb_value bc2cpp_nt;
  if (mrb_likely(BC2CPP_FIXNUM_PAIR_P(r3, r4))) {
  if (mrb_unlikely(bc2cpp_fixnum_add(r3, r4, r3))) { r3 = mrb_num_add(M, r3, r4); }
} else if (mrb_integer_p(r3) && mrb_integer_p(r4)) {
  r3 = mrb_num_add(M, r3, r4);
} else if (!mrb_undef_p(bc2cpp_nt = bc2cpp_num_add_float(M, r3, r4))) {
  r3 = bc2cpp_nt;
} else {
    // NUMERIC_OPERAND_PROOF :+ -- both operands proven Integer/Float; core body, no dynamic send
  r3 = mrb_num_add(M, r3, r4);

}

}
  r5 = bc2cpp_pool_str(M, "\x61");
  // MONO :shout -> Menu#shout, direct C++ call (no by-name send)
  r4 = Menu_shout_impl(M, self, r5);
// size -- generated from native registrations and C method bodies
{

if (mrb_array_p(r4) && mrb_obj_ptr(r4)->c == M->array_class) {
  r4 = mrb_int_value(M, ARY_LEN((mrb_ary_ptr(r4))));
} else
if (mrb_hash_p(r4) && mrb_obj_ptr(r4)->c == M->hash_class) {
  r4 = mrb_int_value(M, (mrb_hash_size(M, r4)));
} else {
  r4 = bc2cpp_owner_call(M, r4, BC2CPP_OWNERS(5, 2, "Array", "File", "File.singleton", "FileTest.singleton", "Hash", "Integer", "Range", "String", "StringIO", "Symbol"), mrb_nil_value(), 0, self); /* CLOSED_WORLD owner-call: size */
}
}
{ mrb_value bc2cpp_nt;
  if (mrb_likely(BC2CPP_FIXNUM_PAIR_P(r3, r4))) {
  if (mrb_unlikely(bc2cpp_fixnum_add(r3, r4, r3))) { r3 = mrb_num_add(M, r3, r4); }
} else if (mrb_integer_p(r3) && mrb_integer_p(r4)) {
  r3 = mrb_num_add(M, r3, r4);
} else if (!mrb_undef_p(bc2cpp_nt = bc2cpp_num_add_float(M, r3, r4))) {
  r3 = bc2cpp_nt;
} else {
    // FIXNUM_ARITHMETIC :+ -- NUMERIC_SLOW_PATH (ADR 0292): mruby's own Integer/Float body, by-name call only inside the helper
  r3 = bc2cpp_slow_add_f(M, r3, r4);

}

}
  return r3;
  mrb_raise(M, mrb_exc_get_id(M, bc2cpp_sym(M, 1)), "bc2cpp: Menu#run fell off the end of its body");
}

static mrb_value Menu_run(mrb_state* M, mrb_value self) {
  return bc2cpp_cfunc_result({M, M->gc.arena_idx, Menu_run_impl(M, self)});
}

mrb_value bc2cpp_xrow_Menu_run(mrb_state* M, mrb_value self) { return Menu_run(M, self); }

// Menu#wrong_sorted (compiled from irep 18, 6 insns)
mrb_value Menu_wrong_sorted_impl(mrb_state* M, mrb_value self) {
  [[maybe_unused]] mrb_value r0 = self;
  mrb_value r2 = mrb_nil_value();
  mrb_value r3 = mrb_nil_value();
  mrb_value r4 = mrb_nil_value();
  // 59 000 ENTER		0:0:0:0:0:0:0:0 (0x0) (args already bound above)
  r3 = bc2cpp_cconst_0(M);
  // INITIALIZER_SITE 18:2
  // MONO :new -> Foo, direct compiled construct (bc2cpp_direct_alloc + Foo_initialize_impl) -- skips Class#new's own allocate+initialize dispatch chain entirely; Foo#initialize's own return value is discarded (real Ruby .new always returns the new object, never whatever #initialize itself returns).
  // Foo#initialize declares arity [0, 0] and this call passes 0.  // CLOSED_WORLD_STABLE_CLASS: the class constant and constructor lookup cannot be reassigned or intercepted, so the class identity guard is omitted.
  // INITIALIZER_DIRECT 18:2 Foo
  r3 = bc2cpp_direct_alloc(M, bc2cpp_owner_class_0(M));
  Foo_initialize_impl(M, r3);
  r4 = bc2cpp_pool_str(M, "\x7a");
  // MONO :sorted -> Menu#sorted, direct C++ call (no by-name send)
  r2 = Menu_sorted_impl(M, self, r3, r4, 1);
  return r2;
  mrb_raise(M, mrb_exc_get_id(M, bc2cpp_sym(M, 1)), "bc2cpp: Menu#wrong_sorted fell off the end of its body");
}

static mrb_value Menu_wrong_sorted(mrb_state* M, mrb_value self) {
  return bc2cpp_cfunc_result({M, M->gc.arena_idx, Menu_wrong_sorted_impl(M, self)});
}

mrb_value bc2cpp_xrow_Menu_wrong_sorted(mrb_state* M, mrb_value self) { return Menu_wrong_sorted(M, self); }

// Menu#wrong (compiled from irep 19, 6 insns)
mrb_value Menu_wrong_impl(mrb_state* M, mrb_value self) {
  [[maybe_unused]] mrb_value r0 = self;
  mrb_value r2 = mrb_nil_value();
  mrb_value r3 = mrb_nil_value();
  mrb_value r4 = mrb_nil_value();
  // 63 000 ENTER		0:0:0:0:0:0:0:0 (0x0) (args already bound above)
  r3 = bc2cpp_cconst_0(M);
  // INITIALIZER_SITE 19:2
  // MONO :new -> Foo, direct compiled construct (bc2cpp_direct_alloc + Foo_initialize_impl) -- skips Class#new's own allocate+initialize dispatch chain entirely; Foo#initialize's own return value is discarded (real Ruby .new always returns the new object, never whatever #initialize itself returns).
  // Foo#initialize declares arity [0, 0] and this call passes 0.  // CLOSED_WORLD_STABLE_CLASS: the class constant and constructor lookup cannot be reassigned or intercepted, so the class identity guard is omitted.
  // INITIALIZER_DIRECT 19:2 Foo
  r3 = bc2cpp_direct_alloc(M, bc2cpp_owner_class_0(M));
  Foo_initialize_impl(M, r3);
  r4 = bc2cpp_pool_str(M, "\x78");
  // MONO :pick -> Menu#pick, direct C++ call (no by-name send)
  r2 = Menu_pick_impl(M, self, r3, r4, 1);
  return r2;
  mrb_raise(M, mrb_exc_get_id(M, bc2cpp_sym(M, 1)), "bc2cpp: Menu#wrong fell off the end of its body");
}

static mrb_value Menu_wrong(mrb_state* M, mrb_value self) {
  return bc2cpp_cfunc_result({M, M->gc.arena_idx, Menu_wrong_impl(M, self)});
}

mrb_value bc2cpp_xrow_Menu_wrong(mrb_state* M, mrb_value self) { return Menu_wrong(M, self); }

// Menu#wrong_add (compiled from irep 20, 6 insns)
mrb_value Menu_wrong_add_impl(mrb_state* M, mrb_value self) {
  [[maybe_unused]] mrb_value r0 = self;
  mrb_value r2 = mrb_nil_value();
  mrb_value r3 = mrb_nil_value();
  mrb_value r4 = mrb_nil_value();
  // 67 000 ENTER		0:0:0:0:0:0:0:0 (0x0) (args already bound above)
  r3 = bc2cpp_cconst_0(M);
  // INITIALIZER_SITE 20:2
  // MONO :new -> Foo, direct compiled construct (bc2cpp_direct_alloc + Foo_initialize_impl) -- skips Class#new's own allocate+initialize dispatch chain entirely; Foo#initialize's own return value is discarded (real Ruby .new always returns the new object, never whatever #initialize itself returns).
  // Foo#initialize declares arity [0, 0] and this call passes 0.  // CLOSED_WORLD_STABLE_CLASS: the class constant and constructor lookup cannot be reassigned or intercepted, so the class identity guard is omitted.
  // INITIALIZER_DIRECT 20:2 Foo
  r3 = bc2cpp_direct_alloc(M, bc2cpp_owner_class_0(M));
  Foo_initialize_impl(M, r3);
  r4 = bc2cpp_pool_str(M, "\x79");
  // MONO :add -> Menu#add, direct C++ call (no by-name send)
  r2 = Menu_add_impl(M, self, r3, r4, 1);
  return r2;
  mrb_raise(M, mrb_exc_get_id(M, bc2cpp_sym(M, 1)), "bc2cpp: Menu#wrong_add fell off the end of its body");
}

static mrb_value Menu_wrong_add(mrb_state* M, mrb_value self) {
  return bc2cpp_cfunc_result({M, M->gc.arena_idx, Menu_wrong_add_impl(M, self)});
}

mrb_value bc2cpp_xrow_Menu_wrong_add(mrb_state* M, mrb_value self) { return Menu_wrong_add(M, self); }

[[maybe_unused]] static void bc2cpp_gem_init(mrb_state* M) {
  bc2cpp_reset_const_site_cache();
  bc2cpp_reset_owner_classes();
  bc2cpp_top_unit_Foo_0(M);
  bc2cpp_top_unit_Menu_0(M);
  bc2cpp_set_instance_tts(M);
  bc2cpp_register_owner_methods(M);
  bc2cpp_capture_direct_construct_classes(M);
  bc2cpp_frame_free_install(M);
}
[[maybe_unused]] static void bc2cpp_gem_final() {
  bc2cpp_reset_symbol_cache();
  bc2cpp_reset_const_site_cache();
  bc2cpp_reset_owner_classes();
  bc2cpp_reset_direct_construct_classes();
}
