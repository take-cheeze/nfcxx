# frozen_string_literal: true

require 'set'
require_relative 'bytecode_ir'

# STRING_EQ_LITERAL: `x == "literal"` (and `x != "literal"`) compares against the literal's bytes when x is a plain String, and builds the
# literal only on the other path. Without it the STRING instruction allocates a new String on every evaluation (the
# literal is mutable), and `String#==` then compares it with x and drops it.
#
# A (STRING, EQ) pair is rewritten when all of these hold; any doubt keeps both instructions as they are:
#   shape       the EQ follows the STRING, compares R(a) with R(a+1) where R(a+1) is the STRING's register, is reached
#               only from the STRING, and the literal is a plain (not frozen) one without a NUL byte (the allocation
#               takes its length from strlen, so a NUL would make the two paths disagree)
#   dead        no other instruction reads that register with the STRING as a reaching definition, so the literal is
#               never needed once the comparison is done
#   String#==   no Ruby definition or prepend shadows String#== (builtin_class_send_safe?), and for `!=` String#!= either
#   receiver    the fast path runs only when R(a) is exactly a String (its class is M->string_class, not a subclass or
#               a singleton, which could define its own ==); any other value takes the original instructions
#
# The fast path stores the Boolean in R(a) and leaves the literal's register untouched, which the dead check makes
# invisible. The other path assigns the literal and then runs the EQ's own text. BC2CPP_STRING_EQ_LITERAL=0 turns it off.
class CodeGen
  def string_eq_literal_enabled?
    ENV['BC2CPP_STRING_EQ_LITERAL'] != '0'
  end

  # Called by compile_method after every other pass: replaces the pairs it can with one glued unit at the STRING's
  # address and suppresses the EQ. +blocked+ answers whether an address is claimed by another emitter.
  def string_eq_literal_pass(irep, owner_def, suppressed, glue_at, targets, blocked)
    return unless string_eq_literal_enabled? && !@resumable
    return unless builtin_class_send_safe?('==', ['String'])

    ne_safe = builtin_class_send_safe?('!=', ['String'])
    prog = BytecodeIR.for(irep)
    params = stack_tuple_params(irep)
    prog.each_source do |insn, idx|
      next unless insn.op == :STRING

      eq = idx + 1 < prog.size ? prog.source_at(idx + 1) : nil
      negate = string_eq_negated(eq)
      next if negate.nil? || (negate && !ne_safe)
      next if blocked.call(insn.addr) || blocked.call(eq.addr) || targets.include?(eq.addr)

      literal = string_eq_literal_of(irep, insn)
      next unless literal

      s = reg_int(insn.reg)
      a = reg_int(eq.reg)
      next unless s && a && s == a + 1 && a != s
      next unless string_eq_only_predecessor?(prog, idx)
      next unless string_eq_literal_dead_after?(irep, prog, idx, s, params)

      fallback = compile_insn(eq, irep, owner_def, idx + 1)
      next if fallback.nil?

      suppressed << insn.addr << eq.addr
      glue_at[insn.addr] = string_eq_literal_text(a, s, literal, fallback, negate)
    end
  end

  private

  # false for `==` (EQ), true for `x != literal` (a SEND of != with one plain argument), nil for anything else.
  def string_eq_negated(insn)
    return nil unless insn
    return false if insn.op == :EQ
    return nil unless insn.op == :SEND && insn.sym == '!=' && insn.plain_fixed_argc? && insn.argc.to_i == 1 &&
                      !insn.keyword_arguments?

    true
  end

  # The literal's bytes when +insn+ is a plain, non-frozen STRING of a NUL-free pool string, else nil.
  def string_eq_literal_of(irep, insn)
    return nil if insn.frozen_literal && frozen_literals_enabled?

    entry = irep.pool.fetch(insn.pool_index.to_i)
    entry.is_a?(String) && !entry.include?("\0") ? entry : nil
  end

  # Is the instruction after +idx+ reached only from +idx+, normal or handler edges?
  def string_eq_only_predecessor?(prog, idx)
    target = idx + 1
    prog.instructions.none? do |ins|
      ins.index != idx && prog.successors_of(ins.index, include_handlers: true).include?(target)
    end && prog.successors_of(idx, include_handlers: true) == [target]
  end

  # No instruction other than the EQ reads register +s+ with the STRING at +idx+ as a reaching definition.
  def string_eq_literal_dead_after?(irep, prog, idx, s, params)
    prog.instructions.all? do |ins|
      j = ins.index
      next true if j == idx || j == idx + 1

      reads = string_eq_reads(ins.source, params)
      next true unless reads == :all || reads.include?(s)

      prods = BytecodeIR.producers(irep, j, s, through_handlers: true)
      next false if prods.nil? || prods.empty?

      prods.none? { |p| !p.entry? && p.index == idx }
    end
  end

  # The registers +insn+ may read, as stack_tuple_reads gives them, but a MOVE reads only its source: the operand
  # loads of the next comparison are MOVEs, which would otherwise look like reads of the previous literal.
  def string_eq_reads(insn, params)
    return [BytecodeIR::OperandModel.move(insn).src.to_i] if insn.op == :MOVE

    stack_tuple_reads(insn, params)
  end

  def string_eq_literal_text(a, s, literal, fallback, negate)
    lit = c_string_literal(literal)
    len = literal.bytesize
    equal = "RSTRING_LEN(bc2cpp_seq) == #{len} && memcmp(RSTRING_PTR(bc2cpp_seq), #{lit}, #{len}) == 0"
    value = negate ? "!(#{equal})" : equal
    head = [
      "  // STRING_EQ_LITERAL: r#{a} #{negate ? '!=' : '=='} \"literal\" compares the bytes of a plain String and builds no String for it\n",
      "  {\n",
      "    mrb_value bc2cpp_seq = r#{a};\n",
      "    if (mrb_string_p(bc2cpp_seq) && mrb_obj_ptr(bc2cpp_seq)->c == M->string_class) {\n",
      "      r#{a} = mrb_bool_value(#{value});\n",
      "    } else {\n",
      "      r#{s} = bc2cpp_pool_str(M, #{lit});\n"
    ]
    body = fallback.lines.map { |line| "  #{line}" }
    (head + body + ["    }\n", "  }\n"]).join
  end
end
