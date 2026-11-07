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
  attr_accessor :nregs, :register_slots, :upvars, :boxed
  # BLOCK: the method takes a block (kept in the frame's block slot). block_slot is that slot's R index.
  attr_accessor :block, :block_slot
  # HANDLERS: the irep's catch handlers (rescue/ensure) when the step has any, and the state each one's entry is dispatched by.
  attr_accessor :handlers
  # STEP_EXIT_JUMPS: [address, value register or nil] of each return/break/jump that parks an exit for an ensure body to run.
  attr_accessor :exit_sites
  # OPTIONAL_ARGS: how many optional positional arguments the method takes (its jump table is the glue at the first
  # JMP, which switches on bc2cpp_given_opt). 0 for a method without optional arguments.
  attr_accessor :optional
  # STEP_KEYWORDS: the method's keyword table (keyword_arg_table) and the frame index of the first keyword cell. Each
  # keyword has a value cell, and an optional one a second cell for its given flag; the step reads them into locals.
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

  # STEP_HANDLERS: a step may have rescue and ensure handlers (the exception is caught around the step body and the step is
  # re-entered at the handler, see resumable_step_function). STEP_EXIT_JUMPS: a return, break or unwinding jump that leaves
  # an ensure region runs the ensure body first (step_exit_guard), so every handler type the VM has is accepted here.
  def resumable_handler_problem(irep)
    handlers = irep.catch_handlers
    return nil if handlers.empty?
    return 'has a handler of a type a step cannot enter' unless handlers.all? { |h| %i[rescue ensure].include?(h.type) }

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

  # STEP_EXIT_JUMPS: a return, break or JMPUW inside a begin/ensure region that it leaves. As the VM does, the exit is parked in
  # a token (Bc2cppExit: the instruction's address, the value it carries and, for a jump, its target) that stands in for the
  # exception EXCEPT captures, and control goes to the ensure handler. The ensure body runs; its RAISEIF finds the token and
  # either hands it to the next enclosing ensure or continues the exit: Lbc2cpp_exit_dispatch jumps back to the label before the
  # instruction's own code, with the value restored (the ensure body may have used the register).
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
    handler_problem = resumable_handler_problem(irep)
    return handler_problem if handler_problem

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
        return 'calls Fiber.yield with a splat or keywords' if argc.nil?

        next
      end
      next unless @fiber_yield_names.include?(name)

      # A call with a block, on self or on any receiver, is a CALL to a known suspendable method or a dynamic call
      # (RESUMABLE_DYN_CALL); either way the block's own steps carry the suspension, and a site that can do neither
      # runs as an ordinary call.
      next if %i[SENDB SSENDB].include?(insn.op)

      unless %i[SSEND SSEND0].include?(insn.op)
        return "calls the yielding method #{name} with an explicit receiver or a block"
      end
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
      return resumable_dyn_send_insn(insn) if dyn_send_site?(insn, idx) && reg_offset.zero?
      return resumable_transfer_intercept(insn, irep, d, idx, reg_offset) if transfer_site?(insn, idx, reg_offset)
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
      return resumable_dyn_send_insn(insn) if dyn_send_site?(insn, idx) && reg_offset.zero?

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
  def resumable_block_site(insn, argc: insn.uint_operand.to_i, splat: false)
    return resumable_not_flat_error('yield') unless @resumable.flat

    state = @resumable.new_state
    dest = insn.reg
    values = (1..argc).map { |i| "r#{dest.to_i + i}" }
    packed = values.empty? ? 'mrb_ary_new(M)' : "bc2cpp_block_args_from(M, {#{values.join(', ')}})"
    # `block.call(*args)`: the one argument register already holds the Array of values.
    packed = "r#{dest.to_i + 1}" if splat
    [
      "  // RESUMABLE_BLOCK_CALL #{state}",
      # The block this suspension calls (a `yield`'s, or a proc held in a variable): the fiber's adapter reads it back.
      "  mrb_iv_set(M, bc2cpp_frame_value, mrb_intern_lit(M, \"__block__\"), r#{dest});",
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
    return false unless insn.op == :SEND && insn.sym == 'call' && idx && @resumable&.flat
    return false if @resumable_plain || reg_offset != 0

    insn.plain_fixed_argc? || insn.positional_splat?
  end

  # DYN_CALL: sends whose method is chosen at run time. In a step they go through bc2cpp_dyn_call, which returns the
  # frame of a registered suspendable method for the step to CALL.
  DYN_SEND_NAMES = %w[send __send__ public_send].freeze

  def dyn_send_site?(insn, idx)
    return false unless %i[SEND SENDB SSEND SSENDB].include?(insn.op) && DYN_SEND_NAMES.include?(insn.sym) && idx
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
    if splat_reg
      ary = "r#{splat_reg}"
      if name
        name_expr = "mrb_symbol_value(mrb_intern_cstr(M, #{c_string_literal(name)}))"
        argc_expr = "ary_size(#{ary})"
        argv_expr = "ary_items(#{ary})"
      else
        setup << "    if (ary_size(#{ary}) == 0) mrb_raise(M, mrb_exc_get_id(M, mrb_intern_lit(M, \"ArgumentError\")), \"no method name given\");"
        name_expr = "ary_items(#{ary})[0]"
        argc_expr = "ary_size(#{ary}) - 1"
        argv_expr = "ary_items(#{ary}) + 1"
      end
    else
      args = (1..argc).map { |i| "r#{dest + i}" }
      # `send(:m, a)` carries the name as its first argument; a plain call has a fixed name.
      name_expr = name ? "mrb_symbol_value(mrb_intern_cstr(M, #{c_string_literal(name)}))" : args.first
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
      "  F->state = #{state};",
      '  bc2cpp_step_guard.yielding = true;',
      RESUMABLE_SPILL_MARK,
      '  R[0] = mrb_nil_value();',
      '  mrb_write_barrier(M, (struct RBasic*)mrb_ary_ptr(bc2cpp_regs_ary));',
      '  bc2cpp_resume_frame_set_call(M, bc2cpp_frame_value, false);',
      '  return bc2cpp_frame_value;',
      "  Lbc2cpp_resume_#{state}:;",
      "  r#{dest} = R[1];",
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

  # DYN_SUPER: `super(args)` in a method step. The block is the register after the arguments (OP_SUPER passes
  # R(a+n+1)). A suspendable target parks and is CALLed; the lookup starts above the method's own class. Nil (the ordinary
  # SUPER rules apply) for a shape it does not take.
  def resumable_super_site(insn, d, idx, reg_offset)
    return nil unless @resumable.flat && reg_offset.zero? && @resumable.upvars.nil? && d && insn.plain_fixed_argc?
    return nil if d.owner.end_with?('.singleton')

    n = insn.argc.to_i
    dest = insn.reg
    call = "bc2cpp_dyn_super(M, self, #{owner_class_ptr_expr(d.owner)}, mrb_intern_lit(M, #{d.name.inspect}), #{n}, bc2cpp_dyn_argv, " \
           "r#{dest + n + 1})"
    # With a name given the site passes r(d+1)..r(d+n) as the arguments; the call itself is replaced by the super lookup.
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

  def resumable_block_call_intercept(insn, irep, d, idx, reg_offset)
    dest = insn.reg
    suspend = resumable_block_site(insn, argc: insn.argc.to_i, splat: insn.positional_splat?)
    plain = begin
      @resumable_plain = true
      compile_insn_op(insn, irep, d, idx, reg_offset)
    ensure
      @resumable_plain = false
    end
    [
      "  if (mrb_proc_p(r#{dest}) && !MRB_PROC_STRICT_P(mrb_proc_ptr(r#{dest}))) {",
      suspend.rstrip,
      '  } else {',
      plain.rstrip,
      '  }',
      ''
    ].join("\n")
  end

  # FIBER_TRANSFER: `fiber.transfer(v)` in a step is a yield of v when the receiver is the root or mruby fiber that
  # resumed this C++ Fiber, or the C++ Fiber whose resume/transfer runs it (bc2cpp_transfer_is_yield, run time); any
  # other receiver takes the ordinary send (Fiber#transfer on a C++ Fiber runs the target nested).
  def transfer_site?(insn, idx, reg_offset)
    return false unless insn.sym == 'transfer' && idx && @resumable&.flat && !@resumable_plain && reg_offset.zero?

    insn.op == :SEND0 || (insn.op == :SEND && insn.plain_fixed_argc? && insn.argc.to_i.between?(1, 3))
  end

  def resumable_transfer_intercept(insn, irep, d, idx, reg_offset)
    dest = insn.reg
    suspend = resumable_yield_site(insn, transfer: true)
    plain = begin
      @resumable_plain = true
      compile_insn_op(insn, irep, d, idx, reg_offset)
    ensure
      @resumable_plain = false
    end
    ["  if (bc2cpp_transfer_is_yield(M, r#{dest})) {", suspend.rstrip, '  } else {', plain.rstrip, '  }', ''].join("\n")
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
            else "bc2cpp_block_args_from(M, {#{(1..argc).map { |i| "r#{dest.to_i + i}" }.join(', ')}})"
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
    # STEP_CLOSURES: the registers a block may keep live in a cells Array the frame holds in one more slot; the step makes
    # the Array on its first run, from the values the entry put in those registers' slots.
    boxed = (@resumable.boxed || []) & registers
    cells_slot = boxed.empty? ? nil : registers.size + 2 + (@resumable.block ? 1 : 0)
    kw_cells = @resumable.kw ? @resumable.kw.sum { |kw| kw[:required] ? 1 : 2 } : 0
    @resumable.kw_base = registers.size + 2 + (@resumable.block ? 1 : 0) + (cells_slot ? 1 : 0)
    nregs = registers.size + (@resumable.block ? 1 : 0) + (cells_slot ? 1 : 0) + kw_cells
    @resumable.nregs = nregs
    @resumable.block_slot = block_slot
    @resumable.register_slots = registers.each_with_index.to_h { |reg, slot| [reg, slot + 2] }
    locals = ENV['BC2CPP_RESUMABLE_LOCALS'] != '0' && !code_only.match?(RESUMABLE_REGISTER_ADDRESS) && boxed.empty?
    spill = registers.each_with_index.map { |reg, slot| "R[#{slot + 2}] = r#{reg};" }.join(' ')
    body = body.gsub(/^#{Regexp.escape(RESUMABLE_SPILL_MARK)}$/) { locals ? "  #{spill}" : '' }
    out = String.new
    out << "static mrb_value #{step_name}(mrb_state* M, mrb_value self, mrb_value bc2cpp_frame_value, mrb_value bc2cpp_resume) {\n"
    out << "  Bc2cppResumeFrame* F = bc2cpp_resume_frame(M, &bc2cpp_frame_value, #{nregs}, #{@resumable.slot_count});\n"
    out << "  mrb_value bc2cpp_regs_ary = bc2cpp_resume_regs(M, bc2cpp_frame_value);\n"
    out << "  mrb_value* R = F->regs;\n"
    (@resumable.upvars || []).each_with_index do |(level, idx), i|
      out << "  [[maybe_unused]] mrb_value* #{upvar_var_name(level, idx)} = (mrb_value*)F->slots[#{i}];\n"
    end
    if cells_slot
      out << "  mrb_value bc2cpp_cells_ary = R[#{cells_slot}];\n"
      out << "  if (mrb_nil_p(bc2cpp_cells_ary)) {\n    bc2cpp_cells_ary = mrb_ary_new_capa(M, #{boxed.size});\n"
      boxed.each { |reg| out << "    mrb_ary_push(M, bc2cpp_cells_ary, R[#{registers.index(reg) + 2}]);\n" }
      out << "    R[#{cells_slot}] = bc2cpp_cells_ary;\n    mrb_write_barrier(M, (struct RBasic*)mrb_ary_ptr(bc2cpp_regs_ary));\n  }\n"
      out << "  mrb_value* bc2cpp_cells = RARRAY_PTR(bc2cpp_cells_ary);\n"
      out << "  Bc2cppCellsGuard bc2cpp_cells_guard = { M, bc2cpp_cells_ary };\n"
    end
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
    # STEP_KEYWORDS: the entry put the keywords in the frame; KEY_P / KARG read them as the plain body's parameters.
    cell = @resumable.kw_base
    (@resumable.kw || []).each do |kw|
      out << "  [[maybe_unused]] mrb_value #{kwarg_param_name(kw[:name])} = R[#{cell}];\n"
      cell += 1
      next if kw[:required]

      out << "  [[maybe_unused]] mrb_int #{kw_given_param_name(kw[:name])} = mrb_test(R[#{cell}]) ? 1 : 0;\n"
      cell += 1
    end
    handlers = @resumable.handlers
    out << "  F->has_handlers = #{handlers ? handlers.size : 0};\n"
    out << "  #{handlers ? '' : 'const '}mrb_int bc2cpp_state = F->state;\n"
    # OPTIONAL_ARGS: a call that starts stores -(given + 1) in the frame state (the entry does). The body's jump-table
    # glue switches on bc2cpp_given_opt, and the resume switch is skipped for that start.
    optional = @resumable.optional.to_i.positive?
    out << "  const mrb_int bc2cpp_given_opt = bc2cpp_state < 0 ? -bc2cpp_state - 1 : 0;\n" if optional
    out << "  if (bc2cpp_state != 0) R[1] = bc2cpp_resume;\n"
    out << "  r0 = self;\n"
    # STEP_HANDLERS: the body runs in a protected call so an exception can be turned into a jump to a handler's entry.
    out << "  auto bc2cpp_body = [&]() -> mrb_value {\n" if handlers
    out << "  mrb_value bc2cpp_exit_cur = mrb_nil_value();\n" if step_ensure_handlers?
    # An exception the fiber delivers (a frame this step CALLed raised, or an unwind passes through it) is raised here, at
    # the address the step suspended at, so the handler lookup is the same as for one raised by the step itself.
    out << "  if (F->raise_pending) { F->raise_pending = 0; mrb_exc_raise(M, R[1]); }\n" if handlers
    out << (optional ? "  if (bc2cpp_state >= 0) switch (bc2cpp_state) {\n    case 0: break;\n" : "  switch (bc2cpp_state) {\n    case 0: break;\n")
    @resumable.states.each { |n| out << "    case #{n}: goto Lbc2cpp_resume_#{n};\n" }
    (handlers || []).each_with_index { |h, k| out << "    case #{RESUMABLE_HANDLER_STATE + k}: goto L#{h.target};\n" }
    out << "    default: bc2cpp_resume_bad_state(M);\n  }\n"
    out << body
    out << resumable_handler_loop(handlers, locals ? spill : '') if handlers
    out
  end

  RESUMABLE_HANDLER_STATE = 1_000_000

  # The loop that runs the body of a step with handlers: an exception takes the innermost handler whose region covers the
  # address the step was last at (F->pc, set before each instruction), as vm.c's catch_handler_find does (the table is
  # searched from its last entry). The handler's entry reads the exception from M->exc (EXCEPT). No handler: the exception
  # leaves the step, which declines further delivery (has_handlers 0) so the fiber moves on to the frame below.
  def resumable_handler_loop(handlers, spill)
    out = String.new
    out << "  };\n"
    out << "  for (;;) {\n"
    out << "    mrb_bool bc2cpp_err = FALSE;\n"
    out << "    mrb_value bc2cpp_res = mrb_protect_error(M, bc2cpp_protect_tramp<decltype(bc2cpp_body)>, &bc2cpp_body, &bc2cpp_err);\n"
    out << "    if (!bc2cpp_err) return bc2cpp_res;\n"
    out << "    mrb_int bc2cpp_hs = -1;\n"
    first = true
    handlers.each_with_index.to_a.reverse_each do |h, k|
      out << "    #{first ? '' : 'else '}if (F->pc >= #{h.begin_addr} && F->pc < #{h.end_addr}) bc2cpp_hs = #{RESUMABLE_HANDLER_STATE + k};\n"
      first = false
    end
    out << "    if (bc2cpp_hs < 0) { F->has_handlers = 0; mrb_exc_raise(M, bc2cpp_res); }\n"
    # GC: mrb_protect_error dropped the arena entries of the objects the run made, and a register that holds one in a C++ local
    # (RESUMABLE_LOCAL_REGISTERS) is not a root, so the values go back to the frame (rooted) before anything allocates.
    unless spill.empty?
      out << "    #{spill}\n"
      out << "    mrb_write_barrier(M, (struct RBasic*)mrb_ary_ptr(bc2cpp_regs_ary));\n"
    end
    out << "    M->exc = (struct RObject*)mrb_obj_ptr(bc2cpp_res);\n"
    out << "    bc2cpp_state = bc2cpp_hs;\n"
    out << "  }\n"
    out
  end

  # `_impl`, the function the registered entry calls: hands a VM-called invocation to the
  # bytecode driver and steps to completion when called from C (where Fiber.yield could
  # not have worked in the bytecode either).
  # DYN_CALL: the dispatcher a `send` of this method reaches (bc2cpp_dyn_call): arms the method's id, runs its entry (which
  # parks the frame) and registers itself under the method's registered C function. Mandatory parameters only.
  def resumable_dyn_function(impl_name, owner_name, argc, blk, wrapper: impl_name.delete_suffix('_impl'), optional: 0, rest: false, kw: nil)
    # An omitted optional argument is nil and the entry is told how many were given (the registered wrapper does the same).
    # A rest parameter is the last one: the arguments past the mandatory ones, packed into an Array.
    fixed = rest ? argc - 1 : argc
    args = (0...fixed).map { |i| ", argc > #{i} ? argv[#{i}] : mrb_nil_value()" }.join
    args += ", argc > #{fixed} ? mrb_ary_new_from_values(M, argc - #{fixed}, argv + #{fixed}) : mrb_ary_new(M)" if rest
    given = optional.positive? ? ", std::min<mrb_int>(argc - #{fixed - optional}, #{optional})" : ''
    max = rest ? 'INT32_MAX' : fixed
    return resumable_dyn_kw_function(impl_name, owner_name, args, blk, given, fixed - optional, max, wrapper, kw) if kw

    <<~CPP
      static mrb_value #{impl_name}_dyn(mrb_state* M, mrb_value self, mrb_int argc, const mrb_value* argv, mrb_value bc2cpp_dyn_blk) {
        (void)argc; (void)argv; (void)bc2cpp_dyn_blk;
        bc2cpp_prologue.expect = #{c_string_literal(owner_name)};
        bc2cpp_prologue.frame = nullptr;
        mrb_value result = #{impl_name}(M, self#{args}#{blk ? ', bc2cpp_dyn_blk' : ''}#{given});
        bc2cpp_prologue.expect = nullptr;
        return result;
      }
      static const int #{impl_name}_dyn_reg = (bc2cpp_dyn_register((void*)&#{wrapper}, #{impl_name}_dyn, #{fixed - optional}, #{max}), 0);
    CPP
  end

  # STEP_KEYWORDS: the dispatcher of a method with keywords. bc2cpp_dyn_bind_keywords declines a call the wrapper would
  # refuse (a missing or unknown keyword), which then runs as an ordinary send and raises there.
  def resumable_dyn_kw_function(impl_name, owner_name, args, blk, given, min, max, wrapper, kw)
    ordered = kw.select { |k| k[:required] } + kw.reject { |k| k[:required] }
    names = ordered.map { |k| "mrb_intern_cstr(M, #{c_string_literal(k[:name].to_s)})" }.join(', ')
    index = ordered.each_with_index.to_h { |k, i| [k[:name], i] }
    kw_args = kw.map do |k|
      value = "bc2cpp_dkw_values[#{index[k[:name]]}]"
      flag = k[:required] ? '' : ", mrb_undef_p(#{value}) ? 0 : 1"
      ", mrb_undef_p(#{value}) ? mrb_nil_value() : #{value}#{flag}"
    end.join
    <<~CPP
      static mrb_value #{impl_name}_dyn(mrb_state* M, mrb_value self, mrb_int argc, const mrb_value* argv, mrb_value bc2cpp_dyn_kd, mrb_value bc2cpp_dyn_blk) {
        (void)argc; (void)argv; (void)bc2cpp_dyn_blk;
        mrb_sym bc2cpp_dkw_names[#{ordered.size}] = { #{names} };
        mrb_value bc2cpp_dkw_values[#{ordered.size}];
        if (!bc2cpp_dyn_bind_keywords(M, bc2cpp_dyn_kd, #{ordered.size}, #{ordered.count { |k| k[:required] }}, bc2cpp_dkw_names, bc2cpp_dkw_values)) return mrb_undef_value();
        bc2cpp_prologue.expect = #{c_string_literal(owner_name)};
        bc2cpp_prologue.frame = nullptr;
        mrb_value result = #{impl_name}(M, self#{args}#{blk ? ', bc2cpp_dyn_blk' : ''}#{given}#{kw_args});
        bc2cpp_prologue.expect = nullptr;
        return result;
      }
      static const int #{impl_name}_dyn_reg = (bc2cpp_dyn_register_kw((void*)&#{wrapper}, #{impl_name}_dyn, #{min}, #{max}), 0);
    CPP
  end

  def resumable_entry_function(impl_name, step_name, owner_name, arg_names = [], ctx = nil, blk = false, optional: 0, rest: false)
    thunk = "#{step_name}_thunk"
    dyn = !@rsm_variant && !@block_step_compile
    kw = ctx&.kw
    if arg_names.empty? && !blk && !kw
      # No arguments: the frame starts empty, and the driver's first step creates it.
      return <<~CPP + (dyn ? resumable_dyn_function(impl_name, owner_name, 0, false) : '')
        static mrb_value #{thunk}(mrb_state* M, mrb_value) {
          mrb_value self, frame, resume;
          mrb_get_args(M, "ooo", &self, &frame, &resume);
          return #{step_name}(M, self, frame, resume);
        }
        mrb_value #{impl_name}(mrb_state* M, mrb_value self) {
          // An armed entry is reached from the runtime (a dispatcher, a CALL site, a Fiber body's start), which counted already.
          if (!bc2cpp_prologue.expect) bc2cpp_check_argc(M, 0, 0);
          bc2cpp_resumable_init(M);
          mrb_value frame = mrb_nil_value(), resume = mrb_nil_value();
          if (bc2cpp_prologue_armed(M, #{c_string_literal(owner_name)}, self)) {
            // The frame exists before it is parked: the maker of a block step stores the pointers it captured in it.
            bc2cpp_resume_frame(M, &frame, #{ctx.nregs}, #{ctx.slot_count});
            return bc2cpp_prologue_park(M, bc2cpp_method_frame_new(M, #{step_name}, self, frame));
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
kw_params = (kw || []).flat_map do |k|
  ["mrb_value #{kwarg_param_name(k[:name])}"] + (k[:required] ? [] : ["mrb_int #{kw_given_param_name(k[:name])}"])
end
params = (arg_names.map { |a| "mrb_value #{a}" } + (blk ? ['mrb_value bc2cpp_blk'] : []) +
          (optional.positive? ? ['mrb_int bc2cpp_given_opt'] : []) + kw_params).join(', ')
# Each argument's slot in the frame; a register the body never reads has none and is not copied.
fill = arg_names.each_with_index.filter_map do |a, idx|
  slot = ctx.register_slots[idx + 1]
  "F->regs[#{slot}] = #{a};" if slot
end
# The block goes in the frame's block slot, and in the frame's __block__ for the driver to call.
if blk
  # mruby keeps the block in register argc+1, which `yield` (BLKPUSH) reads, so that register's slot gets it too.
  # With keywords the keyword-hash register sits between the arguments and the block.
  block_reg_slot = ctx.register_slots[n + 1 + (kw ? 1 : 0)]
  fill += ['mrb_iv_set(M, frame, mrb_intern_lit(M, "__block__"), bc2cpp_blk);', "F->regs[#{ctx.block_slot}] = bc2cpp_blk;"]
  fill << "F->regs[#{block_reg_slot}] = bc2cpp_blk;" if block_reg_slot
end
# STEP_KEYWORDS: each keyword's value (and given flag) goes in the frame's keyword cells.
cell = ctx.kw_base
(kw || []).each do |k|
  fill << "F->regs[#{cell}] = #{kwarg_param_name(k[:name])};"
  cell += 1
  next if k[:required]

  fill << "F->regs[#{cell}] = mrb_bool_value(#{kw_given_param_name(k[:name])});"
  cell += 1
end
optional_head = optional.positive? ? "    F->state = -(bc2cpp_given_opt + 1);\n" : ''
# REST_ARGS: the wrapper checked the count and built the rest Array, so the impl checks nothing.
argc_check = ''
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
      return bc2cpp_prologue_park(M, bc2cpp_method_frame_new(M, #{step_name}, self, frame));
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
head + optional_head + fill.map { |line| "  #{line}\n" }.join + tail + (dyn ? resumable_dyn_function(impl_name, owner_name, n, blk, optional: optional, rest: rest, kw: kw) : '')
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

  # `Fiber.new { prologue; m(args) }`: the block ends with a call on self to a suspendable method `m` of the
  # enclosing method's owner and returns its value. The block's only call is that one, so the C++ Fiber can run the block
  # with `m` armed (bc2cpp_prologue), let `m`'s entry park its frame instead of running it, and call that frame as
  # the fiber's body. Returns the entry's id ("Owner#m"), or nil for any other shape (the site then keeps its old form).
  # Is +region+ a `Fiber.new { ... }` site (no arguments, a literal block)?
  def fiber_new_site?(region)
    return false unless region[:name] == 'new' && !region[:self_implicit] && region[:n].to_i.zero?

    parent = region[:parent_irep]
    idx = parent && parent.index_of_addr(region[:sendb_addr])
    idx ? fiber_const_receiver?(parent, idx, region[:dest_reg]) : false
  end

  def fiber_body_target_id(region, owner_def)
    return nil unless owner_def && fiber_new_site?(region)

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
  def block_step_candidate?(region, owner_def, builder_upvars = nil)
    return false unless owner_def && ENV['BC2CPP_BLOCK_STEP'] != '0' && !@block_step_compile

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

    yields = false
    BytecodeIR.for(block).each_with_op(:SEND, :SEND0) do |insn, idx|
      yields ||= insn.sym == 'yield' && fiber_const_receiver?(block, idx, insn.reg)
    end
    # `block.call(x)` on a proc held in a variable may reach a Fiber.yield, in a method a fiber runs (or its variant).
    yields ||= (@rsm_variant || @fiber_roots&.include?(owner_def.irep)) && BytecodeIR.for(block).instructions_with_op(:SEND, :SEND0).any? { |i| i.sym == 'call' }
    # A block that calls the block of the method that built it (`yield` in an inner block) suspends through that block.
    yields ||= region[:needs_blk] && BytecodeIR.for(block).op?(:BLKCALL)
    # A block that builds a block which reaches Fiber.yield suspends through it (the nested block is a step, DYN_CALL).
    yields ||= (block.reps || []).any? { |child| (c = child && @ireps[child]) && deep_fiber_yield?(c, Set.new) }
    # A block may also suspend through the suspendable methods it calls on self (CALL_STEP).
    unless yields
      BytecodeIR.for(block).each_with_op(:SSEND, :SSEND0) { |insn, _| yields ||= @fiber_yield_names&.include?(insn.sym) }
    end
    yields
  end

  # BLOCK_STEP_UNWIND: the targets a block's `return` and `break` name when its step runs as a frame of the fiber. A break
  # ends the call that took the block, made by the step building it; a return ends the method, which is the building step's
  # frame, or the target the building block step itself carries. Nil values when the builder is not a step.
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

  # BLOCK_STEP_UPVARS: a block step may read and write locals of the step that builds it. The site passes pointers to
  # them (the step's registers are references into its heap frame, see resumable_step_function), which the maker keeps
  # in the block frame's slots. That is sound where the caller's frame lives as long as the callee: a call on self to a
  # suspendable method (a CALL, so the caller's frame stays on the fiber's stack) and not a Fiber body, which outlives it.
  # STEP_NESTED_UPVARS: a local of the builder's own builder (level >= 1) is forwarded when the builder is a block step that
  # holds a pointer to it (+builder_upvars+, the builder region's upvars).
  def block_step_upvars_ok?(region, owner_def, builder_upvars = nil)
    # A Fiber body outlives the frame: its pointers must lead into cells (STEP_CLOSURES), not into the frame.
    return false if fiber_new_site?(region) && !region[:boxed]

    region[:upvars].all? { |(level, idx)| level.zero? || builder_upvars&.include?([level - 1, idx]) }
  end

  # Can the literal block of an inline-loop +region+ suspend the fiber: it reaches Fiber.yield, calls a block
  # (`yield`, `block.call`), or calls a method that can suspend.
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
                                              cells: region[:boxed] ? true : false,
                                              direct_entry: "#{fn_name}_direct", yield_free: region[:yield_free],
                                              step_maker: block_step_maker_for(region))
    "  // FIBER_BODY_STEP :new -- the body is a step, the root frame of a C++ Fiber\n  {\n#{ctor}" \
      "    r#{dest_reg} = bc2cpp_fiber_new_step(M, mrb_obj_value(#{rproc_var}));\n  }\n"
  end

  # Compiles every BLOCK_STEP candidate among +regions+ and returns the C++ text to put ahead of the method; each
  # compiled region gets :step_maker (the maker's name). Done before the owner's own compile starts, so nothing of it
  # is mid-flight (the dual variants are compiled the same way).
  def compile_block_steps(regions, d, builder_upvars = nil)
    return '' if regions.empty? || @block_step_compile

    code = String.new
    regions.each do |region|
      # A block nested in another block is a region of the outer block's body (emit_proc_fallback_fn_body recognizes
      # it again there), so look for steps inside first and name them by block label, not by region object.
      nested = recognize_block_fallback_regions(region[:block_irep], available_upvars: region[:upvars] || [])
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
    saved_budget = @ir_inline_remaining
    saved_upvars = @block_step_upvars
    saved_label = @block_step_label
    saved_needs_blk = @block_step_needs_blk
    begin
      @block_step_compile = true
      @block_step_upvars = region[:upvars] || []
      @block_step_label = label
      # BLOCK_STEP_BLOCK: a `yield` in the block calls the block of the method that built it (BLKPUSH at level 1).
      @block_step_needs_blk = region[:needs_blk] ? true : false
      result = compile_method(label)
    ensure
      @block_step_compile = false
      @block_step_upvars = saved_upvars
      @block_step_label = saved_label
      @block_step_needs_blk = saved_needs_blk
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
    code << block_step_maker(block, "#{name}#{@entry_spec_suffix}_impl", "#{syn.owner}##{syn.name}", maker, region[:upvars] || [],
                            region[:needs_blk], region[:needs_ret] || region[:needs_brk], region[:boxed])
    # A compile that is run again (a probe, a variant) can put the same step in more than one method's text; the guard
    # keeps the first definition.
    guard = "BC2CPP_STEP_#{name}#{@entry_spec_suffix}".gsub(/[^A-Za-z0-9_]/, '_')
    code = "#ifndef #{guard}\n#define #{guard}\n#{code}#endif // #{guard}\n"
    @block_steps[label] = { code: code, maker: maker }
  end

  # The frame maker the block's env carries: binds the yielded values as a non-strict block binds them, runs the
  # step's entry with its own id armed so the entry parks the frame (bc2cpp_prologue) instead of running it, and
  # returns that frame, or nullptr when the entry did not park (the caller then calls the block directly).
  def block_step_maker(block, impl, id, maker, upvars = [], needs_blk = false, unwind = false, cells = false)
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
      if cells
        slot = 1 + upvars.size + (needs_blk ? 1 : 0)
        out << "    mrb_iv_set(M, ((Bc2cppMethodFrame*)bc2cpp_made)->frame, mrb_intern_lit(M, \"__cells__\"), bc2cpp_env->stack[#{slot}]);\n"
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

  # A call on self to a suspendable method with arguments: the step makes the callee's frame (its entry parks it when
  # its own id is armed, as for a Fiber body) and suspends with it; the fiber CALLs the frame, and the callee's result
  # is this step's resume value, which the site reads like the result of a Fiber.yield.
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
    args = (1..argc).map { |i| "r#{dest + i}" }
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
      "  F->state = #{state};",
      '  bc2cpp_step_guard.yielding = true;',
      RESUMABLE_SPILL_MARK,
      '  R[0] = mrb_nil_value();',
      '  mrb_write_barrier(M, (struct RBasic*)mrb_ary_ptr(bc2cpp_regs_ary));',
      '  bc2cpp_resume_frame_set_call(M, bc2cpp_frame_value, false);',
      '  return bc2cpp_frame_value;',
      "  Lbc2cpp_resume_#{state}:;",
      "  r#{dest} = R[1];"
    ]
  end

  # CALL_STEP with a block: the callee takes a block parameter and the site passes a literal block whose own body
  # suspends (it has a step maker, so the callee's yield CALLs the block's step). Nil when the site is not that shape.
  def resumable_block_call_target(name, d)
    target = resumable_call_target(name, d)
    return nil unless target

    callee = @ireps.fetch(target.irep)
    # Mandatory parameters and a bare `yield`, or an explicit `&block` parameter after them.
    ok = (pure_mandatory_arity?(callee) && yields_block_param?(callee)) ||
         (block_param_arity?(callee) && callee.enter.enter_fields[1].zero? && callee.enter.enter_fields[2].zero?)
    ok ? target : nil
  end

  def resumable_dyn_block_glue(region, fn_name, dest_reg, maker, name: nil)
    brk_site, ret_guard = step_unwind_tokens(region, @resumable.upvars.nil?)
    ret_token = region[:needs_ret] ? (ret_guard ? 'mrb_int_value(M, bc2cpp_ret_guard.frame.token)' : 'mrb_int_value(M, 0)') : nil
    brk_token = brk_site ? "mrb_int_value(M, #{brk_site}.frame.token)" : nil
    rproc_var, ctor = emit_rproc_construction(region[:block_addr], fn_name, region[:upvars] || [],
                                              region[:needs_blk] ? true : false, ret_token: ret_token, brk_token: brk_token,
                                              cells: region[:boxed] ? true : false,
                                              direct_entry: region[:direct_entry] ? "#{fn_name}_direct" : nil, yield_free: region[:yield_free],
                                              step_maker: maker, unwind_targets: (maker ? step_unwind_targets(region) : nil))
    (@step_ret_handled ||= Set.new) << [region[:parent_irep].label, region[:block_addr]] if ret_guard
    recv = region[:self_implicit] ? 'self' : "r#{dest_reg}"
    resumable_dyn_site(recv, dest_reg, region[:n].to_i, "mrb_obj_value(#{rproc_var})", ctor, name: name,
                                                                                         kw: region[:kw], brk_site: brk_site, ret_guard: ret_guard)
  end

  # STEP_HANDLERS: a block that has a step but no plain function (its begin/ensure has no function form) needs only a direct
  # entry: called from C, where no fiber CALLs its step, it runs the step to its end (a Fiber.yield in it is then the yield
  # across a C frame an interpreted block would make). The step glue (a dynamic or static call, a Fiber body) uses nothing else.
  def step_only_block_fn(region, d)
    return nil unless (@resumable || fiber_new_site?(region)) && d && @block_fallback_depth.to_i.zero? &&
                      (region[:kind] || 'block_fallback') == 'block_fallback'

    maker = block_step_maker_for(region)
    return nil unless maker && block_direct_entry?(region, 'block_fallback', false)

    fn_name = "#{cpp_name(d.owner, d.name)}_block_fallback_#{region[:block_addr]}"
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
    rproc_var, ctor = emit_rproc_construction(region[:block_addr], fn_name, region[:upvars] || [],
                                              region[:needs_blk] ? true : false, cells: region[:boxed] ? true : false,
                                              ret_token: region[:needs_ret] ? 'mrb_int_value(M, 0)' : nil,
                                              brk_token: region[:needs_brk] ? 'mrb_int_value(M, 0)' : nil,
                                              direct_entry: region[:direct_entry] ? "#{fn_name}_direct" : nil, yield_free: region[:yield_free],
                                              step_maker: maker, unwind_targets: step_unwind_targets(region))
    (@step_ret_handled ||= Set.new) << [region[:parent_irep].label, region[:block_addr]] if region[:needs_ret] && @resumable.upvars.nil?
    args = (1..region[:n]).map { |k| "r#{dest_reg + k}" } + ["mrb_obj_value(#{rproc_var})"]
    state = @resumable.new_state
    lines = resumable_call_lines(state, region[:name], target, dest_reg, args)
    # The proc is made in a scope of its own; the resume label and the result read follow it.
    split = lines.index { |l| l.start_with?('  Lbc2cpp_resume_') }
    "  {\n#{ctor}#{lines[0...split].join("\n")}\n  }\n#{lines[split..].join("\n")}\n"
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
    template <class Body>
    static mrb_value bc2cpp_protect_tramp(mrb_state*, void* body) { return (*(Body*)body)(); }
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
      return mrb_yield_argv(M, blk, RARRAY_LEN(args), RARRAY_PTR(args));
    }
  CPP
end
