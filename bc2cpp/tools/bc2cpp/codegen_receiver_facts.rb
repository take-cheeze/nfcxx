# frozen_string_literal: true

# CodeGen: receiver, owner and super-target facts.

class CodeGen
  # INTERP_UNLOCK: does MONO method `name` carry a hand-placed `-> Array`
  # annotation? Consumed by proven_array_source's chained rule. MONO-only (an
  # annotation sits on one irep). No compiles_clean? requirement: the fact is
  # about the return value only. Sound because the annotation is hand-placed
  # AND every admitted site passes the emitter's mrb_array_p tripwire, which
  # raises on a wrong claim. Unknown tokens resolve to nil.
  def annotated_array_return(name)
    defs = @registry[name]
    return false unless defs && defs.size == 1 && defs.first.irep

    label = defs.first.irep
    # `Array<Klass>` also claims an Array result, so it opens the same gate;
    # annotated_element_return supplies the element class.
    @annotations[label]&.ret == :array || !@element_annotations[label]&.element.nil?
  end

  # ELEMENT_CLASS_SUPPORT: annotated_array_return's MONO-keyed lookup for the
  # element dimension (see ElementAnnotations).
  def annotated_element_return(name)
    defs = @registry[name]
    return nil unless defs && defs.size == 1 && defs.first.irep

    @element_annotations[defs.first.irep]&.element
  end

  def annotated_ret_class(name)
    defs = @registry[name]
    return nil unless defs && defs.size == 1 && defs.first.irep

    @element_annotations[defs.first.irep]&.ret_class
  end

  # ELEMENT_CLASS_SUPPORT: element class of a proven-Array block receiver, from
  # the same scan ArrayElementLayout uses (so they cannot drift). nil (the usual
  # answer) leaves per-element calls as POLY mrb_funcall.
  def proven_element_class(irep, idx, dest_reg, ivar_classes, mand, arg_classes, owner_name)
    array_element_source_scan(irep, idx, dest_reg, element_ctx(ivar_classes, mand, arg_classes, owner_name))
  end

  # Memoized: the registry is fixed after CodeGen.new.
  def known_owner_set
    @known_owner_set ||= Set.new(@registry.values.flatten.map(&:owner))
  end

  # Classes some other class inherits from (see self_receiver_class). Memoized;
  # @superclass_of is fixed.
  def subclassed_set
    @subclassed_set ||= Set.new(@superclass_of.values.select { |v| v.is_a?(String) })
  end

  # The class whose instance `self` is while compiling `owner_def`'s code, or nil
  # inside a runtime-def/EXEC body, whose self is whatever receiver mruby passes.
  def self_class(owner_def)
    @self_class_unknown ? nil : owner_def.owner
  end

  # LEXICAL_SELF_SUPPORT: compile_send's version of self_receiver_class (see it
  # for the soundness argument: no subclass anywhere, and `.singleton` owners
  # refused), using this CodeGen's memoized sets instead of a `ctx` hash.
  def lexical_self_owner(owner_def)
    return nil unless owner_def && self_class(owner_def)

    owner = owner_def.owner
    return nil if owner.nil? || owner.end_with?('.singleton')
    return nil unless known_owner_set.include?(owner)
    return nil if subclassed_set.include?(owner)

    owner
  end

  # SINGLETON_LEXICAL_SELF: `self` in `def self.x` of X is X itself unless X is a
  # subclassed class (a module never is), and X's own singleton def wins lookup.
  def lexical_self_singleton_owner(owner_def)
    return nil unless owner_def && self_class(owner_def)

    owner = owner_def.owner
    return nil unless owner&.end_with?('.singleton')

    base = owner.delete_suffix('.singleton')
    # Top-level `def self.x` is main's singleton, also spelled "Object.singleton".
    return nil if base == 'Object' || subclassed_set.include?(base)
    return nil unless Array(@prepended_modules[owner]).empty?
    return nil if @unknown_mixins.include?(owner) || @unknown_mixins.include?(base)

    owner
  end

  # The one irep def `name` has on that singleton owner (module_function copies
  # have no irep; a second def would make "which one is live" order-dependent).
  def lexical_self_singleton_def(name, owner_def)
    owner = lexical_self_singleton_owner(owner_def)
    return nil unless owner

    defs = (@registry[name] || []).select { |md| md.owner == owner }
    defs.size == 1 && defs.first.irep ? defs.first : nil
  end

  # LEXICAL_SELF_KEYWORD_SUPPORT: monomorphic_target's role for
  # compile_keyword_call, for a POLY name sent with no explicit receiver. `self`
  # in a method of C is a C, and lexical_self_owner has proven no subclass of C
  # exists, so dispatch can only reach C's definition (the same reasoning as
  # super_target and compile_send's LEXICAL_SELF branch).
  # Extra guard: devirt_blocked_name? up front (a name installed on a runtime
  # singleton class can shadow even a known self's method); the LEXICAL_SELF
  # marker is not in RUNTIME_DEF_DYNAMIC_MARKERS, so the text audit still
  # applies. Arity/keyword-shape checks stay in compile_keyword_call.
  # Limit: subclassed_set comes from @superclass_of, which has no entry for an
  # unresolvable superclass expression, so such a subclass would not mark its
  # parent. The closed world has none (every superclass resolves, no
  # Class.new), and the same limit applies to LEXICAL_SELF and
  # self_receiver_class.
  # nil for explicit-receiver sends.
  def lexical_self_keyword_target(name, self_implicit:, owner_def:)
    return nil unless self_implicit
    return nil if devirt_blocked_name?(name)

    lex_owner = lexical_self_owner(owner_def)
    candidate = if lex_owner
                  @registry[name]&.find { |md| md.owner == lex_owner }
                else
                  lexical_self_singleton_def(name, owner_def)
                end
    return nil unless candidate&.irep
    return nil unless compiles_clean?(candidate.irep)

    candidate
  end

  def element_ctx(ivar_classes, mand, arg_classes, owner_name)
    { owner: owner_name, registry: @registry, class_layout: @class_layout, ireps: @ireps,
      class_annotations: @class_annotations, element_annotations: @element_annotations,
      known_owners: known_owner_set, subclassed: subclassed_set,
      ivar_classes: ivar_classes || {}, mand: mand, arg_classes: arg_classes,
      elements: @element_layout,
      annotated_element: ->(n) { annotated_element_return(n) },
      annotated_ret_class: ->(n) { annotated_ret_class(n) } }
  end

  # HASH_ELEMENT_SUPPORT: proven_element_class for Hash values.
  def proven_hash_element_class(irep, idx, dest_reg, ivar_classes, mand, arg_classes, owner_name)
    hash_element_source_scan(irep, idx, dest_reg, hash_element_ctx(ivar_classes, mand, arg_classes, owner_name))
  end

  def hash_element_ctx(ivar_classes, mand, arg_classes, owner_name)
    { owner: owner_name, registry: @registry, class_layout: @class_layout, ireps: @ireps,
      class_annotations: @class_annotations, element_annotations: @element_annotations,
      known_owners: known_owner_set, subclassed: subclassed_set,
      ivar_classes: ivar_classes || {}, mand: mand, arg_classes: arg_classes,
      elements: @element_layout, hash_elements: @hash_element_layout,
      annotated_element: ->(n) { annotated_element_return(n) },
      annotated_ret_class: ->(n) { annotated_ret_class(n) } }
  end

  # SYM_DEVIRT: resolve a `&:sym` target inside emit_sym_inline. Returns
  # [:mono, def], [:poly, defs] or nil, applying compile_send's MONO guards
  # (pure-mandatory arity, arity 0 since recognize_sym_regions requires n=0,
  # ONLY_OWNERS/OTHER_OWNERS). POLY needs a per-element class guard per
  # candidate and is capped at SYM_DEVIRT_CHAIN_CAP. Anything else keeps
  # mrb_funcall.
  SYM_DEVIRT_CHAIN_CAP = 4

  def sym_call_target(sym)
    defs = @registry[sym]
    return nil unless defs

    usable = defs.select do |d|
      next false unless d.irep
      next false unless pure_mandatory_arity?(@ireps.fetch(d.irep))
      next false unless mandatory_arity(@ireps.fetch(d.irep)).zero?
      next false unless compiles_clean?(d.irep)
      next false if @only_owners && !@only_owners.include?(d.owner) && !(@other_owners&.include?(d.owner))

      true
    end
    # All or nothing: skipping a def is unsound for MONO and would misroute
    # elements in a partial POLY chain if the fallback were ever dropped.
    return nil unless usable.size == defs.size && !usable.empty?

    return [:mono, usable.first] if usable.size == 1
    return [:poly, usable] if usable.size <= SYM_DEVIRT_CHAIN_CAP

    nil
  end

  # ANCESTOR_MIXINS_SUPPORT: can `super` in owner_def provably reach the declared
  # superclass, i.e. no included module in between (mruby searches [class,
  # included modules newest-first, superclass, ...])?
  # Declines whenever the owner has ANY plain `include`: a bare `include M` in a
  # class body is resolved relative to the class ("Foo::M"), while
  # build_registry names the module's methods by the module's own path ("M"),
  # so matching module owners could wrongly prove a `super` safe. Only
  # presence is consulted. Prepended modules sit above the class and are not
  # consulted.
  def super_reaches_superclass?(owner_def)
    owner = owner_def.owner
    return false if @unknown_mixins.include?(owner)

    Array(@included_modules[owner]).empty?
  end

  # ZSUPER_GENERAL_SUPPORT (ADR 0159): a bare `super` forwarding the current
  # method's arguments to a COMPILED superclass method. codegen_zsuper emits:
  #
  #   ARGARY R(a+1)  m1:0:0:0 (0)   # packs the CURRENT frame's regs[1..m1]
  #   SUPER  R(a)    n=*            # superes ci->mid, reading that array
  #
  # OP_ARGARY with lv==0 copies regs + 1, so the forwarded arguments are r1..rm1
  # and the call is `Super#name_impl(M, self, r1, ..., rm1)`. `idx` may name
  # either half; both resolve to the same answer (as in zsuper_native_kind).
  # Every fact is re-checked per site from the bytecode:
  def zsuper_forward_plan(owner_def, irep, idx)
    return nil unless owner_def && irep && idx

    instructions = irep.instructions

    # (1) The adjacent ARGARY + SUPER pair (`SUPER R(a)` + `ARGARY R(a+1)`). An
    # interposed EXT declines.
    argary_idx = instructions[idx]&.op == 'ARGARY' ? idx : idx - 1
    return nil if argary_idx.negative?

    argary = instructions[argary_idx]
    super_insn = instructions[argary_idx + 1]
    return nil unless argary && super_insn
    return nil unless argary.op == 'ARGARY' && super_insn.op == 'SUPER'

    # (2) SUPER is the `n=*` zsuper splat, not the fixed `n=N` shape or the
    # keyword `nk=` variant.
    return nil unless super_insn.args.split(/\s+/, 2)[1].to_s.strip == 'n=*'

    # (3) ARGARY is `m1:0:0:0 (0)`: no rest, post, kd, and lv==0 (this frame's
    # registers). m1 is the forwarded count.
    am = argary.args.match(/\AR(\d+)\s+(\d+):(\d):(\d+):(\d)\s+\((\d+)\)/)
    return nil unless am

    argary_dest = am[1]
    m = am[2].to_i
    return nil unless am[3].to_i.zero? && am[4].to_i.zero? && am[5].to_i.zero? && am[6].to_i.zero?
    return nil if m.zero? # zero-param bare `super` is `SUPER ... n=0`, no ARGARY at all

    # (4) OP_SUPER reads regs[a+1], so ARGARY's dest must be SUPER's dest + 1.
    super_dest = super_insn.args[/^R(\d+)/, 1]
    return nil unless argary_dest && super_dest
    return nil unless argary_dest.to_i == super_dest.to_i + 1

    # (5) ENTER is exactly m mandatory and nothing else (REQ:OPT:REST:POST:KEY:
    # KDICT:BLOCK:NOBLOCK, src/codedump.c), so regs[1..m] is the whole argument
    # list and there is no block parameter.
    enter = instructions.find { |i| i.op == 'ENTER' }
    return nil unless enter

    em = enter.args.match(/\A(\d+):(\d+):(\d+):(\d+):(\d+):(\d+):(\d+)/)
    return nil unless em
    return nil unless em[2..7].all? { |x| x.to_i.zero? }
    return nil unless em[1].to_i == m

    # (6) The same-named method on the registered superclass exists, is bytecode
    # and compiles clean. A clean `_impl` never yields, so a caller's block is
    # unobservable (no caller grep needed, unlike SUPER_TARGETS).
    # super_reaches_superclass? rules out an included module in between.
    superclass = @superclass_of[owner_def.owner]
    return nil unless superclass.is_a?(String)
    return nil unless super_reaches_superclass?(owner_def)

    target_def = @registry[owner_def.name].find { |d| d.owner == superclass }
    return nil unless target_def && target_def.irep && compiles_clean?(target_def.irep)

    { target_def: target_def, m: m }
  end

  # ZSUPER_GENERAL_SUPPORT: a direct `_impl` call forwarding r1..m (what ARGARY
  # would have packed). `d_reg` is SUPER's destination.
  def compile_zsuper_forward(target_def, d_reg, m)
    args = (1..m).map { |i| ", r#{i}" }.join
    "  r#{d_reg} = #{cpp_name(target_def.owner, target_def.name)}_impl(M, self#{args});\n"
  end

  # SUPER_SUPPORT: the target of `super` in owner_def's method: the same-named
  # MethodDef on the declared superclass, only when "Owner#name" is in
  # SUPER_TARGETS (see it for the block-forwarding fact). The no-include fact is
  # re-derived by super_reaches_superclass?. Owner-relative, so a POLY name
  # still resolves, as real `super` does.
  def super_target(owner_def)
    return nil unless SUPER_TARGETS.include?("#{owner_def.owner}##{owner_def.name}")

    superclass = @superclass_of[owner_def.owner]
    return nil unless superclass.is_a?(String)
    # ANCESTOR_MIXINS_SUPPORT: re-derived every time; see
    # super_reaches_superclass?.
    return nil unless super_reaches_superclass?(owner_def)

    target_def = @registry[owner_def.name].find { |d| d.owner == superclass }
    return nil unless target_def && target_def.irep
    return nil unless compiles_clean?(target_def.irep)

    target_def
  end

  # ZSUPER_NATIVE_SUPPORT: which native method (a ZSUPER_NATIVE_SHAPES kind)
  # the ARGARY + `SUPER n=*` pair at `idx` reaches; nil keeps `#error`. `idx`
  # may be either half; both give the same answer so the two arms cannot emit
  # half a translation. Everything here is re-checked per site;
  # ZSUPER_NATIVE_TARGETS holds only the non-derivable remainder.
  def zsuper_native_kind(owner_def, irep, idx)
    return nil unless owner_def && irep && idx

    kind = ZSUPER_NATIVE_TARGETS["#{owner_def.owner}##{owner_def.name}"]
    return nil unless kind

    shape = ZSUPER_NATIVE_SHAPES.fetch(kind)
    # (1) Pin the name off the MethodDef, not the allowlist key.
    return nil unless owner_def.name == shape[:name]

    # (2) The adjacent pair codegen_zsuper emits (`SUPER R(a)` + `ARGARY R(a+1)`;
    # OP_SUPER reads the packed argument from regs[a+1]). `idx - 1` must not go
    # negative: Ruby would index from the end of the list.
    argary_idx = irep.instructions[idx]&.op == 'ARGARY' ? idx : idx - 1
    return nil if argary_idx.negative?

    argary = irep.instructions[argary_idx]
    super_insn = irep.instructions[argary_idx + 1]
    return nil unless argary && super_insn
    # Strict adjacency: an interposed EXT declines.
    return nil unless argary.op == 'ARGARY' && super_insn.op == 'SUPER'

    argary_dest = argary.args[/^R(\d+)/, 1]
    super_dest = super_insn.args[/^R(\d+)/, 1]
    return nil unless argary_dest && super_dest
    return nil unless argary_dest.to_i == super_dest.to_i + 1

    # (3) The `n=*` splat shape, not SUPER_TARGETS' fixed `n=N`.
    return nil unless super_insn.args.split(/\s+/, 2)[1].to_s.strip == 'n=*'

    # (4) The ARGARY spec this kind was derived against (`2:0:0:0` or `1:1:0:0`)
    # with lv=0 (plain regs+1) and kd=0. A changed parameter list declines.
    return nil unless argary.args[/\s(\d+:\d+:\d+:\d+)\s*\(/, 1] == shape[:argary]
    return nil unless argary.args[/\((\d+)\)\s*\z/, 1].to_s == '0'

    # (5) The superclass is the implicit Object (:none means a CLASS with no
    # superclass expression, not "unrecognized").
    return nil unless @superclass_of[owner_def.owner] == :none

    # (6) Nothing can intercept the name before the native target: every
    # registered definition belongs to a real CLASS in @superclass_of (so modules,
    # `.singleton` owners and unresolved classes refuse) that is not one of the
    # chain classes. Such a class cannot sit between the owner and Object, since
    # (5) made Object the owner's superclass. `<native>` is checked in (7).
    return nil unless @registry[owner_def.name].all? { |d|
      d.owner == '<native>' ||
        (@superclass_of.key?(d.owner) && !ZSUPER_NATIVE_BLOCKED_OWNERS.include?(d.owner))
    }

    # (7) NATIVE_SRCS has exactly the one definition being reproduced; a second
    # could be an override in the chain. A missing map (scan not run) declines.
    return nil unless @native_name_sources

    srcs = @native_name_sources[owner_def.name] || []
    return nil unless srcs.size == 1 && srcs.first.end_with?(shape[:native_src])

    kind
  end
end
