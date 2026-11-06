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
  # BLOCK: the method takes a block (kept in the frame's block slot). block_slot is that slot's R index.
  attr_accessor :block, :block_slot
  # OPTIONAL_ARGS: how many optional positional arguments the method takes (its jump table is the glue at the first
  # JMP, which switches on bc2cpp_given_opt). 0 for a method without optional arguments.
  attr_accessor :optional

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
    each_nested_irep(irep, fiber_bodies) { |child| return true if deep_fiber_yield?(child, fiber_bodies, seen) }
    false
  end

  # Every method name called anywhere in the irep tree (block bodies included, Fiber.new blocks not).
  def deep_called_names(irep, fiber_bodies, names = Set.new, seen = Set.new.compare_by_identity)
    return names unless seen.add?(irep)

    BytecodeIR.for(irep).instructions_with_op(:SEND, :SEND0, :SENDB, :SSEND, :SSEND0, :SSENDB).each do |insn|
      names << insn.sym if insn.sym
    end
    each_nested_irep(irep, fiber_bodies) { |child| deep_called_names(child, fiber_bodies, names, seen) }
    names
  end

  def each_nested_irep(irep, fiber_bodies)
    irep.reps&.each do |child|
      nested = child && !fiber_bodies.include?(child) && @ireps[child]
      yield nested if nested
    end
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
    BytecodeIR.for(seed_irep).instructions_with_op(:SSEND, :SSEND0, :SSENDB).filter_map(&:sym)
  end

  # Names of the methods a `Fiber.new { ... }` block body calls on an explicit receiver: candidates for roots whose owner
  # the body does not prove (RECEIVER_ROOTS, codegen_block_fallback.rb).
  def fiber_receiver_call_names(seed_irep)
    BytecodeIR.for(seed_irep).instructions_with_op(:SEND, :SEND0, :SENDB).filter_map(&:sym)
  end

  ResumablePlan = Struct.new(:label, :helpers)

  # nil if the method is not a Fiber.new root, a reason String if it is one but cannot be
  # compiled resumable, else a ResumablePlan. Memoized; a pure function of the program.
  def resumable_plan(label)
    return build_resumable_plan(label) if @rsm_variant # RESUMABLE_DUAL: a variant does not need a Fiber root
    @resumable_plans ||= {}
    return @resumable_plans[label] if @resumable_plans.key?(label)

    @resumable_plans[label] = build_resumable_plan(label)
  end

  def resumable_method?(label)
    resumable_plan(label).is_a?(ResumablePlan)
  end

  def build_resumable_plan(label)
    return nil unless @fiber_roots&.include?(label) || @rsm_variant

    d = @owner_of[label]
    irep = @ireps[label]
    reason = resumable_shape_problem(irep, d)
    return reason if reason

    helpers = {}
    reason = collect_resumable_helpers(irep, d, helpers, [label])
    reason || ResumablePlan.new(label, helpers)
  end

  def resumable_shape_problem(irep, d)
    # enter_fields: required, optional, rest, post, keyword, keyword rest, block.
    # The entry copies positional arguments and the block into the frame.
    fields = (irep.enter ? irep.enter.enter_fields.map(&:to_i) : []) + [0] * 7
    return 'takes a post or keyword argument' if fields[3..5].any?(&:positive?)
    # The step must use the same optional jump table as compile_method, including an explicit block parameter.
    if fields[1].positive?
      table = if fields[2].positive?
                optional_rest_arg_table(irep)
              elsif fields[6].positive?
                optional_block_arg_table(irep)
              else
                optional_arg_table(irep)
              end
      return 'takes optional arguments in a shape the step cannot enter' unless table && table[1]
    end
    # REST_ARGS: a rest argument the wrapper builds into an Array (rest_only_arity? is the shape it recognises).
    return 'takes a rest argument in a shape the step cannot enter' if fields[2].positive? && fields[1].zero? && !rest_only_arity?(irep)
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
    when :BLKCALL
      return nil unless idx && @resumable.block

      resumable_block_site(insn)
    when :SEND, :SEND0
      return resumable_block_call_intercept(insn, irep, d, idx, reg_offset) if block_call_site?(insn, idx, reg_offset)
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

  # A `yield` (BLKCALL R n argc) of the method's own block: the step returns a frame whose arguments are the yielded
  # values, and the driver calls the block with them (Bc2cppResumable.drive); the block's value is the resume value.
  # The block runs from the driver's VM frame, so a Fiber.yield inside it has only VM frames to cross.
  def resumable_block_site(insn, argc: insn.uint_operand.to_i)
    return resumable_not_flat_error('yield') unless @resumable.flat

    state = @resumable.new_state
    dest = insn.reg
    values = (1..argc).map { |i| "r#{dest.to_i + i}" }
    packed = values.empty? ? 'mrb_ary_new(M)' : "bc2cpp_block_args_from(M, {#{values.join(', ')}})"
    [
      "  // RESUMABLE_BLOCK_CALL #{state}",
      "  F->state = #{state};",
      '  bc2cpp_step_guard.yielding = true;',
      RESUMABLE_SPILL_MARK,
      "  R[0] = #{packed};",
      '  mrb_write_barrier(M, (struct RBasic*)mrb_ary_ptr(bc2cpp_regs_ary));',
      '  bc2cpp_resume_frame_set_call(M, bc2cpp_frame_value, true);',
      '  return bc2cpp_frame_value;',
      "  Lbc2cpp_resume_#{state}:;",
      "  r#{dest} = R[1];",
      ''
    ].join("\n")
  end

  # `block.call(a, ...)` on the method's own block (a SEND of :call with fixed arguments, in the step's own body): Proc#call
  # is a C function, so the block would run under a C frame that Fiber.yield cannot cross. The site suspends the step as
  # a `yield` does, when the receiver is the entry block at run time; any other receiver takes the ordinary send.
  # Identity is tested at run time, so no alias of the block register needs tracking.
  def block_call_site?(insn, idx, reg_offset)
    return false unless insn.op == :SEND && insn.sym == 'call' && idx && @resumable&.block && @resumable.flat
    return false if @resumable_plain || reg_offset != 0

    insn.plain_fixed_argc?
  end

  def resumable_block_call_intercept(insn, irep, d, idx, reg_offset)
    dest = insn.reg
    suspend = resumable_block_site(insn, argc: insn.argc)
    plain = begin
      @resumable_plain = true
      compile_insn_op(insn, irep, d, idx, reg_offset)
    ensure
      @resumable_plain = false
    end
    [
      "  if (mrb_obj_eq(M, r#{dest}, bc2cpp_blk) && !mrb_nil_p(bc2cpp_blk)) {",
      suspend.rstrip,
      '  } else {',
      plain.rstrip,
      '  }',
      ''
    ].join("\n")
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
      '  bc2cpp_resume_frame_set_call(M, bc2cpp_frame_value, false);',
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
    # One pass collects the registers and blanks every other token: only the `reg` alternative starts with `r`.
    code_only = body.gsub(RESUMABLE_REGISTER_TOKENS) do |token|
      reg = Regexp.last_match[:reg]
      next ' ' unless reg

      registers << reg.to_i
      token
    end
    registers = registers.sort
    # BLOCK_SLOT: a method with a block keeps it in the frame's last register (the block is the same for every call
    # of the step, so no spill), and the step reads it into bc2cpp_blk, which yield (BLKPUSH) reads.
    block_slot = @resumable.block ? registers.size + 2 : nil
    nregs = registers.size + (@resumable.block ? 1 : 0)
    @resumable.nregs = nregs
    @resumable.block_slot = block_slot
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
    out << "  [[maybe_unused]] mrb_value bc2cpp_blk = R[#{block_slot}];\n" if block_slot
    out << "  const mrb_int bc2cpp_state = F->state;\n"
    # OPTIONAL_ARGS: a call that starts stores -(given + 1) in the frame state (the entry does). The body's jump-table
    # glue switches on bc2cpp_given_opt, and the resume switch is skipped for that start.
    optional = @resumable.optional.to_i.positive?
    out << "  const mrb_int bc2cpp_given_opt = bc2cpp_state < 0 ? -bc2cpp_state - 1 : 0;\n" if optional
    out << "  if (bc2cpp_state != 0) R[1] = bc2cpp_resume;\n"
    out << "  r0 = self;\n"
    out << (optional ? "  if (bc2cpp_state >= 0) switch (bc2cpp_state) {\n    case 0: break;\n" : "  switch (bc2cpp_state) {\n    case 0: break;\n")
    @resumable.states.each { |n| out << "    case #{n}: goto Lbc2cpp_resume_#{n};\n" }
    out << "    default: bc2cpp_resume_bad_state(M);\n  }\n"
    out << body
    out
  end

  # `_impl`, the function the registered entry calls: hands a VM-called invocation to the
  # bytecode driver and steps to completion when called from C (where Fiber.yield could
  # not have worked in the bytecode either).
  def resumable_entry_function(impl_name, step_name, owner_name, arg_names = [], ctx = nil, blk = false, optional: 0, rest: false)
    thunk = "#{step_name}_thunk"
    if arg_names.empty? && !blk
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
          mrb_value frame = mrb_nil_value(), resume = mrb_nil_value();
          if (bc2cpp_prologue_armed(M, #{c_string_literal(owner_name)}, self)) {
            return bc2cpp_prologue_park(bc2cpp_method_frame_new(M, #{step_name}, self, frame));
          }
          for (;;) {
            mrb_value result = #{step_name}(M, self, frame, resume);
            if (!bc2cpp_resume_frame_p(M, result)) return result;
            frame = result;
            resume = bc2cpp_resumable_resume_from_c(M, frame);
          }
        }
        // #{owner_name}: entry of a resumable method (RESUMABLE_ENTRY)
      CPP
    end
    # Required arguments: the frame is created here, with each argument in the register the body reads it from, and
    # handed to the driver, whose first step takes it instead of creating an empty one. The argument registers are
    # r1..rN; a register the body never reads has no slot and is not copied.
n = arg_names.size
# OPTIONAL_ARGS: the last `optional` names are optional. The entry takes every positional argument (an omitted one is
# nil, and the body's default-value code sets it), and records how many optionals the call gave in the frame state.
req = n - optional
# The registered wrapper computes the given count (mrb_get_argc - required, clamped) and passes it last, as for any method
# with optionals (codegen_method.rb, arg_params).
params = (arg_names.map { |a| "mrb_value #{a}" } + (blk ? ['mrb_value bc2cpp_blk'] : []) +
          (optional.positive? ? ['mrb_int bc2cpp_given_opt'] : [])).join(', ')
# Each argument's slot in the frame; a register the body never reads has none and is not copied.
fill = arg_names.each_with_index.filter_map do |a, idx|
  slot = ctx.register_slots[idx + 1]
  "F->regs[#{slot}] = #{a};" if slot
end
# The block goes in the frame's block slot, and in the frame's __block__ for the driver to call.
if blk
  # mruby keeps the block in register argc+1, which `yield` (BLKPUSH) reads, so that register's slot gets it too.
  block_reg_slot = ctx.register_slots[n + 1]
  fill += ['mrb_iv_set(M, frame, mrb_intern_lit(M, "__block__"), bc2cpp_blk);', "F->regs[#{ctx.block_slot}] = bc2cpp_blk;"]
  fill << "F->regs[#{block_reg_slot}] = bc2cpp_blk;" if block_reg_slot
end
optional_head = optional.positive? ? "    F->state = -(bc2cpp_given_opt + 1);\n" : ''
# REST_ARGS: the wrapper checked the count and built the rest Array, so the impl checks nothing.
argc_check = rest || @block_step_compile ? '' : "bc2cpp_check_argc(M, #{req}, #{n});\n  "
head = <<~CPP
  static mrb_value #{thunk}(mrb_state* M, mrb_value) {
    mrb_value self, frame, resume;
    mrb_get_args(M, "ooo", &self, &frame, &resume);
    return #{step_name}(M, self, frame, resume);
  }
  mrb_value #{impl_name}(mrb_state* M, mrb_value self, #{params}) {
  #{argc_check}bc2cpp_resumable_init(M);#{blk ? "\n  if (bc2cpp_prologue_armed(M, #{c_string_literal(owner_name)}, self)) bc2cpp_blk = bc2cpp_env_block(M, bc2cpp_blk);" : ''}
    mrb_value frame = mrb_nil_value();
    Bc2cppResumeFrame* F = bc2cpp_resume_frame(M, &frame, #{ctx.nregs}, #{ctx.slot_count});
CPP
tail = <<~CPP
    mrb_write_barrier(M, (struct RBasic*)mrb_ary_ptr(bc2cpp_resume_regs(M, frame)));
    if (bc2cpp_prologue_armed(M, #{c_string_literal(owner_name)}, self)) {
      return bc2cpp_prologue_park(bc2cpp_method_frame_new(M, #{step_name}, self, frame));
    }
    mrb_value resume = mrb_nil_value();
    for (;;) {
      mrb_value result = #{step_name}(M, self, frame, resume);
      if (!bc2cpp_resume_frame_p(M, result)) return result;
      frame = result;
      resume = bc2cpp_resumable_resume_from_c(M, frame);
    }
  }
  // #{owner_name}: entry of a resumable method with #{req} required argument#{'s' unless req == 1}#{", #{optional} optional" if optional.positive?} (RESUMABLE_ENTRY)
CPP
head + optional_head + fill.map { |line| "  #{line}\n" }.join + tail
  end

  # The run-time half, emitted once per generated file that has a resumable method or a Fiber body.
  def emit_resumable_helpers(compiled)
    return '' unless compiled.any? { |m| m[:resumable] } || @fiber_body_used

    "#{RESUMABLE_HELPERS_CPP}\n#{fiber_runtime_cpp}\n"
  end

  FIBER_RUNTIME_DIR = File.expand_path('runtime', __dir__)

  # The C++ Fiber runtime (tools/bc2cpp/runtime): its text goes into the generated file, so a build needs no extra
  # include path. bc2cpp_fiber.hxx is standalone; bc2cpp_fiber_methods.hxx uses the helpers just before it.
  def fiber_runtime_cpp
    %w[bc2cpp_fiber.hxx bc2cpp_fiber_methods.hxx].map do |name|
      File.read(File.join(FIBER_RUNTIME_DIR, name)).gsub(/^#pragma once\n/, '')
    end.join("\n")
  end

  # Ops a Fiber body's prologue may use before its tail call: they read the receiver's state and make constants, so
  # none of them can reach a suspendable method.
  FIBER_BODY_PLAIN_OPS = %i[ENTER GETIV GETUPVAR MOVE LOADSELF LOADNIL LOADT LOADF LOADSYM LOADL STRING].freeze

  # `Fiber.new { prologue; m(args) }`: the block ends with a call on self to a suspendable method `m` of the
  # enclosing method's owner and returns its value. The block's only call is that one, so the C++ Fiber can run the block
  # with `m` armed (bc2cpp_prologue), let `m`'s entry park its frame instead of running it, and call that frame as
  # the fiber's body. Returns the entry's id ("Owner#m"), or nil for any other shape (the site then keeps its old form).
  def fiber_body_target_id(region, owner_def)
    return nil unless owner_def && region[:name] == 'new' && !region[:self_implicit] && region[:n].to_i.zero?

    parent = region[:parent_irep]
    idx = parent && parent.index_of_addr(region[:sendb_addr])
    return nil unless idx && fiber_const_receiver?(parent, idx, region[:dest_reg])

    fiber_body_target_in(region[:block_irep], owner_def)
  end

  # The recognizer's side of fiber_body_target_id (it runs before a region exists): true when the site at +idx+ is a
  # Fiber body that fiber_body_target_id will accept AND every local it captures is safe to copy by value, so a
  # region may take upvars without the synchronous-call gate. The same predicate decides the emission, so a body
  # that captures never reaches the frame-address form.
  def fiber_body_by_value?(irep, idx, paired, block_irep, upvars)
    return false unless paired.sym == 'new' && paired.op == :SENDB && paired.plain_fixed_argc? && paired.argc.to_i.zero?
    return false unless fiber_const_receiver?(irep, idx, paired.reg)

    owner_def = @owner_of[irep.label]
    return false unless owner_def && fiber_body_target_in(block_irep, owner_def)
    return false unless upvars.all? { |(level, _)| level.zero? }
    # The body and the enclosing method must both leave the locals alone: a copy is the variable only if nothing
    # writes either. The body has no SETUPVAR; the method names the register only in ENTER (a mandatory parameter
    # that no instruction writes or reads by its A operand).
    return false if BytecodeIR.for(block_irep).op?(:SETUPVAR)

    mandatory = mandatory_arity(irep)
    nodes = BytecodeIR.for(irep).instructions
    upvars.all? do |(_, reg)|
      reg.between?(1, mandatory) && nodes.none? { |node| node.op != :ENTER && node.source.reg == reg }
    end
  end

  # `block_irep` ends in a tail call on self to a suspendable method of +owner_def+'s owner, after plain prologue ops;
  # the entry id "Owner#m" or nil.
  def fiber_body_target_in(block_irep, owner_def)
    nodes = BytecodeIR.for(block_irep).instructions
    send = nodes[-2]
    ret = nodes[-1]
    return nil unless ret&.op == :RETURN && %i[SSEND SSEND0 SSENDB SEND SEND0 SENDB].include?(send&.op) &&
                      send.source.reg == ret.source.reg

    # SSENDB/SENDB pass a literal block made right before the call (a block whose own body may end in Fiber.yield).
    tail = 2
    if %i[SSENDB SENDB].include?(send.op)
      return nil unless nodes[-3]&.op == :BLOCK && send.source.plain_fixed_argc?

      tail = 3
    end
    return nil unless nodes[0...-tail].all? { |n| FIBER_BODY_PLAIN_OPS.include?(n.op) || n.op.to_s.start_with?('LOADI') }

    name = send.source.sym
    # A call on an explicit receiver names a method whose owner the body does not prove (RECEIVER_ROOTS): any
    # definition of the name that is a fiber root may take the handoff, and only on the receiver the site stores.
    unless %i[SSEND SSEND0 SSENDB].include?(send.op)
      hidden = self.class.core_hidden_defs || []
      candidates = (@registry[name] || []) + hidden.select { |d| d.name == name }
      return nil unless candidates.any? { |d| d.irep && @fiber_roots&.include?(d.irep) }

      return "##{name}"
    end
    targets = (@registry[name] || []).select { |d| d.owner == owner_def.owner && d.irep }
    return nil unless targets.size == 1

    label = targets.first.irep
    return nil unless @fiber_roots&.include?(label) && resumable_method?(label)

    "#{targets.first.owner}##{name}"
  end

  # A block whose last act is `Fiber.yield v` (or `Fiber.yield`), returning its value: nothing of the block is left to
  # resume after the yield, so the C++ Fiber's adapter can take `v` and make the resume value the block's result
  # (Bc2cppTailYield in runtime/bc2cpp_fiber.hxx).
  def tail_yield_block?(irep)
    nodes = BytecodeIR.for(irep).instructions
    ret = nodes[-1]
    send = nodes[-2]
    return false unless ret&.op == :RETURN && %i[SEND SEND0].include?(send&.op) && send.source.sym == 'yield'
    return false unless send.source.reg == ret.source.reg
    return false unless fiber_const_receiver?(irep, nodes.size - 2, send.source.reg)

    send.op == :SEND0 || (send.source.plain_fixed_argc? && send.source.argc == 1)
  end

  # compile_insn_op's hook for the tail yield of a tail_yield_block?: inside the one entry the adapter armed
  # (bc2cpp_block_can_yield), it stores the value and returns; anywhere else it is the ordinary Fiber.yield.
  def tail_yield_intercept(insn, irep, idx, reg_offset)
    return nil if @tail_yield_plain || !@tail_yield_block.equal?(irep) || !reg_offset.to_i.zero?
    return nil unless %i[SEND SEND0].include?(insn.op) && insn.sym == 'yield'
    return nil unless idx == BytecodeIR.for(irep).instructions.size - 2

    value = insn.op == :SEND0 ? 'mrb_nil_value()' : "r#{insn.reg + 1}"
    plain = begin
      @tail_yield_plain = true
      compile_insn_op(insn, irep, nil, idx, reg_offset)
    ensure
      @tail_yield_plain = false
    end
    "  if (bc2cpp_block_can_yield) return bc2cpp_tail_yield_store(#{value});\n#{plain}"
  end

  # Is +region+ the tail call (with its literal block) of the Fiber body prologue being emitted?
  def fiber_prologue_tail_region?(region)
    return false unless @fiber_prologue && region[:parent_irep].equal?(@fiber_prologue)

    nodes = BytecodeIR.for(@fiber_prologue).instructions
    nodes[-2]&.source&.addr == region[:sendb_addr]
  end

  # BLOCK_STEP: a literal block whose body reaches Fiber.yield other than as its last act is compiled a second time as
  # a resumable step, so a suspendable method that calls the block can CALL it instead of calling it from C (where
  # its Fiber.yield could not cross the C frame). The step is the block's irep compiled as a synthetic method of the
  # enclosing owner: its registers live in a frame, its Fiber.yield is a YIELD. The block's proc carries a maker for
  # the step's frame in its env (emit_rproc_construction); the fiber's adapter asks for it at a block-call suspension.
  # Limits (a block outside them keeps the call from C, or its tail yield): no captured locals, no nested block,
  # no break/return/yield to the method's block, mandatory or rest-only parameters.
  def block_step_candidate?(region, owner_def)
    return false unless owner_def && ENV['BC2CPP_BLOCK_STEP'] != '0' && !@rsm_variant && !@block_step_compile

    block = region[:block_irep]
    return false if region[:needs_blk] || region[:needs_brk] || region[:needs_ret]
    return false unless (region[:upvars] || []).empty? && (block.reps || []).empty?
    return false unless pure_mandatory_arity?(block) || rest_only_block?(block)
    return false if tail_yield_block?(block) || BytecodeIR.for(block).op?(:BREAK, :RETURN_BLK, :BLKPUSH)
    return false unless block_direct_entry?(region, region[:kind] || 'block_fallback', false)

    yields = false
    BytecodeIR.for(block).each_with_op(:SEND, :SEND0) do |insn, idx|
      yields ||= insn.sym == 'yield' && fiber_const_receiver?(block, idx, insn.reg)
    end
    yields
  end

  # Compiles every BLOCK_STEP candidate among +regions+ and returns the C++ text to put ahead of the method; each
  # compiled region gets :step_maker (the maker's name). Done before the owner's own compile starts, so nothing of it
  # is mid-flight (the dual variants are compiled the same way).
  def compile_block_steps(regions, d)
    return '' if regions.empty? || @rsm_variant || @block_step_compile

    code = String.new
    regions.each do |region|
      # A block nested in another block is a region of the outer block's body (emit_proc_fallback_fn_body recognizes
      # it again there), so look for steps inside first and name them by block label, not by region object.
      nested = recognize_block_fallback_regions(region[:block_irep], available_upvars: region[:upvars] || [])
      code << compile_block_steps(nested, d)
      next unless block_step_candidate?(region, d)

      step = compile_block_step(region, d)
      next unless step

      @block_step_emitted ||= Set.new
      code << step[:code] if @block_step_emitted.add?(region[:block_irep].label)
      @fiber_body_used = true
    end
    code
  end

  # The maker of the step compiled for +region+'s block, or nil.
  def block_step_maker_for(region)
    @block_steps&.[](region[:block_irep].label)&.[](:maker)
  end

  def compile_block_step(region, d)
    block = region[:block_irep]
    label = block.label
    @block_steps ||= {}
    return @block_steps[label] if @block_steps.key?(label)

    syn = d.dup
    syn.name = "#{d.name}__blk#{region[:block_addr]}"
    syn.irep = label
    syn.kind = nil
    previous_owner = @owner_of[label]
    was_root = @fiber_roots.include?(label)
    @owner_of[label] = syn
    @fiber_roots << label
    saved_budget = @ir_inline_remaining
    begin
      @block_step_compile = true
      result = compile_method(label)
    ensure
      @block_step_compile = false
      @ir_inline_remaining = saved_budget
      previous_owner ? @owner_of[label] = previous_owner : @owner_of.delete(label)
      @fiber_roots.delete(label) unless was_root
    end
    name = cpp_name(syn.owner, syn.name)
    entry = "static mrb_value #{name}(mrb_state* M, mrb_value self) {\n"
    cut = result[:code].rindex(entry)
    ok = result[:resumable] && !result[:unsupported] && !result[:code].include?('#error') && cut
    return @block_steps[label] = nil unless ok

    code = result[:code][0...cut]
    maker = "#{name}_step_maker"
    code << block_step_maker(block, "#{name}_impl", "#{syn.owner}##{syn.name}", maker)
    @block_steps[label] = { code: code, maker: maker }
  end

  # The frame maker the block's env carries: binds the yielded values as a non-strict block binds them, runs the
  # step's entry with its own id armed so the entry parks the frame (bc2cpp_prologue) instead of running it, and
  # returns that frame, or nullptr when the entry did not park (the caller then calls the block directly).
  def block_step_maker(block, impl, id, maker)
    mand = mandatory_arity(block)
    out = String.new
    out << "static Bc2cppFiberFrame* #{maker}(mrb_state* M, struct REnv* bc2cpp_env, mrb_int bc2cpp_argc, " \
           "const mrb_value* bc2cpp_argv) {\n"
    out << "  mrb_value bc2cpp_self = bc2cpp_env->stack[0];\n"
    args = []
    if rest_only_block?(block)
      args << 'mrb_ary_new_from_values(M, bc2cpp_argc, bc2cpp_argv)'
    elsif mand == 1
      args << 'bc2cpp_argc > 0 ? bc2cpp_argv[0] : mrb_nil_value()'
    elsif mand > 1
      out << "  mrb_value bc2cpp_vals = (bc2cpp_argc == 1 && mrb_array_p(bc2cpp_argv[0])) ? bc2cpp_argv[0] : " \
             "mrb_ary_new_from_values(M, bc2cpp_argc, bc2cpp_argv);\n"
      out << "  mrb_int bc2cpp_len = RARRAY_LEN(bc2cpp_vals);\n"
      mand.times { |i| args << "bc2cpp_len > #{i} ? mrb_ary_ref(M, bc2cpp_vals, #{i}) : mrb_nil_value()" }
    end
    out << "  bc2cpp_prologue.expect = #{c_string_literal(id)};\n  bc2cpp_prologue.frame = nullptr;\n"
    out << "  #{impl}(M, bc2cpp_self#{args.map { |a| ", #{a}" }.join});\n"
    out << "  bc2cpp_prologue.expect = nullptr;\n"
    out << "  Bc2cppFiberFrame* bc2cpp_made = bc2cpp_prologue.frame;\n  bc2cpp_prologue.frame = nullptr;\n"
    out << "  return bc2cpp_made;\n}\n\n"
    out
  end

  # The Fiber.new site: the block's RProc and a C++ Fiber over it. A body that captures locals gets their current
  # values copied into a heap Array first (the block reads them through pointers into it), since the Fiber outlives
  # this frame.
  def emit_fiber_body_site(region, fn_name, fiber_id, dest_reg)
    upvars = region[:upvars] || []
    cells = upvars.empty? ? nil : "bc2cpp_cells_#{region[:block_addr]}"
    rproc_var, ctor = emit_rproc_construction(region[:block_addr], fn_name, upvars, false,
                                              direct_entry: region[:direct_entry] ? "#{fn_name}_direct" : nil,
                                              yield_free: region[:yield_free], upvar_cells: cells)
    out = String.new
    out << "  // FIBER_BODY :new -- the body is the root frame of a C++ Fiber (#{fiber_id})\n  {\n"
    if cells
      out << "    mrb_value #{cells}_ary = mrb_ary_new_capa(M, #{upvars.size});\n"
      upvars.each { |(_, reg)| out << "    mrb_ary_push(M, #{cells}_ary, r#{reg});\n" }
      out << "    mrb_value* #{cells} = RARRAY_PTR(#{cells}_ary);\n"
    end
    out << ctor
    out << "    r#{dest_reg} = bc2cpp_fiber_new_body(M, mrb_obj_value(#{rproc_var}), #{c_string_literal(fiber_id)});\n  }\n"
  end

  RESUMABLE_HELPERS_CPP = <<~'CPP'
    // RESUMABLE_HELPERS -- see codegen_resumable.rb (ADR 0273).
    #include <initializer_list>
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
    // Whether a frame's last suspension was a block call (BLOCK_CALL) rather than a Fiber.yield: set by each suspension.
    static void bc2cpp_resume_frame_set_call(mrb_state* M, mrb_value frame, bool call) {
      mrb_iv_set(M, frame, mrb_intern_lit(M, "__call__"), mrb_bool_value(call));
    }
    static mrb_value bc2cpp_resume_frame_block_call(mrb_state* M, mrb_value self) {
      return mrb_iv_get(M, self, mrb_intern_lit(M, "__call__"));
    }
    static mrb_value bc2cpp_resume_frame_block(mrb_state* M, mrb_value self) {
      return mrb_iv_get(M, self, mrb_intern_lit(M, "__block__"));
    }
    // The values of a yield, as the Array the driver splats into the block's arguments.
    static mrb_value bc2cpp_block_args_from(mrb_state* M, std::initializer_list<mrb_value> values) {
      return mrb_ary_new_from_values(M, (mrb_int)values.size(), values.begin());
    }
    static void bc2cpp_resumable_init(mrb_state* M) {
      if (mrb_const_defined_at(M, mrb_obj_value(M->object_class), mrb_intern_lit(M, "Bc2cppResumable"))) return;
      struct RClass* mod = mrb_define_module(M, "Bc2cppResumable");
      struct RClass* frame = mrb_define_class_under(M, mod, "Frame", M->object_class);
      MRB_SET_INSTANCE_TT(frame, MRB_TT_DATA);
      mrb_define_method(M, frame, "value", bc2cpp_resume_frame_value, MRB_ARGS_NONE());
      mrb_define_method(M, frame, "block_call?", bc2cpp_resume_frame_block_call, MRB_ARGS_NONE());
      mrb_define_method(M, frame, "block", bc2cpp_resume_frame_block, MRB_ARGS_NONE());
    }
    // A step of a method called from C yielded: hand it to the real Fiber.yield, which raises
    // the FiberError the interpreted method would have raised.
    static mrb_value bc2cpp_resumable_yield_from_c(mrb_state* M, mrb_value frame) {
      mrb_value value = bc2cpp_resume_frame_value(M, frame);
      return mrb_funcall(M, mrb_obj_value(mrb_class_get(M, "Fiber")), "yield", 1, value);
    }
    // A step of a method called from C that suspended for a block call runs the block from C (the block's own
    // Fiber.yield then raises, as it does in the interpreted method called from C); any other suspension yields.
    static mrb_value bc2cpp_resumable_resume_from_c(mrb_state* M, mrb_value frame) {
      if (!mrb_test(bc2cpp_resume_frame_block_call(M, frame))) return bc2cpp_resumable_yield_from_c(M, frame);
      mrb_value args = bc2cpp_resume_frame_value(M, frame);
      mrb_value blk = bc2cpp_resume_frame_block(M, frame);
      return mrb_yield_argv(M, blk, RARRAY_LEN(args), RARRAY_PTR(args));
    }
  CPP
end
