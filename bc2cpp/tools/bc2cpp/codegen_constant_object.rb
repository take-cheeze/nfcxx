# frozen_string_literal: true

# CLOSED_WORLD_CONSTANT_OBJECT (ADR 0259): a send whose receiver is a stable
# class/module constant resolves to the singleton method mruby's lookup finds
# for that class object, instead of dispatching by name.
class CodeGen
  # The code for `Const.name(*argv)`, or nil when only dispatch is safe. The
  # receiver is exactly the constant's class object (constant_object_owner
  # proved its identity), so its singleton lookup is the class's own singleton,
  # then its superclasses' singletons (ClosedWorld#class_parent).
  def constant_object_send_code(name, n, d, recv, argv, constant_owner)
    return nil if devirt_blocked_name?(name)

    candidate = constant_object_singleton_def(name, constant_owner)
    return nil unless candidate&.visibility == :public

    singleton_owner = candidate.owner
    return constant_object_accessor_code(candidate, n, d, recv, argv) if candidate.irep.nil? && candidate.kind == :ivar_accessor

    copied = candidate.kind == :module_function
    label = candidate.irep || (candidate.copy_irep if copied)
    return nil unless label

    irep = @ireps.fetch(label)
    target = copied ? @registry[name]&.find { |md| md.owner == candidate.copy_owner && md.irep == candidate.copy_irep } : candidate
    return nil unless target

    argc_error = static_argc_error_code(candidate, irep, n, d)
    return argc_error if argc_error

    return nil unless pure_mandatory_or_optional_arity?(irep) && n.between?(mandatory_arity(irep), mandatory_arity(irep) + optional_arity(irep))
    return nil if hot_only_excluded?(label) || !constant_object_candidate_clean?(label)
    return nil if copied && !module_function_copy_self_safe?(irep)
    return nil unless !@only_owners || @only_owners.include?(singleton_owner) || @other_owners&.include?(singleton_owner)

    impl = cpp_name(target.owner, target.name) + '_impl'
    call_argv, native_note = direct_call_args(target, argv, impl)
    via = copied ? "module_function copy of #{target.owner}##{target.name}" : "#{candidate.owner}##{candidate.name}"
    inherited = singleton_owner == "#{constant_owner}.singleton" ? '' : ", inherited from #{singleton_owner.delete_suffix('.singleton')}"
    note = "  // CLOSED_WORLD_CONSTANT_OBJECT :#{name} -> #{via} " \
           "(stable class/module constant, unique public singleton definition#{inherited}), direct C++ call " \
           "without mrb_funcall#{native_note}.\n"
    "#{note}  r#{d} = #{impl}(M, #{([recv] + call_argv).join(', ')});\n"
  end

  # The one singleton definition of `name` mruby's lookup reaches from
  # `constant_owner`'s class object, or nil. Every singleton class on the way
  # must be free of mixins (an included or prepended module could answer
  # first), and the superclass chain must be fully resolved up to the definer.
  def constant_object_singleton_def(name, constant_owner)
    klass = constant_owner
    seen = Set.new
    while klass.is_a?(String) && seen.add?(klass)
      singleton = "#{klass}.singleton"
      return nil if @unknown_mixins.include?(singleton) || !Array(@included_modules[singleton]).empty? ||
                    !Array(@prepended_modules[singleton]).empty?

      defs = @registry.fetch(name, []).select { |md| md.owner == singleton }
      return (defs.one? ? defs.first : nil) unless defs.empty?
      # Past the constant's own singleton, native code or a runtime install could
      # have put the name on a subclass's singleton ahead of the definer.
      return nil unless @closed_world.inherited_lookup_safe?(name, constant_owner)

      klass = @closed_world.class_parent(klass)
    end
    nil
  end

  # ADR 0259: the arm of an UNLISTED_CLASS_GUARDS branch. The receiver is
  # exactly `klass`, so its lookup is the one closed_world_lookup_target
  # proves; the send then calls that definition (optional parameters padded), or
  # raises the ArgumentError its ENTER would. nil keeps the dispatching arm.
  def unlisted_class_call(klass, name, d, recv, argv)
    return nil if devirt_blocked_name?(name) || !@closed_world.inherited_lookup_safe?(name, klass)

    target, known = closed_world_lookup_target(name, klass, Set.new)
    return nil unless known && target&.irep

    irep = @ireps.fetch(target.irep)
    n = argv.size
    argc_error = static_argc_error_code(target, irep, n, d)
    return argc_error if argc_error

    return nil unless poly_arity_fits?(irep, n, true) && !hot_only_excluded?(target.irep) && compiles_clean?(target.irep)
    return nil unless !@only_owners || @only_owners.include?(target.owner) || @other_owners&.include?(target.owner)

    impl = cpp_name(target.owner, target.name) + '_impl'
    call_argv, = direct_call_args(target, argv, impl)
    "// UNLISTED_CLASS_CALL :#{name} -> #{target.owner}##{target.name} (receiver exactly #{klass}), direct C++ call\n" \
      "r#{d} = #{impl}(M, #{([recv] + call_argv).join(', ')});\n"
  end
  # `attr_accessor` inside `class << self`: a bare ivar access on the class
  # object, which never embeds its ivars.
  def constant_object_accessor_code(candidate, n, d, recv, argv)
    return nil unless n == (candidate.name.end_with?('=') ? 1 : 0)

    code = ivar_accessor_call_code(candidate.owner, recv, candidate.name, d, argv)
    return nil unless code

    "  // CLOSED_WORLD_CONSTANT_OBJECT :#{candidate.name} -> #{candidate.owner}##{candidate.name} " \
      "(stable class/module constant, singleton attr accessor), direct ivar access without mrb_funcall.\n" \
      "  #{code}\n"
  end

  # STATIC_ARGC_ERROR: `candidate` is the definition a send provably reaches (a
  # constant object's singleton, or self's own method). OP_ENTER (3rd/mruby/src/vm.c) raises ArgumentError when a plain positional
  # call is outside [mandatory, mandatory + optional]; only a callee with no
  # rest, post, keyword or block parameter has that exact rule. Its message
  # names the mandatory count alone, which is what mrb_argnum_error(min, min)
  # formats. nil otherwise.
  def static_argc_error_code(candidate, irep, n, d)
    return nil unless pure_mandatory_or_optional_arity?(irep)

    min = mandatory_arity(irep)
    max = min + optional_arity(irep)
    return nil if n.between?(min, max)

    "  // STATIC_ARGC_ERROR :#{candidate.name} -> #{candidate.owner}##{candidate.name} " \
      "takes #{min == max ? min : "#{min}..#{max}"} argument(s), called with #{n}: the ArgumentError its " \
      "ENTER raises, no dispatch.\n" \
      "  mrb_argnum_error(M, #{n}, #{min}, #{min});\n" \
      "  r#{d} = mrb_nil_value();\n"
  end
end
