# frozen_string_literal: true

require 'set'
require_relative 'bytecode_ir'
require_relative 'native_expression_devirt'

# BLOCK_PARAM_CALL (docs/adr/0274): `blk.call(...)` in a compiled core method where `blk`
# is that method's own `&blk` parameter. The value is nil or a Proc (vm.c ensure_block),
# so the Proc arm of CORE_PROC_CALL is the whole story and its else can only be
# nil's NoMethodError, which bc2cpp_nomethod raises without a cached send.
module BlockParamCall
  # The only classes that register a native `call`; nil shares none of them.
  NATIVE_CALL_OWNERS = %w[Proc Method UnboundMethod].freeze

  # The code for the send, or nil when any part of the proof is missing.
  def block_param_call_code(irep, idx, reg, d, recv, argv)
    return nil unless @compiling_core && irep && idx && reg && argv.size < CodeGen::FUNCALL_ARGC_MAX
    return nil if devirt_blocked_name?('call')
    return nil unless block_param_receiver?(irep, idx, reg.to_s) && block_param_nil_call_dead?

    args = argv.empty? ? '' : ", #{argv.size}, #{argv.join(', ')}"
    "  // BLOCK_PARAM_CALL :call -- receiver is the method's own &block (nil or a Proc): a Proc is " \
      "called as CORE_PROC_CALL does, nil raises NoMethodError\n" \
      "  if (mrb_proc_p(#{recv})) {\n" \
      "    mrb_value bc2cpp_call_argv[] = { #{(argv + ['mrb_nil_value()']).join(', ')} };\n" \
      "    r#{d} = bc2cpp_yield_argv(M, #{recv}, #{argv.size}, bc2cpp_call_argv);\n" \
      "  } else {\n" \
      "    r#{d} = bc2cpp_nomethod_named(M, #{recv}, \"call\"#{args});\n" \
      "  }\n"
  end

  # Every definition of the register at `idx` is the block a method was entered with,
  # in that method or (through GETUPVAR) an enclosing one, and nothing rewrites it.
  def block_param_receiver?(irep, idx, reg)
    return false unless idx.between?(0, irep.instructions.length - 1)

    defs = BytecodeIR.reaching_definitions(irep, idx, reg)
    return false unless defs&.size == 1

    definition = defs.first
    if definition.entry?
      block_param_incoming_slot?(irep, definition.reg)
    else
      insn = irep.instructions[definition.index]
      return false unless insn.op == 'GETUPVAR' && insn.upvar_ref

      slot, level = insn.upvar_ref
      owner = irep
      (level + 1).times { owner &&= block_param_parent(owner) }
      !owner.nil? && block_param_slot_pristine?(owner, slot.to_s)
    end
  end

  # `slot` is where the method `irep` receives its block. An entry definition reaching a
  # read needs nothing more: a rewrite of the slot would be another definition.
  def block_param_incoming_slot?(irep, slot)
    return false unless @owner_of.key?(irep.label)

    enter = irep.enter
    return false unless enter

    mand, opt, rest, post, kw, kwrest, block = enter.enter_fields
    block.to_i.positive? && post.to_i.zero? && kw.to_i.zero? && kwrest.to_i.zero? &&
      slot == (1 + mand + opt + rest).to_s
  end

  # `slot` holds the block the method `irep` was entered with and nothing changes it: the
  # incoming register itself, or the local mrbc copies it to right after ENTER
  # (`MOVE R2 R1 ; R2:blk`). No other instruction, nor a nested block's SETUPVAR, stores to either.
  def block_param_slot_pristine?(irep, slot)
    return false unless @owner_of.key?(irep.label)

    enter = irep.enter
    return false unless enter

    mand, opt, rest, post, kw, kwrest, block = enter.enter_fields
    return false unless block.to_i.positive? && post.to_i.zero? && kw.to_i.zero? && kwrest.to_i.zero?

    incoming = (1 + mand + opt + rest).to_s
    copy = (incoming.to_i + 1).to_s
    return false unless [incoming, copy].include?(slot)

    upvar_written = BytecodeIR.own_upvar_written_regs(irep)
    return false if upvar_written.include?(incoming) || upvar_written.include?(slot)
    return false unless block_param_writers(irep, incoming).empty?
    return true if slot == incoming

    # The copy is made once, before any closure that could read it exists: its MOVE
    # supplies the register on every path to each BLOCK/LAMBDA.
    copies = block_param_writers(irep, copy)
    return false unless copies.size == 1

    move = irep.instructions[copies.first]
    return false unless move.op == 'MOVE' && move.regs[1] == incoming

    return true if copies.first == 1 && irep.instructions[0].op == 'ENTER'

    irep.instructions.each_index.all? do |i|
      !%w[BLOCK LAMBDA].include?(irep.instructions[i].op) || BytecodeIR.write_dominates?(irep, copies.first, i, copy)
    end
  end

  # Indices of the instructions that store to `reg` (any use of it as a leading operand
  # other than the tests that only read it).
  def block_param_writers(irep, reg)
    irep.instructions.each_index.select do |i|
      insn = irep.instructions[i]
      insn.reg == reg && !BytecodeIR::READS_LEADING_REG_OPS.include?(insn.op)
    end
  end

  def block_param_parent(irep)
    @block_param_parents ||= begin
      parents = {}
      @ireps.each_value { |parent| Array(parent.reps).each { |label| parents[label] = parent if label } }
      parents
    end
    @block_param_parents[irep.label]
  end

  # nil is the only non-Proc a block parameter holds, and nothing in the build answers
  # `call` for it: no Ruby definition anywhere (outside sources and dynamic installers
  # included), no method_missing on NilClass, and native `call` only on Proc and Method.
  def block_param_nil_call_dead?
    return @block_param_nil_call_dead unless @block_param_nil_call_dead.nil?

    @block_param_nil_call_dead = compute_block_param_nil_call_dead
  end

  def compute_block_param_nil_call_dead
    world = block_core_world
    return false unless world && @native_name_sources
    return false if symbol_installed_names.nil? || symbol_installed_names.include?('call')
    return false unless world.nil_call_free?('call')
    return false unless (@registry['call'] || []).all? { |definition| definition.owner == '<native>' }

    registrations, opaque = block_core_registrations
    owners = registrations.fetch('call', []).map { |registration| registration[:owner]&.fetch(:class_name, nil) } +
             opaque.fetch('call', [])
    owners.none?(&:nil?) && (owners.uniq - NATIVE_CALL_OWNERS).empty?
  end
end

CodeGen.include(BlockParamCall)
