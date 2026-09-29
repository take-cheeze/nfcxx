# frozen_string_literal: true

# Shared index for analyses that need to visit every call to one method name.
# Build once per bc2cpp invocation rather than rescanning all instructions for
# every monomorphic name.
class CallSiteIndex
  SEND_OPS = %w[SEND0 SEND SSEND0 SSEND].freeze
  NAME_RE = /:([\w+\-*\/<>=!?\[\]&|^~%@]+)/

  def self.build(ireps)
    by_name = Hash.new { |hash, name| hash[name] = [] }
    ireps.each_value do |irep|
      irep.instructions.each_with_index do |insn, idx|
        next unless SEND_OPS.include?(insn.op)

        name = insn.args[NAME_RE, 1]
        next unless name

        dest = insn.reg.to_i
        argc = insn.args[/n=(\d+)/, 1].to_i
        by_name[name] << [irep, idx, dest, argc]
      end
    end
    by_name
  end
end
