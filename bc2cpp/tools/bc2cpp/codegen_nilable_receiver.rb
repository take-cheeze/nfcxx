# frozen_string_literal: true

require_relative 'nomethod_reviewed'

# NILABLE_RECEIVER: a receiver the class pools prove is nil or exactly one class K
# (`@ui` holding a Hash literal and nil, `@interpreter` holding an Interpreter and nil) is tested
# for nil once; the non-nil path is compiled as an exact-K receiver, so it needs neither a class
# guard nor a by-name fallback. The nil path is the NoMethodError a nil dereference raises when no
# nil method has the name (nil_unanswerable?), else the ordinary send.
#
# The mask is the flow's (exact_flow_class's), so the proof is the pools' proof, and the
# withdrawal conditions are theirs: see codegen_class_pools.rb.
module NilableReceiverSend
  # Plain SEND/SEND0 only: SENDB carries a block register and SSEND has no receiver.
  NILABLE_OPS = %i[SEND SEND0].freeze
  # An unguarded exact-receiver path: no class test, so a nil test is the cheaper guard.
  EXACT_MARK = %r{^\s*// (?:EXACT_TYPED|CLOSED_WORLD_EXACT_CLASS|NATIVE_EXACT_DIRECT|EXACT_NATIVE_WRAPPER|NATIVE_DIRECT_EXACT|NATIVE_CORE_EXACT|CLOSED_WORLD_NATIVE_EXACT|INDEX_EXACT)\b}

  def compile_send(insn, kwargs)
    plan = nilable_receiver_plan(insn, kwargs)
    return super unless plan

    recv = "r#{insn.reg}"
    plain = super
    inner = with_nonnil_receiver(plan[:key]) { super }
    return plain if plain.include?('#error') || inner.include?('#error')

    nil_arm = nilable_nil_arm(insn, recv, plan[:name], plan[:argv])
    # Only worth a nil test when the non-nil path sheds dispatches the plain code keeps, or when the
    # receiver is nil-or-Array and the nil arm does not dispatch by name (nil answers `inspect`, so its arm
    # would add a send): the non-nil path is then the Array push itself, with no class guard.
    return plain unless (plan[:klass] == 'Array' && dispatch_count(nil_arm).zero?) ||
                        dispatch_count(inner) + dispatch_count(nil_arm) < dispatch_count(plain) ||
                        (EXACT_MARK.match?(inner) && !EXACT_MARK.match?(plain)) ||
                        fewer_class_tests?(plain, inner, nil_arm)

    body = inner.lines.map { |line| line.strip.empty? ? line : "  #{line}" }.join
    "  // NILABLE_RECEIVER :#{plan[:name]} -- receiver is nil or exactly #{plan[:klass]} (class pools, ADR 0296)\n" \
      "  if (mrb_nil_p(#{recv})) {\n" \
      "    #{nil_arm}" \
      "  } else {\n" \
      "#{body}" \
      "  }\n"
  end

  # NILABLE_CLASS_TESTS: the nil test replaces a class-test chain (POLY_SMALL_N on a nil-or-K receiver whose
  # fallback raises, so it has no dispatch to shed) when the non-nil path tests fewer classes and neither arm adds a
  # dispatch. BC2CPP_NILABLE_CLASS_TESTS=0 keeps the dispatch-only rule.
  def fewer_class_tests?(plain, inner, nil_arm)
    return false if ENV['BC2CPP_NILABLE_CLASS_TESTS'] == '0'
    return false if dispatch_count(inner) + dispatch_count(nil_arm) > dispatch_count(plain)

    class_test_count(inner) + class_test_count(nil_arm) < class_test_count(plain)
  end

  # Runtime class tests in a piece of generated C++: a class read, or a compare against the hoisted one.
  def class_test_count(code)
    code.scan(/\bbc2cpp_(?:obj_class|class_is)\(M,|== bc2cpp_recv_class\b/).size
  end

  # By-name dispatches in a piece of generated C++.
  def dispatch_count(code)
    # OUTSIDE_OWNER_CALL: the owner call still looks the method up at run time, so a variant that removes it
    # is preferred exactly as one that removes a by-name send.
    code.scan(/\bmrb_funcall(?:_id|_with_block|_argv)?\(M,|\bbc2cpp_send\(M,|\bbc2cpp_funcall_argv\(|\bbc2cpp_owner_call(?:_named)?\(M,/).size
  end

  # The nil-or-K proof of this send's receiver: { key:, klass:, name:, argv: }, else nil.
  def nilable_receiver_plan(insn, kwargs)
    return nil unless @class_pools_on && @closed_world && NILABLE_OPS.include?(insn.op)
    return nil if kwargs[:self_implicit] || kwargs[:call_receiver] || kwargs[:call_arguments]
    return nil if insn.positional_splat? || insn.keyword_arguments?

    irep = kwargs[:irep]
    # An inlined send has no instruction index of its own: its source index and register are the
    # ones compile_send's proof uses(trace_idx, and the register unshifted by trace_reg_offset).
    idx = kwargs[:idx] || kwargs[:trace_idx]
    return nil unless irep && idx && insn.sym

    proof_reg = unshift_proof_reg(insn.reg, kwargs[:trace_reg_offset].to_i)&.to_i
    return nil unless proof_reg

    n = insn.argc.to_i
    return nil if n > CodeGen::FUNCALL_ARGC_MAX

    reg = insn.reg.to_i
    mask = exact_flow_mask(irep, idx, proof_reg)
    return nil unless mask.is_a?(Integer) && mask.anybits?(NumericFlow::NIL)

    klass = return_class_of_mask(mask & ~NumericFlow::NIL) || nilable_union_label(mask & ~NumericFlow::NIL)
    return nil unless klass

    { key: [irep.label, idx, proof_reg], klass: klass, name: insn.sym, argv: (1..n).map { |k| "r#{reg + k}" } }
  end

  # NILABLE_UNION: nil or one of a few exact program classes. The non-nil arm is compiled with the nil bit stripped,
  # where exact_flow_user_union_plan can take the class set. BC2CPP_NILABLE_UNION=0 keeps such receivers plain.
  def nilable_union_label(mask)
    return nil if ENV['BC2CPP_NILABLE_UNION'] == '0' || ENV['BC2CPP_USER_RECEIVER_UNIONS'] == '0'

    bits = numeric_receiver_class_bits(mask)
    return nil unless bits && bits.size >= 2

    names = bits.map { |bit| return_class_name_of_bit(bit) }
    names.all? ? names.join(' | ') : nil
  end

  # GETIDX / SETIDX: an index on a receiver the flow leaves nilable, with no nil check dominating it (a
  # `return unless x`, `if x` or `x&.` narrows the register out of the mask first). Recorded once per site, for the
  # type check (TC1005). `reg` is the receiver register as exact_flow_mask reads it.
  def note_unguarded_index(irep, idx, insn, reg, name)
    return unless @class_pools_on && @closed_world && irep && idx

    mask = exact_flow_mask(irep, idx, reg)
    return unless mask.is_a?(Integer) && mask.anybits?(NumericFlow::NIL)

    @unguarded_index ||= {}
    defn = numeric_irep_owner[irep.label]
    @unguarded_index[[irep.label, insn.lineno, name]] ||= {
      file: irep.file, line: insn.lineno, name: name, owner: defn&.owner, method: defn&.name
    }
  end

  def unguarded_index_sites
    (@unguarded_index || {}).values
  end

  # What nil does with the call: the NoMethodError its dispatch raises when nothing answers the
  # name (a marked helper, so the site is not a dynamic send), else the dispatch itself.
  def nilable_nil_arm(insn, recv, name, argv)
    d = insn.reg
    folded = argv.empty? && nil_native_fold(name, "r#{d}")
    return folded if folded
    return dynamic_dispatch_line(d, recv, name, argv) unless nil_unanswerable?(name)

    args = argv.empty? ? '' : ", #{argv.size}, #{argv.join(', ')}"
    "r#{d} = bc2cpp_nil_receiver_named(M, #{recv}, \"#{name}\"#{args}); #{NomethodReviewed.nil_receiver_marker(name)}\n"
  end
end

# NIL_NATIVE_FOLD: what NilClass's own native answers for a zero-argument name, as the C expression its body
# returns (mruby src/object.c nil_rom_entries, mruby-object-ext nil_ext_rom_entries). `to_f` needs floats.
module NilNativeFold
  BODIES = {
    'nil?' => ['mrb_true_value()'],
    'to_s' => ['mrb_str_new_frozen(M, NULL, 0)', :ascii],
    'inspect' => ['mrb_str_new_lit_frozen(M, "nil")', :ascii],
    'to_a' => ['mrb_ary_new(M)'],
    'to_h' => ['mrb_hash_new(M)'],
    'to_i' => ['mrb_fixnum_value(0)'],
    'to_f' => ['mrb_float_value(M, 0.0)', :float]
  }.freeze

  # The statement folding `nil.name` into +dest+, or nil. Only when nil's lookup of the name ends at NilClass's own
  # native: no Ruby definition on a nil ancestor (program, foreign or installed by name), no method_missing there, and
  # the build's native sources register the name on NilClass (nil_native_owner?). BC2CPP_NIL_NATIVE_FOLD=0 turns it off.
  def nil_native_fold(name, dest)
    body, flag = BODIES[name]
    return nil unless body && ENV['BC2CPP_NIL_NATIVE_FOLD'] != '0' && nil_native_owner?(name)

    code = "#{dest} = #{body};"
    code += " RSTR_SET_ASCII_FLAG(mrb_str_ptr(#{dest}));" if flag == :ascii
    code = "\n#ifndef MRB_NO_FLOAT\n  #{code}\n#endif\n" if flag == :float
    "#{code} /* NIL_NATIVE_FOLD nil.#{name} */\n"
  end

  def nil_native_owner?(name)
    @nil_native_owner ||= {}
    return @nil_native_owner[name] if @nil_native_owner.key?(name)

    @nil_native_owner[name] = compute_nil_native_owner(name)
  end

  # nil_unanswerable_refusal's checks with one answer allowed: a native registration on NilClass itself, which nil's
  # lookup reaches first. Any other nil-ancestor owner (or an unresolved one) refuses.
  def compute_nil_native_owner(name)
    world = block_core_world
    installed = symbol_installed_names
    return false unless world && installed && !installed.include?(name)
    return false unless world.nil_foreign_definition_free?(name, nil_ancestor_modules.to_a)
    return false if (world.method_missing_classes.to_a & nil_ancestor_modules.to_a).any?
    return false if (@registry[name] || []).any? { |definition| nil_ancestor_modules.include?(definition.owner) }

    on_nil = false
    world.native_paths_spelling(name).each do |path|
      registrations, opaque = NativeExpressionDevirt.path_registrations(path)
      owners = registrations.fetch(name, []).map { |entry| entry[:owner]&.fetch(:class_name, nil) } + opaque.fetch(name, [])
      return false if owners.any?(&:nil?)
      return false if owners.any? { |owner| owner != 'NilClass' && nil_ancestor_modules.include?(owner) && owner_before_nil?(owner) }

      on_nil ||= owners.include?('NilClass')
    end
    on_nil
  end

  # A module prepended to NilClass is looked up before it; nothing else on nil's chain is.
  def owner_before_nil?(owner)
    Array(@prepended_modules['NilClass']).include?(owner)
  end
end

CodeGen.prepend(NilableReceiverSend)
CodeGen.include(NilNativeFold)

# NILABLE_RECEIVER for the index instructions (`@ui[:phase]`, `@ui[:k] = v`): GETIDX, GETIDX0 and
# SETIDX are not sends, so the module above never sees them. An exact Array/Hash receiver takes the
# fast path with no class test (INDEX_EXACT in compile_insn).
module NilableIndexOps
  INDEX_OPS = { :GETIDX => '[]', :GETIDX0 => '[]', :SETIDX => '[]=' }.freeze

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
    recv_reg = insn.op == :GETIDX0 ? regs[1] : regs[0]
    proof_reg = unshift_proof_reg(recv_reg, reg_offset)
    return nil unless proof_reg

    mask = exact_flow_mask(irep, idx, proof_reg)
    return nil unless mask.is_a?(Integer) && mask.anybits?(NumericFlow::NIL)

    klass = return_class_of_mask(mask & ~NumericFlow::NIL)
    return nil unless %w[Array Hash].include?(klass)

    argv = case insn.op
           when :GETIDX then ["r#{regs[1]}"]
           when :GETIDX0 then ['mrb_fixnum_value(0)']
           else ["r#{regs[1]}", "r#{regs[2]}"]
           end
    { key: [irep.label, idx, proof_reg.to_i], klass: klass, name: name, recv: "r#{recv_reg}", dest: dest, argv: argv }
  end
end

CodeGen.prepend(NilableIndexOps)
