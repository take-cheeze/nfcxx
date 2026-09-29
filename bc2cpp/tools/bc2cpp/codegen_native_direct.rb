# frozen_string_literal: true

require_relative 'native_direct'

# NATIVE_DIRECT (docs/adr/0253): exact-class arms that call the RGSS natives'
# frame-independent entry points (include/rgss_construct.hxx), placed in the
# else of a call site's guard chain. Every other receiver keeps the chain's
# fallback: ordinary dispatch, or, in a closed world where the arms name every
# native class that answers the name, the proven-dead nomethod raise.
#
# Prepended to CodeGen, so it wraps guarded_fallback_line (codegen_send.rb)
# without editing it.
module NativeDirectFallback
  def guarded_fallback_line(d, recv, name, argv, listed, site)
    plan = native_direct_plan(name, argv.size, closed_world_site: !site.nil?)
    return super unless plan

    tail = plan[:lift] ? @closed_world.with_native_arms(name) { super } : super
    native_direct_wrap(d, recv, name, argv, plan[:arms], tail)
  end

  # The last-resort dispatch of a site with no guard chain at all.
  def native_direct_dynamic_line(d, recv, name, argv)
    line = dynamic_dispatch_line(d, recv, name, argv)
    plan = native_direct_plan(name, argv.size, closed_world_site: false)
    plan ? native_direct_wrap(d, recv, name, argv, plan[:arms], line) : line
  end

  # The zero-argument RGSS arms (compile_send) are emitted ahead of the chain;
  # record their owners so this wrapper does not repeat them.
  def with_native_arms_emitted(name, owners)
    previous = @native_arms_emitted
    @native_arms_emitted = { name => owners }
    yield
  ensure
    @native_arms_emitted = previous
  end

  # owner => [function, kinds] for every class whose native `name` of this
  # arity has an entry point, the older zero-argument tables included.
  def native_direct_specs(name, arity)
    specs = {}
    if arity.zero?
      (CodeGen::NATIVE_WRAPPER_ZERO_ARG_DIRECT[name] || {}).each { |owner, function| specs[owner] = [function, []] }
      if name == 'dispose'
        CodeGen::NATIVE_WRAPPER_DIRECT_OWNERS.fetch(name).each do |owner|
          specs[owner] = [owner == 'RGSS::Tilemap' ? 'tilemap_dispose_direct' : 'dispose_direct', []]
        end
      end
    end
    (NativeDirect::ENTRIES[name] || {}).each do |owner, entry|
      specs[owner] ||= [entry.function, entry.kinds] if entry.kinds.size == arity
    end
    specs
  end

  # Same conditions as native_wrapper_owner_safe?: one native registration, no
  # Ruby definition on the class, no mixin that could precede it.
  def native_direct_owner_safe?(name, owner)
    return false unless @native_name_sources && CodeGen::NATIVE_WRAPPER_CLASS_ACCESSORS.key?(owner)
    return false unless rgss_native_registers?(name)

    defs = @registry[name]
    return false unless defs

    defs.any? { |definition| definition.owner == '<native>' && definition.irep.nil? } &&
      defs.none? { |definition| definition.owner == owner } &&
      Array(@prepended_modules[owner]).empty? && !@unknown_mixins.include?(owner)
  end

  def native_direct_plan(name, arity, closed_world_site:)
    return nil unless @native_name_sources

    specs = native_direct_specs(name, arity)
    return nil if specs.empty?

    present = (@native_arms_emitted && @native_arms_emitted[name]) || []
    arms = specs.reject { |owner, _| present.include?(owner) }
                .select { |owner, _| native_direct_owner_safe?(name, owner) }
    lift = closed_world_site && native_direct_lift?(name, specs, present + arms.keys)
    return nil if arms.empty? && !lift

    { arms: arms, lift: lift }
  end

  # The arms cover every native class registering `name` (or a Ruby definition
  # replaced it), so the chain's else is reached only by receivers no native
  # class answers for.
  def native_direct_lift?(name, specs, covered)
    return false unless @closed_world

    paths = @native_name_sources.fetch(name, []).select { |path| path.include?('/mruby-rgss/src/') }
    registered = NativeDirect.registered_owners(name, paths)
    return false if registered.nil? || registered.empty?

    ruby_owned = @registry.fetch(name, []).reject { |definition| definition.owner == '<native>' }.map(&:owner)
    registered.all? { |owner| specs.key?(owner) && (covered.include?(owner) || ruby_owned.include?(owner)) } &&
      @closed_world.native_only_in?(name, '/mruby-rgss/src/') &&
      @closed_world.native_subclass_free?(registered.to_a)
  end

  def native_direct_wrap(d, recv, name, argv, arms, tail)
    return tail if arms.empty?

    @native_construct_used.merge(arms.keys)
    generic = dynamic_dispatch_line(d, recv, name, argv)
    branches = arms.group_by { |_, spec| spec }.map do |(function, kinds), owners|
      check = owners.map { |owner, _| "bc2cpp_native_class == rgss::#{CodeGen::NATIVE_WRAPPER_CLASS_ACCESSORS.fetch(owner)}()" }
                    .join(' || ')
      guards = kinds.each_index.select { |i| kinds[i] == :int }.map { |i| "mrb_integer_p(#{argv[i]})" }
      args = kinds.each_index.map do |i|
        case kinds[i]
        when :int then "mrb_integer(#{argv[i]})"
        when :bool then "mrb_test(#{argv[i]})"
        else argv[i]
        end
      end
      call = "r#{d} = rgss::#{function}(#{(['M', recv] + args).join(', ')});"
      body = if guards.empty?
               "    #{call}\n"
             else
               "    if (#{guards.join(' && ')}) {\n      #{call}\n    } else {\n      #{generic.chomp}\n    }\n"
             end
      "if (#{check}) {\n#{body}  } else "
    end
    "// NATIVE_DIRECT :#{name} -- exact RGSS class identity selects the shared native entry point\n" \
      "  {\n" \
      "  struct RClass* bc2cpp_native_class = mrb_obj_class(M, #{recv});\n" \
      "  #{branches.join}{\n" \
      "    #{tail.chomp}\n" \
      "  }\n" \
      "  }\n"
  end
end

CodeGen.prepend(NativeDirectFallback)
