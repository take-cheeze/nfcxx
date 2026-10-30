# frozen_string_literal: true

# CLASS_BODY_EMIT (prototype): one C++ function for a class body's bytecode, run once in place of OP_EXEC. Restricted:
# a body compiles only when every opcode is one compile_insn already emits, plus SETCONST, so a body with a def, a
# nested class or a DSL call is refused whole (the refusal names the opcodes), not partly compiled.

class CodeGen
  CLASS_BODY_OPS = (%i[NOP STOP RETURN RETNIL LOADNIL LOADSELF LOADTRUE LOADFALSE LOADL LOADSYM STRING LOADI__1 LOADI_0
                       LOADI_1 LOADI_2 LOADI_3 LOADI_4 LOADI_5 LOADI_6 LOADI_7 LOADI8 LOADI16 LOADI32 SETCONST]).freeze

  # [C++ text, nil] for a compiled body, or [nil, unsupported opcodes]. `owner` is the body's class path (Ruby name).
  def compile_class_body(irep, owner)
    program = BytecodeIR.for(irep)
    unsupported = program.each_source.map { |insn, _| insn.op }.uniq - CLASS_BODY_OPS
    return [nil, unsupported] unless unsupported.empty?

    owner_def = Struct.new(:owner, :core).new(owner, false)
    lines = +''
    program.each_source { |insn, idx| lines << compile_insn(insn, irep, owner_def, idx) }
    fn = "bc2cpp_class_body_#{sanitize(owner)}"
    code = +"static mrb_value #{fn}(mrb_state* M) {\n"
    code << "  mrb_value self = mrb_obj_value(#{owner_class_ptr_expr(owner)});\n"
    code << emit_register_initializers(irep.nregs, [])
    code << lines
    code << "}\n"
    [code, nil]
  end
end
