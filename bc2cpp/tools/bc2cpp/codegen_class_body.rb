# frozen_string_literal: true

# CLASS_BODY_EMIT (prototype): one C++ function per class body, in place of OP_EXEC. A CLASS or MODULE and the EXEC that
# follows it are one unit: the class is created the way the VM creates it (vm.c OP_CLASS / OP_MODULE), then the child
# body's compiled function runs. Restricted: a body compiles only when each opcode is one compile_insn already emits,
# plus SETCONST, a CLASS/MODULE unit whose child compiles, and a TDEF of an omitted key; anything else refuses the whole
# body and names the opcodes.

class CodeGen
  CLASS_BODY_OPS = (%i[NOP STOP RETURN RETNIL LOADNIL LOADSELF LOADTRUE LOADFALSE LOADL LOADSYM STRING LOADI__1 LOADI_0
                       LOADI_1 LOADI_2 LOADI_3 LOADI_4 LOADI_5 LOADI_6 LOADI_7 LOADI8 LOADI16 LOADI32 SETCONST
                       SEND0 SSEND0 SSEND GETCONST ARRAY HASH ADD ADDI ADDILV SUB SUBI SUBILV MUL DIV GETMCNST SETIV SYMBOL EQ ARYCAT MOVE GETIDX RANGE_INC]).freeze

  # The mruby entry points a class unit calls (vm.c; the same declarations load_compile.rb's PRELUDE makes).
  CLASS_UNIT_DECLS = <<~CPP
    extern "C" struct RClass* mrb_vm_define_class(mrb_state*, mrb_value, mrb_value, mrb_sym);
    extern "C" struct RClass* mrb_vm_define_module(mrb_state*, mrb_value, mrb_sym);
  CPP

  # [C++ text, nil] for a compiled body (its children's functions first), or [nil, refusing opcodes]. `owner` is the
  # body's class path. A TDEF of an omitted key (unregistered_keys) is its register write alone.
  def compile_class_body(irep, owner)
    program = BytecodeIR.for(irep)
    omitted = unregistered_keys
    bodies = BytecodeIR.class_bodies(irep, :CLASS, :MODULE, :SCLASS)
    paired_exec = bodies.keys.to_set { |idx| idx + 1 }
    unsupported = program.each_source.reject do |insn, idx|
      omitted_def?(insn, owner, omitted) || (%i[CLASS MODULE SCLASS].include?(insn.op) && bodies.key?(idx)) ||
        (insn.op == :EXEC && paired_exec.include?(idx))
    end.map { |insn, _| insn.op }.uniq - CLASS_BODY_OPS
    return [nil, unsupported] unless unsupported.empty?
    # SETCONST writes to the body's target class; in a singleton body that is the singleton class, which the owner
    # name does not name, so such a body is refused until the emitter names it.
    if owner.end_with?('.singleton') && program.each_source.any? { |insn, _| insn.op == :SETCONST }
      return [nil, [:SETCONST_IN_SINGLETON]]
    end

    texts = +''
    owner_def = Struct.new(:owner, :core, :irep).new(owner, false, irep)
    lines = +''
    program.each_source do |insn, idx|
      next if paired_exec.include?(idx) && insn.op == :EXEC

      if bodies.key?(idx)
        child_path = child_body_path(program, irep, idx, owner)
        return [nil, [:UNRESOLVED_CLASS_PATH]] unless child_path

        child_code, child_refused = compile_class_body(@ireps.fetch(bodies.fetch(idx)), child_path)
        return [nil, child_refused] unless child_code

        texts << child_code
        lines << class_unit_define(insn)
        lines << "  (void)bc2cpp_class_body_#{sanitize(child_path)}(M);\n"
      elsif insn.op == :TDEF && omitted_def?(insn, owner, omitted)
        lines << "  // #{owner}##{insn.sym} omitted: statically dispatched only (no registration)\n"
        lines << "  r#{insn.reg} = mrb_symbol_value(mrb_intern_cstr(M, \"#{insn.sym}\"));\n"
      else
        lines << compile_insn(insn, irep, owner_def, idx)
      end
    end
    fn = "bc2cpp_class_body_#{sanitize(owner)}"
    code = +"#{CLASS_UNIT_DECLS}static mrb_value #{fn}(mrb_state* M) {\n"
    code << "  mrb_value self = #{body_self_expr(owner)};\n"
    code << emit_register_initializers(irep.nregs, [])
    code << lines
    code << "}\n"
    [texts + code, nil]
  end

  # The qualified name of a class unit's child body. A singleton body (`class << self`) is the body's own owner with
  # `.singleton` appended, and only when its SCLASS takes self from the LOADSELF just before it; any other singleton
  # target refuses the body.
  def child_body_path(program, irep, idx, owner)
    insn = program.source_at(idx)
    if insn.op == :SCLASS
      previous = program.source_at(idx - 1)
      return nil unless previous&.op == :LOADSELF && previous.reg == insn.reg

      return "#{owner}.singleton"
    end
    BytecodeIR.class_body_path(irep, idx, owner)
  end

  # The value a body's function starts with: its class, or the singleton class of its base class for a `.singleton` owner.
  def body_self_expr(owner)
    if owner.end_with?('.singleton')
      "mrb_singleton_class(M, mrb_obj_value(#{owner_class_ptr_expr(owner.delete_suffix('.singleton'))}))"
    else
      "mrb_obj_value(#{owner_class_ptr_expr(owner)})"
    end
  end

  # The class or module a CLASS/MODULE opcode creates in its base register, as vm.c's OP_CLASS and OP_MODULE do; an
  # SCLASS turns its register into the singleton class (vm.c OP_SCLASS).
  def class_unit_define(insn)
    reg = insn.reg
    if insn.op == :SCLASS
      "  r#{reg} = mrb_singleton_class(M, r#{reg});\n"
    elsif insn.op == :CLASS
      "  r#{reg} = mrb_obj_value(mrb_vm_define_class(M, r#{reg}, r#{reg + 1}, mrb_intern_cstr(M, \"#{insn.sym}\")));\n"
    else
      "  r#{reg} = mrb_obj_value(mrb_vm_define_module(M, r#{reg}, mrb_intern_cstr(M, \"#{insn.sym}\")));\n"
    end
  end

  def omitted_def?(insn, owner, omitted)
    insn.op == :TDEF && omitted.include?("#{owner}##{insn.sym}")
  end
end
