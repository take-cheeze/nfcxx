// The part of the C++ Fiber runtime that wraps a resumable method's step
// function (codegen_resumable.rb) as a Bc2cppFiberFrame. Emitted into generated
// code after RESUMABLE_HELPERS, whose bc2cpp_resume_frame_* functions it uses;
// it is not standalone. A method step still keeps its registers in the old heap
// frame and returns that frame on suspension; this adapter maps that return
// onto DONE / YIELD, and calls a block from a block-call suspension directly,
// since a block that does not suspend needs no step of its own.
#pragma once

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
    if (!mrb_test(bc2cpp_resume_frame_block_call(M, result))) {
      out->kind = BC2CPP_STEP_YIELD;
      out->value = bc2cpp_resume_frame_value(M, result);
      return;
    }
    resume = bc2cpp_resumable_resume_from_c(M, result);
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
