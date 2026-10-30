# frozen_string_literal: true

# CLASS_BODY_EMIT (prototype): one C++ function per class body, in place of OP_EXEC. A CLASS or MODULE and the EXEC that
# follows it are one unit: the class is created the way the VM creates it (vm.c OP_CLASS / OP_MODULE), then the child
# body's compiled function runs. Restricted: a body compiles only when each opcode is one compile_insn already emits,
# plus SETCONST, a CLASS/MODULE unit whose child compiles, and a TDEF of an omitted key; anything else refuses the whole
# body and names the opcodes.

class CodeGen
  # The build's compiled methods (compile_all's hashes), keyed by irep label: a body's TDEF and SDEF register the
  # entry the gem already emits for the method. Set before compile_top_class_units.
  attr_writer :compiled_methods

  # The sends (SEND, SEND0, SSEND, SSEND0) are out: a send in a body calls owner-call helpers that the gem emits only for
  # its compiled methods, so a body with one does not build (core_compiled_gen.cpp: `include` in Object). Restore them
  # once the helpers are emitted for the units.
  CLASS_BODY_OPS = (%i[NOP STOP RETURN RETNIL LOADNIL LOADSELF LOADTRUE LOADFALSE LOADL LOADSYM STRING LOADI__1 LOADI_0
                       LOADI_1 LOADI_2 LOADI_3 LOADI_4 LOADI_5 LOADI_6 LOADI_7 LOADI8 LOADI16 LOADI32 SETCONST
                       GETCONST ARRAY HASH ADD ADDI ADDILV SUB SUBI SUBILV MUL DIV GETMCNST SETIV SYMBOL EQ ARYCAT MOVE GETIDX RANGE_INC]).freeze

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
      %i[TDEF SDEF].include?(insn.op) || (%i[CLASS MODULE SCLASS].include?(insn.op) && bodies.key?(idx)) ||
        (insn.op == :EXEC && paired_exec.include?(idx))
    end.map { |insn, _| insn.op }.uniq - CLASS_BODY_OPS
    return [nil, unsupported] unless unsupported.empty?
    # SETCONST writes to the body's target class; in a singleton body that is the singleton class, which the owner
    # name does not name, so such a body is refused until the emitter names it.
    if owner.end_with?('.singleton') && program.each_source.any? { |insn, _| insn.op == :SETCONST }
      return [nil, [:SETCONST_IN_SINGLETON]]
    end

    texts = +''
    # A class body is not a method, so it has no name; the send paths that read one (super, module_super_target) are not
    # in CLASS_BODY_OPS, and lexical_module_function_self_target finds nothing under a nil name.
    owner_def = Struct.new(:owner, :core, :name, :irep).new(owner, false, nil, irep)
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
      elsif %i[TDEF SDEF].include?(insn.op)
        registration = class_body_registration(insn, irep, owner)
        return [nil, [insn.op]] unless registration

        lines << registration
        lines << "  r#{insn.reg} = mrb_symbol_value(mrb_intern_cstr(M, \"#{insn.sym}\"));\n"
      else
        lines << compile_insn(insn, irep, owner_def, idx)
      end
    end
    fn = "bc2cpp_class_body_#{sanitize(owner)}"
    code = +"#{CLASS_UNIT_DECLS}static mrb_value #{fn}(mrb_state* M) {\n"
    code << "  mrb_value self = #{body_self_expr(owner)};\n"
    code << emit_register_initializers(body_register_count(program, irep), [])
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

  # A kept method a class body defines (its TDEF), compiled by the method compiler: its C++ and the call that registers
  # its entry, as emit_owner_registration_lines makes for a method. [code, define_line] or nil when the method does not
  # compile or has a visibility the registration call does not cover.
  def class_body_method_registration(owner, child_label)
    compiled = compile_method(child_label)
    return nil if compiled.nil? || compiled[:unsupported]

    define = { public: 'mrb_define_method', private: 'mrb_define_private_method' }[compiled[:visibility]]
    return nil unless define

    line = "  #{define}(M, bc2cpp_owner_reg, #{c_string_literal(compiled[:name])}, #{compiled[:entry]}, #{compiled[:aspec]});\n"
    [compiled[:code], line]
  end

  # CLASS_BODY_EMIT_GEM (on unless BC2CPP_CLASS_BODY_EMIT=0): the top-level class and module units of a gem's root body, as
  # [{ path:, code: }]. A unit is the CLASS or MODULE and its compiled body; the function it adds creates the class the
  # way vm.c's OP_CLASS and OP_MODULE do with the Object base and a nil superclass, then calls the body. A unit whose
  # superclass is not a literal nil, whose path is opened twice, or whose body refuses is left out: the VM still runs it.
  def compile_top_class_units(root_irep)
    program = BytecodeIR.for(root_irep)
    units = BytecodeIR.class_bodies(root_irep, :CLASS, :MODULE).filter_map do |idx, child|
      insn = program.source_at(idx)
      path = BytecodeIR.class_body_path(root_irep, idx, nil)
      next nil unless path && top_unit_super_nil?(program, idx, insn)

      code, _refused = compile_class_body(@ireps.fetch(child), path)
      next nil unless code

      { path: path, insn: insn, code: code }
    end
    counts = units.map { |unit| unit[:path] }.tally
    units.select { |unit| counts[unit[:path]] == 1 }.map do |unit|
      { path: unit[:path], code: top_class_unit_code(unit[:insn], unit[:path], unit[:code]) }
    end
  end

  # The function that creates a top-level unit's class and calls its body function (compile_class_body names it).
  def top_class_unit_code(insn, path, body_code)
    base = 'mrb_obj_value(M->object_class)'
    sym = "mrb_intern_cstr(M, \"#{insn.sym}\")"
    define = if insn.op == :MODULE
               "(void)mrb_vm_define_module(M, #{base}, #{sym});"
             else
               "(void)mrb_vm_define_class(M, #{base}, mrb_nil_value(), #{sym});"
             end
    "#{body_code}static void bc2cpp_top_unit_#{sanitize(path)}(mrb_state* M) {\n" \
      "  #{define}\n  (void)bc2cpp_class_body_#{sanitize(path)}(M);\n}\n"
  end

  # A CLASS takes its superclass from the register after its base; only a LOADNIL there is a nil superclass the unit
  # can pass as is. A MODULE has none.
  def top_unit_super_nil?(program, idx, insn)
    return true if insn.op == :MODULE

    previous = program.source_at(idx - 1)
    previous&.op == :LOADNIL && previous.reg == insn.reg + 1
  end

  # The registers the body's function declares: the irep's, and any a body instruction names beyond them (an omitted
  # TDEF writes its register directly).
  def body_register_count(program, irep)
    named = program.each_source.filter_map { |insn, _| insn.reg&.to_i&.succ }
    [irep.nregs, *named].max
  end

  # The call that registers a kept method a class body defines: a TDEF defines on the body's class (self), an SDEF on its
  # singleton class. The entry is the gem's compiled method for the same irep, so the body makes the call the gem's own
  # registration also makes (emit_owner_registration_lines), and the gem registers it again after the units run. Nil
  # when the build has no compiled entry for the method, or the method is left out of the tables, or the call is one
  # this emitter does not make (a private singleton method, or an SDEF inside a `class << self` body).
  def class_body_registration(insn, irep, owner)
    child = irep.reps[insn.def_child_index]
    compiled = child && @compiled_methods&.[](child)
    return nil unless compiled && compiled[:entry] && compiled[:aspec] && !compiled[:guard]
    return nil if unregistered_keys.include?("#{compiled[:owner]}##{compiled[:name]}")

    call = if insn.op == :SDEF
             return nil if owner.end_with?('.singleton') || compiled[:visibility] != :public

             'mrb_define_class_method'
           else
             { public: 'mrb_define_method', private: 'mrb_define_private_method' }[compiled[:visibility]]
           end
    return nil unless call

    "  #{call}(M, mrb_class_ptr(self), #{c_string_literal(compiled[:name])}, #{compiled[:entry]}, #{compiled[:aspec]});\n"
  end

  def omitted_def?(insn, owner, omitted)
    insn.op == :TDEF && omitted.include?("#{owner}##{insn.sym}")
  end
end
