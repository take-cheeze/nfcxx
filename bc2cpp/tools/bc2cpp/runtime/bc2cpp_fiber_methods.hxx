// The part of the C++ Fiber runtime that wraps a resumable method's step
// function (codegen_resumable.rb) as a Bc2cppFiberFrame. Emitted into generated
// code after RESUMABLE_HELPERS, whose bc2cpp_resume_frame_* functions it uses;
// it is not standalone. A method step still keeps its registers in the old heap
// frame and returns that frame on suspension; this adapter maps that return
// onto DONE / YIELD, and calls a block from a block-call suspension directly,
// since a block that does not suspend needs no step of its own.
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
    if (!mrb_test(bc2cpp_resume_frame_block_call(M, result))) {
      out->kind = BC2CPP_STEP_YIELD;
      out->value = bc2cpp_resume_frame_value(M, result);
      return;
    }
    // A block-call suspension: call the block here. A block whose last act is
    // Fiber.yield (Bc2cppTailYield) hands its value back instead of calling
    // Fiber.yield, and the fiber yields it; the next resume value is the
    // block's result, which the step takes as its own resume value.
    mrb_value args = bc2cpp_resume_frame_value(M, result);
    mrb_value blk = bc2cpp_resume_frame_block(M, result);
    bc2cpp_tail_yield.pending = false;
    // BLOCK_STEP: a block compiled as a step carries a maker for its frame
    // (flag bit 2, the slot before the entry). The block runs as a frame of
    // this fiber (CALL), so its own Fiber.yield suspends it; its result is this
    // step's resume value when it finishes.
    if (mrb_proc_p(blk) && MRB_PROC_CFUNC_P(mrb_proc_ptr(blk))) {
      const struct REnv* step_env = MRB_PROC_ENV(mrb_proc_ptr(blk));
      mrb_int step_len = step_env ? MRB_ENV_LEN(step_env) : 0;
      if (step_len >= 3 && (mrb_integer(step_env->stack[step_len - 1]) & 4)) {
        Bc2cppBlockStepMaker maker =
            (Bc2cppBlockStepMaker)(uintptr_t)mrb_integer(
                step_env->stack[step_len - 3]);
        Bc2cppFiberFrame* callee = maker(M, (struct REnv*)step_env,
                                         RARRAY_LEN(args), RARRAY_PTR(args));
        if (callee) {
          out->kind = BC2CPP_STEP_CALL;
          out->callee = callee;
          return;
        }
      }
    }
    const struct REnv* blk_env = nullptr;
    if (mrb_proc_p(blk) && MRB_PROC_CFUNC_P(mrb_proc_ptr(blk)))
      blk_env = MRB_PROC_ENV(mrb_proc_ptr(blk));
    bc2cpp_tail_yield.env = blk_env;
    resume = mrb_yield_argv(M, blk, RARRAY_LEN(args), RARRAY_PTR(args));
    bc2cpp_tail_yield.env = nullptr;
    if (bc2cpp_tail_yield.pending) {
      bc2cpp_tail_yield.pending = false;
      out->kind = BC2CPP_STEP_YIELD;
      out->value = bc2cpp_tail_yield.value;
      return;
    }
  }
}

static void bc2cpp_method_frame_mark(mrb_state* M,
                                     Bc2cppFiberFrame* base,
                                     mrb_value refs) {
  Bc2cppMethodFrame* m = (Bc2cppMethodFrame*)base;
  bc2cpp_fiber_ref(M, refs, m->self);
  bc2cpp_fiber_ref(M, refs, m->frame);
}

[[maybe_unused]] static Bc2cppFiberFrame* bc2cpp_method_frame_new(
    mrb_state* M,
    Bc2cppMethodStep step,
    mrb_value self,
    mrb_value frame) {
  Bc2cppMethodFrame* m =
      (Bc2cppMethodFrame*)mrb_calloc(M, 1, sizeof(Bc2cppMethodFrame));
  m->f.step = bc2cpp_method_frame_step;
  m->f.mark = bc2cpp_method_frame_mark;
  m->self = self;
  m->frame = frame;
  m->step = step;
  return &m->f;
}

// `Fiber.new { ... }` whose body is a step (BLOCK_STEP): the fiber's root frame
// is the frame the body's maker makes.
[[maybe_unused]] static mrb_value bc2cpp_fiber_new_step(mrb_state* M,
                                                        mrb_value proc) {
  bc2cpp_fiber_define(M);
  const struct REnv* env = MRB_PROC_ENV(mrb_proc_ptr(proc));
  mrb_int len = env ? MRB_ENV_LEN(env) : 0;
  if (len < 3 || !(mrb_integer(env->stack[len - 1]) & 4))
    mrb_raise(M, mrb_class_get(M, "RuntimeError"),
              "bc2cpp: Fiber body has no step");
  Bc2cppBlockStepMaker maker =
      (Bc2cppBlockStepMaker)(uintptr_t)mrb_integer(env->stack[len - 3]);
  Bc2cppFiberFrame* root = maker(M, (struct REnv*)env, 0, nullptr);
  if (!root)
    mrb_raise(M, mrb_class_get(M, "RuntimeError"),
              "bc2cpp: Fiber body step did not make a frame");
  return bc2cpp_fiber_new(M, root);
}
