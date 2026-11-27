# frozen_string_literal: true

require 'set'
require_relative 'bytecode_ir'
require_relative 'bytecode_ir_containers'
require_relative 'escape_analysis'

# FLOAT_SHADOW: a Float made by an arithmetic instruction (ADD SUB MUL DIV ADDI SUBI) or a Float literal (LOADL)
# whose every reader is another of those, a compare (LT LE GT GE) or a MOVE stays a C mrb_float in the frame-local
# `bc2cpp_f<reg>`, and its register holds mrb_undef as the marker. On a 32-bit word-boxing target every boxed Float is
# a heap object, so such a chain (`((n + 1) * 0.002 + 0.8) * (inflation - 1) + 1`) allocates nothing until its result
# is read by anything else, where it was boxed as before.
#
# A site is placed only when all of these hold (refusal is always the answer when unsure):
#   readers   every instruction that reads a register one of the site's values may reach (reaching definitions through
#             MOVEs and handler edges) is a MOVE, an arithmetic op or a compare reading it as an operand. EQ is not one:
#             OP_EQ's mrb_obj_eq sees identity, which an unboxed value does not have
#   model     every instruction of the irep has a modelled read set (stack_tuple_reads), so no reader is unseen
#   closures  with a BLOCK or LAMBDA in the irep, no value may reach a local register (< nlocals): a closure reads
#             those through its environment, which no instruction here shows
#   text      every planned instruction is emitted by compile_insn at offset 0 outside a resumable body, in the shapes
#             float_shadow_insn expects; one that is bypassed or not in shape drops the sites it reads or makes, and
#             the method compiles again without them
# The marker never reaches unaware code: a planned reader tests its marked operands first (bc2cpp_flo_bin), takes the
# Float arm on the unboxed value when OP_MATH / OP_CMP would, and otherwise boxes them before the instruction's own
# text runs. That text is unchanged, so every other arm (Fixnum, heap Integer, the operator send) is as without the
# plan. Float results equal the boxed ones: word boxing stores an mrb_float losslessly (heap RFloat or the rotation
# encoding), so boxing and unboxing are the identity on the value.
class CodeGen
  FLOAT_SHADOW_ARITH = { ADD: 0, SUB: 1, MUL: 2, DIV: 3 }.freeze
  FLOAT_SHADOW_CMP = { LT: 4, LE: 5, GT: 6, GE: 7 }.freeze
  FLOAT_SHADOW_IMM = Set[:ADDI, :SUBI].freeze
  FLOAT_SHADOW_BINARY = FLOAT_SHADOW_ARITH.merge(FLOAT_SHADOW_CMP).freeze
  # Sends whose result is usually a Float: evidence for float_shadow_evidenced, never a proof.
  FLOAT_SHADOW_SOURCES = Set['to_f', 'fdiv', 'sqrt', 'sin', 'cos', 'tan', 'atan2', 'hypot', 'log', 'exp', '**'].freeze
  # Each reads its one register operand only (vm.c).
  FLOAT_SHADOW_STORES = Set[:SETIV, :SETGV, :SETSV, :SETCV, :SETCONST, :SETUPVAR].freeze

  # sites: placed writers; inputs: {instruction index => Set of the operand registers that may hold the marker};
  # movers: MOVE indices whose source may hold it; regs: every register that may; deps: {index => sites it needs}.
  FloatShadowPlan = Struct.new(:sites, :inputs, :movers, :regs, :deps, keyword_init: true)

  def float_shadow_enabled?
    ENV['BC2CPP_FLOAT_SHADOW'] != '0'
  end

  def float_shadow_report?
    ENV['BC2CPP_FLOAT_SHADOW_REPORT'] == '1'
  end

  # The plan for +irep+ without the sites in +dropped+, or nil.
  def float_shadow_plan(irep, dropped = Set.new)
    return nil unless float_shadow_enabled?

    prog = BytecodeIR.for(irep)
    return nil unless prog.resolved? && prog.handlers_resolved?

    candidates = prog.instructions.filter_map do |ins|
      ins.index if !dropped.include?(ins.index) && float_shadow_writer?(irep, ins.source)
    end
    candidates = float_shadow_evidenced(irep, prog, candidates)
    return nil if candidates.empty?

    params = stack_tuple_params(irep)
    reads = prog.instructions.map do |ins|
      insn = ins.source
      if insn.op == :MOVE then [insn.regs[1].to_i]
      elsif EscapeAnalysis::CLOSURE_OPS.include?(insn.op) then [] # its reads of locals are the closures check's
      elsif FLOAT_SHADOW_STORES.include?(insn.op) && insn.reg_operand then [insn.reg_operand.to_i]
      else stack_tuple_reads(insn, params)
      end
    end
    unmodelled = reads.index(:all)
    return float_shadow_refuse(irep, "unmodelled #{prog.source_at(unmodelled).op}") if unmodelled

    sites = candidates.to_set
    reached = Hash.new { |h, k| h[k] = Set.new } # site => registers its value may be in
    uses = [] # [reader index, register, sites reaching it]
    prog.instructions.each do |ins|
      reads[ins.index].uniq.each do |reg|
        prods = BytecodeIR.producers(irep, ins.index, reg, through_handlers: true)
        if prods.nil?
          # Unknown producers: any site may reach this read.
          uses << [ins.index, reg, sites.dup]
          next
        end
        hit = prods.filter_map { |p| p.index if !p.entry? && sites.include?(p.index) }.to_set
        uses << [ins.index, reg, hit] unless hit.empty?
      end
    end
    candidates.each { |w| reached[w] << prog.source_at(w).reg.to_i }
    uses.each do |j, reg, hit|
      insn = prog.source_at(j)
      hit.each do |w|
        reached[w] << reg
        reached[w] << insn.regs[0].to_i if insn.op == :MOVE
        sites.delete(w) unless float_shadow_aware?(insn, reg)
      end
    end
    closures = !EscapeAnalysis.op_sites(irep, EscapeAnalysis::CLOSURE_OP_LIST).empty?
    sites.reject! { |w| reached[w].include?(0) || (closures && reached[w].any? { |r| r < irep.nlocals }) }
    return float_shadow_refuse(irep, :no_site) if sites.empty?

    inputs = Hash.new { |h, k| h[k] = Set.new }
    movers = Set.new
    deps = Hash.new { |h, k| h[k] = Set.new }
    sites.each { |w| deps[w] << w }
    uses.each do |j, reg, hit|
      live = hit & sites
      next if live.empty?

      prog.source_at(j).op == :MOVE ? movers << j : inputs[j] << reg
      deps[j].merge(live)
    end
    regs = sites.flat_map { |w| reached[w].to_a }.to_set
    FloatShadowPlan.new(sites: sites, inputs: inputs.to_h, movers: movers, regs: regs, deps: deps.to_h)
  end

  # Runs the block (the method's compile) under the plan; a planned instruction that was not placed drops the sites it
  # needs and the method compiles again, until every planned instruction is placed or no site is left.
  def float_shadow_compile_method(label)
    irep = @ireps.fetch(label)
    dropped = Set.new
    loop do
      plan = float_shadow_plan(irep, dropped)
      return yield unless plan

      warn "bc2cpp float shadow #{float_shadow_where(irep)}: #{plan.sites.sort}" if float_shadow_report?
      state = { label: label, plan: plan, hooked: Set.new, missed: Set.new }
      saved = @float_shadow_state
      @float_shadow_state = state
      text = begin
        yield
      ensure
        @float_shadow_state = saved
      end
      missed = state[:missed] | (plan.deps.keys.to_set - state[:hooked])
      return text if missed.empty?

      lost = missed.flat_map { |j| plan.deps.fetch(j, Set.new).to_a }.to_set
      warn "bc2cpp float shadow #{float_shadow_where(irep)}: not placed at #{missed.sort}, dropping #{lost.sort}" if float_shadow_report?
      dropped.merge(lost)
    end
  end

  # The frame-local values of the registers that may hold the marker.
  def float_shadow_declarations(irep)
    state = @float_shadow_state
    return '' unless state && state[:label] == irep.label

    names = state[:plan].regs.sort.map { |r| "#{float_shadow_name(r)} = 0" }
    "#ifndef MRB_NO_FLOAT\n  mrb_float #{names.join(', ')};\n#endif\n"
  end

  # Called from the method's instruction loop, as stack_tuple_visit.
  def float_shadow_visit(irep, idx, bypassed)
    state = @float_shadow_state
    return unless bypassed && state && state[:label] == irep.label

    state[:missed] << idx if state[:plan].deps.key?(idx)
  end

  # The text of instruction +idx+ under the plan, from +text+ (what every other wrapper emitted for it).
  def float_shadow_insn(insn, irep, owner_def, idx, reg_offset, text)
    state = @float_shadow_state
    return text unless state && idx && irep && state[:label] == irep.label

    plan = state[:plan]
    return text unless plan.deps.key?(idx)

    placed = (reg_offset.zero? && !@resumable && text.is_a?(String) &&
              float_shadow_text(insn, irep, owner_def, idx, plan, text))
    unless placed
      warn "bc2cpp float shadow #{float_shadow_where(irep)}: #{insn.op} at #{idx} not in shape (offset #{reg_offset})" if float_shadow_report?
      state[:missed] << idx
      return text
    end
    state[:hooked] << idx
    placed
  end

  private

  def float_shadow_name(reg)
    "bc2cpp_f#{reg}"
  end

  def float_shadow_refuse(irep, reason)
    warn "bc2cpp float shadow refused at #{float_shadow_where(irep)}: #{reason}" if float_shadow_report?
    nil
  end

  def float_shadow_where(irep)
    d = @owner_of && @owner_of[irep.label]
    d ? "#{d.owner}##{d.name}" : irep.label.to_s
  end

  def float_shadow_writer?(irep, insn)
    return true if FLOAT_SHADOW_ARITH.key?(insn.op) || FLOAT_SHADOW_IMM.include?(insn.op)

    float_shadow_literal?(irep, insn)
  end

  def float_shadow_literal?(irep, insn)
    return false unless insn.op == :LOADL

    entry = irep.pool[insn.pool_index.to_i]
    entry.is_a?(Hash) && entry[:type] == :float
  end

  # The candidates in a Float-touching expression: the arithmetic ops and compares, joined where one reads another's
  # result, whose connected part has an operand the class flow says may be a Float, a Float literal or a
  # Float-returning send. A placed site costs code at each of its readers, so an Integer-only expression is left as it
  # was. Profitability only: the plan is sound for any subset.
  def float_shadow_evidenced(irep, prog, candidates)
    float_bit = NumericFlow.class_bits('Float').keys.first
    seeds = candidates.reject { |w| float_shadow_operands(prog.source_at(w)) }.to_set
    edges = Hash.new { |h, k| h[k] = [] }
    prog.instructions.each do |ins|
      operands = float_shadow_operands(ins.source)
      next unless operands

      operands.each do |r|
        mask = exact_flow_mask(irep, ins.index, r)
        seeds << ins.index if mask.is_a?(Integer) && mask.anybits?(float_bit)
        (BytecodeIR.producers(irep, ins.index, r, through_handlers: true) || []).each do |p|
          next if p.entry?

          if float_shadow_literal?(irep, p.insn) ||
             (BytecodeIR::Ops::SEND.include?(p.insn.op) && FLOAT_SHADOW_SOURCES.include?(p.insn.sym))
            seeds << ins.index
          end
          edges[ins.index] << p.index
          edges[p.index] << ins.index
        end
      end
    end
    floaty = Set.new
    work = seeds.to_a
    until work.empty?
      j = work.pop
      next if floaty.include?(j)

      floaty << j
      work.concat(edges[j])
    end
    candidates.select { |w| floaty.include?(w) }
  end

  # The operand registers of an arithmetic op or compare, nil for any other instruction.
  def float_shadow_operands(insn)
    lead = insn.reg.to_i
    return [lead] if FLOAT_SHADOW_IMM.include?(insn.op)

    FLOAT_SHADOW_BINARY.key?(insn.op) ? [lead, lead + 1] : nil
  end

  # Whether +insn+ reading +reg+ is a reader the plan rewrites.
  def float_shadow_aware?(insn, reg)
    lead = insn.reg.to_i
    return insn.regs[1].to_i == reg if insn.op == :MOVE
    return reg == lead if FLOAT_SHADOW_IMM.include?(insn.op)

    FLOAT_SHADOW_BINARY.key?(insn.op) && [lead, lead + 1].include?(reg)
  end

  def float_shadow_text(insn, irep, owner_def, idx, plan, text)
    lead = insn.reg.to_i
    site = plan.sites.include?(idx)
    case insn.op
    when :MOVE
      return nil unless text.match?(/\A  r#{lead} = r#{insn.regs[1].to_i};\n\z/)

      "#{text}#ifndef MRB_NO_FLOAT\n  #{float_shadow_name(lead)} = #{float_shadow_name(insn.regs[1].to_i)};\n#endif\n"
    when :LOADL
      m = /\A#ifndef MRB_NO_FLOAT\n  r#{lead} = mrb_float_value\(M, ([^;\n]+)\);\n#else\n/.match(text)
      return nil unless m && site

      text.sub(m[0]) do
        "#ifndef MRB_NO_FLOAT\n  // FLOAT_SHADOW: the literal stays unboxed\n  " \
          "#{float_shadow_name(lead)} = #{m[1]}; r#{lead} = mrb_undef_value();\n#else\n"
      end
    else
      float_shadow_op_text(insn, irep, owner_def, plan, idx, site, text)
    end
  end

  # The pre-arm for an arithmetic op or compare: the Float arm on the (possibly unboxed) operands, else the boxed
  # operands and the instruction's own text.
  def float_shadow_op_text(insn, _irep, owner_def, plan, idx, site, text)
    # A label inside the text could be entered by a jump that skips the pre-arm.
    return nil if text.match?(/^\s*[A-Za-z_]\w*:/)

    lead = insn.reg.to_i
    marked = plan.inputs.fetch(idx, Set.new)
    imm = FLOAT_SHADOW_IMM.include?(insn.op)
    operands = imm ? [lead] : [lead, lead + 1]
    return nil unless (marked - operands).empty?

    mask = operands.each_with_index.sum { |r, k| marked.include?(r) ? 1 << k : 0 }
    value = ->(r) { marked.include?(r) ? float_shadow_name(r) : '0' }
    call = if imm
             step = BytecodeIR::OperandModel.imm_operand(insn)
             return nil unless step

             "bc2cpp_flo_imm(#{mask}, r#{lead}, #{value.call(lead)}, #{insn.op == :ADDI ? '' : '-'}#{step}, &bc2cpp_fo)"
           else
             "bc2cpp_flo_bin(#{FLOAT_SHADOW_BINARY.fetch(insn.op)}, #{mask}, r#{lead}, #{value.call(lead)}, " \
               "r#{lead + 1}, #{value.call(lead + 1)}, &bc2cpp_fo)"
           end
    out = if FLOAT_SHADOW_CMP.key?(insn.op)
            "r#{lead} = mrb_bool_value(bc2cpp_fk == 2);"
          elsif site
            "#{float_shadow_name(lead)} = bc2cpp_fo; r#{lead} = mrb_undef_value();"
          else
            "r#{lead} = mrb_float_value(M, bc2cpp_fo);"
          end
    boxes = operands.select { |r| marked.include?(r) }
                    .map { |r| "    r#{r} = bc2cpp_flo_box(M, r#{r}, #{float_shadow_name(r)});\n" }.join
    inner = cold_compact(insn, text, owner_def)
    "#ifndef MRB_NO_FLOAT\n  { mrb_float bc2cpp_fo; int bc2cpp_fk;\n" \
      "  // FLOAT_SHADOW: #{site ? 'the result stays unboxed' : 'reads unboxed operands'}\n" \
      "  if ((bc2cpp_fk = #{call})) {\n    #{out}\n  } else {\n#{boxes}#endif\n" \
      "#{inner}" \
      "#ifndef MRB_NO_FLOAT\n  }\n  }\n#endif\n"
  end
end

# Prepended to CodeGen: compile_method runs under a plan and retries without the sites that were not placed.
module FloatShadowCompileMethod
  def compile_method(label)
    float_shadow_compile_method(label) { super(label) }
  end
end

# Prepended to CodeGen, outermost: wraps the text every other wrapper settled on.
module FloatShadowCompileInsn
  def compile_insn(insn, irep, owner_def, idx = nil, reg_offset = 0)
    float_shadow_insn(insn, irep, owner_def, idx, reg_offset, super)
  end
end

CodeGen.prepend(FloatShadowCompileMethod)
CodeGen.prepend(FloatShadowCompileInsn)
