#!/usr/bin/env ruby
# frozen_string_literal: true

# CXX_FIBER: tools/bc2cpp/runtime/bc2cpp_fiber.hxx, the C++ Fiber of compiled bc2cpp code. Hand-written steps drive
# it with no mruby-fiber and no VM frame: yields, a nested call, the `each` + block shape Enumerator#next uses,
# a dead fiber, an exception in a step, and a GC between resumes.
#
#   BC2CPP_MRUBY_FULL=path/to/host-build ruby scripts/bc2cpp/cxx_fiber_check.rb
require 'tmpdir'
require 'open3'
require_relative 'check_support'

suite = FixtureCheck.new('cxx_fiber_check')
check = suite.method(:check)
root = ENV['BC2CPP_MRUBY_FULL']
unless root && File.file?(File.join(root, 'lib/libmruby.a'))
  puts 'SKIP cxx_fiber_check: set BC2CPP_MRUBY_FULL to a host mruby build'
  exit 0
end
cxx = ENV.fetch('CXX', 'clang++')
runtime = File.expand_path('../../tools/bc2cpp/runtime', __dir__)

TEST = <<~'CPP'
  #include <mruby.h>
  #include <mruby/error.h>
  // The two helpers the generator's preamble gives the runtime.
  static mrb_value bc2cpp_protect(mrb_state* M, mrb_value (*body)(mrb_state*, void*), void* ud, mrb_bool* error) {
    return mrb_protect_error(M, body, ud, error);
  }
  static void bc2cpp_root(mrb_state* M, mrb_value v) { mrb_gc_protect(M, v); }
  #include "bc2cpp_fiber.hxx"
  #include <mruby/array.h>
  #include <mruby/compile.h>
  #include <stdio.h>

  // A body that yields 1, 2, 3 and then finishes with 99.
  struct Count { Bc2cppFiberFrame f; int state; };
  static void count_step(mrb_state* M, Bc2cppFiberFrame* frame, mrb_value resume, Bc2cppStepOut* out) {
    Count* c = (Count*)frame;
    if (c->state < 3) { out->kind = BC2CPP_STEP_YIELD; out->value = mrb_fixnum_value(++c->state); return; }
    out->kind = BC2CPP_STEP_DONE; out->value = mrb_fixnum_value(99);
  }
  static Bc2cppFiberFrame* count_new(mrb_state* M) {
    Count* c = (Count*)mrb_calloc(M, 1, sizeof(Count));
    c->f.step = count_step;
    return &c->f;
  }

  // A child that yields twice and returns the sum of what it was resumed with.
  struct Child { Bc2cppFiberFrame f; int state; mrb_int sum; };
  static void child_step(mrb_state* M, Bc2cppFiberFrame* frame, mrb_value resume, Bc2cppStepOut* out) {
    Child* c = (Child*)frame;
    if (c->state > 0) c->sum += mrb_fixnum(resume);
    if (c->state < 2) { out->kind = BC2CPP_STEP_YIELD; out->value = mrb_fixnum_value(10 + c->state++); return; }
    out->kind = BC2CPP_STEP_DONE; out->value = mrb_fixnum_value(c->sum);
  }
  // A parent that calls the child and then yields the child's result.
  struct Parent { Bc2cppFiberFrame f; int state; };
  static void parent_step(mrb_state* M, Bc2cppFiberFrame* frame, mrb_value resume, Bc2cppStepOut* out) {
    Parent* p = (Parent*)frame;
    if (p->state == 0) {
      p->state = 1;
      Child* c = (Child*)mrb_calloc(M, 1, sizeof(Child));
      c->f.step = child_step;
      out->kind = BC2CPP_STEP_CALL; out->callee = &c->f; return;
    }
    if (p->state == 1) { p->state = 2; out->kind = BC2CPP_STEP_YIELD; out->value = resume; return; }
    out->kind = BC2CPP_STEP_DONE; out->value = mrb_fixnum_value(-1);
  }

  // Array#each with a block that yields each element (the Enumerator#next shape): each's frame calls the block's
  // frame for every element; the block's frame yields the element and returns what it is resumed with.
  struct Blk { Bc2cppFiberFrame f; int state; mrb_value elem; };
  static void blk_step(mrb_state* M, Bc2cppFiberFrame* frame, mrb_value resume, Bc2cppStepOut* out) {
    Blk* b = (Blk*)frame;
    if (b->state == 0) { b->state = 1; out->kind = BC2CPP_STEP_YIELD; out->value = b->elem; return; }
    out->kind = BC2CPP_STEP_DONE; out->value = resume;
  }
  static void blk_mark(mrb_state* M, Bc2cppFiberFrame* frame, mrb_value refs) { bc2cpp_fiber_ref(M, refs, ((Blk*)frame)->elem); }
  struct Each { Bc2cppFiberFrame f; int i; mrb_value ary; };
  static void each_mark(mrb_state* M, Bc2cppFiberFrame* frame, mrb_value refs) { bc2cpp_fiber_ref(M, refs, ((Each*)frame)->ary); }
  static void each_step(mrb_state* M, Bc2cppFiberFrame* frame, mrb_value resume, Bc2cppStepOut* out) {
    Each* e = (Each*)frame;
    if (e->i < RARRAY_LEN(e->ary)) {
      Blk* b = (Blk*)mrb_calloc(M, 1, sizeof(Blk));
      b->f.step = blk_step; b->f.mark = blk_mark;
      b->elem = mrb_ary_ref(M, e->ary, e->i++);
      out->kind = BC2CPP_STEP_CALL; out->callee = &b->f; return;
    }
    out->kind = BC2CPP_STEP_DONE; out->value = e->ary;
  }

  static void boom_step(mrb_state* M, Bc2cppFiberFrame* frame, mrb_value resume, Bc2cppStepOut* out) {
    mrb_raise(M, mrb_class_get(M, "RuntimeError"), "boom");
  }

  // Yields what it is resumed with (the first resume's value included), three times.
  struct Echo { Bc2cppFiberFrame f; int state; };
  static void echo_step(mrb_state* M, Bc2cppFiberFrame* frame, mrb_value resume, Bc2cppStepOut* out) {
    Echo* e = (Echo*)frame;
    if (e->state++ < 3) { out->kind = BC2CPP_STEP_YIELD; out->value = resume; return; }
    out->kind = BC2CPP_STEP_DONE; out->value = mrb_nil_value();
  }
  // Yields Fiber.current, the fiber it runs in.
  static void current_step(mrb_state* M, Bc2cppFiberFrame* frame, mrb_value resume, Bc2cppStepOut* out) {
    out->kind = BC2CPP_STEP_YIELD;
    out->value = mrb_funcall(M, mrb_obj_value(mrb_class_get(M, "Fiber")), "current", 0);
  }

  static void show(mrb_state* M, const char* label, mrb_value v) {
    mrb_value s = mrb_inspect(M, v);
    printf("%s %.*s\n", label, (int)RSTRING_LEN(s), RSTRING_PTR(s));
  }

  int main() {
    mrb_state* M = mrb_open();
    {
      mrb_value fib = bc2cpp_fiber_new(M, count_new(M));
      for (int i = 0; i < 4; ++i) show(M, "count", bc2cpp_fiber_resume(M, fib, mrb_nil_value()));
      printf("count alive %d\n", (int)bc2cpp_fiber_alive_p(M, fib));
      mrb_bool err = FALSE;
      struct Dead { static mrb_value call(mrb_state* M, void* p) { return bc2cpp_fiber_resume(M, *(mrb_value*)p, mrb_nil_value()); } };
      mrb_value fib2 = fib;
      mrb_protect_error(M, Dead::call, &fib2, &err);
      printf("dead resume raises %d\n", (int)err);
    }
    {
      Parent* p = (Parent*)mrb_calloc(M, 1, sizeof(Parent));
      p->f.step = parent_step;
      mrb_value fib = bc2cpp_fiber_new(M, &p->f);
      show(M, "nested", bc2cpp_fiber_resume(M, fib, mrb_nil_value()));      // child yields 10
      show(M, "nested", bc2cpp_fiber_resume(M, fib, mrb_fixnum_value(5)));  // child yields 11
      show(M, "nested", bc2cpp_fiber_resume(M, fib, mrb_fixnum_value(7)));  // child returns 12, parent yields it
      show(M, "nested", bc2cpp_fiber_resume(M, fib, mrb_nil_value()));      // parent finishes with -1
      printf("nested alive %d\n", (int)bc2cpp_fiber_alive_p(M, fib));
    }
    {
      mrb_value ary = mrb_ary_new(M);
      for (int i = 1; i <= 3; ++i) mrb_ary_push(M, ary, mrb_fixnum_value(i * 10));
      Each* e = (Each*)mrb_calloc(M, 1, sizeof(Each));
      e->f.step = each_step; e->f.mark = each_mark; e->ary = ary;
      mrb_value fib = bc2cpp_fiber_new(M, &e->f);
      for (int i = 0; i < 4; ++i) {
        mrb_full_gc(M);
        show(M, "each", bc2cpp_fiber_resume(M, fib, mrb_nil_value()));
      }
      printf("each alive %d\n", (int)bc2cpp_fiber_alive_p(M, fib));
    }
    {
      Bc2cppFiberFrame* boom = (Bc2cppFiberFrame*)mrb_calloc(M, 1, sizeof(Bc2cppFiberFrame));
      boom->step = boom_step;
      mrb_value fib = bc2cpp_fiber_new(M, boom);
      struct Run { static mrb_value call(mrb_state* M, void* p) { return bc2cpp_fiber_resume(M, *(mrb_value*)p, mrb_nil_value()); } };
      mrb_bool err = FALSE;
      mrb_value exc = mrb_protect_error(M, Run::call, &fib, &err);
      printf("boom raised %d dead %d\n", (int)err, (int)!bc2cpp_fiber_alive_p(M, fib));
      show(M, "boom", mrb_funcall(M, exc, "message", 0));
    }
    {
      mrb_value r = bc2cpp_run_to_completion(M, [&]{ Bc2cppFiberFrame* f = (Bc2cppFiberFrame*)mrb_calloc(M, 1, sizeof(Bc2cppFiberFrame)); f->step = [](mrb_state*, Bc2cppFiberFrame*, mrb_value, Bc2cppStepOut* o){ o->kind = BC2CPP_STEP_DONE; o->value = mrb_fixnum_value(7); }; return f; }(), mrb_nil_value());
      show(M, "to_completion", r);
      struct Y { static mrb_value call(mrb_state* M, void*) {
        return bc2cpp_run_to_completion(M, count_new(M), mrb_nil_value()); } };
      mrb_bool err = FALSE;
      mrb_protect_error(M, Y::call, nullptr, &err);
      printf("yield outside fiber raises %d\n", (int)err);
    }
    {
      bc2cpp_fiber_define(M);
      mrb_value fib = bc2cpp_fiber_new(M, count_new(M));
      mrb_gv_set(M, mrb_intern_lit(M, "$fib"), fib);
      show(M, "ruby", mrb_load_string(M, "a = [$fib.resume, $fib.resume(5), $fib.resume, $fib.resume]; a << $fib.alive?; a"));
      show(M, "ruby class", mrb_load_string(M, "$fib.class"));
      show(M, "mruby fiber", mrb_load_string(M, "f = Fiber.new { Fiber.yield 1; 2 }; r = [f.resume, f.alive?, f.resume]; r << f.alive?; r"));
    }
    {
      bc2cpp_fiber_define(M);
      Echo* e = (Echo*)mrb_calloc(M, 1, sizeof(Echo));
      e->f.step = echo_step;
      mrb_gv_set(M, mrb_intern_lit(M, "$echo"), bc2cpp_fiber_new(M, &e->f));
      show(M, "resume args", mrb_load_string(M, "[$echo.resume, $echo.resume(4), $echo.resume(5, 6)]"));
      Bc2cppFiberFrame* cur = (Bc2cppFiberFrame*)mrb_calloc(M, 1, sizeof(Bc2cppFiberFrame));
      cur->step = current_step;
      mrb_gv_set(M, mrb_intern_lit(M, "$cur"), bc2cpp_fiber_new(M, cur));
      show(M, "current", mrb_load_string(M, "[$cur.resume.equal?($cur), Fiber.current.equal?($cur)]"));
      Bc2cppFiberFrame* boom = (Bc2cppFiberFrame*)mrb_calloc(M, 1, sizeof(Bc2cppFiberFrame));
      boom->step = boom_step;
      mrb_gv_set(M, mrb_intern_lit(M, "$boom"), bc2cpp_fiber_new(M, boom));
      show(M, "after exception", mrb_load_string(M, "begin; $boom.resume; rescue => e; end; [e.message, $boom.alive?]"));
    }
    mrb_close(M);
    return 0;
  }
CPP

EXPECTED = <<~OUT
  count 1
  count 2
  count 3
  count 99
  count alive 0
  dead resume raises 1
  nested 10
  nested 11
  nested 12
  nested -1
  nested alive 0
  each 10
  each 20
  each 30
  each [10, 20, 30]
  each alive 0
  boom raised 1 dead 1
  boom "boom"
  to_completion 7
  yield outside fiber raises 1
  ruby [1, 2, 3, 99, false]
  ruby class Fiber
  mruby fiber [1, true, 2, false]
  resume args [nil, 4, [5, 6]]
  current [true, false]
  after exception ["boom", false]
OUT

Dir.mktmpdir('cxx_fiber') do |dir|
  File.write(File.join(dir, 'test.cpp'), TEST)
  bin = File.join(dir, 'test')
  out, status = Open3.capture2e(cxx, '-std=gnu++17', '-fno-rtti', '-I', runtime, '-I', File.join(root, 'include'),
                                File.join(dir, 'test.cpp'), File.join(root, 'lib/libmruby.a'), '-lm', '-o', bin)
  check.call('the runtime and the test compile and link', status.success?)
  abort out unless status.success?

  run, run_status = Open3.capture2e(bin)
  check.call('the test runs to the end', run_status.success?)
  EXPECTED.lines.each do |line|
    check.call(line.strip, run.lines.include?(line))
  end
  puts run unless EXPECTED.lines.all? { |line| run.lines.include?(line) }
end
suite.finish!
