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

  # The driver of Range#each. The cases the step does not cover (see bc2cpp_range_each_open) run the body, kept by the
  # alias `__bc2cpp_each_plain`: this source runs while `each` is still mrblib's body, before the compiled entry is defined.
  # It yields with block.call, as the body does.
  RANGE_DRIVER = <<~'RUBY'
    class Range
      def __bc2cpp_each_driver(&block)
        return to_enum(:each) unless block

        st = __bc2cpp_each_open
        return __bc2cpp_each_plain(&block) unless st

        while true
          v = __bc2cpp_each_step(st)
          break if st[1]

          block.call(v)
        end
        self
      end
      alias __bc2cpp_each_plain each
      private :__bc2cpp_each_driver, :__bc2cpp_each_plain
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

  # The C++ of Range's step. The open decides, once per call, whether the step covers the range: it returns the cursor
  # [next, done, stop] for an Integer begin with an Integer end (exclusive, or inclusive below MRB_INT_MAX, whose stop
  # is end + 1) or a nil end, and nil for anything else (String, Float or bignum bounds, an inclusive end at
  # MRB_INT_MAX). mrblib's own loops are the same comparisons, so the cursor is an Integer throughout.
  RANGE_C = <<~'CPP'
    // The cursor of the step form of Range#each: [next, done, stop], stop nil for an endless range. nil when the step
    // does not cover the range; the driver then runs the saved body. begin and end are read as mrblib reads them.
    [[maybe_unused]] static mrb_value bc2cpp_range_each_open(mrb_state* M, mrb_value self) {
      mrb_value beg = mrb_funcall(M, self, "begin", 0);
      mrb_value end = mrb_funcall(M, self, "end", 0);
      if (!mrb_integer_p(beg)) return mrb_nil_value();
      mrb_value stop = mrb_nil_value();
      if (!mrb_nil_p(end)) {
        if (!mrb_integer_p(end)) return mrb_nil_value();
        bool excl = mrb_test(mrb_funcall(M, self, "exclude_end?", 0));
        if (excl) {
          stop = end;
        } else if (mrb_integer(end) < MRB_INT_MAX) {
          stop = mrb_int_value(M, mrb_integer(end) + 1);
        } else {
          return mrb_nil_value();
        }
      }
      mrb_value st = mrb_ary_new_capa(M, 3);
      mrb_ary_push(M, st, beg);
      mrb_ary_push(M, st, mrb_false_value());
      mrb_ary_push(M, st, stop);
      return st;
    }
    // Returns the value at the cursor and advances it, or sets done and returns nil. Values past the Fixnum range are
    // boxed with mrb_int_value (word boxing has a smaller Fixnum range than mrb_int). An endless cursor past MRB_INT_MAX
    // is a bignum and goes on through Integer#+, as mrblib's `i += 1` does.
    [[maybe_unused]] static mrb_value bc2cpp_range_each_step(mrb_state* M, mrb_value self) {
      mrb_value st = mrb_nil_value();
      mrb_get_args(M, "o", &st);
      mrb_value cur = mrb_ary_ref(M, st, 0);
      mrb_value stop = mrb_ary_ref(M, st, 2);
      if (!mrb_nil_p(stop) && mrb_integer(cur) >= mrb_integer(stop)) {
        mrb_ary_set(M, st, 1, mrb_true_value());
        return mrb_nil_value();
      }
      mrb_value next = (mrb_integer_p(cur) && mrb_integer(cur) < MRB_INT_MAX)
                         ? mrb_int_value(M, mrb_integer(cur) + 1)
                         : mrb_funcall(M, cur, "+", 1, mrb_fixnum_value(1));
      mrb_ary_set(M, st, 0, next);
      return cur;
    }
  CPP

  # One step form per owner. c_step is the C step (a method of the owner); c_open the C function that opens the cursor,
  # nil when the driver takes no open; driver the Ruby source of the driver; c the C++ the form needs.
  Form = Struct.new(:owner, :c_step, :c_open, :driver, :c) do
    # The driver's C++ string constant, named after the step.
    def src_name = "#{c_step.delete_suffix('_step')}_driver_src"

    # The arguments after the registration's index that bc2cpp_enum_step_save takes for this form.
    def save_args = "#{c_step}, #{c_open || 'nullptr'}, #{src_name}"
  end

  FORMS = {
    'Array' => Form.new('Array', 'bc2cpp_each_step', nil, ARRAY_DRIVER, ARRAY_C),
    'Range' => Form.new('Range', 'bc2cpp_range_each_step', 'bc2cpp_range_each_open', RANGE_DRIVER, RANGE_C)
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
