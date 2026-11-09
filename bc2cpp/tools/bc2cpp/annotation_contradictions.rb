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

  # `annotations`     : irep label -> Annotations::Annotation
  # `inferred_args`   : bare name -> [type or nil per position]  (ArgTypes)
  # `inferred_rets`   : a Set of method names proven Fixnum-returning
  # `class_anns`      : irep label -> ClassAnnotations::Annotation
  # `class_args`      : bare name -> [class or nil per position]  (ClassArgTypes)
  #
  # Returns [owner, name, position_or_:return, declared, inferred] per
  # contradiction; empty when every annotation agrees with its proof.
  def self.find(ireps, registry, annotations, inferred_args, inferred_rets,
                class_anns = nil, class_args = nil)
    findings = []
    registry.each do |name, defs|
      defs.each do |d|
        next unless d.irep

        ann = annotations[d.irep]
        if ann
          findings.concat(arg_conflicts(d, name, ann, inferred_args))
          findings.concat(ret_conflicts(d, name, ann, inferred_rets))
        end

        cann = class_anns && class_anns[d.irep]
        findings.concat(class_conflicts(d, name, cann, class_args)) if cann
      end
    end
    findings
  end

  # A class annotation vs an INDEPENDENTLY inferred class at the same slot. Both
  # sides are class NAMES here, so unlike the fixnum/symbol arm this is a direct
  # comparison -- the two readers are the same representation once a class is
  # named, which is what ClassArgTypes exists to provide. A nil on either side is
  # an absent fact (a call site whose receiver is unknown, or a position the
  # tracer could not resolve), never a conflicting one.
  def self.class_conflicts(d, name, cann, class_args)
    return [] unless class_args

    inferred = class_args[name]
    return [] unless inferred

    Array(cann.args).each_with_index.filter_map do |declared, pos|
      got = inferred[pos]
      next unless declared && got && got != declared

      [d.owner, d.name, pos, declared, got]
    end
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

  # IVAR_SIGNATURE_CONTRADICTION: an RBS ivar declaration (`@x: Integer`, `@y: Game::Actor`) against the class
  # ClassLayout settled for that ivar, or failing that the slot IvarLayout embedded it as. An absent fact (no
  # class, an UNKNOWN class, a boxed slot) never contradicts, and an `Integer?` slot (fixnum or nil) agrees with a
  # declared Integer. Returns [sig, declared, inferred] per disagreement; TypeFacts reports the same rows as TC1001.
  IVAR_EMBED_TYPES = { fixnum: 'Integer', symbol: 'Symbol', bool: 'bool', fixnum_nil: 'Integer?' }.freeze

  def self.ivar_conflicts(signature_ivars, class_layout_raw, ivar_layout, unknown)
    (signature_ivars || {}).each_value.filter_map do |sig|
      name = sig.name.delete_prefix('@')
      t = sig.type.optional || sig.type # `@x: C?` is checked as C: ClassLayout facts are "C or nil"
      inferred = (class_layout_raw[sig.owner] || {})[name]
      embed = (ivar_layout[sig.owner] || {})[name]
      got = if inferred && inferred != unknown then inferred.to_s
            elsif IVAR_EMBED_TYPES.key?(embed) then IVAR_EMBED_TYPES[embed]
            end
      want = case t.kind
             when :class then t.cls
             when :int then 'Integer'
             when :sym then 'Symbol'
             when :array then 'Array'
             when :hash then 'Hash'
             end
      next unless want && got
      next if got == want || (got == 'Integer?' && want == 'Integer')

      [sig, want, got]
    end
  end

  # ELEMENT_SIGNATURE_CHECK: an RBS `@x: Array[C]` / `@x: Hash[K, C]` seeds the element table without proof
  # (RbsSignatures.seed_table), so it must at least agree with every site the element analysis traced: a site that
  # wrote another class (a primitive literal included) is a contradiction. Untraced sites are what the seed covers.
  # `array_sites` / `hash_sites` are ArrayElementLayout / HashElementLayout `site_classes`. Rows as ivar_conflicts.
  def self.ivar_element_conflicts(signature_ivars, array_sites, hash_sites)
    (signature_ivars || {}).each_value.filter_map do |sig|
      t = sig.type.optional || sig.type
      sites = { array: array_sites, hash: hash_sites }[t.kind]
      next unless sites && t.element

      got = ((sites[sig.owner] || {})[sig.name.delete_prefix('@')] || []).to_a.map(&:to_s).sort - [t.element]
      next if got.empty?

      container = t.kind == :array ? 'Array' : 'Hash'
      [sig, "#{container}[#{t.element}]", "a #{container} element of class #{got.join(', ')}"]
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
