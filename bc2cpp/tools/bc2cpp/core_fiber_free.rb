# frozen_string_literal: true

require 'set'
require_relative 'bytecode_ir'
require_relative 'bytecode_ir_ops'
require_relative 'core_enumerator_free'

# CORE_FIBER_FREE (closed only): a proof that no Fiber is ever made in the closed build, so the resumable variants of the
# core iterators (RESUMABLE_DUAL, codegen_method.rb), which an entry takes only under a Fiber, never run and are not
# emitted. Fiber.new and Fiber.current are methods of the Fiber class, and a program reaches that class only by naming it:
#
#   - a `Fiber` constant in the Ruby the binary loads, unless it lies in a method that never runs: one the closed build
#     leaves out (core_left_out: no lookup reaches its name, so no code calls it), or one of mruby-enumerator's instance
#     classes when CORE_ENUMERATOR_FREE holds (no instance exists to run it);
#   - a native that spells Fiber (mrb_class_get(M, "Fiber"), MRB_SYM(Fiber));
#   - a constant looked up by a computed name: any `const_get` send, a Symbol `:const_get` that reaches a lookup, or a
#     native that spells const_get outside its registration.
#
# Premises, the closed-list proof's (docs/bc2cpp-unregistered-methods.md): the Ruby the binary runs is the world's own,
# natives look a name up only by spelling it, and every lookup by Symbol takes a literal (StaticDispatchSymbolUses).
module CoreFiberFree
  CONSTANT = 'Fiber'
  CONST_LOOKUPS = %w[const_get].to_set.freeze
  # The class whose instances CORE_FIBER_FREE proves are never made (StaticDispatchLists' unmade_classes).
  UNMADE = [CONSTANT].freeze
  Result = Struct.new(:holds, :unproven, keyword_init: true)

  module_function

  # +inputs+ is CoreEnumeratorFree.inputs of the same world, +enumerator_free+ a callable for whether its proof holds,
  # +left_out+ the "Owner#name" keys of the core methods the build leaves out.
  def prove(inputs, enumerator_free:, left_out: Set.new)
    unproven = []
    [inputs.engine, *inputs.core].each { |g| group_conditions(g, enumerator_free, left_out, unproven) }
    inputs.native_spelled.each do |name, files|
      next unless name == CONSTANT || CONST_LOOKUPS.include?(name)

      unproven << "native text spells #{name} (#{files.first(3).join(', ')})"
    end
    lookups = inputs.symbol_lookups
    if lookups.nil?
      unproven << 'some lookup takes a name that is no Symbol literal'
    else
      (lookups & CONST_LOOKUPS).each { |name| unproven << "Symbol :#{name} reaches a lookup" }
    end
    Result.new(holds: unproven.empty?, unproven: unproven)
  end

  def group_conditions(group, enumerator_free, left_out, unproven)
    group.ireps.each_value do |irep|
      BytecodeIR.for(irep).each_source do |insn, _|
        if %i[GETCONST GETMCNST].include?(insn.op) && insn.const_name.to_s == CONSTANT
          next if !group.engine && left_out.include?(where(group, irep))
          next if enumerator_instance_method?(group, irep) && enumerator_free.call

          unproven << "#{irep.file}:#{insn.lineno} names #{CONSTANT} (#{where(group, irep)})"
        elsif BytecodeIR::Ops::SEND_FAMILY.include?(insn.op) && CONST_LOOKUPS.include?(insn.sym.to_s)
          unproven << "#{irep.file}:#{insn.lineno} calls #{insn.sym} (#{where(group, irep)})"
        end
      end
    end
  end

  # Is +irep+ (a method body or a block in one) in a method of an Enumerator instance class of mruby-enumerator's file?
  def enumerator_instance_method?(group, irep)
    return false unless irep.file.to_s.match?(CoreEnumeratorFree::GROUP_FILE)

    label = group.method_of[irep.label]
    d = label && group.body_of[label]
    !d.nil? && CoreEnumeratorFree::INSTANCE_OWNERS.include?(d.owner)
  end

  def where(group, irep)
    label = group.method_of[irep.label]
    d = label && group.body_of[label]
    d ? "#{d.owner}##{d.name}" : 'load time'
  end
end
