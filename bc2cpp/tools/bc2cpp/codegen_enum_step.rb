# frozen_string_literal: true

# ENUM_STEP (docs/bc2cpp-enum-step.md): the step form of Array#each for external iteration.
#
# A compiled Array#each entered under a Fiber (CORE_BLOCK_GUARD) hands over to mruby's own Ruby body, which is saved
# bytecode, so the block's Fiber.yield has only VM frames between resume and yield. With BC2CPP_ENUM_STEP=1 the saved
# body is a shared driver instead: a Ruby loop in the engine that calls a compiled step for the next element and makes
# the block call itself. The step holds its cursor in a heap array, [next index, done]; it returns the element, or
# sets done and returns nil.
#
# Read once, when bc2cpp generates code: EnumStep.enabled?. Unset, nothing here is emitted and the output is unchanged.
# Only Array#each takes part; every other guarded core method keeps its saved bytecode.
module EnumStep
  FLAG = 'BC2CPP_ENUM_STEP'
  DRIVER_METHOD = '__bc2cpp_each_driver'
  STEP_METHOD = '__bc2cpp_each_step'

  # The driver, compiled into the VM by mrb_load_string when the registration runs. It is the bytecode the guard
  # runs under a Fiber in place of Array#each's own body (bc2cpp_core_interpreted swaps the frame for it).
  DRIVER_SOURCE = <<~'RUBY'
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

  module_function

  def enabled?
    ENV[FLAG] == '1'
  end

  # The compiled entry that takes the step form: Array#each, an instance method with a guard.
  def each_entry?(entry, singleton)
    enabled? && !singleton && entry[:owner] == 'Array' && entry[:name] == 'each' && !entry[:guard].nil?
  end

  # The C++ text the generated unit needs when an Array#each is guarded: the step, the driver's source, and the
  # registration that saves the driver in Array#each's slot. Empty otherwise, so an unset flag adds no line.
  def helpers(compiled)
    return '' unless enabled? && compiled.any? { |entry| each_entry?(entry, false) }

    <<~CPP
      // ENUM_STEP -- the step form of Array#each (tools/bc2cpp/codegen_enum_step.rb, docs/bc2cpp-enum-step.md).
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
      static const char* const bc2cpp_each_driver_src = R"RUBY(
      #{DRIVER_SOURCE}
      )RUBY";
      // Array#each's saved body is the driver (ENUM_STEP), found on the class like any saved method.
      [[maybe_unused]] static bool bc2cpp_enum_step_save(mrb_state* M, struct RClass* c, bool singleton, const char* name, mrb_int index) {
        (void)name;
        mrb_define_private_method(M, c, "#{STEP_METHOD}", bc2cpp_each_step, MRB_ARGS_REQ(1));
        mrb_load_string(M, bc2cpp_each_driver_src);
        if (M->exc) {
          mrb_print_error(M);
          M->exc = nullptr;
          return false;
        }
        return bc2cpp_core_save_interpreted(M, c, singleton, "#{DRIVER_METHOD}", index);
      }

    CPP
  end
end
