# frozen_string_literal: true

require 'set'
require_relative 'bytecode_ir'

# CALL_INLINE: a statically bound call to a small leaf method becomes the callee's own instructions, compiled into the
# caller's function.
#
# The call is already decided before this runs. compile_send binds a send to one definition only behind a proof (a
# monomorphic name, an exact receiver class, a runtime class guard with a by-name fallback) and writes
# `rD = Owner_name_impl(M, recv, args...);`. This pass leaves that decision alone and replaces just that line, so
# every guard, fallback and proof stays where it was. Inlining adds no assumption about the receiver.
#
# The callee qualifies when its whole body is straight-line or branching register code: no block, no rescue or
# ensure, no constant, no argument beyond the mandatory ones, at most INLINE_CALL_MAX_INSNS instructions, and a send
# only when the callee is not mruby's own Ruby (see INLINE_CALL_SEND_OPS). Its registers move to a fresh range in a
# nested scope (`r1000...`, never colliding with the caller's own or an inlined block's), the receiver and arguments
# are copied into R0..Rn, each RETURN becomes an assignment to the call's destination and a jump to the end, and
# every other instruction goes through compile_insn with the shifted registers, as an inlined block body does, so the
# arithmetic arms and their proofs are the ones the callee's own function uses.
#
# What it buys: no call, no argument copy through the C++ ABI, and the callee's branches and fixnum tests sit in the
# caller where the C++ compiler sees the constants. What it does not: it removes no allocation (the callee has none).
#
# BC2CPP_INLINE_CALLS=0 turns it off; BC2CPP_INLINE_REPORT=1 (or a file path) reports each inlined call.
INLINE_CALL_MAX_INSNS = 24
INLINE_CALL_REG_BASE = 1000

class CodeGen
  INLINE_CALL_OPS = Set[
    :NOP, :MOVE, :LOADNIL, :LOADTRUE, :LOADFALSE, :LOADSYM,
    :LOADI__1, :LOADI_0, :LOADI_1, :LOADI_2, :LOADI_3, :LOADI_4, :LOADI_5, :LOADI_6, :LOADI_7,
    :LOADI8, :LOADINEG, :LOADI16, :LOADI32,
    :ADD, :SUB, :MUL, :DIV, :LT, :LE, :GT, :GE, :EQ, :ADDI, :SUBI,
    :LOADSELF, :GETIV, :SETIV, :GETIDX, :GETIDX0, :SETIDX,
    :JMP, :JMPIF, :JMPNOT, :JMPNIL,
    :RETURN, :RETNIL, :RETTRUE, :RETFALSE, :RETSELF
  ].freeze
  # Sends are allowed in a callee that is not mruby's own Ruby (CallInline's second rule): a core body is compiled with
  # no closed-world proof and binds statically only to core definitions (compile_method), a state the caller's
  # function is not in.
  INLINE_CALL_SEND_OPS = Set[:SEND, :SEND0, :SSEND, :SSEND0].freeze
  INLINE_CALL_LINE = /^(?<ind>[ \t]*)r(?<dest>\d+) = (?<impl>[A-Za-z_][\w$]*_impl)\(M, (?<args>(?:self|r\d+)(?:, r\d+)*)\);[ \t]*$/

  def inline_calls_enabled?
    ENV['BC2CPP_INLINE_CALLS'] != '0'
  end

  # impl function name => the one definition that has it (nil when two do), over the compiled Ruby bodies.
  def inline_impl_defs
    @inline_impl_defs ||= begin
      map = {}
      @registry.each_value do |defs|
        defs.each do |d|
          next unless d.irep

          key = "#{cpp_name(d.owner, d.name)}_impl"
          map[key] = map.key?(key) ? nil : d
        end
      end
      map
    end
  end

  # The instructions of +d+'s body when it can be inlined, else nil. Memoized per definition.
  def inline_callee_insns(d)
    @inline_callee_cache ||= {}
    return @inline_callee_cache[d.irep] if @inline_callee_cache.key?(d.irep)

    @inline_callee_cache[d.irep] = compute_inline_callee_insns(d)
  end

  def compute_inline_callee_insns(d)
    irep = @ireps[d.irep]
    return nil unless irep && d.kind.nil? && d.installer.nil?
    return nil unless irep.reps.empty? && irep.catch_handlers.to_a.empty? && pure_mandatory_arity?(irep)

    insns = []
    BytecodeIR.for(irep).each_source { |insn, i| insns << [insn, i] }
    body = insns.reject { |insn, _| insn.op == :ENTER }
    return nil if body.empty? || body.size > INLINE_CALL_MAX_INSNS
    allowed = d.core ? INLINE_CALL_OPS : INLINE_CALL_OPS | INLINE_CALL_SEND_OPS
    return nil unless body.all? { |insn, _| allowed.include?(insn.op) }
    return nil unless body.any? { |insn, _| %i[RETURN RETNIL RETTRUE RETFALSE RETSELF].include?(insn.op) }

    body
  end

  # The text that stands for `rD = impl(M, recv, args);`, or nil when the call is not inlinable.
  def inline_call_text(dest, impl, arg_regs, indent)
    d = inline_impl_defs[impl]
    return nil unless d

    irep = @ireps[d.irep]
    body = inline_callee_insns(d)
    return nil unless body && arg_regs.size == mandatory_arity(irep) + 1 && irep.nregs >= arg_regs.size

    @inline_call_serial = (@inline_call_serial || 0) + 1
    serial = @inline_call_serial
    base = INLINE_CALL_REG_BASE
    prefix = "LINL#{serial}_"
    done = "#{prefix}end"
    targets = BytecodeIR.for(irep).branch_target_addrs
    out = String.new
    out << "#{indent}// CALL_INLINE #{d.owner}##{d.name} (#{body.size} insns)\n#{indent}{\n"
    # `self` is redeclared for the callee's own GETIV/SETIV text; its initializer must not name the new `self`.
    out << "#{indent}  mrb_value bc2cpp_irecv#{serial} = #{arg_regs.first};\n"
    out << "#{indent}  [[maybe_unused]] mrb_value self = bc2cpp_irecv#{serial};\n"
    (0...irep.nregs).each do |k|
      init = k.zero? ? 'self' : (k < arg_regs.size ? arg_regs[k] : 'mrb_nil_value()')
      out << "#{indent}  mrb_value r#{base + k} = #{init};\n"
    end
    body.each do |insn, i|
      out << "#{indent}  #{prefix}#{insn.addr.to_i}:;\n" if targets.include?(insn.addr)
      out << inline_call_insn(insn, irep, d, i, base, prefix, done, dest)
    end
    out << "#{indent}  #{done}:;\n#{indent}}\n"
    return nil if out.include?('#error')

    inline_call_report("#{d.owner}##{d.name}")
    out
  end

  # BC2CPP_INLINE_REPORT=1 prints each inlined call to stderr; any other value is a file the lines are appended to (a
  # build driver may swallow the generator's stderr).
  def inline_call_report(what)
    mode = ENV['BC2CPP_INLINE_REPORT']
    return if mode.nil? || mode.empty? || mode == '0'

    line = "bc2cpp CALL_INLINE: #{what}\n"
    mode == '1' ? warn(line) : File.open(mode, 'a') { |f| f.write(line) }
  end

  def inline_call_insn(insn, irep, d, idx, base, prefix, done, dest)
    case insn.op
    when :RETURN
      "    r#{dest} = r#{insn.reg.to_i + base};\n    goto #{done};\n"
    when :RETNIL
      "    r#{dest} = mrb_nil_value();\n    goto #{done};\n"
    when :RETTRUE
      "    r#{dest} = mrb_true_value();\n    goto #{done};\n"
    when :RETFALSE
      "    r#{dest} = mrb_false_value();\n    goto #{done};\n"
    when :RETSELF
      "    r#{dest} = r#{base};\n    goto #{done};\n"
    when :JMP
      "    goto #{prefix}#{insn.jmp_addr.to_i};\n"
    when :JMPNOT
      "    if (!mrb_test(r#{insn.reg.to_i + base})) goto #{prefix}#{insn.uint_operand.to_i};\n"
    when :JMPIF
      "    if (mrb_test(r#{insn.reg.to_i + base})) goto #{prefix}#{insn.uint_operand.to_i};\n"
    when :JMPNIL
      "    if (mrb_nil_p(r#{insn.reg.to_i + base})) goto #{prefix}#{insn.uint_operand.to_i};\n"
    else
      compile_insn(insn.shift_regs(base), irep, d, idx, base)
    end
  end
end

# Prepended to CodeGen: after the ordinary text of a SEND is made, its direct call line is replaced.
module CallInlineCompileInsn
  def compile_insn(insn, irep, owner_def, idx = nil, reg_offset = 0)
    text = super
    return text unless %i[SEND SEND0 SSEND SSEND0].include?(insn.op) && reg_offset.zero? && inline_calls_enabled? && !@resumable && !@rsm_variant
    return text unless text.is_a?(String) && text.include?('_impl(M, ')
    # A guarded expansion (COMPUTED_SEND_GUARDED, a switch over the argument count) is read back by the passes that
    # built it (SPLAT_SHARED checks its arms' text); its arms keep their calls.
    return text if text.include?('COMPUTED_SEND') || text.include?('switch (')

    lines = text.lines
    hits = lines.each_index.select { |i| lines[i].match?(CodeGen::INLINE_CALL_LINE) }
    return text unless hits.size == 1

    m = CodeGen::INLINE_CALL_LINE.match(lines[hits.first])
    inlined = inline_call_text(m[:dest], m[:impl], m[:args].split(', '), m[:ind])
    return text unless inlined

    lines[hits.first] = inlined
    lines.join
  end
end

CodeGen.prepend(CallInlineCompileInsn)
