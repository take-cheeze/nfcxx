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
    'Range' => { guard: 'mrb_range_p(%<r>s) && mrb_obj_ptr(%<r>s)->c == M->range_class' }
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
    nil_or_string: '(mrb_nil_p(%<a>s) || mrb_string_p(%<a>s))'
  }.freeze

  # `checks` are [function, expected body, :exact | :prefix, optional file next to the
  # registration's]; the first is the registered function. Bodies are compared with
  # whitespace and comments removed. `internals` and `implicit_self` are KERNEL_ENTRIES' (below).
  Entry = Struct.new(:name, :owner, :arity, :arg, :aspec, :expression, :checks, :apis, :helper, :internals,
                     :implicit_self, keyword_init: true) do
    def function
      checks.first.first
    end

    def guard(recv, argv)
      parts = [format(OWNERS.fetch(owner)[:guard], r: recv)]
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

  # The C text of each helper, emitted once per output that calls it.
  HAND_HELPERS = {
    'bc2cpp_ary_compact' => <<~CPP,
      static inline mrb_value bc2cpp_ary_compact(mrb_state* M, mrb_value self) {
        mrb_value ary = mrb_ary_new_capa(M, RARRAY_LEN(self));
        for (mrb_int i = 0; i < RARRAY_LEN(self); i++) {
          if (!mrb_nil_p(RARRAY_PTR(self)[i])) mrb_ary_push(M, ary, RARRAY_PTR(self)[i]);
        }
        return ary;
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
    headers = (ENTRIES + KERNEL_ENTRIES + NUMERIC_CONVERSION_ENTRIES + INHERITED_ENTRIES).flat_map { |entry| entry.apis + Array(entry.internals) }
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
    (ENTRIES + KERNEL_ENTRIES + NUMERIC_CONVERSION_ENTRIES + INHERITED_ENTRIES).to_h do |entry|
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
