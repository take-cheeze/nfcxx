# frozen_string_literal: true

require_relative 'bytecode_ir_resumable'

# CodeGen: resumable compiled methods. A method that reaches Fiber.yield cannot
# keep its registers in C++ locals: the yield returns to the fiber's resumer, so everything
# it needs lives in a heap frame and the method is compiled as a step function that a
# bytecode driver calls again after each Fiber.yield.

# One yield point is a state number; F->slots holds the counters of flat inlined loops.
class ResumableCtx
  attr_reader :label, :helpers, :states, :reasons
  attr_accessor :flat, :helper_stack
  # Set when the step function is emitted: the frame's register count, and each register's index in the frame (R[index]).
  attr_accessor :nregs, :register_slots, :upvars, :boxed
  # BLOCK: the method takes a block, kept in the frame slot block_slot.
  attr_accessor :block, :block_slot
  # HANDLERS: the irep's catch handlers when the step has any.
  attr_accessor :handlers
  # STEP_EXIT_JUMPS: [address, value register or nil] of each exit that parks for an ensure body to run.
  attr_accessor :exit_sites
  # OPTIONAL_ARGS: the optional positional argument count; the glue at the first JMP switches on bc2cpp_given_opt.
  attr_accessor :optional
  # STEP_KEYWORDS: the keyword table (keyword_arg_table) and the frame index of the first keyword cell; an optional keyword
  # has a second cell for its given flag.
  attr_accessor :kw, :kw_base

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
    def emit_proc_fallback_fn(region, *args, **kwargs)
      # A block that has a step is called as that step by the fiber; its plain body only runs when no fiber CALLs it,
      # so it is compiled outside the enclosing step (a Fiber.yield in it is then an ordinary send).
      if @resumable && (block_step_maker_for(region) || tail_yield_block?(region[:block_irep]))
        saved = @resumable
        @resumable = nil
        begin
          return super
        ensure
          @resumable = saved
        end
      end
      with_resumable_flat(false) { super }
    end
  end
  prepend ResumableFlatGuards

  # ---------------------------------------------------------------------------
  # Analysis
  # ---------------------------------------------------------------------------

  # True if the irep itself (not a block in it) calls Fiber.yield.
  def direct_fiber_yield?(irep)
    BytecodeIR.for(irep).each_with_op(:SEND, :SEND0) do |insn, idx|
      return true if insn.sym == 'yield' && insn.reg && fiber_const_receiver?(irep, idx, insn.reg)
    end
    false
  end

  # True if the irep, or a block nested in it, calls Fiber.yield. A Fiber.new block is another
  # fiber's body (`fiber_bodies`): a yield there returns to that fiber's resumer, so it is not
  # above the method that builds the fiber.
  def deep_fiber_yield?(irep, fiber_bodies, seen = Set.new.compare_by_identity)
    return false unless seen.add?(irep)
    return true if direct_fiber_yield?(irep)

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

  # STEP_HANDLERS: a step may have rescue and ensure handlers (see resumable_step_function). STEP_EXIT_JUMPS: an exit that
  # leaves an ensure region runs the ensure body first (step_exit_guard), so every handler type is accepted here.
  def resumable_handler_problem(irep)
    return 'has a handler of a type a step cannot enter' unless irep.catch_handlers.all? { |h| %i[rescue ensure].include?(h.type) }

    nil
  end

  # STEP_EXIT_JUMPS: the instructions that leave the step's own code or a protected range by a jump the handler table must
  # see (vm.c: every return, OP_BREAK, and OP_JMPUW, which is `break`/`next`/`redo`/`retry` in a loop or rescue clause).
  STEP_EXIT_OPS = %i[RETURN RETNIL RETTRUE RETFALSE RETSELF RETURN_BLK BREAK JMPUW].freeze

  # The step's ensure handlers (index into its table, handler) that cover +addr+, innermost first: vm.c's
  # catch_handler_find searches the table from its last entry.
  def step_covering_ensures(addr)
    covering = @resumable.handlers.each_with_index.select do |h, _|
      h.type == :ensure && h.begin_addr <= addr && addr < h.end_addr
    end
    covering.reverse
  end

  def step_ensure_handlers?
    @resumable&.handlers&.any? { |h| h.type == :ensure } ? true : false
  end

  # The ensure handler that the exit at +insn+ runs, or nil. A jump (JMPUW) only leaves a region whose range does not hold
  # its target (vm.c compares `a < begin || a > end`); a return or break leaves every covering one, and the innermost goes first.
  def step_exit_handler(insn)
    target = insn.op == :JMPUW ? insn.jmp_addr : nil
    step_covering_ensures(insn.addr).map(&:first).find { |h| target.nil? || target < h.begin_addr || target > h.end_addr }
  end

  # STEP_EXIT_JUMPS: a return, break or JMPUW leaving a begin/ensure region is parked in a Bc2cppExit token that stands in
  # for the exception EXCEPT captures; the ensure's RAISEIF continues it (Lbc2cpp_exit_dispatch) or hands it to the next ensure.
  def step_exit_guard(insn, text)
    return text unless STEP_EXIT_OPS.include?(insn.op)

    text = "  goto L#{insn.jmp_addr};\n" if insn.op == :JMPUW
    handler = step_exit_handler(insn)
    return text unless handler

    value_reg = %i[RETURN RETURN_BLK BREAK].include?(insn.op) ? (insn.no_operands? ? 0 : insn.reg) : nil
    (@resumable.exit_sites ||= []) << [insn.addr, value_reg]
    target = insn.op == :JMPUW ? insn.jmp_addr : -1
    [
      "  // STEP_EXIT_JUMPS #{insn.op}",
      "  M->exc = (struct RObject*)mrb_obj_ptr(bc2cpp_exit_new(M, #{insn.addr}, #{value_reg ? RegName[value_reg] : 'mrb_nil_value()'}, #{target}));",
      "  goto L#{handler.target};",
      "  Lbc2cpp_exit_#{insn.addr}:;",
      text
    ].join("\n")
  end

  # RAISEIF in a step with an ensure handler: nil continues, an exit token goes to the next enclosing ensure that its jump
  # leaves, else it is continued (Lbc2cpp_exit_dispatch), and anything else is raised.
  def step_raiseif_code(insn)
    reg = RegName[insn.reg]
    chain = step_covering_ensures(insn.addr).map do |h, _|
      "      if (bc2cpp_exit_t < 0 || bc2cpp_exit_t < #{h.begin_addr} || bc2cpp_exit_t > #{h.end_addr}) " \
        "{ M->exc = (struct RObject*)mrb_obj_ptr(#{reg}); goto L#{h.target}; }\n"
    end
    "  if (!mrb_nil_p(#{reg})) {\n" \
      "    if (bc2cpp_exit_p(M, #{reg})) {\n" \
      "      mrb_int bc2cpp_exit_t = bc2cpp_exit_target(M, #{reg});\n" \
      "#{chain.join}" \
      "      bc2cpp_exit_cur = #{reg};\n" \
      "      goto Lbc2cpp_exit_dispatch;\n" \
      "    }\n" \
      "    mrb_exc_raise(M, #{reg});\n" \
      "  }\n"
  end

  # The code after the step's instructions that continues a parked exit: its address picks the instruction's label.
  def step_exit_dispatch
    out = String.new
    out << "  Lbc2cpp_exit_dispatch:;\n  switch (bc2cpp_exit_site(M, bc2cpp_exit_cur)) {\n"
    (@resumable.exit_sites || []).uniq.each do |addr, reg|
      restore = reg ? "#{RegName[reg]} = bc2cpp_exit_value(M, bc2cpp_exit_cur); " : ''
      out << "    case #{addr}: #{restore}goto Lbc2cpp_exit_#{addr};\n"
    end
    out << "    default: bc2cpp_resume_bad_state(M);\n  }\n"
    out
  end

  def resumable_shape_problem(irep, d)
    # enter_fields: required, optional, rest, post, keyword, keyword rest, block.
    # The entry copies positional arguments and the block into the frame.
    fields = (irep.enter ? irep.enter.enter_fields.map(&:to_i) : []) + [0] * 7
    return 'takes a post or keyword rest argument' if fields[3].positive? || fields[5].positive?
    # STEP_KEYWORDS: the keywords are the ones compile_method binds (keyword_arg_table), next to a rest or block too.
    keywords = fields[4].positive?
    return 'takes keywords in a shape the step cannot enter' if keywords && !keyword_arg_table(irep, rest_block: true)
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
    return 'takes a rest argument in a shape the step cannot enter' if fields[2].positive? && fields[1].zero? && !keywords && !rest_only_arity?(irep)
    resumable_handler_problem(irep)
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
        return 'calls Fiber.yield with a splat or keywords' if argc.nil?

        next
      end
      next unless @fiber_yield_names.include?(name)

      # A call with a block is a CALL to a known suspendable method or a dynamic call (RESUMABLE_DYN_CALL); a site that can do
      # neither runs as an ordinary call.
      next if %i[SENDB SSENDB].include?(insn.op)

      # Without a block, an explicit-receiver call takes the dynamic call (resumable_intercept).
      next if %i[SEND SEND0].include?(insn.op)
      return "calls the yielding method #{name} with an explicit receiver or a block" unless %i[SSEND SSEND0].include?(insn.op)

      next if helpers.key?(name)

      reason = resumable_helper_problem(name, d, stack)
      if reason
        next if resumable_call_target(name, d)

        return reason
      end

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

  # compile_insn's hook: the replacement code for a suspension site (Fiber.yield, a block call, a dynamic call, a call to a
  # yielding helper), nil for everything else. Outside a flat context there is no frame to resume, so it is `#error`.
  def resumable_intercept(insn, irep, d, idx, reg_offset)
    case insn.op
    when :BLKCALL
      return nil unless idx && @resumable.block

      resumable_block_site(insn)
    when :SEND, :SEND0
      return resumable_block_call_intercept(insn, irep, d, idx, reg_offset) if block_call_site?(insn, idx, reg_offset)
      return resumable_dyn_send_insn(insn) if dyn_send_site?(insn, idx, reg_offset)
      return resumable_yielder_site(insn) if yielder_send_site?(insn, irep, idx, reg_offset)
      return resumable_transfer_intercept(insn, irep, d, idx, reg_offset) if transfer_site?(insn, idx, reg_offset)
      return resumable_dyn_send_insn(insn) if blockless_yielding_send?(insn, idx, reg_offset)
      return nil unless insn.sym == 'yield' && idx

      dest = insn.reg - reg_offset
      return nil unless fiber_const_receiver?(irep, idx, dest)

      resumable_yield_site(insn)
    when :SUPER
      resumable_super_site(insn, d, idx, reg_offset)
    when :BREAK, :RETURN_BLK
      return nil unless @resumable.flat && @resumable.upvars

      resumable_unwind_site(insn)
    when :SSEND, :SSEND0
      # STEP_KEYWORDS: `send(:m, k: 1)` on self is an SSEND (a send with keywords is not rewritten to __send__).
      return resumable_dyn_send_insn(insn) if dyn_send_site?(insn, idx, reg_offset)
      # Yielder#<< is `self.yield(*args)`: the variant reaches Yielder#yield's, which calls the consumer's block.
      if insn.sym == 'yield' && d&.owner == 'Enumerator::Yielder' && @rsm_variant && @resumable.flat && reg_offset.zero? && !@resumable_plain
        shape = dyn_call_shape(insn)
        return resumable_dyn_site('self', shape[:dest], shape[:n], 'mrb_nil_value()', name: 'yield', splat_reg: shape[:argv_reg])
      end

      # CATCH_THROW: mruby's throw finds its catch on the VM's call stack; in a step it goes through the dynamic call, whose
      # dispatcher finds the catch frame of this fiber (bc2cpp_fiber_catch.hxx) and declines for any other.
      if insn.sym == 'throw' && insn.op == :SSEND && @resumable.flat && reg_offset.zero? && !@resumable_plain && insn.plain_fixed_argc? &&
         [1, 2].include?(insn.argc.to_i)
        return resumable_dyn_site('self', insn.reg, insn.argc.to_i, 'mrb_nil_value()', name: 'throw')
      end
      return nil unless @fiber_yield_names.include?(insn.sym)

      resumable_helper_call(insn, irep, d, idx, reg_offset)
    end
  end

  # An `#error` line for something the step cannot express; the reason is kept for the method's refusal log.
  def resumable_error(message)
    @resumable.reasons << message
    "  #error resumable method: #{message}\n"
  end

  def resumable_not_flat_error(what)
    resumable_error("#{what} inside a block or loop that is not inlined into the step function")
  end

  # Positional argument count of a Fiber.yield call, nil for a splat or keywords.
  def fiber_yield_argc(insn)
    return 0 if insn.op == :SEND0

    insn.plain_fixed_argc? ? insn.argc : nil
  end

  # The registers (r<dest+1>..) holding a call's +argc+ positional arguments.
  def argument_registers(dest, argc)
    (1..argc).map { |i| "r#{dest.to_i + i}" }
  end

  # The suspension every step site ends with: park +state+ with +value+ in R[0], return the frame to the driver, and continue
  # at the resume label with the resumed value in r<dest>. +call+ marks a block call (bc2cpp_resumable_resume_from_c).
  def resumable_suspend_lines(state, dest, value, call: false)
    [
      "  F->state = #{state};",
      '  bc2cpp_step_guard.yielding = true;',
      RESUMABLE_SPILL_MARK,
      "  R[0] = #{value};",
      '  mrb_write_barrier(M, (struct RBasic*)mrb_ary_ptr(bc2cpp_regs_ary));',
      "  bc2cpp_resume_frame_set_call(M, bc2cpp_frame_value, #{call});",
      '  return bc2cpp_frame_value;',
      "  Lbc2cpp_resume_#{state}:;",
      "  r#{dest} = R[1];"
    ]
  end

  # A `yield` (BLKCALL R n argc) of the method's own block: the step returns a frame whose arguments are the yielded
  # values, and the driver calls the block with them (Bc2cppResumable.drive); the block's value is the resume value.
  # The block runs from the driver's VM frame, so a Fiber.yield inside it has only VM frames to cross.
  def resumable_block_site(insn, argc: insn.uint_operand.to_i, splat: false)
    return resumable_not_flat_error('yield') unless @resumable.flat

    state = @resumable.new_state
    dest = insn.reg
    values = argument_registers(dest, argc)
    packed = values.empty? ? 'mrb_ary_new(M)' : "bc2cpp_block_args_from(M, {#{values.join(', ')}})"
    # `block.call(*args)`: the one argument register already holds the Array of values.
    packed = "r#{dest.to_i + 1}" if splat
    [
      "  // RESUMABLE_BLOCK_CALL #{state}",
      # The block this suspension calls (a `yield`'s, or a proc held in a variable): the fiber's adapter reads it back.
      "  mrb_iv_set(M, bc2cpp_frame_value, mrb_intern_lit(M, \"__block__\"), r#{dest});",
      *resumable_suspend_lines(state, dest, packed, call: true),
      ''
    ].join("\n")
  end

  # `block.call(a, ...)` on the method's own block (a SEND of :call with fixed arguments, in the step's own body): Proc#call
  # is a C function, so the block would run under a C frame that Fiber.yield cannot cross. The site suspends the step as
  # a `yield` does, when the receiver is the entry block at run time; any other receiver takes the ordinary send.
  # Identity is tested at run time, so no alias of the block register needs tracking.
  def block_call_site?(insn, idx, reg_offset)
    return false unless %i[SEND SEND0].include?(insn.op) && insn.sym == 'call' && idx && @resumable&.flat
    return false if @resumable_plain || reg_offset != 0

    insn.op == :SEND0 || insn.plain_fixed_argc? || insn.positional_splat?
  end

  # DYN_CALL: sends whose method is chosen at run time. In a step they go through bc2cpp_dyn_call, which returns the
  # frame of a registered suspendable method for the step to CALL.
  DYN_SEND_NAMES = %w[send __send__ public_send].freeze

  # An explicit-receiver call without a block to a method name that can reach Fiber.yield (`ary.each`): a dynamic call, so
  # a suspendable target parks and is CALLed and any other runs as an ordinary call.
  def blockless_yielding_send?(insn, idx, reg_offset)
    idx && reg_offset.zero? && insn.sym != 'yield' && @fiber_yield_names&.include?(insn.sym) && @resumable&.flat &&
      !@resumable_plain && dyn_call_shape(insn)
  end

  def dyn_send_site?(insn, idx, reg_offset)
    return false unless %i[SEND SENDB SSEND SSENDB].include?(insn.op) && DYN_SEND_NAMES.include?(insn.sym) && idx && reg_offset.zero?
    return false if @resumable_plain || !@resumable&.flat

    shape = dyn_call_shape(insn)
    shape && (shape[:splat] || shape[:n] >= 1)
  end

  # Where a call's operands sit: the receiver at +reg+, then the positional arguments (a packed Array for `*args`),
  # the keywords (one Hash register for `**kw`, key/value pairs for literal keywords) and the block register.
  def dyn_call_shape(insn)
    return nil unless insn.argc_operand

    dest = insn.reg.to_i
    splat = insn.positional_splat?
    n = splat ? 0 : insn.argc.to_i
    next_reg = dest + 1 + (splat ? 1 : n)
    kw = nil
    if insn.keyword_splat?
      kw = { kind: :hash, reg: next_reg }
      next_reg += 1
    elsif insn.keyword_arguments?
      kw = { kind: :pairs, n: insn.keyword_argc.to_i, reg: next_reg }
      next_reg += 2 * insn.keyword_argc.to_i
    end
    { dest: dest, splat: splat, n: n, argv_reg: (dest + 1 if splat), kw: kw, blk_reg: next_reg }
  end

  # +splat_reg+: the positional arguments are the Array in that register. With +name+ nil (a `send`) the method name is
  # the first argument. +kw+ is dyn_call_shape's keyword part.
  def resumable_dyn_site(recv, dest, argc, block_value, prelude = '', name: nil, splat_reg: nil, kw: nil, brk_site: nil,
                         ret_guard: false, call_override: nil)
    state = @resumable.new_state
    setup = []
    # `send(:m, a)` carries the name as its first argument; a plain call has a fixed name.
    fixed_name = "mrb_symbol_value(mrb_intern_cstr(M, #{c_string_literal(name)}))" if name
    if splat_reg
      ary = "r#{splat_reg}"
      if name
        name_expr = fixed_name
        argc_expr = "ary_size(#{ary})"
        argv_expr = "ary_items(#{ary})"
      else
        setup << "    if (ary_size(#{ary}) == 0) mrb_raise(M, mrb_exc_get_id(M, mrb_intern_lit(M, \"ArgumentError\")), \"no method name given\");"
        name_expr = "ary_items(#{ary})[0]"
        argc_expr = "ary_size(#{ary}) - 1"
        argv_expr = "ary_items(#{ary}) + 1"
      end
    else
      args = argument_registers(dest, argc)
      name_expr = fixed_name || args.first
      call_args = name ? args : args.drop(1)
      setup << "    mrb_value bc2cpp_dyn_argv[] = { #{(call_args + ['mrb_nil_value()']).join(', ')} };"
      argc_expr = call_args.size
      argv_expr = 'bc2cpp_dyn_argv'
    end
    kdict = 'mrb_nil_value()'
    case kw&.[](:kind)
    when :hash
      kdict = "r#{kw[:reg]}"
    when :pairs
      kdict = 'bc2cpp_dyn_kd'
      setup << '    mrb_value bc2cpp_dyn_kd = mrb_hash_new(M);'
      kw[:n].times { |i| setup << "    mrb_hash_set(M, bc2cpp_dyn_kd, r#{kw[:reg] + 2 * i}, r#{kw[:reg] + 2 * i + 1});" }
    end
    call = "bc2cpp_dyn_call(M, #{recv}, #{name_expr}, #{argc_expr}, #{argv_expr}, #{kdict}, #{block_value})"
    # A block that runs from C (the callee is not a registered suspendable method) breaks and returns by exception, as
    # in any method: the site owns the break frame and, in a method step, a return frame (the step is DONE when it catches).
    call = call_override if call_override
    guarded = brk_site || ret_guard
    lines = [
      "  // RESUMABLE_DYN_CALL #{state}",
      '  {',
      brk_site ? "    Bc2cppFrameGuard #{brk_site}(&bc2cpp_break_frames);" : nil,
      ret_guard ? '    Bc2cppFrameGuard bc2cpp_ret_guard(&bc2cpp_return_frames);' : nil,
      prelude.to_s.rstrip,
      *setup,
      guarded ? '    Bc2cppDynResult bc2cpp_dyn = { nullptr, mrb_nil_value() };' : nil,
      guarded ? '    Bc2cppVmMark bc2cpp_dyn_mark = bc2cpp_vm_mark(M);' : nil,
      guarded ? '    try {' : nil,
      guarded ? "      bc2cpp_dyn = #{call};" : "    Bc2cppDynResult bc2cpp_dyn = #{call};",
      brk_site ? '    } catch (bc2cpp_block_break& bc2cpp_brk) {' : nil,
      brk_site ? "      if (bc2cpp_brk.token != #{brk_site}.frame.token) throw;" : nil,
      brk_site ? '      bc2cpp_vm_restore(M, bc2cpp_dyn_mark);' : nil,
      brk_site ? '      bc2cpp_dyn = { nullptr, bc2cpp_brk.value };' : nil,
      ret_guard ? '    } catch (bc2cpp_method_return& bc2cpp_ret) {' : nil,
      ret_guard ? '      if (bc2cpp_ret.token != bc2cpp_ret_guard.frame.token) throw;' : nil,
      ret_guard ? '      bc2cpp_vm_restore(M, bc2cpp_dyn_mark);' : nil,
      ret_guard ? '      return bc2cpp_ret.value;' : nil,
      guarded ? '    }' : nil,
      '    if (!bc2cpp_dyn.frame) {',
      "      r#{dest} = bc2cpp_dyn.value;",
      "      goto Lbc2cpp_dyn_done_#{state};",
      '    }',
      '    F->callee = bc2cpp_dyn.frame;',
      '  }',
      *resumable_suspend_lines(state, dest, 'mrb_nil_value()'),
      "  Lbc2cpp_dyn_done_#{state}:;"
    ]
    lines.compact.reject(&:empty?).join("\n") + "\n"
  end

  # A `send`-family call without a literal block (a forwarded `&blk` included), in any argument shape.
  def resumable_dyn_send_insn(insn)
    shape = dyn_call_shape(insn)
    recv = %i[SSEND SSENDB].include?(insn.op) ? 'self' : "r#{shape[:dest]}"
    block_value = %i[SENDB SSENDB].include?(insn.op) ? "r#{shape[:blk_reg]}" : 'mrb_nil_value()'
    resumable_dyn_site(recv, shape[:dest], shape[:n], block_value, splat_reg: shape[:argv_reg], kw: shape[:kw])
  end

  # DYN_SUPER: `super(args)` in a method step; the block is the register after the arguments (OP_SUPER's R(a+n+1)).
  # Nil for a shape it does not take.
  def resumable_super_site(insn, d, idx, reg_offset)
    return nil unless @resumable.flat && reg_offset.zero? && @resumable.upvars.nil? && d && insn.plain_fixed_argc?
    return nil if d.owner.end_with?('.singleton')

    n = insn.argc.to_i
    dest = insn.reg
    call = "bc2cpp_dyn_super(M, self, #{owner_class_ptr_expr(d.owner)}, mrb_intern_lit(M, #{d.name.inspect}), #{n}, bc2cpp_dyn_argv, " \
           "r#{dest + n + 1})"
    resumable_dyn_site('self', dest, n, "r#{dest + n + 1}", '', name: d.name, call_override: call)
  end

  # BLOCK_STEP_UNWIND: a `break` (BREAK) or `return` (RETURN_BLK) in a block step ends the frames above the one the building
  # step named in the block's env; the fiber drops them and resumes (break) or finishes (return) that frame with the value.
  def resumable_unwind_site(insn)
    mode, key = insn.op == :BREAK ? [1, '__brk__'] : [2, '__ret__']
    [
      "  // RESUMABLE_UNWIND #{insn.op}",
      "  {",
      "    mrb_value bc2cpp_target = mrb_iv_get(M, bc2cpp_frame_value, mrb_intern_lit(M, \"#{key}\"));",
      '    if (!mrb_data_p(bc2cpp_target)) mrb_raise(M, mrb_exc_get_id(M, mrb_intern_lit(M, "LocalJumpError")), "break from proc-closure");',
      "    F->unwind_key = mrb_obj_ptr(bc2cpp_target);",
      "    F->unwind_mode = #{mode};",
      '  }',
      "  R[0] = r#{insn.reg};",
      '  bc2cpp_step_guard.yielding = true;',
      '  mrb_write_barrier(M, (struct RBasic*)mrb_ary_ptr(bc2cpp_regs_ary));',
      '  bc2cpp_resume_frame_set_call(M, bc2cpp_frame_value, false);',
      '  return bc2cpp_frame_value;',
      ''
    ].join("\n")
  end

  # +suspend+ when +condition+ holds at run time, else the ordinary send of +insn+ (compiled with the interception off).
  def resumable_suspend_or_send(condition, suspend, insn, irep, d, idx, reg_offset)
    plain = begin
      @resumable_plain = true
      compile_insn_op(insn, irep, d, idx, reg_offset)
    ensure
      @resumable_plain = false
    end
    ["  if (#{condition}) {", suspend.rstrip, '  } else {', plain.rstrip, '  }', ''].join("\n")
  end

  def resumable_block_call_intercept(insn, irep, d, idx, reg_offset)
    dest = insn.reg
    suspend = resumable_block_site(insn, argc: insn.argc.to_i, splat: insn.positional_splat?)
    # A lambda whose body is a step and whose arity fits suspends the same way (bc2cpp_lambda_step_ok); any other lambda is called.
    strict = insn.positional_splat? ? '' : " || bc2cpp_lambda_step_ok(M, r#{dest}, #{insn.argc.to_i})"
    resumable_suspend_or_send("mrb_proc_p(r#{dest}) && (!MRB_PROC_STRICT_P(mrb_proc_ptr(r#{dest}))#{strict})", suspend, insn, irep, d, idx, reg_offset)
  end

  # FIBER_TRANSFER: `fiber.transfer(v)` in a step is a yield of v when the receiver resumed this C++ Fiber or is the one
  # running it (bc2cpp_transfer_is_yield); any other receiver is an ordinary send.
  def transfer_site?(insn, idx, reg_offset)
    return false unless insn.sym == 'transfer' && idx && @resumable&.flat && !@resumable_plain && reg_offset.zero?

    insn.op == :SEND0 || (insn.op == :SEND && insn.plain_fixed_argc? && insn.argc.to_i.between?(1, 3))
  end

  def resumable_transfer_intercept(insn, irep, d, idx, reg_offset)
    suspend = resumable_yield_site(insn, transfer: true)
    resumable_suspend_or_send("bc2cpp_transfer_is_yield(M, r#{insn.reg})", suspend, insn, irep, d, idx, reg_offset)
  end

  def resumable_yield_site(insn, transfer: false)
    return resumable_not_flat_error('Fiber.yield') unless @resumable.flat

    argc = fiber_yield_argc(insn)
    return resumable_error('Fiber.yield with a splat or keywords') if argc.nil?

    state = @resumable.new_state
    dest = insn.reg
    # Fiber.yield a, b hands the resumer [a, b]; one value is itself, none is nil.
    value = case argc
            when 0 then 'mrb_nil_value()'
            when 1 then "r#{dest.to_i + 1}"
            else "bc2cpp_block_args_from(M, {#{argument_registers(dest, argc).join(', ')}})"
            end
    [
      "  // RESUMABLE_YIELD #{state}",
      "  R[0] = #{value};",
      "  F->state = #{state};",
      '  bc2cpp_step_guard.yielding = true;',
      '  bc2cpp_resume_frame_set_call(M, bc2cpp_frame_value, false);',
      RESUMABLE_SPILL_MARK,
      '  mrb_write_barrier(M, (struct RBasic*)mrb_ary_ptr(bc2cpp_regs_ary));',
      transfer ? '  bc2cpp_transfer_yielding = true;' : nil,
      '  return bc2cpp_frame_value;',
      "  Lbc2cpp_resume_#{state}:;",
      "  r#{dest} = R[1];",
      ''
    ].compact.join("\n")
  end

  # Inlines a yielding helper (wait_one_clock, ...) at its call site: its registers follow
  # the caller's in the frame, its `return` assigns the call's destination and jumps past
  # the body, and its jump labels are prefixed per site.
  def resumable_helper_call(insn, irep, d, idx, reg_offset)
    name = insn.sym
    return resumable_not_flat_error("call to the yielding method #{name}") unless @resumable.flat

    label = @resumable.helpers[name]
    unless label && (insn.op == :SSEND0 || insn.argc.zero?)
      target = resumable_call_target(name, d)
      return resumable_call_site(insn, target, reg_offset) if target

      return resumable_error("no inlinable helper #{name}") unless label
      return resumable_error("helper #{name} called with arguments")
    end

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

  HELPER_RETURN_VALUES = { RETNIL: 'mrb_nil_value()', RETTRUE: 'mrb_true_value()', RETFALSE: 'mrb_false_value()', RETSELF: 'self' }.freeze

  def resumable_helper_insn(hinsn, helper, helper_def, base, dest, end_label, prefix, hidx)
    value = hinsn.op == :RETURN ? "r#{hinsn.reg.to_i + base}" : HELPER_RETURN_VALUES[hinsn.op]
    # No block, no break: the nil break label makes BREAK an `#error`.
    return compile_block_body_insn(hinsn, helper, helper_def, base, end_label, prefix, idx: hidx) unless value

    "  r#{dest} = #{value};\n  goto #{end_label};\n"
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

  # The step function's opening: the frame, the registers, and the dispatch to the state saved by the last yield.
  # RESUMABLE_LOCAL_REGISTERS: the registers are C++ locals, loaded on entry and stored back at each yield
  # (docs/bc2cpp-resumable-locals.md). A body that takes a register's address keeps references into the frame, since that
  # pointer must reach the same cell after a resume.
  def resumable_step_function(step_name, body)
    ctx = @resumable
    registers = Set[0]
    # R[0] and R[1] are the yield/resume cells. One pass collects the registers and blanks every other token: only the `reg`
    # alternative starts with `r`, so literals and comments cannot name one.
    code_only = body.gsub(RESUMABLE_REGISTER_TOKENS) do |token|
      reg = Regexp.last_match[:reg]
      next ' ' unless reg

      registers << reg.to_i
      token
    end
    registers = registers.sort
    # Frame slots after the registers: BLOCK_SLOT (the same block for every call of the step, so no spill), STEP_CLOSURES (the
    # cells Array of the registers a block may keep live) and STEP_KEYWORDS (a value cell per keyword, a given cell if optional).
    next_slot = registers.size + 2
    block_slot = ctx.block ? next_slot : nil
    next_slot += 1 if block_slot
    boxed = (ctx.boxed || []) & registers
    cells_slot = boxed.empty? ? nil : next_slot
    next_slot += 1 if cells_slot
    ctx.kw_base = next_slot
    ctx.nregs = next_slot - 2 + (ctx.kw || []).sum { |kw| kw[:required] ? 1 : 2 }
    ctx.block_slot = block_slot
    ctx.register_slots = registers.each_with_index.to_h { |reg, slot| [reg, slot + 2] }
    locals = ENV['BC2CPP_RESUMABLE_LOCALS'] != '0' && !code_only.match?(RESUMABLE_REGISTER_ADDRESS) && boxed.empty?
    spill = registers.each_with_index.map { |reg, slot| "R[#{slot + 2}] = r#{reg};" }.join(' ')
    body = body.gsub(/^#{Regexp.escape(RESUMABLE_SPILL_MARK)}$/) { locals ? "  #{spill}" : '' }
    handlers = ctx.handlers
    out = String.new
    out << "static mrb_value #{step_name}(mrb_state* M, mrb_value self, mrb_value bc2cpp_frame_value, mrb_value bc2cpp_resume) {\n"
    out << "  Bc2cppResumeFrame* F = bc2cpp_resume_frame(M, &bc2cpp_frame_value, #{ctx.nregs}, #{ctx.slot_count});\n"
    out << "  mrb_value bc2cpp_regs_ary = bc2cpp_resume_regs(M, bc2cpp_frame_value);\n"
    out << "  mrb_value* R = F->regs;\n"
    (ctx.upvars || []).each_with_index do |(level, idx), i|
      out << "  [[maybe_unused]] mrb_value* #{upvar_var_name(level, idx)} = (mrb_value*)F->slots[#{i}];\n"
    end
    if ctx.upvars
      (@block_step_cell_levels || []).each_with_index do |level, i|
        out << "  [[maybe_unused]] mrb_value bc2cpp_up_cells_#{level} = RARRAY_PTR(mrb_iv_get(M, bc2cpp_frame_value, mrb_intern_lit(M, \"__cells__\")))[#{i}];\n"
      end
    end
    out << resumable_cells_setup(boxed, registers, cells_slot) if cells_slot
    out << "  Bc2cppStepGuard bc2cpp_step_guard(F);\n"
    out << "  // RESUMABLE_LOCAL_REGISTERS\n" if locals
    registers.each_with_index do |reg, slot|
      if (cell = boxed.index(reg))
        out << "  mrb_value& r#{reg} = bc2cpp_cells[#{cell}];\n"
      else
        out << "  mrb_value#{'&' unless locals} r#{reg} = R[#{slot + 2}];\n"
      end
    end
    out << "  [[maybe_unused]] mrb_value bc2cpp_blk = R[#{block_slot}];\n" if block_slot
    out << resumable_keyword_reads(ctx)
    out << "  F->has_handlers = #{handlers ? handlers.size : 0};\n"
    out << "  #{handlers ? '' : 'const '}mrb_int bc2cpp_state = F->state;\n"
    # OPTIONAL_ARGS: a call that starts stores -(given + 1) in the frame state (the entry does). The body's jump-table
    # glue switches on bc2cpp_given_opt, and the resume switch is skipped for that start.
    optional = ctx.optional.to_i.positive?
    out << "  const mrb_int bc2cpp_given_opt = bc2cpp_state < 0 ? -bc2cpp_state - 1 : 0;\n" if optional
    out << "  if (bc2cpp_state != 0) R[1] = bc2cpp_resume;\n"
    out << "  r0 = self;\n"
    # STEP_HANDLERS: the body runs in a protected call so an exception can be turned into a jump to a handler's entry.
    out << "  auto bc2cpp_body = [&]() -> mrb_value {\n" if handlers
    out << "  mrb_value bc2cpp_exit_cur = mrb_nil_value();\n" if step_ensure_handlers?
    # An exception the fiber delivers (a frame this step CALLed raised, or an unwind passes through it) is raised here, at
    # the address the step suspended at, so the handler lookup is the same as for one raised by the step itself.
    out << "  if (F->raise_pending) { F->raise_pending = 0; mrb_exc_raise(M, R[1]); }\n" if handlers
    out << "  #{'if (bc2cpp_state >= 0) ' if optional}switch (bc2cpp_state) {\n    case 0: break;\n"
    ctx.states.each { |n| out << "    case #{n}: goto Lbc2cpp_resume_#{n};\n" }
    (handlers || []).each_with_index { |h, k| out << "    case #{RESUMABLE_HANDLER_STATE + k}: goto L#{h.target};\n" }
    out << "    default: bc2cpp_resume_bad_state(M);\n  }\n"
    out << body
    out << resumable_handler_loop(handlers, locals ? spill : '') if handlers
    out
  end

  # STEP_CLOSURES: the Array of cells the step makes on its first run, from the values the entry put in the boxed registers' slots.
  def resumable_cells_setup(boxed, registers, cells_slot)
    out = String.new
    out << "  mrb_value bc2cpp_cells_ary = R[#{cells_slot}];\n"
    out << "  if (mrb_nil_p(bc2cpp_cells_ary)) {\n    bc2cpp_cells_ary = mrb_ary_new_capa(M, #{boxed.size});\n"
    boxed.each { |reg| out << "    mrb_ary_push(M, bc2cpp_cells_ary, R[#{registers.index(reg) + 2}]);\n" }
    out << "    R[#{cells_slot}] = bc2cpp_cells_ary;\n    mrb_write_barrier(M, (struct RBasic*)mrb_ary_ptr(bc2cpp_regs_ary));\n  }\n"
    out << "  mrb_value* bc2cpp_cells = RARRAY_PTR(bc2cpp_cells_ary);\n"
    out << "  Bc2cppCellsGuard bc2cpp_cells_guard = { M, bc2cpp_cells_ary };\n"
  end

  # STEP_KEYWORDS: the entry put the keywords in the frame; KEY_P / KARG read them as the plain body's parameters.
  def resumable_keyword_reads(ctx)
    out = String.new
    cell = ctx.kw_base
    (ctx.kw || []).each do |kw|
      out << "  [[maybe_unused]] mrb_value #{kwarg_param_name(kw[:name])} = R[#{cell}];\n"
      cell += 1
      next if kw[:required]

      out << "  [[maybe_unused]] mrb_int #{kw_given_param_name(kw[:name])} = mrb_test(R[#{cell}]) ? 1 : 0;\n"
      cell += 1
    end
    out
  end

  RESUMABLE_HANDLER_STATE = 1_000_000

  # The loop that runs a step body with handlers: an exception takes the innermost handler covering F->pc, as vm.c's
  # catch_handler_find does; the handler's entry reads it from M->exc. With none it leaves the step (has_handlers 0).
  def resumable_handler_loop(handlers, spill)
    out = String.new
    out << "  };\n"
    out << "  for (;;) {\n"
    out << "    mrb_bool bc2cpp_err = FALSE;\n"
    out << "    mrb_value bc2cpp_res = bc2cpp_protect_call(M, bc2cpp_body, &bc2cpp_err);\n"
    out << "    if (!bc2cpp_err) return bc2cpp_res;\n"
    out << "    mrb_int bc2cpp_hs = -1;\n"
    handlers.each_with_index.to_a.reverse.each_with_index do |(h, k), i|
      out << "    #{'else ' unless i.zero?}if (F->pc >= #{h.begin_addr} && F->pc < #{h.end_addr}) bc2cpp_hs = #{RESUMABLE_HANDLER_STATE + k};\n"
    end
    out << "    if (bc2cpp_hs < 0) { F->has_handlers = 0; mrb_exc_raise(M, bc2cpp_res); }\n"
    # GC: bc2cpp_protect dropped the arena entries of the run's objects, and a C++-local register
    # (RESUMABLE_LOCAL_REGISTERS) is not a root, so the values go back to the (rooted) frame first.
    unless spill.empty?
      out << "    #{spill}\n"
      out << "    mrb_write_barrier(M, (struct RBasic*)mrb_ary_ptr(bc2cpp_regs_ary));\n"
    end
    out << "    M->exc = (struct RObject*)mrb_obj_ptr(bc2cpp_res);\n"
    out << "    bc2cpp_state = bc2cpp_hs;\n"
    out << "  }\n"
    out
  end

  # DYN_CALL: the dispatcher a `send` of this method reaches (bc2cpp_dyn_call): arms the method's id and runs its entry,
  # which parks the frame. An omitted optional argument is nil and the entry is told how many were given (as the registered
  # wrapper does); a rest parameter is the last one, packed into an Array.
  def resumable_dyn_function(impl_name, owner_name, argc, blk, wrapper: impl_name.delete_suffix('_impl'), optional: 0, rest: false, kw: nil)
    fixed = rest ? argc - 1 : argc
    args = (0...fixed).map { |i| ", argc > #{i} ? argv[#{i}] : mrb_nil_value()" }.join
    args += ", argc > #{fixed} ? mrb_ary_new_from_values(M, argc - #{fixed}, argv + #{fixed}) : mrb_ary_new(M)" if rest
    given = optional.positive? ? ", std::min<mrb_int>(argc - #{fixed - optional}, #{optional})" : ''
    max = rest ? 'INT32_MAX' : fixed
    bind, kw_args = kw ? resumable_dyn_kw_binding(kw) : ['', '']
    <<~CPP
      static mrb_value #{impl_name}_dyn(mrb_state* M, mrb_value self, mrb_int argc, const mrb_value* argv, #{'mrb_value bc2cpp_dyn_kd, ' if kw}mrb_value bc2cpp_dyn_blk) {
        (void)argc; (void)argv; (void)bc2cpp_dyn_blk;#{bind}
        bc2cpp_prologue.expect = #{c_string_literal(owner_name)};
        bc2cpp_prologue.frame = nullptr;
        mrb_value result = #{impl_name}(M, self#{args}#{blk ? ', bc2cpp_dyn_blk' : ''}#{given}#{kw_args});
        bc2cpp_prologue.expect = nullptr;
        return result;
      }
      static const int #{impl_name}_dyn_reg = (bc2cpp_dyn_register#{'_kw' if kw}((void*)&#{wrapper}, #{impl_name}_dyn, #{fixed - optional}, #{max}), 0);
    CPP
  end

  # STEP_KEYWORDS: the lines binding a keyword method's hash to its keyword arguments, and those arguments. The binder
  # declines a call the wrapper would refuse (a missing or unknown keyword), which then runs as an ordinary send and raises.
  def resumable_dyn_kw_binding(kw)
    ordered = kw.select { |k| k[:required] } + kw.reject { |k| k[:required] }
    names = ordered.map { |k| "mrb_intern_cstr(M, #{c_string_literal(k[:name].to_s)})" }.join(', ')
    index = ordered.each_with_index.to_h { |k, i| [k[:name], i] }
    kw_args = kw.map do |k|
      value = "bc2cpp_dkw_values[#{index[k[:name]]}]"
      flag = k[:required] ? '' : ", mrb_undef_p(#{value}) ? 0 : 1"
      ", mrb_undef_p(#{value}) ? mrb_nil_value() : #{value}#{flag}"
    end.join
    bind = "\n  mrb_sym bc2cpp_dkw_names[#{ordered.size}] = { #{names} };\n" \
           "  mrb_value bc2cpp_dkw_values[#{ordered.size}];\n" \
           "  if (!bc2cpp_dyn_bind_keywords(M, bc2cpp_dyn_kd, #{ordered.size}, #{ordered.count { |k| k[:required] }}, " \
           'bc2cpp_dkw_names, bc2cpp_dkw_values)) return mrb_undef_value();'
    [bind, kw_args]
  end

  # The C function the fiber runtime calls to run one step, and the loop a C caller drives the entry with.
  def resumable_thunk_cpp(step_name)
    <<~CPP
      static mrb_value #{step_name}_thunk(mrb_state* M, mrb_value) {
        mrb_value self, frame, resume;
        mrb_get_args(M, "ooo", &self, &frame, &resume);
        return #{step_name}(M, self, frame, resume);
      }
    CPP
  end

  def resumable_drive_loop_cpp(step_name)
    <<~CPP.gsub(/^(?=.)/, '  ')
      for (;;) {
        mrb_value result = #{step_name}(M, self, frame, resume);
        if (!bc2cpp_resume_frame_p(M, result)) return result;
        frame = result;
        resume = bc2cpp_resumable_resume_from_c(M, frame);
      }
    CPP
  end

  # The stores that put an entry's arguments, block and keywords in the frame, each where the body reads it. A register the
  # body never reads has no slot and is not copied.
  def resumable_entry_fill(arg_names, ctx, blk, kw)
    fill = arg_names.each_with_index.filter_map do |a, idx|
      slot = ctx.register_slots[idx + 1]
      "F->regs[#{slot}] = #{a};" if slot
    end
    if blk
      # mruby keeps the block in register argc+1, which `yield` (BLKPUSH) reads, so that register's slot gets it too.
      # With keywords the keyword-hash register sits between the arguments and the block.
      block_reg_slot = ctx.register_slots[arg_names.size + 1 + (kw ? 1 : 0)]
      fill += ['mrb_iv_set(M, frame, mrb_intern_lit(M, "__block__"), bc2cpp_blk);', "F->regs[#{ctx.block_slot}] = bc2cpp_blk;"]
      fill << "F->regs[#{block_reg_slot}] = bc2cpp_blk;" if block_reg_slot
    end
    cell = ctx.kw_base
    (kw || []).each do |k|
      fill << "F->regs[#{cell}] = #{kwarg_param_name(k[:name])};"
      cell += 1
      next if k[:required]

      fill << "F->regs[#{cell}] = mrb_bool_value(#{kw_given_param_name(k[:name])});"
      cell += 1
    end
    fill
  end

  def resumable_entry_function(impl_name, step_name, owner_name, arg_names = [], ctx = nil, blk = false, optional: 0, rest: false)
    dyn = !@rsm_variant && !@block_step_compile
    kw = ctx&.kw
    owner_literal = c_string_literal(owner_name)
    if arg_names.empty? && !blk && !kw
      # No arguments: the frame starts empty, and the driver's first step creates it.
      return resumable_thunk_cpp(step_name) + <<~CPP + resumable_drive_loop_cpp(step_name) + <<~CPP + (dyn ? resumable_dyn_function(impl_name, owner_name, 0, false) : '')
        mrb_value #{impl_name}(mrb_state* M, mrb_value self) {
          // An armed entry is reached from the runtime (a dispatcher, a CALL site, a Fiber body's start), which counted already.
          if (!bc2cpp_prologue.expect) bc2cpp_check_argc(M, 0, 0);
          bc2cpp_resumable_init(M);
          mrb_value frame = mrb_nil_value(), resume = mrb_nil_value();
          if (bc2cpp_prologue_armed(M, #{owner_literal}, self)) {
            // The frame exists before it is parked: the maker of a block step stores the pointers it captured in it.
            bc2cpp_resume_frame(M, &frame, #{ctx.nregs}, #{ctx.slot_count});
            return bc2cpp_prologue_park(M, bc2cpp_method_frame_new(M, #{step_name}, self, frame));
          }
      CPP
        }
        // #{owner_name}: entry of a resumable method (RESUMABLE_ENTRY)
      CPP
    end
    # Required arguments: the frame is created here and handed to the driver, whose first step takes it instead of creating an
    # empty one. The last `optional` names are optional: an omitted one is nil, the body's default-value code sets it, and the
    # frame state records how many the call gave (OPTIONAL_ARGS). The registered wrapper passes that count last.
    n = arg_names.size
    req = n - optional
    kw_params = (kw || []).flat_map do |k|
      ["mrb_value #{kwarg_param_name(k[:name])}"] + (k[:required] ? [] : ["mrb_int #{kw_given_param_name(k[:name])}"])
    end
    params = (arg_names.map { |a| "mrb_value #{a}" } + (blk ? ['mrb_value bc2cpp_blk'] : []) +
              (optional.positive? ? ['mrb_int bc2cpp_given_opt'] : []) + kw_params).join(', ')
    optional_head = optional.positive? ? "    F->state = -(bc2cpp_given_opt + 1);\n" : ''
    arm_block = blk ? "\n  if (bc2cpp_prologue_armed(M, #{owner_literal}, self)) bc2cpp_blk = bc2cpp_env_block(M, bc2cpp_blk);" : ''
    head = <<~CPP
      mrb_value #{impl_name}(mrb_state* M, mrb_value self, #{params}) {
      bc2cpp_resumable_init(M);#{arm_block}
        mrb_value frame = mrb_nil_value();
        Bc2cppResumeFrame* F = bc2cpp_resume_frame(M, &frame, #{ctx.nregs}, #{ctx.slot_count});
    CPP
    fill = resumable_entry_fill(arg_names, ctx, blk, kw).map { |line| "  #{line}\n" }.join
    tail = <<~CPP.gsub(/^(?=.)/, '  ')
      mrb_write_barrier(M, (struct RBasic*)mrb_ary_ptr(bc2cpp_resume_regs(M, frame)));
      if (bc2cpp_prologue_armed(M, #{owner_literal}, self)) {
        return bc2cpp_prologue_park(M, bc2cpp_method_frame_new(M, #{step_name}, self, frame));
      }
      mrb_value resume = mrb_nil_value();
    CPP
    footer = <<~CPP
      }
      // #{owner_name}: entry of a resumable method with #{req} required argument#{'s' unless req == 1}#{", #{optional} optional" if optional.positive?} (RESUMABLE_ENTRY)
    CPP
    resumable_thunk_cpp(step_name) + head + optional_head + fill + tail + resumable_drive_loop_cpp(step_name) + footer +
      (dyn ? resumable_dyn_function(impl_name, owner_name, n, blk, optional: optional, rest: rest, kw: kw) : '')
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
    %w[bc2cpp_fiber.hxx bc2cpp_fiber_methods.hxx bc2cpp_fiber_catch.hxx bc2cpp_fiber_sort.hxx].map do |name|
      File.read(File.join(FIBER_RUNTIME_DIR, name)).gsub(/^#pragma once\n/, '')
    end.join("\n")
  end

  # Ops a Fiber body's prologue may use before its tail call: they read the receiver's state and make constants, so
  # none of them can reach a suspendable method.
  FIBER_BODY_PLAIN_OPS = %i[ENTER GETIV GETUPVAR MOVE LOADSELF LOADNIL LOADT LOADF LOADSYM LOADL STRING].freeze

  # Is +region+ a `Fiber.new { ... }` site (no arguments, a literal block)?
  def fiber_new_site?(region)
    return false unless region[:name] == 'new' && !region[:self_implicit] && region[:n].to_i.zero?

    parent = region[:parent_irep]
    idx = parent && parent.index_of_addr(region[:sendb_addr])
    idx ? fiber_const_receiver?(parent, idx, region[:dest_reg]) : false
  end

  # `Fiber.new { prologue; m(args) }`: the block ends with a call on self to a suspendable method `m`, so the C++ Fiber runs
  # the block with `m` armed (bc2cpp_prologue) and calls the frame m's entry parks as its body. The entry id "Owner#m", or nil.
  def fiber_body_target_id(region, owner_def)
    return nil unless owner_def && fiber_new_site?(region)

    fiber_body_target_in(region[:block_irep], owner_def)
  end

  # The recognizer's side of fiber_body_target_id (it runs before a region exists): a Fiber body it accepts whose captured
  # locals are all safe to copy by value, so a region may take upvars without the synchronous-call gate.
  def fiber_body_by_value?(irep, idx, paired, block_irep, upvars)
    return false unless paired.sym == 'new' && paired.op == :SENDB && paired.plain_fixed_argc? && paired.argc.to_i.zero?
    return false unless fiber_const_receiver?(irep, idx, paired.reg)

    owner_def = @owner_of[irep.label]
    return false unless owner_def && fiber_body_target_in(block_irep, owner_def)
    return false unless upvars.all? { |(level, _)| level.zero? }
    # Body and enclosing method must both leave the locals alone (no SETUPVAR; the method names the register only in ENTER),
    # else a copy is not the variable.
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
    # Block parameters bind from the first resume's arguments: that is the body step's start, not the handoff.
    return nil unless mandatory_arity(block_irep).zero? && pure_mandatory_arity?(block_irep)

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

  # A block whose last act is `Fiber.yield v`: nothing is left to resume, so the C++ Fiber's adapter takes `v` and makes the
  # resume value the result (Bc2cppTailYield).
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

  # A name that can reach Fiber.yield: a program method that does, or a core iterator with a resumable variant (its
  # definition is not a registry entry).
  def yielding_call_name?(name)
    @fiber_yield_names&.include?(name) || (EnumStep.enabled? && RESUMABLE_DUAL_NAMES.include?(name))
  end

  # BLOCK_STEP: a literal block whose body reaches Fiber.yield other than as its last act is also compiled as a resumable
  # step (a synthetic method of the enclosing owner), so a suspendable method can CALL it instead of calling it from C. Its
  # env carries a frame maker (emit_rproc_construction); the block takes mandatory or rest-only parameters.
  def block_step_candidate?(region, owner_def, builder_upvars = nil)
    return false unless owner_def && !@block_step_compile

    block = region[:block_irep]
    return false unless (region[:upvars] || []).empty? || block_step_upvars_ok?(region, owner_def, builder_upvars)
    return false unless pure_mandatory_arity?(block) || rest_only_block?(block)
    body = fiber_new_site?(region) && !fiber_body_target_id(region, owner_def)
    return false if (!body && tail_yield_block?(block)) || (body && BytecodeIR.for(block).op?(:BREAK, :RETURN_BLK))
    return false if body && (region[:needs_brk] || region[:needs_ret])
    return false if BytecodeIR.for(block).op?(:BLKPUSH) && !region[:needs_blk] # a BLKPUSH is the method's block only when it is passed in
    return false unless block_direct_entry?(region.merge(needs_ret: false, needs_brk: false), region[:kind] || 'block_fallback', false)

    # A Fiber body is always a step: a Fiber over a compiled proc needs a frame to run, whether or not it ever suspends.
    return true if body

    program = BytecodeIR.for(block)
    return true if direct_fiber_yield?(block)
    # `block.call(x)` on a proc held in a variable may reach a Fiber.yield, in a method a fiber runs (or its variant).
    return true if (@rsm_variant || @fiber_roots&.include?(owner_def.irep)) && program.instructions_with_op(:SEND, :SEND0).any? { |i| i.sym == 'call' }
    return true if region[:needs_blk] && program.op?(:BLKCALL)
    # A block that builds a block which reaches Fiber.yield suspends through it (the nested block is a step, DYN_CALL).
    return true if (block.reps || []).any? { |child| (c = child && @ireps[child]) && deep_fiber_yield?(c, Set.new) }

    # A `break` out of a call to a method that can suspend: the callee's frame is CALLed, so the break unwinds frames.
    return true if region[:needs_brk] && !fiber_new_site?(region) && @fiber_yield_names&.include?(region[:name])
    return true if generator_irep?(block) && program.instructions_with_op(:SEND, :SEND0).any? { |i| YIELDER_SENDS.include?(i.sym) }

    program.instructions_with_op(:SSEND, :SSEND0, :SSENDB).any? { |insn| yielding_call_name?(insn.sym) }
  end

  # The Yielder calls of an `Enumerator.new { |y| y << v }` generator: Enumerator#next runs the block on a C++ Fiber, and a
  # Yielder call there suspends through the consumer's block.
  YIELDER_SENDS = %w[<< yield].freeze

  # Is +irep+ a literal block of `Enumerator.new`, or nested in one?
  def generator_irep?(irep)
    @generator_labels ||= begin
      labels = Set.new
      @ireps.each_value do |parent|
        BytecodeIR.for(parent).adjacent_pairs(:BLOCK, %i[SENDB]) do |insn, paired, sendb_idx|
          next unless paired.sym == 'new' && insn.block_index && const_receiver?(parent, sendb_idx - 1, paired.reg, 'Enumerator')

          stack = [parent.reps[insn.block_index.to_i]]
          until stack.empty?
            label = stack.pop
            stack.concat(@ireps[label].reps.compact) if label && labels.add?(label) && @ireps[label]
          end
        end
      end
      labels
    end
    @generator_labels.include?(irep.label)
  end

  # `y << v` / `y.yield v` in a generator block of a step: a dynamic call, so Yielder#<< parks its frame and the consumer's
  # block runs as a step.
  def yielder_send_site?(insn, irep, idx, reg_offset)
    return false unless %i[SEND SEND0].include?(insn.op) && YIELDER_SENDS.include?(insn.sym) && idx && reg_offset.zero?
    return false if @resumable_plain || !@resumable&.flat || !generator_irep?(irep)
    return false if insn.sym == 'yield' && fiber_const_receiver?(irep, idx, insn.reg)

    insn.op == :SEND0 || insn.plain_fixed_argc?
  end

  def resumable_yielder_site(insn)
    n = insn.op == :SEND0 ? 0 : insn.argc.to_i
    resumable_dyn_site("r#{insn.reg}", insn.reg, n, 'mrb_nil_value()', name: insn.sym)
  end

  # BLOCK_STEP_UNWIND: the targets a block's `break` (the call that took the block) and `return` (the method's frame, or the
  # target the builder block step carries) name when its step runs as a fiber frame. Nil when the builder is not a step.
  def step_unwind_targets(region)
    return nil unless region[:needs_ret] || region[:needs_brk]

    ret = if !@resumable then 'mrb_nil_value()'
          elsif @resumable.upvars then 'mrb_iv_get(M, bc2cpp_frame_value, mrb_intern_lit(M, "__ret__"))'
          else 'bc2cpp_frame_value'
          end
    brk = @resumable ? 'bc2cpp_frame_value' : 'mrb_nil_value()'
    [ret, brk]
  end

  # The tokens of a block that runs from C (see resumable_dyn_site): the call site's own frames.
  def step_unwind_tokens(region, builder_is_method)
    addr = region[:block_addr]
    brk = region[:needs_brk] ? "bc2cpp_site_#{addr}" : nil
    ret = region[:needs_ret] && builder_is_method
    [brk, ret]
  end

  # BLOCK_STEP_UPVARS: a block step reads and writes the builder's locals through pointers its maker keeps in the block frame's
  # slots. Sound only where the caller's frame outlives the callee: a CALL on self, not a Fiber body.
  # STEP_NESTED_UPVARS: a local of the builder's builder (level >= 1) is forwarded when the builder holds a pointer to it.
  def block_step_upvars_ok?(region, owner_def, builder_upvars = nil)
    # A Fiber body outlives the frame: its pointers must lead into cells (STEP_CLOSURES), not into the frame.
    return false if fiber_new_site?(region) && !region[:boxed]

    region[:upvars].all? { |(level, idx)| level.zero? || builder_upvars&.include?([level - 1, idx]) }
  end

  # The block irep of an inline-loop +region+ of +irep+, or nil.
  def inline_region_block(irep, region)
    insn = region[:block_addr] && BytecodeIR.for(irep).instructions.map(&:source).find { |s| s.addr == region[:block_addr] }
    block_label = insn&.op == :BLOCK && insn.block_index && irep.reps[insn.block_index.to_i]
    block_label && @ireps[block_label]
  end

  # STEP_CLOSURES: a block that builds a region over cells keeps its own registers in them, so its body cannot be inlined
  # into the host function (the loop would share the host's register numbering and cells).
  def inline_block_boxes?(irep, region)
    block = inline_region_block(irep, region)
    block ? recognize_block_fallback_regions(block).any? { |nested| nested[:boxed] } : false
  end

  # Can the literal block of an inline-loop +region+ suspend the fiber: it reaches Fiber.yield, calls a block
  # (`yield`, `block.call`), or calls a method that can suspend.
  def inline_block_may_suspend?(irep, region)
    block = inline_region_block(irep, region)
    return false unless block

    nested = ->(i) { [i] + (i.reps || []).filter_map { |l| l && @ireps[l] }.flat_map { |c| nested.call(c) } }
    nested.call(block).any? do |i|
      deep_fiber_yield?(i, Set.new) || BytecodeIR.for(i).op?(:BLKCALL) ||
        deep_called_names(i, Set.new).any? { |n| n == 'call' || n == 'yield' || @fiber_yield_names&.include?(n) }
    end
  end

  # The Fiber.new site of a body compiled as a step (block_step_candidate? accepted it and compile_block_step made its
  # maker): the fiber's root frame is the body's step frame.
  def emit_fiber_body_step_site(region, fn_name, dest_reg)
    @fiber_body_used = true
    rproc_var, ctor = emit_rproc_construction(region[:block_addr], fn_name, region[:upvars] || [], false,
                                              cells: region_cells_exprs(region),
                                              direct_entry: "#{fn_name}_direct", yield_free: region[:yield_free],
                                              step_maker: block_step_maker_for(region))
    "  // FIBER_BODY_STEP :new -- the body is a step, the root frame of a C++ Fiber\n  {\n#{ctor}" \
      "    r#{dest_reg} = bc2cpp_fiber_new_step(M, mrb_obj_value(#{rproc_var}));\n  }\n"
  end

  # Compiles every BLOCK_STEP candidate among +regions+ and returns the C++ text to put ahead of the method; each gets
  # :step_maker. Done before the owner's own compile (the dual variants likewise).
  def compile_block_steps(regions, d, builder_upvars = nil)
    return '' if regions.empty? || @block_step_compile

    code = String.new
    regions.each do |region|
      # A block nested in another block is a region of the outer block's body (emit_proc_fallback_fn_body recognizes
      # it again there), so look for steps inside first and name them by block label, not by region object.
      nested = recognize_block_fallback_regions(region[:block_irep], available_upvars: region[:upvars] || [],
                                                cell_levels: region[:boxed] ? (region[:cell_levels] || [0]) : [])
      code << compile_block_steps(nested, d, region[:upvars] || [])
      next unless block_step_candidate?(region, d, builder_upvars)

      step = compile_block_step(region, d)
      next unless step

      @block_step_emitted ||= Set.new
      # A probe compile (compiles_clean?) throws its text away, so it neither takes nor consumes the one emission.
      emit = @probing.empty? ? @block_step_emitted.add?(region[:block_irep].label) : true
      code << step[:code] if emit
      @fiber_body_used = true
    end
    code
  end

  # The maker of the step compiled for +region+'s block, or nil.
  def block_step_maker_for(region)
    @block_steps&.[](region[:block_irep].label)&.[](:maker)
  end

  # What compile_block_step sets for the nested compile of a block's step, and restores after it.
  BLOCK_STEP_STATE = %i[@ir_inline_remaining @block_step_upvars @block_step_label @block_step_needs_blk @block_step_cell_levels].freeze

  def compile_block_step(region, d)
    block = region[:block_irep]
    label = block.label
    @block_steps ||= {}
    return @block_steps[label] if @block_steps.key?(label)

    syn = d.dup
    # block_addr is unique only within one irep: a block nested in a block of the same method can share it.
    step_name = "#{d.name}__blk#{region[:block_addr]}"
    @block_step_names ||= {}
    step_name = "#{step_name}_#{label}" if @block_step_names[[d.owner, step_name]] && @block_step_names[[d.owner, step_name]] != label
    @block_step_names[[d.owner, step_name]] = label
    syn.name = step_name
    syn.irep = label
    syn.kind = nil
    previous_owner = @owner_of[label]
    was_root = @fiber_roots.include?(label)
    @owner_of[label] = syn
    @fiber_roots << label
    saved = BLOCK_STEP_STATE.to_h { |name| [name, instance_variable_get(name)] }
    begin
      @block_step_compile = true
      @block_step_cell_levels = region[:boxed] ? (region[:cell_levels] || [0]) : []
      @block_step_upvars = region[:upvars] || []
      @block_step_label = label
      # BLOCK_STEP_BLOCK: a `yield` in the block calls the block of the method that built it (BLKPUSH at level 1).
      @block_step_needs_blk = region[:needs_blk] ? true : false
      result = compile_method(label)
    ensure
      @block_step_compile = false
      saved.each { |name, value| instance_variable_set(name, value) }
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
    code << block_step_maker(block, "#{name}#{@entry_spec_suffix}_impl", "#{syn.owner}##{syn.name}", maker, region[:upvars] || [],
                            region[:needs_blk], region[:needs_ret] || region[:needs_brk], region[:boxed] ? (region[:cell_levels] || [0]).size : 0)
    # A compile that is run again (a probe, a variant) can put the same step in more than one method's text; the guard
    # keeps the first definition.
    guard = "BC2CPP_STEP_#{name}#{@entry_spec_suffix}".gsub(/[^A-Za-z0-9_]/, '_')
    code = "#ifndef #{guard}\n#define #{guard}\n#{code}#endif // #{guard}\n"
    @block_steps[label] = { code: code, maker: maker }
  end

  # The frame maker the block's env carries: binds the yielded values as a non-strict block does, runs the step's entry with
  # its id armed so it parks the frame (bc2cpp_prologue), and returns it (nullptr if the entry did not park).
  def block_step_maker(block, impl, id, maker, upvars = [], needs_blk = false, unwind = false, cells = 0)
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
    args << "bc2cpp_env->stack[#{1 + upvars.size}]" if needs_blk # the env carries the building method's block after the upvars
    out << "  bc2cpp_prologue.expect = #{c_string_literal(id)};\n  bc2cpp_prologue.frame = nullptr;\n"
    out << "  #{impl}(M, bc2cpp_self#{args.map { |a| ", #{a}" }.join});\n"
    out << "  bc2cpp_prologue.expect = nullptr;\n"
    out << "  Bc2cppFiberFrame* bc2cpp_made = bc2cpp_prologue.frame;\n  bc2cpp_prologue.frame = nullptr;\n"
    if unwind
      # BLOCK_STEP_UNWIND: the frames a `break` / `return` of the step ends, from the env, into the frame the step reads them from.
      out << "  if (bc2cpp_made) {\n"
      out << "    mrb_value bc2cpp_mf = ((Bc2cppMethodFrame*)bc2cpp_made)->frame;\n"
      out << "    mrb_int bc2cpp_len = MRB_ENV_LEN(bc2cpp_env);\n"
      out << "    mrb_iv_set(M, bc2cpp_mf, mrb_intern_lit(M, \"__brk__\"), bc2cpp_env->stack[bc2cpp_len - 4]);\n"
      out << "    mrb_iv_set(M, bc2cpp_mf, mrb_intern_lit(M, \"__ret__\"), bc2cpp_env->stack[bc2cpp_len - 5]);\n"
      out << "  }\n"
    end
    unless upvars.empty?
      # BLOCK_STEP_UPVARS: the pointers to the builder's locals, from the env, into the slots the step reads them from.
      out << "  if (bc2cpp_made) {\n"
      out << "    Bc2cppResumeFrame* bc2cpp_f = (Bc2cppResumeFrame*)DATA_PTR(((Bc2cppMethodFrame*)bc2cpp_made)->frame);\n"
      upvars.each_index do |i|
        out << "    bc2cpp_f->slots[#{i}] = (long long)(uintptr_t)mrb_integer(bc2cpp_env->stack[#{i + 1}]);\n"
      end
      # STEP_CLOSURES: the pointers lead into the cells Array the env keeps (after the block, if it takes one); the frame
      # keeps it too, as the env may go before the frame does.
      if cells.positive?
        slot = 1 + upvars.size + (needs_blk ? 1 : 0)
        out << "    mrb_iv_set(M, ((Bc2cppMethodFrame*)bc2cpp_made)->frame, mrb_intern_lit(M, \"__cells__\"), " \
               "mrb_ary_new_from_values(M, #{cells}, &bc2cpp_env->stack[#{slot}]));\n"
      end
      out << "  }\n"
    end
    out << "  return bc2cpp_made;\n}\n\n"
    out
  end

  # CALL_STEP: the definition a call on self to +name+ reaches, when its step can run as a frame of the fiber: one
  # definition in the caller's owner, compiled as a resumable step. nil otherwise (the call is then refused).
  def resumable_call_target(name, d)
    defs = @registry[name]
    return nil unless defs&.size == 1

    target = defs.first
    return nil unless target.irep && target.owner == d.owner && !target.core && @fiber_roots&.include?(target.irep)

    @resumable_call_checking ||= Set.new
    return target if @resumable_call_checking.include?(target.irep) # recursion: planned optimistically

    @resumable_call_checking << target.irep
    begin
      resumable_method?(target.irep) ? target : nil
    ensure
      @resumable_call_checking.delete(target.irep)
    end
  end

  # A call on self to a suspendable method with arguments: the step makes the callee's frame (its entry parks it when its id
  # is armed) and suspends; the callee's result is this step's resume value.
  def resumable_call_site(insn, target, reg_offset)
    return resumable_not_flat_error("call to the suspendable method #{insn.sym}") unless @resumable.flat

    dest = insn.reg - reg_offset
    # STEP_KEYWORDS: a callee that takes optional, rest, keyword or block parameters, or a call that carries keywords or a
    # splat, binds through the dynamic call (bc2cpp_dyn_call), whose dispatcher fills in what the call leaves out.
    if reg_offset.zero? && !(pure_mandatory_arity?(@ireps.fetch(target.irep)) && (insn.op == :SSEND0 || insn.plain_fixed_argc?))
      shape = insn.op == :SSEND0 ? { n: 0, argv_reg: nil, kw: nil } : dyn_call_shape(insn)
      return resumable_dyn_site('self', dest, shape[:n], 'mrb_nil_value()', name: insn.sym, splat_reg: shape[:argv_reg], kw: shape[:kw])
    end
    argc = insn.op == :SSEND0 ? 0 : insn.argc
    args = argument_registers(dest, argc)
    resumable_call_lines(@resumable.new_state, insn.sym, target, dest, args).join("\n") + "\n"
  end

  # The lines of a CALL suspension: the callee's entry parks its frame (its id armed), and the step suspends with it.
  # +args+ are the C++ arguments after self (a block proc included).
  def resumable_call_lines(state, name, target, dest, args)
    impl = "#{cpp_name(target.owner, target.name)}_impl"
    id = "#{target.owner}##{target.name}"
    [
      "  // RESUMABLE_CALL #{state} #{name}",
      '  bc2cpp_prologue.expect = ' + c_string_literal(id) + ';',
      '  bc2cpp_prologue.frame = nullptr;',
      "  #{impl}(M, self#{args.map { |a| ", #{a}" }.join});",
      '  bc2cpp_prologue.expect = nullptr;',
      '  F->callee = bc2cpp_prologue.frame;',
      '  bc2cpp_prologue.frame = nullptr;',
      *resumable_suspend_lines(state, dest, 'mrb_nil_value()')
    ]
  end

  # CALL_STEP with a block: the callee takes a block parameter and the site passes a literal block whose own body
  # suspends (it has a step maker, so the callee's yield CALLs the block's step). Nil when the site is not that shape.
  def resumable_block_call_target(name, d)
    target = resumable_call_target(name, d)
    return nil unless target

    callee = @ireps.fetch(target.irep)
    ok = (pure_mandatory_arity?(callee) && yields_block_param?(callee)) ||
         (block_param_arity?(callee) && callee.enter.enter_fields[1].zero? && callee.enter.enter_fields[2].zero?)
    ok ? target : nil
  end

  # The block's proc for a call site in a step; +ret_token+ / +brk_token+ are the unwind tokens its env carries.
  def resumable_step_rproc(region, fn_name, maker, ret_token, brk_token)
    emit_rproc_construction(region[:block_addr], fn_name, region[:upvars] || [],
                            region[:needs_blk] ? true : false, ret_token: ret_token, brk_token: brk_token,
                            cells: region_cells_exprs(region),
                            direct_entry: region[:direct_entry] ? "#{fn_name}_direct" : nil, yield_free: region[:yield_free],
                            step_maker: maker, unwind_targets: (maker ? step_unwind_targets(region) : nil))
  end

  # The method's step catches this block's `return` itself (a return guard at the call site).
  def mark_step_return_handled(region)
    (@step_ret_handled ||= Set.new) << [region[:parent_irep].label, region[:block_addr]]
  end

  def resumable_dyn_block_glue(region, fn_name, dest_reg, maker, name: nil)
    brk_site, ret_guard = step_unwind_tokens(region, @resumable.upvars.nil?)
    ret_token = region[:needs_ret] ? (ret_guard ? 'mrb_int_value(M, bc2cpp_ret_guard.frame.token)' : 'mrb_int_value(M, 0)') : nil
    brk_token = brk_site ? "mrb_int_value(M, #{brk_site}.frame.token)" : nil
    rproc_var, ctor = resumable_step_rproc(region, fn_name, maker, ret_token, brk_token)
    mark_step_return_handled(region) if ret_guard
    recv = region[:self_implicit] ? 'self' : "r#{dest_reg}"
    resumable_dyn_site(recv, dest_reg, region[:n].to_i, "mrb_obj_value(#{rproc_var})", ctor, name: name,
                                                                                         kw: region[:kw], brk_site: brk_site, ret_guard: ret_guard)
  end

  # STEP_HANDLERS: a block with a step but no plain function (its begin/ensure has no function form) needs only a direct
  # entry that runs the step to its end when called from C.
  def step_only_block_fn(region, d)
    return nil unless (@resumable || fiber_new_site?(region)) && d && @block_fallback_depth.to_i.zero? &&
                      (region[:kind] || 'block_fallback') == 'block_fallback'

    maker = block_step_maker_for(region)
    return nil unless maker
    fn_name = "#{cpp_name(d.owner, d.name)}_block_fallback_#{region[:block_addr]}"
    # A `break`/`return` of the step unwinds fiber frames (BLOCK_STEP_UNWIND); the proc stays a cfunc one, and called from C
    # it runs the step on a fiber of its own, where an unwind to the builder's frame is an error.
    if region[:needs_ret] || region[:needs_brk]
      return nil unless block_direct_entry?(region.merge(needs_ret: false, needs_brk: false), 'block_fallback', false)

      region[:yield_free] = false
      return [fn_name, <<~CPP]
        static mrb_value #{fn_name}(mrb_state* M, mrb_value) {
          const mrb_value* bc2cpp_argv;
          mrb_int bc2cpp_argc;
          mrb_get_args(M, "*", &bc2cpp_argv, &bc2cpp_argc);
          Bc2cppFiberFrame* bc2cpp_made = #{maker}(M, MRB_PROC_ENV(M->c->ci->proc), bc2cpp_argc, bc2cpp_argv);
          if (!bc2cpp_made) mrb_raise(M, mrb_class_get(M, "RuntimeError"), "bc2cpp: block step did not make a frame");
          return bc2cpp_run_callee_from_c(M, bc2cpp_made);
        }
      CPP
    end
    return nil unless block_direct_entry?(region, 'block_fallback', false)

    region[:direct_entry] = true
    region[:yield_free] = false
    code = <<~CPP
      static mrb_value #{fn_name}_direct(mrb_state* M, struct REnv* bc2cpp_env, bool bc2cpp_strict, mrb_int bc2cpp_argc, const mrb_value* bc2cpp_argv) {
        (void)bc2cpp_strict;
        Bc2cppFiberFrame* bc2cpp_made = #{maker}(M, bc2cpp_env, bc2cpp_argc, bc2cpp_argv);
        if (!bc2cpp_made) mrb_raise(M, mrb_class_get(M, "RuntimeError"), "bc2cpp: block step did not make a frame");
        return bc2cpp_run_callee_from_c(M, bc2cpp_made);
      }
    CPP
    [fn_name, code]
  end

  # `recv.m(args, &blk)` in a step: the block is a proc already (a forwarded block), so only the call is dynamic.
  def resumable_explicit_block_dyn(region)
    return nil unless @resumable && @block_fallback_depth.to_i.zero?

    dest = region[:dest_reg].to_i
    recv = region[:self_implicit] ? 'self' : "r#{dest}"
    send_family = DYN_SEND_NAMES.include?(region[:name])
    splat = region[:n] == '*'
    return nil if send_family && !splat && region[:n].to_i < 1

    resumable_dyn_site(recv, dest, splat ? 0 : region[:n].to_i, "r#{region[:blk_reg]}",
                       name: send_family ? nil : region[:name], splat_reg: (region[:argv_reg] if splat), kw: region[:kw])
  end

  # The glue of a top-level `m(args) { block }` site in a step, or nil to keep the ordinary glue. The block's proc is
  # built on the heap (nothing in it points into the step's frame: block_step_candidate? takes no captured locals).
  def resumable_block_call_glue(region, fn_name, dest_reg, owner_def)
    return nil unless @resumable && owner_def && @block_fallback_depth.to_i.zero?
    maker = block_step_maker_for(region)
    # BLOCK_KEYWORD_CALL: keywords go through the dynamic call, which also parks a suspendable callee.
    if region[:kw] && !fiber_new_site?(region)
      send_name = DYN_SEND_NAMES.include?(region[:name]) && region[:n].to_i >= 1
      return resumable_dyn_block_glue(region, fn_name, dest_reg, maker, name: (region[:name] unless send_name))
    end
    # A plain block handed to a method that can suspend: the callee's frame is CALLed, so the block runs later from the fiber.
    return resumable_dyn_block_glue(region, fn_name, dest_reg, nil, name: region[:name]) if suspending_callee_plain_block?(region, maker)
    return nil unless region[:direct_entry] || region[:needs_ret] || region[:needs_brk]

    # A tail-yield block has no step: the callee's frame adapter arms its yield (bc2cpp_tail_yield).
    # A block that cannot suspend but returns from the method has no step either; the dynamic site catches its return.
    method_return = !maker && region[:needs_ret] && @resumable.upvars.nil?
    return nil unless (maker || tail_yield_block?(region[:block_irep]) || method_return) && !fiber_new_site?(region)
    return resumable_dyn_block_glue(region, fn_name, dest_reg, maker) if DYN_SEND_NAMES.include?(region[:name]) && region[:n].to_i >= 1

    target = maker && region[:self_implicit] ? resumable_block_call_target(region[:name], owner_def) : nil
    # No known suspendable callee: the method is looked up on the receiver at run time (a core iterator's variant, or a
    # method of another owner); anything that is not registered runs as an ordinary call with the block.
    return resumable_dyn_block_glue(region, fn_name, dest_reg, maker, name: region[:name]) unless target
    return nil unless mandatory_arity(@ireps.fetch(target.irep)) == region[:n].to_i

    # The block only runs as a step here (the callee's entry parks its frame and runs nothing), so its plain tokens are dead.
    rproc_var, ctor = resumable_step_rproc(region, fn_name, maker, region[:needs_ret] ? 'mrb_int_value(M, 0)' : nil,
                                           region[:needs_brk] ? 'mrb_int_value(M, 0)' : nil)
    mark_step_return_handled(region) if region[:needs_ret] && @resumable.upvars.nil?
    args = argument_registers(dest_reg, region[:n]) + ["mrb_obj_value(#{rproc_var})"]
    state = @resumable.new_state
    lines = resumable_call_lines(state, region[:name], target, dest_reg, args)
    split = lines.index { |l| l.start_with?('  Lbc2cpp_resume_') }
    "  {\n#{ctor}#{lines[0...split].join("\n")}\n  }\n#{lines[split..].join("\n")}\n"
  end

  def suspending_callee_plain_block?(region, maker)
    !maker && !region[:needs_ret] && !region[:needs_brk] && !fiber_new_site?(region) && @fiber_yield_names&.include?(region[:name]) &&
      !DYN_SEND_NAMES.include?(region[:name]) && !tail_yield_block?(region[:block_irep])
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
      void* callee; // CALL_STEP: the frame this suspension asks the fiber to call (a Bc2cppFiberFrame*), or null
      mrb_int pc; // HANDLERS: the address of the instruction the step was last at (the handler lookup reads it)
      mrb_int raise_pending; // HANDLERS: the fiber delivered an exception (in R[1]) to raise when the step is re-entered
      mrb_int has_handlers; // HANDLERS: the step has a handler table and has not declined the exception in flight
      void* unwind_key; // UNWIND: the heap frame of the method frame a `break`/`return` ends
      int unwind_mode; // 0 none, 1 break (resume the target with the value), 2 return (the target finishes with it)
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
    static void bc2cpp_fiber_define(mrb_state* M); // the fiber runtime, after this
    static void bc2cpp_resumable_init(mrb_state* M) {
      if (mrb_const_defined_at(M, mrb_obj_value(M->object_class), mrb_intern_lit(M, "Bc2cppResumable"))) return;
      bc2cpp_fiber_define(M); // Fiber, FiberError and Fiber.yield exist before any suspendable method runs
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
    // CALL_STEP / DYN_CALL: a step that asked for a callee frame has it run to its end here, so its result is the step's
    // resume value (bc2cpp_run_callee_from_c, in the fiber runtime after this).
    struct Bc2cppFiberFrame;
    static mrb_value bc2cpp_run_callee_from_c(mrb_state* M, Bc2cppFiberFrame* callee);
    static mrb_value bc2cpp_resumable_resume_from_c(mrb_state* M, mrb_value frame) {
      Bc2cppResumeFrame* suspended = (Bc2cppResumeFrame*)DATA_PTR(frame);
      if (suspended && suspended->callee) {
        Bc2cppFiberFrame* callee = (Bc2cppFiberFrame*)suspended->callee;
        suspended->callee = nullptr;
        return bc2cpp_run_callee_from_c(M, callee);
      }
      if (!mrb_test(bc2cpp_resume_frame_block_call(M, frame))) return bc2cpp_resumable_yield_from_c(M, frame);
      mrb_value args = bc2cpp_resume_frame_value(M, frame);
      mrb_value blk = bc2cpp_resume_frame_block(M, frame);
      return bc2cpp_yield_foreign(M, blk, RARRAY_LEN(args), RARRAY_PTR(args));
    }
  CPP
end
