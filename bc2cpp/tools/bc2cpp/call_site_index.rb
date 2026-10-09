# frozen_string_literal: true

# Shared index for analyses that need to visit every call to one method name.
# Build once per bc2cpp invocation rather than rescanning all instructions for
# every monomorphic name.
class CallSiteIndex
  SEND_OPS = %w[SEND0 SEND SENDB SSEND0 SSEND SSENDB].freeze
  # OP_SUPER (vm.c) is `goto L_SENDB_SYM` with mid = ci->mid, the ENCLOSING method's name, and the
  # same a/c operand layout as SENDB (args at R[a+1..], count c). It has no :name operand, so
  # `build` keys it by the name of the nearest enclosing `def` body. Without it the one `def set` a
  # `Class.new(A) { def set(x) = super("s") }` super call reaches (that def is in a block, so not
  # in the registry: `set` stays MONO) would look fed by its direct callers only.
  SUPER_OP = 'SUPER'
  NAME_RE = /:([\w+\-*\/<>=!?\[\]&|^~%@]+)/

  def self.build(ireps)
    by_name = Hash.new { |hash, name| hash[name] = [] }
    super_names = nil
    ireps.each_value do |irep|
      irep.each_with_op(*SEND_OPS, SUPER_OP) do |insn, idx|
        name = insn.op == SUPER_OP ? (super_names ||= enclosing_def_names(ireps))[irep.label] : insn.sym
        next unless name

        dest = insn.reg.to_i
        # A packed send (`f(*a)`, n=*, vm.c CALL_MAXARGS) has no count: nil, so no consumer reads it as 0 args.
        argc = insn.n_spec == '*' || (insn.nk_spec && insn.nk_spec != '0') ? nil : insn.argc.to_i
        by_name[name] << [irep, idx, dest, argc]
      end
    end
    by_name
  end

  # irep label -> name of its nearest enclosing `def` body (the irep itself when it is one), from the
  # def instructions themselves (TDEF, SDEF, METHOD+DEF) rather than the registry, which omits defs
  # inside blocks. Unresolvable (a block never under a `def`, e.g. `define_method(:n) { super }`): no
  # entry, and that name is a DynamicNames literal, which the joins already refuse.
  def self.enclosing_def_names(ireps)
    body_name = {}
    parent = {}
    ireps.each_value do |irep|
      (irep.reps || []).each { |child| parent[child] = irep.label }
      irep.instructions.each_with_index do |insn, idx|
        case insn.op
        when 'TDEF', 'SDEF'
          child = irep.reps[insn.block_index]
          body_name[child] = insn.sym if child && insn.sym
        when 'DEF'
          mi = irep.previous_real_index(idx - 1)
          meth = mi >= 0 ? irep.instructions[mi] : nil
          next unless meth && meth.op == 'METHOD' && insn.paren_reg == meth.reg

          child = irep.reps[meth.block_index]
          body_name[child] = insn.sym if child && insn.sym
        end
      end
    end
    ireps.each_key.each_with_object({}) do |label, out|
      up = label
      up = parent[up] until up.nil? || body_name.key?(up)
      out[label] = body_name[up] if up
    end
  end
end
