# frozen_string_literal: true

# RESPOND_TO_FOLD: `recv.respond_to?(:name)` with a Symbol literal is answered from the closed world's definitions
# instead of a call to Kernel#respond_to?, whose miss looks the name up, then respond_to_missing?, then the left-out
# table (RESPOND_TO_PHANTOM).
#
# It needs the conditions of the CLASS_NARROWING respond_to? test (class_test_name_safe?, respond_to_missing_absent?):
# mruby's own respond_to? is the only one and answers whether the receiver's class reaches a definition, visibility
# ignored. Per receiver class:
#   - false when no definition can reach an instance of it (class_test_responds_verdict, CallFacts::Answers#answers?);
#   - for a user class whose lookup ends at a Ruby `def` of the registry or at nothing (respond_to_fold_exact): true
#     when a Ruby owner of the name sits on its lookup path, false when none does.
# A receiver whose class set the flow names folds to a constant when the classes agree, else to a class switch. An
# unnamed receiver folds when every class that may answer (Answers#members) has an answer: the fold is then
# membership in the classes that answer true. Anything else keeps the call. A verify build (BC2CPP_UNREGISTERED_VERIFY) also makes the
# call and aborts when the answers differ. BC2CPP_RESPOND_TO_FOLD=0 keeps every call.
module RespondToFold
  def compile_send(insn, kwargs)
    folded = insn.sym == 'respond_to?' && respond_to_fold(insn, kwargs)
    return super unless folded

    expr, why = folded
    d = insn.reg
    @respond_to_fold_count = (@respond_to_fold_count || 0) + 1
    "  // RESPOND_TO_FOLD :#{respond_to_fold_name(insn, kwargs)} -- #{why}\n" \
      "#ifdef BC2CPP_UNREGISTERED_VERIFY\n" \
      "  {\n  mrb_bool bc2cpp_rtf = #{expr};\n#{super}" \
      "  if (bc2cpp_rtf != mrb_test(r#{d})) {\n" \
      "    fprintf(stderr, \"bc2cpp: RESPOND_TO_FOLD: folded %d, respond_to? said %d\\n\", (int)bc2cpp_rtf, (int)mrb_test(r#{d}));\n" \
      "    abort();\n  }\n  }\n" \
      "#else\n" \
      "  r#{d} = mrb_bool_value(#{expr});\n" \
      "#endif\n"
  end

  attr_reader :respond_to_fold_count

  private

  def respond_to_fold(insn, kwargs)
    return nil if ENV['BC2CPP_RESPOND_TO_FOLD'] == '0' || @clean_probe
    return nil unless insn.op == :SEND && insn.argc.to_i == 1 && !insn.positional_splat? && !insn.keyword_arguments?
    return nil if kwargs[:call_receiver] || kwargs[:call_arguments] || kwargs[:self_implicit] || @call_block_expr
    return nil unless class_narrowing_enabled? && class_test_name_safe?('respond_to?') && respond_to_missing_absent?

    irep = kwargs[:irep]
    idx = kwargs[:idx] || kwargs[:trace_idx]
    return nil unless irep && idx

    original = BytecodeIR.for(irep).source_at(idx)
    return nil unless original && original.op == :SEND && original.sym == 'respond_to?'

    meth = respond_to_fold_name(insn, kwargs)
    return respond_to_fold_miss(irep, idx, meth, 'not a Symbol literal') unless meth.is_a?(String)
    return respond_to_fold_miss(irep, idx, meth, respond_to_fold_unbounded(meth)) if respond_to_fold_unbounded(meth)

    recv = "r#{insn.reg}"
    mask = exact_flow_mask(irep, idx, original.reg.to_i)
    named = mask.is_a?(Integer) && mask.positive? ? respond_to_fold_named(mask, meth, recv) : nil
    named || respond_to_fold_members(meth, recv) ||
      respond_to_fold_miss(irep, idx, meth, "receiver #{mask.is_a?(Integer) ? class_mask_name(mask) : '-'}; " \
                                            "#{respond_to_fold_members_refusal(meth)}")
  end

  # BC2CPP_RESPOND_TO_FOLD_REPORT=<path>: one TSV row per respond_to? site left as a call (irep, index, name, why).
  def respond_to_fold_miss(irep, idx, meth, why)
    path = ENV['BC2CPP_RESPOND_TO_FOLD_REPORT']
    File.open(path, 'a') { |f| f.puts([irep.label, idx, meth, why].join("\t")) } if path && !path.empty?
    nil
  end

  def respond_to_fold_members_refusal(meth)
    answers = call_facts_answers
    members = answers.members(meth)
    return 'members unbounded' if members.nil?
    return 'a class object may answer' if members.include?(CallFacts::CLASS_OBJECT)

    unsure = members.select { |klass| respond_to_fold_exact(klass, meth).nil? }.to_a.sort
    unless unsure.empty?
      shown = unsure.first(4).map { |klass| "#{klass}(#{respond_to_fold_definite_refusal(klass, meth)})" }
      return "not sure for #{shown.join(', ')}#{unsure.size > 4 ? ", +#{unsure.size - 4}" : ''}"
    end

    'members have no class bits'
  end

  def respond_to_fold_name(insn, kwargs)
    irep = kwargs[:irep]
    idx = kwargs[:idx] || kwargs[:trace_idx]
    return nil unless irep && idx

    original = BytecodeIR.for(irep).source_at(idx)
    irep.walk_dominating_writers(idx - 1, original.reg.to_i + 1, use: idx, follow_moves: true) do |writer|
      writer.sym if writer.op == :LOADSYM
    end
  end

  # nil when every definition of +meth+ is named (no hook name, unknown definer or computed install), else why not.
  def respond_to_fold_unbounded(meth)
    return 'a hook name' if CallFacts::HOOK_NAMES.include?(meth)
    return 'an unknown def' if @closed_world.unknown_def?(meth)

    installed = symbol_installed_names
    return 'installed by computed code' if installed.nil? || installed.include?(meth)

    call_facts_answers.definers(meth).nil? ? 'definers unbounded' : nil
  end

  # [expression, reason] for a receiver whose every class bit the flow names, or nil.
  def respond_to_fold_named(mask, meth, recv)
    yes = 0
    rest = mask
    bits = CodeGen::CLASS_TEST_CORE_BITS.merge((@numeric_class_bits || {}).to_h { |klass, bit| [bit, klass] })
    bits.each do |bit, klass|
      next unless mask.anybits?(bit)

      rest &= ~bit
      verdict = respond_to_fold_verdict(klass, meth)
      return nil if verdict.nil?

      yes |= bit if verdict
    end
    return nil unless rest.zero?
    return ['false', "no class of the receiver (#{class_mask_name(mask)}) reaches a definition"] if yes.zero?
    return ['true', "every class of the receiver (#{class_mask_name(mask)}) defines it in Ruby"] if yes == mask

    member = class_narrowing_membership(yes, recv)
    member && ["(#{member})", "the receiver (#{class_mask_name(mask)}) answers when it is #{class_mask_name(yes)}"]
  end

  # [expression, reason] for any receiver, from every class that may answer (a superset: Answers matches names by
  # their last segment), or nil.
  def respond_to_fold_members(meth, recv)
    answers = call_facts_answers
    members = answers.members(meth)
    return nil if members.nil? || members.include?(CallFacts::CLASS_OBJECT)

    verdicts = members.to_h { |klass| [klass, respond_to_fold_exact(klass, meth)] }
    return nil if verdicts.value?(nil)

    yes = verdicts.select { |_, v| v }.keys.sort
    return ['false', 'no class reaches a definition'] if yes.empty?

    bits = yes.reduce(0) { |mask, klass| mask | numeric_class_bit(klass) }
    member = class_narrowing_membership(bits, recv)
    member && ["(#{member})", "only #{yes.join(', ')} define it (in Ruby)"]
  end

  # true, false, or nil when the closed world does not say, for an instance of exactly +klass+.
  def respond_to_fold_verdict(klass, meth)
    return false if class_test_responds_verdict(klass, meth) == false

    respond_to_fold_exact(klass, meth)
  end

  def respond_to_fold_definite_refusal(klass, meth)
    answers = call_facts_answers
    return 'undeclared' unless @closed_world.class_declared?(klass)
    return 'not an instance class' unless @closed_world.instance_class?(klass)
    return 'touched' unless answers.user_instance?(klass)
    return 'not resolved in Ruby' unless answers.resolves_in_ruby?(klass, meth)

    'no lookup path'
  end

  # The answer for an instance of exactly +klass+, a user class (Answers#user_instance?) whose lookup of +meth+ ends at
  # a Ruby `def` of the registry or at nothing (Answers#resolves_in_ruby?, which judges full names): true when a
  # Ruby owner sits on its lookup path, false when none does. nil when the closed world does not say.
  def respond_to_fold_exact(klass, meth)
    answers = call_facts_answers
    return nil unless @closed_world.class_declared?(klass) && @closed_world.instance_class?(klass)
    return nil unless answers.user_instance?(klass) && answers.resolves_in_ruby?(klass, meth)

    path = answers.send(:lookup_path, klass)
    return nil if path.nil?

    ruby = answers.send(:ruby_owners, meth)
    path.any? { |owner| ruby.include?(owner) }
  end
end

CodeGen.prepend(RespondToFold)
