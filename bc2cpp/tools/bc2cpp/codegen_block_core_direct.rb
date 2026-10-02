# frozen_string_literal: true

require 'set'
require_relative 'core_defs'
require_relative 'foreign_definers'
require_relative 'native_expression_devirt'

# BLOCK_CORE_DIRECT (docs/adr/0270): exact-builtin-class arms that call the compiled body of a
# block-taking core method (Array#each, Hash#select, Integer#times, Enumerable#collect, ...)
# directly, in front of the dynamic send of a literal-block site. The block is the RProc the
# site already built; every receiver an arm does not name dispatches exactly as before.
#
# These bodies are not direct-call targets for the compiler at large (ADR 0269): the guard that
# hands a Fiber's frames to the bytecode lives in the registered entry, which a direct `_impl`
# call skips. Each arm therefore repeats the entry's condition, `M->c == M->root_c`; the
# `each_is_builtin` test of an Enumerable entry is a fact of the exact classes named here.
#
# Prepended to CodeGen like NativeCoreDirectFallback (ADR 0257), so it wraps
# native_direct_dynamic_line (a site with no guard chain) and guarded_fallback_line (a chain's
# else) without editing them.
module BlockCoreDirectFallback
  # guard: the exact-class test (an instance whose class is a subclass or has a singleton
  # class fails it); chain: the lookup order of that class among the owners with block
  # methods in mruby's own Ruby.
  RECEIVERS = {
    'Array' => { guard: 'mrb_array_p(%<r>s) && mrb_obj_ptr(%<r>s)->c == M->array_class', chain: %w[Array Enumerable] },
    'Hash' => { guard: 'mrb_hash_p(%<r>s) && mrb_obj_ptr(%<r>s)->c == M->hash_class', chain: %w[Hash Enumerable] },
    'Range' => { guard: 'mrb_range_p(%<r>s) && mrb_obj_ptr(%<r>s)->c == M->range_class', chain: %w[Range Enumerable] },
    'Integer' => { guard: 'mrb_integer_p(%<r>s)', chain: %w[Integer Numeric Comparable] }
  }.freeze

  def native_direct_dynamic_line(d, recv, name, argv)
    block_core_direct_wrap(d, recv, name, argv, super)
  end

  def guarded_fallback_line(d, recv, name, argv, listed, site)
    block_core_direct_wrap(d, recv, name, argv, super)
  end

  # A literal-block site in a closed world: engine code, or a core body of the same program (the
  # core compile hides the world from its own static-binding proofs but the outside-definer and
  # installer facts below are about the whole program).
  def block_core_world
    @closed_world || @core_program_world
  end

  def block_core_direct_wrap(d, recv, name, argv, tail)
    return tail unless block_core_direct_enabled? && @call_block_expr && block_core_world && @native_name_sources
    return tail if tail.include?('bc2cpp_nomethod')

    arms = block_core_arms(name, argv.size)
    if arms.empty?
      reasons = @block_core_reasons && @block_core_reasons[[name, argv.size]]
      return tail unless reasons&.any?

      return "// BLOCK_CORE_WHY :#{name}/#{argv.size} -- #{reasons.uniq.join('; ')}\n  #{tail}"
    end

    # EXACT_CORE_RECEIVER (ADR 0280): a proven exact class leaves one arm and no class test. The
    # else stays: a Fiber's frames need a real callinfo to reach the bytecode (ADR 0269).
    site = exact_core_site_for(recv, name)
    exact = site ? arms.select { |arm| arm[:class] == site[:klass] } : []
    exact_class = !exact.empty?
    arms = exact if exact_class
    sole_call = nil
    branches = arms.map do |arm|
      args, = direct_call_args(arm[:target], argv, arm[:impl])
      # YIELD_REACH (ADR 0283): with a yield-free block and a body that cannot suspend a Fiber on its
      # own, no yield can cross the callee's frame, so the root-context test is not needed.
      unguarded = block_core_arm_unguarded?(arm)
      tests = []
      tests << 'M->c == M->root_c' unless unguarded
      tests << format(arm[:guard], r: recv) unless exact_class
      call = "r#{d} = #{arm[:impl]}(M, #{([recv] + args).join(', ')});"
      sole_call = call if tests.empty? && exact_class && arms.size == 1 && block_arm_reach?
      "if (#{tests.empty? ? 'true' : tests.join(' && ')}) {\n" \
        "    #{call}\n" \
        '  } else '
    end.join
    # BLOCK_ARM_REACH (ADR 0310): a proven class and a block that cannot reach a yield leave nothing
    # for the dynamic else to answer.
    if sole_call
      return "// BLOCK_CORE_DIRECT :#{name} -- proven #{arms.first[:class]} receiver, yield-free block: " \
             "calls the compiled core body, no dynamic send\n  #{sole_call}\n"
    end

    "// BLOCK_CORE_DIRECT :#{name} -- #{exact_class ? 'proven' : 'exact'} #{arms.map { |arm| arm[:class] }.join('/')} receiver at the root " \
      "context calls the compiled core body with the block\n" \
      "  #{branches}{\n" \
      "    #{tail.chomp}\n" \
      "  }\n"
  end

  # Is the site's literal block proved yield-free and the arm's body relaxable? Recorded for the
  # build-time table (once per site).
  def block_core_arm_unguarded?(arm)
    region = @call_block_region
    block_free = !!(region && region[:direct_entry] && region[:yield_free])
    unguarded = block_free && core_body_relaxable?(arm[:target].irep)
    site = (@yf_arm_sites ||= {})[[region && region[:parent_irep]&.label, region && region[:block_addr]]] ||=
             { block_free: false, arms: Set.new, unguarded: Set.new }
    site[:block_free] = block_free
    site[:arms] << arm[:class]
    site[:unguarded] << arm[:class] if unguarded
    unguarded
  end

  # BC2CPP_BLOCK_CORE_WHY=1 reports, on stderr, why a class gets no arm for a name.
  def block_core_refuse(klass, name, arity, reason)
    (@block_core_reasons ||= Hash.new { |hash, key| hash[key] = [] })[[name, arity]] << "#{klass}: #{reason}" if
      ENV['BC2CPP_BLOCK_CORE_WHY'] == '1'
    nil
  end

  # BC2CPP_BLOCK_CORE_DIRECT=0 turns the arms off, to measure them against the plain send.
  def block_core_direct_enabled?
    ENV['BC2CPP_BLOCK_CORE_DIRECT'] != '0'
  end

  # [{class:, guard:, target:, impl:}] for `name` called with `arity` arguments and a block.
  def block_core_arms(name, arity)
    @block_core_arms ||= {}
    @block_core_arms.fetch([name, arity]) do
      @block_core_arms[[name, arity]] =
        RECEIVERS.filter_map do |klass, spec|
          target = block_core_target(klass, spec[:chain], name, arity)
          next unless target

          { class: klass, guard: spec[:guard], target: target, impl: "#{cpp_name(target.owner, target.name)}_impl" }
        end
    end
  end

  # The compiled core definition that `klass` answers `name` with, or nil when anything else
  # could: a native or engine definition on the way, a prepend or unattributed mixin, an
  # outside definer, a dynamic installer.
  def block_core_target(klass, chain, name, arity)
    return block_core_refuse(klass, name, arity, 'a dynamic installer names it') if symbol_installed_names.nil? || symbol_installed_names.include?(name)
    if (@registry[name] || []).any? { |definition| chain.include?(definition.owner) }
      return block_core_refuse(klass, name, arity, 'a project definition on the chain')
    end

    chain.each do |owner|
      return block_core_refuse(klass, name, arity, "#{owner} is not plain (native, prepend, mixin or outside definer)") unless block_core_owner_plain?(owner, name)

      defs = block_core_index[[owner, name]]
      return block_core_callable(defs.first, arity, klass, name) if defs&.one?
      return block_core_refuse(klass, name, arity, "#{defs.size} compiled definitions on #{owner}") if defs
    end
    block_core_refuse(klass, name, arity, 'no compiled core definition on the chain')
  end

  # Nothing on `owner` could take `name` from the compiled core definition (or hide it from
  # the chain walk): no native registration, no prepend, no outside Ruby definer.
  def block_core_owner_plain?(owner, name)
    return false if Array(@prepended_modules[owner]).any? || @unknown_mixins.include?(owner)
    return false if block_core_native_registered?(owner, name)

    block_core_world.core_ruby_arm_safe?(name, owner)
  end

  def block_core_native_registered?(owner, name)
    registrations, opaque = block_core_registrations
    return true if opaque.fetch(name, []).any? { |o| o.nil? || o == owner }

    registrations.fetch(name, []).any? { |registration| registration[:owner] && registration[:owner][:class_name] == owner }
  end

  def block_core_registrations
    @block_core_registrations ||= NativeExpressionDevirt.class_registrations(@native_name_sources.values.flatten.uniq)
  end

  # [owner, name] => the compiled core definitions of that name, aliases included.
  def block_core_index
    @block_core_index ||= begin
      index = Hash.new { |hash, key| hash[key] = [] }
      (self.class.core_hidden_defs || []).each do |definition|
        next unless definition.irep

        index[[definition.owner, definition.name]] << definition
        (self.class.core_aliases&.dig([definition.owner, definition.name]) || []).each do |alias_name|
          index[[definition.owner, alias_name]] << definition
        end
      end
      index.default_proc = nil
      index
    end
  end

  # `definition` when a call with `arity` arguments and a block can be a plain `_impl` call:
  # the callee takes the block, the arity is one its signature models, its body reads nothing
  # of the caller's frame, it compiles clean and its owner is emitted by this link.
  def block_core_callable(definition, arity, klass = nil, name = nil)
    irep = @ireps.fetch(definition.irep)
    why = ->(reason) { block_core_refuse(klass, name, arity, "#{definition.owner}##{definition.name}: #{reason}") }
    return why.call('does not take a block') unless takes_block_param?(irep)
    return why.call('signature or frame use not modelled by direct calls') unless pure_mandatory_or_optional_arity?(irep)

    mand = mandatory_arity(irep)
    unless arity >= mand && arity <= mand + optional_arity(irep)
      return why.call("arity #{arity} outside #{mand}..#{mand + optional_arity(irep)}")
    end
    unless !@only_owners || @only_owners.include?(definition.owner) || @other_owners&.include?(definition.owner)
      return why.call('owner not emitted by this link')
    end
    return why.call('does not compile clean') unless block_core_clean?(definition.irep)

    definition
  end

  # compiles_clean? for a body whose entry carries the ADR 0269 guard: the guard is why that
  # predicate says no, and the arms above supply it.
  def block_core_clean?(label)
    return false if hot_only_excluded?(label)
    return @clean_cache[label] if @clean_cache.key?(label)
    return false if @probing.include?(label)

    @probing << label
    begin
      result = with_fresh_method_state { compile_method(label) }
      @clean_cache[label] = !result[:code].include?('#error')
    ensure
      @probing.delete(label)
    end
  end
end

CodeGen.prepend(BlockCoreDirectFallback)
