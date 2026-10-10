# frozen_string_literal: true

require 'set'

# CodeGen: CONSTRUCTOR_POOLS (ADR 0313).
#
# ENTRY_ARG_CALLSITE_PROOF and the argument pools refuse `initialize` (rule 5): no SEND names it, so its
# call sites cannot be enumerated by name. They can by class: the initialize D a class K runs is a fact of
# the closed hierarchy (numeric_init_definition up the superclass chain), and D is entered from two places:
#
#   * `Klass.new(args)`. Every definition reaching the receiver register is a GETCONST/GETMCNST and no
#     SETCONST binds a value to that name, so the site builds a class named like it
#     (ClosedWorld#classes_named). A `new` in a method of X whose receiver is X's own class object (the
#     implicit-self `new` of `def self.m`, `self.class.new`) builds X or a descendant ("rooted").
#   * `super(a, b)` in the initialize of a subclass (a bare `super` withdraws the target).
#
# D becomes a candidate, in the shape ENTRY_ARG_CALLSITE_PROOF's candidates have so the numeric, Fixnum and
# class pools read it unchanged, only when nothing else can enter it:
#
#   * a `new` whose receiver is not provably a constant or rooted could build any class. It withdraws every D
#     it can get past ENTER for (mand <= argc <= mand + opt, any count with a rest parameter), all of them when
#     the count is unknown (splat, keyword);
#   * no `:new`/`:initialize` Symbol, keyword or computed name (an `alias_method :x, :initialize` in a class
#     body withdraws that class's initialize only), no Ruby `new`, no module or singleton `initialize`, no
#     explicit `initialize` call, no Class mixin, no wild class;
#   * D's class and every class running D has a plain declared-class chain to Object (an Exception subclass is
#     built by `raise`), is not opaque, and no native or foreign Ruby source spells its root and last segment.
#
# Only positions 1..mand are candidates: positions past them are optional parameters whose default code may
# read a later one. A keyword or post-mandatory parameter leaves D out.
#
# BC2CPP_CONSTRUCTOR_POOLS=0 turns it off.
class CodeGen
  CONSTRUCTOR_NEW_OPS = %w[SEND SEND0 SENDB SSEND SSEND0 SSENDB].freeze
  # Ops that name a method without calling it, so the name can reach a body with arguments nobody sees.
  CONSTRUCTOR_NAMING_OPS = %w[LOADSYM ALIAS KARG KEY_P].freeze

  # [irep label, mandatory argument position] => [sites, position], as entry_arg_candidates.
  def constructor_pool_candidates
    return @constructor_pool_candidates if defined?(@constructor_pool_candidates)

    @constructor_pool_status = {}
    @constructor_pool_candidates = {}
    refusal = constructor_pools_refusal
    if refusal
      @constructor_pool_refusal = refusal
    else
      build_constructor_pool_candidates
    end
    @constructor_pool_candidates
  end

  # Why the whole analysis is off, or nil.
  def constructor_pools_refusal
    return 'BC2CPP_CONSTRUCTOR_POOLS=0' if ENV.fetch('BC2CPP_CONSTRUCTOR_POOLS', '1') == '0'

    world = @closed_world
    return 'no outside-source scan' unless @foreign_method_names && @outside_tokens
    return 'no closed world' unless world && world.global_refusal.nil? && world.exact_instances_singleton_free?
    return 'non-standard new/allocate lookup' unless world.standard_constructor_lookup?
    return 'Class has a mixin' unless Array(@included_modules['Class']).empty? && Array(@prepended_modules['Class']).empty? &&
                                      !@unknown_mixins.include?('Class')
    return 'Ruby-defined new' unless (@registry['new'] || []).all? { |d| d.owner == '<native>' }
    return 'initialize defined outside a class' unless constructor_initializers_in_classes?
    return 'new/initialize installed out of sight' if %w[new initialize].any? { |name| world.unknown_def?(name) }

    constructor_naming_refusal
  end

  # BC2CPP_CTOR_KEYWORDS=0 turns the keyword-call rule off (a keyword call, or a keyword parameter, refuses the initialize).
  def constructor_keywords_enabled?
    ENV.fetch('BC2CPP_CTOR_KEYWORDS', '1') != '0'
  end

  # CONSTRUCTOR_KEYWORDS: the positional count of a call that passes literal keywords (`new(a, b, k: v)`, n=2|nk=1), or
  # nil for a splat, a packed kdict (`**opts`, nk=*) or a call without keywords. The keywords occupy the registers after
  # the positionals; vm.c OP_ENTER hands them to a callee with keyword parameters as its kdict and appends them to the
  # positionals of one without (an extra trailing Hash), so argument k <= n is the k-th positional either way.
  def constructor_keyword_argc(insn)
    return nil unless constructor_keywords_enabled?

    n = insn.n_spec
    nk = insn.nk_spec
    return nil unless n && n != '*' && nk && nk != '*' && nk.to_i.positive?

    n.to_i
  end

  # Does a keyword call with +positionals+ positional arguments leave all of D's mandatory positions (1..mand) as plain
  # positionals? A call with fewer raises in ENTER or, without keyword parameters, would see the keyword Hash there.
  def constructor_keyword_site_ok?(d, positionals)
    positionals >= mandatory_arity(@ireps[d.irep])
  end

  # Every Ruby initialize belongs to a declared class: a module's or singleton's one could sit between a
  # class and its superclass's initialize, or run with an argument list the sites do not show.
  def constructor_initializers_in_classes?
    (@registry['initialize'] || []).all? { |d| d.owner == '<native>' || @closed_world.class_declared?(d.owner) }
  end

  # A name in an op that does not call it can reach the body with arguments nobody sees. The one shape
  # kept per class is `alias_method :other, :initialize` (or `alias other initialize`) in a class body,
  # which makes that class's initialize callable as `other`: that initialize is withdrawn
  # (@constructor_aliased). Anything else naming new/initialize turns the analysis off.
  def constructor_naming_refusal
    @constructor_aliased = Set.new
    string_spelled = false
    @ireps.each do |label, irep|
      insns = irep.instructions
      insns.each_with_index do |insn, idx|
        return 'explicit initialize call' if insn.sym == 'initialize' && CONSTRUCTOR_NEW_OPS.include?(insn.op)

        string_spelled ||= insn.op == 'STRING' && %w[new initialize].include?(irep.pool[insn.pool_index.to_i])
        next unless CONSTRUCTOR_NAMING_OPS.include?(insn.op)

        names = [insn.sym, (insn.first_of(:name)&.value if insn.op == 'ALIAS')].compact
        next unless names.any? { |name| %w[new initialize].include?(name) }

        klass = constructor_alias_class(label, insn, insns, idx)
        return "#{insn.op} :#{names.join('/')} names new/initialize" unless klass

        @constructor_aliased << klass
      end
    end
    return 'new/initialize spelled as a String where a computed name can reach it' if string_spelled && DynamicNames.analyze(@ireps).last

    nil
  end

  # The class whose body aliases its initialize under another name, or nil for any other use.
  def constructor_alias_class(label, insn, insns, idx)
    klass = constructor_body_classes[label]
    return nil unless klass

    other = ->(name) { name && !%w[initialize new].include?(name) }
    return (insn.first_of(:name)&.value == 'initialize' && other.call(insn.sym) ? klass : nil) if insn.op == 'ALIAS'
    return nil unless insn.op == 'LOADSYM' && insn.sym == 'initialize'

    call = insns[idx + 1]
    prior = idx.positive? ? insns[idx - 1] : nil
    alias_call = call&.op == 'SSEND' && call.sym == 'alias_method' && call.plain_fixed_argc? && call.argc == 2 &&
                 call.reg.to_i + 2 == insn.reg.to_i && prior&.op == 'LOADSYM' && prior.reg.to_i == call.reg.to_i + 1 &&
                 other.call(prior.sym)
    alias_call ? klass : nil
  end

  # Class body irep label => the class path it opens (CLASS or MODULE with an implicit or `::` outer).
  def constructor_body_classes
    @constructor_body_classes ||= begin
      map = {}
      children = @ireps.values.flat_map { |irep| Array(irep.reps) }.to_set
      walk = lambda do |label, namespace|
        irep = @ireps.fetch(label)
        pending = nil
        irep.instructions.each_with_index do |insn, idx|
          case insn.op
          when 'CLASS', 'MODULE'
            outer = irep.last_writer(idx - 1, insn.reg)&.op
            full = outer == 'LOADNIL' ? [namespace, insn.sym].compact.join('::') : (insn.sym if outer == 'OCLASS')
            pending = [insn.reg_token, full, idx]
          when 'EXEC'
            if pending && pending[0] == insn.reg_token && pending[2] == idx - 1 && pending[1]
              child = irep.reps[insn.block_index]
              map[child] = pending[1]
              walk.call(child, pending[1])
            end
            pending = nil
          end
        end
      end
      @ireps.each_key { |label| walk.call(label, nil) unless children.include?(label) }
      map
    end
  end

  def build_constructor_pool_candidates
    found = { sites: Hash.new { |h, k| h[k] = [] }, broken: {}, open_argc: [], rooted: [], stats: Hash.new(0) }
    @constructor_pool_stats = found[:stats]

    @ireps.each_value do |irep|
      owner = entry_arg_body_owner[irep.label]
      irep.instructions.each_with_index do |insn, idx|
        if insn.op == 'SUPER'
          constructor_super_site(irep, idx, insn, owner, found)
        elsif CONSTRUCTOR_NEW_OPS.include?(insn.op) && insn.sym == 'new'
          constructor_new_site(irep, idx, insn, owner, found)
        end
      end
    end

    @constructor_aliased.each do |klass|
      target = constructor_init_target(klass)
      found[:broken][target.irep] ||= "initialize aliased in #{klass}" if target
    end

    (@registry['initialize'] || []).each do |d|
      next unless d.irep

      status, here = constructor_pool_status(d, found)
      @constructor_pool_status[d.irep] = status
      next unless status == :ok

      (1..mandatory_arity(@ireps[d.irep])).each { |k| @constructor_pool_candidates[[d.irep, k]] = [here, k] }
    end
  end

  # [:ok, sites], or [why D is not a candidate, nil].
  def constructor_pool_status(d, found)
    broken = found[:broken]
    return [broken[:all], nil] if broken[:all]

    irep = @ireps[d.irep]
    fields = irep.enter ? irep.enter.enter_fields : []
    mand = fields[0].to_i
    opt = fields[1].to_i
    # Positions 1..mand hold the first positional arguments of every call that gets as far as the body, whatever
    # follows them (optional, rest, block); a post-mandatory or keyword parameter is left out to stay clear of ENTER's hash handling.
    # CONSTRUCTOR_KEYWORDS: keyword parameters (fields 4 and 5) leave positions 1..mand alone (vm.c OP_ENTER keeps the
    # caller's keywords in a separate kdict register when the callee accepts any), so only a post-mandatory parameter
    # is still refused. With the switch off the old rule refuses all three.
    return [:arity, nil] unless mand.positive? && fields[3].to_i.zero? && (constructor_keywords_enabled? || fields[4..5].all? { |f| f.to_i.zero? })
    return [broken[d.irep], nil] if broken[d.irep]

    reach = constructor_reach(d)
    return [:hierarchy, nil] unless reach
    return [:outside_name, nil] if reach.any? { |klass| @closed_world.outside_spells_class?(klass) }

    # A call with fewer than mand or more than mand + opt positionals raises in ENTER (no rest parameter).
    enters = ->(argc) { argc.between?(mand, fields[2].to_i.positive? ? Float::INFINITY : mand + opt) }
    clash = found[:open_argc].find { |argc, _| enters.call(argc) }
    return ["unresolved new with #{clash[0]} arguments (#{clash[1]})", nil] if clash

    # A `new` in a method of X builds X or a descendant, so it reaches D when X is, or is above, a class that runs D.
    rooted = found[:rooted].select { |root, _argc, _site| reach.any? { |klass| constructor_chain(klass).include?(root) } }
    return ['new with a splat or keyword', nil] if rooted.any? { |_root, argc, _site| argc.nil? }

    here = (found[:sites][d.irep] + rooted.map(&:last)).select { |(_ir, _i, _recv, argc, _own)| enters.call(argc) }
    return [:no_sites, nil] if here.empty?

    [:ok, here]
  end

  # The classes that run D (D's class and the descendants resolving to it), or nil when the set is not
  # fully visible.
  def constructor_reach(d)
    world = @closed_world
    return nil unless constructor_plain_chain?(d.owner)

    hierarchy = world.class_hierarchy(d.owner)
    return nil unless hierarchy && hierarchy[:wild].empty?

    ([d.owner] + hierarchy[:descendants].to_a).select { |klass| constructor_init_target(klass)&.irep == d.irep }
  end

  # Superclass chain of declared classes ending at an implicit Object.
  def constructor_plain_chain?(klass)
    seen = Set.new
    while seen.add?(klass)
      return false unless @closed_world.class_declared?(klass)

      parent = @superclass_of[klass]
      return true if parent == :none
      return false unless parent.is_a?(String)

      klass = parent
    end
    false
  end

  # The initialize an instance of +klass+ runs, nil when it is Object's or unknowable.
  def constructor_init_target(klass)
    seen = Set.new
    while klass.is_a?(String) && seen.add?(klass)
      definition = numeric_init_definition(klass)
      return nil if definition == :unknown
      return definition if definition

      klass = @superclass_of[klass]
    end
    nil
  end

  # Every initialize definition the classes in +classes+ run.
  def constructor_targets(classes)
    classes.filter_map { |klass| constructor_init_target(klass) }.uniq
  end

  # +klass+ and its superclasses, with the implicit Object, Kernel and BasicObject at the end.
  def constructor_chain(klass)
    @constructor_chain ||= {}
    @constructor_chain[klass] ||= begin
      chain = []
      while klass.is_a?(String) && !chain.include?(klass)
        chain << klass
        klass = @superclass_of[klass]
      end
      chain + %w[Object Kernel BasicObject]
    end
  end

  def constructor_new_site(irep, idx, insn, owner, found)
    stats = found[:stats]
    stats[:new] += 1
    argc = insn.op.end_with?('0') ? 0 : (insn.plain_fixed_argc? ? insn.argc : nil)
    # No initialize this analysis pools takes zero arguments: a count of 0 raises in ENTER.
    return stats[:no_args] += 1 if argc&.zero?

    site = [irep, idx, insn.reg.to_i, argc, owner]
    kw_argc = constructor_keyword_argc(insn) if argc.nil?
    classes = constructor_named_classes(irep, idx, insn) unless insn.op.start_with?('SS')
    if classes
      targets = constructor_targets(classes)
      stats[targets.empty? ? :named_no_ruby_init : :named] += 1
      targets.each do |d|
        if kw_argc && constructor_keyword_site_ok?(d, kw_argc)
          # CONSTRUCTOR_KEYWORDS: a keyword call is a site of its positionals.
          stats[:keyword_named] += 1
          found[:sites][d.irep] << [irep, idx, insn.reg.to_i, kw_argc, owner]
          next
        end
        if kw_argc
          stats[:keyword_refused_short] += 1
          found[:broken][d.irep] ||= "keyword new with fewer positionals than mandatory parameters at #{irep.label}:#{idx}"
          next
        end
        found[:sites][d.irep] << site
        found[:broken][d.irep] ||= "new with a splat or keyword at #{irep.label}:#{idx}" if argc.nil?
      end
    elsif (root = constructor_new_root(irep, idx, insn, numeric_irep_owner[irep.label]))
      stats[:rooted] += 1
      found[:rooted] << [root, argc, site]
    elsif argc.nil?
      stats[:unresolved_unknown_argc] += 1
      found[:broken][:all] = "new with a splat or keyword on an unknown receiver at #{irep.label}:#{idx}"
    else
      stats[:unresolved] += 1
      found[:open_argc] << [argc, "new at #{File.basename(irep.file.to_s)} #{irep.label}:#{idx}"]
    end
  end

  # The class X whose method the `new` is in when its receiver is X's own class object: the implicit-self
  # `new` of `def self.m` in X, or `self.class.new` in an instance method of X.
  def constructor_new_root(irep, idx, insn, owner)
    return nil unless owner && !@closed_world.module_declared?(owner.owner.delete_suffix('.singleton'))

    if insn.op.start_with?('SS')
      owner.owner.end_with?('.singleton') ? owner.owner.delete_suffix('.singleton') : nil
    else
      constructor_self_class_root(irep, idx, insn, owner)
    end
  end

  # `self.class.new`: the receiver's one reaching definition is a SEND0 `class` on the method's own `self`.
  def constructor_self_class_root(irep, idx, insn, owner)
    return nil if owner.owner.end_with?('.singleton') || !(@registry['class'] || []).all? { |d| d.owner == '<native>' }

    defs = BytecodeIR.reaching_definitions(irep, idx, insn.reg.to_s, through_handlers: true)
    return nil unless defs&.size == 1 && !defs.first.entry?

    send = irep.instructions[defs.first.index]
    return nil unless irep.label == owner.irep && send.sym == 'class'
    return owner.owner if send.op == 'SSEND0'
    return nil unless send.op == 'SEND0'

    selves = BytecodeIR.reaching_definitions(irep, defs.first.index, send.reg.to_s, through_handlers: true)
    selves&.size == 1 && selves.first.entry? && selves.first.reg == '0' ? owner.owner : nil
  end

  # The declared classes the constant receiver of the `new` at +idx+ can name, or nil when some
  # definition reaching it is not a constant that only names classes.
  def constructor_named_classes(irep, idx, insn)
    defs = BytecodeIR.reaching_definitions(irep, idx, insn.reg.to_s, through_handlers: true)
    return nil if defs.nil? || defs.empty?

    names = defs.map do |definition|
      next nil if definition.entry?

      writer = irep.instructions[definition.index]
      case writer.op
      when 'GETCONST' then writer.const_name
      when 'GETMCNST' then writer.mcnst_name
      end
    end
    return nil unless names.all? && names.all? { |name| @closed_world.class_valued_constant?(name) }

    names.uniq.flat_map { |name| @closed_world.classes_named(name) }
  end

  # `super` in an initialize reaches the superclass's initialize with the arguments it passes.
  def constructor_super_site(irep, idx, insn, owner, found)
    return unless owner && owner.name == 'initialize'

    parent = @superclass_of[owner.owner]
    return unless parent.is_a?(String)

    target = constructor_init_target(parent)
    return unless target&.irep

    # A bare `super` forwards the method's own arguments through ARGARY, an op the flow does not model, so only
    # the explicit form can ever prove anything; the other withdraws the target.
    kw_argc = constructor_keyword_argc(insn)
    if insn.plain_fixed_argc?
      found[:stats][:super_explicit] += 1
      found[:sites][target.irep] << [irep, idx, insn.reg.to_i, insn.argc, owner]
    elsif kw_argc && constructor_keyword_site_ok?(target, kw_argc)
      found[:stats][:super_keyword] += 1
      found[:sites][target.irep] << [irep, idx, insn.reg.to_i, kw_argc, owner]
    else
      found[:stats][:super_unmodelled] += 1
      found[:broken][target.irep] = "super with unmodelled arguments at #{irep.label}:#{idx}"
    end
  end

  # Lines for the diagnostic: the refusal, or one per constructor and why it is not pooled.
  def constructor_pool_report
    constructor_pool_candidates
    return ["  off: #{@constructor_pool_refusal}"] if @constructor_pool_refusal

    lines = ["  SITES #{@constructor_pool_stats.sort.map { |k, v| "#{k}=#{v}" }.join(' ')}"]
    (@registry['initialize'] || []).each do |d|
      status = @constructor_pool_status[d.irep] or next
      if status == :ok
        lines << "  CTOR #{d.owner}#initialize pooled"
        @constructor_pool_candidates.each_key { |(label, k)| lines << "  CTORARG #{d.owner}#initialize arg#{k} #{constructor_arg_state(label, k)}" if label == d.irep }
      else
        lines << "  CTOR #{d.owner}#initialize refused: #{status}#{constructor_arity_note(d, status)}"
      end
    end
    lines.sort
  end

  # " (req=2 opt=0 rest=0 post=0 key=1 kdict=0)" for an arity refusal, so the report says which shape it was.
  def constructor_arity_note(d, status)
    return '' unless status == :arity

    f = (@ireps[d.irep].enter ? @ireps[d.irep].enter.enter_fields : []).map(&:to_i)
    " (req=#{f[0]} opt=#{f[1]} rest=#{f[2]} post=#{f[3]} key=#{f[4]} kdict=#{f[5]})"
  end

  # What the fixpoint made of one candidate argument: its pools, or the producers that dropped it.
  def constructor_arg_state(label, k)
    cls = @class_arg_pools && @class_arg_pools[[label, k]]
    num = @entry_arg_numeric && @entry_arg_numeric[[label, k]]
    fix = @entry_arg_fixnum&.include?([label, k])
    state = []
    state << "class=#{class_mask_name(cls)}" if cls
    state << "numeric=#{numeric_mask_name(num)}" if num
    state << 'fixnum' if fix
    return state.join(' ') unless state.empty?

    sites, = @constructor_pool_candidates.fetch([label, k])
    culprits = sites.filter_map do |irep, idx, recv, _argc, _owner|
      mask = return_class_raw_mask(irep, idx, (recv + k).to_s)
      next if mask && !mask.anybits?(CLASS_POOL_UNSHIPPABLE)

      writer = irep.walk_writers(idx - 1, (recv + k).to_s, skip_ops: ['BLOCK', *READ_ONLY_OPCODE_SKIP], follow_moves: true,
                                                          exhausted: ->(last) { last == '0' ? 'self' : 'incoming_arg' }) do |ins|
        %w[SEND SEND0 SSEND SSEND0 SENDB].include?(ins.op) ? "send:#{ins.sym}" : ins.op.downcase
      end
      writer.is_a?(String) ? writer : 'unknown'
    end
    "dropped<#{culprits.tally.map { |c, n| "#{c}x#{n}" }.join(',')}>"
  end
end
