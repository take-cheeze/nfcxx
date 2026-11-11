// Array#sort! with a block, as a frame of the C++ Fiber: mruby's own sort is C,
// so a Fiber.yield in the comparison block could not cross it. The algorithms
// and comparison order are array.c's (insertion sort up to 16 elements, heap
// sort above), so a block sees the same calls; each comparison is a
// bc2cpp_block_call and may suspend. Emitted after bc2cpp_fiber_methods.hxx,
// whose bc2cpp_block_call and dynamic-call registry it uses; not standalone.
#pragma once

enum {
  SORT_INSERT_NEXT,
  SORT_INSERT_CMP,
  SORT_INSERT_RESULT,
  SORT_HEAP_BUILD,
  SORT_HEAP_EXTRACT,
  SORT_HEAPIFY,
  SORT_HEAPIFY_CHILD,  // compare child `child` (left, then right) with `max`
  SORT_HEAPIFY_CHILD_RESULT,
  SORT_HEAPIFY_DONE
};

struct Bc2cppSortFrame {
  Bc2cppFiberFrame f;
  mrb_value ary;
  mrb_value blk;
  mrb_value key;    // the insertion sort's element in hand
  mrb_value* base;  // the array's storage and length when a comparison began
  mrb_int len;
  mrb_int n;
  mrb_int i, j;  // insertion: outer and inner index; heap: outer index
  mrb_int index, size, max, child;  // heapify
  int state;
  int after_heapify;  // SORT_HEAP_BUILD or SORT_HEAP_EXTRACT
};

static void bc2cpp_sort_mark(mrb_state* M,
                             Bc2cppFiberFrame* base,
                             mrb_value refs) {
  Bc2cppSortFrame* s = (Bc2cppSortFrame*)base;
  bc2cpp_fiber_ref(M, refs, s->ary);
  bc2cpp_fiber_ref(M, refs, s->blk);
  bc2cpp_fiber_ref(M, refs, s->key);
}

// sort_cmp's decision on the block's value: is the left element greater.
static bool bc2cpp_sort_decide(mrb_state* M, Bc2cppSortFrame* s, mrb_value c) {
  if (mrb_nil_p(c) || !mrb_fixnum_p(c))
    mrb_raise(M, mrb_class_get(M, "ArgumentError"), "comparison failed");
  if (RARRAY_PTR(s->ary) != s->base || RARRAY_LEN(s->ary) != s->len)
    mrb_raise(M, mrb_class_get(M, "RuntimeError"),
              "array modified during sort");
  return mrb_fixnum(c) > 0;
}

// Begins comparing a with b. True with the block's value in *c when it ended
// here; false with *out set when the fiber has to act first (the value then
// comes back as the next resume value).
static bool bc2cpp_sort_compare(mrb_state* M,
                                Bc2cppSortFrame* s,
                                mrb_value a,
                                mrb_value b,
                                Bc2cppStepOut* out,
                                mrb_value* c) {
  s->base = RARRAY_PTR(s->ary);
  s->len = RARRAY_LEN(s->ary);
  mrb_value args[2] = {a, b};
  return bc2cpp_block_call(M, s->blk, 2, args, out, c);
}

static void bc2cpp_sort_step(mrb_state* M,
                             Bc2cppFiberFrame* base,
                             mrb_value resume,
                             Bc2cppStepOut* out) {
  Bc2cppSortFrame* s = (Bc2cppSortFrame*)base;
  mrb_value* a = RARRAY_PTR(s->ary);
  for (;;) {
    switch (s->state) {
      case SORT_INSERT_NEXT:
        if (s->i >= s->n) {
          out->kind = BC2CPP_STEP_DONE;
          out->value = s->ary;
          return;
        }
        s->key = a[s->i];
        s->j = s->i - 1;
        s->state = SORT_INSERT_CMP;
        break;
      case SORT_INSERT_CMP:
        if (s->j < 0) {
          a[s->j + 1] = s->key;
          s->i++;
          s->state = SORT_INSERT_NEXT;
          break;
        }
        s->state = SORT_INSERT_RESULT;
        if (!bc2cpp_sort_compare(M, s, a[s->j], s->key, out, &resume))
          return;
        break;
      case SORT_INSERT_RESULT:
        if (bc2cpp_sort_decide(M, s, resume)) {
          a[s->j + 1] = a[s->j];
          s->j--;
          s->state = SORT_INSERT_CMP;
        } else {
          a[s->j + 1] = s->key;
          s->i++;
          s->state = SORT_INSERT_NEXT;
        }
        break;
      case SORT_HEAP_BUILD:
        if (s->i < 0) {
          s->i = s->n - 1;
          s->state = SORT_HEAP_EXTRACT;
          break;
        }
        s->index = s->i;
        s->size = s->n;
        s->after_heapify = SORT_HEAP_BUILD;
        s->state = SORT_HEAPIFY;
        break;
      case SORT_HEAP_EXTRACT:
        if (s->i <= 0) {
          out->kind = BC2CPP_STEP_DONE;
          out->value = s->ary;
          return;
        }
        std::swap(a[0], a[s->i]);
        s->index = 0;
        s->size = s->i;
        s->after_heapify = SORT_HEAP_EXTRACT;
        s->state = SORT_HEAPIFY;
        break;
      case SORT_HEAPIFY:
        s->max = s->index;
        s->child = 2 * s->index + 1;
        s->state = SORT_HEAPIFY_CHILD;
        break;
      case SORT_HEAPIFY_CHILD:
        // Past the heap's end, or past the right child: heapify is done.
        if (s->child >= s->size || s->child > 2 * s->index + 2) {
          s->state = SORT_HEAPIFY_DONE;
          break;
        }
        s->state = SORT_HEAPIFY_CHILD_RESULT;
        if (!bc2cpp_sort_compare(M, s, a[s->child], a[s->max], out, &resume))
          return;
        break;
      case SORT_HEAPIFY_CHILD_RESULT:
        if (bc2cpp_sort_decide(M, s, resume))
          s->max = s->child;
        s->child++;
        s->state = SORT_HEAPIFY_CHILD;
        break;
      case SORT_HEAPIFY_DONE:
        if (s->max == s->index) {
          s->i--;
          s->state = s->after_heapify;
        } else {
          std::swap(a[s->max], a[s->index]);
          s->index = s->max;
          s->state = SORT_HEAPIFY;
        }
        break;
    }
  }
}

static Bc2cppFiberFrame* bc2cpp_sort_frame_new(mrb_state* M,
                                               mrb_value ary,
                                               mrb_value blk) {
  Bc2cppSortFrame* s = bc2cpp_frame_alloc<Bc2cppSortFrame>(M, bc2cpp_sort_step,
                                                           bc2cpp_sort_mark);
  s->ary = ary;
  s->blk = blk;
  s->key = mrb_nil_value();
  s->n = RARRAY_LEN(ary);
  if (s->n <= 16) {
    s->state = SORT_INSERT_NEXT;
    s->i = 1;
  } else {
    s->state = SORT_HEAP_BUILD;
    s->i = s->n / 2 - 1;
  }
  return &s->f;
}

// The dispatcher for Array#sort! (registered under mruby's C function). It
// declines (undef) what needs no frame: no block, or fewer than two elements.
static mrb_value bc2cpp_sort_dyn(mrb_state* M,
                                 mrb_value self,
                                 mrb_int,
                                 const mrb_value*,
                                 mrb_value blk) {
  if (!mrb_array_p(self) || RARRAY_LEN(self) < 2 || mrb_nil_p(blk))
    return mrb_undef_value();
  mrb_ary_modify(M, mrb_ary_ptr(self));
  bc2cpp_prologue.frame = bc2cpp_sort_frame_new(M, self, blk);
  return mrb_nil_value();
}

// Registers the built-in dispatchers once the class is known.
[[maybe_unused]] static void bc2cpp_dyn_builtins(mrb_state* M) {
  static bool done = false;
  if (done)
    return;
  done = true;
  bc2cpp_catch_builtins(M);
  mrb_func_t sort_bang = bc2cpp_fiber_cfunc(M, M->array_class, "sort!");
  if (sort_bang)
    bc2cpp_dyn_register((void*)sort_bang, bc2cpp_sort_dyn, 0, 0);
}
