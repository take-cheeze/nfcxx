# frozen_string_literal: true

require 'set'
require_relative 'irep'
require_relative 'native_names'
require_relative 'native_expression_devirt'

# NATIVE_CORE_DIRECT: exact-builtin-class arms that call a core
# native method's frame-independent body directly, the mruby-core counterpart of
# NativeDirect's RGSS entry points.
#
# A method is admitted only through a hand-audited entry below. The audit is
# re-run against the real sources on every compile (`audit`): the ROM
# registration must still bind `function` to `name` on `owner` with `aspec`, the
# registered function's body must still be the text the entry was written
# against, and any public API the expression names must still be declared
# MRB_API. An entry that no longer verifies is dropped, never trusted.
module NativeCoreDirect
  # tag/field are the instance type tag and MRB_state class field the guard
  # compares; an Integer is an immediate, so its type tag decides alone.
  OWNERS = {
    'Array' => { guard: 'mrb_array_p(%<r>s) && mrb_obj_ptr(%<r>s)->c == M->array_class' },
    'String' => { guard: 'mrb_string_p(%<r>s) && mrb_obj_ptr(%<r>s)->c == M->string_class' },
    'Integer' => { guard: 'mrb_integer_p(%<r>s)' },
    'Range' => { guard: 'mrb_range_p(%<r>s) && mrb_obj_ptr(%<r>s)->c == M->range_class' },
    # OWNER_ARM_ENTRIES only (below). A Float has no singleton class and no subclass instances.
    'Float' => { guard: 'mrb_float_p(%<r>s)' },
    'Hash' => { guard: 'mrb_hash_p(%<r>s) && mrb_obj_ptr(%<r>s)->c == M->hash_class' }
  }.freeze

  # A guard that keeps the C wrapper's argument coercion out of the fast path:
  # anything else takes the ordinary send, which raises what the wrapper would.
  ARG_GUARDS = {
    none: nil,
    integer: 'mrb_integer_p(%<a>s)',
    # 'A' only type-checks (mrb_ensure_array_type), so any Array passes through as is.
    array: 'mrb_array_p(%<a>s)',
    two_integers: 'mrb_integer_p(%<a>s) && mrb_integer_p(%<b>s)',
    # 'c' accepts exactly these (class_ptr_p); anything else raises TypeError through the send.
    class_or_module: '(mrb_class_p(%<a>s) || mrb_sclass_p(%<a>s) || mrb_module_p(%<a>s))',
    nil_or_string: '(mrb_nil_p(%<a>s) || mrb_string_p(%<a>s))',
    # cmpnum's two direct branches: fixnum against fixnum, or either against a Float. A heap Integer (word boxing)
    # or any other argument keeps the send.
    fixnum_or_float: '(mrb_fixnum_p(%<a>s) || mrb_float_p(%<a>s))'
  }.freeze

  # `checks` are [function, expected body, :exact | :prefix, optional file next to the
  # registration's]; the first is the registered function. Bodies are compared with
  # whitespace and comments removed. `internals` and `implicit_self` are KERNEL_ENTRIES' (below).
  # `recv_guard` narrows the receiver further, to the values the expression computes exactly (OWNER_ARM_ENTRIES).
  Entry = Struct.new(:name, :owner, :arity, :arg, :aspec, :expression, :checks, :apis, :helper, :internals,
                     :implicit_self, :explicit_receiver, :recv_guard, keyword_init: true) do
    def function
      checks.first.first
    end

    def guard(recv, argv)
      parts = [format(OWNERS.fetch(owner)[:guard], r: recv)]
      parts << format(recv_guard, r: recv) if recv_guard
      arg_guard = ARG_GUARDS.fetch(arg)
      parts << format(arg_guard, a: argv.first, b: argv[1]) if arg_guard
      parts.join(' && ')
    end

    def call(recv, argv)
      expression.gsub('recv', recv).gsub('ARG0', argv.first.to_s).gsub('ARG1', argv[1].to_s)
                .gsub('ARG2', argv[2].to_s).gsub('ARG3', argv[3].to_s)
    end
  end

  NUMERIC_CONVERSION_ENTRIES = [
    Entry.new(name: 'to_s', owner: 'Integer', arity: 0, arg: :none, aspec: 'MRB_ARGS_OPT(1)',
              expression: 'mrb_integer_to_str(M, recv, 10)',
              apis: [%w[mruby/numeric.h mrb_integer_to_str]],
              checks: [['int_to_s', <<~C, :exact]]),
                mrb_int base;
                if (mrb_get_argc(mrb) > 0) {
                  base = mrb_integer(mrb_get_arg1(mrb));
                }
                else {
                  base = 10;
                }
                return mrb_integer_to_str(mrb, self, base);
              C
    Entry.new(name: 'to_i', owner: 'Integer', arity: 0, arg: :none, aspec: 'MRB_ARGS_NONE()',
              expression: 'recv', apis: [],
              checks: [['mrb_obj_itself', 'return self;', :exact, 'object.c']]),
  ].freeze

  ARY_ROTATE_BANG = <<~C
    mrb_int count=1;
    mrb_get_args(mrb, "|i", &count);
    struct RArray *a = mrb_ary_ptr(self);
    mrb_int len = ARY_LEN(a);
    mrb_int idx;
    mrb_ary_modify(mrb, a);
    mrb_value *p = ARY_PTR(a);
    if (len == 0 || count == 0) return self;
    if (count == 1) {
      mrb_value v = p[0];
      for (mrb_int i=1; i<len; i++) {
        p[i-1] = p[i];
      }
      p[len-1] = v;
      return self;
    }
    if (count < 0) {
      idx = len - (~count % len) - 1;
    }
    else {
      idx = count % len;
    }
    rev(p, 0, len);
    rev(p, 0, len-idx);
    rev(p, len-idx, len);
    return self;
  C

  ARY_REV = <<~C
    static void
    rev(mrb_value *p, mrb_int beg, mrb_int end)
    {
      for (mrb_int i=beg,j=end-1; i<j; i++,j--) {
        mrb_value v = p[i];
        p[i] = p[j];
        p[j] = v;
      }
    }
  C

  HAND_ENTRIES = [
    Entry.new(name: 'join', owner: 'Array', arity: 0, arg: :none, aspec: 'MRB_ARGS_OPT(1)',
              expression: 'mrb_ary_join(M, recv, mrb_nil_value())',
              apis: [%w[mruby/array.h mrb_ary_join]],
              checks: [['mrb_ary_join_m', <<~C, :exact]]),
                mrb_value sep = mrb_nil_value();
                mrb_get_args(mrb, "|S!", &sep);
                return mrb_ary_join(mrb, ary, sep);
              C
    Entry.new(name: 'join', owner: 'Array', arity: 1, arg: :nil_or_string, aspec: 'MRB_ARGS_OPT(1)',
              expression: 'mrb_ary_join(M, recv, ARG0)',
              apis: [%w[mruby/array.h mrb_ary_join]],
              checks: [['mrb_ary_join_m', <<~C, :exact]]),
                mrb_value sep = mrb_nil_value();
                mrb_get_args(mrb, "|S!", &sep);
                return mrb_ary_join(mrb, ary, sep);
              C
    Entry.new(name: 'shift', owner: 'Array', arity: 0, arg: :none, aspec: 'MRB_ARGS_OPT(1)',
              expression: 'mrb_ary_shift(M, recv)',
              apis: [%w[mruby/array.h mrb_ary_shift]],
              checks: [['mrb_ary_shift_m', <<~C, :prefix]]),
                if (mrb_get_argc(mrb) == 0) {
                  return mrb_ary_shift(mrb, self);
                }
              C
    # Integer#inspect is int_to_s registered a second time; with no argument the
    # base is 10 and the body is mrb_integer_to_str.
    Entry.new(name: 'inspect', owner: 'Integer', arity: 0, arg: :none, aspec: 'MRB_ARGS_OPT(1)',
              expression: 'mrb_integer_to_str(M, recv, 10)',
              apis: [%w[mruby/numeric.h mrb_integer_to_str]],
              checks: [['int_to_s', <<~C, :exact]]),
                mrb_int base;
                if (mrb_get_argc(mrb) > 0) {
                  base = mrb_integer(mrb_get_arg1(mrb));
                }
                else {
                  base = 10;
                }
                return mrb_integer_to_str(mrb, self, base);
              C
    # The three below have static bodies, so the call is a mirror in
    # emit_native_core_helpers; its behavior is pinned by these bodies.
    Entry.new(name: 'compact', owner: 'Array', arity: 0, arg: :none, aspec: 'MRB_ARGS_NONE()',
              expression: 'bc2cpp_ary_compact(M, recv)', helper: 'bc2cpp_ary_compact',
              apis: [],
              checks: [['ary_compact', <<~C, :exact],
                mrb_value ary = mrb_ary_dup(mrb, self);
                ary_compact_bang(mrb, ary);
                return ary;
              C
                       ['ary_compact_bang', <<~C, :exact]]),
                struct RArray *a = mrb_ary_ptr(self);
                mrb_int i, j = 0;
                mrb_int len = ARY_LEN(a);
                mrb_ary_modify(mrb, a);
                mrb_value *ptr = RARRAY_PTR(self);
                for (i = 0; i < len; i++) {
                  if (!mrb_nil_p(ptr[i])) {
                    if (i != j) ptr[j] = ptr[i];
                    j++;
                  }
                }
                if (i == j) return mrb_nil_value();
                ARY_SET_LEN(RARRAY(self), j);
                return self;
              C
    # ary_rotate_bang and rev are static, so the call is a mirror in emit_native_core_helpers; "|i" on a fixnum (the
    # Integer guard) is mrb_integer, and the public mrb_ary_modify adds only a write barrier to the static ary_modify.
    Entry.new(name: 'rotate!', owner: 'Array', arity: 0, arg: :none, aspec: 'MRB_ARGS_OPT(1)',
              expression: 'bc2cpp_ary_rotate_bang(M, recv, 1)', helper: 'bc2cpp_ary_rotate_bang',
              apis: [%w[mruby/array.h mrb_ary_modify]],
              checks: [['ary_rotate_bang', ARY_ROTATE_BANG, :exact], ['rev', ARY_REV, :source]]),
    Entry.new(name: 'rotate!', owner: 'Array', arity: 1, arg: :integer, aspec: 'MRB_ARGS_OPT(1)',
              expression: 'bc2cpp_ary_rotate_bang(M, recv, mrb_integer(ARG0))', helper: 'bc2cpp_ary_rotate_bang',
              apis: [%w[mruby/array.h mrb_ary_modify]],
              checks: [['ary_rotate_bang', ARY_ROTATE_BANG, :exact], ['rev', ARY_REV, :source]]),
    Entry.new(name: 'index', owner: 'Array', arity: 1, arg: :none, aspec: 'MRB_ARGS_OPT(1)',
              expression: 'bc2cpp_ary_index(M, recv, ARG0)', helper: 'bc2cpp_ary_index',
              apis: [],
              checks: [['mrb_ary_index_m', <<~C, :exact]]),
                mrb_value obj, blk;
                if (mrb_get_args(mrb, "|o&", &obj, &blk) == 0 && mrb_nil_p(blk)) {
                  return mrb_funcall_id(mrb, self, MRB_SYM(to_enum), 1, mrb_symbol_value(MRB_SYM(index)));
                }
                if (mrb_nil_p(blk)) {
                  for (mrb_int i = 0; i < RARRAY_LEN(self); i++) {
                    if (mrb_equal(mrb, RARRAY_PTR(self)[i], obj)) {
                      return mrb_int_value(mrb, i);
                    }
                  }
                }
                else {
                  for (mrb_int i = 0; i < RARRAY_LEN(self); i++) {
                    mrb_value eq = mrb_yield(mrb, blk, RARRAY_PTR(self)[i]);
                    if (mrb_test(eq)) {
                      return mrb_int_value(mrb, i);
                    }
                  }
                }
                return mrb_nil_value();
              C
    # ary_modify is static, so the call is a mirror in emit_native_core_helpers: the block-less arm, with the public
    # mrb_ary_modify (ary_modify plus a write barrier) in place of ary_modify.
    Entry.new(name: 'delete', owner: 'Array', arity: 1, arg: :none, aspec: 'MRB_ARGS_REQ(1)',
              expression: 'bc2cpp_ary_delete(M, recv, ARG0)', helper: 'bc2cpp_ary_delete',
              apis: [%w[mruby/array.h mrb_ary_modify], %w[mruby.h mrb_equal], %w[mruby.h mrb_gc_protect]],
              checks: [['mrb_ary_delete', <<~C, :exact]]),
                mrb_value obj, blk;
                mrb_get_args(mrb, "o&", &obj, &blk);
                struct RArray *ary = RARRAY(self);
                mrb_value ret = obj;
                int ai = mrb_gc_arena_save(mrb);
                mrb_int i = 0;
                mrb_int j = 0;
                for (; i < ARY_LEN(ary); i++) {
                  mrb_value elem = ARY_PTR(ary)[i];
                  if (mrb_equal(mrb, elem, obj)) {
                    mrb_gc_arena_restore(mrb, ai);
                    mrb_gc_protect(mrb, elem);
                    ret = elem;
                    continue;
                  }
                  if (i != j) {
                    if (j >= ARY_LEN(ary)) {
                      mrb_raise(mrb, E_RUNTIME_ERROR, "array modified during delete");
                    }
                    ary_modify(mrb, ary);
                    ARY_PTR(ary)[j] = elem;
                  }
                  j++;
                }
                if (i == j) {
                  if (mrb_nil_p(blk)) return mrb_nil_value();
                  return mrb_yield(mrb, blk, obj);
                }
                ARY_SET_LEN(ary, j);
                return ret;
              C
    # A bulk push of N values is N single pushes: the frozen check and the final contents are the same, only
    # the capacity growth differs. mrb_ary_push_m itself is static.
    Entry.new(name: 'push', owner: 'Array', arity: 2, arg: :none, aspec: 'MRB_ARGS_ANY()',
              expression: '(mrb_ary_push(M, recv, ARG0), mrb_ary_push(M, recv, ARG1), recv)',
              apis: [%w[mruby/array.h mrb_ary_push]],
              checks: [['mrb_ary_push_m', <<~C, :exact]]),
                mrb_int argc = mrb_get_argc(mrb);
                if (argc == 1) {
                  mrb_ary_push(mrb, self, mrb_get_argv(mrb)[0]);
                  return self;
                }
                struct RArray *a = mrb_ary_ptr(self);
                mrb_int len = ARY_LEN(a);
                mrb_int len2 = len + argc;
                ary_modify(mrb, a);
                if (ARY_CAPA(a) < len2) {
                  ary_expand_capa(mrb, a, len2);
                }
                const mrb_value *argv = mrb_get_argv(mrb);
                array_copy(ARY_PTR(a)+len, argv, argc);
                ARY_SET_LEN(a, len2);
                while (argc--) {
                  mrb_field_write_barrier_value(mrb, (struct RBasic*)a, *argv);
                  argv++;
                }
                return self;
              C
    Entry.new(name: 'push', owner: 'Array', arity: 3, arg: :none, aspec: 'MRB_ARGS_ANY()',
              expression: '(mrb_ary_push(M, recv, ARG0), mrb_ary_push(M, recv, ARG1), mrb_ary_push(M, recv, ARG2), recv)',
              apis: [%w[mruby/array.h mrb_ary_push]],
              checks: [['mrb_ary_push_m', <<~C, :exact]]),
                mrb_int argc = mrb_get_argc(mrb);
                if (argc == 1) {
                  mrb_ary_push(mrb, self, mrb_get_argv(mrb)[0]);
                  return self;
                }
                struct RArray *a = mrb_ary_ptr(self);
                mrb_int len = ARY_LEN(a);
                mrb_int len2 = len + argc;
                ary_modify(mrb, a);
                if (ARY_CAPA(a) < len2) {
                  ary_expand_capa(mrb, a, len2);
                }
                const mrb_value *argv = mrb_get_argv(mrb);
                array_copy(ARY_PTR(a)+len, argv, argc);
                ARY_SET_LEN(a, len2);
                while (argc--) {
                  mrb_field_write_barrier_value(mrb, (struct RBasic*)a, *argv);
                  argv++;
                }
                return self;
              C
    Entry.new(name: 'push', owner: 'Array', arity: 4, arg: :none, aspec: 'MRB_ARGS_ANY()',
              expression: '(mrb_ary_push(M, recv, ARG0), mrb_ary_push(M, recv, ARG1), mrb_ary_push(M, recv, ARG2), mrb_ary_push(M, recv, ARG3), recv)',
              apis: [%w[mruby/array.h mrb_ary_push]],
              checks: [['mrb_ary_push_m', <<~C, :exact]]),
                mrb_int argc = mrb_get_argc(mrb);
                if (argc == 1) {
                  mrb_ary_push(mrb, self, mrb_get_argv(mrb)[0]);
                  return self;
                }
                struct RArray *a = mrb_ary_ptr(self);
                mrb_int len = ARY_LEN(a);
                mrb_int len2 = len + argc;
                ary_modify(mrb, a);
                if (ARY_CAPA(a) < len2) {
                  ary_expand_capa(mrb, a, len2);
                }
                const mrb_value *argv = mrb_get_argv(mrb);
                array_copy(ARY_PTR(a)+len, argv, argc);
                ARY_SET_LEN(a, len2);
                while (argc--) {
                  mrb_field_write_barrier_value(mrb, (struct RBasic*)a, *argv);
                  argv++;
                }
                return self;
              C
    Entry.new(name: 'replace', owner: 'Array', arity: 1, arg: :array, aspec: 'MRB_ARGS_REQ(1)',
              expression: '(mrb_ary_replace(M, recv, ARG0), recv)',
              apis: [%w[mruby/array.h mrb_ary_replace]],
              checks: [['mrb_ary_replace_m', <<~C, :exact]]),
                mrb_value other;
                mrb_get_args(mrb, "A", &other);
                mrb_ary_replace(mrb, self, other);
                return self;
              C
    # Only an exact String reaches the arm, and for one mrb_str_to_s returns the receiver itself.
    Entry.new(name: 'to_s', owner: 'String', arity: 0, arg: :none, aspec: 'MRB_ARGS_NONE()',
              expression: 'recv',
              apis: [],
              checks: [['mrb_str_to_s', <<~C, :exact]]),
                if (mrb_obj_class(mrb, self) != mrb->string_class) {
                  return mrb_str_dup(mrb, self);
                }
                return self;
              C
    # The two below read their argument with "i"; the Integer guard (a fixnum, not a bigint) is the case where
    # mrb_as_int is just mrb_integer, and every other argument keeps the send.
    Entry.new(name: 'getbyte', owner: 'String', arity: 1, arg: :integer, aspec: 'MRB_ARGS_REQ(1)',
              expression: 'bc2cpp_str_getbyte(M, recv, ARG0)', helper: 'bc2cpp_str_getbyte',
              apis: [],
              checks: [['mrb_str_getbyte', <<~C, :exact]]),
                mrb_int pos;
                mrb_get_args(mrb, "i", &pos);
                if (pos < 0)
                  pos += RSTRING_LEN(str);
                if (pos < 0 ||  RSTRING_LEN(str) <= pos)
                  return mrb_nil_value();
                return mrb_fixnum_value((unsigned char)RSTRING_PTR(str)[pos]);
              C
    Entry.new(name: 'to_i', owner: 'String', arity: 1, arg: :integer, aspec: 'MRB_ARGS_ANY()',
              expression: 'bc2cpp_str_to_i(M, recv, ARG0)', helper: 'bc2cpp_str_to_i',
              apis: [%w[mruby/string.h mrb_str_to_integer], %w[mruby.h mrb_raisef]],
              checks: [['mrb_str_to_i', <<~C, :exact]]),
                mrb_int base = 10;
                mrb_get_args(mrb, "|i", &base);
                if (base < 0 || 36 < base) {
                  mrb_raisef(mrb, E_ARGUMENT_ERROR, "illegal radix %i", base);
                }
                return mrb_str_to_integer(mrb, self, base, FALSE);
              C
    # Range#__empty_range? reads (begin, end, exclusive) with "oob"; 'b' is mrb_test, and the receiver is unused.
    Entry.new(name: '__empty_range?', owner: 'Range', arity: 3, arg: :none, aspec: 'MRB_ARGS_REQ(3)',
              expression: 'bc2cpp_range_empty_p(M, ARG0, ARG1, ARG2)', helper: 'bc2cpp_range_empty_p',
              apis: [%w[mruby.h mrb_cmp]],
              checks: [['range_empty_p', <<~C, :exact]]),
                mrb_value b, e;
                mrb_bool excl;
                mrb_get_args(mrb, "oob", &b, &e, &excl);
                if (mrb_nil_p(b) || mrb_nil_p(e))
                  return mrb_false_value();
                mrb_int comp = mrb_cmp(mrb, b, e);
                return mrb_bool_value(comp == -2 || comp > 0 || (comp == 0 && excl));
              C
    # Array#__fetch(index, default, none): the index is mrb_as_int'd, so the Integer guard is on it (ARG0).
    Entry.new(name: '__fetch', owner: 'Array', arity: 3, arg: :integer, aspec: 'MRB_ARGS_REQ(3)',
              expression: 'bc2cpp_ary_fetch(M, recv, ARG0, ARG1, ARG2)', helper: 'bc2cpp_ary_fetch',
              apis: [%w[mruby.h mrb_obj_equal], %w[mruby.h mrb_raisef]],
              checks: [['ary_fetch', <<~C, :exact]]),
                mrb_value index_val, default_val, none;
                mrb_get_args(mrb, "ooo", &index_val, &default_val, &none);
                mrb_int index = mrb_as_int(mrb, index_val);
                mrb_int original_index = index;
                struct RArray *ary = mrb_ary_ptr(self);
                mrb_int len = ARY_LEN(ary);
                if (index < 0) {
                  index += len;
                }
                if (index < 0 || index >= len) {
                  if (mrb_obj_equal(mrb, default_val, none)) {
                    mrb_raisef(mrb, E_INDEX_ERROR,
                               "index %i outside of array bounds: %i...%i",
                               original_index, -len, len);
                  }
                  return default_val;
                }
                return ARY_PTR(ary)[index];
              C
    # String#byteslice with fixnum arguments: the one-argument Integer arm (len 1, a zero-length slice is nil) and the
    # two-argument "ii" arm. A Range argument keeps the send. Both helpers call internal.h's non-static functions.
    Entry.new(name: 'byteslice', owner: 'String', arity: 1, arg: :integer, aspec: 'MRB_ARGS_ARG(1,1)',
              expression: 'bc2cpp_str_byteslice1(M, recv, ARG0)', helper: 'bc2cpp_str_byteslice1',
              apis: [],
              internals: [%w[mruby/internal.h mrb_str_beg_len], %w[mruby/internal.h mrb_str_byte_subseq]],
              checks: [['mrb_str_byteslice', <<~C, :exact]]),
                mrb_value a1;
                mrb_int str_len, beg, len;
                mrb_bool empty = TRUE;
                len = mrb_get_argc(mrb);
                switch (len) {
                case 2:
                  mrb_get_args(mrb, "ii", &beg, &len);
                  str_len = RSTRING_LEN(str);
                  break;
                case 1:
                  a1 = mrb_get_arg1(mrb);
                  str_len = RSTRING_LEN(str);
                  if (mrb_range_p(a1)) {
                    if (mrb_range_beg_len(mrb, a1, &beg, &len, str_len, TRUE) != MRB_RANGE_OK) {
                      return mrb_nil_value();
                    }
                  }
                  else {
                    beg = mrb_as_int(mrb, a1);
                    len = 1;
                    empty = FALSE;
                  }
                  break;
                default:
                  mrb_argnum_error(mrb, len, 1, 2);
                  break;
                }
                if (mrb_str_beg_len(str_len, &beg, &len) && (empty || len != 0)) {
                  return mrb_str_byte_subseq(mrb, str, beg, len);
                }
                else {
                  return mrb_nil_value();
                }
              C
    Entry.new(name: 'byteslice', owner: 'String', arity: 2, arg: :two_integers, aspec: 'MRB_ARGS_ARG(1,1)',
              expression: 'bc2cpp_str_byteslice2(M, recv, ARG0, ARG1)', helper: 'bc2cpp_str_byteslice2',
              apis: [],
              internals: [%w[mruby/internal.h mrb_str_beg_len], %w[mruby/internal.h mrb_str_byte_subseq]],
              checks: [['mrb_str_byteslice', <<~C, :exact]]),
                mrb_value a1;
                mrb_int str_len, beg, len;
                mrb_bool empty = TRUE;
                len = mrb_get_argc(mrb);
                switch (len) {
                case 2:
                  mrb_get_args(mrb, "ii", &beg, &len);
                  str_len = RSTRING_LEN(str);
                  break;
                case 1:
                  a1 = mrb_get_arg1(mrb);
                  str_len = RSTRING_LEN(str);
                  if (mrb_range_p(a1)) {
                    if (mrb_range_beg_len(mrb, a1, &beg, &len, str_len, TRUE) != MRB_RANGE_OK) {
                      return mrb_nil_value();
                    }
                  }
                  else {
                    beg = mrb_as_int(mrb, a1);
                    len = 1;
                    empty = FALSE;
                  }
                  break;
                default:
                  mrb_argnum_error(mrb, len, 1, 2);
                  break;
                }
                if (mrb_str_beg_len(str_len, &beg, &len) && (empty || len != 0)) {
                  return mrb_str_byte_subseq(mrb, str, beg, len);
                }
                else {
                  return mrb_nil_value();
                }
              C
    # mrb_ary_svalue is static, so the call is a mirror in emit_native_core_helpers.
    Entry.new(name: '__svalue', owner: 'Array', arity: 0, arg: :none, aspec: 'MRB_ARGS_NONE()',
              expression: 'bc2cpp_ary_svalue(M, recv)', helper: 'bc2cpp_ary_svalue',
              apis: [],
              checks: [['mrb_ary_svalue', <<~C, :exact]]),
                switch (RARRAY_LEN(ary)) {
                case 0:
                  return mrb_nil_value();
                case 1:
                  return RARRAY_PTR(ary)[0];
                default:
                  return ary;
                }
              C
    # Only an exact Array reaches the arm, and for one mrb_ary_to_a returns the receiver itself.
    Entry.new(name: 'to_a', owner: 'Array', arity: 0, arg: :none, aspec: 'MRB_ARGS_NONE()',
              expression: 'recv',
              apis: [],
              checks: [['mrb_ary_to_a', <<~C, :exact]]),
                if (mrb_obj_class(mrb, self) != mrb->array_class) {
                  /* Convert subclass to Array */
                  return mrb_ary_dup(mrb, self);
                }
                return self;
              C
    Entry.new(name: 'bytes', owner: 'String', arity: 0, arg: :none, aspec: 'MRB_ARGS_NONE()',
              expression: 'bc2cpp_str_bytes(M, recv)', helper: 'bc2cpp_str_bytes',
              apis: [],
              checks: [['mrb_str_bytes', <<~C, :exact]])
                struct RString *s = mrb_str_ptr(str);
                mrb_value a = mrb_ary_new_capa(mrb, RSTR_LEN(s));
                unsigned char *p = (unsigned char*)(RSTR_PTR(s)), *pend = p + RSTR_LEN(s);
                while (p < pend) {
                  mrb_ary_push(mrb, a, mrb_fixnum_value(p[0]));
                  p++;
                }
                return a;
              C
  ].freeze

  # KERNEL_DIRECT: natives every object inherits, sent with an implicit
  # self. No receiver class is guarded: the row is taken only while the name has no other
  # definition anywhere (CodeGen#kernel_direct_entry), so `owner` names the audited
  # registration. `internals` are declared in mruby/internal.h without MRB_API.
  #
  # mrb_f_raise reads its arguments with mrb_get_args, which needs a frame, so the helpers
  # replay its one- and two-argument arms; a bare raise (`$!` is not set by compiled
  # rescue), a third argument and `cause:` keep their send.
  MRB_F_RAISE = <<~C
      mrb_value exc, mesg;
      mrb_int argc = mrb_get_args(mrb, "|oo", &exc, &mesg);
      mrb->c->ci->mid = 0;
      switch (argc) {
      case 0:
        if (mrb->errinfo) {
          mrb_exc_raise(mrb, mrb_obj_value(mrb->errinfo));
        }
        mrb_raise(mrb, E_RUNTIME_ERROR, "");
        break;
      case 1:
        if (mrb_string_p(exc)) {
          mesg = exc;
          exc = mrb_obj_value(E_RUNTIME_ERROR);
        }
        else {
          mesg = mrb_nil_value();
        }
      default:
        exc = mrb_make_exception(mrb, exc, mesg);
        mrb_exc_raise(mrb, exc);
        break;
      }
      return mrb_nil_value();
  C

  KERNEL_ENTRIES = [
    Entry.new(name: 'raise', owner: 'Kernel', arity: 1, arg: :none, aspec: 'MRB_ARGS_OPT(2) | MRB_MT_PRIVATE',
              expression: 'bc2cpp_raise1(M, ARG0)', helper: 'bc2cpp_raise1', implicit_self: true,
              apis: [%w[mruby.h mrb_exc_raise]],
              internals: [%w[mruby/internal.h mrb_make_exception]],
              checks: [['mrb_f_raise', MRB_F_RAISE, :exact]]),
    Entry.new(name: 'raise', owner: 'Kernel', arity: 2, arg: :none, aspec: 'MRB_ARGS_OPT(2) | MRB_MT_PRIVATE',
              expression: 'bc2cpp_raise2(M, ARG0, ARG1)', helper: 'bc2cpp_raise2', implicit_self: true,
              apis: [%w[mruby.h mrb_exc_raise]],
              internals: [%w[mruby/internal.h mrb_make_exception]],
              checks: [['mrb_f_raise', MRB_F_RAISE, :exact]]),
    Entry.new(name: '__id__', owner: 'BasicObject', arity: 0, arg: :none, aspec: 'MRB_ARGS_NONE()',
              expression: 'mrb_fixnum_value(mrb_obj_id(recv))', implicit_self: true,
              apis: [%w[mruby.h mrb_obj_id]],
              checks: [['mrb_obj_id_m', <<~C, :exact, 'kernel.c']])
                return mrb_fixnum_value(mrb_obj_id(self));
              C
  ].freeze

  # RESULT_ONLY: natives whose result class is a fact (CodeGen#native_result_kind) but which no call site calls
  # directly: their bodies are static, so nothing outside their unit links to them. Audited like ENTRIES, down to the
  # allocation that fixes the result's class; `expression` is nil.
  RESULT_ENTRIES = [
    # ary_new_capa allocates from M->array_class.
    Entry.new(name: '+', owner: 'Array', arity: 1, arg: :array, aspec: 'MRB_ARGS_REQ(1)', expression: nil, apis: [],
              checks: [['mrb_ary_plus', <<~C, :exact],
                struct RArray *a1 = mrb_ary_ptr(self);
                const mrb_value *ptr;
                mrb_int blen;

                mrb_get_args(mrb, "a", &ptr, &blen);
                ary_check_too_big(mrb, ARY_LEN(a1), blen);
                mrb_int len1 = ARY_LEN(a1);
                struct RArray *a2 = ary_new_capa(mrb, len1 + blen);
                array_copy(ARY_PTR(a2), ARY_PTR(a1), len1);
                array_copy(ARY_PTR(a2) + len1, ptr, blen);
                ARY_SET_LEN(a2, len1+blen);

                return mrb_obj_value(a2);
              C
                       ['ary_new_capa', <<~C, :source]]),
                static struct RArray*
                ary_new_capa(mrb_state *mrb, mrb_int capa)
                {
                  ary_check_too_big(mrb, capa, 0);

                  size_t blen = capa * sizeof(mrb_value);
                  struct RArray *a = MRB_OBJ_ALLOC(mrb, MRB_TT_ARRAY, mrb->array_class);
              C
    # ARRAY_TIMES_RESULT (CodeGen#native_array_times_result): for an argument that is no String and answers no
    # to_str, mrb_ary_times returns mrb_ary_new (mrb_ary_new_capa's ary_new_capa) or its own ary_new_capa.
    Entry.new(name: '*', owner: 'Array', arity: 1, arg: :integer, aspec: 'MRB_ARGS_REQ(1)', expression: nil, apis: [],
              checks: [['mrb_ary_times', <<~C, :exact],
                struct RArray *a1 = mrb_ary_ptr(self);

                mrb_value arg = mrb_get_arg1(mrb);
                mrb_value tmp = mrb_check_string_type(mrb, arg);
                if (!mrb_nil_p(tmp)) {
                  return mrb_ary_join(mrb, self, tmp);
                }

                mrb_int times = mrb_as_int(mrb, arg);
                if (times < 0) {
                  mrb_raise(mrb, E_ARGUMENT_ERROR, "negative argument");
                }
                if (times == 0) return mrb_ary_new(mrb);
                if (ARY_MAX_SIZE / times < ARY_LEN(a1)) {
                  ary_too_big(mrb);
                }

                mrb_int len1 = ARY_LEN(a1);
                struct RArray *a2 = ary_new_capa(mrb, len1 * times);
                ARY_SET_LEN(a2, len1 * times);

                mrb_value *ptr = ARY_PTR(a2);
                while (times--) {
                  array_copy(ptr, ARY_PTR(a1), len1);
                  ptr += len1;
                }

                return mrb_obj_value(a2);
              C
                       ['ary_new_capa', <<~C, :source]]),
                static struct RArray*
                ary_new_capa(mrb_state *mrb, mrb_int capa)
                {
                  ary_check_too_big(mrb, capa, 0);

                  size_t blen = capa * sizeof(mrb_value);
                  struct RArray *a = MRB_OBJ_ALLOC(mrb, MRB_TT_ARRAY, mrb->array_class);
              C
    # With one argument ary_subtract_internal returns the mrb_ary_new it pushed into (ary_subtract_body's ctx->result
    # is the same object; MRB_ENSURE re-raises on failure), which is mrb_ary_new_capa's ary_new_capa.
    Entry.new(name: '-', owner: 'Array', arity: 1, arg: :array, aspec: 'MRB_ARGS_REQ(1)', expression: nil, apis: [],
              checks: [['ary_sub', <<~C, :exact],
                mrb_value other;
                mrb_get_args(mrb, "A", &other);
                return mrb_ary_ext_sub_impl(mrb, self, other);
              C
                       ['mrb_ary_ext_sub_impl', <<~C, :source],
                mrb_value
                mrb_ary_ext_sub_impl(mrb_state *mrb, mrb_value self, mrb_value other)
                {
                  return ary_subtract_internal(mrb, self, 1, &other);
                }
              C
                       ['ary_subtract_internal', <<~C, :source],
                static mrb_value
                ary_subtract_internal(mrb_state *mrb, mrb_value self, mrb_int argc, const mrb_value *argv)
                {
                  if (argc == 0) {
                    return mrb_ary_dup(mrb, self);
                  }

                  mrb_int total_len = ary_get_array_args(mrb, argc, &argv);

                  mrb_value result = mrb_ary_new(mrb);

                  if (total_len > SET_OP_HASH_THRESHOLD) {
                    /* Create shared copies to protect elements during khash operations */
                    mrb_value *argv_copies = (mrb_value *)mrb_alloca(mrb, sizeof(mrb_value) * argc);
                    for (mrb_int i = 0; i < argc; i++) {
                      argv_copies[i] = mrb_ary_make_shared_copy(mrb, argv[i]);
                    }

                    ary_set_t set_struct;
                    ary_set_t *set = &set_struct;
                    ary_init_temp_set(mrb, set, total_len);

                    struct ary_subtract_ctx ctx = { set, self, result, argv_copies, argc };
                    MRB_ENSURE(mrb, result, ary_subtract_body, &ctx) {
                      ary_destroy_temp_set(mrb, set);
                    }
                  }
                  else {
                    int ai = mrb_gc_arena_save(mrb);
                    for (mrb_int i = 0; i < RARRAY_LEN(self); i++) {
                      mrb_value p = RARRAY_PTR(self)[i];
                      mrb_gc_protect(mrb, p); // p may be removed from self by mrb_equal()
                      mrb_bool found = FALSE;
                      for (mrb_int j = 0; j < argc; j++) {
                        for (mrb_int k = 0; k < RARRAY_LEN(argv[j]); k++) {
                          if (mrb_equal(mrb, p, RARRAY_PTR(argv[j])[k])) {
                            found = TRUE;
                            break;
                          }
                        }
                        if (found) break;
                      }
                      if (!found) {
                        mrb_ary_push(mrb, result, p);
                      }
                      mrb_gc_arena_restore(mrb, ai);
                    }
                  }

                  return result;
                }
              C
                       ['ary_subtract_body', <<~C, :source],
                static mrb_value
                ary_subtract_body(mrb_state *mrb, void *data)
                {
                  struct ary_subtract_ctx *ctx = (struct ary_subtract_ctx *)data;

                  for (mrb_int i = 0; i < ctx->argc; i++) {
                    ary_populate_temp_set(mrb, ctx->set, ctx->argv[i]);
                  }

                  int ai = mrb_gc_arena_save(mrb);
                  for (mrb_int i = 0; i < RARRAY_LEN(ctx->self); i++) {
                    mrb_value p = RARRAY_PTR(ctx->self)[i];
                    mrb_gc_protect(mrb, p); // p may be removed from self by kh_get(ary_set, ...)
                    khiter_t k = kh_get(ary_set, mrb, ctx->set, p);
                    if (kh_is_end(ctx->set, k)) {  /* key doesn't exist in any ary */
                      mrb_ary_push(mrb, ctx->result, p);
                    }
                    mrb_gc_arena_restore(mrb, ai);
                  }

                  return ctx->result;
                }
              C
                       ['mrb_ary_new', <<~C, :source, '../../../src/array.c'],
                MRB_API mrb_value
                mrb_ary_new(mrb_state *mrb)
                {
                  return mrb_ary_new_capa(mrb, 0);
                }
              C
                       ['mrb_ary_new_capa', <<~C, :source, '../../../src/array.c'],
                MRB_API mrb_value
                mrb_ary_new_capa(mrb_state *mrb, mrb_int capa)
                {
                  struct RArray *a = ary_new_capa(mrb, capa);
                  return mrb_obj_value(a);
                }
              C
                       ['ary_new_capa', <<~C, :source, '../../../src/array.c']])
                static struct RArray*
                ary_new_capa(mrb_state *mrb, mrb_int capa)
                {
                  ary_check_too_big(mrb, capa, 0);

                  size_t blen = capa * sizeof(mrb_value);
                  struct RArray *a = MRB_OBJ_ALLOC(mrb, MRB_TT_ARRAY, mrb->array_class);
              C
  ].freeze

  # INHERITED_CORE_DIRECT: Kernel and BasicObject natives an exact core receiver reaches through its ancestry
  # (CodeGen#inherited_core_entry decides that nothing earlier in the lookup can answer). `owner` names the audited
  # registration, not the receiver's class.
  INHERITED_ENTRIES = [
    Entry.new(name: 'nil?', owner: 'Kernel', arity: 0, arg: :none, aspec: 'MRB_ARGS_NONE()',
              expression: 'mrb_false_value()', apis: [],
              checks: [['mrb_false', 'return mrb_false_value();', :exact]]),
    Entry.new(name: 'class', owner: 'Kernel', arity: 0, arg: :none, aspec: 'MRB_ARGS_NONE()',
              expression: 'mrb_obj_value(mrb_obj_class(M, recv))', apis: [],
              checks: [['mrb_obj_class_m', 'return mrb_obj_value(mrb_obj_class(mrb, self));', :exact]]),
    Entry.new(name: 'dup', owner: 'Kernel', arity: 0, arg: :none, aspec: 'MRB_ARGS_NONE()',
              expression: 'mrb_obj_dup(M, recv)', apis: [%w[mruby.h mrb_obj_dup]],
              checks: [['mrb_obj_dup', <<~C, :exact, 'class.c']]),
                if (mrb_immediate_p(obj)) {
                  return obj;
                }
                if (mrb_sclass_p(obj)) {
                  mrb_raise(mrb, E_TYPE_ERROR, "can't dup singleton class");
                }
                struct RBasic *p = mrb_obj_alloc(mrb, mrb_type(obj), mrb_obj_class(mrb, obj));
                mrb_value dup = mrb_obj_value(p);
                init_copy(mrb, dup, obj);
                return dup;
              C
    Entry.new(name: 'equal?', owner: 'BasicObject', arity: 1, arg: :none, aspec: 'MRB_ARGS_REQ(1)',
              expression: 'mrb_bool_value(mrb_obj_equal(M, recv, ARG0))', apis: [%w[mruby.h mrb_obj_equal]],
              checks: [['mrb_obj_equal_m', <<~C, :exact]]),
                mrb_value arg = mrb_get_arg1(mrb);
                return mrb_bool_value(mrb_obj_equal(mrb, self, arg));
              C
    Entry.new(name: 'is_a?', owner: 'Kernel', arity: 1, arg: :class_or_module, aspec: 'MRB_ARGS_REQ(1)',
              expression: 'mrb_bool_value(mrb_obj_is_kind_of(M, recv, mrb_class_ptr(ARG0)))',
              apis: [%w[mruby.h mrb_obj_is_kind_of]],
              checks: [['mrb_obj_is_kind_of_m', <<~C, :exact]]),
                struct RClass *c;
                mrb_get_args(mrb, "c", &c);
                return mrb_bool_value(mrb_obj_is_kind_of(mrb, self, c));
              C
    Entry.new(name: 'kind_of?', owner: 'Kernel', arity: 1, arg: :class_or_module, aspec: 'MRB_ARGS_REQ(1)',
              expression: 'mrb_bool_value(mrb_obj_is_kind_of(M, recv, mrb_class_ptr(ARG0)))',
              apis: [%w[mruby.h mrb_obj_is_kind_of]],
              checks: [['mrb_obj_is_kind_of_m', <<~C, :exact]]),
                struct RClass *c;
                mrb_get_args(mrb, "c", &c);
                return mrb_bool_value(mrb_obj_is_kind_of(mrb, self, c));
              C
    Entry.new(name: 'frozen?', owner: 'Kernel', arity: 0, arg: :none, aspec: 'MRB_ARGS_NONE()',
              expression: 'mrb_bool_value(mrb_immediate_p(recv) || mrb_frozen_p(mrb_basic_ptr(recv)))', apis: [],
              checks: [['mrb_obj_frozen', 'return mrb_bool_value(mrb_immediate_p(self) || mrb_frozen_p(mrb_basic_ptr(self)));', :exact]]),
    Entry.new(name: 'freeze', owner: 'Kernel', arity: 0, arg: :none, aspec: 'MRB_ARGS_NONE()',
              expression: 'mrb_obj_freeze(M, recv)', apis: [%w[mruby.h mrb_obj_freeze]],
              checks: [['mrb_obj_freeze', <<~C, :exact]])
                if (!mrb_immediate_p(self)) {
                  struct RBasic *b = mrb_basic_ptr(self);
                  if (!mrb_frozen_p(b)) {
                    b->frozen = 1;
                    if (b->c->tt == MRB_TT_SCLASS) b->c->frozen = 1;
                  }
                }
                return self;
              C
  ].freeze

  # KERNEL_DIRECT for any receiver: the INHERITED_ENTRIES rows audited as implicit_self (no other class registers the
  # name), so a send whose receiver class is unknown reaches the same body (CodeGen#kernel_direct_code guards it).
  KERNEL_ANY_RECEIVER_ENTRIES = INHERITED_ENTRIES.map do |entry|
    entry.dup.tap do |row|
      row.implicit_self = true
      row.explicit_receiver = true
    end
  end.freeze

  # OWNER_SET_DIRECT (codegen_owner_set_direct.rb): the registrations an owner call may resolve to when every owner
  # of its name is one of these mruby natives. Each row is one owner's registration, audited like the rows above;
  # the codegen table says which rows a name's owner set must be covered by and what the call computes.
  OWNER_SET_ENTRIES = [
    Entry.new(name: 'nil?', owner: 'Kernel', arity: 0, arg: :none, aspec: 'MRB_ARGS_NONE()',
              expression: 'mrb_false_value()', apis: [],
              checks: [['mrb_false', 'return mrb_false_value();', :exact]]),
    Entry.new(name: 'nil?', owner: 'NilClass', arity: 0, arg: :none, aspec: 'MRB_ARGS_NONE()',
              expression: 'mrb_true_value()', apis: [],
              checks: [['mrb_true', 'return mrb_true_value();', :exact]]),
    Entry.new(name: 'respond_to?', owner: 'Kernel', arity: 1, arg: :none, aspec: 'MRB_ARGS_ARG(1,1)',
              expression: 'mrb_bool_value(mrb_respond_to(M, recv, mrb_symbol(ARG0)))',
              apis: [%w[mruby.h mrb_respond_to]],
              checks: [['obj_respond_to', <<~C, :exact]]),
                mrb_sym id;
                mrb_bool priv = FALSE, respond_to_p;
                mrb_get_args(mrb, "n|b", &id, &priv);
                respond_to_p = mrb_respond_to(mrb, self, id);
                if (!respond_to_p) {
                  mrb_sym rtm_id = MRB_SYM_Q(respond_to_missing);
                  if (!mrb_func_basic_p(mrb, self, rtm_id, mrb_false)) {
                    mrb_value v = mrb_funcall_id(mrb, self, rtm_id, 2, mrb_symbol_value(id), mrb_bool_value(priv));
                    return mrb_bool_value(mrb_bool(v));
                  }
                }
                return mrb_bool_value(respond_to_p);
              C
    INHERITED_ENTRIES.find { |entry| entry.name == 'dup' },
    Entry.new(name: 'object_id', owner: 'Kernel', arity: 0, arg: :none, aspec: 'MRB_ARGS_NONE()',
              expression: 'mrb_fixnum_value(mrb_obj_id(recv))', apis: [%w[mruby.h mrb_obj_id]],
              checks: [['mrb_obj_id_m', 'return mrb_fixnum_value(mrb_obj_id(self));', :exact]]),
    # The registered function is the public API itself, called with the receiver as its value.
    Entry.new(name: '__to_int', owner: 'Kernel', arity: 0, arg: :none, aspec: 'MRB_ARGS_NONE()',
              expression: 'mrb_ensure_int_type(M, recv)', apis: [%w[mruby.h mrb_ensure_int_type]],
              checks: [['mrb_ensure_int_type', <<~C, :exact, 'object.c']]),
                val = mrb_ensure_integer_type(mrb, val);
                #ifdef MRB_USE_BIGINT
                if (mrb_bigint_p(val)) {
                  return mrb_int_value(mrb, mrb_bint_as_int(mrb, val));
                }
                #endif
                return val;
              C
    # respond_to? consults respond_to_missing? only when it is not this default.
    Entry.new(name: 'respond_to_missing?', owner: 'Kernel', arity: 2, arg: :none,
              aspec: 'MRB_ARGS_ARG(1,1) | MRB_MT_PRIVATE', expression: 'mrb_false_value()', apis: [],
              checks: [['mrb_false', 'return mrb_false_value();', :exact]])
  ].freeze

  # cmpnum (numeric.c), the comparison num_cmp delegates to; bc2cpp_num_cmp copies its two direct branches. A
  # three-parameter static function, so it is checked as :source text.
  CMPNUM_BODY = <<~C
    #ifdef MRB_NO_FLOAT             /* integer version */

      if (!mrb_integer_p(v2)) {
        if (!mrb_obj_is_kind_of(mrb, v2, mrb_class_get_id(mrb, MRB_SYM(Numeric)))) {
          return -2;
        }
        v1 = mrb_funcall_argv(mrb, v2, MRB_OPSYM(cmp), 1, &v1);
        if (mrb_integer_p(v1)) {
          return -mrb_integer(v1);
        }
        return -2;
      }
      mrb_int x = mrb_as_int(mrb, v1);
      mrb_int y = mrb_integer(v2);

    #else                           /* float version */

      mrb_float x, y;

      if (mrb_integer_p(v1)) {
        if (mrb_integer_p(v2)) {
          mrb_int x = mrb_integer(v1);
          mrb_int y = mrb_integer(v2);

          if (x > y) return 1;
          else if (x < y) return -1;
          return 0;
        }
    #ifdef MRB_USE_BIGINT
        if (mrb_bigint_p(v2)) {
          return -mrb_bint_cmp(mrb, v2, v1);
        }
    #endif
        x = (mrb_float)mrb_integer(v1);
      }
    #ifdef MRB_USE_BIGINT
      else if (mrb_bigint_p(v1)) {
        if (mrb_integer_p(v2) || mrb_bigint_p(v2)) {
          return mrb_bint_cmp(mrb, v1, v2);
        }
        x = mrb_as_float(mrb, v1);
      }
    #endif
      else {
        x = mrb_as_float(mrb, v1);
      }

      switch (mrb_type(v2)) {
    #ifdef MRB_USE_RATIONAL
      case MRB_TT_RATIONAL:
    #endif
    #ifdef MRB_USE_BIGINT
      case MRB_TT_BIGINT:
    #endif
      case MRB_TT_INTEGER:
        if (mrb_integer_p(v2)) {
          y = (mrb_float)mrb_integer(v2);
          break;
        }
        /* fall through */
      case MRB_TT_FLOAT:
        y = mrb_as_float(mrb, v2);
        break;
      default:
        if (!mrb_obj_is_kind_of(mrb, v2, mrb_class_get_id(mrb, MRB_SYM(Numeric)))) {
          return -2;
        }
        /* fall through */
    #ifdef MRB_USE_COMPLEX
      case MRB_TT_COMPLEX:
    #endif
        v1 = mrb_funcall_argv(mrb, v2, MRB_OPSYM(cmp), 1, &v1);
        if (mrb_integer_p(v1)) {
          return -mrb_integer(v1);
        }
        return -2;
      }
    #endif
      if (x > y)
        return 1;
      else if (x < y)
        return -1;
      return 0;
  C

  # OWNER_ARM_ENTRIES (codegen_owner_set_direct.rb, owner_set_native_arms): exact-class arms in front of an owner
  # call, for an owner of its name whose registration is one of these. Used only there, so the typed-receiver passes
  # that read ENTRIES are unchanged. Integer#to_i is NUMERIC_CONVERSION_ENTRIES' row.
  OWNER_ARM_ENTRIES = [
    # flo_to_i raises for NaN/Infinity (mrb_check_num_exact) and widens past the fixnum range; the receiver guard
    # leaves both to the send, so the arm is the truncating cast alone.
    Entry.new(name: 'to_i', owner: 'Float', arity: 0, arg: :none, aspec: 'MRB_ARGS_NONE()',
              recv_guard: 'isfinite(mrb_float(%<r>s)) && FIXABLE_FLOAT(mrb_float(%<r>s))',
              expression: 'mrb_int_value(M, (mrb_int)(mrb_float(recv) > 0.0 ? floor(mrb_float(recv)) : ceil(mrb_float(recv))))',
              apis: [],
              checks: [['flo_to_i', <<~C, :exact]]),
                mrb_float f = mrb_float(num);
                mrb_check_num_exact(mrb, f);
                if (!FIXABLE_FLOAT(f)) {
                #ifdef MRB_USE_BIGINT
                  return mrb_bint_new_float(mrb, f);
                #else
                  mrb_int_overflow(mrb, "to_f");
                #endif
                }
                if (f > 0.0) f = floor(f);
                if (f < 0.0) f = ceil(f);
                return mrb_int_value(mrb, (mrb_int)f);
              C
    Entry.new(name: 'to_f', owner: 'Integer', arity: 0, arg: :none, aspec: 'MRB_ARGS_NONE()',
              expression: 'mrb_float_value(M, (mrb_float)mrb_integer(recv))', apis: [],
              checks: [['int_to_f', <<~C, :exact]]),
                #ifdef MRB_USE_BIGINT
                if (mrb_bigint_p(num)) {
                  return mrb_float_value(mrb, mrb_bint_as_float(mrb, num));
                }
                #endif
                return mrb_float_value(mrb, (mrb_float)mrb_integer(num));
              C
    Entry.new(name: 'to_f', owner: 'Float', arity: 0, arg: :none, aspec: 'MRB_ARGS_NONE()',
              expression: 'recv', apis: [],
              checks: [['mrb_obj_itself', 'return self;', :exact, 'object.c']]),
    # num_cmp over cmpnum, for its two direct branches only: fixnum against fixnum, or a fixnum/Float pair compared
    # as doubles (so NaN answers 0, as cmpnum does). A heap Integer receiver or argument keeps the send.
    Entry.new(name: '<=>', owner: 'Integer', arity: 1, arg: :fixnum_or_float, aspec: 'MRB_ARGS_REQ(1)',
              recv_guard: 'mrb_fixnum_p(%<r>s)',
              expression: 'bc2cpp_num_cmp(recv, ARG0)', apis: [], helper: 'bc2cpp_num_cmp',
              checks: [['num_cmp', <<~C, :exact],
                mrb_value other = mrb_get_arg1(mrb);
                mrb_int n = cmpnum(mrb, self, other);
                if (n == -2) return mrb_nil_value();
                return mrb_fixnum_value(n);
              C
                       ['cmpnum', CMPNUM_BODY, :source]]),
    Entry.new(name: '<=>', owner: 'Float', arity: 1, arg: :fixnum_or_float, aspec: 'MRB_ARGS_REQ(1)',
              expression: 'bc2cpp_num_cmp(recv, ARG0)', apis: [], helper: 'bc2cpp_num_cmp',
              checks: [['num_cmp', <<~C, :exact],
                mrb_value other = mrb_get_arg1(mrb);
                mrb_int n = cmpnum(mrb, self, other);
                if (n == -2) return mrb_nil_value();
                return mrb_fixnum_value(n);
              C
                       ['cmpnum', CMPNUM_BODY, :source]]),
    Entry.new(name: 'bytesize', owner: 'String', arity: 0, arg: :none, aspec: 'MRB_ARGS_NONE()',
              expression: 'mrb_int_value(M, RSTRING_LEN(recv))', apis: [],
              checks: [['mrb_str_bytesize', 'return mrb_int_value(mrb, RSTRING_LEN(self));', :exact]]),
    # The registered function is the public API itself, called with the receiver as its value.
    Entry.new(name: 'keys', owner: 'Hash', arity: 0, arg: :none, aspec: 'MRB_ARGS_NONE()',
              expression: 'mrb_hash_keys(M, recv)', apis: [%w[mruby/hash.h mrb_hash_keys]],
              checks: [['mrb_hash_keys', <<~C, :exact]])
                struct RHash *h = mrb_hash_ptr(hash);
                mrb_value ary = mrb_ary_new_capa(mrb, (mrb_int)h_size(h));
                H_EACH(h, entry) {
                  mrb_ary_push(mrb, ary, entry->key);
                }
                return ary;
              C
  ].freeze

  # The C text of each helper, emitted once per output that calls it.
  HAND_HELPERS = {
    # cmpnum's direct branches (OWNER_ARM_ENTRIES' guards keep everything else on the send).
    'bc2cpp_num_cmp' => <<~CPP,
      static inline mrb_value bc2cpp_num_cmp(mrb_value a, mrb_value b) {
        if (mrb_fixnum_p(a) && mrb_fixnum_p(b)) {
          mrb_int x = mrb_integer(a), y = mrb_integer(b);
          return mrb_fixnum_value(x > y ? 1 : x < y ? -1 : 0);
        }
        mrb_float x = mrb_fixnum_p(a) ? (mrb_float)mrb_integer(a) : mrb_float(a);
        mrb_float y = mrb_fixnum_p(b) ? (mrb_float)mrb_integer(b) : mrb_float(b);
        return mrb_fixnum_value(x > y ? 1 : x < y ? -1 : 0);
      }
    CPP
    'bc2cpp_ary_compact' => <<~CPP,
      static inline mrb_value bc2cpp_ary_compact(mrb_state* M, mrb_value self) {
        mrb_value ary = mrb_ary_new_capa(M, RARRAY_LEN(self));
        for (mrb_int i = 0; i < RARRAY_LEN(self); i++) {
          if (!mrb_nil_p(RARRAY_PTR(self)[i])) mrb_ary_push(M, ary, RARRAY_PTR(self)[i]);
        }
        return ary;
      }
    CPP
    'bc2cpp_ary_rotate_bang' => <<~CPP,
      #define BC2CPP_ROTATE_SMALL_MAX 16
      static inline void bc2cpp_ary_rev(mrb_value *p, mrb_int beg, mrb_int end) {
        for (mrb_int i = beg, j = end - 1; i < j; i++, j--) {
          mrb_value v = p[i];
          p[i] = p[j];
          p[j] = v;
        }
      }
      static inline mrb_value bc2cpp_ary_rotate_bang(mrb_state* M, mrb_value self, mrb_int count) {
        struct RArray *a = mrb_ary_ptr(self);
        mrb_int len = ARY_LEN(a);
        mrb_int idx;
        mrb_ary_modify(M, a);
        mrb_value *p = ARY_PTR(a);
        if (len == 0 || count == 0) return self;
        if (count == 1) {
          mrb_value v = p[0];
          for (mrb_int i = 1; i < len; i++) {
            p[i-1] = p[i];
          }
          p[len-1] = v;
          return self;
        }
        if (count < 0) {
          idx = len - (~count % len) - 1;
        }
        else {
          idx = count % len;
        }
        // ROTATE_SMALL_SHIFT: the triple reversal leaves the same order, so a shift whose short side fits the
        // buffer is moved in place instead; mrb_ary_modify above already did the unshare and the write barrier.
        if (idx == 0) return self;
        mrb_int rest = len - idx;
        mrb_value buf[BC2CPP_ROTATE_SMALL_MAX];
        if (idx <= BC2CPP_ROTATE_SMALL_MAX) {
          memcpy(buf, p, sizeof(mrb_value) * idx);
          memmove(p, p + idx, sizeof(mrb_value) * rest);
          memcpy(p + rest, buf, sizeof(mrb_value) * idx);
          return self;
        }
        if (rest <= BC2CPP_ROTATE_SMALL_MAX) {
          memcpy(buf, p + idx, sizeof(mrb_value) * rest);
          memmove(p + rest, p, sizeof(mrb_value) * idx);
          memcpy(p, buf, sizeof(mrb_value) * rest);
          return self;
        }
        bc2cpp_ary_rev(p, 0, len);
        bc2cpp_ary_rev(p, 0, len-idx);
        bc2cpp_ary_rev(p, len-idx, len);
        return self;
      }
    CPP
    'bc2cpp_ary_index' => <<~CPP,
      static inline mrb_value bc2cpp_ary_index(mrb_state* M, mrb_value self, mrb_value obj) {
        for (mrb_int i = 0; i < RARRAY_LEN(self); i++) {
          if (mrb_equal(M, RARRAY_PTR(self)[i], obj)) return mrb_int_value(M, i);
        }
        return mrb_nil_value();
      }
    CPP
    'bc2cpp_ary_delete' => <<~CPP,
      static inline mrb_value bc2cpp_ary_delete(mrb_state* M, mrb_value self, mrb_value obj) {
        struct RArray *ary = RARRAY(self);
        mrb_value ret = obj;
        int ai = mrb_gc_arena_save(M);
        mrb_int i = 0;
        mrb_int j = 0;
        for (; i < ARY_LEN(ary); i++) {
          mrb_value elem = ARY_PTR(ary)[i];
          if (mrb_equal(M, elem, obj)) {
            mrb_gc_arena_restore(M, ai);
            mrb_gc_protect(M, elem);
            ret = elem;
            continue;
          }
          if (i != j) {
            if (j >= ARY_LEN(ary)) {
              mrb_raise(M, mrb_exc_get_id(M, mrb_intern_lit(M, "RuntimeError")), "array modified during delete");
            }
            mrb_ary_modify(M, ary);
            ARY_PTR(ary)[j] = elem;
          }
          j++;
        }
        if (i == j) return mrb_nil_value();
        ARY_SET_LEN(ary, j);
        return ret;
      }
    CPP
    'bc2cpp_range_empty_p' => <<~CPP,
      static inline mrb_value bc2cpp_range_empty_p(mrb_state* M, mrb_value b, mrb_value e, mrb_value excl_value) {
        mrb_bool excl = mrb_test(excl_value);
        if (mrb_nil_p(b) || mrb_nil_p(e))
          return mrb_false_value();
        mrb_int comp = mrb_cmp(M, b, e);
        return mrb_bool_value(comp == -2 || comp > 0 || (comp == 0 && excl));
      }
    CPP
    'bc2cpp_ary_fetch' => <<~CPP,
      static inline mrb_value bc2cpp_ary_fetch(mrb_state* M, mrb_value self, mrb_value index_val, mrb_value default_val,
                                               mrb_value none) {
        mrb_int index = mrb_integer(index_val);
        mrb_int original_index = index;
        struct RArray *ary = mrb_ary_ptr(self);
        mrb_int len = ARY_LEN(ary);
        if (index < 0) {
          index += len;
        }
        if (index < 0 || index >= len) {
          if (mrb_obj_equal(M, default_val, none)) {
            mrb_raisef(M, mrb_exc_get_id(M, mrb_intern_lit(M, "IndexError")),
                       "index %i outside of array bounds: %i...%i",
                       original_index, -len, len);
          }
          return default_val;
        }
        return ARY_PTR(ary)[index];
      }
    CPP
    # mrb_str_beg_len and mrb_str_byte_subseq are internal.h's, which has no C linkage guard.
    'bc2cpp_str_byteslice1' => <<~CPP,
      extern "C" mrb_bool mrb_str_beg_len(mrb_int, mrb_int*, mrb_int*);
      extern "C" mrb_value mrb_str_byte_subseq(mrb_state*, mrb_value, mrb_int, mrb_int);
      static inline mrb_value bc2cpp_str_byteslice1(mrb_state* M, mrb_value str, mrb_value pos) {
        mrb_int beg = mrb_integer(pos), len = 1;
        if (mrb_str_beg_len(RSTRING_LEN(str), &beg, &len) && len != 0) {
          return mrb_str_byte_subseq(M, str, beg, len);
        }
        return mrb_nil_value();
      }
    CPP
    'bc2cpp_str_byteslice2' => <<~CPP,
      extern "C" mrb_bool mrb_str_beg_len(mrb_int, mrb_int*, mrb_int*);
      extern "C" mrb_value mrb_str_byte_subseq(mrb_state*, mrb_value, mrb_int, mrb_int);
      static inline mrb_value bc2cpp_str_byteslice2(mrb_state* M, mrb_value str, mrb_value pos, mrb_value count) {
        mrb_int beg = mrb_integer(pos), len = mrb_integer(count);
        if (mrb_str_beg_len(RSTRING_LEN(str), &beg, &len)) {
          return mrb_str_byte_subseq(M, str, beg, len);
        }
        return mrb_nil_value();
      }
    CPP
    'bc2cpp_str_getbyte' => <<~CPP,
      static inline mrb_value bc2cpp_str_getbyte(mrb_state* M, mrb_value str, mrb_value pos_value) {
        mrb_int pos = mrb_integer(pos_value);
        if (pos < 0)
          pos += RSTRING_LEN(str);
        if (pos < 0 || RSTRING_LEN(str) <= pos)
          return mrb_nil_value();
        return mrb_fixnum_value((unsigned char)RSTRING_PTR(str)[pos]);
      }
    CPP
    'bc2cpp_str_to_i' => <<~CPP,
      static inline mrb_value bc2cpp_str_to_i(mrb_state* M, mrb_value self, mrb_value base_value) {
        mrb_int base = mrb_integer(base_value);
        if (base < 0 || 36 < base) {
          mrb_raisef(M, mrb_exc_get_id(M, mrb_intern_lit(M, "ArgumentError")), "illegal radix %i", base);
        }
        return mrb_str_to_integer(M, self, base, FALSE);
      }
    CPP
    'bc2cpp_ary_svalue' => <<~CPP,
      static inline mrb_value bc2cpp_ary_svalue(mrb_state* M, mrb_value ary) {
        switch (RARRAY_LEN(ary)) {
        case 0:
          return mrb_nil_value();
        case 1:
          return RARRAY_PTR(ary)[0];
        default:
          return ary;
        }
      }
    CPP
    'bc2cpp_str_bytes' => <<~CPP,
      static inline mrb_value bc2cpp_str_bytes(mrb_state* M, mrb_value str) {
        mrb_value a = mrb_ary_new_capa(M, RSTRING_LEN(str));
        for (mrb_int i = 0; i < RSTRING_LEN(str); i++) {
          mrb_ary_push(M, a, mrb_fixnum_value((unsigned char)RSTRING_PTR(str)[i]));
        }
        return a;
      }
    CPP
    # mrb_f_raise's one- and two-argument arms. The declaration is internal.h's,
    # which has no C linkage guard (see the mrb_str_aref note in bc2cpp.rb).
    'bc2cpp_raise1' => <<~CPP,
      extern "C" mrb_value mrb_make_exception(mrb_state*, mrb_value, mrb_value);
      static inline mrb_value bc2cpp_raise1(mrb_state* M, mrb_value exc) {
        mrb_value mesg = mrb_nil_value();
        if (mrb_string_p(exc)) {
          mesg = exc;
          exc = mrb_obj_value(mrb_exc_get_id(M, mrb_intern_lit(M, "RuntimeError")));
        }
        mrb_exc_raise(M, mrb_make_exception(M, exc, mesg));
      }
    CPP
    'bc2cpp_raise2' => <<~CPP
      extern "C" mrb_value mrb_make_exception(mrb_state*, mrb_value, mrb_value);
      static inline mrb_value bc2cpp_raise2(mrb_state* M, mrb_value exc, mrb_value mesg) {
        mrb_exc_raise(M, mrb_make_exception(M, exc, mesg));
      }
    CPP
  }.freeze

  # The generated entries (scripts/bc2cpp/native_core_direct_wire.rb): frame-free core natives on Array, String and
  # Integer, each with its body pinned. Loaded here, after Entry and the hand lists, because the file reopens this module.
  require_relative 'native_core_direct_generated'
  ENTRIES = (HAND_ENTRIES + GENERATED_ENTRIES).freeze
  HELPERS = HAND_HELPERS.merge(GENERATED_HELPERS).freeze

  @audits = {}

  module_function

  def normalize(text)
    text.gsub(%r{/\*.*?\*/|//[^\n]*}m, ' ').gsub(/\s+/, '')
  end

  def mruby_include_dir(paths)
    root = Array(paths).filter_map { |path| path[%r{\A(.+/3rd/mruby)/}, 1] }.first
    dir = root && File.join(root, 'include')
    dir if dir && File.directory?(dir)
  end

  # The body of the function named `function` in `path`, or nil.
  def function_body(path, function)
    source = NativeExpressionDevirt.read_source(path)
    pattern = /\b#{Regexp.escape(function)}\s*\(\s*mrb_state\s*\*\s*\w+\s*,\s*mrb_value\s+\w+\s*\)\s*\{/
    match = pattern.match(source)
    return unless match

    NativeExpressionDevirt.brace_body(source, match.end(0) - 1).first
  end

  # { entry => nil | failure reason } for every ENTRIES row against `paths`.
  def audit(paths)
    files = Array(paths).select { |path| File.file?(path) }
    key = files.map { |path| stat = File.stat(path); [path, stat.mtime, stat.size] }
    include_dir = mruby_include_dir(files)
    headers = (ENTRIES + RESULT_ENTRIES + KERNEL_ENTRIES + NUMERIC_CONVERSION_ENTRIES + INHERITED_ENTRIES +
     KERNEL_ANY_RECEIVER_ENTRIES + OWNER_SET_ENTRIES + OWNER_ARM_ENTRIES).flat_map { |entry| entry.apis + Array(entry.internals) }
    key += headers.map(&:first).uniq.map do |header|
      path = include_dir && File.join(include_dir, header)
      stat = path && File.file?(path) && File.stat(path)
      [path, stat && stat.mtime, stat && stat.size]
    end
    @audits.fetch(key) do
      @audits.clear
      @audits[key] = audit_files(files)
    end
  end

  def audit_files(files)
    registrations, opaque_owners = NativeExpressionDevirt.class_registrations(files)
    include_dir = mruby_include_dir(files)
    (ENTRIES + RESULT_ENTRIES + KERNEL_ENTRIES + NUMERIC_CONVERSION_ENTRIES + INHERITED_ENTRIES +
     KERNEL_ANY_RECEIVER_ENTRIES + OWNER_SET_ENTRIES + OWNER_ARM_ENTRIES).to_h do |entry|
      [entry, audit_entry(entry, registrations, opaque_owners, include_dir)]
    end
  end

  def audit_entry(entry, registrations, opaque_owners, include_dir)
    return 'no mruby core include directory' unless include_dir
    unattributed = opaque_owners.fetch(entry.name, []).any? { |owner| entry.implicit_self || owner.nil? || owner == entry.owner }
    return 'spelled by an unattributed native registration' if unattributed

    matches = registrations.fetch(entry.name, []).select do |registration|
      registration[:owner] && registration[:owner][:class_name] == entry.owner
    end
    return "expected exactly one #{entry.owner}##{entry.name} registration, found #{matches.size}" unless matches.one?

    # An implicit-self call reaches any receiver, so a registration of the name on any
    # other class is a second candidate too.
    if entry.implicit_self && registrations.fetch(entry.name, []).size != 1
      return "#{entry.name} is registered on more than #{entry.owner}"
    end

    registration = matches.first
    unless registration[:function] == entry.function && registration[:aspec] == entry.aspec
      return "#{entry.owner}##{entry.name} is registered as #{registration[:function]} #{registration[:aspec]}"
    end

    entry.checks.each do |function, expected, mode, file|
      path = registration[:path]
      path = File.join(File.dirname(path), file) if file
      if mode == :source
        # A macro or other text outside any function body, found anywhere in the file.
        found = File.file?(path) && normalize(NativeExpressionDevirt.read_source(path)).include?(normalize(expected))
        return "#{File.basename(path)} no longer contains the audited text" unless found
        next
      end

      body = function_body(path, function)
      return "#{function} not found in #{File.basename(path)}" unless body

      actual = normalize(body)
      wanted = normalize(expected)
      ok = mode == :exact ? actual == wanted : actual.start_with?(wanted)
      return "#{function} no longer matches the audited body" unless ok
    end
    entry.apis.each do |header, function|
      text = File.read(File.join(include_dir, header), encoding: 'UTF-8')
      return "#{function} is not declared MRB_API in #{header}" unless text.match?(/\bMRB_API\s+\w[\w\s*]*\b#{function}\s*\(/)
    end
    Array(entry.internals).each do |header, function|
      text = File.read(File.join(include_dir, header), encoding: 'UTF-8')
      return "#{function} is not declared in #{header}" unless text.match?(/^(?:mrb_value|mrb_bool)\s+#{function}\s*\(/)
    end
    nil
  end

  def verified?(paths, entry)
    audit(paths).fetch(entry).nil?
  end
end
