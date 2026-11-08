// The closed build's call-frame machinery without the bytecode VM
// (docs/bc2cpp-vm-free-runtime-plan.md, Phase 5). Replaces mruby's vm.c in a
// closed libmruby.a (tools/bc2cpp/native_vm_build.rb). Frames, funcall
// and yield are vm.c's code for native callees; every path that would start an
// irep proc raises instead.
// The entries nothing links to (mrb_vm_exec, mrb_vm_run, mrb_top_run, ...) are
// not defined.
#define __STDC_CONSTANT_MACROS
#define __STDC_LIMIT_MACROS

#ifndef MRB_USE_CXX_ABI
extern "C" {
#endif
// clang-format off: internal.h needs proc.h and class.h first.
#include <mruby.h>
#include <mruby/array.h>
#include <mruby/class.h>
#include <mruby/hash.h>
#include <mruby/irep.h>
#include <mruby/proc.h>
#include <mruby/string.h>
#include <mruby/variable.h>
#include <mruby/error.h>
#include <mruby/throw.h>
#include <mruby/internal.h>
// clang-format on

#define STACK_INIT_SIZE 128
#define CALLINFO_INIT_SIZE 32
#define MRB_STACK_GROWTH 128
// vm.c's limits, so a call-depth error is raised at the same depth.
#ifdef __clang__
#if __has_feature(address_sanitizer) && !defined(__SANITIZE_ADDRESS__)
#define __SANITIZE_ADDRESS__
#endif
#endif
#ifdef __SANITIZE_ADDRESS__
#define MRB_CALL_LEVEL_MAX 128
#else
#define MRB_CALL_LEVEL_MAX 512
#endif
#define MRB_STACK_MAX (0x40000 - MRB_STACK_GROWTH)
#define CALL_MAXARGS 15
#define MRB_FUNCALL_ARGC_MAX 16

#define CINFO_NONE 0
#define CINFO_SKIP 1
#define CINFO_DIRECT 2
#define CINFO_RESUMED 3

mrb_value mrb_obj_missing(mrb_state* mrb, mrb_value mod);

// Why: an irep proc reaching a frame is a closed-world violation; host_sweep
// greps this message.
[[noreturn]] static void no_irep(mrb_state* mrb) {
  mrb_raise(mrb, E_RUNTIME_ERROR,
            "bytecode interpreter is not built in (frames-only runtime)");
}

// Why: send and instance_eval/module_eval ran in the VM's own frame when called
// from bytecode; no bytecode runs here, so a native frame without CINFO_DIRECT
// means a caller this runtime does not cover.
[[noreturn]] static void no_frame(mrb_state* mrb) {
  mrb_raise(mrb, E_RUNTIME_ERROR,
            "bytecode interpreter is not built in (frames-only runtime: no "
            "native frame)");
}

static inline void stack_clear(mrb_value* from, size_t count) {
  while (count-- > 0) {
    SET_NIL_VALUE(*from);
    from++;
  }
}

static inline void stack_copy(mrb_value* dst,
                              const mrb_value* src,
                              size_t size) {
  if (!src)
    return;
  memcpy(dst, src, sizeof(mrb_value) * size);
}

static void stack_init(mrb_state* mrb) {
  struct mrb_context* c = mrb->c;

  c->stbase = (mrb_value*)mrb_malloc(mrb, STACK_INIT_SIZE * sizeof(mrb_value));
  c->stend = c->stbase + STACK_INIT_SIZE;
  stack_clear(c->stbase, STACK_INIT_SIZE);

  static const mrb_callinfo ci_zero = {};
  c->cibase =
      (mrb_callinfo*)mrb_malloc(mrb, CALLINFO_INIT_SIZE * sizeof(mrb_callinfo));
  c->ciend = c->cibase + CALLINFO_INIT_SIZE;
  c->cibase[0] = ci_zero;
  c->ci = c->cibase;
  c->ci->u.target_class = mrb->object_class;
  c->ci->stack = c->stbase;
  c->ci->vis = 1; /* private (2-bit packed) */
}

static inline void envadjust(mrb_state* mrb,
                             mrb_value* oldbase,
                             mrb_value* newbase) {
  mrb_callinfo* ci = mrb->c->cibase;
  ptrdiff_t off = (char*)newbase - (char*)oldbase;

  if (off == 0)
    return;
  while (ci <= mrb->c->ci) {
    struct REnv* e = mrb_vm_ci_env(ci);

    mrb_value* new_stack = (mrb_value*)((char*)ci->stack + off);

    if (e) {
      e->stack = new_stack;
    }
    ci->stack = new_stack;
    ci++;
  }
}

static void stack_extend_alloc(mrb_state* mrb, mrb_int room) {
  mrb_value* oldbase = mrb->c->stbase;
  size_t oldsize = mrb->c->stend - mrb->c->stbase;
  size_t size = oldsize;
  size_t off = mrb->c->ci->stack ? mrb->c->stend - mrb->c->ci->stack : 0;

  if (off > size)
    size = off;
  {
    size_t newsize = size + (size >> 1); /* 1.5x growth */
    if (newsize < size + MRB_STACK_GROWTH)
      newsize = size + MRB_STACK_GROWTH;
    if (newsize < size + (size_t)room)
      newsize = size + room;
    size = newsize;
  }

  mrb_value* newstack =
      (mrb_value*)mrb_realloc(mrb, mrb->c->stbase, sizeof(mrb_value) * size);
  stack_clear(&(newstack[oldsize]), size - oldsize);
  envadjust(mrb, oldbase, newstack);
  mrb->c->stbase = newstack;
  mrb->c->stend = mrb->c->stbase + size;

  if (size > MRB_STACK_MAX) {
    mrb_exc_raise(mrb, mrb_obj_value(mrb->stack_err));
  }
}

static inline void stack_extend(mrb_state* mrb, mrb_int room) {
  if (mrb_unlikely(!mrb->c->ci->stack ||
                   mrb->c->ci->stack + room >= mrb->c->stend)) {
    stack_extend_alloc(mrb, room);
  }
}

static void stack_extend_adjust(mrb_state* mrb,
                                mrb_int room,
                                const mrb_value** argp) {
  const struct mrb_context* c = mrb->c;
  ptrdiff_t voff = *argp - c->stbase;

  if (voff < 0 || voff >= c->stend - c->stbase) {
    stack_extend(mrb, room);
  } else {
    stack_extend(mrb, room);
    *argp = c->stbase + voff;
  }
}

// Frames here never run bytecode, so a frame's pc is always NULL.
static inline void ci_proc_set(mrb_callinfo* ci, const struct RProc* p) {
  ci->proc = p;
  ci->pc = NULL;
}

#define CI_TARGET_CLASS(ci)                                        \
  (((ci)->u.env && (ci)->u.env->tt == MRB_TT_ENV) ? (ci)->u.env->c \
                                                  : (ci)->u.target_class)

struct RClass* mrb_vm_ci_target_class(const mrb_callinfo* ci) {
  return CI_TARGET_CLASS(ci);
}

#define CI_ENV(ci) \
  (((ci)->u.env && (ci)->u.env->tt == MRB_TT_ENV) ? (ci)->u.env : NULL)

struct REnv* mrb_vm_ci_env(const mrb_callinfo* ci) {
  return CI_ENV(ci);
}

static inline void ci_env_set(mrb_callinfo* ci, struct REnv* e) {
  if (ci->u.env) {
    if (ci->u.env->tt == MRB_TT_ENV) {
      if (e) {
        e->c = ci->u.env->c;
        ci->u.env = e;
      } else {
        ci->u.target_class = ci->u.env->c;
      }
    } else if (e) {
      e->c = ci->u.target_class;
      ci->u.env = e;
    }
  } else {
    ci->u.env = e;
  }
}

mrb_bool mrb_env_unshare(mrb_state* mrb, struct REnv* e, mrb_bool noraise);

MRB_API void mrb_vm_ci_env_clear(mrb_state* mrb, mrb_callinfo* ci) {
  if (!ci)
    return;
  struct REnv* e = ci->u.env;
  if (e && e->tt == MRB_TT_ENV) {
    ci->u.target_class = e->c;
    mrb_env_unshare(mrb, e, FALSE);
  }
}

#define BLK_PTR(b) ((mrb_proc_p(b)) ? mrb_proc_ptr(b) : NULL)

static inline mrb_callinfo* cipush(mrb_state* mrb,
                                   mrb_int push_stacks,
                                   uint8_t cci,
                                   struct RClass* target_class,
                                   const struct RProc* proc,
                                   struct RProc* blk,
                                   mrb_sym mid,
                                   uint16_t argc) {
  struct mrb_context* c = mrb->c;
  mrb_callinfo* ci = c->ci + 1;

  if (ci < c->ciend) {
    c->ci = ci;
  } else {
    ptrdiff_t size = ci - c->cibase;

    if (size >= MRB_CALL_LEVEL_MAX) {
      mrb_exc_raise(mrb, mrb_obj_value(mrb->stack_err));
    }
    c->cibase = (mrb_callinfo*)mrb_realloc(mrb, c->cibase,
                                           sizeof(mrb_callinfo) * size * 2);
    c->ci = ci = c->cibase + size;
    c->ciend = c->cibase + size * 2;
  }
  ci->mid = mid;
  ci_proc_set(ci, proc);
  ci->blk = blk;
  ci->stack = ci[-1].stack + push_stacks;
  ci->n = argc & 0xf;
  ci->nk = (argc >> 4) & 0xf;
  ci->cci = cci;
  ci->vis = MRB_METHOD_PUBLIC_FL;
  ci->u.target_class = target_class;

  return ci;
}

mrb_bool mrb_env_unshare(mrb_state* mrb, struct REnv* e, mrb_bool noraise) {
  size_t len = (size_t)MRB_ENV_LEN(e);
  if (len == 0) {
    e->stack = NULL;
    MRB_ENV_CLOSE(e);
    return TRUE;
  }

  size_t live = mrb->gc.live;
  mrb_value* p = (mrb_value*)mrb_malloc_simple(mrb, sizeof(mrb_value) * len);
  if (live != mrb->gc.live && mrb_object_dead_p(mrb, (struct RBasic*)e)) {
    mrb_free(mrb, p);
    return TRUE;
  } else if (p) {
    stack_copy(p, e->stack, len);
    e->stack = p;
    MRB_ENV_CLOSE(e);
    mrb_write_barrier(mrb, (struct RBasic*)e);
    return TRUE;
  } else {
    e->stack = NULL;
    MRB_ENV_CLOSE(e);
    MRB_ENV_SET_LEN(e, 0);
    MRB_ENV_SET_BIDX(e, 0);
    if (!noraise) {
      mrb_exc_raise(mrb, mrb_obj_value(mrb->nomem_err));
    }
    return FALSE;
  }
}

static inline mrb_callinfo* cipop(mrb_state* mrb) {
  struct mrb_context* c = mrb->c;
  mrb_callinfo* ci = c->ci;
  struct REnv* env = CI_ENV(ci);

  ci_env_set(ci, NULL);  // make possible to free env by GC if not needed
  struct RProc* b = ci->blk;
  if (b && !MRB_PROC_STRICT_P(b) && MRB_PROC_ENV(b) == CI_ENV(&ci[-1])) {
    b->flags |= MRB_PROC_ORPHAN;
  }
  if (env && !mrb_env_unshare(mrb, env, TRUE)) {
    c->ci--;  // exceptions are handled at the method caller; see #3087
    mrb_exc_raise(mrb, mrb_obj_value(mrb->nomem_err));
  }
  c->ci--;
  if (mrb->errinfo && (c->ci - c->cibase) < mrb->errinfo_ci_depth) {
    mrb->errinfo = NULL;
  }
  return c->ci;
}

MRB_API mrb_value mrb_protect_error(mrb_state* mrb,
                                    mrb_protect_error_func* body,
                                    void* userdata,
                                    mrb_bool* error) {
  struct mrb_jmpbuf* prev_jmp = mrb->jmp;
  struct mrb_jmpbuf c_jmp;
  mrb_value result;
  int ai = mrb_gc_arena_save(mrb);
  const struct mrb_context* c = mrb->c;
  ptrdiff_t ci_index = c->ci - c->cibase;

  if (error) {
    *error = FALSE;
  }

  MRB_TRY(&c_jmp) {
    mrb->jmp = &c_jmp;
    result = body(mrb, userdata);
    mrb->jmp = prev_jmp;
  }
  MRB_CATCH(&c_jmp) {
    mrb->jmp = prev_jmp;
    result = mrb_obj_value(mrb->exc);
    mrb->exc = NULL;
    if (error) {
      *error = TRUE;
    }
    if (mrb->c == c) {
      while (c->ci - c->cibase > ci_index) {
        cipop(mrb);
      }
    } else {
      // It was probably switched by mrb_fiber_resume().
      c = mrb->c;
      while (c->ci > c->cibase && c->ci->cci == CINFO_DIRECT) {
        cipop(mrb);
      }
    }
  }
  MRB_END_EXC(&c_jmp);

  mrb_gc_arena_restore(mrb, ai);
  mrb_gc_protect(mrb, result);
  return result;
}

static mrb_value funcall_with_block_m(mrb_state* mrb,
                                      mrb_value self,
                                      mrb_sym mid,
                                      mrb_int argc,
                                      const mrb_value* argv,
                                      const mrb_value* kdict,
                                      mrb_bool check_argc,
                                      mrb_value blk,
                                      const mrb_method_t* fixed,
                                      struct RClass* fixed_owner);

static mrb_value funcall_va(mrb_state* mrb,
                            mrb_value self,
                            mrb_sym mid,
                            mrb_int argc,
                            va_list ap) {
  mrb_value argv[MRB_FUNCALL_ARGC_MAX];
  for (mrb_int i = 0; i < argc; i++) {
    argv[i] = va_arg(ap, mrb_value);
  }
  return funcall_with_block_m(mrb, self, mid, argc, argv, NULL, FALSE,
                              mrb_nil_value(), NULL, NULL);
}

MRB_API mrb_value mrb_funcall(mrb_state* mrb,
                              mrb_value self,
                              const char* name,
                              mrb_int argc,
                              ...) {
  mrb_sym mid = mrb_intern_cstr(mrb, name);

  if (argc > MRB_FUNCALL_ARGC_MAX) {
    mrb_raise(
        mrb, E_ARGUMENT_ERROR,
        "Too long arguments. (limit=" MRB_STRINGIZE(MRB_FUNCALL_ARGC_MAX) ")");
  }

  va_list ap;
  va_start(ap, argc);
  mrb_value r = funcall_va(mrb, self, mid, argc, ap);
  va_end(ap);
  return r;
}

MRB_API mrb_value
mrb_funcall_id(mrb_state* mrb, mrb_value self, mrb_sym mid, mrb_int argc, ...) {
  if (argc > MRB_FUNCALL_ARGC_MAX) {
    mrb_raise(
        mrb, E_ARGUMENT_ERROR,
        "Too long arguments. (limit=" MRB_STRINGIZE(MRB_FUNCALL_ARGC_MAX) ")");
  }

  va_list ap;
  va_start(ap, argc);
  mrb_value r = funcall_va(mrb, self, mid, argc, ap);
  va_end(ap);
  return r;
}

static inline mrb_int mrb_bidx(uint8_t n, uint8_t k) {
  if (n == 15)
    n = 1;
  if (k == 15)
    n += 1;
  else
    n += k * 2;
  return n + 1; /* self + args + kargs */
}

mrb_int mrb_ci_bidx(mrb_callinfo* ci) {
  return mrb_bidx(ci->n, ci->nk);
}

mrb_int mrb_ci_nregs(mrb_callinfo* ci) {
  if (!ci)
    return 4;
  return mrb_bidx(ci->n, ci->nk) + 1; /* self + args + kargs + blk */
}

static mrb_method_t prepare_missing(mrb_state* mrb,
                                    mrb_callinfo* ci,
                                    mrb_value recv,
                                    mrb_sym mid,
                                    mrb_value blk,
                                    mrb_bool super) {
  mrb_sym missing = MRB_SYM(method_missing);
  mrb_value* argv = &ci->stack[1];
  mrb_value args;
  mrb_method_t m;

  /* pack positional arguments */
  if (ci->n == 15)
    args = argv[0];
  else
    args = mrb_ary_new_from_values(mrb, ci->n, argv);

  if (mrb_func_basic_p(mrb, recv, missing, mrb_obj_missing)) {
  method_missing:
    if (super)
      mrb_no_method_error(mrb, mid, args, "no superclass method '%n' for %T",
                          mid, recv);
    else
      mrb_method_missing(mrb, mid, recv, args);
    /* not reached */
  }
  if (mid != missing) {
    ci->u.target_class = mrb_class(mrb, recv);
  }
  m = mrb_vm_find_method(mrb, ci->u.target_class, &ci->u.target_class, missing);
  if (MRB_METHOD_UNDEF_P(m))
    goto method_missing; /* just in case */
  stack_extend(mrb, 4);

  argv = &ci->stack[1]; /* maybe reallocated */
  if (ci->nk == 0) {
    argv[1] = blk;
  } else {
    mrb_assert(ci->nk == 15);
    if (ci->n != CALL_MAXARGS) {
      argv[1] = argv[ci->n]; /* keyword arguments */
    }
    argv[2] = blk;
  }
  argv[0] = args; /* must be replaced after saving argv[0] as it may be a
                     keyword argument */
  ci->n = CALL_MAXARGS;
  ci->mid = missing;
  mrb_ary_unshift(mrb, args, mrb_symbol_value(mid));
  return m;
}

static void check_argument_count(mrb_state* mrb,
                                 const mrb_callinfo* ci,
                                 mrb_aspec aspec);

/* kdict: keyword hash to pass as keyword arguments, or NULL for none */
static void funcall_args_capture(mrb_state* mrb,
                                 int stoff,
                                 mrb_int argc,
                                 const mrb_value* argv,
                                 const mrb_value* kdict,
                                 mrb_value block,
                                 mrb_callinfo* ci) {
  if (argc < 0 || argc > INT32_MAX) {
    mrb_raisef(mrb, E_ARGUMENT_ERROR,
               "negative or too big argc for funcall (%i)", argc);
  }

  ci->nk = kdict ? 15 : 0;
  mrb_value kd = kdict ? *kdict : mrb_nil_value();
  int kslot = kdict ? 1 : 0;
  if (argc < CALL_MAXARGS) {
    mrb_int extends = stoff + argc + 2 /* self + block */ + kslot;
    stack_extend_adjust(mrb, extends, &argv);

    mrb_value* args = mrb->c->ci->stack + stoff + 1 /* self */;
    stack_copy(args, argv, argc);
    if (kdict)
      args[argc] = kd;
    args[argc + kslot] = block;
    ci->n = (uint8_t)argc;
  } else {
    int extends = stoff + 3 /* self + splat + block */ + kslot;
    stack_extend_adjust(mrb, extends, &argv);

    mrb_value* args = mrb->c->ci->stack + stoff + 1 /* self */;
    args[0] = mrb_ary_new_from_values(mrb, argc, argv);
    if (kdict)
      args[1] = kd;
    args[1 + kslot] = block;
    ci->n = CALL_MAXARGS;
  }
}

static inline mrb_value ensure_block(mrb_state* mrb, mrb_value blk) {
  if (!mrb_nil_p(blk) && !mrb_proc_p(blk)) {
    blk = mrb_type_convert(mrb, blk, MRB_TT_PROC, MRB_SYM(to_proc));
  }
  return blk;
}

static mrb_value funcall_with_block_m(mrb_state* mrb,
                                      mrb_value self,
                                      mrb_sym mid,
                                      mrb_int argc,
                                      const mrb_value* argv,
                                      const mrb_value* kdict,
                                      mrb_bool check_argc,
                                      mrb_value blk,
                                      const mrb_method_t* fixed,
                                      struct RClass* fixed_owner) {
  mrb_value val;
  int ai = mrb_gc_arena_save(mrb);

  if (!mrb->jmp) {
    struct mrb_jmpbuf c_jmp;
    ptrdiff_t nth_ci = mrb->c->ci - mrb->c->cibase;

    MRB_TRY(&c_jmp) {
      mrb->jmp = &c_jmp;
      val = funcall_with_block_m(mrb, self, mid, argc, argv, kdict, check_argc,
                                 blk, fixed, fixed_owner);
      mrb->jmp = NULL;
    }
    MRB_CATCH(&c_jmp) { /* error */
      while (nth_ci < (mrb->c->ci - mrb->c->cibase)) {
        cipop(mrb);
      }
      mrb->jmp = 0;
      val = mrb_obj_value(mrb->exc);
    }
    MRB_END_EXC(&c_jmp);
    mrb->jmp = NULL;
  } else {
    mrb_method_t m;
    mrb_callinfo* ci = mrb->c->ci;
    mrb_int n = mrb_ci_nregs(ci);

    if (!mrb->c->stbase) {
      stack_init(mrb);
    }
    if (ci - mrb->c->cibase > MRB_CALL_LEVEL_MAX) {
      mrb_exc_raise(mrb, mrb_obj_value(mrb->stack_err));
    }
    blk = ensure_block(mrb, blk);
    ci = cipush(mrb, n, CINFO_DIRECT, NULL, NULL, BLK_PTR(blk), 0, 0);
    funcall_args_capture(mrb, 0, argc, argv, kdict, blk, ci);
    ci->u.target_class = mrb_class(mrb, self);
    if (fixed) {
      m = *fixed;
      ci->u.target_class = fixed_owner;
    } else {
      m = mrb_vm_find_method(mrb, ci->u.target_class, &ci->u.target_class, mid);
    }
    if (MRB_METHOD_UNDEF_P(m)) {
      m = prepare_missing(mrb, ci, self, mid, mrb_nil_value(), FALSE);
    } else {
      ci->mid = mid;
    }
    ci->proc = MRB_METHOD_PROC_P(m) ? MRB_METHOD_PROC(m) : NULL;

    if (!MRB_METHOD_CFUNC_P(m))
      no_irep(mrb);
    mrb->exc = NULL;
    ci->stack[0] = self;
    if (check_argc) {
      if (MRB_METHOD_FUNC_P(m)) {
        check_argument_count(mrb, ci, MRB_MT_ASPEC(m.flags));
      } else if (MRB_PROC_NOARG_P(MRB_METHOD_PROC(m)) &&
                 (ci->n > 0 || ci->nk > 0)) {
        check_argument_count(mrb, ci, 0);
      }
    }
    val = MRB_METHOD_CFUNC(m)(mrb, self);
    cipop(mrb);
    if (mrb->exc != NULL) {
      mrb_exc_raise(mrb, mrb_obj_value(mrb->exc));
    }
  }
  mrb_gc_arena_restore(mrb, ai);
  mrb_gc_protect(mrb, val);
  return val;
}

MRB_API mrb_value mrb_funcall_with_block(mrb_state* mrb,
                                         mrb_value self,
                                         mrb_sym mid,
                                         mrb_int argc,
                                         const mrb_value* argv,
                                         mrb_value blk) {
  return funcall_with_block_m(mrb, self, mid, argc, argv, NULL, FALSE, blk,
                              NULL, NULL);
}

mrb_value mrb_funcall_send(mrb_state* mrb,
                           mrb_value self,
                           mrb_sym mid,
                           mrb_int argc,
                           const mrb_value* argv,
                           mrb_value kdict,
                           mrb_value blk) {
  const mrb_value* kdict_p = mrb_hash_p(kdict) ? &kdict : NULL;
  return funcall_with_block_m(mrb, self, mid, argc, argv, kdict_p, TRUE, blk,
                              NULL, NULL);
}

// The hot case (a found cfunc, positional arguments, a running context):
// funcall_with_block_m's steps with the generic argument capture and the nregs
// call folded away. Anything else takes the general path.
mrb_value mrb_funcall_with_method(mrb_state* mrb,
                                  mrb_value self,
                                  mrb_sym mid,
                                  const mrb_method_t* m,
                                  struct RClass* owner,
                                  mrb_int argc,
                                  const mrb_value* argv,
                                  mrb_value blk) {
  struct mrb_context* c = mrb->c;
  mrb_callinfo* pci = c->ci;
  if (mrb_unlikely(!mrb->jmp || !c->stbase || !pci->stack || argc < 0 ||
                   argc >= CALL_MAXARGS || !MRB_METHOD_CFUNC_P(*m) ||
                   !(mrb_nil_p(blk) || mrb_proc_p(blk)) ||
                   pci - c->cibase > MRB_CALL_LEVEL_MAX ||
                   pci->stack + mrb_bidx(pci->n, pci->nk) + 1 + argc + 2 >=
                       c->stend)) {
    return funcall_with_block_m(mrb, self, mid, argc, argv, NULL, FALSE, blk, m,
                                owner);
  }
  int ai = mrb_gc_arena_save(mrb);
  mrb_callinfo* ci =
      cipush(mrb, mrb_bidx(pci->n, pci->nk) + 1, CINFO_DIRECT, owner,
             MRB_METHOD_PROC_P(*m) ? MRB_METHOD_PROC(*m) : NULL, BLK_PTR(blk),
             mid, (uint16_t)argc);
  mrb_value* args = ci->stack;
  args[0] = self;
  for (mrb_int i = 0; i < argc; i++)
    args[i + 1] = argv[i];
  args[argc + 1] = blk;
  mrb->exc = NULL;
  mrb_value val = MRB_METHOD_CFUNC(*m)(mrb, self);
  cipop(mrb);
  if (mrb->exc != NULL) {
    mrb_exc_raise(mrb, mrb_obj_value(mrb->exc));
  }
  mrb_gc_arena_restore(mrb, ai);
  mrb_gc_protect(mrb, val);
  return val;
}

MRB_API mrb_value mrb_funcall_argv(mrb_state* mrb,
                                   mrb_value self,
                                   mrb_sym mid,
                                   mrb_int argc,
                                   const mrb_value* argv) {
  return mrb_funcall_with_block(mrb, self, mid, argc, argv, mrb_nil_value());
}

static void check_argument_count(mrb_state* mrb,
                                 const mrb_callinfo* ci,
                                 mrb_aspec aspec) {
  mrb_int argc = ci->n;
  if (mrb_unlikely(argc == CALL_MAXARGS)) {
    argc = RARRAY_LEN(ci->stack[1]);
  }
  /* keyword hash counts as positional if method doesn't accept keywords */
  if (ci->nk > 0 && MRB_ASPEC_KEY(aspec) == 0 && !MRB_ASPEC_KDICT(aspec)) {
    mrb_int kidx = (ci->n == CALL_MAXARGS) ? 2 : ci->n + 1;
    mrb_value kdict = ci->stack[kidx];
    if (mrb_hash_p(kdict) && !mrb_hash_empty_p(mrb, kdict)) {
      argc++;
    }
  }
  int min = MRB_ASPEC_REQ(aspec) + MRB_ASPEC_POST(aspec);
  int max = MRB_ASPEC_REST(aspec) ? -1 : min + MRB_ASPEC_OPT(aspec);
  if (mrb_unlikely(argc < min || (max >= 0 && argc > max))) {
    mrb_argnum_error(mrb, argc, min, max);
  }
}

// The proc's body runs in the caller's C frame (Proc#call on a native block):
// only a cfunc proc can.
mrb_value mrb_exec_irep(mrb_state* mrb, mrb_value self, const struct RProc* p) {
  mrb_callinfo* ci = mrb->c->ci;
  if (ci->cci == CINFO_NONE || !MRB_PROC_CFUNC_P(p))
    no_irep(mrb);
  if (MRB_PROC_NOARG_P(p) && (ci->n > 0 || ci->nk > 0)) {
    check_argument_count(mrb, ci, 0);
  }
  ci = cipush(mrb, 0, CINFO_DIRECT, CI_TARGET_CLASS(ci), p, NULL, ci->mid,
              ci->n | (ci->nk << 4));
  mrb->exc = NULL;
  mrb_value ret = MRB_PROC_CFUNC(p)(mrb, self);
  cipop(mrb);
  if (mrb->exc && mrb->jmp) {
    mrb_exc_raise(mrb, mrb_obj_value(mrb->exc));
  }
  return ret;
}

// A native frame is always CINFO_DIRECT here (no VM frame calls it), so send is
// a funcall.
static mrb_value send_method(mrb_state* mrb, mrb_value self) {
  mrb_sym name;
  const mrb_value* argv;
  mrb_int argc;
  mrb_value block;
  if (mrb->c->ci->cci == CINFO_NONE)
    no_frame(mrb);
  mrb_get_args(mrb, "n*&", &name, &argv, &argc, &block);
  return mrb_funcall_with_block(mrb, self, name, argc, argv, block);
}

mrb_value mrb_f_send(mrb_state* mrb, mrb_value self) {
  return send_method(mrb, self);
}

// vm.c's funcall branch (the only one here) does not check visibility for
// public_send either.
mrb_value mrb_f_public_send(mrb_state* mrb, mrb_value self) {
  return send_method(mrb, self);
}

static void check_block(mrb_state* mrb, mrb_value blk) {
  if (mrb_nil_p(blk)) {
    mrb_raise(mrb, E_ARGUMENT_ERROR, "no block given");
  }
  if (!mrb_proc_p(blk)) {
    mrb_raise(mrb, E_TYPE_ERROR, "not a block");
  }
}

static mrb_value yield_with_attr(mrb_state* mrb,
                                 mrb_value b,
                                 mrb_int argc,
                                 const mrb_value* argv,
                                 mrb_value self,
                                 struct RClass* c,
                                 mrb_bool vis_break) {
  check_block(mrb, b);

  mrb_callinfo* ci = mrb->c->ci;
  mrb_int n = mrb_ci_nregs(ci);
  const struct RProc* p = mrb_proc_ptr(b);
  mrb_sym mid;

  if (MRB_PROC_ENV_P(p)) {
    mid = p->e.env->mid;
  } else {
    mid = ci->mid;
  }
  if (!MRB_PROC_CFUNC_P(p))
    no_irep(mrb);
  ci = cipush(mrb, n, CINFO_DIRECT, NULL, NULL, NULL, mid, 0);
  funcall_args_capture(mrb, 0, argc, argv, NULL, mrb_nil_value(), ci);
  ci->u.target_class = c;
  ci->proc = p;
  if (vis_break) {
    MRB_CI_SET_VISIBILITY_BREAK(ci);
  }

  mrb->exc = NULL;
  ci->stack[0] = self;
  mrb_value val = MRB_PROC_CFUNC(p)(mrb, self);
  cipop(mrb);
  if (mrb->exc && mrb->jmp) {
    mrb_exc_raise(mrb, mrb_obj_value(mrb->exc));
  }
  return val;
}

MRB_API mrb_value mrb_yield_with_class(mrb_state* mrb,
                                       mrb_value b,
                                       mrb_int argc,
                                       const mrb_value* argv,
                                       mrb_value self,
                                       struct RClass* c) {
  return yield_with_attr(mrb, b, argc, argv, self, c, TRUE);
}

MRB_API mrb_value mrb_yield_argv(mrb_state* mrb,
                                 mrb_value b,
                                 mrb_int argc,
                                 const mrb_value* argv) {
  const struct RProc* p = mrb_proc_ptr(b);
  struct RClass* tc;
  mrb_value self = mrb_proc_get_self(mrb, p, &tc);

  return yield_with_attr(mrb, b, argc, argv, self, tc, FALSE);
}

MRB_API mrb_value mrb_yield(mrb_state* mrb, mrb_value b, mrb_value arg) {
  const struct RProc* p = mrb_proc_ptr(b);
  struct RClass* tc;
  mrb_value self = mrb_proc_get_self(mrb, p, &tc);

  return yield_with_attr(mrb, b, 1, &arg, self, tc, FALSE);
}

mrb_value mrb_mod_module_eval(mrb_state* mrb, mrb_value mod) {
  mrb_value a, b;

  if (mrb_get_args(mrb, "|S&", &a, &b) == 1) {
    mrb_raise(mrb, E_NOTIMP_ERROR,
              "module_eval/class_eval with string not implemented");
  }
  check_block(mrb, b);
  if (mrb->c->ci->cci == CINFO_NONE)
    no_frame(mrb);
  return mrb_yield_with_class(mrb, b, 1, &mod, mod, mrb_class_ptr(mod));
}

mrb_value mrb_obj_instance_eval(mrb_state* mrb, mrb_value self) {
  mrb_value a, b;

  if (mrb_get_args(mrb, "|S&", &a, &b) == 1) {
    mrb_raise(mrb, E_NOTIMP_ERROR, "instance_eval with string not implemented");
  }
  check_block(mrb, b);
  if (mrb->c->ci->cci == CINFO_NONE)
    no_frame(mrb);
  return mrb_yield_with_class(mrb, b, 1, &self, self,
                              mrb_singleton_class_ptr(mrb, self));
}

#ifndef MRB_USE_CXX_ABI
}
#endif
