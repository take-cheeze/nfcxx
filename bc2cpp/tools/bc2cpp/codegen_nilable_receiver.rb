# frozen_string_literal: true

require_relative 'nomethod_reviewed'

# NILABLE_RECEIVER (ADR 0296): a receiver the class pools prove is nil or exactly one class K
# (`@ui` holding a Hash literal and nil, `@interpreter` holding an Interpreter and nil) is tested
# for nil once; the non-nil path is compiled as an exact-K receiver, so it needs neither a class
# guard nor a by-name fallback. The nil path is the NoMethodError a nil dereference raises when no
# nil method has the name (nil_unanswerable?), else the ordinary send.
#
# The mask is the flow's (exact_flow_class's), so the proof is the pools' proof, and the
# withdrawal conditions are theirs: see codegen_class_pools.rb.
module NilableReceiverSend
  # Plain SEND/SEND0 only: SENDB carries a block register and SSEND has no receiver.
  NILABLE_OPS = %w[SEND SEND0].freeze
  # An unguarded exact-receiver path: no class test, so a nil test is the cheaper guard.
  EXACT_MARK = %r{^\s*// (?:EXACT_TYPED|CLOSED_WORLD_EXACT_CLASS|NATIVE_EXACT_DIRECT|EXACT_NATIVE_WRAPPER|NATIVE_DIRECT_EXACT|NATIVE_CORE_EXACT|CLOSED_WORLD_NATIVE_EXACT|INDEX_EXACT)\b}

  def compile_send(insn, **kwargs)
    plan = nilable_receiver_plan(insn, kwargs)
    return super unless plan

    recv = "r#{insn.reg}"
    plain = super
    inner = with_nonnil_receiver(plan[:key]) { super }
    return plain if plain.include?('#error') || inner.include?('#error')

    nil_arm = nilable_nil_arm(insn, recv, plan[:name], plan[:argv])
    # Only worth a nil test when the non-nil path sheds dispatches the plain code keeps.
    return plain unless dispatch_count(inner) + dispatch_count(nil_arm) < dispatch_count(plain) ||
                        (EXACT_MARK.match?(inner) && !EXACT_MARK.match?(plain))

    body = inner.lines.map { |line| line.strip.empty? ? line : "  #{line}" }.join
    "  // NILABLE_RECEIVER :#{plan[:name]} -- receiver is nil or exactly #{plan[:klass]} (class pools, ADR 0296)\n" \
      "  if (mrb_nil_p(#{recv})) {\n" \
      "    #{nil_arm}" \
      "  } else {\n" \
      "#{body}" \
      "  }\n"
  end

  # By-name dispatches in a piece of generated C++.
  def dispatch_count(code)
    code.scan(/\bmrb_funcall(?:_id|_with_block|_argv)?\(M,|\bbc2cpp_send\(M,|\bbc2cpp_funcall_argv\(/).size
  end

  # The nil-or-K proof of this send's receiver: { key:, klass:, name:, argv: }, else nil.
  def nilable_receiver_plan(insn, kwargs)
    return nil unless @class_pools_on && @closed_world && NILABLE_OPS.include?(insn.op)
    return nil if kwargs[:self_implicit] || kwargs[:call_receiver] || kwargs[:call_arguments]
    return nil unless kwargs[:trace_reg_offset].to_i.zero?
    return nil if insn.n_spec == '*' || insn.nk_spec

    irep = kwargs[:irep]
    idx = kwargs[:idx]
    return nil unless irep && idx && insn.sym

    n = insn.n_spec.to_i
    return nil if n > CodeGen::FUNCALL_ARGC_MAX

    reg = insn.reg.to_i
    mask = exact_flow_mask(irep, idx, reg)
    return nil unless mask.is_a?(Integer) && mask.anybits?(NumericFlow::NIL)

    klass = return_class_of_mask(mask & ~NumericFlow::NIL)
    return nil unless klass

    { key: [irep.label, idx, reg], klass: klass, name: insn.sym, argv: (1..n).map { |k| "r#{reg + k}" } }
  end

  # What nil does with the call: the NoMethodError its dispatch raises when nothing answers the
  # name (a marked helper, so the site is not a dynamic send), else the dispatch itself.
  def nilable_nil_arm(insn, recv, name, argv)
    d = insn.reg
    return dynamic_dispatch_line(d, recv, name, argv) unless nil_unanswerable?(name)

    args = argv.empty? ? '' : ", #{argv.size}, #{argv.join(', ')}"
    "r#{d} = bc2cpp_nil_receiver_named(M, #{recv}, \"#{name}\"#{args}); #{NomethodReviewed.nil_receiver_marker(name)}\n"
  end
end

CodeGen.prepend(NilableReceiverSend)

# NILABLE_RECEIVER for the index instructions (`@ui[:phase]`, `@ui[:k] = v`): GETIDX, GETIDX0 and
# SETIDX are not sends, so the module above never sees them. An exact Array/Hash receiver takes the
# fast path with no class test (INDEX_EXACT in compile_insn).
module NilableIndexOps
  INDEX_OPS = { 'GETIDX' => '[]', 'GETIDX0' => '[]', 'SETIDX' => '[]=' }.freeze

  def compile_insn(insn, irep, owner_def, idx = nil, reg_offset = 0)
    plan = nilable_index_plan(insn, irep, idx, reg_offset)
    return super unless plan

    inner = with_nonnil_receiver(plan[:key]) { super }
    return inner if inner.include?('#error')

    args = plan[:argv]
    nil_arm = if nil_unanswerable?(plan[:name])
                "r#{plan[:dest]} = bc2cpp_nil_receiver_named(M, #{plan[:recv]}, \"#{plan[:name]}\", #{args.size}, " \
                  "#{args.join(', ')}); #{NomethodReviewed.nil_receiver_marker(plan[:name])}\n"
              else
                "r#{plan[:dest]} = mrb_funcall(M, #{plan[:recv]}, \"#{plan[:name]}\", #{args.size}, #{args.join(', ')});\n"
              end
    body = inner.lines.map { |line| line.strip.empty? ? line : "  #{line}" }.join
    "  // NILABLE_RECEIVER :#{plan[:name]} -- receiver is nil or exactly #{plan[:klass]} (class pools, ADR 0296)\n" \
      "  if (mrb_nil_p(#{plan[:recv]})) {\n" \
      "    #{nil_arm}" \
      "  } else {\n" \
      "#{body}" \
      "  }\n"
  end

  # { key:, klass:, name:, recv:, dest:, argv: } when the receiver register is nil or an exact
  # Array/Hash at this instruction.
  def nilable_index_plan(insn, irep, idx, reg_offset)
    name = INDEX_OPS[insn.op]
    return nil unless name && @class_pools_on && @closed_world && irep && idx

    regs = insn.regs
    dest = regs[0]
    recv_reg = insn.op == 'GETIDX0' ? regs[1] : regs[0]
    proof_reg = unshift_proof_reg(recv_reg, reg_offset)
    return nil unless proof_reg

    mask = exact_flow_mask(irep, idx, proof_reg)
    return nil unless mask.is_a?(Integer) && mask.anybits?(NumericFlow::NIL)

    klass = return_class_of_mask(mask & ~NumericFlow::NIL)
    return nil unless %w[Array Hash].include?(klass)

    argv = case insn.op
           when 'GETIDX' then ["r#{regs[1]}"]
           when 'GETIDX0' then ['mrb_fixnum_value(0)']
           else ["r#{regs[1]}", "r#{regs[2]}"]
           end
    { key: [irep.label, idx, proof_reg.to_i], klass: klass, name: name, recv: "r#{recv_reg}", dest: dest, argv: argv }
  end
end

CodeGen.prepend(NilableIndexOps)
