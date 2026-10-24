# frozen_string_literal: true

require 'set'
require_relative 'bytecode_ir'
require_relative 'factory_flow'
require_relative 'core_defs'

# Method names a computed-name send (`send("#{stem}=", v)`, `method(name)`, ...) could reach
# although no call site spells them: the proofs that enumerate call sites (ArgTypes,
# ENTRY_ARG_CALLSITE_PROOF, FIXNUM_RETURN_PROOF, the embedding of ivars a setter writes) refuse
# these names. The same rule covers pooled numeric arguments.
module DynamicNames
  # Sends that turn a value into a method name (call it, fetch it, define it).
  SENDS = %w[send __send__ public_send method instance_method
             define_method define_singleton_method alias_method attr attr_reader attr_writer
             attr_accessor].freeze
  # PROBE_ONLY: a Symbol literal whose every use is the name argument of `respond_to?` never becomes a call:
  # Kernel#respond_to? (kernel.c) only looks the name up and asks respond_to_missing?, which is mruby's native
  # `false` unless the program defines it. So such a literal is left out while no Ruby defines, aliases or spells
  # either method. Nor is it a stem of a computed name: its value reaches nothing but the probe, and a same-spelled
  # literal used any other way is a stem already.
  PROBE_SENDS = %w[respond_to?].freeze
  PROBE_HOOKS = %w[respond_to? respond_to_missing?].freeze

  class << self
    # DEFINE_METHOD_LOOPS: [irep label, index] of each `define_method(n)` loop send the settled
    # registry defines => the names it installs (DefineMethodSites.loop_sites). Its name is not a literal at
    # the send, yet every name it can install is known. Empty until bc2cpp.rb sets it after settling.
    attr_writer :settled_sends

    def settled_sends
      @settled_sends || {}
    end
  end

  # A name built from a Symbol literal is already poisoned by the call-site scans (LOADSYM);
  # this adds names a program spells as a string, and, once any name is computed, the setter
  # `stem=` of every stem (the only composition the closed-world lint baseline contains).
  def self.universe(ireps)
    stems, computed = analyze(ireps)
    computed && setter_composition(ireps) ? stems | stems.map { |n| "#{n}=" } : stems
  end

  # SETTER_NAME_CLOSURE: a computed-name send calls the method its name value names, so it can reach an unspelled
  # setter `x=` only when a value naming `x=` exists at run time. A literal one is a stem already. The other ways a
  # program gets one are below; when it uses none of them, no setter name joins the universe through composition.
  # Native code handing Ruby a setter-name Symbol is outside the model, as for every Symbol value bc2cpp tracks.
  # Returns why a setter name may be composed ("file irep:index reason"), or nil. BC2CPP_SETTER_NAME_CLOSURE=0
  # restores the blanket rule.
  def self.setter_composition(ireps)
    return 'BC2CPP_SETTER_NAME_CLOSURE=0' if ENV['BC2CPP_SETTER_NAME_CLOSURE'] == '0'

    parents = exec_parents(ireps)
    ireps.each_value do |irep|
      program = BytecodeIR.for(irep)
      program.each_source do |insn, idx|
        why = setter_composition_at(irep, program, idx, insn, parents)
        return "#{File.basename(irep.file.to_s)} #{irep.label}:#{idx} #{why}" if why
      end
    end
    nil
  end

  # Sends whose result lists method names, or names the running method.
  METHOD_NAME_LISTERS = %w[methods public_methods private_methods protected_methods singleton_methods instance_methods
                           public_instance_methods private_instance_methods protected_instance_methods all_symbols
                           __method__].freeze
  # Definition sends whose result may be the defined name. mruby's attr_* return nil and define_method returns the
  # name value it was given (already a value), so this is a guard for other cores; DEF/TDEF/SDEF are the ones that
  # make a name value from a literal no LOADSYM spells.
  NAME_RESULT_SENDS = %w[define_method define_singleton_method attr attr_reader attr_writer attr_accessor
                         alias_method].freeze
  # The one use a definition's name value may have: a visibility call taking it as its argument.
  VISIBILITY_SENDS = %w[private public protected module_function private_class_method public_class_method].freeze
  # Core methods whose to_sym/intern keeps a Symbol's shape: case conversion of an existing Symbol, a Struct member.
  SHAPE_KEEPING_FILES = %r{/mrbgems/mruby-(?:symbol-ext/mrblib/symbol|struct/mrblib/struct)\.rb\z}

  # Sends that call the method a name value names. A computed one is safe only where the name is a Symbol by
  # construction (the core sends below), because send/public_send/method also take a String, and a String naming
  # a setter is one interpolation away from any spelled stem.
  CALLING_SENDS = %w[send __send__ public_send method instance_method].freeze
  # Core files whose computed __send__ sends a Symbol: Symbol#to_proc (its own self), Enumerable#inject (behind
  # `Symbol === args[-1]`) and Enumerator#each (the name to_enum, enum_for or Enumerator.new recorded, which
  # literal_enumerator_name? keeps a literal Symbol).
  SYMBOL_NAMED_FILES = %r{/(?:mrblib/(?:symbol|enum)|mrbgems/mruby-enumerator/mrblib/enumerator)\.rb\z}
  ENUMERATOR_MAKERS = %w[to_enum enum_for].freeze

  def self.string_named_call?(irep, program, idx, insn)
    return false unless CALLING_SENDS.include?(insn.sym) && !settled_sends.key?([irep.label, idx])
    return false if literal_name_argument?(irep, program, idx, insn)

    !(CoreDefs.core_source?(irep.file) && irep.file.to_s.match?(SYMBOL_NAMED_FILES) && insn.sym == '__send__')
  end

  # `to_enum`/`enum_for` with no name (:each) or a LOADSYM name, and `Enumerator.new(obj, :name, ...)` likewise.
  def self.literal_enumerator_name?(irep, program, idx, insn)
    return true if insn.op.end_with?('0')
    return insn.argc.to_i.zero? || literal_name_argument?(irep, program, idx, insn) if insn.plain_fixed_argc?

    insn.n_spec == '*' && literal_splat_head?(irep, program, idx, (insn.reg.to_i + 1).to_s)
  end

  # A splat call's packed argument Array (`f(:name, *rest)`: ARRAY then ARYCAT/ARYPUSH onto it) starts with a LOADSYM.
  def self.literal_splat_head?(irep, program, idx, reg)
    at = idx
    8.times do
      writers = BytecodeIR.reaching_writer_indices(irep, at, reg)
      return false unless writers&.size == 1

      writer = program.source_at(writers.first)
      case writer.op
      when 'ARYCAT', 'ARYPUSH'
        return false unless writer.reg.to_s == reg

        at = writers.first
      when 'ARRAY'
        return false unless writer.regs.size == 1 && writer.reg.to_s == reg && writer.uint_operand.to_i.positive?

        heads = BytecodeIR.reaching_writer_indices(irep, writers.first, reg)
        return heads && !heads.empty? && heads.all? { |i| program.source_at(i).op == 'LOADSYM' }
      else
        return false
      end
    end
    false
  end

  def self.setter_composition_at(irep, program, idx, insn, parents)
    case insn.op
    when 'INTERN' then interned_setter?(irep, program, idx, insn) ? 'interpolated Symbol may end in =' : nil
    when 'DEF', 'TDEF', 'SDEF' then name_value_used?(irep, idx, insn.reg, parents) ? "#{insn.op} name value used" : nil
    else
      return nil unless BytecodeIR::Ops::SEND_FAMILY.include?(insn.op)
      return "#{insn.sym} lists method names" if METHOD_NAME_LISTERS.include?(insn.sym)
      return "computed #{insn.sym} may take a String name" if string_named_call?(irep, program, idx, insn)
      return "#{insn.sym} names its method by a non-literal" if ENUMERATOR_MAKERS.include?(insn.sym) &&
                                                                 !literal_enumerator_name?(irep, program, idx, insn)
      shape_kept = CoreDefs.core_source?(irep.file) && irep.file.to_s.match?(SHAPE_KEEPING_FILES)
      return "#{insn.sym} of a String" if %w[to_sym intern].include?(insn.sym) && !shape_kept
      return nil unless NAME_RESULT_SENDS.include?(insn.sym) && name_value_used?(irep, idx, insn.reg, parents)

      "#{insn.sym} result used"
    end
  end

  # `:"...#{x}..."`: STRING/STRCAT pieces then INTERN. Its value ends in `=` only when its last piece can: safe when
  # every writer of the interned register is a STRCAT whose appended operand, or a STRING, is a literal not ending in `=`.
  def self.interned_setter?(irep, program, idx, insn)
    reg = insn.reg.to_s
    writers = BytecodeIR.reaching_writer_indices(irep, idx, reg) or return true
    writers.empty? || writers.any? do |w|
      writer = program.source_at(w)
      case writer.op
      when 'STRING' then string_may_end_setter?(irep, writer)
      when 'STRCAT'
        piece = BytecodeIR.reaching_writer_indices(irep, w, writer.paren_reg.to_s) or next true
        piece.empty? || piece.any? { |p| (s = program.source_at(p)).op != 'STRING' || string_may_end_setter?(irep, s) }
      else true
      end
    end
  end

  def self.string_may_end_setter?(irep, insn)
    entry = irep.pool[insn.pool_index.to_i]
    !entry.is_a?(String) || entry.end_with?('=')
  end

  # Whether the name value a definition leaves in +reg+ reaches anything but a visibility call. A class body's
  # value goes to its EXEC; a file's top-level value goes to the loader, which discards it.
  def self.name_value_used?(irep, idx, reg, parents, depth = 0)
    return true if reg.nil? || depth > 8

    uses = FactoryFlow.uses(irep, idx, reg.to_s) or return true
    program = BytecodeIR.for(irep)
    uses.any? do |use, used_reg|
      user = program.source_at(use)
      # vm.c OP_TDEF never reads R[a]; OP_DEF/OP_SDEF read it as the definition's target, which routes no name.
      next false if %w[DEF TDEF SDEF].include?(user.op)
      # A self send's R[a] is only its result slot (the receiver is self), so the value is overwritten, not read.
      next false if user.op.start_with?('SSEND') && used_reg.to_s == user.reg.to_s
      next false if VISIBILITY_SENDS.include?(user.sym) && BytecodeIR::Ops::SEND_FAMILY.include?(user.op) &&
                    user.plain_fixed_argc? && used_reg.to_i > user.reg.to_i
      next true unless user.op == 'RETURN'

      parent = parents[irep.label]
      next false if parent == :root
      next true unless parent

      parent_irep, exec_idx, exec_reg = parent
      name_value_used?(parent_irep, exec_idx, exec_reg, parents, depth + 1)
    end
  end

  # Irep label => [parent irep, EXEC index, EXEC result register] for a class body, :root for a file's top level.
  def self.exec_parents(ireps)
    map = {}
    children = ireps.values.flat_map { |irep| Array(irep.reps) }.to_set
    ireps.each_value do |irep|
      map[irep.label] = :root unless children.include?(irep.label)
      BytecodeIR.for(irep).each_with_op('EXEC') do |insn, idx|
        child = insn.block_index && Array(irep.reps)[insn.block_index]
        map[child] = [irep, idx, insn.reg] if child
      end
    end
    map
  end

  # [the names a program spells as a Symbol or String literal, whether any send turns a computed
  # value into a name].
  def self.analyze(ireps)
    stems = Set.new
    probes = Set.new
    computed = false
    ireps.each_value do |irep|
      program = BytecodeIR.for(irep)
      program.each_with_op('LOADSYM', 'STRING', *BytecodeIR::Ops::SEND_FAMILY) do |insn, idx|
        (probe_only?(irep, idx, insn) ? probes : stems) << insn.sym if insn.op == 'LOADSYM' && insn.sym
        if insn.op == 'STRING'
          entry = irep.pool[insn.pool_index.to_i]
          stems << entry if entry.is_a?(String) && entry.match?(/\A[A-Za-z_]\w*[?!=]?\z/)
          next
        end
        next unless SENDS.include?(insn.sym)

        if (installed = settled_sends[[irep.label, idx]])
          stems.merge(installed)
          next
        end
        computed = true unless literal_name_argument?(irep, program, idx, insn)
      end
    end
    stems.merge(probes) if probe_hooks_touched?(ireps, stems)
    [stems, computed]
  end

  # Every write of the name argument reaching the send is a LOADSYM: one non-literal arm of a join makes it computed.
  def self.literal_name_argument?(irep, program, idx, insn)
    writers = insn.plain_fixed_argc? && insn.argc.to_i.positive? &&
              BytecodeIR.reaching_writer_indices(irep, idx, (insn.reg.to_i + 1).to_s)
    writers && writers.all? { |i| program.instruction_at(i).op == 'LOADSYM' } || false
  end

  # Every use of the LOADSYM's value (MOVE aliases and handler edges followed) is the first argument of a plain
  # `respond_to?(name)` / `respond_to?(name, include_all)` send.
  def self.probe_only?(irep, idx, insn)
    uses = FactoryFlow.uses(irep, idx, insn.reg.to_s)
    uses && !uses.empty? && uses.all? do |use, reg|
      send = BytecodeIR.for(irep).source_at(use)
      BytecodeIR::Ops::SEND_FAMILY.include?(send.op) && PROBE_SENDS.include?(send.sym) && send.plain_fixed_argc? &&
        (1..2).cover?(send.argc.to_i) && reg.to_s == (send.reg.to_i + 1).to_s
    end
  end

  # Whether the program could route a probe's name into Ruby: it defines or aliases respond_to? or
  # respond_to_missing?, or spells either as a literal (define_method(:respond_to_missing?), send(:respond_to?, ...)).
  def self.probe_hooks_touched?(ireps, stems)
    return true if PROBE_HOOKS.any? { |name| stems.include?(name) }

    ireps.each_value.any? do |irep|
      found = false
      irep.each_with_op('DEF', 'TDEF', 'SDEF', 'ALIAS') do |insn, _idx|
        names = case insn.op
                when 'ALIAS' then insn.typed.map { |operand| operand.value.to_s }
                when 'DEF' then [insn.sym_token]
                else [insn.sym]
                end
        found ||= names.any? { |n| PROBE_HOOKS.include?(n.to_s) }
      end
      found
    end
  end
end
