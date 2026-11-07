// catch and throw as frames of the C++ Fiber: mruby's throw finds the catch by
// walking the VM's call stack, which cannot see a fiber's C++ frames. A `catch`
// whose block has a step is a frame that CALLs the block; a `throw` of its tag
// from the same fiber unwinds to it. Anything else keeps mruby's own (the
// dispatchers decline with undef). Emitted after bc2cpp_fiber_methods.hxx
// (bc2cpp_block_call, the dynamic-call registry); not standalone.
#pragma once

struct Bc2cppCatchFrame {
  Bc2cppFiberFrame f;
  mrb_value tag;
  mrb_value blk;
  int state;
};

static void bc2cpp_catch_mark(mrb_state* M,
                              Bc2cppFiberFrame* base,
                              mrb_value refs) {
  Bc2cppCatchFrame* c = (Bc2cppCatchFrame*)base;
  bc2cpp_fiber_ref(M, refs, c->tag);
  bc2cpp_fiber_ref(M, refs, c->blk);
}

// The first step calls the block with the tag; a block that does not finish
// there (a step, or ending in Fiber.yield) hands the fiber a CALL or YIELD, and
// its value comes back as the resume value, which is the catch's result.
static void bc2cpp_catch_step(mrb_state* M,
                              Bc2cppFiberFrame* base,
                              mrb_value resume,
                              Bc2cppStepOut* out) {
  Bc2cppCatchFrame* c = (Bc2cppCatchFrame*)base;
  if (c->state == 1) {
    out->kind = BC2CPP_STEP_DONE;
    out->value = resume;
    return;
  }
  c->state = 1;
  mrb_value value;
  if (bc2cpp_block_call(M, c->blk, 1, &c->tag, out, &value)) {
    out->kind = BC2CPP_STEP_DONE;
    out->value = value;
  }
}

// A `throw` names the catch frame by itself.
static struct RBasic* bc2cpp_catch_identity(Bc2cppFiberFrame* frame) {
  return (struct RBasic*)frame;
}

static mrb_value bc2cpp_catch_dyn(mrb_state* M,
                                  mrb_value,
                                  mrb_int argc,
                                  const mrb_value* argv,
                                  mrb_value blk) {
  // A block without a step cannot suspend: mruby's catch runs it.
  if (!mrb_proc_p(blk) || !MRB_PROC_CFUNC_P(mrb_proc_ptr(blk)) ||
      !bc2cpp_block_has_step(mrb_proc_ptr(blk),
                             MRB_PROC_ENV(mrb_proc_ptr(blk))))
    return mrb_undef_value();
  Bc2cppCatchFrame* c = bc2cpp_frame_alloc<Bc2cppCatchFrame>(
      M, bc2cpp_catch_step, bc2cpp_catch_mark);
  c->f.identity = bc2cpp_catch_identity;
  c->tag = argc > 0 ? argv[0] : mrb_obj_new(M, M->object_class, 0, nullptr);
  c->blk = blk;
  bc2cpp_prologue_park(M, &c->f);
  return mrb_nil_value();
}

struct Bc2cppThrowFrame {
  Bc2cppFiberFrame f;
  struct RBasic* catcher;
  mrb_value value;
};

static void bc2cpp_throw_mark(mrb_state* M,
                              Bc2cppFiberFrame* base,
                              mrb_value refs) {
  bc2cpp_fiber_ref(M, refs, ((Bc2cppThrowFrame*)base)->value);
}

static void bc2cpp_throw_step(mrb_state*,
                              Bc2cppFiberFrame* base,
                              mrb_value,
                              Bc2cppStepOut* out) {
  Bc2cppThrowFrame* t = (Bc2cppThrowFrame*)base;
  out->kind = BC2CPP_STEP_UNWIND;
  out->value = t->value;
  out->target = t->catcher;
  out->to_return = true;
}

static mrb_value bc2cpp_throw_dyn(mrb_state* M,
                                  mrb_value,
                                  mrb_int argc,
                                  const mrb_value* argv,
                                  mrb_value) {
  if (argc < 1 || !bc2cpp_current_fiber.in)
    return mrb_undef_value();
  Bc2cppFiber* fiber = bc2cpp_fiber_ptr(M, bc2cpp_current_fiber.fiber);
  for (Bc2cppFiberFrame* f = fiber ? fiber->top : nullptr; f; f = f->parent) {
    if (f->step == bc2cpp_catch_step &&
        mrb_obj_eq(M, ((Bc2cppCatchFrame*)f)->tag, argv[0])) {
      Bc2cppThrowFrame* t = bc2cpp_frame_alloc<Bc2cppThrowFrame>(
          M, bc2cpp_throw_step, bc2cpp_throw_mark);
      t->catcher = (struct RBasic*)f;
      t->value = argc > 1 ? argv[1] : mrb_nil_value();
      bc2cpp_prologue_park(M, &t->f);
      return mrb_nil_value();
    }
  }
  return mrb_undef_value();  // no catch in this fiber: mruby's throw decides
}

// Registers the dispatchers under mruby's Kernel#catch (a bytecode method, so
// keyed by its proc) and Kernel#throw (a C function).
[[maybe_unused]] static void bc2cpp_catch_builtins(mrb_state* M) {
  struct RClass* kernel = M->kernel_module;
  struct RClass* found = kernel;
  mrb_method_t method =
      mrb_method_search_vm(M, &found, mrb_intern_lit(M, "catch"));
  if (!MRB_METHOD_UNDEF_P(method) && MRB_METHOD_PROC_P(method) &&
      !MRB_PROC_CFUNC_P(MRB_METHOD_PROC(method)))
    bc2cpp_dyn_register((void*)MRB_METHOD_PROC(method), bc2cpp_catch_dyn, 0, 1);
  mrb_func_t throw_func = bc2cpp_fiber_cfunc(M, kernel, "throw");
  if (throw_func)
    bc2cpp_dyn_register((void*)throw_func, bc2cpp_throw_dyn, 1, 2);
}
