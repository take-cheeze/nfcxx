# frozen_string_literal: true

require_relative 'call_facts'

# CodeGen: CALL_FACTS. The receiver of `x.m2` after `x.m1` returned normally is an instance
# of a class that answers `m1`; when only declared classes do, that set is a proven receiver set for the
# guard chain of `m2` (ClosedWorld#refusal), with the same soundness conditions as INSTANCE_RECEIVER
# BC2CPP_CALL_FACTS=0 turns it off.
class CodeGen
  # Larger sets stop being a useful proof: the chain would list most of the program.
  CALL_FACTS_MAX_CLASSES = 32

  # Not memoized: a core method's body compiles with @closed_world swapped out.
  # INSTANCE_SINGLETON_TAINT: instances that may get a singleton class do not turn the facts off when every such
  # class is placed (ClosedWorld#instance_singleton_taint): a fact set then also holds each tainted class whose
  # singleton may answer one of its names (call_facts_classes), and a use that dispatches a name refuses a set holding
  # a class whose singleton may answer that name (singleton_tainted_for?). BC2CPP_SINGLETON_TAINT=0 restores the
  # whole-world condition.
  def call_facts_enabled?
    ENV['BC2CPP_CALL_FACTS'] != '0' && !@closed_world.nil? && !@native_name_sources.nil? &&
      @closed_world.global_refusal.nil? && (@closed_world.exact_instances_singleton_free? || singleton_taint_placed?)
  end

  # Every instance singleton maker is placed on a class (ClosedWorld#instance_singleton_taint).
  def singleton_taint_placed?
    ENV['BC2CPP_SINGLETON_TAINT'] != '0' && !@closed_world.instance_singleton_taint.nil?
  end

  # What a singleton class of an instance of +klass+ may answer: nil (none can have one), :any, or a Set of names. A
  # tainted class taints every class below it, and a class whose ancestry is not fully known is tainted by any taint.
  def instance_singleton_gain(klass)
    taint = @closed_world&.instance_singleton_taint
    return :any if taint.nil?
    return nil if taint.empty? || klass == CallFacts::CLASS_OBJECT

    @instance_singleton_gain ||= {}
    key = [@closed_world.object_id, klass]
    return @instance_singleton_gain[key] if @instance_singleton_gain.key?(key)

    answers = call_facts_answers
    by_simple = Hash.new { |h, k| h[k] = [] }
    taint.each { |owner, gain| by_simple[answers.simple(owner)] << gain }
    anc, unknown = answers.ancestors(klass)
    gains = unknown ? taint.values : anc.flat_map { |a| by_simple.fetch(a, []) }
    @instance_singleton_gain[key] = merge_singleton_gains(gains)
  end

  def merge_singleton_gains(gains)
    return nil if gains.empty?
    return :any if gains.include?(:any)

    names = gains.reduce(Set.new) { |all, g| all.merge(g) }
    return names unless names.delete?(ClosedWorld::SINGLETON_INSTALLED)

    installed = symbol_installed_names
    installed.nil? ? :any : names.merge(installed)
  end

  # An instance of +klass+ may answer one of +names+ through its singleton class.
  def singleton_tainted_for?(klass, names)
    gain = instance_singleton_gain(klass)
    !gain.nil? && (gain == :any || names.any? { |name| gain.include?(name) })
  end

  def call_facts_answers
    @call_facts_answers ||= CallFacts::Answers.new(
      CallFacts::World.new(closed_world: @closed_world, registry: @registry, superclass_of: @superclass_of,
                           included: @included_modules, prepended: @prepended_modules,
                           unknown_mixins: @unknown_mixins, native_sources: @native_name_sources,
                           installed: symbol_installed_names, instance_installed: symbol_instance_installed_names,
                           compiled_core: ->(name) { core_compiled_definers(name) })
    )
  end

  def call_facts_states(irep)
    @call_facts_states ||= {}
    return @call_facts_states[irep.label] if @call_facts_states.key?(irep.label)

    @call_facts_states[irep.label] = CallFacts::Flow.states(irep, fixnum_proof_ctx(irep)[:upvars])
  end

  # The declared classes the receiver register of the SEND at +site+ must be an instance of because an
  # earlier call on the same value returned, or nil. Every fact is a name some call answered, and the
  # set is the classes that can answer all of them.
  # LOOP_FLOW_POSITION: the [irep, idx, insn] flow position of a site: its own, or for a send
  # in an inlined loop body the unshifted position `closed_world_site` attached. Nil when there is none.
  def site_flow_position(site)
    return [site[:irep], site[:idx], site[:insn]] if site[:idx]

    flow = site[:flow]
    flow && [flow[:irep], flow[:idx], flow[:insn]]
  end

  def refined_receiver_instances(site, name)
    return nil unless call_facts_enabled? && @native_results_ready

    irep, idx, insn = site_flow_position(site)
    return nil unless irep && idx && insn&.sym == name && %i[SEND SEND0].include?(insn.op)

    reg = insn.reg.to_i
    return nil if reg >= irep.nregs.to_i || fixnum_proof_ctx(irep)[:upvars].include?(reg)

    states = call_facts_states(irep)
    names = states && CallFacts::Flow.facts(states[idx], reg)
    set = names && call_facts_classes(names)
    # An instance whose singleton class may answer +name+ does not run its class's definition.
    return nil if set&.any? { |k| singleton_tainted_for?(k, [name]) }

    set
  end

  def call_facts_classes(names)
    @call_facts_classes ||= {}
    return @call_facts_classes[names] if @call_facts_classes.key?(names)

    answers = call_facts_answers
    sets = names.filter_map { |m| answers.members(m) }
    set = sets.reduce(:&) unless sets.empty?
    # INSTANCE_SINGLETON_TAINT: an instance may have answered a name through its singleton class.
    if set && @closed_world.instance_singleton_taint&.any?
      set |= answers.classes.select { |k| singleton_tainted_for?(k, names) }
    end
    ok = set && !set.empty? && set.size <= CALL_FACTS_MAX_CLASSES && set.all? { |k| answers.user_instance?(k) }
    @call_facts_classes[names] = ok ? set.to_a.sort : nil
  end

  # No native, outside Ruby, module or method_missing definition of +name+ reaches any class of +classes+.
  def call_facts_native_free?(name, classes)
    answers = call_facts_answers
    classes.all? { |k| answers.native_free?(k, name) }
  end

  # NATIVE_CLASS_ARMS: BC2CPP_NATIVE_CLASS_ARMS=0 turns it off. Same world conditions as CALL_FACTS.
  def native_class_arms_enabled?
    ENV['BC2CPP_NATIVE_CLASS_ARMS'] != '0' && !@closed_world.nil? && !@native_name_sources.nil? &&
      @closed_world.global_refusal.nil? && @closed_world.exact_instances_singleton_free?
  end

  # [instances, scoped, native_free, instance_scope] for ClosedWorld#refusal: the exact-class flow's set when it
  # has one, else the call-fact set. Both are the whole receiver set of instance classes (so only their classes
  # need an arm). With NATIVE_CLASS_ARMS the exact set is scoped too, a class counts as native free when its
  # lookup reaches a Ruby definition first (Answers#resolves_in_ruby?), and `instance_scope` drops the
  # definers and installs only a class object sees.
  def receiver_instance_scope(site, name)
    arms = native_class_arms_enabled?
    exact = receiver_instances(site, name)
    return [exact, false, false, false] if exact && !arms
    return [exact, true, native_class_free?(name, exact), true] if exact && !nil_may_answer?(site, name)
    return [exact, false, false, false] if exact

    refined = refined_receiver_instances(site, name)
    return [nil, false, false, false] unless refined
    return [refined, true, call_facts_native_free?(name, refined), false] unless arms

    [refined, true, call_facts_native_free?(name, refined) || native_class_free?(name, refined), true]
  end

  # The exact set leaves nil out (receiver_instances), but a nil the flow cannot exclude reaches the else arm
  # too: it must raise what dispatch raises, so a name NilClass may answer keeps the whole-name gates.
  def nil_may_answer?(site, name)
    irep, idx, insn = site_flow_position(site)
    mask = exact_flow_mask(irep, idx, insn.reg)
    (!mask.is_a?(Integer) || mask.anybits?(NumericFlow::NIL)) && !nil_unanswerable_for_instances?(name)
  end

  # NATIVE_ARM_COVER: a class counts as native free when an exact-class native arm for it was emitted
  # ahead of this fallback (`with_native_arms_emitted`, the zero-argument RGSS wrappers), so a receiver of exactly
  # that class takes the arm and never reaches the else. BC2CPP_NATIVE_ARM_COVER=0 turns it off.
  def native_class_free?(name, classes)
    answers = call_facts_answers
    covered = native_arm_cover_classes(name)
    classes.all? { |k| covered.include?(k) || answers.resolves_in_ruby?(k, name) }
  end

  # The owners of the exact-class native arms of +name+ that wrap the chain being emitted, or none.
  def native_arm_cover_classes(name)
    return [] if ENV['BC2CPP_NATIVE_ARM_COVER'] == '0'

    Array(@native_arms_emitted && @native_arms_emitted[name])
  end
end
