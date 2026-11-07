// C++ Fiber runtime for compiled bc2cpp code: no mruby-fiber, no VM frame. A
// method that can suspend is a step function over a heap frame; the fiber owns
// a stack of frames, so no C++ frame stays between a YIELD and the resumer.
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
#include <utility>

// The fiber runtime is in this translation unit (bc2cpp_owner_call's guard asks
// bc2cpp_fiber_definer_p).
#define BC2CPP_FIBER_RUNTIME 1

enum Bc2cppStepKind {
  BC2CPP_STEP_DONE,
  BC2CPP_STEP_YIELD,
  BC2CPP_STEP_CALL,
  BC2CPP_STEP_UNWIND
};

struct Bc2cppFiberFrame;

// What a step reports. DONE: `value` is the result. YIELD: `value` goes to the
// resumer. CALL: `callee` is a new fiber-owned (mrb_malloc'd) frame whose
// result is the next resume value. UNWIND (`break`/`return` out of a block
// step): frames above `target` are dropped; with `to_return` it finishes with
// `value`, else resumes with `value` as its call's result.
struct Bc2cppStepOut {
  Bc2cppStepKind kind;
  mrb_value value;
  Bc2cppFiberFrame* callee;
  struct RBasic* target;
  bool to_return;
};

typedef void (*Bc2cppStepFn)(mrb_state* M,
                             Bc2cppFiberFrame* frame,
                             mrb_value resume,
                             Bc2cppStepOut* out);
typedef void (*Bc2cppMarkFn)(mrb_state* M,
                             Bc2cppFiberFrame* frame,
                             mrb_value refs);

// A frame is the first member of the body's own frame struct. `mark` marks
// every mrb_value the frame holds; `release` frees what the body's struct
// allocated besides itself (either may be null).
struct Bc2cppFiberFrame {
  Bc2cppStepFn step;
  Bc2cppFiberFrame* parent;
  Bc2cppMarkFn mark;
  void (*release)(mrb_state* M, Bc2cppFiberFrame* frame);
  // The object an UNWIND names this frame by, or null when it cannot be one.
  struct RBasic* (*identity)(Bc2cppFiberFrame* frame);
  // An exception (or unwind) reaches this frame from above: true when it takes
  // it (the step is re-entered with it raised where it suspended); null or
  // false drops the frame.
  bool (*unwind_into)(mrb_state* M, Bc2cppFiberFrame* frame, mrb_value exc);
  // Whether the step has rescue/ensure handlers that run when something unwinds
  // through it; an UNWIND then travels as an exception.
  bool (*has_handlers)(Bc2cppFiberFrame* frame);
};

// A frame of type T (whose first member `f` is the Bc2cppFiberFrame), zeroed.
template <class T>
static T* bc2cpp_frame_alloc(mrb_state* M,
                             Bc2cppStepFn step,
                             Bc2cppMarkFn mark) {
  T* frame = (T*)mrb_calloc(M, 1, sizeof(T));
  frame->f.step = step;
  frame->f.mark = mark;
  return frame;
}

struct Bc2cppFiber {
  Bc2cppFiberFrame* top;
  // on the resume chain: executing, or waiting on a fiber it resumed
  bool running;
  bool started;
  // the run in progress was entered by a transfer
  bool by_transfer;
  // suspended by a transfer away (not by Fiber.yield)
  bool transferred;
  // on the chain, waiting on a fiber it transferred to (mruby: TRANSFERRED)
  bool waiting_transfer;
  // the main context's stand-in (bc2cpp_root_fiber): no frames, always alive
  bool root;
  // the C++ Fiber whose resume/transfer runs this one, or nil (root or mruby)
  mrb_value caller;
};

// The handoff between a Fiber body and the suspendable method it ends with: the
// body's first step arms the method's id (`Owner#name`) and runs its prologue;
// the method's entry, seeing its id armed, parks its frame in `frame` and
// returns, and the fiber calls that frame.
struct Bc2cppPrologue {
  const char* expect;
  mrb_value recv;
  Bc2cppFiberFrame* frame;
};
inline Bc2cppPrologue bc2cpp_prologue = {nullptr, {}, nullptr};

// `id` is the entry's own "Owner#name". An armed "Owner#name" matches exactly;
// an armed "#name" (explicit receiver of unproven class) matches any owner's
// `name`, but only on the receiver the call site stored
// (bc2cpp_prologue_set_recv).
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

// An Array in a global: raw values only C++ holds (the GC does not see them)
// need a root.
static mrb_value bc2cpp_rooted_array(mrb_state* M, const char* name) {
  mrb_sym key = mrb_intern_cstr(M, name);
  mrb_value ary = mrb_gv_get(M, key);
  if (!mrb_array_p(ary)) {
    ary = mrb_ary_new(M);
    mrb_gv_set(M, key, ary);
  }
  return ary;
}

// A parked frame is held only by C++ until its fiber's refs are rebuilt, and
// the arena protecting its objects is popped, so its values are pinned here
// until the next refresh.
static mrb_value bc2cpp_pins(mrb_state* M) {
  return bc2cpp_rooted_array(M, "$__bc2cpp_pins");
}

static void bc2cpp_unpin(mrb_state* M) {
  mrb_ary_clear(M, bc2cpp_pins(M));
}

[[maybe_unused]] static mrb_value bc2cpp_prologue_park(
    mrb_state* M,
    Bc2cppFiberFrame* frame) {
  bc2cpp_prologue.expect = nullptr;
  bc2cpp_prologue.frame = frame;
  if (frame->mark)
    frame->mark(M, frame, bc2cpp_pins(M));
  return mrb_nil_value();
}

// A block whose last act is `Fiber.yield v` hands `v` to the C++ Fiber by
// returning (nothing is left to resume). The adapter names the block's env
// here; the block's entry (Bc2cppTailYieldScope) then stores `v` in `value` and
// returns, and the adapter makes it a YIELD. `can_yield` is true only inside
// that one entry; any other call takes the ordinary Fiber.yield.
struct Bc2cppTailYield {
  const struct REnv* env;
  bool pending;
  mrb_value value;
};
inline Bc2cppTailYield bc2cpp_tail_yield = {nullptr, false, {}};
inline bool bc2cpp_block_can_yield = false;

struct Bc2cppTailYieldScope {
  bool previous;
  explicit Bc2cppTailYieldScope(const struct REnv* env)
      : previous(bc2cpp_block_can_yield) {
    bc2cpp_block_can_yield = env && bc2cpp_tail_yield.env == env;
    if (bc2cpp_block_can_yield)
      bc2cpp_tail_yield.env = nullptr;
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

static void bc2cpp_fiber_pop(mrb_state* M, Bc2cppFiber* fiber) {
  Bc2cppFiberFrame* frame = fiber->top;
  fiber->top = frame->parent;
  bc2cpp_frame_free(M, frame);
}

static void bc2cpp_fiber_clear(mrb_state* M, Bc2cppFiber* fiber) {
  while (fiber->top)
    bc2cpp_fiber_pop(M, fiber);
}

static void bc2cpp_fiber_data_free(mrb_state* M, void* p) {
  Bc2cppFiber* fiber = (Bc2cppFiber*)p;
  if (!fiber)
    return;
  bc2cpp_fiber_clear(M, fiber);
  mrb_free(M, fiber);
}

// mruby has no mark callback for a data object, so the fiber carries a hidden
// Array of the values its frames hold (added with bc2cpp_fiber_ref), rebuilt
// after every step.
static void bc2cpp_fiber_ref(mrb_state* M, mrb_value refs, mrb_value v) {
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

static void bc2cpp_fiber_error(mrb_state* M, const char* msg) {
  mrb_raise(M, bc2cpp_fiber_error_class(M), msg);
}

static Bc2cppFiber* bc2cpp_fiber_ptr(mrb_state* M, mrb_value fiber) {
  return (Bc2cppFiber*)mrb_data_get_ptr(M, fiber, &bc2cpp_fiber_type);
}

// Fiber's instance type is MRB_TT_FIBER, which mrb_obj_alloc refuses for an
// RData, so the object is made under Object and given its class here.
static mrb_value bc2cpp_fiber_object(mrb_state* M, Bc2cppFiber** out) {
  Bc2cppFiber* fiber = (Bc2cppFiber*)mrb_calloc(M, 1, sizeof(Bc2cppFiber));
  fiber->caller = mrb_nil_value();
  struct RData* data =
      mrb_data_object_alloc(M, M->object_class, fiber, &bc2cpp_fiber_type);
  data->c = mrb_define_class(M, "Fiber", M->object_class);
  *out = fiber;
  return mrb_obj_value(data);
}

// A fiber whose first step is `root`'s. The frame is owned by the fiber from
// now on.
static mrb_value bc2cpp_fiber_new(mrb_state* M, Bc2cppFiberFrame* root) {
  Bc2cppFiber* fiber;
  mrb_value self = bc2cpp_fiber_object(M, &fiber);
  fiber->top = root;
  root->parent = nullptr;
  bc2cpp_fiber_refresh(M, self, fiber);
  return self;
}

static bool bc2cpp_fiber_alive_p(mrb_state* M, mrb_value fiber) {
  Bc2cppFiber* f = bc2cpp_fiber_ptr(M, fiber);
  return f && (f->root || f->top != nullptr);
}

// The object Fiber.current answers at the root when mruby-fiber is not there to
// supply one; it is rooted in a global because only C++ holds it.
static mrb_value bc2cpp_root_fiber(mrb_state* M) {
  mrb_sym key = mrb_intern_lit(M, "$__bc2cpp_root_fiber");
  mrb_value root = mrb_gv_get(M, key);
  if (mrb_nil_p(root)) {
    Bc2cppFiber* fiber;
    root = bc2cpp_fiber_object(M, &fiber);
    fiber->root = true;
    fiber->started = true;
    mrb_gv_set(M, key, root);
  }
  return root;
}

// Set by a `transfer` site that turns into a yield, read when the step reports
// YIELD: the fiber is then suspended by a transfer, not by Fiber.yield.
inline bool bc2cpp_transfer_yielding = false;

struct Bc2cppRunArgs {
  mrb_value self;
  Bc2cppFiber* fiber;
  mrb_value resume;
  mrb_value
      result;  // the fiber's result when an unwind finished its last frame
};

static mrb_value bc2cpp_iv(mrb_state* M, mrb_value obj, const char* name) {
  return mrb_iv_get(M, obj, mrb_intern_cstr(M, name));
}

static void bc2cpp_iv_set(mrb_state* M,
                          mrb_value obj,
                          const char* name,
                          mrb_value v) {
  mrb_iv_set(M, obj, mrb_intern_cstr(M, name), v);
}

// A break, return or throw passing frames with handlers travels as an exception
// of this class (no `rescue` clause matches it: RESCUE tests bc2cpp_unwind_p),
// so ensure bodies run and re-raise it. It names the frame it ends by identity.
static struct RClass* bc2cpp_unwind_class(mrb_state* M) {
  return mrb_define_class(M, "Bc2cppUnwind", M->eException_class);
}

static bool bc2cpp_unwind_p(mrb_state* M, mrb_value v) {
  return !mrb_immediate_p(v) &&
         mrb_obj_is_kind_of(M, v, bc2cpp_unwind_class(M));
}

static mrb_value bc2cpp_unwind_new(mrb_state* M,
                                   struct RBasic* target,
                                   mrb_value value,
                                   bool to_return) {
  mrb_value u = mrb_obj_new(M, bc2cpp_unwind_class(M), 0, nullptr);
  bc2cpp_iv_set(M, u, "__target__", mrb_cptr_value(M, target));
  bc2cpp_iv_set(M, u, "__value__", value);
  bc2cpp_iv_set(M, u, "__return__", mrb_bool_value(to_return));
  bc2cpp_iv_set(M, u, "__ran__", mrb_false_value());
  return u;
}

// STEP_EXIT_JUMPS: a return, break or jump leaving a begin/ensure region of a
// step is parked in one of these while the ensure body runs; it stands in for
// the exception EXCEPT captures (RAISEIF finds it) and is never raised. `site`
// is the leaving instruction's address, `value` what it carries, `target` a
// jump's address (-1: none).
static struct RClass* bc2cpp_exit_class(mrb_state* M) {
  return mrb_define_class(M, "Bc2cppExit", M->eException_class);
}

[[maybe_unused]] static mrb_value bc2cpp_exit_new(mrb_state* M,
                                                  mrb_int site,
                                                  mrb_value value,
                                                  mrb_int target) {
  mrb_value e = mrb_obj_new(M, bc2cpp_exit_class(M), 0, nullptr);
  bc2cpp_iv_set(M, e, "__site__", mrb_int_value(M, site));
  bc2cpp_iv_set(M, e, "__value__", value);
  bc2cpp_iv_set(M, e, "__target__", mrb_int_value(M, target));
  return e;
}

[[maybe_unused]] static bool bc2cpp_exit_p(mrb_state* M, mrb_value v) {
  return !mrb_immediate_p(v) && mrb_obj_is_kind_of(M, v, bc2cpp_exit_class(M));
}

[[maybe_unused]] static mrb_int bc2cpp_exit_site(mrb_state* M, mrb_value e) {
  return mrb_integer(bc2cpp_iv(M, e, "__site__"));
}

[[maybe_unused]] static mrb_int bc2cpp_exit_target(mrb_state* M, mrb_value e) {
  return mrb_integer(bc2cpp_iv(M, e, "__target__"));
}

[[maybe_unused]] static mrb_value bc2cpp_exit_value(mrb_state* M, mrb_value e) {
  return bc2cpp_iv(M, e, "__value__");
}

static bool bc2cpp_frame_is(Bc2cppFiberFrame* frame, const void* target) {
  return frame->identity && (const void*)frame->identity(frame) == target;
}

// A step reported UNWIND: drop the frames above the target, then resume it (a
// `break`) or drop it too (a `return`). A frame with handlers on the way sends
// the unwind up as an exception instead, so they run.
static void bc2cpp_fiber_unwind_to(mrb_state* M,
                                   Bc2cppFiber* fiber,
                                   const Bc2cppStepOut& out) {
  Bc2cppFiberFrame* frame = fiber->top;
  for (Bc2cppFiberFrame* f = frame; f; f = f->parent) {
    if (f->has_handlers && f->has_handlers(f))
      mrb_exc_raise(M,
                    bc2cpp_unwind_new(M, out.target, out.value, out.to_return));
    if (bc2cpp_frame_is(f, out.target))
      break;
  }
  Bc2cppFiberFrame* target = frame;
  while (target && !bc2cpp_frame_is(target, out.target)) {
    Bc2cppFiberFrame* up = target->parent;
    if (target != frame)
      bc2cpp_frame_free(M, target);
    target = up;
  }
  if (!target) {
    fiber->top = nullptr;
    bc2cpp_frame_free(M, frame);
    mrb_raise(M, mrb_class_get(M, "RuntimeError"),
              "bc2cpp: break or return target is not on the fiber stack");
  }
  fiber->top = out.to_return ? target->parent : target;
  if (out.to_return && target != frame)
    bc2cpp_frame_free(M, target);
  bc2cpp_frame_free(M, frame);
}

// Runs steps until a frame yields or the last frame finishes. A frame that
// finishes hands its result to its parent as the parent's resume value.
static mrb_value bc2cpp_fiber_run(mrb_state* M, void* userdata) {
  Bc2cppRunArgs* args = (Bc2cppRunArgs*)userdata;
  Bc2cppFiber* fiber = args->fiber;
  mrb_value resume = args->resume;
  for (;;) {
    Bc2cppFiberFrame* frame = fiber->top;
    Bc2cppStepOut out = {BC2CPP_STEP_DONE, mrb_nil_value(), nullptr, nullptr,
                         false};
    frame->step(M, frame, resume, &out);
    switch (out.kind) {
      case BC2CPP_STEP_YIELD: {
        bool by_transfer_site = bc2cpp_transfer_yielding;
        bc2cpp_transfer_yielding = false;
        // A fiber entered by a transfer cannot Fiber.yield: nothing resumed it.
        if (fiber->by_transfer && !by_transfer_site)
          bc2cpp_fiber_error(M, "attempt to yield on a not resumed fiber");
        fiber->transferred = by_transfer_site;
        bc2cpp_fiber_refresh(M, args->self, fiber);
        bc2cpp_unpin(M);
        return out.value;
      }
      case BC2CPP_STEP_CALL:
        out.callee->parent = frame;
        fiber->top = out.callee;
        resume = mrb_nil_value();
        continue;
      case BC2CPP_STEP_UNWIND:
        bc2cpp_fiber_unwind_to(M, fiber, out);
        break;
      case BC2CPP_STEP_DONE:
        bc2cpp_fiber_pop(M, fiber);
        break;
    }
    if (!fiber->top) {
      bc2cpp_unpin(M);
      return out.value;
    }
    resume = out.value;
  }
}

// The C++ Fiber being resumed (Fiber.current inside it); `in` is false at the
// root, where Fiber.current is mruby-fiber's. One shared object across all
// translation units, restored when a resume ends (also by an exception).
struct Bc2cppCurrentFiber {
  bool in;
  mrb_value fiber;
  struct mrb_context* ctx;  // M->c when it was resumed
};
inline Bc2cppCurrentFiber bc2cpp_current_fiber = {false, {}, nullptr};

static bool bc2cpp_fiber_current_p(mrb_state* M, mrb_value fiber) {
  return bc2cpp_current_fiber.in &&
         mrb_obj_eq(M, bc2cpp_current_fiber.fiber, fiber);
}

// What the first resume was given: an Array of its arguments (resume(1, 2) is
// [1, 2]), or nil when the fiber is resumed from C. A body that takes block
// parameters binds them from it (Bc2cppBodyStart).
inline mrb_value bc2cpp_first_args = {};
inline bool bc2cpp_first_args_set = false;

enum {
  BC2CPP_UNWIND_NONE,      // no frame takes it: it leaves the fiber
  BC2CPP_UNWIND_CONTINUE,  // run the fiber on (args->resume says with what)
  BC2CPP_UNWIND_FINISHED   // the last frame finished: args->result
};

// An exception (or unwind) left the step of fiber->top: frames are dropped from
// the top until one takes it. An unwind ends at its target: a `break` resumes
// it with the value, a `return` or throw runs its handlers, then finishes it.
static int bc2cpp_fiber_unwind(mrb_state* M,
                               Bc2cppFiber* fiber,
                               mrb_value exc,
                               Bc2cppRunArgs* args) {
  bool is_unwind = bc2cpp_unwind_p(M, exc);
  while (fiber->top) {
    Bc2cppFiberFrame* frame = fiber->top;
    bool ends_here =
        is_unwind &&
        bc2cpp_frame_is(frame, mrb_cptr(bc2cpp_iv(M, exc, "__target__")));
    mrb_value value =
        ends_here ? bc2cpp_iv(M, exc, "__value__") : mrb_nil_value();
    if (ends_here && !mrb_test(bc2cpp_iv(M, exc, "__return__"))) {
      args->resume = value;
      return BC2CPP_UNWIND_CONTINUE;
    }
    // The target's own handlers get one go at the unwind.
    bool offer = !ends_here || !mrb_test(bc2cpp_iv(M, exc, "__ran__"));
    if (ends_here && offer)
      bc2cpp_iv_set(M, exc, "__ran__", mrb_true_value());
    if (offer && frame->unwind_into && frame->unwind_into(M, frame, exc)) {
      args->resume = exc;
      return BC2CPP_UNWIND_CONTINUE;
    }
    bc2cpp_fiber_pop(M, fiber);
    if (ends_here) {
      if (!fiber->top) {
        args->result = value;
        return BC2CPP_UNWIND_FINISHED;
      }
      args->resume = value;
      return BC2CPP_UNWIND_CONTINUE;
    }
  }
  return BC2CPP_UNWIND_NONE;
}

static bool bc2cpp_fiber_own_p(mrb_value v);

// The fibers on the resume chain, in a rooted global Array:
// bc2cpp_current_fiber and Bc2cppFiber::caller are raw values the GC does not
// see.
static mrb_value bc2cpp_running_fibers(mrb_state* M) {
  return bc2cpp_rooted_array(M, "$__bc2cpp_running");
}

// Fiber#resume / #transfer: the yielded value, or the body's result once
// finished. An exception in a step kills the fiber and reaches the resumer; the
// FiberError cases and messages are mruby-fiber's. FIBER_RAISE: `raise_exc` is
// raised where the fiber is suspended; the fiber runs on if a frame takes it,
// else it is dead and the exception leaves Fiber#raise.
static mrb_value bc2cpp_fiber_resume(mrb_state* M,
                                     mrb_value self,
                                     mrb_value value,
                                     bool transfer = false,
                                     const mrb_value* raise_exc = nullptr) {
  Bc2cppFiber* fiber = bc2cpp_fiber_ptr(M, self);
  const char* busy =
      transfer ? "attempt to transfer to a resuming fiber" : "double resume";
  if (fiber->root) {
    // A transfer from a fiber back to its resumer is compiled as a yield
    // (bc2cpp_transfer_is_yield), so what reaches here is at the root itself,
    // or a fiber whose resumer is not the root.
    if (bc2cpp_current_fiber.in)
      bc2cpp_fiber_error(M, busy);
    if (transfer)
      return value;
    bc2cpp_fiber_error(M, "attempt to resume the current fiber");
  }
  if (bc2cpp_fiber_current_p(M, self)) {
    if (transfer)
      return value;
    bc2cpp_fiber_error(M, "attempt to resume the current fiber");
  }
  if (!transfer && (fiber->transferred || fiber->waiting_transfer))
    bc2cpp_fiber_error(M, "resuming transferred fiber");
  if (fiber->running)
    bc2cpp_fiber_error(M, busy);
  if (!fiber->top)
    bc2cpp_fiber_error(M, "resuming dead fiber");
  Bc2cppRunArgs args = {self, fiber, value, mrb_nil_value()};
  fiber->running = true;
  fiber->started = true;
  fiber->by_transfer = transfer;
  fiber->transferred = false;
  Bc2cppCurrentFiber outer = bc2cpp_current_fiber;
  fiber->caller = outer.in ? outer.fiber : mrb_nil_value();
  Bc2cppFiber* waiting = outer.in ? bc2cpp_fiber_ptr(M, outer.fiber) : nullptr;
  if (waiting)
    waiting->waiting_transfer = transfer;
  bc2cpp_current_fiber = {true, self, M->c};
  mrb_ary_push(M, bc2cpp_running_fibers(M), self);
  // With `raise_exc` the first round is the exception where the fiber is
  // suspended, so it goes the way one raised by the top step goes.
  mrb_bool error = raise_exc != nullptr;
  mrb_value result = error ? *raise_exc : mrb_nil_value();
  for (;;) {
    if (!error)
      result = mrb_protect_error(M, bc2cpp_fiber_run, &args, &error);
    if (!error)
      break;
    // An exception: the nearest frame with a handler for it takes it, and the
    // fiber runs on from there; with none it kills the fiber.
    int taken = bc2cpp_fiber_unwind(M, fiber, result, &args);
    if (taken == BC2CPP_UNWIND_CONTINUE) {
      error = FALSE;
      continue;
    }
    if (taken == BC2CPP_UNWIND_FINISHED) {
      error = FALSE;
      result = args.result;
    }
    break;
  }
  mrb_ary_pop(M, bc2cpp_running_fibers(M));
  bc2cpp_current_fiber = outer;
  if (waiting)
    waiting->waiting_transfer = false;
  bc2cpp_first_args_set = false;
  fiber->running = false;
  fiber->by_transfer = false;
  fiber->caller = mrb_nil_value();
  if (error) {
    bc2cpp_prologue.expect = nullptr;
    bc2cpp_prologue.frame = nullptr;
    bc2cpp_tail_yield.env = nullptr;
    bc2cpp_tail_yield.pending = false;
    bc2cpp_transfer_yielding = false;
    bc2cpp_fiber_clear(M, fiber);
    mrb_exc_raise(M, result);
  }
  return result;
}

// A `transfer` site in a step: is it a yield? The receiver is the root fiber or
// an mruby fiber (the fiber's resumer when it was resumed from outside any C++
// Fiber), or the C++ Fiber whose resume/transfer runs this one.
[[maybe_unused]] static bool bc2cpp_transfer_is_yield(mrb_state* M,
                                                      mrb_value recv) {
  if (!bc2cpp_current_fiber.in)
    return false;
  Bc2cppFiber* me = bc2cpp_fiber_ptr(M, bc2cpp_current_fiber.fiber);
  if (!me)
    return false;
  if (bc2cpp_fiber_own_p(recv)) {
    Bc2cppFiber* target = bc2cpp_fiber_ptr(M, recv);
    if (target && target->root)
      return mrb_nil_p(me->caller);
    return mrb_obj_eq(M, recv, me->caller);
  }
  return mrb_type(recv) == MRB_TT_FIBER && mrb_nil_p(me->caller);
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
    bc2cpp_fiber_clear(M, bc2cpp_fiber_ptr(M, fiber));
    mrb_gc_arena_restore(M, arena);
    bc2cpp_fiber_error(M, "can't yield from root fiber");
  }
  mrb_gc_arena_restore(M, arena);
  return result;
}

// A suspendable method entered from C: a frame its step CALLs runs to its end
// here. A YIELD inside is a yield across a C frame, so it goes to Fiber.yield,
// which raises the FiberError; if it returns, the value goes back in.
static mrb_value bc2cpp_run_callee_from_c(mrb_state* M,
                                          Bc2cppFiberFrame* callee) {
  mrb_value fiber = bc2cpp_fiber_new(M, callee);
  int arena = mrb_gc_arena_save(M);
  mrb_gc_protect(M, fiber);
  mrb_value result = bc2cpp_fiber_resume(M, fiber, mrb_nil_value());
  while (bc2cpp_fiber_alive_p(M, fiber)) {
    mrb_value resumed = mrb_funcall(M, mrb_obj_value(mrb_class_get(M, "Fiber")),
                                    "yield", 1, result);
    result = bc2cpp_fiber_resume(M, fiber, resumed);
  }
  mrb_gc_arena_restore(M, arena);
  return result;
}

// The Ruby-visible surface: the class is `Fiber`, so a call site naming
// Fiber#resume or Fiber#alive? reaches it. Each answers for a Bc2cppFiber and
// hands any other receiver to the method it replaced.
inline mrb_func_t bc2cpp_fiber_orig_resume = nullptr;
inline mrb_func_t bc2cpp_fiber_orig_transfer = nullptr;
inline mrb_func_t bc2cpp_fiber_orig_alive_p = nullptr;
inline mrb_func_t bc2cpp_fiber_orig_current = nullptr;

static bool bc2cpp_fiber_own_p(mrb_value v) {
  return mrb_data_p(v) && DATA_TYPE(v) == &bc2cpp_fiber_type;
}

static mrb_value bc2cpp_fiber_delegate(mrb_state* M,
                                       mrb_value self,
                                       mrb_func_t orig) {
  if (!orig)
    mrb_raise(M, mrb_class_get(M, "TypeError"), "not a fiber");
  return orig(M, self);
}

// resume(a, b) hands the fiber [a, b] (what its Fiber.yield returns, or its
// block parameters on the first resume); one argument is itself, none is nil.
// A transfer from inside back to its resumer is compiled as a yield instead
// (bc2cpp_transfer_is_yield).
static mrb_value bc2cpp_fiber_enter(mrb_state* M,
                                    mrb_value self,
                                    mrb_func_t orig,
                                    bool transfer) {
  if (!bc2cpp_fiber_own_p(self))
    return bc2cpp_fiber_delegate(M, self, orig);
  const mrb_value* argv;
  mrb_int argc;
  mrb_get_args(M, "*", &argv, &argc);
  mrb_value value = argc == 0   ? mrb_nil_value()
                    : argc == 1 ? argv[0]
                                : mrb_ary_new_from_values(M, argc, argv);
  if (!bc2cpp_fiber_ptr(M, self)->started) {
    bc2cpp_first_args = mrb_ary_new_from_values(M, argc, argv);
    bc2cpp_first_args_set = true;
  }
  return bc2cpp_fiber_resume(M, self, value, transfer);
}

static mrb_value bc2cpp_fiber_m_resume(mrb_state* M, mrb_value self) {
  return bc2cpp_fiber_enter(M, self, bc2cpp_fiber_orig_resume, false);
}

static mrb_value bc2cpp_fiber_m_transfer(mrb_state* M, mrb_value self) {
  return bc2cpp_fiber_enter(M, self, bc2cpp_fiber_orig_transfer, true);
}

// Fiber.current: the C++ Fiber being resumed, else the root fiber mruby-fiber
// answers with.
static mrb_value bc2cpp_fiber_s_current(mrb_state* M, mrb_value self) {
  if (bc2cpp_current_fiber.in)
    return bc2cpp_current_fiber.fiber;
  if (!bc2cpp_fiber_orig_current)
    return bc2cpp_root_fiber(M);
  return bc2cpp_fiber_orig_current(M, self);
}

extern "C" mrb_value mrb_make_exception(mrb_state*, mrb_value, mrb_value);

// Fiber#raise(...) with Kernel#raise's arguments. mruby-fiber has no
// Fiber#raise, so without this the call reaches the private Kernel#raise.
static mrb_value bc2cpp_fiber_exception(mrb_state* M,
                                        mrb_int argc,
                                        const mrb_value* argv) {
  if (argc > 2)
    mrb_argnum_error(M, argc, 0, 2);
  switch (argc) {
    case 0:
      return mrb_exc_new_str(M, mrb_class_get(M, "RuntimeError"),
                             mrb_str_new_lit(M, ""));
    case 1:
      if (mrb_string_p(argv[0]))
        return mrb_make_exception(
            M, mrb_obj_value(mrb_class_get(M, "RuntimeError")), argv[0]);
      return mrb_make_exception(M, argv[0], mrb_nil_value());
    default:
      return mrb_make_exception(M, argv[0], argv[1]);
  }
}

// An exception raised where a C++ Fiber is suspended; the cases are CRuby's:
// the current fiber just raises it, a fiber waiting on one it resumed forwards
// it to the running fiber, an unborn fiber has no such point, a dead one is not
// resumed.
static mrb_value bc2cpp_fiber_m_raise(mrb_state* M, mrb_value self) {
  const mrb_value* argv;
  mrb_int argc;
  mrb_get_args(M, "*", &argv, &argc);
  if (!bc2cpp_fiber_own_p(self))
    mrb_raise(M, mrb_class_get(M, "NoMethodError"),
              "Fiber#raise is only defined for a fiber of compiled code");
  mrb_value exc = bc2cpp_fiber_exception(M, argc, argv);
  Bc2cppFiber* fiber = bc2cpp_fiber_ptr(M, self);
  if (fiber->root || bc2cpp_fiber_current_p(M, self) || fiber->running)
    mrb_exc_raise(M, exc);
  if (!fiber->started)
    bc2cpp_fiber_error(M, "cannot raise exception on unborn fiber");
  // A fiber suspended by a transfer away is continued by a transfer.
  return bc2cpp_fiber_resume(M, self, mrb_nil_value(), fiber->transferred,
                             &exc);
}

// FIBER_RAISE: Fiber#raise is installed at run time and no source of the closed
// world lists its definer (listing it would give `raise` a second definer in
// every build), so bc2cpp_owner_call's guard accepts exactly this C function as
// a definer. So do the Fiber.yield definers (see bc2cpp_fiber_define).
static mrb_value bc2cpp_fiber_s_yield(mrb_state* M, mrb_value self);
static mrb_value bc2cpp_fiber_s_yield_wrapped(mrb_state* M, mrb_value self);
[[maybe_unused]] static bool bc2cpp_fiber_definer_p(const mrb_method_t& m) {
  return MRB_METHOD_CFUNC_P(m) &&
         (MRB_METHOD_CFUNC(m) == bc2cpp_fiber_m_raise ||
          MRB_METHOD_CFUNC(m) == bc2cpp_fiber_s_yield ||
          MRB_METHOD_CFUNC(m) == bc2cpp_fiber_s_yield_wrapped);
}

static mrb_value bc2cpp_fiber_m_alive_p(mrb_state* M, mrb_value self) {
  if (!bc2cpp_fiber_own_p(self))
    return bc2cpp_fiber_delegate(M, self, bc2cpp_fiber_orig_alive_p);
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

// Fiber.yield from code that is not a step of a C++ Fiber: a yield across a C
// frame (inside a Fiber) or outside any fiber. Defined only when mruby-fiber is
// not there to answer it with the same errors.
static mrb_value bc2cpp_fiber_s_yield(mrb_state* M, mrb_value) {
  bc2cpp_fiber_error(M, bc2cpp_current_fiber.in
                            ? "can't cross C function boundary"
                            : "attempt to yield on a not resumed fiber");
  return mrb_nil_value();
}

// With mruby-fiber, a Fiber.yield that reaches it from a C++ Fiber's own
// context ran in a block called from C, which mruby-fiber would report as a C
// function boundary.
static mrb_func_t bc2cpp_fiber_orig_yield = nullptr;
static mrb_value bc2cpp_fiber_s_yield_wrapped(mrb_state* M, mrb_value self) {
  if (bc2cpp_current_fiber.in && bc2cpp_current_fiber.ctx == M->c)
    bc2cpp_fiber_error(M, "can't cross C function boundary");
  return bc2cpp_fiber_orig_yield(M, self);
}

static void bc2cpp_fiber_define(mrb_state* M) {
  struct RClass* klass = mrb_define_class(M, "Fiber", M->object_class);
  mrb_func_t resume = bc2cpp_fiber_cfunc(M, klass, "resume");
  if (resume == bc2cpp_fiber_m_resume)
    return;
  // Without mruby-fiber the runtime is the whole Fiber: its error class and
  // Fiber.yield come from here.
  if (!mrb_const_defined_at(M, mrb_obj_value(M->object_class),
                            mrb_intern_lit(M, "FiberError")))
    mrb_define_class(M, "FiberError", M->eStandardError_class);
  struct RClass* meta = mrb_singleton_class_ptr(M, mrb_obj_value(klass));
  bc2cpp_fiber_orig_yield = bc2cpp_fiber_cfunc(M, meta, "yield");
  mrb_define_class_method(M, klass, "yield",
                          bc2cpp_fiber_orig_yield ? bc2cpp_fiber_s_yield_wrapped
                                                  : bc2cpp_fiber_s_yield,
                          MRB_ARGS_ANY());
  bc2cpp_fiber_orig_resume = resume;
  bc2cpp_fiber_orig_alive_p = bc2cpp_fiber_cfunc(M, klass, "alive?");
  bc2cpp_fiber_orig_transfer = bc2cpp_fiber_cfunc(M, klass, "transfer");
  bc2cpp_fiber_orig_current = bc2cpp_fiber_cfunc(M, meta, "current");
  mrb_define_class_method(M, klass, "current", bc2cpp_fiber_s_current,
                          MRB_ARGS_NONE());
  mrb_define_method(M, klass, "resume", bc2cpp_fiber_m_resume, MRB_ARGS_ANY());
  mrb_define_method(M, klass, "transfer", bc2cpp_fiber_m_transfer,
                    MRB_ARGS_ANY());
  mrb_define_method(M, klass, "alive?", bc2cpp_fiber_m_alive_p,
                    MRB_ARGS_NONE());
  mrb_define_method(M, klass, "raise", bc2cpp_fiber_m_raise, MRB_ARGS_ANY());
}

// The root frame of `Fiber.new { prologue; method(args) }`: the first step runs
// the block with `id` armed; if the method's entry parked a frame, it is called
// and its result is the fiber's, else the block's value is.
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
  Bc2cppBlockBody* body = bc2cpp_frame_alloc<Bc2cppBlockBody>(
      M, bc2cpp_block_body_step, bc2cpp_block_body_mark);
  body->proc = proc;
  body->id = id;
  return bc2cpp_fiber_new(M, &body->f);
}
