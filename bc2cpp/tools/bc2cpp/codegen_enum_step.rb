# frozen_string_literal: true

require_relative 'enum_driver_gen'

# ENUM_STEP (docs/bc2cpp-enum-step.md): the step form of an owner's #each for external iteration.
#
# A compiled core #each under a Fiber (CORE_BLOCK_GUARD) hands over to mruby's own Ruby body, which is saved bytecode,
# so the block's Fiber.yield has only VM frames between resume and yield. With BC2CPP_ENUM_STEP=1 the saved body is a
# shared driver instead: a Ruby loop in the engine that calls a compiled step for the next element and makes the block
# call itself. The step holds its cursor in a heap array, [next, done, ...]; it returns the element, or sets done and
# returns nil. The cursor's other slots are the owner's own (Range keeps its stop there).
#
# Read once, when bc2cpp generates code: EnumStep.enabled?. On by default; BC2CPP_ENUM_STEP=0 turns it off, and then
# nothing here is emitted and the output is unchanged.
# Only the owners in FORMS take part; every other guarded core method keeps its saved bytecode.
module EnumStep
  MRUBY_ROOT = File.expand_path('../../3rd/mruby', __dir__)
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

  # One step form per owner. c_step is the C step (a method of the owner); c_open the C function that opens the cursor,
  # nil when the driver takes no open; driver the Ruby source of the driver; c the C++ the form needs. stubs_body: the
  # step covers every case the saved body covers, so under the flag the body is emptied (MrblibStubs, bc2cpp_stub_top_mrblib).
  # name: the method the form replaces (each, unless given); driver_method: the driver's name, saved as the body.
  Form = Struct.new(:owner, :c_step, :c_open, :driver, :c, :stubs_body, :name, :driver_method) do
    def method_name = name || 'each'

    def driver_name = driver_method || DRIVER_METHOD

    # The driver's C++ string constant, named after the step, or after the method for a form with no C step.
    def src_name = c_step ? "#{c_step.delete_suffix('_step')}_driver_src" : "bc2cpp_#{EnumStep.slug(owner.downcase)}_#{EnumStep.slug(method_name)}_driver_src"

    # The arguments after the registration's index that bc2cpp_enum_step_save takes for this form.
    def save_args = [c_step || 'nullptr', c_open || 'nullptr', src_name, *(driver_method ? ["\"#{driver_name}\""] : [])].join(', ')
  end

  # A driver generated from the body it replaces (EnumDriverGen): the body's own source, read when the form is used.
  def self.generated(rel, owner, method, driver)
    -> { EnumDriverGen.driver_source(File.join(MRUBY_ROOT, rel), owner, method, driver) }
  end

  FORMS = {
    %w[Array each] => Form.new('Array', 'bc2cpp_each_step', nil, ARRAY_DRIVER, ARRAY_C, false),
    %w[Range each] => Form.new('Range', nil, nil, generated('mrblib/range.rb', 'Range', 'each', '__bc2cpp_each_driver'), nil, true, 'each', '__bc2cpp_each_driver'),
    %w[String upto] => Form.new('String', nil, nil, generated('mrbgems/mruby-string-ext/mrblib/string.rb', 'String', 'upto', '__bc2cpp_upto_driver'), nil, true, 'upto', '__bc2cpp_upto_driver'),
    %w[Integer times] => Form.new('Integer', nil, nil, generated('mrblib/numeric.rb', 'Integer', 'times', '__bc2cpp_times_driver'), nil, true, 'times', '__bc2cpp_times_driver'),
    %w[Integer upto] => Form.new('Integer', nil, nil, generated('mrblib/numeric.rb', 'Integer', 'upto', '__bc2cpp_upto_driver'), nil, true, 'upto', '__bc2cpp_upto_driver'),
    %w[Integer downto] => Form.new('Integer', nil, nil, generated('mrblib/numeric.rb', 'Integer', 'downto', '__bc2cpp_downto_driver'), nil, true, 'downto', '__bc2cpp_downto_driver'),
    %w[Hash each] => Form.new('Hash', nil, nil, generated('mrblib/hash.rb', 'Hash', 'each', '__bc2cpp_each_driver'), nil, true, 'each', '__bc2cpp_each_driver'),
    %w[Hash each_key] => Form.new('Hash', nil, nil, generated('mrblib/hash.rb', 'Hash', 'each_key', '__bc2cpp_each_key_driver'), nil, true, 'each_key', '__bc2cpp_each_key_driver'),
    %w[Hash each_value] => Form.new('Hash', nil, nil, generated('mrblib/hash.rb', 'Hash', 'each_value', '__bc2cpp_each_value_driver'), nil, true, 'each_value', '__bc2cpp_each_value_driver')
  }.freeze

  # Where each guarded core method's body is defined, by irep label: [file, def line]. bc2cpp sets it with the guard set
  # (CodeGen.core_guarded), before the stub pass and the emission read the forms. Nil: no generated forms.
  class << self
    attr_reader :sources

    def sources=(value)
      @default_forms = {}
      @sources = value
    end
  end

  module_function

  def enabled?
    ENV[FLAG] != '0'
  end

  # A name as a C identifier part: ? and ! and = spelled out, anything else non-alphanumeric as _.
  def slug(name)
    name.gsub(/[^A-Za-z0-9_]/) { |c| { '?' => '_p', '!' => '_b', '=' => '_e' }.fetch(c, '_') }
  end

  # The driver a generated form of +name+ is saved as. each's is DRIVER_METHOD, so the owners' drivers keep their names.
  def default_driver_name(name) = "__bc2cpp_#{slug(name)}_driver"

  # The step form of a guarded entry, or nil: keyed by its owner and method, or else generated from its body. Instance
  # methods only.
  def form_for(entry, singleton)
    return nil unless enabled? && !singleton && !entry[:guard].nil?

    FORMS[[entry[:owner], entry[:name]]] || default_form(entry)
  end

  # The generated form of a guarded method with no FORMS entry: its driver is the body's own def (EnumDriverGen), read
  # from the file and line the compiler saw. Nil when there is no source for it or the body cannot be rewritten
  # (EnumDriverGen::Refused): such a body keeps its saved bytecode.
  def default_form(entry)
    file, line = sources&.[](entry[:label])
    return nil unless file && line

    @default_forms ||= {}
    return @default_forms[entry[:label]] if @default_forms.key?(entry[:label])

    @default_forms[entry[:label]] = begin
      driver_name = default_driver_name(entry[:name])
      text = EnumDriverGen.driver_source(file, entry[:owner], entry[:name], driver_name, line: line)
      Form.new(entry[:owner], nil, nil, text, nil, true, entry[:name], driver_name)
    rescue EnumDriverGen::Refused
      nil
    end
  end

  # Whether the entry's saved body may leave the binary under the flag: its form covers that body (Form#stubs_body).
  def stubs_body?(entry, singleton)
    form = form_for(entry, singleton)
    !form.nil? && form.stubs_body
  end

  # The C++ text the generated unit needs when an owner's #each is guarded: the generic save helper, then each used
  # form's step, open and driver source. Empty otherwise, so a flag at 0 adds no line.
  def helpers(compiled)
    return '' unless enabled?

    used = compiled.filter_map { |entry| form_for(entry, false) }.uniq { |form| [form.owner, form.method_name] }
    return '' if used.empty?

    <<~CPP + used.map { |form| form_text(form) }.join
      // ENUM_STEP -- the step form of an owner's #each (tools/bc2cpp/codegen_enum_step.rb, docs/bc2cpp-enum-step.md).
      // The first registration of a body still in bytecode loads the owner's driver, which takes the body's place in
      // the saved table; a second registration finds the compiled entry and the driver already saved.
      [[maybe_unused]] static bool bc2cpp_enum_step_save(mrb_state* M, struct RClass* c, bool singleton, const char* name,
                                                         mrb_int index, mrb_func_t step, mrb_func_t open, const char* driver_src,
                                                         const char* driver_name = "#{DRIVER_METHOD}") {
        struct RClass* target = singleton ? mrb_singleton_class_ptr(M, mrb_obj_value(c)) : c;
        struct RClass* found = target;
        mrb_method_t m = mrb_method_search_vm(M, &found, mrb_intern_cstr(M, name));
        if (found == target && !MRB_METHOD_UNDEF_P(m) && MRB_METHOD_PROC_P(m) && !MRB_PROC_CFUNC_P(MRB_METHOD_PROC(m))) {
          if (step) mrb_define_private_method(M, c, "#{STEP_METHOD}", step, MRB_ARGS_REQ(1));
          if (open) mrb_define_private_method(M, c, "#{OPEN_METHOD}", open, MRB_ARGS_NONE());
          mrb_load_string(M, driver_src);
          if (M->exc) {
            mrb_print_error(M);
            M->exc = nullptr;
            return false;
          }
        }
        return bc2cpp_core_save_interpreted(M, c, singleton, driver_name, index);
      }

    CPP
  end

  def form_text(form)
    <<~CPP
      #{form.c}
      static const char* const #{form.src_name} = R"RUBY(
      #{form.driver.respond_to?(:call) ? form.driver.call : form.driver}
      )RUBY";

    CPP
  end
end
