// C++ Fiber runtime for compiled bc2cpp code: no mruby-fiber, no VM frame, no Fiber.yield call.
//
// A method that can suspend is compiled as a step function over a heap frame. A step runs until it
// finishes (DONE), suspends (YIELD) or needs another suspendable body to run first (CALL). The fiber
// owns a stack of frames; resuming runs the top frame's step and moves between frames as the steps ask.
// No C++ frame stays between a YIELD and the resumer, so nothing needs a VM frame to suspend across.
#pragma once

#include <mruby.h>
#include <mruby/class.h>
#include <mruby/data.h>
#include <mruby/error.h>
#include <mruby/string.h>
#include <mruby/variable.h>

enum Bc2cppStepKind { BC2CPP_STEP_DONE, BC2CPP_STEP_YIELD, BC2CPP_STEP_CALL };

struct Bc2cppFrame;

// What a step reports. DONE: `value` is the body's result. YIELD: `value` goes to the resumer. CALL: `callee` is
// a new frame (allocated with mrb_malloc, owned by the fiber from now on); its result is the next resume value.
struct Bc2cppStepOut {
  Bc2cppStepKind kind;
  mrb_value value;
  Bc2cppFrame* callee;
};

typedef void (*Bc2cppStepFn)(mrb_state* M, Bc2cppFrame* frame, mrb_value resume, Bc2cppStepOut* out);

// A frame is the first member of the body's own frame struct. `mark` marks every mrb_value the frame holds;
// `release` frees what the body's struct allocated besides itself (either may be null).
struct Bc2cppFrame {
  Bc2cppStepFn step;
  Bc2cppFrame* parent;
  void (*mark)(mrb_state* M, Bc2cppFrame* frame);
  void (*release)(mrb_state* M, Bc2cppFrame* frame);
};

struct Bc2cppFiber {
  Bc2cppFrame* top;
  bool running;
  bool started;
};

static void bc2cpp_frame_free(mrb_state* M, Bc2cppFrame* frame) {
  if (frame->release) frame->release(M, frame);
  mrb_free(M, frame);
}

static void bc2cpp_fiber_clear(mrb_state* M, Bc2cppFiber* fiber) {
  while (fiber->top) {
    Bc2cppFrame* frame = fiber->top;
    fiber->top = frame->parent;
    bc2cpp_frame_free(M, frame);
  }
}

static void bc2cpp_fiber_data_free(mrb_state* M, void* p) {
  Bc2cppFiber* fiber = (Bc2cppFiber*)p;
  if (!fiber) return;
  bc2cpp_fiber_clear(M, fiber);
  mrb_free(M, fiber);
}

static void bc2cpp_fiber_data_mark(mrb_state* M, struct RBasic* obj) {
  Bc2cppFiber* fiber = (Bc2cppFiber*)((struct RData*)obj)->data;
  if (!fiber) return;
  for (Bc2cppFrame* frame = fiber->top; frame; frame = frame->parent) {
    if (frame->mark) frame->mark(M, frame);
  }
}

static const mrb_data_type bc2cpp_fiber_type = {"Bc2cppFiber", bc2cpp_fiber_data_free};

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

// A fiber whose first step is `root`'s. The frame is owned by the fiber from now on.
static mrb_value bc2cpp_fiber_new(mrb_state* M, Bc2cppFrame* root) {
  Bc2cppFiber* fiber = (Bc2cppFiber*)mrb_calloc(M, 1, sizeof(Bc2cppFiber));
  fiber->top = root;
  root->parent = nullptr;
  struct RData* data = mrb_data_object_alloc(M, M->object_class, fiber, &bc2cpp_fiber_type);
  return mrb_obj_value(data);
}

static bool bc2cpp_fiber_alive_p(mrb_state* M, mrb_value fiber) {
  Bc2cppFiber* f = bc2cpp_fiber_ptr(M, fiber);
  return f && f->top != nullptr;
}

struct Bc2cppRunArgs {
  Bc2cppFiber* fiber;
  mrb_value resume;
  bool yielded;
};

// Runs steps until a frame yields or the last frame finishes. A frame that finishes hands its result to its parent
// as the parent's resume value.
static mrb_value bc2cpp_fiber_run(mrb_state* M, void* userdata) {
  Bc2cppRunArgs* args = (Bc2cppRunArgs*)userdata;
  Bc2cppFiber* fiber = args->fiber;
  mrb_value resume = args->resume;
  for (;;) {
    Bc2cppFrame* frame = fiber->top;
    Bc2cppStepOut out = {BC2CPP_STEP_DONE, mrb_nil_value(), nullptr};
    frame->step(M, frame, resume, &out);
    switch (out.kind) {
      case BC2CPP_STEP_YIELD:
        args->yielded = true;
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

// Fiber#resume. Returns the yielded value, or the body's result once it finishes (alive? is then false). An
// exception in a step kills the fiber and propagates to the resumer, as it does for an mruby Fiber.
static mrb_value bc2cpp_fiber_resume(mrb_state* M, mrb_value self, mrb_value value) {
  Bc2cppFiber* fiber = bc2cpp_fiber_ptr(M, self);
  if (fiber->running) mrb_raise(M, bc2cpp_fiber_error_class(M), "attempt to resume the current fiber");
  if (!fiber->top) mrb_raise(M, bc2cpp_fiber_error_class(M), "dead fiber called");
  Bc2cppRunArgs args = {fiber, value, false};
  fiber->running = true;
  fiber->started = true;
  mrb_bool error = FALSE;
  mrb_value result = mrb_protect_error(M, bc2cpp_fiber_run, &args, &error);
  fiber->running = false;
  if (error) {
    bc2cpp_fiber_clear(M, fiber);
    mrb_exc_raise(M, result);
  }
  return result;
}

// A suspendable body called from code that is not inside a Fiber: it runs to completion, and a YIELD raises the
// FiberError an interpreted Fiber.yield outside a fiber raises.
static mrb_value bc2cpp_run_to_completion(mrb_state* M, Bc2cppFrame* root, mrb_value first) {
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
