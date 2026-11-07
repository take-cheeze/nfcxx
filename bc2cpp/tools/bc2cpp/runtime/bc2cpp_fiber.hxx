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

enum Bc2cppStepKind {
  BC2CPP_STEP_DONE,
  BC2CPP_STEP_YIELD,
  BC2CPP_STEP_CALL,
  BC2CPP_STEP_UNWIND
};

struct Bc2cppFiberFrame;

// What a step reports. DONE: `value` is the body's result. YIELD: `value` goes
// to the resumer. CALL: `callee` is a new frame (allocated with mrb_malloc,
// owned by the fiber from now on); its result is the next resume value. UNWIND
// (a `break` or `return` out of a block step): the frames above the frame whose
// identity is `target` are dropped; with `to_return` that frame finishes with
// `value` too, else it is resumed with `value` as its call's result.
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

// A frame is the first member of the body's own frame struct. `mark` marks
// every mrb_value the frame holds; `release` frees what the body's struct
// allocated besides itself (either may be null).
struct Bc2cppFiberFrame {
  Bc2cppStepFn step;
  Bc2cppFiberFrame* parent;
  void (*mark)(mrb_state* M, Bc2cppFiberFrame* frame, mrb_value refs);
  void (*release)(mrb_state* M, Bc2cppFiberFrame* frame);
  // The object an UNWIND names this frame by (a method frame's heap frame), or
  // null when the frame cannot be a target.
  struct RBasic* (*identity)(Bc2cppFiberFrame* frame);
  // An exception (or a break/return/throw unwinding as one) reaches this frame
  // from a frame above it: true when the frame takes it, which re-enters its
  // step with the exception raised at the address it was suspended at. Null,
  // or false, and the frame is dropped.
  bool (*unwind_into)(mrb_state* M, Bc2cppFiberFrame* frame, mrb_value exc);
  // Whether the frame's step has handlers (rescue/ensure) that may run code
  // when something unwinds through it; an UNWIND then travels as an exception.
  bool (*has_handlers)(Bc2cppFiberFrame* frame);
};

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
  // the C++ Fiber whose resume/transfer runs this one, or nil (root or mruby)
  mrb_value caller;
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

// A parked frame is held only by C++ until its fiber's refs are rebuilt, and
// the arena that protected the objects it was made of is popped when the calls
// that made it return. Until the next refresh the frame's values are pinned in
// a global (rooted) Array.
static mrb_value bc2cpp_pins(mrb_state* M) {
  mrb_sym key = mrb_intern_lit(M, "$__bc2cpp_pins");
  mrb_value pins = mrb_gv_get(M, key);
  if (!mrb_array_p(pins)) {
    pins = mrb_ary_new(M);
    mrb_gv_set(M, key, pins);
  }
  return pins;
}

[[maybe_unused]] static void bc2cpp_unpin(mrb_state* M) {
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
  fiber->caller = mrb_nil_value();
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

// Set by a `transfer` site that turns into a yield (a transfer back to the
// fiber's resumer), read when the fiber's step reports the YIELD: the fiber is
// then suspended by a transfer, not by Fiber.yield.
inline bool bc2cpp_transfer_yielding = false;

struct Bc2cppRunArgs {
  mrb_value self;
  Bc2cppFiber* fiber;
  mrb_value resume;
  bool yielded;
  mrb_value
      result;  // the fiber's result when an unwind finished its last frame
};

// A break, return or throw that passes frames with handlers travels as an
// exception of this class (not a StandardError, and no `rescue` clause matches
// it: RESCUE tests bc2cpp_unwind_p), so the ensure bodies on the way run and
// re-raise it. It names the frame it ends by identity, as an UNWIND does.
static struct RClass* bc2cpp_unwind_class(mrb_state* M) {
  return mrb_define_class(M, "Bc2cppUnwind", M->eException_class);
}

[[maybe_unused]] static bool bc2cpp_unwind_p(mrb_state* M, mrb_value v) {
  return !mrb_immediate_p(v) &&
         mrb_obj_is_kind_of(M, v, bc2cpp_unwind_class(M));
}

static mrb_value bc2cpp_unwind_new(mrb_state* M,
                                   struct RBasic* target,
                                   mrb_value value,
                                   bool to_return) {
  mrb_value u = mrb_obj_new(M, bc2cpp_unwind_class(M), 0, nullptr);
  mrb_iv_set(M, u, mrb_intern_lit(M, "__target__"), mrb_cptr_value(M, target));
  mrb_iv_set(M, u, mrb_intern_lit(M, "__value__"), value);
  mrb_iv_set(M, u, mrb_intern_lit(M, "__return__"), mrb_bool_value(to_return));
  mrb_iv_set(M, u, mrb_intern_lit(M, "__ran__"), mrb_false_value());
  return u;
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
        if (fiber->by_transfer && !by_transfer_site) {
          mrb_raise(M, bc2cpp_fiber_error_class(M),
                    "attempt to yield on a not resumed fiber");
        }
        fiber->transferred = by_transfer_site;
        args->yielded = true;
        bc2cpp_fiber_refresh(M, args->self, fiber);
        bc2cpp_unpin(M);
        return out.value;
      }
      case BC2CPP_STEP_CALL:
        out.callee->parent = frame;
        fiber->top = out.callee;
        resume = mrb_nil_value();
        break;
      case BC2CPP_STEP_UNWIND: {
        // A frame with handlers on the way (up to the target) must run them:
        // the unwind then goes up as an exception.
        for (Bc2cppFiberFrame* f = frame; f; f = f->parent) {
          if (f->has_handlers && f->has_handlers(f))
            mrb_exc_raise(
                M, bc2cpp_unwind_new(M, out.target, out.value, out.to_return));
          if (f->identity && f->identity(f) == out.target)
            break;
        }
        Bc2cppFiberFrame* target = frame;
        while (target &&
               !(target->identity && target->identity(target) == out.target)) {
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
        if (out.to_return) {
          fiber->top = target->parent;
          if (target != frame)
            bc2cpp_frame_free(M, target);
          bc2cpp_frame_free(M, frame);
          if (!fiber->top) {
            args->yielded = false;
            bc2cpp_unpin(M);
            return out.value;
          }
          resume = out.value;
        } else {
          fiber->top = target;
          bc2cpp_frame_free(M, frame);
          resume = out.value;
        }
        break;
      }
      case BC2CPP_STEP_DONE:
        fiber->top = frame->parent;
        bc2cpp_frame_free(M, frame);
        if (!fiber->top) {
          args->yielded = false;
          bc2cpp_unpin(M);
          return out.value;
        }
        resume = out.value;
        break;
    }
  }
}

// The C++ Fiber being resumed (Fiber.current inside it); `in` is false at the
// root, where Fiber.current is mruby-fiber's. One shared object across all
// translation units, restored when a resume ends (also by an exception).
struct Bc2cppCurrentFiber {
  bool in;
  mrb_value fiber;
};
inline Bc2cppCurrentFiber bc2cpp_current_fiber = {false, {}};

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

// An exception (or an unwind) left the step of fiber->top. Frames are dropped
// from the top until one takes it. An unwind ends at its target: a `break`
// resumes the target with the value (its call returns it), a `return` or a
// throw runs the target's own handlers, then finishes it with the value.
static int bc2cpp_fiber_unwind(mrb_state* M,
                               Bc2cppFiber* fiber,
                               mrb_value exc,
                               Bc2cppRunArgs* args) {
  bool is_unwind = bc2cpp_unwind_p(M, exc);
  while (fiber->top) {
    Bc2cppFiberFrame* frame = fiber->top;
    if (is_unwind && frame->identity &&
        (void*)frame->identity(frame) ==
            mrb_cptr(mrb_iv_get(M, exc, mrb_intern_lit(M, "__target__")))) {
      mrb_value value = mrb_iv_get(M, exc, mrb_intern_lit(M, "__value__"));
      if (!mrb_test(mrb_iv_get(M, exc, mrb_intern_lit(M, "__return__")))) {
        args->resume = value;
        return BC2CPP_UNWIND_CONTINUE;
      }
      if (!mrb_test(mrb_iv_get(M, exc, mrb_intern_lit(M, "__ran__")))) {
        mrb_iv_set(M, exc, mrb_intern_lit(M, "__ran__"), mrb_true_value());
        if (frame->unwind_into && frame->unwind_into(M, frame, exc)) {
          args->resume = exc;
          return BC2CPP_UNWIND_CONTINUE;
        }
      }
      fiber->top = frame->parent;
      bc2cpp_frame_free(M, frame);
      if (!fiber->top) {
        args->result = value;
        return BC2CPP_UNWIND_FINISHED;
      }
      args->resume = value;
      return BC2CPP_UNWIND_CONTINUE;
    }
    if (frame->unwind_into && frame->unwind_into(M, frame, exc)) {
      args->resume = exc;
      return BC2CPP_UNWIND_CONTINUE;
    }
    fiber->top = frame->parent;
    bc2cpp_frame_free(M, frame);
  }
  return BC2CPP_UNWIND_NONE;
}

static bool bc2cpp_fiber_own_p(mrb_value v);

// The fibers on the resume chain, kept in a rooted global Array:
// bc2cpp_current_fiber and Bc2cppFiber::caller are raw values the GC does not
// see, and the arena that protected the running fiber belongs to the C function
// that started it.
static mrb_value bc2cpp_running_fibers(mrb_state* M) {
  mrb_sym key = mrb_intern_lit(M, "$__bc2cpp_running");
  mrb_value running = mrb_gv_get(M, key);
  if (!mrb_array_p(running)) {
    running = mrb_ary_new(M);
    mrb_gv_set(M, key, running);
  }
  return running;
}

// Fiber#resume / Fiber#transfer. Returns the yielded value, or the body's
// result once it finishes (alive? is then false). An exception in a step kills
// the fiber and propagates to the resumer, as it does for an mruby Fiber. The
// FiberError cases and their messages are mruby-fiber's (fiber_switch /
// fiber_transfer).
static mrb_value bc2cpp_fiber_resume(mrb_state* M,
                                     mrb_value self,
                                     mrb_value value,
                                     bool transfer = false) {
  Bc2cppFiber* fiber = bc2cpp_fiber_ptr(M, self);
  bool current = bc2cpp_current_fiber.in &&
                 mrb_obj_eq(M, bc2cpp_current_fiber.fiber, self);
  if (transfer && current)
    return value;
  if (!transfer && current)
    mrb_raise(M, bc2cpp_fiber_error_class(M),
              "attempt to resume the current fiber");
  if (!transfer && (fiber->transferred || fiber->waiting_transfer))
    mrb_raise(M, bc2cpp_fiber_error_class(M), "resuming transferred fiber");
  if (fiber->running)
    mrb_raise(
        M, bc2cpp_fiber_error_class(M),
        transfer ? "attempt to transfer to a resuming fiber" : "double resume");
  if (!fiber->top)
    mrb_raise(M, bc2cpp_fiber_error_class(M), "resuming dead fiber");
  Bc2cppRunArgs args = {self, fiber, value, false, mrb_nil_value()};
  fiber->running = true;
  fiber->started = true;
  fiber->by_transfer = transfer;
  fiber->transferred = false;
  Bc2cppCurrentFiber outer = bc2cpp_current_fiber;
  fiber->caller = outer.in ? outer.fiber : mrb_nil_value();
  Bc2cppFiber* waiting = outer.in ? bc2cpp_fiber_ptr(M, outer.fiber) : nullptr;
  if (waiting)
    waiting->waiting_transfer = transfer;
  bc2cpp_current_fiber = {true, self};
  mrb_ary_push(M, bc2cpp_running_fibers(M), self);
  mrb_bool error = FALSE;
  mrb_value result;
  for (;;) {
    error = FALSE;
    result = mrb_protect_error(M, bc2cpp_fiber_run, &args, &error);
    if (!error)
      break;
    // An exception: the nearest frame with a handler for it takes it, and the
    // fiber runs on from there; with none it kills the fiber.
    int taken = bc2cpp_fiber_unwind(M, fiber, result, &args);
    if (taken == BC2CPP_UNWIND_CONTINUE)
      continue;
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
  if (bc2cpp_fiber_own_p(recv))
    return mrb_obj_eq(M, recv, me->caller);
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
    Bc2cppFiber* f = bc2cpp_fiber_ptr(M, fiber);
    bc2cpp_fiber_clear(M, f);
    mrb_gc_arena_restore(M, arena);
    mrb_raise(M, bc2cpp_fiber_error_class(M), "can't yield from root fiber");
  }
  mrb_gc_arena_restore(M, arena);
  return result;
}

// A suspendable method entered from C (interpreted code, the VM, a native
// iterator) rather than as a frame of a C++ Fiber: a frame its step CALLs runs
// to its end here. A YIELD inside it is a yield across a C frame, so it goes to
// Fiber.yield, which raises the FiberError an interpreted method would raise;
// if it returns (the frame can be resumed), the value goes back in.
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
  // resume(a, b) hands the fiber [a, b] (what its Fiber.yield returns, or its
  // block parameters on the first resume); one argument is itself, none is nil.
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
  return bc2cpp_fiber_resume(M, self, value);
}

inline mrb_func_t bc2cpp_fiber_orig_transfer = nullptr;

// Fiber#transfer to a C++ Fiber from outside it (the root, an mruby fiber, or
// another C++ Fiber's step): runs the target as resume does, with transfer's
// rules. A transfer from inside a C++ Fiber back to its resumer is a yield, and
// is compiled at the site (bc2cpp_transfer_is_yield).
static mrb_value bc2cpp_fiber_m_transfer(mrb_state* M, mrb_value self) {
  if (!bc2cpp_fiber_own_p(self)) {
    if (!bc2cpp_fiber_orig_transfer)
      mrb_raise(M, mrb_class_get(M, "TypeError"), "not a fiber");
    return bc2cpp_fiber_orig_transfer(M, self);
  }
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
  return bc2cpp_fiber_resume(M, self, value, true);
}

// Fiber.current: the C++ Fiber being resumed, else the root fiber mruby-fiber
// answers with.
inline mrb_func_t bc2cpp_fiber_orig_current = nullptr;

static mrb_value bc2cpp_fiber_s_current(mrb_state* M, mrb_value self) {
  if (bc2cpp_current_fiber.in)
    return bc2cpp_current_fiber.fiber;
  if (!bc2cpp_fiber_orig_current)
    return mrb_nil_value();
  return bc2cpp_fiber_orig_current(M, self);
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

// Fiber.yield from code that is not a step of a C++ Fiber: a yield across a C
// frame (inside a Fiber) or outside any fiber. Defined only when mruby-fiber is
// not there to answer it with the same errors.
static mrb_value bc2cpp_fiber_s_yield(mrb_state* M, mrb_value self) {
  mrb_raise(M, bc2cpp_fiber_error_class(M),
            bc2cpp_current_fiber.in
                ? "can't cross C function boundary"
                : "attempt to yield on a not resumed fiber");
  return mrb_nil_value();
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
  if (!bc2cpp_fiber_cfunc(M, mrb_singleton_class_ptr(M, mrb_obj_value(klass)),
                          "yield"))
    mrb_define_class_method(M, klass, "yield", bc2cpp_fiber_s_yield,
                            MRB_ARGS_ANY());
  bc2cpp_fiber_orig_resume = resume;
  bc2cpp_fiber_orig_alive_p = bc2cpp_fiber_cfunc(M, klass, "alive?");
  bc2cpp_fiber_orig_transfer = bc2cpp_fiber_cfunc(M, klass, "transfer");
  bc2cpp_fiber_orig_current = bc2cpp_fiber_cfunc(
      M, mrb_singleton_class_ptr(M, mrb_obj_value(klass)), "current");
  mrb_define_class_method(M, klass, "current", bc2cpp_fiber_s_current,
                          MRB_ARGS_NONE());
  mrb_define_method(M, klass, "resume", bc2cpp_fiber_m_resume, MRB_ARGS_ANY());
  mrb_define_method(M, klass, "transfer", bc2cpp_fiber_m_transfer,
                    MRB_ARGS_ANY());
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
