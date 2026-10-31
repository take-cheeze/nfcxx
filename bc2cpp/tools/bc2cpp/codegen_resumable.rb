# frozen_string_literal: true

require_relative 'bytecode_ir_resumable'

# CodeGen: resumable compiled methods. A method that reaches Fiber.yield cannot
# keep its registers in C++ locals: the yield returns to the fiber's resumer, so everything
# it needs lives in a heap frame and the method is compiled as a step function that a
# bytecode driver calls again after each Fiber.yield.

# One yield point is a state number; F->slots holds the counters of flat inlined loops.
class ResumableCtx
  attr_reader :label, :helpers, :states, :reasons
  attr_accessor :flat, :helper_stack, :sites
  # Set when the step function is emitted: the frame's register count, and each register's index in the frame (R[index]).
  attr_accessor :nregs, :register_slots

  def initialize(label, helpers)
    @label = label
    @helpers = helpers
    @states = []
    @reasons = []
    @slots = 0
    @sites = 0
    @flat = false
    @helper_stack = []
  end

  def new_state = (@states << @states.size + 1).last

  def new_slot
    @slots += 1
    @slots - 1
  end

  def slot_count = @slots
  def new_site = (@sites += 1)
end

class CodeGen
  # Depth of yielding helpers inlined into each other. The register file grows by a helper
  # frame per level, so a small bound keeps the frame small and rules out recursion.
  RESUMABLE_HELPER_DEPTH = 4

  def with_resumable_flat(flat)
    return yield unless @resumable

    saved = @resumable.flat
    @resumable.flat = flat
    begin
      yield
    ensure
      @resumable.flat = saved
    end
  end

  # Separate C++ functions (block fallback bodies) are not part of the step function's
  # frame; a yield compiled into one could never be resumed.
  module ResumableFlatGuards
    def emit_proc_fallback_fn(*args, **kwargs)
      with_resumable_flat(false) { super }
    end
  end
  prepend ResumableFlatGuards

  # ---------------------------------------------------------------------------
  # Analysis
  # ---------------------------------------------------------------------------

  # True if the irep, or a block nested in it, calls Fiber.yield. A Fiber.new block is another
  # fiber's body (`fiber_bodies`): a yield there returns to that fiber's resumer, so it is not
  # above the method that builds the fiber.
  def deep_fiber_yield?(irep, fiber_bodies, seen = Set.new.compare_by_identity)
    return false unless seen.add?(irep)

    BytecodeIR.for(irep).each_with_op(:SEND, :SEND0) do |insn, idx|
      next unless insn.sym == 'yield'

      dest = insn.reg
      return true if dest && fiber_const_receiver?(irep, idx, dest)
    end
    nested_ireps(irep, fiber_bodies).any? { |child| deep_fiber_yield?(child, fiber_bodies, seen) }
  end

  # Every method name called anywhere in the irep tree (block bodies included, Fiber.new blocks not).
  def deep_called_names(irep, fiber_bodies, names = Set.new, seen = Set.new.compare_by_identity)
    return names unless seen.add?(irep)

    BytecodeIR.for(irep).instructions_with_op(:SEND, :SEND0, :SENDB, :SSEND, :SSEND0, :SSENDB).each do |insn|
      names << insn.sym if insn.sym
    end
    nested_ireps(irep, fiber_bodies).each { |child| deep_called_names(child, fiber_bodies, names, seen) }
    names
  end

  def nested_ireps(irep, fiber_bodies)
    (irep.reps || []).filter_map { |child| @ireps[child] if child && !fiber_bodies.include?(child) }
  end

  # Names of the methods that can reach Fiber.yield: a body that calls it, and, by name and
  # whatever the receiver, any method calling such a name. Over-approximate on purpose: a
  # method outside this set is not on the native stack of any yield.
  def compute_fiber_yield_names(fiber_bodies)
    defs = @registry.values.flatten.select(&:irep)
    direct = defs.select { |d| deep_fiber_yield?(@ireps.fetch(d.irep), fiber_bodies) }
    names = direct.to_set(&:name)
    calls = defs.map { |d| [d.name, deep_called_names(@ireps.fetch(d.irep), fiber_bodies)] }
    loop do
      grown = calls.select { |name, called| !names.include?(name) && called.intersect?(names) }.map(&:first)
      break if grown.empty?

      names.merge(grown)
    end
    names
  end

  # Names of the methods a `Fiber.new { ... }` block body calls directly on self (not from a
  # nested block): the roots that are compiled as resumable when they qualify.
  def fiber_block_root_targets(seed_irep)
    BytecodeIR.for(seed_irep).instructions_with_op(:SSEND, :SSEND0).filter_map(&:sym)
  end

  ResumablePlan = Struct.new(:label, :helpers)

  # nil if the method is not a Fiber.new root, a reason String if it is one but cannot be
  # compiled resumable, else a ResumablePlan. Memoized; a pure function of the program.
  def resumable_plan(label)
    @resumable_plans ||= {}
    return @resumable_plans[label] if @resumable_plans.key?(label)

    @resumable_plans[label] = build_resumable_plan(label)
  end

  def resumable_method?(label)
    resumable_plan(label).is_a?(ResumablePlan)
  end

  def build_resumable_plan(label)
    return nil unless @fiber_roots&.include?(label)

    d = @owner_of[label]
    irep = @ireps[label]
    reason = resumable_shape_problem(irep, d)
    return reason if reason

    helpers = {}
    reason = collect_resumable_helpers(irep, d, helpers, [label])
    reason || ResumablePlan.new(label, helpers)
  end

  def resumable_shape_problem(irep, d)
    # enter_fields: required, optional, rest, post, keyword, keyword rest, block. Required positional arguments are
    # copied into the frame when the call starts (resumable_entry_function); the others are not supported yet.
    fields = (irep.enter ? irep.enter.enter_fields.map(&:to_i) : []) + [0] * 7
    return 'takes an optional, rest, post, keyword or block argument' if fields[1..6].any?(&:positive?)
    return 'has a rescue or ensure handler' unless irep.catch_handlers.empty?

    nil
  end

  # Finds the yielding helpers a method (transitively) calls and checks that each can be
  # inlined at its call sites; fills `helpers` (name => irep label). Returns a reason or nil.
  def collect_resumable_helpers(irep, d, helpers, stack, seen = Set.new.compare_by_identity)
    return nil unless seen.add?(irep)

    program = BytecodeIR.for(irep)
    program.each_with_op(:SEND, :SEND0, :SENDB, :SSEND, :SSEND0, :SSENDB) do |insn, idx|
      name = insn.sym
      next unless name

      if name == 'yield' && insn.reg && fiber_const_receiver?(irep, idx, insn.reg)
        argc = fiber_yield_argc(insn)
        return "calls Fiber.yield with #{argc.inspect} arguments (only 0 or 1 round-trip)" unless [0, 1].include?(argc)

        next
      end
      next unless @fiber_yield_names.include?(name)

      unless %i[SSEND SSEND0].include?(insn.op)
        return "calls the yielding method #{name} with an explicit receiver or a block"
      end
      next if helpers.key?(name)

      reason = resumable_helper_problem(name, d, stack)
      return reason if reason

      helper_label = @registry[name].first.irep
      helpers[name] = helper_label
      reason = collect_resumable_helpers(@ireps.fetch(helper_label), d, helpers, stack + [helper_label])
      return reason if reason
    end
    (irep.reps || []).each do |child|
      child_irep = child && @ireps[child]
      next unless child_irep

      reason = collect_resumable_helpers(child_irep, d, helpers, stack, seen)
      return reason if reason
    end
    nil
  end

  def resumable_helper_problem(name, d, stack)
    defs = @registry[name]
    return "calls the yielding method #{name}, which has #{defs&.size || 0} definitions" unless defs&.size == 1

    target = defs.first
    return "calls #{name}, which is not defined in #{d.owner}" unless target.irep && target.owner == d.owner && !target.core
    return "calls itself through #{name}" if stack.include?(target.irep)
    return "nests yielding helpers deeper than #{RESUMABLE_HELPER_DEPTH}" if stack.size > RESUMABLE_HELPER_DEPTH

    helper = @ireps.fetch(target.irep)
    return "calls #{name}, which takes arguments" unless helper.enter.nil? || helper.enter.enter_fields.all?(&:zero?)
    return "calls #{name}, which has a rescue or ensure handler" unless helper.catch_handlers.empty?
    return "calls #{name}, which builds a block" unless (helper.reps || []).empty?
    return "calls #{name}, which has unsupported helper control flow" unless BytecodeIR::ResumableRegion.build(helper)

    nil
  end

  # ---------------------------------------------------------------------------
  # Instruction level: yield points and inlined helper calls
  # ---------------------------------------------------------------------------

  # compile_insn's hook. Returns the replacement code for Fiber.yield and for a call to a
  # yielding helper, nil for everything else. Outside a flat context (a fallback block
  # function, a non-step inline loop) both are `#error`: no frame is there to resume.
  def resumable_intercept(insn, irep, d, idx, reg_offset)
    case insn.op
    when :SEND, :SEND0
      return nil unless insn.sym == 'yield' && idx

      dest = insn.reg - reg_offset
      return nil unless fiber_const_receiver?(irep, idx, dest)

      resumable_yield_site(insn)
    when :SSEND, :SSEND0
      return nil unless @fiber_yield_names.include?(insn.sym)

      resumable_helper_call(insn, irep, idx, reg_offset)
    end
  end

  # An `#error` line for something the step function cannot express; the reason is kept so the
  # method's refusal can be logged with it.
  def resumable_error(message)
    @resumable.reasons << message
    "  #error resumable method: #{message}\n"
  end

  def resumable_not_flat_error(what)
    resumable_error("#{what} inside a block or loop that is not inlined into the step function")
  end

  # Positional argument count of a Fiber.yield call, nil for a splat or keywords. Only 0 and 1
  # round-trip: `Fiber.yield a, b` yields an Array that the driver's one-value yield cannot rebuild.
  def fiber_yield_argc(insn)
    return 0 if insn.op == :SEND0

    insn.plain_fixed_argc? ? insn.argc : nil
  end

  def resumable_yield_site(insn)
    return resumable_not_flat_error('Fiber.yield') unless @resumable.flat

    argc = fiber_yield_argc(insn)
    return resumable_error("Fiber.yield with #{argc.inspect} arguments") unless [0, 1].include?(argc)

    state = @resumable.new_state
    dest = insn.reg
    value = argc.zero? ? 'mrb_nil_value()' : "r#{dest.to_i + 1}"
    [
      "  // RESUMABLE_YIELD #{state}",
      "  R[0] = #{value};",
      "  F->state = #{state};",
      '  bc2cpp_step_guard.yielding = true;',
      RESUMABLE_SPILL_MARK,
      '  mrb_write_barrier(M, (struct RBasic*)mrb_ary_ptr(bc2cpp_regs_ary));',
      '  return bc2cpp_frame_value;',
      "  Lbc2cpp_resume_#{state}:;",
      "  r#{dest} = R[1];",
      ''
    ].join("\n")
  end

  # Inlines a yielding helper (wait_one_clock, ...) at its call site: its registers follow
  # the caller's in the frame, its `return` assigns the call's destination and jumps past
  # the body, and its jump labels are prefixed per site.
  def resumable_helper_call(insn, irep, idx, reg_offset)
    name = insn.sym
    return resumable_not_flat_error("call to the yielding method #{name}") unless @resumable.flat

    label = @resumable.helpers[name]
    return resumable_error("no inlinable helper #{name}") unless label
    return resumable_error("helper #{name} called with arguments") unless insn.op == :SSEND0 || insn.argc == 0

    helper = @ireps.fetch(label)
    region = BytecodeIR::ResumableRegion.build(helper)
    return resumable_error("helper #{name} has unsupported control flow") unless region

    helper_def = @owner_of.fetch(label)
    return resumable_error("helper #{name} calls itself") if @resumable.helper_stack.include?(label)
    return resumable_error("helper nesting too deep at #{name}") if @resumable.helper_stack.size >= RESUMABLE_HELPER_DEPTH

    base = reg_offset + irep.nregs
    dest = insn.reg.to_i
    site = @resumable.new_site
    prefix = "LH#{site}_"
    end_label = "Lbc2cpp_helper_#{site}_end"
    out = String.new
    out << "  // RESUMABLE_HELPER #{name}\n"
    (1...helper.nregs).each { |i| out << "  r#{base + i} = mrb_nil_value();\n" }
    out << "  r#{base} = self;\n"
    targets = region.program.branch_targets
    saved_nested = @inline_nested
    @inline_nested = nil
    @resumable.helper_stack.push(label)
    begin
      region.program.instructions.each do |node|
        hinsn = node.source
        next if hinsn.op == :ENTER

        out << "  #{prefix}#{hinsn.addr}:;\n" if targets.include?(hinsn.addr)
        out << resumable_helper_insn(hinsn, helper, helper_def, base, dest, end_label, prefix, node.index)
      end
    ensure
      @resumable.helper_stack.pop
      @inline_nested = saved_nested
    end
    out << "  #{end_label}:;\n"
  end

  def resumable_helper_insn(hinsn, helper, helper_def, base, dest, end_label, prefix, hidx)
    case hinsn.op
    when :RETURN then "  r#{dest} = r#{hinsn.reg.to_i + base};\n  goto #{end_label};\n"
    when :RETNIL then "  r#{dest} = mrb_nil_value();\n  goto #{end_label};\n"
    when :RETTRUE then "  r#{dest} = mrb_true_value();\n  goto #{end_label};\n"
    when :RETFALSE then "  r#{dest} = mrb_false_value();\n  goto #{end_label};\n"
    when :RETSELF then "  r#{dest} = self;\n  goto #{end_label};\n"
    else
      # No block, no break: the nil break label makes BREAK an `#error`.
      compile_block_body_insn(hinsn, helper, helper_def, base, end_label, prefix, idx: hidx)
    end
  end

  # ---------------------------------------------------------------------------
  # Function assembly
  # ---------------------------------------------------------------------------

  RESUMABLE_REGISTER_TOKENS = %r{
    R"(?<delimiter>[^ ()\\\t\r\n]{0,16})\(.*?\)\k<delimiter>"
    |"(?:\\.|[^"\\])*"
    |'(?:\\.|[^'\\])*'
    |//[^\n]*
    |/\*.*?\*/
    |\br(?<reg>\d+)\b
  }mx

  # Placeholder in a yield site for the stores that copy local registers back into the frame.
  RESUMABLE_SPILL_MARK = '  // RESUMABLE_SPILL'
  # `&rN` outside literals and comments: a pointer to a register that may outlive the step.
  RESUMABLE_REGISTER_ADDRESS = /(?<![&\w])&\s*r\d+\b/

  # The step function's opening: the frame, the registers, and the dispatch to the state saved
  # by the last yield. Only register identifiers need slots.
  # RESUMABLE_LOCAL_REGISTERS: the registers are C++ locals, loaded on entry and stored back at each
  # yield (docs/bc2cpp-resumable-locals.md). A body that takes a register's address keeps references
  # into the frame, since that pointer must reach the same cell after a resume.
  def resumable_step_function(step_name, body)
    registers = Set[0]
    # Literal contents and comments cannot name frame registers. R[0] and R[1]
    # remain the yield/resume cells; ordinary registers have dense aliases.
    body.scan(RESUMABLE_REGISTER_TOKENS) do
      reg = Regexp.last_match[:reg]
      registers << reg.to_i if reg
    end
    code_only = body.gsub(RESUMABLE_REGISTER_TOKENS) { |token| token.match?(/\Ar\d+\z/) ? token : ' ' }
    registers = registers.sort
    nregs = registers.size
    @resumable.nregs = nregs
    @resumable.register_slots = registers.each_with_index.to_h { |reg, slot| [reg, slot + 2] }
    locals = ENV['BC2CPP_RESUMABLE_LOCALS'] != '0' && !code_only.match?(RESUMABLE_REGISTER_ADDRESS)
    spill = registers.each_with_index.map { |reg, slot| "R[#{slot + 2}] = r#{reg};" }.join(' ')
    body = body.gsub(/^#{Regexp.escape(RESUMABLE_SPILL_MARK)}$/) { locals ? "  #{spill}" : '' }
    out = String.new
    out << "static mrb_value #{step_name}(mrb_state* M, mrb_value self, mrb_value bc2cpp_frame_value, mrb_value bc2cpp_resume) {\n"
    out << "  Bc2cppResumeFrame* F = bc2cpp_resume_frame(M, &bc2cpp_frame_value, #{nregs}, #{@resumable.slot_count});\n"
    out << "  mrb_value bc2cpp_regs_ary = bc2cpp_resume_regs(M, bc2cpp_frame_value);\n"
    out << "  mrb_value* R = F->regs;\n"
    out << "  Bc2cppStepGuard bc2cpp_step_guard(F);\n"
    out << "  // RESUMABLE_LOCAL_REGISTERS\n" if locals
    registers.each_with_index { |reg, slot| out << "  mrb_value#{'&' unless locals} r#{reg} = R[#{slot + 2}];\n" }
    out << "  const mrb_int bc2cpp_state = F->state;\n"
    out << "  if (bc2cpp_state != 0) R[1] = bc2cpp_resume;\n"
    out << "  r0 = self;\n"
    out << "  switch (bc2cpp_state) {\n    case 0: break;\n"
    @resumable.states.each { |n| out << "    case #{n}: goto Lbc2cpp_resume_#{n};\n" }
    out << "    default: bc2cpp_resume_bad_state(M);\n  }\n"
    out << body
    out
  end

  # `_impl`, the function the registered entry calls: hands a VM-called invocation to the
  # bytecode driver and steps to completion when called from C (where Fiber.yield could
  # not have worked in the bytecode either).
  def resumable_entry_function(impl_name, step_name, owner_name, arg_names = [], ctx = nil)
    thunk = "#{step_name}_thunk"
    if arg_names.empty?
      # No arguments: the frame starts empty, and the driver's first step creates it.
      return <<~CPP
        static mrb_value #{thunk}(mrb_state* M, mrb_value) {
          mrb_value self, frame, resume;
          mrb_get_args(M, "ooo", &self, &frame, &resume);
          return #{step_name}(M, self, frame, resume);
        }
        mrb_value #{impl_name}(mrb_state* M, mrb_value self) {
          bc2cpp_check_argc(M, 0, 0);
          bc2cpp_resumable_init(M);
          if (bc2cpp_resumable_exec_ok(M, 0)) return bc2cpp_resumable_exec(M, self, #{thunk}, mrb_nil_value());
          mrb_value frame = mrb_nil_value(), resume = mrb_nil_value();
          for (;;) {
            mrb_value result = #{step_name}(M, self, frame, resume);
            if (!bc2cpp_resume_frame_p(M, result)) return result;
            frame = result;
            resume = bc2cpp_resumable_yield_from_c(M, frame);
          }
        }
        // #{owner_name}: entry of a resumable method (RESUMABLE_ENTRY)
      CPP
    end
    # Required arguments: the frame is created here, with each argument in the register the body reads it from, and
    # handed to the driver, whose first step takes it instead of creating an empty one. The argument registers are
    # r1..rN; a register the body never reads has no slot and is not copied.
n = arg_names.size
params = arg_names.map { |a| "mrb_value #{a}" }.join(', ')
# Each argument's slot in the frame; a register the body never reads has none and is not copied.
fill = arg_names.each_with_index.filter_map do |a, idx|
  slot = ctx.register_slots[idx + 1]
  "F->regs[#{slot}] = #{a};" if slot
end
head = <<~CPP
  static mrb_value #{thunk}(mrb_state* M, mrb_value) {
    mrb_value self, frame, resume;
    mrb_get_args(M, "ooo", &self, &frame, &resume);
    return #{step_name}(M, self, frame, resume);
  }
  mrb_value #{impl_name}(mrb_state* M, mrb_value self, #{params}) {
    bc2cpp_check_argc(M, #{n}, #{n});
    bc2cpp_resumable_init(M);
    mrb_value frame = mrb_nil_value();
    Bc2cppResumeFrame* F = bc2cpp_resume_frame(M, &frame, #{ctx.nregs}, #{ctx.slot_count});
CPP
tail = <<~CPP
    mrb_write_barrier(M, (struct RBasic*)mrb_ary_ptr(bc2cpp_resume_regs(M, frame)));
    if (bc2cpp_resumable_exec_ok(M, #{n})) return bc2cpp_resumable_exec(M, self, #{thunk}, frame);
    mrb_value resume = mrb_nil_value();
    for (;;) {
      mrb_value result = #{step_name}(M, self, frame, resume);
      if (!bc2cpp_resume_frame_p(M, result)) return result;
      frame = result;
      resume = bc2cpp_resumable_yield_from_c(M, frame);
    }
  }
  // #{owner_name}: entry of a resumable method with #{n} required argument#{'s' unless n == 1} (RESUMABLE_ENTRY)
CPP
head + fill.map { |line| "  #{line}\n" }.join + tail
  end

  # The run-time half, emitted once per generated file that has a resumable method.
  def emit_resumable_helpers(compiled)
    return '' unless compiled.any? { |m| m[:resumable] }

    "#{RESUMABLE_HELPERS_CPP.sub('@DRIVER@') { resumable_driver_bytes }}\n"
  end

  # Loaded from inside a running method, so the module and every constant it names are
  # spelled from the top level: a bare `module` would nest in that method's class.
  RESUMABLE_DRIVER_RB = <<~'RUBY'
    module ::Bc2cppResumable
      def drive(&step)
        f = step.call(self, ::Bc2cppResumable.take_initial, nil)
        while ::Bc2cppResumable::Frame === f
          f = step.call(self, f, ::Fiber.yield(f.value))
        end
        f
      end
    end
  RUBY

  # The driver compiled by the same mrbc that compiled the program: the bytes of a C array.
  def resumable_driver_bytes
    require 'tmpdir'
    Dir.mktmpdir('bc2cpp_driver') do |dir|
      File.write(File.join(dir, 'driver.rb'), RESUMABLE_DRIVER_RB)
      system(MRBC, '-Bbc2cpp_resumable_driver', '-o', File.join(dir, 'driver.c'), File.join(dir, 'driver.rb'),
             exception: true)
      File.read(File.join(dir, 'driver.c'))[/\{(.*)\};/m, 1].strip
    end
  end

  RESUMABLE_HELPERS_CPP = <<~'CPP'
    // RESUMABLE_HELPERS -- see codegen_resumable.rb (ADR 0273).
    extern "C" mrb_value mrb_exec_irep(mrb_state*, mrb_value, const struct RProc*);
    // Slots 0 and 1 of `regs` carry the yielded and the resumed value; the registers follow.
    // The GC marks `regs` through the RData's hidden ivar, and the array never grows.
    struct Bc2cppResumeFrame {
      mrb_int state;
      mrb_int nregs;
      mrb_value* regs;
      long long slots[1];
    };
    static void bc2cpp_resume_frame_free(mrb_state* M, void* p) { mrb_free(M, p); }
    static const mrb_data_type bc2cpp_resume_frame_type = { "Bc2cppResumable::Frame", bc2cpp_resume_frame_free };
    static mrb_sym bc2cpp_resume_regs_sym(mrb_state* M) { return mrb_intern_lit(M, "__bc2cpp_regs__"); }
    static struct RClass* bc2cpp_resume_frame_class(mrb_state* M) {
      return mrb_class_get_under(M, mrb_module_get(M, "Bc2cppResumable"), "Frame");
    }
    static bool bc2cpp_resume_frame_p(mrb_state* M, mrb_value v) {
      return mrb_data_p(v) && mrb_obj_ptr(v)->c == bc2cpp_resume_frame_class(M);
    }
    static mrb_value bc2cpp_resume_regs(mrb_state* M, mrb_value frame) {
      return mrb_iv_get(M, frame, bc2cpp_resume_regs_sym(M));
    }
    [[noreturn]] static void bc2cpp_resume_bad_state(mrb_state* M) {
      mrb_raise(M, mrb_exc_get_id(M, mrb_intern_lit(M, "RuntimeError")), "bc2cpp: resumable frame resumed in an unknown state");
    }
    // A new frame for a nil `*frame`, else the one the driver passed back.
    static Bc2cppResumeFrame* bc2cpp_resume_frame(mrb_state* M, mrb_value* frame, mrb_int nregs, mrb_int nslots) {
      if (mrb_nil_p(*frame)) {
        mrb_value regs = mrb_ary_new_capa(M, nregs + 2);
        for (mrb_int i = 0; i < nregs + 2; ++i) mrb_ary_push(M, regs, mrb_nil_value());
        size_t size = sizeof(Bc2cppResumeFrame) + sizeof(long long) * (size_t)nslots;
        Bc2cppResumeFrame* f = (Bc2cppResumeFrame*)mrb_calloc(M, 1, size);
        f->nregs = nregs;
        f->regs = ary_items(regs);
        *frame = mrb_obj_value(mrb_data_object_alloc(M, bc2cpp_resume_frame_class(M), f, &bc2cpp_resume_frame_type));
        mrb_iv_set(M, *frame, bc2cpp_resume_regs_sym(M), regs);
        return f;
      }
      Bc2cppResumeFrame* f = (Bc2cppResumeFrame*)mrb_data_check_get_ptr(M, *frame, &bc2cpp_resume_frame_type);
      if (!f || f->nregs != nregs) bc2cpp_resume_bad_state(M);
      return f;
    }
    // A step that returns instead of yielding is finished: drop the frame's references.
    struct Bc2cppStepGuard {
      Bc2cppResumeFrame* frame;
      bool yielding = false;
      explicit Bc2cppStepGuard(Bc2cppResumeFrame* f) : frame(f) {}
      ~Bc2cppStepGuard() {
        if (yielding) return;
        frame->state = -1;
        for (mrb_int i = 0; i < frame->nregs + 2; ++i) frame->regs[i] = mrb_nil_value();
      }
      Bc2cppStepGuard(const Bc2cppStepGuard&) = delete;
      Bc2cppStepGuard& operator=(const Bc2cppStepGuard&) = delete;
    };
    static mrb_value bc2cpp_resume_frame_value(mrb_state* M, mrb_value self) {
      Bc2cppResumeFrame* f = (Bc2cppResumeFrame*)DATA_PTR(self);
      return f ? f->regs[0] : mrb_nil_value();
    }
    static mrb_value bc2cpp_resumable_take_initial(mrb_state* M, mrb_value self);
    static void bc2cpp_resumable_init(mrb_state* M) {
      if (mrb_const_defined_at(M, mrb_obj_value(M->object_class), mrb_intern_lit(M, "Bc2cppResumable"))) return;
      static const uint8_t driver[] = {
    @DRIVER@
      };
      struct RClass* mod = mrb_define_module(M, "Bc2cppResumable");
      struct RClass* frame = mrb_define_class_under(M, mod, "Frame", M->object_class);
      MRB_SET_INSTANCE_TT(frame, MRB_TT_DATA);
      mrb_define_method(M, frame, "value", bc2cpp_resume_frame_value, MRB_ARGS_NONE());
      mrb_define_module_function(M, mod, "take_initial", bc2cpp_resumable_take_initial, MRB_ARGS_NONE());
      mrb_load_irep(M, driver);
      if (M->exc) mrb_exc_raise(M, mrb_obj_value(M->exc));
    }
    // Called from the VM straight (no C frame between the caller and this entry), with no
    // arguments: the only situation in which the bytecode driver can Fiber.yield.
    static bool bc2cpp_resumable_exec_ok(mrb_state* M, mrb_int argc) {
      mrb_callinfo* ci = M->c->ci;
      return ci->cci == 0 && ci->n == argc && ci->nk == 0;
    }
    // The frame of a call with arguments, parked for the driver's first step (Bc2cppResumable.take_initial). It is
    // set just before the driver runs and cleared as soon as the driver returns, so no other call sees it.
    static void bc2cpp_resumable_handoff(mrb_state* M, mrb_value frame) {
      struct RClass* mod = mrb_module_get(M, "Bc2cppResumable");
      mrb_iv_set(M, mrb_obj_value(mod), mrb_intern_lit(M, "__handoff__"), frame);
    }
    static mrb_value bc2cpp_resumable_take_initial(mrb_state* M, mrb_value self) {
      mrb_sym sym = mrb_intern_lit(M, "__handoff__");
      mrb_value frame = mrb_iv_get(M, self, sym);
      mrb_iv_set(M, self, sym, mrb_nil_value());
      return frame;
    }
    // exec_irep leaves the block slot (stack[1] for a call without arguments) to the new
    // frame, whose `&step` parameter is the cfunc proc that runs the step function.
    static mrb_value bc2cpp_resumable_exec(mrb_state* M, mrb_value self, mrb_func_t thunk, mrb_value frame) {
      struct RClass* mod = mrb_module_get(M, "Bc2cppResumable");
      struct RClass* found = mod;
      mrb_method_t m = mrb_method_search_vm(M, &found, mrb_intern_lit(M, "drive"));
      if (MRB_METHOD_UNDEF_P(m) || !MRB_METHOD_PROC_P(m)) {
        mrb_raise(M, mrb_exc_get_id(M, mrb_intern_lit(M, "RuntimeError")), "bc2cpp: Bc2cppResumable#drive is missing");
      }
      // The driver takes no positional arguments: it is entered as a call with none, so the block sits in slot 1, and
      // the caller's own argument count is put back afterwards. The arguments are already in the frame.
      mrb_int argc = M->c->ci->n;
      ptrdiff_t idx = M->c->ci - M->c->cibase;
      M->c->ci->stack[1] = mrb_obj_value(mrb_proc_new_cfunc(M, thunk));
      M->c->ci->n = 0;
      bc2cpp_resumable_handoff(M, frame);
      mrb_value result = mrb_exec_irep(M, self, MRB_METHOD_PROC(m));
      bc2cpp_resumable_handoff(M, mrb_nil_value());
      M->c->cibase[idx].n = argc;
      return result;
    }
    // A step of a method called from C yielded: hand it to the real Fiber.yield, which raises
    // the FiberError the interpreted method would have raised.
    static mrb_value bc2cpp_resumable_yield_from_c(mrb_state* M, mrb_value frame) {
      mrb_value value = bc2cpp_resume_frame_value(M, frame);
      return mrb_funcall(M, mrb_obj_value(mrb_class_get(M, "Fiber")), "yield", 1, value);
    }
  CPP
end
