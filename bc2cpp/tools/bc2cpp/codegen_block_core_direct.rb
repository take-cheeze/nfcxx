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

  # Only a literal-block site of engine code in a closed world: the proofs below are about the
  # engine's Ruby, and a core body never binds an engine method (ADR 0264).
  def block_core_direct_wrap(d, recv, name, argv, tail)
    return tail unless @call_block_expr && @closed_world && @native_name_sources && !@compiling_core
    return tail if tail.include?('bc2cpp_nomethod')

    arms = block_core_arms(name, argv.size)
    return tail if arms.empty?

    branches = arms.map do |arm|
      args, = direct_call_args(arm[:target], argv, arm[:impl])
      "if (M->c == M->root_c && #{format(arm[:guard], r: recv)}) {\n" \
        "    r#{d} = #{arm[:impl]}(M, #{([recv] + args).join(', ')});\n" \
        '  } else '
    end.join
    "// BLOCK_CORE_DIRECT :#{name} -- exact #{arms.map { |arm| arm[:class] }.join('/')} receiver at the root " \
      "context calls the compiled core body with the block\n" \
      "  #{branches}{\n" \
      "    #{tail.chomp}\n" \
      "  }\n"
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
    return nil if symbol_installed_names.nil? || symbol_installed_names.include?(name)
    return nil if (@registry[name] || []).any? { |definition| chain.include?(definition.owner) }

    chain.each do |owner|
      return nil unless block_core_owner_plain?(owner, name)

      defs = block_core_index[[owner, name]]
      return block_core_callable(defs.first, arity) if defs&.one?
      return nil if defs
    end
    nil
  end

  # Nothing on `owner` could take `name` from the compiled core definition (or hide it from
  # the chain walk): no native registration, no prepend, no outside Ruby definer.
  def block_core_owner_plain?(owner, name)
    return false if Array(@prepended_modules[owner]).any? || @unknown_mixins.include?(owner)
    return false if block_core_native_registered?(owner, name)

    @closed_world.core_ruby_arm_safe?(name, owner)
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
  def block_core_callable(definition, arity)
    irep = @ireps.fetch(definition.irep)
    return nil unless takes_block_param?(irep) && pure_mandatory_or_optional_arity?(irep)

    mand = mandatory_arity(irep)
    return nil unless arity >= mand && arity <= mand + optional_arity(irep)
    return nil unless !@only_owners || @only_owners.include?(definition.owner) || @other_owners&.include?(definition.owner)
    return nil unless block_core_clean?(definition.irep)

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
