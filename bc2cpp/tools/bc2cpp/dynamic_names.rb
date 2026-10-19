# frozen_string_literal: true

require 'set'
require_relative 'bytecode_ir'

# Method names a computed-name send (`send("#{stem}=", v)`, `method(name)`, ...) could reach
# although no call site spells them: the proofs that enumerate call sites (ArgTypes,
# ENTRY_ARG_CALLSITE_PROOF, FIXNUM_RETURN_PROOF, the embedding of ivars a setter writes) refuse
# these names. ADR 0276 introduced the rule for pooled numeric arguments, ADR 0279 shares it.
module DynamicNames
  # Sends that turn a value into a method name (call it, fetch it, define it).
  SENDS = %w[send __send__ public_send method public_method instance_method public_instance_method
             define_method define_singleton_method alias_method attr attr_reader attr_writer
             attr_accessor].freeze

  # Every send op, the splat forms included: they name the method the same way, so the scan must visit them.
  SEND_OPS = (BytecodeIR::Ops::SEND | %w[SENDV SENDVB SSENDV SSENDVB]).freeze

  class << self
    # DEFINE_METHOD_LOOPS (ADR 0469): [irep label, index] of each `define_method(n)` loop send the settled
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
    computed = false
    ireps.each_value do |irep|
      program = BytecodeIR.for(irep)
      program.each_with_op('LOADSYM', 'STRING', *SEND_OPS) do |insn, idx|
        stems << insn.sym if insn.op == 'LOADSYM' && insn.sym
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
    [stems, computed]
  end
end
