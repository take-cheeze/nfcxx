# frozen_string_literal: true

# ENUM_STEP (docs/bc2cpp-enum-step.md): the step form of an owner's #each for external iteration.
#
# A compiled core #each under a Fiber (CORE_BLOCK_GUARD) hands over to mruby's own Ruby body, which is saved bytecode,
# so the block's Fiber.yield has only VM frames between resume and yield. With BC2CPP_ENUM_STEP=1 the saved body is a
# shared driver instead: a Ruby loop in the engine that calls a compiled step for the next element and makes the block
# call itself. The step holds its cursor in a heap array, [next, done, ...]; it returns the element, or sets done and
# returns nil. The cursor's other slots are the owner's own (Range keeps its stop there).
#
# Read once, when bc2cpp generates code: EnumStep.enabled?. Unset, nothing here is emitted and the output is unchanged.
# Only the owners in FORMS take part; every other guarded core method keeps its saved bytecode.
module EnumStep
  FLAG = 'BC2CPP_ENUM_STEP'
  DRIVER_METHOD = '__bc2cpp_each_driver'
  STEP_METHOD = '__bc2cpp_each_step'
  OPEN_METHOD = '__bc2cpp_each_open'

  # The driver of Array#each, compiled into the VM by mrb_load_string when the registration runs.
  ARRAY_DRIVER = <<~'RUBY'
    class Array
      def __bc2cpp_each_driver(&block)
        return to_enum(:each) unless block

        st = [0, false]
        while true
          v = __bc2cpp_each_step(st)
          break if st[1]

          yield v
        end
        self
      end
      private :__bc2cpp_each_driver
    end
  RUBY

  # The driver of Range#each. The open returns the state; a range the body hands to String#upto or
  # String#__upto_endless is a [method, receiver, args] triple, and the driver makes that call itself: a Ruby call, so
  # the block's Fiber.yield has VM frames only. Every other range is stepped, and the body is not kept.
  RANGE_DRIVER = <<~'RUBY'
    class Range
      def __bc2cpp_each_driver(&block)
        return to_enum(:each) unless block

        st = __bc2cpp_each_open
        return st[1].__send__(st[0], *st[2], &block) if st[0]

        while true
          v = __bc2cpp_each_step(st)
          break if st[6]

          block.call(v)
        end
        self
      end
      private :__bc2cpp_each_driver
    end
  RUBY

  # The C++ of Array's step: the cursor is [next index, done]; the step reads the length of an exact Array directly
  # and dispatches `length` and `[]` otherwise (a subclass).
  ARRAY_C = <<~'CPP'
    // The cursor is a heap array [next index, done]; a step returns the element at it, or sets done.
    [[maybe_unused]] static mrb_value bc2cpp_each_step(mrb_state* M, mrb_value self) {
      mrb_value st = mrb_nil_value();
      mrb_get_args(M, "o", &st);
      mrb_int idx = mrb_fixnum(mrb_ary_ref(M, st, 0));
      bool exact = mrb_array_p(self) && mrb_obj_ptr(self)->c == M->array_class;
      mrb_value len = exact ? mrb_fixnum_value(ARY_LEN(mrb_ary_ptr(self))) : mrb_funcall(M, self, "length", 0);
      if (idx >= mrb_as_int(M, len)) {
        mrb_ary_set(M, st, 1, mrb_true_value());
        return mrb_nil_value();
      }
      mrb_value elem = exact ? mrb_ary_ref(M, self, idx) : mrb_funcall(M, self, "[]", 1, mrb_fixnum_value(idx));
      mrb_ary_set(M, st, 0, mrb_fixnum_value(idx + 1));
      return elem;
    }
  CPP

  # The C++ of Range's step, for every range mruby's body covers (docs/bc2cpp-enum-step.md, "Range generic"). The open
  # makes the body's own dispatch, in its order: begin, end, then kind_of?/nil?/respond_to? on the bounds, the Integer
  # bounds' exclude_end? (and end + 1), the String upto call, and `(val <=> last) > 0`. The step makes the loop's: `<=>`,
  # `<` on its result, the yield, `succ` after the block, and the final `exclude_end?` and `== 0` check. Each dispatch is
  # where the body makes it, so the calls a user succ or <=> sees are the body's.
  RANGE_C = <<~'CPP'
    // The state of the step form of Range#each: [delegate, cursor, last, kind, phase, str_each, done]. A stepped state has
    // nil delegate. Other states hold [method, receiver, args] for the driver's call to String#upto or __upto_endless.
    enum : mrb_int {
      bc2cpp_rg_cur = 1, bc2cpp_rg_last, bc2cpp_rg_kind, bc2cpp_rg_phase, bc2cpp_rg_str_each, bc2cpp_rg_done,
      bc2cpp_rg_int = 0, bc2cpp_rg_endless, bc2cpp_rg_generic,
      bc2cpp_rg_check = 0, bc2cpp_rg_advance, bc2cpp_rg_final, bc2cpp_rg_end
    };
    [[maybe_unused]] static bool bc2cpp_rg_is(mrb_state* M, mrb_value v, struct RClass* c) {
      return mrb_test(mrb_funcall(M, v, "kind_of?", 1, mrb_obj_value(c)));
    }
    [[maybe_unused]] static bool bc2cpp_rg_nil(mrb_state* M, mrb_value v) {
      return mrb_test(mrb_funcall(M, v, "nil?", 0));
    }
    [[maybe_unused]] static bool bc2cpp_rg_responds(mrb_state* M, mrb_value v, const char* name) {
      return mrb_test(mrb_funcall(M, v, "respond_to?", 1, mrb_symbol_value(mrb_intern_cstr(M, name))));
    }
    // a < b and a > b: native when both are Integers (as the VM's OP_LT and OP_GT are), else dispatched on a.
    [[maybe_unused]] static bool bc2cpp_rg_lt(mrb_state* M, mrb_value a, mrb_value b) {
      if (mrb_integer_p(a) && mrb_integer_p(b)) return mrb_integer(a) < mrb_integer(b);
      return mrb_test(mrb_funcall(M, a, "<", 1, b));
    }
    [[maybe_unused]] static bool bc2cpp_rg_gt(mrb_state* M, mrb_value a, mrb_value b) {
      if (mrb_integer_p(a) && mrb_integer_p(b)) return mrb_integer(a) > mrb_integer(b);
      return mrb_test(mrb_funcall(M, a, ">", 1, b));
    }
    [[maybe_unused]] static bool bc2cpp_rg_eq0(mrb_state* M, mrb_value c) {
      if (mrb_integer_p(c)) return mrb_integer(c) == 0;
      return mrb_test(mrb_funcall(M, c, "==", 1, mrb_fixnum_value(0)));
    }
    // v + 1 as `i += 1` makes it: native below MRB_INT_MAX, Integer#+ above (a Bignum).
    [[maybe_unused]] static mrb_value bc2cpp_rg_inc(mrb_state* M, mrb_value v) {
      if (mrb_integer_p(v) && mrb_integer(v) < MRB_INT_MAX) return mrb_int_value(M, mrb_integer(v) + 1);
      return mrb_funcall(M, v, "+", 1, mrb_fixnum_value(1));
    }
    [[maybe_unused]] static mrb_value bc2cpp_rg_state(mrb_state* M, mrb_value cur, mrb_value last, mrb_int kind,
                                                      bool str_each) {
      mrb_value st = mrb_ary_new_capa(M, 7);
      mrb_ary_push(M, st, mrb_nil_value());
      mrb_ary_push(M, st, cur);
      mrb_ary_push(M, st, last);
      mrb_ary_push(M, st, mrb_fixnum_value(kind));
      mrb_ary_push(M, st, mrb_fixnum_value(bc2cpp_rg_check));
      mrb_ary_push(M, st, mrb_bool_value(str_each));
      mrb_ary_push(M, st, mrb_false_value());
      return st;
    }
    [[maybe_unused]] static mrb_value bc2cpp_rg_delegate(mrb_state* M, const char* name, mrb_value recv, mrb_value args) {
      mrb_value st = mrb_ary_new_capa(M, 3);
      mrb_ary_push(M, st, mrb_symbol_value(mrb_intern_cstr(M, name)));
      mrb_ary_push(M, st, recv);
      mrb_ary_push(M, st, args);
      return st;
    }
    [[maybe_unused]] static mrb_value bc2cpp_range_each_open(mrb_state* M, mrb_value self) {
      mrb_value val = mrb_funcall(M, self, "begin", 0);
      mrb_gc_protect(M, val);
      mrb_value last = mrb_funcall(M, self, "end", 0);
      mrb_gc_protect(M, last);
      if (bc2cpp_rg_is(M, val, M->integer_class) && bc2cpp_rg_nil(M, last)) {
        return bc2cpp_rg_state(M, val, mrb_nil_value(), bc2cpp_rg_endless, false);
      }
      bool str_each = false;
      if (bc2cpp_rg_is(M, val, M->string_class) && bc2cpp_rg_nil(M, last)) {
        if (bc2cpp_rg_responds(M, val, "__upto_endless")) {
          return bc2cpp_rg_delegate(M, "__upto_endless", val, mrb_ary_new(M));
        }
        str_each = true;
      }
      if (bc2cpp_rg_is(M, val, M->integer_class) && bc2cpp_rg_is(M, last, M->integer_class)) {
        mrb_value lim = last;
        if (!mrb_test(mrb_funcall(M, self, "exclude_end?", 0))) lim = bc2cpp_rg_inc(M, last);
        mrb_gc_protect(M, lim);
        return bc2cpp_rg_state(M, val, lim, bc2cpp_rg_int, false);
      }
      if (bc2cpp_rg_is(M, val, M->string_class) && bc2cpp_rg_is(M, last, M->string_class)) {
        if (bc2cpp_rg_responds(M, val, "upto")) {
          mrb_value args = mrb_ary_new_capa(M, 2);
          mrb_ary_push(M, args, last);
          mrb_ary_push(M, args, mrb_bool_value(mrb_test(mrb_funcall(M, self, "exclude_end?", 0))));
          return bc2cpp_rg_delegate(M, "upto", val, args);
        }
        str_each = true;
      }
      // E_TYPE_ERROR names `mrb`, and this function's state is `M`.
      if (!bc2cpp_rg_responds(M, val, "succ")) mrb_raise(M, mrb_exc_get_id(M, MRB_ERROR_SYM(TypeError)), "can't iterate");
      mrb_value st = bc2cpp_rg_state(M, val, last, bc2cpp_rg_generic, str_each);
      // `return self if (val <=> last) > 0`: nothing is yielded, so the state is done.
      if (bc2cpp_rg_gt(M, mrb_funcall(M, val, "<=>", 1, last), mrb_fixnum_value(0))) {
        mrb_ary_set(M, st, bc2cpp_rg_done, mrb_true_value());
      }
      return st;
    }
    // Returns the value to yield, or sets done and returns nil. The block runs between two steps, so the body's order holds:
    // the advance (`i += 1`, or `val = val.succ`) follows the block's return.
    [[maybe_unused]] static mrb_value bc2cpp_range_each_step(mrb_state* M, mrb_value self) {
      mrb_value st = mrb_nil_value();
      mrb_get_args(M, "o", &st);
      if (mrb_test(mrb_ary_ref(M, st, bc2cpp_rg_done))) return mrb_nil_value();
      mrb_value cur = mrb_ary_ref(M, st, bc2cpp_rg_cur);
      mrb_value last = mrb_ary_ref(M, st, bc2cpp_rg_last);
      mrb_int kind = mrb_integer(mrb_ary_ref(M, st, bc2cpp_rg_kind));
      mrb_int phase = mrb_integer(mrb_ary_ref(M, st, bc2cpp_rg_phase));
      if (kind != bc2cpp_rg_generic) {
        if (phase == bc2cpp_rg_advance) cur = bc2cpp_rg_inc(M, cur);
        if (kind == bc2cpp_rg_int && !bc2cpp_rg_lt(M, cur, last)) {
          mrb_ary_set(M, st, bc2cpp_rg_done, mrb_true_value());
          return mrb_nil_value();
        }
        mrb_ary_set(M, st, bc2cpp_rg_cur, cur);
        mrb_ary_set(M, st, bc2cpp_rg_phase, mrb_fixnum_value(bc2cpp_rg_advance));
        return cur;
      }
      if (phase == bc2cpp_rg_end) {
        mrb_ary_set(M, st, bc2cpp_rg_done, mrb_true_value());
        return mrb_nil_value();
      }
      if (phase == bc2cpp_rg_advance) {
        cur = mrb_funcall(M, cur, "succ", 0);
        mrb_ary_set(M, st, bc2cpp_rg_cur, cur);
        phase = bc2cpp_rg_check;
        // `break if val.size > last.size` for a String range without String#upto.
        if (mrb_test(mrb_ary_ref(M, st, bc2cpp_rg_str_each))) {
          mrb_value size = mrb_funcall(M, cur, "size", 0);
          mrb_value last_size = mrb_funcall(M, last, "size", 0);
          if (bc2cpp_rg_gt(M, size, last_size)) phase = bc2cpp_rg_final;
        }
      }
      if (phase == bc2cpp_rg_check) {
        // while (val <=> last) < 0: yield val.
        if (bc2cpp_rg_lt(M, mrb_funcall(M, cur, "<=>", 1, last), mrb_fixnum_value(0))) {
          mrb_ary_set(M, st, bc2cpp_rg_phase, mrb_fixnum_value(bc2cpp_rg_advance));
          return cur;
        }
      }
      // block.call(val) if !exclude_end? && (val <=> last) == 0
      if (!mrb_test(mrb_funcall(M, self, "exclude_end?", 0)) &&
          bc2cpp_rg_eq0(M, mrb_funcall(M, cur, "<=>", 1, last))) {
        mrb_ary_set(M, st, bc2cpp_rg_phase, mrb_fixnum_value(bc2cpp_rg_end));
        return cur;
      }
      mrb_ary_set(M, st, bc2cpp_rg_done, mrb_true_value());
      return mrb_nil_value();
    }
  CPP

  # One step form per owner. c_step is the C step (a method of the owner); c_open the C function that opens the cursor,
  # nil when the driver takes no open; driver the Ruby source of the driver; c the C++ the form needs. stubs_body: the
  # step covers every case the saved body covers, so under the flag the body is emptied (MrblibStubs, bc2cpp_stub_top_mrblib).
  Form = Struct.new(:owner, :c_step, :c_open, :driver, :c, :stubs_body) do
    # The driver's C++ string constant, named after the step.
    def src_name = "#{c_step.delete_suffix('_step')}_driver_src"

    # The arguments after the registration's index that bc2cpp_enum_step_save takes for this form.
    def save_args = "#{c_step}, #{c_open || 'nullptr'}, #{src_name}"
  end

  FORMS = {
    'Array' => Form.new('Array', 'bc2cpp_each_step', nil, ARRAY_DRIVER, ARRAY_C, false),
    'Range' => Form.new('Range', 'bc2cpp_range_each_step', 'bc2cpp_range_each_open', RANGE_DRIVER, RANGE_C, true)
  }.freeze

  module_function

  def enabled?
    ENV[FLAG] == '1'
  end

  # The step form of an entry's #each, or nil. Instance methods only, and only an each with a guard (a block-taking one).
  def form_for(entry, singleton)
    return nil unless enabled? && !singleton && entry[:name] == 'each' && !entry[:guard].nil?

    FORMS[entry[:owner]]
  end

  # Whether the entry's saved body may leave the binary under the flag: its form covers that body (Form#stubs_body).
  def stubs_body?(entry, singleton)
    form = form_for(entry, singleton)
    !form.nil? && form.stubs_body
  end

  # The C++ text the generated unit needs when an owner's #each is guarded: the generic save helper, then each used
  # form's step, open and driver source. Empty otherwise, so an unset flag adds no line.
  def helpers(compiled)
    return '' unless enabled?

    used = FORMS.values.select { |form| compiled.any? { |entry| form_for(entry, false).equal?(form) } }
    return '' if used.empty?

    <<~CPP + used.map { |form| form_text(form) }.join
      // ENUM_STEP -- the step form of an owner's #each (tools/bc2cpp/codegen_enum_step.rb, docs/bc2cpp-enum-step.md).
      // The first registration of a body still in bytecode loads the owner's driver, which takes the body's place in
      // the saved table; a second registration finds the compiled entry and the driver already saved.
      [[maybe_unused]] static bool bc2cpp_enum_step_save(mrb_state* M, struct RClass* c, bool singleton, const char* name,
                                                         mrb_int index, mrb_func_t step, mrb_func_t open, const char* driver_src) {
        struct RClass* target = singleton ? mrb_singleton_class_ptr(M, mrb_obj_value(c)) : c;
        struct RClass* found = target;
        mrb_method_t m = mrb_method_search_vm(M, &found, mrb_intern_cstr(M, name));
        if (found == target && !MRB_METHOD_UNDEF_P(m) && MRB_METHOD_PROC_P(m) && !MRB_PROC_CFUNC_P(MRB_METHOD_PROC(m))) {
          mrb_define_private_method(M, c, "#{STEP_METHOD}", step, MRB_ARGS_REQ(1));
          if (open) mrb_define_private_method(M, c, "#{OPEN_METHOD}", open, MRB_ARGS_NONE());
          mrb_load_string(M, driver_src);
          if (M->exc) {
            mrb_print_error(M);
            M->exc = nullptr;
            return false;
          }
        }
        return bc2cpp_core_save_interpreted(M, c, singleton, "#{DRIVER_METHOD}", index);
      }

    CPP
  end

  def form_text(form)
    <<~CPP
      #{form.c}
      static const char* const #{form.src_name} = R"RUBY(
      #{form.driver}
      )RUBY";

    CPP
  end
end
