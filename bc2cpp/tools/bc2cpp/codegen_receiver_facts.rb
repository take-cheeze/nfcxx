# frozen_string_literal: true

# CodeGen: receiver, owner and super-target facts.

class CodeGen
  # A rescue handler's exception register stays an Exception value until it is
  # overwritten. Follow only MOVE aliases back to the recognized EXCEPT.
  def rescued_exception_receiver?(irep, idx, dest_reg)
    return false unless irep && !idx.nil?

    addr = irep.instructions[idx]&.addr
    return false unless addr

    # RESCUE reads its first register and writes its second; the caught
    # exception remains live in the input register for the handler.
    rescue_write = ->(insn, cur) { insn.op == 'RESCUE' && insn.regs[1] == cur }
    irep.walk_writers(idx - 1, dest_reg.to_s, skip_ops: %w[RESCUE], barrier: rescue_write, barrier_result: false,
                                              follow_moves: true) do |insn, _index, exc_reg|
      next false unless insn.op == 'EXCEPT'

      recognize_rescue_regions(irep).any? do |region|
        region[:kind] == :rescue_class && region[:exc_reg] == exc_reg &&
          region[:except_addr] == insn.addr && insn.addr < addr && addr < region[:shared_target]
      end
    end || false
  end

  # `Exception#message` and `#to_s` share exc_to_s in mruby. A rescue proves the
  # receiver is an exception, but any Ruby instance override or runtime installer
  # invalidates using that C body directly.
  def rescued_exception_message_safe?
    return @rescued_exception_message_safe if defined?(@rescued_exception_message_safe)

    defs = @registry['message'] || []
    @rescued_exception_message_safe = defs.any? { |d| d.owner == '<native>' && d.irep.nil? } &&
                                      defs.all? { |d| d.owner == '<native>' || d.owner.end_with?('.singleton') } &&
                                      !devirt_blocked_name?('message') &&
                                      Array(@prepended_modules['Exception']).empty? &&
                                      !@unknown_mixins.include?('Exception')
  end

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

  # Prefer the whole-program hierarchy when it is available: the partial
  # superclass map omits classes whose superclass expression did not resolve.
  def exact_receiver_class?(owner)
    return @closed_world.exact_class?(owner) if @closed_world

    !subclassed_set.include?(owner)
  end

  # Exact only for a fresh `Klass.new` whose constant and constructor lookup are
  # closed-world stable. ClassLayout and argument annotations remain guarded.
  def exact_new_receiver_class(irep, idx, dest_reg, owner:, expected_class:)
    return nil unless stable_standard_constructor_class?(expected_class)

    # JOIN_DOMINANCE: unguarded, so the `new` must be the only value the register can hold.
    irep.walk_dominating_writers(idx - 1, dest_reg, use: idx, follow_moves: true) do |insn|
      # The known-class trace already resolved this SEND's constant path;
      # stability above proves that path still denotes the same class.
      expected_class if %w[SEND SEND0].include?(insn.op) && insn.sym == 'new'
    end
  end

  # Diagnostic-only: identify the nearest producer behind an unresolved
  # receiver, following register copies without changing the type proof.
  def receiver_trace_origin(irep, idx, dest_reg)
    return 'receiver_unavailable' unless irep && idx && dest_reg

    at_entry = ->(last) { last == '0' ? 'self_register' : 'incoming_or_unwritten_register' }
    irep.walk_writers(idx - 1, dest_reg.to_s, skip_ops: ['BLOCK', *READ_ONLY_OPCODE_SKIP], exhausted: at_entry) do |insn|
      case insn.op
      when 'MOVE' then insn.regs[1] ? IrepScans.follow(insn.regs[1]) : 'move_without_source'
      when 'GETIV' then 'get_ivar'
      when 'GETIDX', 'GETIDX0' then 'indexed_result'
      when 'GETUPVAR' then 'captured_upvar'
      when 'GETCONST', 'GETMCNST' then 'constant_lookup'
      when 'SEND', 'SEND0', 'SENDB', 'SSEND', 'SSEND0', 'SSENDB' then 'send_result'
      when 'ARRAY', 'ARRAY2', 'HASH', 'STRING', 'STR' then 'literal_container'
      else "write_#{insn.op.downcase}"
      end
    end
  end

  # Resolve a constant expression used as a class/module object, not an
  # instance. A branch edge that can bypass the constant write invalidates it.
  def constant_object_owner(irep, idx, dest_reg, lexical_owner)
    return nil unless @closed_world && ConstructClassNames.table && irep && idx &&
                      idx < irep.instructions.length && dest_reg

    written = straight_line_constant_name(irep, idx, dest_reg) || irep.agreed_constant_name(idx, dest_reg.to_s)
    return nil unless written

    owner = resolve_class_constant_name(written, lexical_owner)
    stable = owner && (@closed_world.stable_constant_identity?(owner) ||
                       CodeGen.stable_class_constants&.include?(owner.split('::').last))
    stable ? owner : nil
  end

  # The constant the straight-line walk finds when no branch can bypass its
  # load; nil otherwise (agreed_constant_name then asks every reaching definition).
  def straight_line_constant_name(irep, idx, dest_reg)
    branch_edges = BytecodeIR.for(irep).jump_edges_before(idx, %w[JMP JMPIF JMPNOT JMPNIL JMPUW])
    return nil unless branch_edges

    ref = irep.constant_path(idx - 1, dest_reg.to_s, skip_ops: READ_ONLY_OPCODE_SKIP,
                                                     barrier: %w[JMPUW ONERR RESCUE EXCEPT BLOCK])
    return nil unless ref&.root == :const

    # A forward edge from before this write into the send's block could
    # bypass the receiver value; edges from later code already execute it.
    return nil if branch_edges.any? { |source, target| source < ref.root_index && target > ref.root_index && target <= idx }

    ref.name && ([ref.name] + ref.segments).join('::')
  end

  def resolve_class_constant_name(written, lexical_owner)
    return nil unless written && lexical_owner

    lexical = lexical_owner.to_s.delete_suffix('.singleton').split('::')
    candidates = lexical.length.downto(1).map { |n| "#{lexical.first(n).join('::')}::#{written}" }
    candidates << written
    hits = candidates.uniq.select { |name| ConstructClassNames.table.key?(name) }
    # GETCONST follows Ruby's lexical nesting order: the innermost defined
    # binding shadows outer bindings with the same name. Identity stability
    # below proves the selected binding cannot be rebound at runtime.
    return hits.first unless hits.empty?

    # A bare native class/module may enter lookup through Object's included
    # modules (for example Input resolving to RGSS::Input). Reuse the existing
    # whole-program unique-name proof rather than guessing the alias path.
    unique = UniqueClassNames.resolve(written, lexical_owner)
    unique if unique && ConstructClassNames.table.key?(unique)
  end

  def constant_object_candidate_clean?(label)
    return false if @constant_object_probe

    @constant_object_probe = true
    compiles_clean?(label)
  ensure
    @constant_object_probe = false
  end

  # A module_function copy shares its instance method's irep but runs with the
  # module object as self (ADR 0241 already passes it for the body's own bare
  # calls), so the instance-owner proof is reusable only when the body neither
  # observes self nor ties itself to instance state: ivars, class variables,
  # `super` or ARGARY, anywhere in its blocks too (ADR 0258, 0259).
  MODULE_FUNCTION_INSTANCE_OPS = %w[GETIV SETIV GETCV SETCV SUPER ARGARY].freeze

  def module_function_copy_self_safe?(irep, owner)
    return false unless irep
    return false if @ivar_layout.key?(owner)

    seen = Set.new
    pending = [irep]
    until pending.empty?
      current = pending.pop
      next unless seen.add?(current.label)

      return false if current.instructions.any? { |insn| MODULE_FUNCTION_INSTANCE_OPS.include?(insn.op) || insn.mentions_reg?(0) || insn.upvar_ref&.first&.zero? }

      pending.concat(current.reps.map { |label| @ireps.fetch(label) })
    end
    true
  end

  def stable_standard_constructor_class?(klass)
    stable_identity = @closed_world && (@closed_world.stable_class_constant?(klass) ||
                                        @closed_world.stable_constant_identity?(klass))
    stable_identity && @closed_world.standard_constructor_lookup? && exact_constructor_chain?(klass)
  end

  # Inside a class method, bare `new` has the class object as its receiver.
  # The registry's `.singleton` owner is therefore class-name evidence, but only
  # for classes the current closed-world build actually emits.
  def implicit_singleton_self_class(owner_def)
    owner = owner_def&.owner
    return nil unless owner.is_a?(String) && owner.end_with?('.singleton')

    klass = owner.delete_suffix('.singleton')
    return nil if klass.empty? || !@known_owners&.include?(klass)

    klass
  end

  def exact_constructor_chain?(klass)
    # Every class object's singleton lookup reaches Class after its own
    # singleton superclass chain. A module mixed into Class can replace new or
    # allocate for every class object, so reject it even though it is not in
    # `klass`'s ordinary superclass chain below.
    return false if @unknown_mixins.include?('Class')
    return false unless Array(@included_modules['Class']).empty? && Array(@prepended_modules['Class']).empty?

    seen = Set.new
    while klass.is_a?(String) && seen.add?(klass)
      singleton = "#{klass}.singleton"
      # Instance includes/prepends do not affect the class object's singleton
      # lookup. Only an unresolved mixin on the singleton owner can intercept
      # Class#new or #allocate; known singleton mixins are checked below too.
      return false if @unknown_mixins.include?(singleton)
      return false unless Array(@included_modules[singleton]).empty? && Array(@prepended_modules[singleton]).empty?

      %w[new allocate].each do |name|
        return false if (@registry[name] || []).any? do |definition|
          [klass, singleton, 'Class'].include?(definition.owner) && definition.owner != '<native>'
        end
      end
      klass = @superclass_of[klass]
    end
    true
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
    return nil unless exact_receiver_class?(owner)

    owner
  end

  # MODULE_SINGLETON_SELF (ADR 0258): ClosedWorld#exact_class? has no answer for
  # a module (only classes are declared), so `def self.x` in a module M never
  # reached SINGLETON_LEXICAL_SELF under a closed world. ClosedWorld#module_object_self?
  # proves self is M (ADR 0259); inherited_lookup_safe? covers outside reopening
  # and by-name installers.
  def module_singleton_self?(base, name)
    return false unless name && @closed_world&.module_object_self?(base)

    @closed_world.inherited_lookup_safe?(name, base)
  end

  # SINGLETON_LEXICAL_SELF: `self` in `def self.x` of X is X itself unless X is a
  # subclassed class or a declared module that never has its singleton methods
  # cloned (ADR 0258, 0259), and X's own singleton def wins lookup.
  def lexical_self_singleton_owner(owner_def, name: nil)
    return nil unless owner_def && self_class(owner_def)

    owner = owner_def.owner
    return nil unless owner&.end_with?('.singleton')

    base = owner.delete_suffix('.singleton')
    # Top-level `def self.x` is main's singleton, also spelled "Object.singleton".
    return nil if base == 'Object' || !(exact_receiver_class?(base) || module_singleton_self?(base, name))
    return nil unless Array(@prepended_modules[owner]).empty?
    return nil if @unknown_mixins.include?(owner) || @unknown_mixins.include?(base)

    owner
  end

  # The one irep def (or `attr_*` accessor) `name` has on that singleton owner
  # (module_function copies have no irep; a second def would make "which one is
  # live" order-dependent).
  def lexical_self_singleton_def(name, owner_def)
    owner = lexical_self_singleton_owner(owner_def, name: name)
    return nil unless owner

    defs = (@registry[name] || []).select { |md| md.owner == owner }
    defs.size == 1 && (defs.first.irep || defs.first.kind == :ivar_accessor) ? defs.first : nil
  end

  # A compiled module_function copy runs the source body with the module object
  # as self. Resolve its bare self-calls against that same module's singleton
  # copies, but only when both copies are emitted in this closed-world build.
  def lexical_module_function_self_target(name, owner_def)
    return nil unless owner_def && owner_def.owner.is_a?(String)

    owner = owner_def.owner.delete_suffix('.singleton')
    singleton_owner = "#{owner}.singleton"
    return nil unless @closed_world&.stable_constant_identity?(owner)
    return nil unless @only_owners&.include?(singleton_owner) || @other_owners&.include?(singleton_owner)
    return nil if @unknown_mixins.include?(singleton_owner) ||
                  !Array(@included_modules[singleton_owner]).empty? ||
                  !Array(@prepended_modules[singleton_owner]).empty?

    current_copy = (@registry[owner_def.name] || []).select do |definition|
      definition.kind == :module_function && definition.owner == singleton_owner &&
        definition.copy_owner == owner && definition.copy_irep == owner_def.irep
    end
    return nil unless current_copy.one?

    copies = (@registry[name] || []).select do |definition|
      definition.kind == :module_function && definition.owner == singleton_owner &&
        definition.copy_owner == owner && definition.visibility == :public && definition.copy_irep
    end
    return nil unless copies.one?

    copy = copies.first
    target = (@registry[name] || []).find do |definition|
      definition.owner == owner && definition.irep == copy.copy_irep
    end
    return nil unless target && !hot_only_excluded?(copy.copy_irep)
    return nil if devirt_blocked_name?(name)

    target
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
  # With a closed-world scan, exact_receiver_class? includes subclasses whose
  # superclass expression the local resolver could not identify.
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
      known_owners: known_owner_set, subclassed: subclassed_set, closed_world: @closed_world,
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
      known_owners: known_owner_set, subclassed: subclassed_set, closed_world: @closed_world,
      ivar_classes: ivar_classes || {}, mand: mand, arg_classes: arg_classes,
      elements: @element_layout, hash_elements: @hash_element_layout,
      annotated_element: ->(n) { annotated_element_return(n) },
      annotated_ret_class: ->(n) { annotated_ret_class(n) } }
  end

  # SYM_DEVIRT: resolve a `&:sym` target inside emit_sym_inline. Returns
  # [:mono, def], [:poly, defs] or nil, applying compile_send's MONO guards
  # (pure-mandatory arity, arity 0 since recognize_sym_regions requires n=0,
  # ONLY_OWNERS/OTHER_OWNERS). POLY needs a per-element exact-class guard for
  # each direct or closed-world-proven inherited implementation and is capped
  # at SYM_DEVIRT_CHAIN_CAP. Anything else keeps mrb_funcall.
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
    return nil if usable.size > SYM_DEVIRT_CHAIN_CAP

    # Each inherited entry is keyed by the exact receiver class, not its
    # ancestor implementation owner; emission therefore retains lookup's
    # runtime-class check and shares the caller's closed-world hierarchy proof.
    branches = usable.map { |definition| { guard_owner: definition.owner, definition: definition } }
    if @closed_world
      (@superclass_of.keys + known_owner_set.to_a).uniq.each do |receiver_class|
        next if receiver_class.end_with?('.singleton') || branches.any? { |b| b[:guard_owner] == receiver_class }

        target = closed_world_inherited_target(sym, receiver_class)
        next unless target && usable.include?(target)

        branches << { guard_owner: receiver_class, definition: target }
      end
    end
    return [:poly, branches] if branches.size <= SYM_DEVIRT_CHAIN_CAP

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
    return nil unless super_insn.pure_splat?

    # (3) ARGARY is `m1:0:0:0 (0)`: no rest, post, kd, and lv==0 (this frame's
    # registers). m1 is the forwarded count.
    spec = argary.argary_spec
    return nil unless spec && argary.reg && argary.paren_value&.match?(/\A\d+\z/)

    argary_dest = argary.reg
    m = spec[0]
    return nil unless spec[1..].all?(&:zero?) && argary.paren_value.to_i.zero?
    return nil if m.zero? # zero-param bare `super` is `SUPER ... n=0`, no ARGARY at all

    # (4) OP_SUPER reads regs[a+1], so ARGARY's dest must be SUPER's dest + 1.
    super_dest = super_insn.reg
    return nil unless argary_dest && super_dest
    return nil unless argary_dest.to_i == super_dest.to_i + 1

    # (5) ENTER is exactly m mandatory and nothing else (REQ:OPT:REST:POST:KEY:
    # KDICT:BLOCK:NOBLOCK, src/codedump.c), so regs[1..m] is the whole argument
    # list and there is no block parameter.
    enter = irep.enter
    return nil unless enter

    em = enter.enter_fields
    return nil unless em.length >= 7
    return nil unless em[1..6].all?(&:zero?)
    return nil unless em[0] == m

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

    argary_dest = argary.reg
    super_dest = super_insn.reg
    return nil unless argary_dest && super_dest
    return nil unless argary_dest.to_i == super_dest.to_i + 1

    # (3) The `n=*` splat shape, not SUPER_TARGETS' fixed `n=N`.
    return nil unless super_insn.pure_splat?

    # (4) The ARGARY spec this kind was derived against (`2:0:0:0` or `1:1:0:0`)
    # with lv=0 (plain regs+1) and kd=0. A changed parameter list declines.
    return nil unless argary.argary_spec&.join(':') == shape[:argary]
    return nil unless argary.paren_value == '0'

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
