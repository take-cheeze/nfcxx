# frozen_string_literal: true

# CodeGen: inlined Integer#step / #upto / #downto loops (ADR 0273).

class CodeGen
  STEP_LOOP_KINDS = {
    'step' => { argc: 'n=2', block_offset: 3 },
    'upto' => { argc: 'n=1', block_offset: 2 },
    'downto' => { argc: 'n=1', block_offset: 2 }
  }.freeze

  # Loop bounds and the step are held in `long long` so `i += step` cannot wrap a 32-bit
  # `mrb_int`; a literal is admitted only if it is a fixnum on every target.
  STEP_LOOP_LITERAL_MAX = 0x3fff_ffff

  # `recv.step(limit, step) { |i| ... }`, `recv.upto(limit)`, `recv.downto(limit)` with an
  # Integer receiver and limit and (for `step`) a literal non-zero step. Integer#step is
  # mrblib's `while i <= num` loop for a positive step (`>=` for a negative one) and
  # returns the receiver, so the inlined loop is the same iteration; a Float receiver or
  # limit runs other code (Float#step), hence the operands must be proven Integers here
  # (step_loop_operand). The emitter checks the proof, which needs the owner definition.
  def recognize_step_regions(irep)
    regions = []
    layout = lambda do |insn|
      shape = STEP_LOOP_KINDS[insn.sym]
      shape[:block_offset] if shape && insn.argc_text == shape[:argc]
    end
    each_block_site(irep, send_ops: %w[SENDB], layout: layout) do |insn, sendb_idx, block_insn, dest_reg, block_irep|
      next unless [0, 1].include?(mandatory_arity(block_irep)) && pure_mandatory_arity?(block_irep)
      next unless block_blk_needs(block_irep) == []

      kind = insn.sym
      step = 1
      if kind == 'step'
        step = step_loop_literal(irep, sendb_idx - 1, (dest_reg.to_i + 2).to_s)
        next if step.nil? || step.zero?
      elsif kind == 'downto'
        step = -1
      end

      regions << { block_addr: block_insn.addr, sendb_addr: insn.addr, dest_reg: dest_reg, block_irep: block_irep,
                   bind_counter: mandatory_arity(block_irep) == 1, kind: kind, step: step,
                   sendb_idx: sendb_idx, limit_reg: (dest_reg.to_i + 1).to_s }
    end
    regions
  end

  # The integer a register holds at `from` if the LOADI that wrote it is straight-line
  # code up to the call (no jump lands between them), else nil.
  def step_loop_literal(irep, from, reg)
    writer_index = irep.last_writer_index(from, reg)
    return nil unless writer_index

    writer = irep.instructions[writer_index]
    return nil unless writer.op.start_with?('LOADI')

    value = (writer.paren_value || writer.imm_operand)&.to_i
    return nil unless value&.abs&.<=(STEP_LOOP_LITERAL_MAX)

    landed = jump_targets(irep).any? { |addr| addr > writer.addr && addr <= irep.instructions[from].addr }
    landed ? nil : value
  end

  # A C++ `long long` expression for a loop operand, or nil if it is not provably an Integer.
  def step_loop_operand(irep, region, reg, d)
    literal = step_loop_literal(irep, region[:sendb_idx] - 1, reg)
    return "#{literal}LL" if literal
    return nil unless proven_fixnum_operand?(irep, region[:sendb_idx], reg, d)

    "(long long)mrb_integer(r#{reg})"
  end

  # A `for` over a `long long` counter, so `i += step` cannot wrap a 32-bit `mrb_int` (both
  # bounds are fixnums, hence so is every counter value that reaches the block). A flat loop (in
  # a resumable method) keeps the counter and the bound in frame slots and uses `goto`, because
  # a yield inside it must be resumable. A `break` assigns the send's destination and leaves it.
  def emit_step_inline(region, irep, d)
    block_irep = region[:block_irep]
    offset = irep.nregs
    dest = region[:dest_reg]
    addr = region[:block_addr]
    start = step_loop_operand(irep, region, dest, d)
    limit = step_loop_operand(irep, region, region[:limit_reg], d)
    return nil unless start && limit

    iter_label = "Lbc2cpp_step_iter_#{addr}"
    break_label = "Lbc2cpp_step_end_#{addr}"
    flat = !@resumable.nil?
    body = with_resumable_flat(flat) do
      compile_inline_block_body(region, irep, d, iter_label, break_label: break_label)
    end
    return nil unless body

    cmp = region[:step].positive? ? '<=' : '>='
    param = "r#{1 + offset} = mrb_fixnum_value((mrb_int)"
    out = String.new
    if flat
      i = "F->slots[#{@resumable.new_slot}]"
      bound = "F->slots[#{@resumable.new_slot}]"
      out << "  #{bound} = #{limit};\n"
      out << "  #{i} = #{start};\n"
      out << "  Lbc2cpp_step_top_#{addr}:;\n"
      out << "  if (!(#{i} #{cmp} #{bound})) goto #{break_label};\n"
      out << inline_block_reset(block_irep, offset)
      out << "  #{param}#{i});\n" if region[:bind_counter]
      out << body
      out << "  #{iter_label}:;\n"
      out << "  #{i} += #{region[:step]};\n"
      out << "  goto Lbc2cpp_step_top_#{addr};\n"
      out << "  #{break_label}:;\n"
    else
      i = "bc2cpp_step_i_#{addr}"
      out << "  {\n"
      out << "    const long long bc2cpp_step_limit_#{addr} = #{limit};\n"
      out << "    for (long long #{i} = #{start}; #{i} #{cmp} bc2cpp_step_limit_#{addr}; #{i} += #{region[:step]}) {\n"
      out << inline_block_frame(block_irep, offset)
      out << "      #{param}#{i});\n" if region[:bind_counter]
      out << body
      out << "      #{iter_label}:;\n"
      out << "    }\n"
      out << "    #{break_label}:;\n"
      out << "  }\n"
    end
    # Integer#step/upto/downto return the receiver, which r<dest> still holds (the
    # recognizer's `break` path overwrites it with the break value).
    out
  end

  # inline_block_frame's declarations as assignments, for a frame whose registers are
  # declared once at function scope.
  def inline_block_reset(block_irep, offset)
    out = String.new
    (1...block_irep.nregs).each { |i| out << "  r#{i + offset} = mrb_nil_value();\n" }
    out << "  r#{offset} = self;\n"
  end
end
