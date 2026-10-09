# frozen_string_literal: true

# Shared index for analyses that need to visit every call to one method name.
# Build once per bc2cpp invocation rather than rescanning all instructions for
# every monomorphic name.
class CallSiteIndex
  SEND_OPS = %w[SEND0 SEND SENDB SSEND0 SSEND SSENDB].freeze
  NAME_RE = /:([\w+\-*\/<>=!?\[\]&|^~%@]+)/

  def self.build(ireps)
    by_name = Hash.new { |hash, name| hash[name] = [] }
    ireps.each_value do |irep|
      irep.each_with_op(*SEND_OPS) do |insn, idx|
        name = insn.sym
        next unless name

        dest = insn.reg.to_i
        # A packed send (`f(*a)`, n=*, vm.c CALL_MAXARGS) has no count: nil, so no consumer reads it as 0 args.
        argc = insn.n_spec == '*' ? nil : insn.argc.to_i
        by_name[name] << [irep, idx, dest, argc]
      end
    end
    by_name
  end
end
