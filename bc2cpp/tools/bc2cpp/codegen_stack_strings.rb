# frozen_string_literal: true

require 'set'
require_relative 'bytecode_ir'
require_relative 'escape_analysis'

# STACK_STRINGS: a String literal (OP_STRING) that never leaves its frame and is only read is a frame-local String
# (Bc2cppStackStr, red) over the literal's static bytes, not a heap object. mruby's own str_new makes the same
# MRB_STR_NOFREE String when the bytes are read-only data (src/string.c), so contents, flags and sharing behave alike.
#
# A site is placed only when all of these hold (refusal is always the answer when unsure):
#   escape    the ESCAPE_ANALYSIS verdict for the creation is non-escaping (no callee keeps it, nothing stores it)
#   readers   every instruction that reads a register which may hold it is a MOVE, a branch test, or a send that
#             passes it as a positional argument to a name in STACK_STRING_READERS whose every definition is an
#             audited native (stack_string_reader_ok?). No receiver call: a String method could mutate it, and a
#             mutated NOFREE String takes a malloc'd buffer that a frame-local object never frees.
#   closures  no closure of the frame reads (GETUPVAR) a register that may hold it
#   params    no parameter or block register may hold it (ARGARY / zsuper read those without naming them)
# The storage is reused when the instruction runs again; it is rewritten with the same bytes and flags, and no reader
# can tell two runs apart (only audited natives see it, and none compares identity).
#
# The planned STRING is placed by StackStringCompileInsn (outermost). A planned instruction a path bypasses
# (suppressed, glued, behind a guarded prefix, in a resumable or shifted body) or whose text is not the plain pool
# string makes the method compile again without that site, so no use of the storage is emitted without its declaration.
class CodeGen
  # Natives that read a String argument's bytes and keep, mutate and share none of it, by position. The registrations
  # must be exactly NATIVE_ARG_OK's audited files for the name (see stack_string_reader_ok?).
  #   section  profiler.cxx (real and WIO stub): "S&", then mrb_string_value_cstr, which writes only when the bytes
  #            lack a NUL terminator (a C literal has one) and otherwise raises on an embedded NUL
  #   pack / unpack  pack.c prepare_tmpl: "S" into a stack struct, then RSTRING_PTR/LEN reads; errors format copies
  STACK_STRING_READERS = { 'section' => [0], 'pack' => [0], 'unpack' => [0] }.freeze
  STACK_STRING_TESTS = Set[:JMPIF, :JMPNOT, :JMPNIL].freeze
  # [irep label, STRING address] of every site placed in this run, for the escape report's `today` column.
  STACK_STRINGS_PLACED = Set.new

  def stack_strings_enabled?
    ENV['BC2CPP_STACK_STRINGS'] != '0'
  end

  # The plan for +irep+: {STRING index => pool literal}, empty when nothing is placed or the analysis is off.
  def stack_string_plan(irep)
    return {} unless stack_strings_enabled?

    analyzer = escape_analyzer
    return {} unless analyzer

    prog = BytecodeIR.for(irep)
    creations = prog.instructions.select { |ins| ins.op == :STRING }
    return {} if creations.empty? || !prog.resolved? || !prog.handlers_resolved?

    params = stack_tuple_params(irep)
    upvar_reads = stack_string_upvar_reads(irep)
    plan = {}
    creations.each do |ins|
      lit = stack_string_site(irep, prog, ins, analyzer, params, upvar_reads)
      plan[ins.index] = lit if lit
    end
    plan
  end

  # Runs the block (the method's compile) under the plan; a site that was not placed is dropped and the method
  # compiles again, until every planned site is placed or none is left.
  def stack_string_compile_method(label)
    irep = @ireps.fetch(label)
    plan = stack_strings_enabled? ? stack_string_plan(irep) : {}
    loop do
      warn "bc2cpp stack strings #{label}: #{plan.keys}" if ENV['BC2CPP_STACK_STRINGS_REPORT'] == '1' && !plan.empty?
      return yield if plan.empty?

      state = { label: label, plan: plan, hooked: Set.new, bypassed: Set.new }
      saved = @stack_string_state
      @stack_string_state = state
      text = begin
        yield
      ensure
        @stack_string_state = saved
      end
      missed = plan.keys.reject { |idx| state[:hooked].include?(idx) } | state[:bypassed].to_a
      if missed.empty?
        prog = BytecodeIR.for(irep)
        plan.each_key { |idx| STACK_STRINGS_PLACED << [label, prog.source_at(idx).addr] }
        return text
      end

      warn "bc2cpp stack strings #{label}: not placed #{missed.sort}" if ENV['BC2CPP_STACK_STRINGS_REPORT'] == '1'
      plan = plan.reject { |idx, _| missed.include?(idx) }
    end
  end

  # The declarations of the placed Strings of the method body +irep+ (empty without a plan).
  def stack_string_declarations(irep)
    state = @stack_string_state
    return '' unless state && state[:label] == irep.label

    state[:plan].keys.map { |idx| "  Bc2cppStackStr #{stack_string_name(idx)};\n" }.join
  end

  # Called from the method's instruction loop, as stack_tuple_visit.
  def stack_string_visit(irep, idx, bypassed)
    state = @stack_string_state
    return unless bypassed && state && state[:label] == irep.label && state[:plan].key?(idx)

    state[:bypassed] << idx
  end

  # The text of the planned STRING +idx+: the plain pool string (+text+, what the other wrappers emitted) with the
  # frame-local String in its place. Anything else is left as it is and the site is not placed.
  def stack_string_insn(irep, idx, reg_offset, text)
    state = @stack_string_state
    return text unless state && idx && irep && state[:label] == irep.label && state[:plan].key?(idx)
    return text if reg_offset != 0 || @resumable || !text.is_a?(String)

    lead = reg_int(BytecodeIR.for(irep).source_at(idx).reg)
    lit = c_string_literal(state[:plan][idx])
    return text unless text == "  #{RegName[lead]} = bc2cpp_pool_str(M, #{lit});\n"

    state[:hooked] << idx
    "  #{RegName[lead]} = bc2cpp_stack_str(M, #{stack_string_name(idx)}, #{lit});\n"
  end

  private

  def stack_string_name(idx)
    "bc2cpp_str#{idx}"
  end

  def stack_string_refuse(where, reason)
    warn "bc2cpp stack string refused at #{where}: #{reason}" if ENV['BC2CPP_STACK_STRINGS_REPORT'] == '1'
    nil
  end

  # The pool literal of the STRING +ins+ when the site is placed, else nil.
  def stack_string_site(irep, prog, ins, analyzer, params, upvar_reads)
    where = "#{irep.label}##{ins.index}"
    insn = ins.source
    return nil if insn.frozen_literal

    lit = irep.pool.fetch(insn.pool_index.to_i)
    return stack_string_refuse(where, :not_pool_string) unless lit.is_a?(String)

    lead = reg_int(insn.reg)
    return stack_string_refuse(where, :no_lead) unless lead

    verdict = analyzer.creation(irep, ins.index, points: true)
    return stack_string_refuse(where, "escapes (#{verdict.reason})") if verdict.escapes?
    return stack_string_refuse(where, :no_points) unless verdict.holding

    tracked = verdict.tracked.map { |reg| reg.to_i }.to_set << lead
    return stack_string_refuse(where, :parameter_register) if tracked.any? { |reg| reg.between?(1, params + 1) }
    return stack_string_refuse(where, :read_by_closure) if tracked.intersect?(upvar_reads)

    prog.instructions.each do |other|
      j = other.index
      next if j == ins.index

      held = verdict.holding_at(j).map { |reg| reg.to_i }.to_set
      next if held.empty?

      reads = stack_string_reads(other.source, params)
      reads = reads == :all ? held.to_a : reads.select { |reg| held.include?(reg) }
      reads.each do |reg|
        why = stack_string_reader_refusal(analyzer, irep, j, other.source, reg)
        return stack_string_refuse(where, "#{why} at #{j}") if why
      end
    end
    lit
  end

  # A superset of the registers +insn+ reads: stack_tuple_reads, with a MOVE's source, a store's value and none for a
  # closure (it reads the frame by GETUPVAR, see stack_string_upvar_reads).
  def stack_string_reads(insn, params)
    return [reg_int(BytecodeIR::OperandModel.move(insn).src)] if insn.op == :MOVE
    return [] if EscapeAnalysis::CLOSURE_OPS.include?(insn.op)
    # A store names its value register only (SETIV's leading operand is the name).
    if STACK_TUPLE_STORE_OPS.include?(insn.op)
      value = reg_int(insn.reg_operand)
      return value ? [value] : :all
    end

    stack_tuple_reads(insn, params)
  end

  # nil when the instruction +insn+ only reads the String in +reg+ (see STACK_STRINGS), else why not.
  def stack_string_reader_refusal(analyzer, irep, index, insn, reg)
    op = insn.op
    return nil if op == :MOVE
    return nil if STACK_STRING_TESTS.include?(op) && reg_int(insn.reg) == reg
    return :"read_by_#{op}" unless BytecodeIR::Ops::SEND.include?(op)
    return :splat_or_keyword if insn.positional_splat? || insn.keyword_arguments? || insn.keyword_splat?

    lead = reg_int(insn.reg)
    argc = insn.argc_operand.nil? ? 0 : insn.argc.to_i
    k = reg - lead - 1
    return :"not_an_argument_of_#{insn.sym}" unless k.between?(0, argc - 1)
    recv = BytecodeIR::Ops::SELF_SEND_FAMILY.include?(op) ? nil : lead
    return :"reader_#{insn.sym}" unless stack_string_reader_ok?(analyzer, irep, index, recv, insn.sym, k)

    nil
  end

  # Every definition the call can reach is a native (by the receiver's exact classes when the class flow proves them,
  # else every definition of the name), every native registration of the name sits in the files NATIVE_ARG_OK audits
  # for it, and STACK_STRING_READERS says that native only reads argument +k+. An empty list is the native alone.
  def stack_string_reader_ok?(analyzer, irep, index, recv, name, k)
    return false unless STACK_STRING_READERS.fetch(name, []).include?(k)

    world = analyzer.world
    entry = EscapeAnalysis::NATIVE_ARG_OK[name]
    return false unless entry && world.native_name?(name) && world.native_files_audited?(name, entry[:files])

    klasses = recv && analyzer.receiver_classes&.call(irep, index, recv)
    list = klasses ? world.defs_for(name, klasses, true) : world.defs_named(name)
    !list.nil? && list.all? { |d| d.owner == '<native>' && d.irep.nil? && !d.installer }
  end

  # The registers of +irep+ a closure nested in it reads by GETUPVAR (at any depth, resolved to this frame).
  def stack_string_upvar_reads(irep)
    regs = Set.new
    BytecodeIR::Tree.children(irep, @ireps, EscapeAnalysis::CLOSURE_OPS).each do |_, child|
      BytecodeIR::Tree.each_subtree(child, @ireps, EscapeAnalysis::CLOSURE_OPS) do |node, depth, _|
        BytecodeIR.for(node).each_with_op(:GETUPVAR) do |insn, _|
          idx, level = insn.upvar_ref
          regs << idx.to_i if level == depth
        end
      end
    end
    regs
  end
end

# Prepended to CodeGen: compile_method runs under a plan and drops the sites it could not place.
module StackStringCompileMethod
  def compile_method(label)
    stack_string_compile_method(label) { super(label) }
  end
end

# Prepended to CodeGen, last: outermost compile_insn, so it sees the text every other wrapper settled on.
module StackStringCompileInsn
  def compile_insn(insn, irep, owner_def, idx = nil, reg_offset = 0)
    stack_string_insn(irep, idx, reg_offset, super(insn, irep, owner_def, idx, reg_offset))
  end
end

CodeGen.prepend(StackStringCompileMethod)
CodeGen.prepend(StackStringCompileInsn)
