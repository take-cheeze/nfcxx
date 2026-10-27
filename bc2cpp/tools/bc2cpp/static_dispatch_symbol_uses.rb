# frozen_string_literal: true

require 'set'
require_relative 'bytecode_ir'

# SYMBOL_USES (closed only): which Symbol literals can name a method that something looks up by that name.
#
# The default proof counts every `:name` literal as a lookup of `name`, since a Symbol can be handed to `send`.
# Most are hash keys, `when` labels and `respond_to?` arguments. A Symbol only names a looked-up method when it
# reaches a method that takes a name (LOOKUP_SENDS: `send`, `method`, `inject(:+)`, `to_enum(:each)`, ...) or the
# block slot of a call (`&:name` runs Symbol#to_proc). `respond_to?` is answered for the methods the closed build
# leaves out of the tables too (RESPOND_TO_PHANTOM, codegen_emit.rb), so it needs no registration.
#
# `lookups` proves that every such use in the closed bytecode takes a literal: each name argument of a
# LOOKUP_SENDS call and each block argument is written only by a literal load (or, for a block, a block literal or
# the caller's own block). Then a Symbol from anywhere else -- a hash key, a variable, a container -- never reaches
# one, and only the literals at those sites name a method. Natives look a method up only by a name they spell
# (NATIVE_NAME_TOKENS), and the core Ruby that forwards a name it was given is reached only through LOOKUP_SENDS.
# INTROSPECTION_SENDS list the methods of a class and so see a missing registration directly; any call of one,
# like an UNDEF (which makes respond_to? false where RESPOND_TO_PHANTOM would answer true), refuses the proof.
module StaticDispatchSymbolUses
  # Methods that look up, or redefine, a method named by an argument; core Ruby (enum.rb's inject, enumerator.rb's
  # each over to_enum's name, symbol.rb's to_proc) included. The attr_* family and the visibility calls only act on
  # methods defined while the program loads, before any compiled registration, and are left out.
  LOOKUP_SENDS = %w[
    send __send__ public_send method public_method singleton_method instance_method public_instance_method
    define_method define_singleton_method remove_method undef_method inject reduce to_enum enum_for instance_eval instance_exec class_eval module_eval class_exec module_exec eval
    method_missing respond_to_missing? to_proc
  ].to_set.freeze
  # Methods whose answer depends on which methods a class has registered.
  INTROSPECTION_SENDS = %w[
    methods public_methods private_methods protected_methods singleton_methods instance_methods
    public_instance_methods private_instance_methods protected_instance_methods method_defined?
    public_method_defined? private_method_defined? protected_method_defined?
  ].to_set.freeze
  # Loads of a value that is no Symbol, or a literal one.
  LITERAL_OPS = (BytecodeIR::Ops::LOADI_OPS | Set[:LOADL, :LOADNIL, :LOADTRUE, :LOADFALSE, :LOADSELF, :STRING,
                                                    :LOADSYM]).freeze
  # What a block argument may be besides a literal: a block or lambda literal, or nil.
  BLOCK_OPS = Set[:BLOCK, :LAMBDA, :LOADNIL].freeze

  module_function

  # The Symbol literals that name a looked-up method, or nil when some lookup may take a Symbol that is not one.
  # `ireps`: label => irep.
  def lookups(ireps)
    names = Set.new
    ireps.each_value do |irep|
      program = BytecodeIR.for(irep)
      program.instructions.each do |ins|
        insn = ins.source
        return nil if insn.op == :UNDEF

        next unless BytecodeIR::Ops::SEND.include?(insn.op)
        return nil if INTROSPECTION_SENDS.include?(insn.sym)

        if LOOKUP_SENDS.include?(insn.sym)
          return nil unless literal_arguments(irep, program, ins.index, insn, names)
        end
        next unless BytecodeIR::Ops::BLOCK_SEND_FAMILY.include?(insn.op)
        return nil unless literal_block(irep, program, ins.index, insn, names)
      end
    end
    names
  end

  # Whether every argument of the call (and its receiver, for to_proc) is a literal; adds the Symbols to `names`.
  def literal_arguments(irep, program, index, insn, names)
    return false if insn.positional_splat? || insn.keyword_splat?

    argc = insn.argc_operand ? insn.argc.to_i : 0
    regs = (1..argc).map { |k| insn.reg.to_i + k }
    regs += (0...insn.keyword_argc.to_i).map { |k| insn.reg.to_i + argc + (2 * k) + 2 } if insn.keyword_arguments?
    regs << insn.reg.to_i if insn.sym == 'to_proc'
    regs.all? do |reg|
      ops = writers(irep, program, index, reg) or next false
      next false unless ops.all? { |op, _| LITERAL_OPS.include?(op) }

      ops.each { |op, sym| names << sym if op == :LOADSYM }
      true
    end
  end

  # Whether the call's block argument is a block literal, nil, the caller's own block, or a Symbol literal (added to
  # `names`).
  def literal_block(irep, program, index, insn, names)
    argc = insn.positional_splat? ? 1 : (insn.argc_operand ? insn.argc.to_i : 0)
    kw = insn.keyword_arguments? ? 2 * insn.keyword_argc.to_i : (insn.keyword_splat? ? 1 : 0)
    ops = writers(irep, program, index, insn.reg.to_i + argc + kw + 1) or return false
    ops.all? do |op, sym|
      names << sym if op == :LOADSYM
      BLOCK_OPS.include?(op) || op == :LOADSYM || op == :block
    end
  end

  # [op, sym] of every definition of `reg` reaching instruction `index`. A value the frame was entered with is
  # [:block, nil] when it is the frame's own block parameter (a Proc: a `&:name` argument became one at the call
  # site) and [:entry, nil] for any other. When the reaching-definition query refuses, the nearest earlier write of
  # `reg` is the one definition if straight-line code (no jump target, only ops writing just their leading register)
  # leads from it to the use.
  def writers(irep, program, index, reg)
    prods = BytecodeIR.producers(irep, index, reg)
    if prods && !prods.empty?
      return prods.map do |p|
        next [entry_kind(program, p.reg), nil] if p.entry?

        src = program.source_at(p.index)
        [src.op, src.sym]
      end
    end

    targets = jump_targets(program)
    j = index
    while j.positive? && !targets.include?(j)
      j -= 1
      prev = program.source_at(j)
      return nil unless BytecodeIR::WRITES_LEADING_REG_OPS.include?(prev.op) || BytecodeIR::Ops::LOADI_OPS.include?(prev.op)
      next unless prev.reg.to_i == reg

      return (LITERAL_OPS | BLOCK_OPS).include?(prev.op) ? [[prev.op, prev.sym]] : nil
    end
    nil
  end

  def entry_kind(program, reg)
    enter = program.instructions.first&.source
    enter&.op == :ENTER && program.send(:enter_slot, enter, reg) == :block ? :block : :entry
  end

  # Indices some instruction other than the one before reaches (a jump, a handler).
  def jump_targets(program)
    @jump_targets ||= {}.compare_by_identity
    @jump_targets[program] ||= program.instructions.each_with_object(Set.new) do |ins, out|
      program.successors_of(ins.index, include_handlers: true).each { |n| out << n unless n == ins.index + 1 }
    end
  end
end
