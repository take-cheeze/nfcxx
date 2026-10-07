# frozen_string_literal: true

require_relative 'codegen_nilable_receiver'
require_relative 'dynamic_names'
require_relative 'numeric_flow'

# CodeGen: SETTER_POOLS and CHECKED_POOL_EXACT (ADR 0370).
#
# The class pools of ADR 0295 refuse an ivar an attr_writer or an audited native writes (the value is the
# caller's) and a setter's parameter whenever its name has several definitions. Every way to call `x=` is a
# send named `x=`, so the one fact those stores need is the join of the class sets of the argument at every
# such send (setter_pool_reads), under the same name rules as ENTRY_ARG_CALLSITE_PROOF plus: no native
# call spells the name (a registration is not a call), no definition of it calls `super`, every Ruby
# definition takes exactly one mandatory argument.
#
# The pools this builds carry NumericFlow::CHECKED, which no unguarded decoder accepts (each reads a class
# only from a mask equal to one class bit). The one reader is CHECKED_POOL_EXACT: a SEND whose receiver is nil
# or one class K by such a pool is compiled as an exact-K call behind a class test whose else is
# bc2cpp_guard_violation (ADR 0290, 0359), so a writer the scan missed is a loud error and never an
# unchecked call. BC2CPP_SETTER_POOLS=0 restores the earlier output byte for byte.
class CodeGen
  SETTER_POOL_NAME = /\A[A-Za-z_]\w*=\z/

  def setter_pools_enabled?
    return false if ENV.fetch('BC2CPP_SETTER_POOLS', '1') == '0'

    @class_pools_on && @closed_world && @closed_world.global_refusal.nil? && NomethodReviewed.guard_violation_enabled?
  end

  # [[irep, idx, register]] of the argument of every call of +setter+, or nil when the name is not admitted
  # (setter_pool_refusal says why).
  def setter_pool_reads(setter)
    @setter_pool_reads ||= {}
    return @setter_pool_reads[setter] if @setter_pool_reads.key?(setter)

    @setter_pool_reads[setter] = if setter_pool_refusal(setter)
                                   nil
                                 else
                                   entry_arg_call_index.first[setter].map { |(irep, idx, recv, _argc, _owner)| [irep, idx, (recv + 1).to_s] }
                                 end
  end

  # nil when every call of +setter+ is a visible one-argument send and every definition takes the value
  # without forwarding it, else the first rule that fails.
  def setter_pool_refusal(setter)
    @setter_pool_refusal ||= {}
    return @setter_pool_refusal[setter] if @setter_pool_refusal.key?(setter)

    @setter_pool_refusal[setter] = compute_setter_pool_refusal(setter)
  end

  def compute_setter_pool_refusal(setter)
    return :disabled unless setter_pools_enabled?
    return :not_setter unless setter.match?(SETTER_POOL_NAME)
    return :no_scan unless @foreign_method_names && @outside_tokens

    stem = setter.chomp('=')
    sites, poisoned = entry_arg_call_index
    return :poisoned if poisoned.include?(setter)
    return :spelled_name if setter_spelled_as_literal?(setter)
    return :foreign_definition if @foreign_method_names.include?(setter)
    return :unknown_definition if @closed_world.unknown_def?(setter)
    return :outside_call if setter_called_outside?(setter, stem)

    here = sites[setter]
    return :no_sites if here.empty?
    return :argument_count unless here.all? { |(_irep, _idx, _recv, argc, _owner)| argc == 1 }

    definitions = @registry[setter] || []
    return :no_definition if definitions.empty?

    setter_definition_refusal(definitions)
  end

  # The program spells `x=` as a String (a Symbol is a poisoned name already): evidence of a by-name call the sites
  # do not show. numeric_dynamically_named? would also refuse every `x=` once any send takes a computed name (mruby's
  # Symbol#to_proc does); that clause is a precision rule for the unchecked proofs. A composed name that stores
  # outside the pool is a guard violation at the reader (scripts/bc2cpp_setter_pools_check.rb).
  def setter_spelled_as_literal?(setter)
    @setter_literal_names ||= DynamicNames.analyze(@ireps).first
    @setter_literal_names.include?(setter)
  end

  # A native funcall or a foreign Ruby identifier names it, or an outside native source spells it as anything but a
  # registration's name (ClosedWorld#record_native_other_literals).
  def setter_called_outside?(setter, stem)
    @setter_outside_names ||= @closed_world.outside_call_names(@ireps.values.to_set(&:file))
    @setter_outside_names.include?(setter) || @setter_outside_names.include?(stem) ||
      @closed_world.outside_native_literal?(setter)
  end

  def setter_definition_refusal(definitions)
    definitions.each do |d|
      next if d.irep.nil?
      return :installed_body if d.installer || d.copy_irep

      irep = @ireps[d.irep]
      return :no_body unless irep
      return :arity unless pure_mandatory_arity?(irep) && mandatory_arity(irep) == 1
      return :super if irep_tree_op?(irep, 'SUPER')
    end
    nil
  end

  def irep_tree_op?(irep, op)
    stack = [irep]
    seen = Set.new
    until stack.empty?
      cur = stack.pop
      next unless cur && seen.add?(cur.label)
      return true if cur.instructions.any? { |insn| insn.op == op }

      cur.reps.each { |label| stack << @ireps[label] }
    end
    false
  end

  # The stores an ivar group's class pool may account for by setter calls and audited natives instead of
  # refusing the group, or nil. Every setter must be admitted.
  def checked_group_stores(group)
    return nil unless setter_pools_enabled? && group.structural && group.checked
    return nil if group.checked[:setters].any? { |setter| setter_pool_reads(setter).nil? }

    group.checked
  end

  def checked_group_reads(group)
    group.checked[:setters].flat_map { |setter| setter_pool_reads(setter) }
  end

  # [irep label, 1] => the argument reads of a Ruby setter definition the argument pools do not already hold.
  def setter_arg_candidates
    @setter_arg_candidates ||= begin
      found = {}
      if setter_pools_enabled?
        @registry.each do |name, definitions|
          next unless name.match?(SETTER_POOL_NAME) && (reads = setter_pool_reads(name))

          definitions.each do |d|
            next unless d.irep && !(@entry_cand || {}).key?([d.irep, 1])

            found[[d.irep, 1]] = reads
          end
        end
      end
      found
    end
  end

  # -- CHECKED_POOL_EXACT -------------------------------------------------------------------------------------------

  # The receiver of this SEND is nil or one non-core class by a checked pool: { key:, klass:, name:, argv:, nilable: }.
  def checked_pool_plan(insn, kwargs)
    return nil unless @checked_pools_used && @class_pools_on && @closed_world && NilableReceiverSend::NILABLE_OPS.include?(insn.op)
    return nil if kwargs[:self_implicit] || kwargs[:call_receiver] || kwargs[:call_arguments] || !kwargs[:trace_reg_offset].to_i.zero?
    return nil if insn.n_spec == '*' || insn.nk_spec

    irep = kwargs[:irep]
    idx = kwargs[:idx]
    return nil unless irep && idx && insn.sym

    n = insn.n_spec.to_i
    return nil if n > CodeGen::FUNCALL_ARGC_MAX

    reg = insn.reg.to_i
    mask = exact_flow_mask(irep, idx, reg)
    return nil unless mask.is_a?(Integer) && mask.anybits?(NumericFlow::CHECKED)

    klass = return_class_name_of_bit(mask & ~(NumericFlow::NIL | NumericFlow::CHECKED))
    return nil unless klass && !RETURN_CORE_CLASS.value?(klass)

    { key: [irep.label, idx, reg], klass: klass, name: insn.sym, argv: (1..n).map { |k| "r#{reg + k}" },
      nilable: mask.anybits?(NumericFlow::NIL) }
  end

  def with_checked_pool_class(plan)
    previous = @checked_pool_override
    @checked_pool_override = plan
    yield
  ensure
    @checked_pool_override = previous
  end

  def checked_pool_class_expr(klass)
    accessor = NATIVE_WRAPPER_CLASS_ACCESSORS[klass]
    accessor ? "rgss::#{accessor}()" : owner_class_ptr_expr(klass)
  end
end

module CheckedPoolReceiverSend
  def compile_send(insn, **kwargs)
    plan = checked_pool_plan(insn, kwargs)
    return super unless plan

    recv = "r#{insn.reg}"
    plain = super
    inner = with_checked_pool_class(plan) { super }
    return plain if plain.include?('#error') || inner.include?('#error')

    nil_arm = plan[:nilable] ? nilable_nil_arm(insn, recv, plan[:name], plan[:argv]) : ''
    return plain unless NilableReceiverSend::EXACT_MARK.match?(inner) &&
                        dispatch_count(inner) + dispatch_count(nil_arm) < dispatch_count(plain)

    body = inner.lines.map { |line| line.strip.empty? ? line : "    #{line}" }.join
    violation = guard_violation_line(insn.reg, recv, plan[:name], plan[:argv], 'CHECKED_POOL_EXACT')
    nil_test = plan[:nilable] ? "if (mrb_nil_p(#{recv})) {\n    #{nil_arm}  } else " : ''
    "  // CHECKED_POOL_EXACT :#{plan[:name]} -- receiver is #{plan[:nilable] ? 'nil or ' : ''}exactly #{plan[:klass]} by a checked " \
      "setter-site pool (ADR 0370); a class miss is a guard violation\n" \
      "  #{nil_test}if (mrb_obj_class(M, #{recv}) == #{checked_pool_class_expr(plan[:klass])}) {\n" \
      "#{body}" \
      "  } else {\n" \
      "    #{violation}" \
      "  }\n"
  end
end

CodeGen.prepend(CheckedPoolReceiverSend)
