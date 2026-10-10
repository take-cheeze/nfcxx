# frozen_string_literal: true

require_relative 'native_owner_map'

# CodeGen: NATIVE_OWNER_MAP (docs/adr/0397). A by-name else gets, ahead of it, one exact-class arm per Ruby
# definition of the name, when native_owner_map.rb proves no native definition of the name on that class.
# BC2CPP_NATIVE_OWNER_MAP=0 emits none of it; =strict also refuses while mruby core registers computed names.
class CodeGen
  class << self
    # The NATIVE_SRCS paths bc2cpp.rb read (nil without them: no map, no arm).
    attr_accessor :native_source_paths
  end

  # Program-wide: one map per list of native sources (a nested CodeGen reuses it).
  NATIVE_OWNER_MAP_CACHE = {}

  # nil when off, :strict or :trusted (the default).
  def native_owner_map_mode
    case ENV['BC2CPP_NATIVE_OWNER_MAP']
    when '0' then nil
    when 'strict' then :strict
    else :trusted
    end
  end

  def native_owner_map
    paths = self.class.native_source_paths
    return nil unless paths

    NATIVE_OWNER_MAP_CACHE[paths] ||= NativeOwnerMap.build(paths)
  end

  # The arms of a by-name send of `name` on `recv`, each ending in `} else ` for the caller to close; '' when
  # off, when the send takes a block, or when the site is not proven.
  def native_owner_map_arms(d, recv, name, argv)
    return '' unless native_owner_map_mode && @closed_world && !@call_block_expr

    targets = native_owner_map_targets(name, argv.size)
    return '' if targets.nil? || targets.empty?

    NATIVE_OWNER_MAP_TALLY[:arms_emitted] += 1
    branches = targets.map do |target|
      impl = "#{cpp_name(target.owner, target.name)}_impl"
      call_argv, = direct_call_args(target, argv, impl)
      "if (#{owner_class_ptr_expr(target.owner)} == mrb_obj_class(M, #{recv})) {\n" \
        "    r#{d} = #{impl}(M, #{([recv] + call_argv).join(', ')});\n  } else "
    end
    "  // NATIVE_OWNER_MAP :#{name} -- exact instance of a Ruby definition's class, no native definer (ADR 0397)\n" \
      "  #{branches.join}"
  end

  # The Ruby definitions a proven site dispatches to, sorted by owner, or nil. Every Ruby definition of the
  # name must be an eligible candidate and every candidate owner must be proven by the map: one that is not
  # leaves the whole site to the by-name else.
  def native_owner_map_targets(name, arity)
    @native_owner_map_targets ||= {}
    @native_owner_map_targets.fetch([name, arity]) do
      @native_owner_map_targets[[name, arity]] = native_owner_map_targets_uncached(name, arity)
    end
  end

  # The sites decided, by reason (:proven or a refusal); written by BC2CPP_NATIVE_OWNER_MAP_REPORT.
  NATIVE_OWNER_MAP_TALLY = Hash.new(0)

  def native_owner_map_targets_uncached(name, arity)
    targets, reason = native_owner_map_decide(name, arity)
    NATIVE_OWNER_MAP_TALLY[reason || :proven] += 1
    targets
  end

  # [targets, nil] for a proven site, [nil, reason] for any other.
  def native_owner_map_decide(name, arity)
    map = native_owner_map
    return [nil, :no_map] unless map
    return [nil, :devirt_blocked] if devirt_blocked_name?(name)

    every = (@registry[name] || []).reject { |definition| definition.owner == '<native>' }
    return [nil, :no_ruby_definition] if every.empty?
    return [nil, :repeated_owner] if every.map(&:owner).uniq.size != every.size
    refusal = @closed_world.exact_arm_refusal(name, symbol_installed_names)
    return [nil, refusal] if refusal

    # A core body is compiled into every build: its arms name core definitions only (see core_targets).
    defs = core_targets(every) || []
    return [nil, :no_candidate] if defs.empty?
    return [nil, :ineligible_candidate] unless defs.all? { |definition| native_owner_map_candidate?(definition, arity) }

    trusted = native_owner_map_mode == :trusted
    defs.each do |definition|
      verdict = NativeOwnerMap.verdict(map, name, [definition.owner], core_dynamic_trusted: trusted)
      return [nil, :"owner_#{verdict[1]}"] unless verdict == [:proven]
    end
    [defs.sort_by(&:owner), nil]
  end

  # Per distinct name and arity; arms_emitted counts sites.
  at_exit do
    path = ENV['BC2CPP_NATIVE_OWNER_MAP_REPORT']
    File.write(path, NATIVE_OWNER_MAP_TALLY.sort_by { |k, _| k.to_s }.map { |k, v| "#{k} #{v}\n" }.join) if path
  end

  # A definition an arm can call directly: public, compiled, arity-matching, of a declared class (not a module,
  # singleton or accessor), with no prepend in front of it.
  def native_owner_map_candidate?(definition, arity)
    owner = definition.owner
    return false unless definition.irep && definition.kind != :ivar_accessor && definition.visibility == :public
    return false if owner.end_with?('.singleton') || CodeGen.module_names&.include?(owner)
    return false unless @closed_world.class_declared?(owner) && @closed_world.stable_class_constant?(owner)
    return false unless Array(@prepended_modules[owner]).empty?
    return false if @only_owners && !@only_owners.include?(owner) && !@other_owners&.include?(owner)
    return false if core_guarded_def?(definition) && !core_body_relaxable?(definition.irep)
    return false unless compiles_clean?(definition.irep)

    t_irep = @ireps.fetch(definition.irep)
    poly_arity_fits?(t_irep, arity, false) && native_arg_types(definition, mandatory_arity(t_irep)).compact.empty?
  end
end
