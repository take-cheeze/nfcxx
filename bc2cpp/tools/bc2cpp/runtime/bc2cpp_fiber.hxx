// C++ Fiber runtime for compiled bc2cpp code: no mruby-fiber, no VM frame, no
// Fiber.yield call.
//
// A method that can suspend is compiled as a step function over a heap frame. A
// step runs until it finishes (DONE), suspends (YIELD) or needs another
// suspendable body to run first (CALL). The fiber owns a stack of frames;
// resuming runs the top frame's step and moves between frames as the steps ask.
// No C++ frame stays between a YIELD and the resumer, so nothing needs a VM
// frame to suspend across.
#pragma once

#include <mruby.h>
#include <mruby/array.h>
#include <mruby/class.h>
#include <mruby/data.h>
#include <mruby/error.h>
#include <mruby/hash.h>
#include <mruby/proc.h>
#include <mruby/string.h>
#include <mruby/variable.h>
#include <string.h>
#include <unordered_map>

enum Bc2cppStepKind { BC2CPP_STEP_DONE, BC2CPP_STEP_YIELD, BC2CPP_STEP_CALL };

struct Bc2cppFiberFrame;

// What a step reports. DONE: `value` is the body's result. YIELD: `value` goes
// to the resumer. CALL: `callee` is a new frame (allocated with mrb_malloc,
// owned by the fiber from now on); its result is the next resume value.
struct Bc2cppStepOut {
  Bc2cppStepKind kind;
  mrb_value value;
  Bc2cppFiberFrame* callee;
};

typedef void (*Bc2cppStepFn)(mrb_state* M,
                             Bc2cppFiberFrame* frame,
                             mrb_value resume,
                             Bc2cppStepOut* out);

// A frame is the first member of the body's own frame struct. `mark` marks
// every mrb_value the frame holds; `release` frees what the body's struct
// allocated besides itself (either may be null).
struct Bc2cppFiberFrame {
  Bc2cppStepFn step;
  Bc2cppFiberFrame* parent;
  void (*mark)(mrb_state* M, Bc2cppFiberFrame* frame, mrb_value refs);
  void (*release)(mrb_state* M, Bc2cppFiberFrame* frame);
};

struct Bc2cppFiber {
  Bc2cppFiberFrame* top;
  bool running;
  bool started;
};

// The handoff between a Fiber body and the suspendable method it ends with. The
// body's first step arms the id of the method it expects (`Owner#name`) and
// runs the body's compiled prologue, whose only call is that method. The
// method's entry, seeing its own id armed, parks the frame it would have run in
// `frame` and returns at once, so the body finishes without running it and the
// fiber calls the parked frame. One shared object across all translation units.
struct Bc2cppPrologue {
  const char* expect;
  mrb_value recv;
  Bc2cppFiberFrame* frame;
};
inline Bc2cppPrologue bc2cpp_prologue = {nullptr, {}, nullptr};

// `id` is the entry's own "Owner#name". An armed "Owner#name" matches exactly
// (a call on self to a known method). An armed "#name" is a call on an explicit
// receiver whose class the body does not prove: it matches any owner's `name`,
// but only on the receiver the body's call site stored
// (bc2cpp_prologue_set_recv), so a method that happens to call another `name`
// cannot take the handoff.
[[maybe_unused]] static bool bc2cpp_prologue_armed(mrb_state* M,
                                                   const char* id,
                                                   mrb_value self) {
  const char* expect = bc2cpp_prologue.expect;
  if (!expect)
    return false;
  if (expect[0] != '#')
    return strcmp(expect, id) == 0;
  const char* hash = strchr(id, '#');
  return hash && strcmp(hash, expect) == 0 &&
         mrb_obj_eq(M, self, bc2cpp_prologue.recv);
}

[[maybe_unused]] static void bc2cpp_prologue_set_recv(mrb_value recv) {
  bc2cpp_prologue.recv = recv;
}

[[maybe_unused]] static mrb_value bc2cpp_prologue_park(
    Bc2cppFiberFrame* frame) {
  bc2cpp_prologue.expect = nullptr;
  bc2cpp_prologue.frame = frame;
  return mrb_nil_value();
}

// A block whose last act is `Fiber.yield v` can hand `v` to the C++ Fiber by
// returning: nothing of the block is left to resume. When the fiber's adapter
// calls such a block it names the block's env here; the block's entry
// (Bc2cppTailYieldScope) sees the match and lets its tail yield store `v` in
// `value` and return, and the adapter turns that into a YIELD whose resume
// value is the block's result. `can_yield` is true only inside that one entry,
// so a nested block, or the same block called any other way, takes the ordinary
// Fiber.yield.
struct Bc2cppTailYield {
  const struct REnv* env;
  bool pending;
  mrb_value value;
};
inline Bc2cppTailYield bc2cpp_tail_yield = {nullptr, false, {}};
inline bool bc2cpp_block_can_yield = false;

struct Bc2cppTailYieldScope {
  bool previous;
  explicit Bc2cppTailYieldScope(const struct REnv* env) {
    previous = bc2cpp_block_can_yield;
    bool match = env && bc2cpp_tail_yield.env == env;
    if (match)
      bc2cpp_tail_yield.env = nullptr;
    bc2cpp_block_can_yield = match;
  }
  ~Bc2cppTailYieldScope() { bc2cpp_block_can_yield = previous; }
  Bc2cppTailYieldScope(const Bc2cppTailYieldScope&) = delete;
  Bc2cppTailYieldScope& operator=(const Bc2cppTailYieldScope&) = delete;
};

[[maybe_unused]] static mrb_value bc2cpp_tail_yield_store(mrb_value value) {
  bc2cpp_tail_yield.pending = true;
  bc2cpp_tail_yield.value = value;
  return mrb_nil_value();
}

static void bc2cpp_frame_free(mrb_state* M, Bc2cppFiberFrame* frame) {
  if (frame->release)
    frame->release(M, frame);
  mrb_free(M, frame);
}

static void bc2cpp_fiber_clear(mrb_state* M, Bc2cppFiber* fiber) {
  while (fiber->top) {
    Bc2cppFiberFrame* frame = fiber->top;
    fiber->top = frame->parent;
    bc2cpp_frame_free(M, frame);
  }
}

static void bc2cpp_fiber_data_free(mrb_state* M, void* p) {
  Bc2cppFiber* fiber = (Bc2cppFiber*)p;
  if (!fiber)
    return;
  bc2cpp_fiber_clear(M, fiber);
  mrb_free(M, fiber);
}

// mruby has no mark callback for a data object, so the values the frames hold
// are kept alive the way the resume frames' registers are: the fiber carries a
// hidden Array of them, rebuilt after every step. A frame adds each value it
// holds with bc2cpp_fiber_ref.
[[maybe_unused]] static void bc2cpp_fiber_ref(mrb_state* M,
                                              mrb_value refs,
                                              mrb_value v) {
  if (!mrb_immediate_p(v))
    mrb_ary_push(M, refs, v);
}

static void bc2cpp_fiber_refresh(mrb_state* M,
                                 mrb_value self,
                                 Bc2cppFiber* fiber) {
  mrb_sym key = mrb_intern_lit(M, "__refs__");
  mrb_value refs = mrb_iv_get(M, self, key);
  if (!mrb_array_p(refs)) {
    refs = mrb_ary_new(M);
    mrb_iv_set(M, self, key, refs);
  }
  mrb_ary_clear(M, refs);
  for (Bc2cppFiberFrame* frame = fiber->top; frame; frame = frame->parent) {
    if (frame->mark)
      frame->mark(M, frame, refs);
  }
}

inline const mrb_data_type bc2cpp_fiber_type = {"Bc2cppFiber",
                                                bc2cpp_fiber_data_free};

static struct RClass* bc2cpp_fiber_error_class(mrb_state* M) {
  mrb_sym name = mrb_intern_lit(M, "FiberError");
  if (mrb_const_defined_at(M, mrb_obj_value(M->object_class), name)) {
    return mrb_class_get_id(M, name);
  }
  return mrb_class_get(M, "RuntimeError");
}

static Bc2cppFiber* bc2cpp_fiber_ptr(mrb_state* M, mrb_value fiber) {
  return (Bc2cppFiber*)mrb_data_get_ptr(M, fiber, &bc2cpp_fiber_type);
}

// A fiber whose first step is `root`'s. The frame is owned by the fiber from
// now on.
static mrb_value bc2cpp_fiber_new(mrb_state* M, Bc2cppFiberFrame* root) {
  Bc2cppFiber* fiber = (Bc2cppFiber*)mrb_calloc(M, 1, sizeof(Bc2cppFiber));
  fiber->top = root;
  root->parent = nullptr;
  struct RData* data =
      mrb_data_object_alloc(M, M->object_class, fiber, &bc2cpp_fiber_type);
  // Fiber's instance type is MRB_TT_FIBER, which mrb_obj_alloc refuses for an
  // RData, so the object is made under Object and given its class here.
  data->c = mrb_define_class(M, "Fiber", M->object_class);
  mrb_value self = mrb_obj_value(data);
  bc2cpp_fiber_refresh(M, self, fiber);
  return self;
}

static bool bc2cpp_fiber_alive_p(mrb_state* M, mrb_value fiber) {
  Bc2cppFiber* f = bc2cpp_fiber_ptr(M, fiber);
  return f && f->top != nullptr;
}

struct Bc2cppRunArgs {
  mrb_value self;
  Bc2cppFiber* fiber;
  mrb_value resume;
  bool yielded;
};

// Runs steps until a frame yields or the last frame finishes. A frame that
// finishes hands its result to its parent as the parent's resume value.
static mrb_value bc2cpp_fiber_run(mrb_state* M, void* userdata) {
  Bc2cppRunArgs* args = (Bc2cppRunArgs*)userdata;
  Bc2cppFiber* fiber = args->fiber;
  mrb_value resume = args->resume;
  for (;;) {
    Bc2cppFiberFrame* frame = fiber->top;
    Bc2cppStepOut out = {BC2CPP_STEP_DONE, mrb_nil_value(), nullptr};
    frame->step(M, frame, resume, &out);
    switch (out.kind) {
      case BC2CPP_STEP_YIELD:
        args->yielded = true;
        bc2cpp_fiber_refresh(M, args->self, fiber);
        return out.value;
      case BC2CPP_STEP_CALL:
        out.callee->parent = frame;
        fiber->top = out.callee;
        resume = mrb_nil_value();
        break;
      case BC2CPP_STEP_DONE:
        fiber->top = frame->parent;
        bc2cpp_frame_free(M, frame);
        if (!fiber->top) {
          args->yielded = false;
          return out.value;
        }
        resume = out.value;
        break;
    }
  }
}

// Fiber#resume. Returns the yielded value, or the body's result once it
// finishes (alive? is then false). An exception in a step kills the fiber and
// propagates to the resumer, as it does for an mruby Fiber.
static mrb_value bc2cpp_fiber_resume(mrb_state* M,
                                     mrb_value self,
                                     mrb_value value) {
  Bc2cppFiber* fiber = bc2cpp_fiber_ptr(M, self);
  if (fiber->running)
    mrb_raise(M, bc2cpp_fiber_error_class(M),
              "attempt to resume the current fiber");
  if (!fiber->top)
    mrb_raise(M, bc2cpp_fiber_error_class(M), "dead fiber called");
  Bc2cppRunArgs args = {self, fiber, value, false};
  fiber->running = true;
  fiber->started = true;
  mrb_bool error = FALSE;
  mrb_value result = mrb_protect_error(M, bc2cpp_fiber_run, &args, &error);
  fiber->running = false;
  if (error) {
    bc2cpp_prologue.expect = nullptr;
    bc2cpp_prologue.frame = nullptr;
    bc2cpp_tail_yield.env = nullptr;
    bc2cpp_tail_yield.pending = false;
    bc2cpp_fiber_clear(M, fiber);
    mrb_exc_raise(M, result);
  }
  return result;
}

// A suspendable body called from code that is not inside a Fiber: it runs to
// completion, and a YIELD raises the FiberError an interpreted Fiber.yield
// outside a fiber raises.
static mrb_value bc2cpp_run_to_completion(mrb_state* M,
                                          Bc2cppFiberFrame* root,
                                          mrb_value first) {
  mrb_value fiber = bc2cpp_fiber_new(M, root);
  int arena = mrb_gc_arena_save(M);
  mrb_gc_protect(M, fiber);
  mrb_value result = bc2cpp_fiber_resume(M, fiber, first);
  if (bc2cpp_fiber_alive_p(M, fiber)) {
    Bc2cppFiber* f = bc2cpp_fiber_ptr(M, fiber);
    bc2cpp_fiber_clear(M, f);
    mrb_gc_arena_restore(M, arena);
    mrb_raise(M, bc2cpp_fiber_error_class(M), "can't yield from root fiber");
  }
  mrb_gc_arena_restore(M, arena);
  return result;
}

// The Ruby-visible surface: the class is `Fiber`, so a call site that names
// Fiber#resume or Fiber#alive? (the closed world lists that definer) reaches
// it. Both methods answer for a Bc2cppFiber and hand any other receiver (a
// Fiber made by mruby-fiber) to the method they replaced; a build without
// mruby-fiber has no other receiver.
inline mrb_func_t bc2cpp_fiber_orig_resume = nullptr;
inline mrb_func_t bc2cpp_fiber_orig_alive_p = nullptr;

static bool bc2cpp_fiber_own_p(mrb_value v) {
  return mrb_data_p(v) && DATA_TYPE(v) == &bc2cpp_fiber_type;
}

static mrb_value bc2cpp_fiber_m_resume(mrb_state* M, mrb_value self) {
  if (!bc2cpp_fiber_own_p(self)) {
    if (!bc2cpp_fiber_orig_resume)
      mrb_raise(M, mrb_class_get(M, "TypeError"), "not a fiber");
    return bc2cpp_fiber_orig_resume(M, self);
  }
  mrb_value value = mrb_nil_value();
  mrb_get_args(M, "|o", &value);
  return bc2cpp_fiber_resume(M, self, value);
}

static mrb_value bc2cpp_fiber_m_alive_p(mrb_state* M, mrb_value self) {
  if (!bc2cpp_fiber_own_p(self)) {
    if (!bc2cpp_fiber_orig_alive_p)
      mrb_raise(M, mrb_class_get(M, "TypeError"), "not a fiber");
    return bc2cpp_fiber_orig_alive_p(M, self);
  }
  return mrb_bool_value(bc2cpp_fiber_alive_p(M, self));
}

static mrb_func_t bc2cpp_fiber_cfunc(mrb_state* M,
                                     struct RClass* klass,
                                     const char* name) {
  mrb_method_t method =
      mrb_method_search_vm(M, &klass, mrb_intern_cstr(M, name));
  return !MRB_METHOD_UNDEF_P(method) && MRB_METHOD_CFUNC_P(method)
             ? MRB_METHOD_CFUNC(method)
             : nullptr;
}

static void bc2cpp_fiber_define(mrb_state* M) {
  struct RClass* klass = mrb_define_class(M, "Fiber", M->object_class);
  mrb_func_t resume = bc2cpp_fiber_cfunc(M, klass, "resume");
  if (resume == bc2cpp_fiber_m_resume)
    return;
  bc2cpp_fiber_orig_resume = resume;
  bc2cpp_fiber_orig_alive_p = bc2cpp_fiber_cfunc(M, klass, "alive?");
  mrb_define_method(M, klass, "resume", bc2cpp_fiber_m_resume, MRB_ARGS_OPT(1));
  mrb_define_method(M, klass, "alive?", bc2cpp_fiber_m_alive_p,
                    MRB_ARGS_NONE());
}

// The root frame of `Fiber.new { prologue; method(args) }`: the body is a
// compiled block whose last act is a call to `id`'s suspendable method. The
// first step runs the block with `id` armed; if the method's entry parked a
// frame, that frame is called and its result is the fiber's; otherwise the
// block ran to the end and its value is the result.
struct Bc2cppBlockBody {
  Bc2cppFiberFrame f;
  mrb_value proc;
  const char* id;
  int state;
};

static void bc2cpp_block_body_step(mrb_state* M,
                                   Bc2cppFiberFrame* base,
                                   mrb_value resume,
                                   Bc2cppStepOut* out) {
  Bc2cppBlockBody* body = (Bc2cppBlockBody*)base;
  if (body->state != 0) {
    out->kind = BC2CPP_STEP_DONE;
    out->value = resume;
    return;
  }
  body->state = 1;
  bc2cpp_prologue.expect = body->id;
  bc2cpp_prologue.frame = nullptr;
  mrb_value result = mrb_yield_argv(M, body->proc, 0, nullptr);
  bc2cpp_prologue.expect = nullptr;
  Bc2cppFiberFrame* callee = bc2cpp_prologue.frame;
  bc2cpp_prologue.frame = nullptr;
  if (callee) {
    out->kind = BC2CPP_STEP_CALL;
    out->callee = callee;
    return;
  }
  out->kind = BC2CPP_STEP_DONE;
  out->value = result;
}

static void bc2cpp_block_body_mark(mrb_state* M,
                                   Bc2cppFiberFrame* base,
                                   mrb_value refs) {
  bc2cpp_fiber_ref(M, refs, ((Bc2cppBlockBody*)base)->proc);
}

// `Fiber.new { ... }` of compiled code: a Bc2cppFiber whose root frame runs
// `proc` as above.
[[maybe_unused]] static mrb_value bc2cpp_fiber_new_body(mrb_state* M,
                                                        mrb_value proc,
                                                        const char* id) {
  bc2cpp_fiber_define(M);
  Bc2cppBlockBody* body =
      (Bc2cppBlockBody*)mrb_calloc(M, 1, sizeof(Bc2cppBlockBody));
  body->f.step = bc2cpp_block_body_step;
  body->f.mark = bc2cpp_block_body_mark;
  body->proc = proc;
  body->id = id;
  return bc2cpp_fiber_new(M, &body->f);
}
