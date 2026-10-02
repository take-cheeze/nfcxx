# frozen_string_literal: true

require 'set'

# Method names a computed-name send (`send("#{stem}=", v)`, `method(name)`, ...) could reach
# although no call site spells them: the proofs that enumerate call sites (ArgTypes,
# ENTRY_ARG_CALLSITE_PROOF, FIXNUM_RETURN_PROOF, the embedding of ivars a setter writes) refuse
# these names. ADR 0276 introduced the rule for pooled numeric arguments, ADR 0279 shares it.
module DynamicNames
  # Sends that turn a value into a method name (call it, fetch it, define it).
  SENDS = %w[send __send__ public_send method public_method instance_method public_instance_method
             define_method define_singleton_method alias_method attr attr_reader attr_writer
             attr_accessor].freeze

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
      irep.instructions.each_with_index do |insn, idx|
        stems << insn.sym if insn.op == 'LOADSYM' && insn.sym
        if insn.op == 'STRING'
          entry = irep.pool[insn.pool_index.to_i]
          stems << entry if entry.is_a?(String) && entry.match?(/\A[A-Za-z_]\w*[?!=]?\z/)
        end
        next unless insn.op.include?('SEND') && SENDS.include?(insn.sym)

        literal = insn.plain_fixed_argc? && insn.argc.to_i.positive? &&
                  irep.walk_writers(idx - 1, (insn.reg.to_i + 1).to_s, follow_moves: true) { |w| w.op == 'LOADSYM' }
        computed = true unless literal
      end
    end
    [stems, computed]
  end
end
