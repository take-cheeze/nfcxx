# frozen_string_literal: true

# CLASS_BODY_EMIT (prototype): one C++ function per class body, in place of OP_EXEC. A CLASS or MODULE and the EXEC that
# follows it are one unit: the class is created the way the VM creates it (vm.c OP_CLASS / OP_MODULE), then the child
# body's compiled function runs. Restricted: a body compiles only when each opcode is one compile_insn already emits,
# plus SETCONST, a CLASS/MODULE unit whose child compiles, and a TDEF of an omitted key; anything else refuses the whole
# body and names the opcodes.

require 'fileutils'

class CodeGen
  # The build's compiled methods (compile_all's hashes), keyed by irep label: a body's TDEF and SDEF register the
  # entry the gem already emits for the method. Set before compile_top_class_units.
  attr_writer :compiled_methods

  # SEND and SEND0 are in: a unit's send is a plain mrb_funcall (see compile_class_body), and a no-argument send is the
  # same call with no arguments. The shape that needs SEND0 is core `Enumerable`'s `NONE = Object.new` (GETCONST Object
  # then SEND0 :new), the one body the driver refused. The name such a call keeps in the method table is one the SEND
  # sites keep already. The self sends (SSEND, SSEND0) are left to the VM, since a self send in a body calls owner-call
  # helpers the gem emits only for its compiled methods.
  CLASS_BODY_VISIBILITY_SENDS = %w[private public protected module_function private_class_method public_class_method].freeze
  CLASS_BODY_OPS = (%i[NOP STOP RETURN RETNIL LOADNIL LOADSELF LOADTRUE LOADFALSE LOADL LOADSYM STRING LOADI__1 LOADI_0
                       LOADI_1 LOADI_2 LOADI_3 LOADI_4 LOADI_5 LOADI_6 LOADI_7 LOADI8 LOADI16 LOADI32 SETCONST
                       GETCONST SETGV ARRAY HASH ADD ADDI ADDILV SUB SUBI SUBILV MUL DIV GETMCNST SETIV SYMBOL EQ ARYCAT MOVE GETIDX RANGE_INC SEND SEND0]).freeze

  # The mruby entry points a class unit calls (vm.c; the same declarations the class-body prelude makes).
  CLASS_UNIT_DECLS = <<~CPP
    extern "C" struct RClass* mrb_vm_define_class(mrb_state*, mrb_value, mrb_value, mrb_sym);
    extern "C" struct RClass* mrb_vm_define_module(mrb_state*, mrb_value, mrb_sym);
  CPP

  # [C++ text, nil] for a compiled body (its children's functions first), or [nil, refusing opcodes]. `owner` is the
  # body's class path. A TDEF of an omitted key (unregistered_keys) is its register write alone.
  # A checked send (codegen_checked_send.rb) names a helper the gem does not define, so a unit's sends keep the plain
  # mrb_funcall the generator starts from. @class_body_unit is set only while a unit compiles.
  # UNIT_TAG: a unit's function names carry its tag ("_<occurrence>" for a reopened top-level class), so each occurrence
  # of one class path is its own function in the translation unit. Nested bodies inherit the tag of their unit.
  def compile_class_body(irep, owner, tag: '')
    was_unit = @class_body_unit
    outer_notes = @class_body_notes
    outer_tag = @unit_tag
    @class_body_unit = true
    @class_body_notes = []
    @unit_tag = tag
    code, refused = compile_class_body_unit(irep, owner)
    dump_class_unit(owner, code, refused, @class_body_notes)
    [code, refused]
  ensure
    @class_body_unit = was_unit
    @class_body_notes = outer_notes
    @unit_tag = outer_tag
  end

  # BC2CPP_DUMP_UNITS=<dir>: each body the driver tries, as <owner>.cpp (its unit text) or <owner>.refused (the opcodes
  # that refuse it). A nested body is tried once per enclosing unit, so the last attempt for an owner is the one kept.
  def dump_class_unit(owner, code, refused, notes = [])
    dir = ENV['BC2CPP_DUMP_UNITS']
    return if dir.nil? || dir.empty?

    # One directory per gem run (OUT_SYMBOL), so the probe runs (never_called_probe) do not overwrite the shipped gems' files.
    run_dir = File.join(dir, ENV.fetch('OUT_SYMBOL', 'unnamed_run'))
    FileUtils.mkdir_p(run_dir)
    base = File.join(run_dir, sanitize(owner))
    if code
      File.write("#{base}.cpp", code)
      File.delete("#{base}.refused") if File.exist?("#{base}.refused")
    else
      File.write("#{base}.refused", "#{Array(refused).map(&:to_s).sort.join(' ')}\n#{notes.map { |n| "  #{n}\n" }.join}")
      File.delete("#{base}.cpp") if File.exist?("#{base}.cpp")
    end
  end

  def compile_class_body_unit(irep, owner)
    program = BytecodeIR.for(irep)
    check_const_reads(program, owner)
    omitted = unregistered_keys
    bodies = BytecodeIR.class_bodies(irep, :CLASS, :MODULE, :SCLASS)
    paired_exec = bodies.keys.to_set { |idx| idx + 1 }
    # A constant a block builds is the folded value (codegen_class_fold.rb): its statement's instructions are skipped.
    folds = folded_class_constants(program, irep, owner)
    folded_away = folds.values.flat_map { |fold| fold[:skip] }.to_set
    unsupported = program.each_source.reject do |insn, idx|
      folded_away.include?(idx) || %i[TDEF SDEF ALIAS SSEND SSEND0 TCLASS METHOD DEF].include?(insn.op) || literal_freeze?(program, idx) ||
      (%i[CLASS MODULE SCLASS].include?(insn.op) && bodies.key?(idx)) || (%i[CLASS MODULE].include?(insn.op) && !bodies.key?(idx)) ||
      (insn.op == :SCLASS && !bodies.key?(idx) && self_singleton_open?(program, idx)) ||
        (insn.op == :EXEC && paired_exec.include?(idx)) || (insn.op == :LAMBDA && free_lambda_irep(insn, irep)) ||
        literal_native_send?(program, irep, idx)
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
    # The instance methods this body has registered so far: an alias may name only one of them (its old name must exist
    # when the unit runs, and the gem's own registrations come after the units).
    registered = Set.new
    program.each_source do |insn, idx|
      next if paired_exec.include?(idx) && insn.op == :EXEC || folded_away.include?(idx)

      lines << folds[idx][:code] if folds.key?(idx)
      if bodies.key?(idx)
        child_path = child_body_path(program, irep, idx, owner)
        return [nil, [:UNRESOLVED_CLASS_PATH]] unless child_path

        child_code, child_refused = compile_class_body(@ireps.fetch(bodies.fetch(idx)), child_path, tag: @unit_tag)
        return [nil, child_refused] unless child_code

        texts << child_code
        lines << class_unit_define(insn)
        lines << "  (void)bc2cpp_class_body_#{sanitize(child_path)}#{@unit_tag}(M);\n"
      elsif %i[TDEF SDEF].include?(insn.op) && omitted_def?(insn, owner, omitted)
        lines << "  // #{owner}##{insn.sym} omitted: statically dispatched only (no registration)\n"
        lines << "  r#{insn.reg} = mrb_symbol_value(mrb_intern_cstr(M, \"#{insn.sym}\"));\n"
      elsif %i[TDEF SDEF].include?(insn.op) && left_out_method?(insn, irep)
        # The method is left out of the tables (statically dispatched only), so the unit registers nothing for it.
        lines << "  // #{insn.sym} left out of the method tables: statically dispatched only (no registration)\n"
        lines << "  r#{insn.reg} = mrb_symbol_value(mrb_intern_cstr(M, \"#{insn.sym}\"));\n"
      elsif %i[TDEF SDEF].include?(insn.op)
        registration = class_body_registration(insn, irep, owner)
        if registration.nil? && irep.file.to_s.end_with?('/mruby-enumerator/mrblib/enumerator.rb')
          # A def the compiler cannot express (SKIP_UNSUPPORTED, e.g. Enumerator#initialize_copy's instance_eval block) is just
          # missing: refusing the body would lose the whole class, whose compiled methods register on it (ENUMERATOR_FIBER).
          lines << "  // #{owner}##{insn.sym} has no compiled body (unsupported): the class body still runs\n"
          lines << "  r#{insn.reg} = mrb_symbol_value(mrb_intern_cstr(M, \"#{insn.sym}\"));\n"
          next
        end
        return [nil, [insn.op]] unless registration

        registered << insn.sym.to_s if insn.op == :TDEF
        lines << registration
        lines << "  r#{insn.reg} = mrb_symbol_value(mrb_intern_cstr(M, \"#{insn.sym}\"));\n"
      elsif %i[CLASS MODULE].include?(insn.op) && !bodies.key?(idx)
        # A class or module with an empty body has no EXEC: it is only created (vm.c OP_CLASS / OP_MODULE), as a unit does.
        lines << class_unit_define(insn)
      elsif insn.op == :SCLASS && !bodies.key?(idx)
        # A `class << self` with no EXEC: its defs follow on the register, which is the singleton class (vm.c OP_SCLASS).
        lines << class_unit_define(insn)
      elsif insn.op == :TCLASS
        # The target class of a class body is the body's own class: the self of this function.
        lines << "  r#{insn.reg} = self;\n"
      elsif insn.op == :METHOD
        # The proc a `def` installs; the DEF after it registers the method, so nothing is written here.
        lines << "  // proc for the def that follows (R#{insn.reg})\n"
      elsif insn.op == :DEF && left_out_def?(program, idx, irep)
        # Left out of the tables (statically dispatched only), as a TDEF of an omitted key is: nothing registers.
        lines << "  // #{insn.sym} left out of the method tables: statically dispatched only (no registration)\n"
        lines << "  r#{insn.reg} = mrb_symbol_value(mrb_intern_cstr(M, #{c_string_literal(insn.sym.to_s)}));\n"
      elsif insn.op == :DEF
        registration = class_def_registration(insn, program, idx, irep)
        return [nil, [:DEF]] unless registration

        lines << registration
        lines << "  r#{insn.reg} = mrb_symbol_value(mrb_intern_cstr(M, #{c_string_literal(insn.sym.to_s)}));\n"
      elsif %i[SSEND SSEND0].include?(insn.op) && AliasSites.settled?(@registry, irep.label, idx)
        # A settled alias_method site is the registry's definition (ALIAS_SITES), so it installs nothing here: a by-name
        # call copies `old` as it stands at run time, and a body run twice copies its own def (alias_handled_by_ir?).
        lines << "  // #{insn.sym} alias handled by the bytecode IR\n"
      elsif %i[SSEND SSEND0].include?(insn.op) && CLASS_BODY_VISIBILITY_SENDS.include?(insn.sym.to_s)
        # private/public/protected/module_function set visibility of defs the registration already sets, and a
        # statically dispatched def has no method to set it on: nothing to run here.
        lines << "  // #{insn.sym} (visibility) left to the method registrations\n"
      elsif %i[SSEND SSEND0].include?(insn.op)
        # A self send (include, extend, prepend, attr_accessor, ...) runs by name on the class being defined; the VM-free build
        # has no residual bytecode to run it.
        n = insn.op == :SSEND0 ? 0 : (insn.argc || 0)
        args = (1..n).map { |k| "r#{insn.reg + k}" }
        lines << "  r#{insn.reg} = bc2cpp_ssend(M, self, mrb_intern_cstr(M, #{c_string_literal(insn.sym.to_s)}), {#{args.join(', ')}});\n"
      elsif literal_length_send?(program, irep, idx)
        lines << literal_length_line(program, irep, idx)
      elsif literal_freeze?(program, idx)
        lines << "  r#{insn.reg} = mrb_obj_freeze(M, r#{insn.reg});\n"
      elsif insn.op == :ALIAS && alias_handled_by_ir?(irep, idx, owner)
        # The registry defines the new name (AliasSites) and the gem registers it; the VM residual still runs the alias.
        lines << "  // #{insn.sym} alias handled by the bytecode IR\n"
      elsif insn.op == :ALIAS && omitted_alias?(insn, owner, omitted)
        # A name the build leaves out of the tables is statically dispatched only: no method is installed for it, and
        # an old name left out of them does not exist when the unit runs (mrb_alias_method would raise NameError).
        lines << "  // #{insn.sym} alias of a method left out of the tables: statically dispatched only (no registration)\n"
      elsif insn.op == :ALIAS
        line = class_body_alias(insn, registered)
        return [nil, [:ALIAS]] unless line

        lines << line
      elsif insn.op == :LAMBDA
        fn_code, glue = class_free_lambda(insn, irep, owner, owner_def, idx)
        return [nil, [:LAMBDA]] unless glue

        texts << fn_code
        lines << glue
      else
        lines << compile_insn(insn, irep, owner_def, idx)
      end
    end
    fn = "bc2cpp_class_body_#{sanitize(owner)}#{@unit_tag}"
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
  # A SCLASS on self with no EXEC after it (`class << self` whose defs the compiler emits inline): the unit makes the
  # singleton class of the register and the DEFs after it register on that class.
  def self_singleton_open?(program, idx)
    insn = program.source_at(idx)
    previous = program.source_at(idx - 1)
    previous&.op == :LOADSELF && previous.reg == insn.reg
  end

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
    else
      # vm.c (OP_CLASS, OP_MODULE): a nil base is the body's target class, which is this body's self.
      base = "(mrb_nil_p(r#{reg}) ? self : r#{reg})"
      if insn.op == :CLASS
        "  r#{reg} = mrb_obj_value(mrb_vm_define_class(M, #{base}, r#{reg + 1}, mrb_intern_cstr(M, \"#{insn.sym}\")));\n"
      else
        "  r#{reg} = mrb_obj_value(mrb_vm_define_module(M, #{base}, mrb_intern_cstr(M, \"#{insn.sym}\")));\n"
      end
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
  # CONST_RESOLVE: a constant read (GETCONST / GETMCNST) must name a constant the build binds before the unit runs (the IR's
  # constant table plus the names native sources define). Unresolved reads are collected and compile_top_class_units
  # fails once at the phase end; CodeGen.known_const_names nil means no check.
  def check_const_reads(program, owner)
    known = CodeGen.known_const_names
    return unless known

    program.each_source do |insn, _idx|
      name = case insn.op
             when :GETCONST then insn.const_name
             when :GETMCNST then insn.mcnst_name
             end
      next if name.nil? || known.include?(name.to_s)

      (CodeGen.const_unresolved ||= []) << { name: name.to_s, owner: owner }
    end
  end

  def compile_top_class_units(root_irep)
    program = BytecodeIR.for(root_irep)
    candidates = BytecodeIR.class_bodies(root_irep, :CLASS, :MODULE).filter_map do |idx, child|
      insn = program.source_at(idx)
      path = BytecodeIR.class_body_path(root_irep, idx, nil)
      superclass = path && top_unit_superclass(program, idx, insn)
      next nil unless superclass

      [insn, path, child, superclass]
    end
    occurrences = Hash.new(0)
    compiled = candidates.map do |insn, path, child, superclass|
      tag = "_#{occurrences[path]}"
      occurrences[path] += 1
      code, _refused = compile_class_body(@ireps.fetch(child), path, tag: tag)
      { path: path, insn: insn, code: code, tag: tag, superclass: superclass, file: @ireps.fetch(child).file }
    end
    missing = (CodeGen.const_unresolved || []).uniq
    unless missing.empty?
      listing = missing.map { |m| "  #{m[:name]} (read in #{m[:owner]})" }.join("\n")
      raise "unresolved constants in class bodies (CONST_RESOLVE):\n#{listing}"
    end
    # A path is emitted only when every occurrence of it compiled: UNIT_BLANK removes all of that path's statements, so a
    # refused occurrence would otherwise lose its body.
    refused_paths = compiled.reject { |unit| unit[:code] }.map { |unit| unit[:path] }.to_set
    compiled.select { |unit| unit[:code] && !refused_paths.include?(unit[:path]) }.map do |unit|
      { path: unit[:path], name: "#{sanitize(unit[:path])}#{unit[:tag]}", file: unit[:file],
        code: top_class_unit_code(unit[:insn], unit[:path], unit[:code], unit[:tag], unit[:superclass]) }
    end
  end

  # The function that creates a top-level unit's class and calls its body function (compile_class_body names it).
  def top_class_unit_code(insn, path, body_code, tag = '', superclass = 'mrb_nil_value()')
    base = 'mrb_obj_value(M->object_class)'
    sym = "mrb_intern_cstr(M, \"#{insn.sym}\")"
    define = if insn.op == :MODULE
               "(void)mrb_vm_define_module(M, #{base}, #{sym});"
             else
               "(void)mrb_vm_define_class(M, #{base}, #{superclass}, #{sym});"
             end
    "#{body_code}static void bc2cpp_top_unit_#{sanitize(path)}#{tag}(mrb_state* M) {\n" \
      "  #{define}\n  (void)bc2cpp_class_body_#{sanitize(path)}#{tag}(M);\n}\n"
  end

  # The superclass a top-level unit passes to mrb_vm_define_class, as a C expression, or nil when the unit cannot name it.
  # A CLASS takes its superclass from the register after its base: a LOADNIL there is nil, and a GETCONST there is a
  # constant read, which the unit reads from Object as the VM does. A MODULE has none.
  def top_unit_superclass(program, idx, insn)
    return 'mrb_nil_value()' if insn.op == :MODULE

    previous = program.source_at(idx - 1)
    return nil unless previous && previous.reg == insn.reg + 1

    case previous.op
    when :LOADNIL then 'mrb_nil_value()'
    when :GETCONST
      "mrb_const_get(M, mrb_obj_value(M->object_class), mrb_intern_cstr(M, \"#{previous.const_name}\"))"
    end
  end

  # TOP_LEVEL_STATEMENTS: the top-level constant and global writes of a gem's root body, as C++ statements in one function
  # gem_init calls after the class units. A statement is the run of root instructions ending in a SETCONST or SETGV (or a
  # class EXEC). Returns '' for none.
  def compile_top_level_statements(root_irep)
    program = BytecodeIR.for(root_irep)
    body = +''
    start = 0
    targets = jump_targets(root_irep)
    jump_sources = top_level_jump_sources(program)
    program.each_source do |insn, idx|
      if insn.op == :EXEC
        start = idx + 1
        next
      end
      next unless %i[SETCONST SETGV].include?(insn.op)

      # A run whose branches leave it (`if cond; X = 1; else; X = 2; end` spans two runs) would emit a `goto` to a label that
      # is in no statement, or jump over a declaration into one. The VM still runs such a statement from the bytecode.
      unless top_level_run_self_contained?(program, start, idx, jump_sources)
        start = idx + 1
        next
      end

      lines = +''
      @class_body_unit = true
      owner_def = Struct.new(:owner, :core, :name, :irep).new('Object', false, nil, root_irep)
      (start..idx).each do |index|
        source = program.source_at(index)
        next unless source

        # A jump inside the run (`x = cond ? A : B`) lands on a label of this statement; compile_insn writes the `goto` only.
        lines << "  L#{source.addr}:;\n" if targets.include?(source.addr)
        lines << compile_insn(source, root_irep, owner_def, index)
      end
      body << "  {\n#{emit_register_initializers(body_register_count(program, root_irep), [])}#{lines}  }\n"
      start = idx + 1
    end
    return '' if body.empty?

    "static void bc2cpp_top_level_statements(mrb_state* M) {\n  mrb_value self = mrb_obj_value(M->top_self);\n#{body}}\n"
  ensure
    @class_body_unit = false
  end

  # Target index => the indices whose branch (not fallthrough) or raise reaches it, over a root program.
  def top_level_jump_sources(program)
    sources = Hash.new { |h, k| h[k] = [] }
    program.size.times do |i|
      program.successors_of(i, include_handlers: true).each { |n| sources[n] << i unless n == i + 1 }
    end
    sources
  end

  # Every branch of run start..idx lands inside the run (a branch to the next statement would be a goto into another block),
  # and no branch from outside lands inside past its first instruction.
  def top_level_run_self_contained?(program, start, idx, jump_sources)
    range = start..idx
    inside = range.all? do |i|
      program.successors_of(i, include_handlers: true).all? { |n| n == i + 1 || range.cover?(n) }
    end
    return false unless inside

    ((start + 1)..idx).none? { |t| jump_sources.key?(t) && jump_sources[t].any? { |src| !range.cover?(src) } }
  end

  # The units a gem's gem_init runs are the ones of the owners that gem emits (ONLY_OWNERS). Every gem's TU would otherwise
  # run every unit, so core's gem_init ran RPG2k's body before mruby-rgss had defined RGSS (uninitialized constant RGSS
  # at boot). A unit is kept when an owner is its path or nests under it. nil only_owners is the one run for every owner.
  def owned_class_units(units, only_owners)
    return units unless only_owners

    units.select do |unit|
      path = unit[:path]
      only_owners.any? { |owner| owner == path || owner.start_with?("#{path}::", "#{path}.") }
    end
  end

  # FREE_LAMBDA: a lambda whose body reads nothing from its creating frame (no self, no upvar, no block, no nested
  # closure) is built as a free RProc (mrb_proc_new_cfunc, no env) over a standalone cfunc. The ops below are the ones
  # that read self, the frame's upvars or block, or create a closure over them. Nil when the lambda is not free.
  FREE_LAMBDA_FRAME_OPS = %i[LOADSELF RETSELF SSEND SSEND0 SSENDB SENDB SUPER BLOCK LAMBDA METHOD EXEC SCLASS TCLASS GETIV SETIV
                             GETCV SETCV GETUPVAR SETUPVAR BLKPUSH BLKCALL CLASS MODULE DEF TDEF SDEF ALIAS].freeze

  def free_lambda_irep(insn, irep)
    label = irep.reps[insn.block_index.to_i]
    child = label && @ireps[label]
    return nil unless child && lambda_fallback_safe?(child)
    return nil if BytecodeIR.for(child).op?(*FREE_LAMBDA_FRAME_OPS) || block_self_rebound?(label)
    # self is R0 of the body (a `self` expression is a MOVE from R0, not a LOADSELF), and the body never writes R0.
    return nil if BytecodeIR.for(child).each_source.any? { |insn, _| insn.regs.include?(0) }

    upvars = block_upvar_needs(child)
    upvars&.empty? ? child : nil
  end

  # The standalone function of a free lambda and the statement that builds its RProc. Nil when the body does not
  # compile standalone; the caller then refuses the whole body.
  def class_free_lambda(insn, irep, owner, owner_def, idx)
    child = free_lambda_irep(insn, irep)
    return nil unless child

    region = { block_addr: idx, dest_reg: insn.reg, block_irep: child, kind: 'lambda_fallback', upvars: [], call_sites: [],
               free: true }
    fn_name, fn_code = emit_proc_fallback_fn(region, owner_def, "bc2cpp_class_lambda_#{sanitize(owner)}")
    return nil unless fn_code

    # A lambda checks its arity (vm.c: a lambda's RProc is strict).
    glue = "  {\n    struct RProc* bc2cpp_free_lambda = mrb_proc_new_cfunc(M, #{fn_name});\n" \
           "    bc2cpp_free_lambda->flags |= MRB_PROC_STRICT;\n    r#{insn.reg} = mrb_obj_value(bc2cpp_free_lambda);\n  }\n"
    [fn_code, glue]
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
  # A def whose method the build leaves out of its tables (unregistered_keys), by the owner and name the compiled entry
  # carries. Its registration is skipped, and nothing the unit does depends on it.
  def left_out_method?(insn, irep)
    compiled = @compiled_methods&.[](irep.reps[insn.def_child_index])
    return false unless compiled

    unregistered_keys.include?("#{compiled[:owner]}##{compiled[:name]}")
  end

  # The body of the `def` a DEF installs: the child of the METHOD built into R[a+1] just before it. Nil when there is none.
  def def_method_child(insn, program, idx, irep)
    method = (idx - 1).downto(idx - 4).map { |j| program.source_at(j) }.find { |m| m&.op == :METHOD && m.reg == insn.reg + 1 }
    method && irep.reps[method.block_index]
  end

  # A DEF whose method the build leaves out of its tables (unregistered_keys), by the owner and name its compiled entry carries.
  def left_out_def?(program, idx, irep)
    insn = program.source_at(idx)
    compiled = @compiled_methods&.[](def_method_child(insn, program, idx, irep))
    compiled ? unregistered_keys.include?("#{compiled[:owner]}##{compiled[:name]}") : false
  end

  # The call that registers a `def` a class body makes through DEF (not TDEF): the class is R[a] (set by TCLASS), the method
  # is the proc METHOD built into R[a+1] just before. Its compiled entry is the one TDEF uses. Nil when the proc, its entry
  # or its visibility is not one this emitter makes, or the method is left out of the tables (then nothing registers).
  def class_def_registration(insn, program, idx, irep)
    child = def_method_child(insn, program, idx, irep)
    compiled = child && @compiled_methods&.[](child)
    return nil unless compiled && compiled[:entry] && compiled[:aspec]
    return nil if unregistered_keys.include?("#{compiled[:owner]}##{compiled[:name]}")

    define = { public: 'mrb_define_method', private: 'mrb_define_private_method' }[compiled[:visibility]]
    return nil unless define

    "  #{define}(M, mrb_class_ptr(r#{insn.reg}), #{c_string_literal(compiled[:name])}, #{compiled[:entry]}, #{compiled[:aspec]});\n"
  end

  def class_body_registration(insn, irep, owner)
    child = irep.reps[insn.def_child_index]
    # A core definition a later definition replaces is not registered: the later one is (CORE_SHADOWED).
    return nil if child && CodeGen.shadowed_labels&.include?(child)
    compiled = child && @compiled_methods&.[](child)
    # A bytecode def with no compiled body (a block-taking wrapper such as Array#sort) keeps the native method already
    # registered under that owner and name, instead of refusing the whole class body.
    if compiled.nil? && (@registry[insn.sym.to_s] || []).any? { |d| d.owner == owner && d.irep.nil? }
      return nil
    end
    # A guarded entry registers too; its Fiber fallback reads bytecode that engine methods lack, so a block call under a
    # non-root Fiber fails there.
    return class_body_refusal(insn, compiled, child) unless compiled && compiled[:entry] && compiled[:aspec]
    return nil if unregistered_keys.include?("#{compiled[:owner]}##{compiled[:name]}")

    call = if insn.op == :SDEF
             return class_body_refusal(insn, compiled, child, 'singleton def in a singleton body or not public') if owner.end_with?('.singleton') || compiled[:visibility] != :public

             'mrb_define_class_method'
           else
             { public: 'mrb_define_method', private: 'mrb_define_private_method' }[compiled[:visibility]]
           end
    return class_body_refusal(insn, compiled, child, "visibility #{compiled[:visibility].inspect}") unless call

    "  #{call}(M, mrb_class_ptr(self), #{c_string_literal(compiled[:name])}, #{compiled[:entry]}, #{compiled[:aspec]});\n"
  end

  # Why a TDEF or SDEF of a unit registers nothing (nil): the method's compiled entry is missing or refused, with the
  # `#error` line its refusal wrote. Recorded for BC2CPP_DUMP_UNITS.
  def class_body_refusal(insn, compiled, child, reason = nil)
    reason ||= if compiled.nil?
                 "no compiled method for irep #{child.inspect}"
               elsif compiled[:guard]
                 "guarded entry #{compiled[:guard].inspect}"
               else
                 compiled[:code].to_s[/^#error.*$/] || "no entry or aspec (#{compiled.keys.sort.join(' ')})"
               end
    (@class_body_notes ||= []) << "#{insn.op} #{insn.sym}: #{reason}"
    nil
  end

  # The call an `alias NEW OLD` in a class body makes (vm.c OP_ALIAS: mrb_alias_method(target, NEW, OLD)). It runs after
  # the body registered OLD, so OLD exists. Nil when OLD is not a method this body has registered (an inherited, native
  # or omitted method): the unit could not find it.
  # An ALIAS the bytecode IR handles: a settled registry definition (AliasSites.settle), or a core alias the static routing
  # map sends to its target (CoreDefs.alias_map). Such an alias needs no unit code: a settled one's old name may not
  # exist yet when the unit runs (the gem's registrations come after the units), and the VM residual still runs both.
  def alias_handled_by_ir?(irep, idx, owner)
    return true if AliasSites.settled?(@registry, irep.label, idx)
    return false unless CoreDefs.core_source?(irep.file) && self.class.core_aliases

    name = BytecodeIR.for(irep).source_at(idx).sym
    self.class.core_aliases.any? { |(key_owner, _), names| key_owner == owner && names.include?(name) }
  end

  # An alias copies the method `old` names when the unit runs. That is a native (C) method, which mruby's own init defines
  # before any gem_init runs, or a method this body registers earlier. A Ruby method the gem registers after the units
  # is not there yet, so it is refused: the registry lists it (a def with a body).
  # True when no definition of +name+ anywhere in the registry has a body: the name is a native method.
  def native_before_units?(name)
    @registry.fetch(name, []).none? { |definition| definition.irep }
  end

  def class_body_alias(insn, registered)
    old = insn.first_of(:name)&.value.to_s
    return nil unless registered.include?(old) || native_before_units?(old)

    "  mrb_alias_method(M, mrb_class_ptr(self), mrb_intern_cstr(M, #{c_string_literal(insn.sym.to_s)}), " \
      "mrb_intern_cstr(M, #{c_string_literal(old)}));\n"
  end

  # A SEND0 `to_a` on the register a Range literal was just built into: the literal fixes the receiver's class, so the
  # send can take the compiled core body (Range#to_a).
  def literal_native_send?(program, irep, idx)
    insn = program.source_at(idx)
    return false unless insn.op == :SEND0

    previous = program.source_at(idx - 1)
    return false unless previous && previous.reg == insn.reg

    case insn.sym.to_s
    when 'to_a'
      # Range#to_a is a core body (its super resolves through Enumerable); the receiver's class is known from the literal.
      previous.op == :RANGE_INC
    when 'length', 'size'
      !literal_string_counts(previous, irep).nil?
    else
      false
    end
  end

  # A `length` or `size` SEND0 on the String literal just built into its register: folded to the literal's count.
  def literal_length_send?(program, irep, idx)
    insn = program.source_at(idx)
    %w[length size].include?(insn.sym.to_s) && literal_native_send?(program, irep, idx)
  end

  # [byte count, character count] of a STRING literal, or nil when it is not a String pool entry or its bytes are not
  # valid UTF-8 (then no character count is taken). The two counts are what RSTRING_CHAR_LEN gives with and without
  # MRB_UTF8_STRING; the C arm is chosen by the preprocessor, so the fold follows the build's own setting.
  def literal_string_counts(insn, irep)
    return nil unless insn&.op == :STRING

    entry = irep.pool[insn.pool_index.to_i]
    return nil unless entry.is_a?(String)

    utf8 = entry.dup.force_encoding(Encoding::UTF_8)
    return nil unless utf8.valid_encoding?

    [entry.b.bytesize, utf8.length]
  end

  # The fold's C text: the literal's count as the result register, under MRB_UTF8_STRING or not.
  def literal_length_line(program, irep, idx)
    insn = program.source_at(idx)
    bytes, chars = literal_string_counts(program.source_at(idx - 1), irep)
    "#ifdef MRB_UTF8_STRING\n  r#{insn.reg} = mrb_int_value(M, #{chars});\n" \
      "#else\n  r#{insn.reg} = mrb_int_value(M, #{bytes});\n#endif\n"
  end

  # A `freeze` with no arguments on the register a body holds, emitted as mrb_obj_freeze (Object#freeze) rather than a
  # send. Not checked for a user redefinition of freeze on the receiver: the direct call bypasses one.
  def literal_freeze?(program, idx)
    insn = program.source_at(idx)
    insn&.op == :SEND0 && insn.sym.to_s == 'freeze'
  end

  # A definition the static dispatch proof omits is never called by name, so its unit registers nothing for it. A TDEF's
  # key is Owner#name; an SDEF's is Owner.singleton#name (the lists' spelling).
  def omitted_def?(insn, owner, omitted)
    key = insn.op == :SDEF ? "#{owner}.singleton##{insn.sym}" : "#{owner}##{insn.sym}"
    omitted.include?(key)
  end

  # An `alias NEW OLD` naming a method the build leaves out of its tables, on either side (see class_body_alias).
  def omitted_alias?(insn, owner, omitted)
    old = insn.first_of(:name)&.value
    omitted.include?("#{owner}##{insn.sym}") || (!old.nil? && omitted.include?("#{owner}##{old}"))
  end
end

require_relative 'codegen_class_fold'
