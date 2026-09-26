# frozen_string_literal: true

# RBS_SEED_CONTRADICTION: an annotation that DISAGREES with a type the compiler
# already PROVED is a build error, not a silently-lost hint.
#
# Spinel's rule (--rbs DIR): a signature the analyzer can represent "is an
# assertion, not a hint" -- a contradiction the compiler can see is a compile
# error. bc2pp already has the same seeding mechanism (`# bc2cpp: (T, ...) -> R`,
# read by Annotations), but it only ever ADDS a fact. An annotation that
# conflicts with an inferred fact is currently indistinguishable from one that
# merely failed to apply, so a typo in a hand-written annotation costs an
# optimization in silence.
#
# The check is deliberately narrow, because it has to be sound and cheap:
#
#   * only an INFERRED concrete type contradicts. UNKNOWN is the ABSENCE of a
#     fact, not a conflicting one -- a `# bc2cpp: (fixnum)` on a method whose
#     argument type is still unknown is the normal case, not a contradiction,
#     and refusing it would refuse nearly every existing annotation.
#   * `inferred_args` is ArgTypes' own table, which is keyed by BARE name and
#     covers MONO names only, so a method ArgTypes skipped cannot be checked
#     and is skipped here rather than guessed at.
#   * the value compared is the RETURN for `-> T`, the ARGUMENT for a slot.
#   * only :fixnum and :symbol are comparable. A class name (ClassAnnotations)
#     is a different lattice with no common representation, and `Array` is not
#     an IvarLayout member at all (see Annotations' own note that `:array` feeds
#     only the block-receiver gate). Comparing either would invent a
#     disagreement rather than find one.
#
# Soundness of the direction: this never widens or narrows an inferred type. It
# only refuses a build whose annotation text disagrees with a proof, so a false
# positive can cost a build, never a correct program.

module AnnotationContradictions
  COMPARABLE = { fixnum: :fixnum, symbol: :symbol }.freeze

  # An inferred type that is not a COMPARABLE value, or is a NIL literal,
  # cannot CONTRADICT an annotation -- it only fails to agree with it.
  #
  # NIL_LITERAL_IS_A_NARROWING: the first version compared against
  # IvarLayout::NIL and refused
  #
  #   # bc2cpp: (, fixnum, )
  #   def battle_level_up_lines(actor, before_level, before_skills)
  #
  # because its one call site is `... if before_level`, so ArgTypes proved
  # :nil_literal for position 2. That proof is CORRECT and the annotation is
  # also correct: the annotation says "when this is a fixnum, it is a fixnum",
  # which is a claim about the non-nil case, and the guard is what makes it
  # true. Refusing it would refuse a correct and useful annotation, and it is
  # the shape an annotation is MOST likely to take. Spinel reaches the same
  # conclusion from the other side: a signature "that only turns out wrong at run
  # time ... is reinterpreted rather than widened".
  #
  # So a contradiction is only reported when both sides name a COMPARABLE type
  # and they differ -- :fixnum against :symbol, or :symbol against :fixnum.
  # Everything else (nil, a class name, UNKNOWN, an unrepresented type) is an
  # absence of a comparable fact and is left to the existing silent-degradation
  # behaviour, which is already sound because every consumer re-checks at
  # runtime.
  def self.contradicting?(declared, inferred)
    want = COMPARABLE[declared]
    got = COMPARABLE[inferred]
    return false unless want && got

    want != got
  end

  # `annotations`   : irep label -> Annotations::Annotation
  # `inferred_args` : bare name -> [type or nil per position]  (ArgTypes)
  # `inferred_rets` : a Set of method names proven Fixnum-returning
  #
  # Returns [owner, name, position_or_:return, declared, inferred] per
  # contradiction; empty when every annotation agrees with its proof.
  def self.find(ireps, registry, annotations, inferred_args, inferred_rets)
    findings = []
    registry.each do |name, defs|
      defs.each do |d|
        next unless d.irep

        ann = annotations[d.irep]
        next unless ann

        findings.concat(arg_conflicts(d, name, ann, inferred_args))
        findings.concat(ret_conflicts(d, name, ann, inferred_rets))
      end
    end
    findings
  end

  def self.arg_conflicts(d, name, ann, inferred_args)
    return [] unless inferred_args

    inferred = inferred_args[name]
    return [] unless inferred

    Array(ann.args).each_with_index.filter_map do |declared, pos|
      got = inferred[pos]
      next unless got && AnnotationContradictions.contradicting?(declared, got)

      [d.owner, d.name, pos, declared, got]
    end
  end

  def self.ret_conflicts(d, name, ann, inferred_rets)
    return [] unless inferred_rets && ann.ret

    # `inferred_rets` is a Set of method NAMES proven Fixnum-returning, not a
    # name -> type table: a member proves :fixnum and a non-member proves nothing.
    # (Set#[] is a "default if absent" reader with a block, not a lookup, so it
    # raises here without one.)
    return [] unless inferred_rets.include?(name)
    return [] unless AnnotationContradictions.contradicting?(ann.ret, :fixnum)

    [[d.owner, d.name, :return, ann.ret, :fixnum]]
  end
end
