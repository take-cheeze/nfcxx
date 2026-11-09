# frozen_string_literal: true

require_relative 'world_root'
require_relative 'codegen_block_core_direct'

# CORE_EXACT_DIRECT: a send with no block whose receiver is proven an exact
# Array, Hash, Range or Integer and whose name that class answers with a
# compiled mruby core body is a
# direct `_impl` call. Nothing else could answer: the receiver's class is a fact, so the by-name
# send has no receiver left to dispatch for.
#
# The body of a guarded method may only run in a Fiber's frames when it provably cannot suspend one
# whatever it is given; a call has no block of its own, so that is
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
  # named out: its to_enum bodies are not CORE_SELF_EXACT receivers.
  TO_ENUM_DIRECT_CLASSES = begin
    dir = File.join(BC2CPP_WORLD_ROOT, "3rd/mruby/mrblib")
    raise "bc2cpp: #{dir} is missing (is 3rd/mruby checked out?)" unless Dir.exist?(dir)

    Dir[File.join(dir, '*.rb')].sort.flat_map do |path|
      File.read(path, encoding: 'UTF-8').scan(/^class (\w+)\n(.*?)^end$/m)
          .select { |_name, body| body.include?('return to_enum(') }.map(&:first)
    end.uniq.reject { |name| name == 'Integer' }.freeze
  end

  # TO_ENUM_DIRECT: `to_enum(:meth, *args)` / `enum_for` on a receiver proven exactly an Array, Hash, Range or
  # String builds the Enumerator the way Kernel#to_enum's body does, `Enumerator.new self, meth, *args`, without looking
  # the name up. EnumeratorModel proves Kernel#to_enum is the program's only to_enum/enum_for and that nothing replaces
  # the construction chain; the constant must be stable and no runtime installer may name the involved methods.
  def to_enum_direct_line(d, recv, name, argv, site)
    return nil unless TO_ENUM_DIRECT_CLASSES.include?(site[:klass]) && to_enum_direct_proven?(argv)

    to_enum_construction_line(d, recv, name, argv, "proven #{site[:klass]} receiver")
  end

  # TO_ENUM_DIRECT on any receiver (closed world): the program's one Kernel#to_enum answers every object that has
  # Kernel in its ancestry, and BASIC_OBJECT_SEALED (CodeGen#kernel_receiver_sealed?) proves every object does, unless
  # a class below Kernel defines the name again. The outside Ruby may (mruby-enum-lazy's Enumerator::Lazy#to_enum):
  # a receiver of such a class takes the owner call over exactly those owners, any other builds the Enumerator.
  # A core body (`return to_enum(:each) unless block_given?`) uses the program's world: Kernel#to_enum is itself a
  # core definition, the one kind a core body may bind to.
  def to_enum_any_receiver_line(d, recv, name, argv)
    world = @closed_world || @core_program_world
    return nil unless EnumeratorModel::NAMES.include?(name) && world && !@call_block_expr && core_extend_enabled?
    return nil unless kernel_receiver_sealed?(world) && argv.size <= CodeGen::FUNCALL_ARGC_MAX
    return nil unless to_enum_direct_proven?(argv)

    overriders = to_enum_overriders(world)
    return nil unless overriders

    build = to_enum_construction_line(d, recv, name, argv, 'closed world, Kernel#to_enum answers this receiver')
    return build if overriders.empty?

    test = overriders.map do |owner|
      "((bc2cpp_te_c = #{owner_class_ptr_expr(owner)}) && mrb_obj_is_kind_of(M, #{recv}, bc2cpp_te_c))"
    end
    "  // TO_ENUM_DIRECT :#{name} -- an instance of #{overriders.join(', ')} takes its own #{name}\n" \
      "  { struct RClass* bc2cpp_te_c;\n  if (#{test.join(' || ')}) {\n" \
      "    #{outside_owner_call_line(d, recv, name, argv, overriders)}\n" \
      "  } else {\n  #{build.gsub("\n  ", "\n    ")}  } }\n"
  end

  # The classes besides Kernel that define to_enum/enum_for, or nil when one cannot be named: no definition the
  # registry cannot see (computed or native), and every outside or core Ruby one named. A Kernel definition may come
  # only from mruby's own Ruby: the core mrblib's (kernel.rb's NotImplementedError stub) loads before any gem, so the
  # mruby-enumerator body EnumeratorModel proved replaces it; any other outside Kernel definition refuses.
  MRUBY_CORE_MRBLIB = File.join(BC2CPP_WORLD_ROOT, "3rd/mruby/mrblib") + '/'

  def to_enum_overriders(world)
    @to_enum_overriders ||= {}
    @to_enum_overriders.fetch(world.object_id) do
      @to_enum_overriders[world.object_id] = to_enum_overriders_decide(world)
    end
  end

  def to_enum_overriders_decide(world)
    names = EnumeratorModel::NAMES
    return nil if world.global_refusal || names.any? { |n| world.unknown_def?(n) || @native_name_sources&.key?(n) }

    owners_in = lambda do |paths|
      result = OutsideRubyOwners.scan(paths)
      return nil if result.unknown.include?(:all) || names.any? { |n| result.unknown.include?(n) } || !result.wild.empty?

      names.flat_map { |n| result.names.fetch(n, Set.new).to_a }.uniq
    end
    core = owners_in.call(program_core_ruby_paths)
    return nil unless core && (core - ['Kernel']).empty?

    overriders = []
    Array(world.ruby_paths).each do |path|
      owners = owners_in.call([path])
      return nil unless owners
      return nil if owners.include?('Kernel') && !File.expand_path(path).start_with?(MRUBY_CORE_MRBLIB)

      overriders |= owners - ['Kernel']
    end
    return nil if overriders.any? { |o| !o.match?(OutsideOwnerCall::OWNER_PATH) || o.end_with?('.singleton') }

    overriders.sort
  end

  def to_enum_direct_proven?(argv)
    model = self.class.enumerator_model
    return false unless model&.to_enum_direct && model.constant_stable && argv.size <= 8
    return false if (EnumeratorModel::NAMES + EnumeratorModel::CONSTRUCTION_NAMES).any? { |n| devirt_blocked_name?(n) }

    # Only the names an installer creates or replaces matter: `alias_method :_old_initialize, :initialize` copies, it does not install `initialize`.
    installed = symbol_installed_destinations
    !!installed && (EnumeratorModel::NAMES + EnumeratorModel::CONSTRUCTION_NAMES).none? { |n| installed.include?(n) }
  end

  def to_enum_construction_line(d, recv, name, argv, why)
    @direct_alloc_used = true if to_enum_owner_call_owners # the helper allocates with bc2cpp_direct_alloc
    meth = argv.empty? ? 'mrb_symbol_value(mrb_intern_lit(M, "each"))' : argv.first
    vector = [recv, meth, *argv.drop(1)]
    "#{TO_ENUM_DIRECT_NOTE}#{name} -- #{why}: builds Enumerator.new(self, meth, *args) as " \
      "Kernel#to_enum does, no lookup of #{name}\n" \
      "  { mrb_value bc2cpp_te_argv[] = { #{vector.join(', ')} }; " \
      "r#{d} = bc2cpp_to_enum(M, #{vector.size}, bc2cpp_te_argv); }\n"
  end

  # The helper TO_ENUM_DIRECT sites call, emitted only when some compiled code does: Class#new without a block, as
  # GENERIC_NEW_DIRECT builds it (`mrb_class_get` is the constant read of the body's `Enumerator`, a TypeError or
  # NameError exactly where the read would raise), then `initialize(self, meth, *args)` as an owner call. The text goes
  # through SymbolCache like the method bodies. mrb_obj_new when the owner list cannot be built.
  # The owners of the Enumerator construction's owner call, or nil. Enumerator#initialize is compiled only when the
  # registry keeps its definer; the enumerator model drops an interpreted one (EnumeratorModel), and an owner list
  # without it would raise at run time. Without it the construction keeps mrb_obj_new.
  def to_enum_owner_call_owners
    return nil unless @registry.fetch('initialize', []).any? { |definition| definition.owner == 'Enumerator' }

    generic_new_initialize_owners
  end

  def emit_to_enum_helper(compiled)
    return '' unless compiled.any? { |m| m[:code].include?('bc2cpp_to_enum(') }

    owners = to_enum_owner_call_owners
    body = if owners
             "  mrb_value obj = bc2cpp_direct_alloc(M, mrb_class_get(M, \"Enumerator\"));\n" \
               "  (void)bc2cpp_owner_call_argv_named(M, obj, \"initialize\", 0, BC2CPP_OWNERS(#{owner_call_owner_list(owners)}), " \
               "mrb_nil_value(), argc, argv);\n" \
               "  return obj;\n"
           else
             "  return mrb_obj_new(M, mrb_class_get(M, \"Enumerator\"), argc, argv);\n"
           end
    "static inline mrb_value bc2cpp_to_enum(mrb_state* M, mrb_int argc, const mrb_value* argv) {\n#{body}}\n\n"
  end

  # FLOW_CORE_DIRECT: the direct call of an exact-receiver site that would otherwise get a guard
  # chain over user classes (a name some project class also defines). The receiver is exactly the core
  # class, so those arms are dead and the compiled core body is the only candidate.
  def flow_core_direct_line(d, recv, name, argv)
    return nil unless ENV['BC2CPP_NATIVE_CLASS_ARMS'] != '0' && exact_core_site_for(recv, name)

    core_exact_direct_line(d, recv, name, argv, dynamic_dispatch_line(d, recv, name, argv)) ||
      flow_native_core_exact_line(d, recv, name, argv)
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
    return nil if target.owner == 'Enumerable' && !core_each_builtin?(klass, chain)

    target
  end

  # An Enumerable body runs `each` on its receiver: the entry checks it at run time
  # (bc2cpp_core_each_is_builtin); a proven class needs the same fact at compile time.
  def core_each_builtin?(klass, chain)
    !block_core_target(klass, chain, 'each', 0, blockless: false).nil?
  end
end

CodeGen.prepend(CoreExactDirect)
