// The part of the C++ Fiber runtime that wraps a resumable method's step
// function (codegen_resumable.rb) as a Bc2cppFiberFrame. Emitted after
// RESUMABLE_HELPERS, whose bc2cpp_resume_frame_* functions it uses; not
// standalone. A method step returns its heap frame on suspension; this adapter
// maps that onto DONE / YIELD / CALL / UNWIND.
#pragma once

typedef Bc2cppFiberFrame* (*Bc2cppBlockStepMaker)(mrb_state* M,
                                                  struct REnv* env,
                                                  mrb_int argc,
                                                  const mrb_value* argv);

typedef mrb_value (*Bc2cppMethodStep)(mrb_state* M,
                                      mrb_value self,
                                      mrb_value frame,
                                      mrb_value resume);

struct Bc2cppMethodFrame {
  Bc2cppFiberFrame f;
  mrb_value self;
  mrb_value frame;
  Bc2cppMethodStep step;
};

// A cfunc block that carries a step maker: a thunk (direct-entry) block sets
// flag bit 2, any other block ends its env with the magic-tagged flag word
// (BLOCK_STEP_MAGIC), so an env that merely ends in some pointer is not
// mistaken for one.
static bool bc2cpp_block_has_step(const struct RProc* p,
                                  const struct REnv* env) {
  mrb_int len = env ? MRB_ENV_LEN(env) : 0;
  if (len < 3 || !mrb_integer_p(env->stack[len - 1]))
    return false;
  mrb_int flags = mrb_integer(env->stack[len - 1]);
  if (MRB_PROC_CFUNC(p) == bc2cpp_block_thunk)
    return (flags & 4) != 0;
  return (flags & ~(mrb_int)0xffff) == 0x5b2c0000 && (flags & 4) != 0;
}

// The maker is in the env slot before the entry.
static Bc2cppBlockStepMaker bc2cpp_block_step_maker(const struct REnv* env) {
  return (Bc2cppBlockStepMaker)(uintptr_t)mrb_integer(
      env->stack[MRB_ENV_LEN(env) - 3]);
}

// Calls +blk+ with the arguments from a frame of this fiber. Returns true with
// the value in *value when the block ran to its end here; false with *out set
// when the fiber has to act first: CALL when the block is a step (BLOCK_STEP),
// or YIELD when its last act is Fiber.yield (Bc2cppTailYield), whose next
// resume value is the block's result.
static bool bc2cpp_block_call(mrb_state* M,
                              mrb_value blk,
                              mrb_int argc,
                              const mrb_value* argv,
                              Bc2cppStepOut* out,
                              mrb_value* value) {
  bc2cpp_tail_yield.pending = false;
  const struct RProc* p = mrb_proc_p(blk) && MRB_PROC_CFUNC_P(mrb_proc_ptr(blk))
                              ? mrb_proc_ptr(blk)
                              : nullptr;
  const struct REnv* env = p ? MRB_PROC_ENV(p) : nullptr;
  if (p && bc2cpp_block_has_step(p, env)) {
    Bc2cppFiberFrame* callee =
        bc2cpp_block_step_maker(env)(M, (struct REnv*)env, argc, argv);
    if (callee) {
      out->kind = BC2CPP_STEP_CALL;
      out->callee = callee;
      return false;
    }
  }
  bc2cpp_tail_yield.env = env;
  *value = mrb_yield_argv(M, blk, argc, argv);
  bc2cpp_tail_yield.env = nullptr;
  if (bc2cpp_tail_yield.pending) {
    bc2cpp_tail_yield.pending = false;
    out->kind = BC2CPP_STEP_YIELD;
    out->value = bc2cpp_tail_yield.value;
    return false;
  }
  return true;
}

static void bc2cpp_method_frame_step(mrb_state* M,
                                     Bc2cppFiberFrame* base,
                                     mrb_value resume,
                                     Bc2cppStepOut* out) {
  Bc2cppMethodFrame* m = (Bc2cppMethodFrame*)base;
  for (;;) {
    mrb_value result = m->step(M, m->self, m->frame, resume);
    if (!bc2cpp_resume_frame_p(M, result)) {
      out->kind = BC2CPP_STEP_DONE;
      out->value = result;
      return;
    }
    m->frame = result;
    // CALL_STEP: the step asked the fiber to call another frame; its result is
    // the resume value of this step.
    Bc2cppResumeFrame* suspended = (Bc2cppResumeFrame*)DATA_PTR(result);
    if (suspended && suspended->callee) {
      out->kind = BC2CPP_STEP_CALL;
      out->callee = (Bc2cppFiberFrame*)suspended->callee;
      suspended->callee = nullptr;
      return;
    }
    // UNWIND: a `break` or `return` out of a block step names the method frame
    // it ends.
    if (suspended && suspended->unwind_mode) {
      out->kind = BC2CPP_STEP_UNWIND;
      out->value = bc2cpp_resume_frame_value(M, result);
      out->target = (struct RBasic*)suspended->unwind_key;
      out->to_return = suspended->unwind_mode == 2;
      suspended->unwind_mode = 0;
      return;
    }
    if (!mrb_test(bc2cpp_resume_frame_block_call(M, result))) {
      out->kind = BC2CPP_STEP_YIELD;
      out->value = bc2cpp_resume_frame_value(M, result);
      return;
    }
    // A block-call suspension: call the block here. A block whose last act is
    // Fiber.yield (Bc2cppTailYield) hands its value back and the fiber yields
    // it; the next resume value is the block's result.
    mrb_value args = bc2cpp_resume_frame_value(M, result);
    mrb_value blk = bc2cpp_resume_frame_block(M, result);
    if (!bc2cpp_block_call(M, blk, RARRAY_LEN(args), RARRAY_PTR(args), out,
                           &resume))
      return;
  }
}

static void bc2cpp_method_frame_mark(mrb_state* M,
                                     Bc2cppFiberFrame* base,
                                     mrb_value refs) {
  Bc2cppMethodFrame* m = (Bc2cppMethodFrame*)base;
  bc2cpp_fiber_ref(M, refs, m->self);
  bc2cpp_fiber_ref(M, refs, m->frame);
}

static Bc2cppResumeFrame* bc2cpp_method_frame_resume(Bc2cppFiberFrame* base) {
  mrb_value frame = ((Bc2cppMethodFrame*)base)->frame;
  return mrb_data_p(frame) ? (Bc2cppResumeFrame*)DATA_PTR(frame) : nullptr;
}

static struct RBasic* bc2cpp_method_frame_identity(Bc2cppFiberFrame* base) {
  mrb_value frame = ((Bc2cppMethodFrame*)base)->frame;
  return mrb_data_p(frame) ? (struct RBasic*)mrb_obj_ptr(frame) : nullptr;
}

static bool bc2cpp_method_frame_has_handlers(Bc2cppFiberFrame* base) {
  Bc2cppResumeFrame* f = bc2cpp_method_frame_resume(base);
  return f && f->has_handlers;
}

// An exception reaches a method frame that CALLed (or called a block of) the
// frame it came from: a step with handlers is re-entered with it raised at the
// address it suspended at; one without, or one that declined it, is dropped.
static bool bc2cpp_method_frame_unwind_into(mrb_state*,
                                            Bc2cppFiberFrame* base,
                                            mrb_value) {
  if (!bc2cpp_method_frame_has_handlers(base))
    return false;
  bc2cpp_method_frame_resume(base)->raise_pending = 1;
  return true;
}

[[maybe_unused]] static Bc2cppFiberFrame* bc2cpp_method_frame_new(
    mrb_state* M,
    Bc2cppMethodStep step,
    mrb_value self,
    mrb_value frame) {
  Bc2cppMethodFrame* m = bc2cpp_frame_alloc<Bc2cppMethodFrame>(
      M, bc2cpp_method_frame_step, bc2cpp_method_frame_mark);
  m->f.identity = bc2cpp_method_frame_identity;
  m->f.unwind_into = bc2cpp_method_frame_unwind_into;
  m->f.has_handlers = bc2cpp_method_frame_has_handlers;
  m->self = self;
  m->frame = frame;
  m->step = step;
  return &m->f;
}

// `Fiber.new { |x, y| ... }` whose body is a step (BLOCK_STEP): the root frame
// makes the body's frame on the first resume, from that resume's arguments
// (bound as a block's parameters are), and calls it; the body's result is the
// fiber's.
struct Bc2cppBodyStart {
  Bc2cppFiberFrame f;
  mrb_value proc;
  bool started;
};

static void bc2cpp_body_start_step(mrb_state* M,
                                   Bc2cppFiberFrame* base,
                                   mrb_value resume,
                                   Bc2cppStepOut* out) {
  Bc2cppBodyStart* start = (Bc2cppBodyStart*)base;
  if (start->started) {
    out->kind = BC2CPP_STEP_DONE;
    out->value = resume;
    return;
  }
  start->started = true;
  const struct REnv* env = MRB_PROC_ENV(mrb_proc_ptr(start->proc));
  // resume(a, b) arrives as [a, b]; from C, as the one value (or nothing).
  mrb_value first = bc2cpp_first_args_set ? bc2cpp_first_args : mrb_nil_value();
  mrb_int argc = 0;
  const mrb_value* argv = nullptr;
  if (mrb_array_p(first)) {
    argc = RARRAY_LEN(first);
    argv = RARRAY_PTR(first);
  } else if (!mrb_nil_p(resume)) {
    argc = 1;
    argv = &resume;
  }
  Bc2cppFiberFrame* root =
      bc2cpp_block_step_maker(env)(M, (struct REnv*)env, argc, argv);
  if (!root)
    mrb_raise(M, mrb_class_get(M, "RuntimeError"),
              "bc2cpp: Fiber body step did not make a frame");
  out->kind = BC2CPP_STEP_CALL;
  out->callee = root;
}

static void bc2cpp_body_start_mark(mrb_state* M,
                                   Bc2cppFiberFrame* base,
                                   mrb_value refs) {
  bc2cpp_fiber_ref(M, refs, ((Bc2cppBodyStart*)base)->proc);
}

[[maybe_unused]] static mrb_value bc2cpp_fiber_new_step(mrb_state* M,
                                                        mrb_value proc) {
  bc2cpp_fiber_define(M);
  const struct REnv* env = MRB_PROC_ENV(mrb_proc_ptr(proc));
  mrb_int len = env ? MRB_ENV_LEN(env) : 0;
  if (len < 3 || !(mrb_integer(env->stack[len - 1]) & 4))
    mrb_raise(M, mrb_class_get(M, "RuntimeError"),
              "bc2cpp: Fiber body has no step");
  Bc2cppBodyStart* start = bc2cpp_frame_alloc<Bc2cppBodyStart>(
      M, bc2cpp_body_start_step, bc2cpp_body_start_mark);
  start->proc = proc;
  return bc2cpp_fiber_new(M, &start->f);
}

// DYN_CALL: a call whose method is chosen at run time (`send`, `__send__`,
// `public_send`). A suspendable method registers a dispatcher (the generated
// `_dyn`) under its registered C function; the call resolves the method on the
// receiver and, when it is registered and takes this many arguments, returns
// the frame its entry parks, for the caller to CALL. Anything else runs as an
// ordinary send.
typedef mrb_value (*Bc2cppDynFn)(mrb_state* M,
                                 mrb_value self,
                                 mrb_int argc,
                                 const mrb_value* argv,
                                 mrb_value blk);
// STEP_KEYWORDS: the dispatcher of a method that takes keywords. It gets the
// call's keyword Hash (nil when none) and declines (undef) a call whose
// keywords do not fit, so the ordinary send raises the interpreter's
// ArgumentError.
typedef mrb_value (*Bc2cppDynKwFn)(mrb_state* M,
                                   mrb_value self,
                                   mrb_int argc,
                                   const mrb_value* argv,
                                   mrb_value kdict,
                                   mrb_value blk);
struct Bc2cppDynEntry {
  Bc2cppDynFn fn;
  mrb_int min_argc;
  mrb_int max_argc;
  Bc2cppDynKwFn kwfn = nullptr;
};

inline std::unordered_map<void*, Bc2cppDynEntry>& bc2cpp_dyn_table() {
  static std::unordered_map<void*, Bc2cppDynEntry> table;
  return table;
}

[[maybe_unused]] static void bc2cpp_dyn_register(void* cfunc,
                                                 Bc2cppDynFn fn,
                                                 mrb_int min_argc,
                                                 mrb_int max_argc) {
  bc2cpp_dyn_table()[cfunc] = Bc2cppDynEntry{fn, min_argc, max_argc};
}

[[maybe_unused]] static void bc2cpp_dyn_register_kw(void* cfunc,
                                                    Bc2cppDynKwFn fn,
                                                    mrb_int min_argc,
                                                    mrb_int max_argc) {
  bc2cpp_dyn_table()[cfunc] = Bc2cppDynEntry{nullptr, min_argc, max_argc, fn};
}

// Binds the keywords of a call to a method's parameters: `names` lists the `n`
// keywords, the first `required` required; `values[i]` is the value, or undef
// when omitted. False when the call does not fit (a required keyword missing or
// an unknown one), as mrb_get_args' ':' refuses it; the Hash is not changed.
[[maybe_unused]] static bool bc2cpp_dyn_bind_keywords(mrb_state* M,
                                                      mrb_value kdict,
                                                      mrb_int n,
                                                      mrb_int required,
                                                      const mrb_sym* names,
                                                      mrb_value* values) {
  bool have = mrb_hash_p(kdict);
  mrb_int found = 0;
  for (mrb_int i = 0; i < n; ++i) {
    mrb_value key = mrb_symbol_value(names[i]);
    if (have && mrb_hash_key_p(M, kdict, key)) {
      values[i] = mrb_hash_get(M, kdict, key);
      ++found;
    } else {
      values[i] = mrb_undef_value();
      if (i < required)
        return false;
    }
  }
  return !have || mrb_hash_size(M, kdict) == found;
}

static void bc2cpp_dyn_builtins(mrb_state* M);  // bc2cpp_fiber_sort.hxx

struct Bc2cppDynResult {
  Bc2cppFiberFrame* frame;  // parked callee frame, or null when value is set
  mrb_value value;
};

extern "C" mrb_value mrb_funcall_send(mrb_state* M,
                                      mrb_value self,
                                      mrb_sym mid,
                                      mrb_int argc,
                                      const mrb_value* argv,
                                      mrb_value kdict,
                                      mrb_value blk);

// `kdict` is the keyword Hash of the call, or nil. A method with a keyword
// dispatcher takes it; any other suspendable method takes none, so a non-empty
// one runs as an ordinary send that carries them (mrb_funcall_send).
static bool bc2cpp_dyn_keywords_p(mrb_state* M, mrb_value kdict) {
  return mrb_hash_p(kdict) && !mrb_hash_empty_p(M, kdict);
}

// A registered suspendable method found for a call: park its frame (the caller
// CALLs it), else nothing.
static bool bc2cpp_dyn_park(mrb_state* M,
                            mrb_value recv,
                            mrb_method_t method,
                            mrb_int argc,
                            const mrb_value* argv,
                            mrb_value kdict,
                            mrb_value blk,
                            Bc2cppDynResult* out) {
  if (MRB_METHOD_UNDEF_P(method))
    return false;
  // A C function is keyed by itself; a bytecode method (Kernel#catch) by its
  // proc.
  void* key = MRB_METHOD_CFUNC_P(method)  ? (void*)MRB_METHOD_CFUNC(method)
              : MRB_METHOD_PROC_P(method) ? (void*)MRB_METHOD_PROC(method)
                                          : nullptr;
  if (!key)
    return false;
  auto& table = bc2cpp_dyn_table();
  auto it = table.find(key);
  if (it == table.end() || argc < it->second.min_argc ||
      argc > it->second.max_argc)
    return false;
  bool keywords = bc2cpp_dyn_keywords_p(M, kdict);
  if (!it->second.kwfn && keywords)
    return false;
  bc2cpp_prologue.frame = nullptr;
  mrb_value result =
      it->second.kwfn ? it->second.kwfn(M, recv, argc, argv,
                                        keywords ? kdict : mrb_nil_value(), blk)
                      : it->second.fn(M, recv, argc, argv, blk);
  Bc2cppFiberFrame* parked = bc2cpp_prologue.frame;
  bc2cpp_prologue.frame = nullptr;
  // undef: the dispatcher declined (nothing for a frame to do).
  if (!parked && mrb_undef_p(result))
    return false;
  *out = Bc2cppDynResult{parked, result};
  return true;
}

[[maybe_unused]] static Bc2cppDynResult bc2cpp_dyn_call(mrb_state* M,
                                                        mrb_value recv,
                                                        mrb_value name,
                                                        mrb_int argc,
                                                        const mrb_value* argv,
                                                        mrb_value kdict,
                                                        mrb_value blk) {
  bc2cpp_dyn_builtins(M);
  mrb_sym mid = mrb_symbol_p(name)
                    ? mrb_symbol(name)
                    : mrb_intern_str(M, mrb_obj_as_string(M, name));
  bool keywords = bc2cpp_dyn_keywords_p(M, kdict);
  struct RClass* c = mrb_class(M, recv);
  mrb_method_t method = mrb_method_search_vm(M, &c, mid);
  Bc2cppDynResult out;
  if (bc2cpp_dyn_park(M, recv, method, argc, argv, kdict, blk, &out))
    return out;
  if (!keywords)
    return Bc2cppDynResult{
        nullptr, mrb_funcall_with_block(M, recv, mid, argc, argv, blk)};
  return Bc2cppDynResult{
      nullptr, mrb_funcall_send(M, recv, mid, argc, argv, kdict, blk)};
}

// `super` in a step: the lookup starts above `owner`, the class the running
// method is defined on (OP_SUPER). A registered suspendable target parks its
// frame as in a dynamic call; any other target is called as bc2cpp_super_call
// does.
[[maybe_unused]] static Bc2cppDynResult bc2cpp_dyn_super(mrb_state* M,
                                                         mrb_value self,
                                                         struct RClass* owner,
                                                         mrb_sym mid,
                                                         mrb_int argc,
                                                         const mrb_value* argv,
                                                         mrb_value blk) {
  struct RClass* c = owner;
  MRB_CLASS_ORIGIN(c);
  c = c->super;
  mrb_method_t method = mrb_method_search_vm(M, &c, mid);
  if (MRB_METHOD_UNDEF_P(method))
    mrb_method_missing(M, mid, self, mrb_ary_new_from_values(M, argc, argv));
  Bc2cppDynResult out;
  if (bc2cpp_dyn_park(M, self, method, argc, argv, mrb_nil_value(), blk, &out))
    return out;
  return Bc2cppDynResult{nullptr, mrb_funcall_with_method(M, self, mid, &method,
                                                          c, argc, argv, blk)};
}
