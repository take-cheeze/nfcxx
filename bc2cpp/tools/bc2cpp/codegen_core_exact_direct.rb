# frozen_string_literal: true

require_relative 'codegen_block_core_direct'

# CORE_EXACT_DIRECT (docs/adr/0314): a send with no block whose receiver is proven an exact
# Array, Hash, Range or Integer (ADR 0280) and whose name that class answers with a
# compiled mruby core body (hidden from the registry, ADR 0264; possibly guarded, ADR 0269) is a
# direct `_impl` call. Nothing else could answer: the receiver's class is a fact, so the by-name
# send has no receiver left to dispatch for.
#
# The body of a guarded method may only run in a Fiber's frames when it provably cannot suspend one
# whatever it is given (YIELD_REACH `nb`, ADR 0283); a call has no block of its own, so that is
# the whole condition and the entry's root-context test is not needed.
#
# BC2CPP_CORE_EXTEND=0 turns every emission of this file off.
module CoreExactDirect
  CORE_EXACT_DIRECT_NOTE = '// CORE_EXACT_DIRECT :'

  def native_direct_dynamic_line(d, recv, name, argv)
    tail = super
    core_exact_direct_line(d, recv, name, argv, tail) || tail
  end

  def core_extend_enabled?
    ENV['BC2CPP_CORE_EXTEND'] != '0'
  end

  # The direct call replacing the plain by-name send `tail` of an exact-receiver site, or nil.
  # Only the bare dispatch line is replaced: any arm another pass put in front of it (a native
  # body with an unproven argument, a poly chain) already decided what the else is for.
  def core_exact_direct_line(d, recv, name, argv, tail)
    return nil unless core_extend_enabled? && !@call_block_expr && block_core_world && @native_name_sources

    site = exact_core_site_for(recv, name)
    return nil unless site && tail == dynamic_dispatch_line(d, recv, name, argv)
    return to_enum_direct_line(d, recv, name, argv, site) if EnumeratorModel::NAMES.include?(name)

    spec = BlockCoreDirectFallback::RECEIVERS[site[:klass]]
    return nil unless spec

    target = core_exact_target(site[:klass], spec[:chain], name, argv.size, private_ok: site[:implicit_self])
    return nil unless target

    impl = "#{cpp_name(target.owner, target.name)}_impl"
    args, = direct_call_args(target, argv, impl)
    "#{CORE_EXACT_DIRECT_NOTE}#{name} -- proven #{site[:klass]} receiver: calls the compiled #{target.owner}##{target.name} " \
      "body, no dispatch\n  r#{d} = #{impl}(M, #{([recv] + args).join(', ')});\n"
  end

  TO_ENUM_DIRECT_NOTE = '// TO_ENUM_DIRECT :'
  # The classes whose mruby core mrblib methods `return to_enum(` (3rd/mruby/mrblib, read at load time). Integer is
  # named out: its to_enum bodies are not CORE_SELF_EXACT receivers (ADR 0381, ADR 0418).
  TO_ENUM_DIRECT_CLASSES = begin
    dir = File.expand_path('../../3rd/mruby/mrblib', __dir__)
    raise "bc2cpp: #{dir} is missing (is 3rd/mruby checked out?)" unless Dir.exist?(dir)

    Dir[File.join(dir, '*.rb')].sort.flat_map do |path|
      File.read(path, encoding: 'UTF-8').scan(/^class (\w+)\n(.*?)^end$/m)
          .select { |_name, body| body.include?('return to_enum(') }.map(&:first)
    end.uniq.reject { |name| name == 'Integer' }.freeze
  end

  # TO_ENUM_DIRECT (ADR 0418): `to_enum(:meth, *args)` / `enum_for` on a receiver proven exactly an Array, Hash, Range or
  # String builds the Enumerator the way Kernel#to_enum's body does, `Enumerator.new self, meth, *args`, without looking
  # the name up. EnumeratorModel proves Kernel#to_enum is the program's only to_enum/enum_for and that nothing replaces
  # the construction chain; the constant must be stable and no runtime installer may name the involved methods.
  def to_enum_direct_line(d, recv, name, argv, site)
    model = self.class.enumerator_model
    return nil unless model&.to_enum_direct && TO_ENUM_DIRECT_CLASSES.include?(site[:klass]) && argv.size <= 8
    return nil unless model.constant_stable
    return nil if (EnumeratorModel::NAMES + EnumeratorModel::CONSTRUCTION_NAMES).any? { |n| devirt_blocked_name?(n) }

    # Only the names an installer creates or replaces matter: `alias_method :_old_initialize, :initialize` copies, it does not install `initialize`.
    installed = symbol_installed_destinations
    return nil unless installed && (EnumeratorModel::NAMES + EnumeratorModel::CONSTRUCTION_NAMES).none? { |n| installed.include?(n) }

    meth = argv.empty? ? 'mrb_symbol_value(mrb_intern_lit(M, "each"))' : argv.first
    vector = [recv, meth, *argv.drop(1)]
    "#{TO_ENUM_DIRECT_NOTE}#{name} -- proven #{site[:klass]} receiver: builds Enumerator.new(self, meth, *args) as " \
      "Kernel#to_enum does, no lookup of #{name}\n" \
      "  { mrb_value bc2cpp_te_argv[] = { #{vector.join(', ')} }; " \
      "r#{d} = bc2cpp_to_enum(M, #{vector.size}, bc2cpp_te_argv); }\n"
  end

  # The helper TO_ENUM_DIRECT sites call, emitted only when some compiled code does. `mrb_class_get` is the constant
  # read of the body's `Enumerator` (a TypeError/NameError exactly where the read would raise), `mrb_obj_new` is
  # Class#new without a block: allocate, then `initialize(self, meth, *args)`.
  def emit_to_enum_helper(compiled)
    return '' unless compiled.any? { |m| m[:code].include?('bc2cpp_to_enum(') }

    <<~CPP
      static inline mrb_value bc2cpp_to_enum(mrb_state* M, mrb_int argc, const mrb_value* argv) {
        return mrb_obj_new(M, mrb_class_get(M, "Enumerator"), argc, argv);
      }

    CPP
  end

  # FLOW_CORE_DIRECT (ADR 0323): the direct call of an exact-receiver site that would otherwise get a guard
  # chain over user classes (a name some project class also defines). The receiver is exactly the core
  # class, so those arms are dead and the compiled core body is the only candidate.
  def flow_core_direct_line(d, recv, name, argv)
    return nil unless ENV['BC2CPP_NATIVE_CLASS_ARMS'] != '0' && exact_core_site_for(recv, name)

    core_exact_direct_line(d, recv, name, argv, dynamic_dispatch_line(d, recv, name, argv))
  end

  # The compiled core definition a call to `name` with `arity` arguments and no block reaches on
  # an exact `klass`, or nil when anything else could answer or the body cannot run outside the
  # entry's guard.
  def core_exact_target(klass, chain, name, arity, private_ok: false)
    @core_exact_targets ||= {}
    key = [klass, name, arity, private_ok]
    @core_exact_targets.fetch(key) do
      @core_exact_targets[key] = core_exact_target_uncached(klass, chain, name, arity, private_ok)
    end
  end

  def core_exact_target_uncached(klass, chain, name, arity, private_ok = false)
    return nil if devirt_blocked_name?(name)

    target = block_core_target(klass, chain, name, arity, blockless: true)
    # An explicit-receiver call of a private method is a NoMethodError, not a call.
    return nil unless target && (target.visibility == :public || private_ok)
    return nil if core_guarded_def?(target) && !core_body_relaxable?(target.irep)
    return nil if target.owner == 'Enumerable' && !core_each_builtin?(klass, chain)

    target
  end

  def core_guarded_def?(definition)
    !!self.class.core_guarded&.include?(definition.irep)
  end

  # An Enumerable body runs `each` on its receiver: the entry checks it at run time
  # (bc2cpp_core_each_is_builtin); a proven class needs the same fact at compile time.
  def core_each_builtin?(klass, chain)
    !block_core_target(klass, chain, 'each', 0, blockless: false).nil?
  end
end

CodeGen.prepend(CoreExactDirect)
