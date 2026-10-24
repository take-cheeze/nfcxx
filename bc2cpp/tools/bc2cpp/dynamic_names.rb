# frozen_string_literal: true

require 'set'
require_relative 'bytecode_ir'
require_relative 'factory_flow'

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
    computed ? stems | stems.map { |n| "#{n}=" } : stems
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
        # Every write of the name reaching the send must be a LOADSYM: one non-literal arm of a join makes it computed.
        writers = insn.plain_fixed_argc? && insn.argc.to_i.positive? &&
                  BytecodeIR.reaching_writer_indices(irep, idx, (insn.reg.to_i + 1).to_s)
        literal = writers && writers.all? { |i| program.instruction_at(i).op == 'LOADSYM' }
        computed = true unless literal
      end
    end
    stems.merge(probes) if probe_hooks_touched?(ireps, stems)
    [stems, computed]
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
