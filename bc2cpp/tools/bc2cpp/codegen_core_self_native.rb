# frozen_string_literal: true

require_relative 'call_facts'

# CORE_SELF_NATIVE: an implicit-self call in a compiled core method (`__sub_replace` in String#sub,
# `pos` in StringIO#ungetc, `seek` in IO#rewind) whose one definition in the program is the C function
# registered on the method's own owner calls that function through a per-site method cache
# (bc2cpp_native_owner), instead of a by-name send.
#
# `self` in a method's own body is an instance of a class whose ancestry holds the owner (a module's
# includer, a class or one of its subclasses): a body is reached only by lookup, by `super` or by binding
# a method to a kind_of its owner. Whatever that class is, its lookup of `name` reaches the owner's
# registration unless another definition comes first. CallFacts models every class an object can be an
# instance of (declared, core, native) with its lookup path and every definer of the name (Ruby, native, outside
# Ruby): for each class whose path holds the owner, the first definer on it must be the owner's native
# registration. No installer, alias or undef may name it, and no C source may undefine it. The proof is the
# whole program's (@core_program_world); the core compile only withholds the world's static-binding proofs,
# which this does not use.
module CoreSelfNative
  # BC2CPP_CORE_SELF_NATIVE=0 keeps the by-name self call.
  def core_self_native_enabled?
    ENV['BC2CPP_CORE_SELF_NATIVE'] != '0'
  end

  # The site being compiled when it is an implicit-self send (SSEND) on the method's register 0, so the
  # by-name line it may end in (a bare dispatch, or the else of a fast path) can be the cached native call.
  def compile_send(insn, **kw)
    site = kw[:self_implicit] && kw[:call_receiver].nil? && kw.fetch(:trace_reg_offset, 0).zero? &&
           %w[SSEND0 SSEND].include?(insn.op) ? [kw[:irep], kw[:owner_def]] : nil
    saved = @core_self_native_site
    @core_self_native_site = site
    begin
      super
    ensure
      @core_self_native_site = saved
    end
  end

  def dynamic_dispatch_line(d, recv, name, argv)
    code = @core_self_native_site && recv == 'self' && core_self_native_line(d, name, argv, *@core_self_native_site)
    code || super
  end

  # The cached native call, or nil. Only the method's own irep counts: a block can run with a rebound
  # self (instance_exec, define_method).
  def core_self_native_line(d, name, argv, irep, owner_def)
    return nil unless core_self_native_enabled? && @closed_world.nil? && @core_program_world && @native_name_sources
    return nil unless !@call_block_expr && !@self_class_unknown && argv.size <= CodeGen::FUNCALL_ARGC_MAX
    return nil unless owner_def&.core && irep && irep.equal?(@ireps[owner_def.irep])

    owner = owner_def.owner
    return nil if owner.end_with?('.singleton')
    return core_self_native_arms(d, name, argv, owner_def) unless core_self_native_proven?(name, owner)

    args = argv.map { |arg| ", #{arg}" }.join
    "r#{d} = bc2cpp_native_owner_named(M, self, \"#{name}\", #{owner_class_ptr_expr(owner)}, #{argv.size}#{args}); " \
      "/* CORE_SELF_NATIVE: #{owner}##{name}, the program's one definition of the name */\n"
  end

  # CORE_SELF_NATIVE_ARMS bound the exact-class arms of one site.
  CORE_SELF_NATIVE_ARMS_MAX = 8

  # CORE_SELF_NATIVE_ARMS: the name has several definers (or one on Object/Kernel, as `<=>`), so no single owner
  # answers every self. `self` in the method's own body is still an instance of a class whose lookup of the method
  # reaches its owner first (Comparable#< runs for a String, a Symbol, a Time: Integer and Float define `<`
  # themselves). For each such core class whose lookup of `name` reaches a native registration first, an exact-class
  # arm calls that registration through the per-site cache; any other class takes the line the arms replace (the
  # owner call, or the by-name send). An arm tests the receiver's class itself, so it needs only that class's lookup
  # path: no singleton class or mixin can be added to an instance (ClosedWorld#exact_instances_singleton_free?).
  def core_self_native_arms(d, name, argv, owner_def)
    arms = core_self_native_arm_targets(name, owner_def)
    return nil if arms.nil? || arms.empty?

    args = argv.map { |arg| ", #{arg}" }.join
    fallback = dynamic_dispatch_line_without_core_self(d, name, argv)
    branches = arms.map do |klass, definer|
      "if (mrb_obj_class(M, self) == #{owner_class_ptr_expr(klass)}) {\n" \
        "    r#{d} = bc2cpp_native_owner_named(M, self, \"#{name}\", #{owner_class_ptr_expr(definer)}, #{argv.size}#{args}); " \
        "/* CORE_SELF_NATIVE: #{klass}##{name} is #{definer}'s registration */\n  } else "
    end
    "// CORE_SELF_NATIVE_ARMS :#{name} -- self of #{owner_def.owner}##{owner_def.name} is one of #{arms.keys.join(', ')} " \
      "or another class\n  #{branches.join}{\n    #{fallback.chomp}\n  }\n"
  end

  # The line the arms fall back to: what this site would emit without CORE_SELF_NATIVE.
  def dynamic_dispatch_line_without_core_self(d, name, argv)
    saved = @core_self_native_site
    @core_self_native_site = nil
    dynamic_dispatch_line(d, 'self', name, argv)
  ensure
    @core_self_native_site = saved
  end

  # { core class => the class whose native registration of `name` its lookup reaches first }, for the core classes
  # whose lookup of the enclosing method reaches its owner first; nil when the world cannot say.
  def core_self_native_arm_targets(name, owner_def)
    @core_self_native_arm_targets ||= {}
    key = [name, owner_def.owner, owner_def.name]
    return @core_self_native_arm_targets[key] if @core_self_native_arm_targets.key?(key)

    targets = core_self_native_arm_decide(name, owner_def)
    warn "[CORE_SELF_NATIVE_ARMS] #{owner_def.owner}##{owner_def.name} -> #{name}: #{targets.inspect}" if ENV['BC2CPP_CORE_SELF_NATIVE_DEBUG']
    @core_self_native_arm_targets[key] = targets
  end

  def core_self_native_arm_decide(name, owner_def)
    world = @core_program_world
    return nil if devirt_blocked_name?(name) || world.global_refusal || !world.exact_instances_singleton_free?
    return nil if !@native_name_sources.key?(name) || core_self_native_undef?(name)

    answers = core_self_call_facts
    method_defs = answers.all_definers(owner_def.name, instance: true)
    name_defs = answers.all_definers(name, instance: true)
    return nil if method_defs.nil? || name_defs.nil? || method_defs[:singleton] || name_defs[:singleton]

    own = answers.simple(owner_def.owner)
    method_all = method_defs[:ruby] | method_defs[:native] | method_defs[:foreign]
    name_all = name_defs[:ruby] | name_defs[:native] | name_defs[:foreign]
    targets = {}
    CallFacts::CORE_SUPER.each_key do |klass|
      next if klass == 'BasicObject'

      ancestors, unknown = answers.ancestors(klass)
      next if unknown || ancestors.find { |a| method_all.include?(a) } != own

      definer = ancestors.find { |a| name_all.include?(a) }
      next unless definer && name_defs[:native].include?(definer) && !name_defs[:ruby].include?(definer) &&
                  !name_defs[:foreign].include?(definer) && CallFacts::CORE_SUPER.key?(definer)

      targets[klass] = definer
    end
    targets.size > CORE_SELF_NATIVE_ARMS_MAX ? nil : targets
  end

  def core_self_native_proven?(name, owner)
    @core_self_native_proven ||= {}
    @core_self_native_proven.fetch([name, owner]) do
      why = core_self_native_refusal(name, owner)
      warn "[CORE_SELF_NATIVE] #{owner}##{name}: #{why || 'proven'}" if ENV['BC2CPP_CORE_SELF_NATIVE_DEBUG']
      @core_self_native_proven[[name, owner]] = why.nil?
    end
  end

  # nil when every possible self reaches the owner's native registration of `name`, else why not.
  def core_self_native_refusal(name, owner)
    world = @core_program_world
    return :blocked_name if devirt_blocked_name?(name) || world.global_refusal
    return :not_native unless @native_name_sources.key?(name)
    return :native_undef if core_self_native_undef?(name)
    return :boot_class if ClosedWorld::BOOT_CLASSES.include?(owner)

    answers = core_self_call_facts
    definers = answers.definers(name, instance: true)
    return :unbounded_name unless definers

    own = answers.simple(owner)
    return :owner_not_native unless definers[:native].include?(own)
    return :owner_also_ruby if definers[:ruby].include?(own) || definers[:foreign].include?(own)
    # A native definer whose superclass the model only assumes (a project class it does not declare) could sit
    # below the owner unseen.
    unknown_parent = definers[:native].find { |klass| klass != own && !core_self_known_parent?(klass) }
    return :"native_definer_parent_unknown(#{unknown_parent})" if unknown_parent

    all = definers[:ruby] | definers[:native] | definers[:foreign]
    answers.classes.each do |klass|
      next if klass == CallFacts::CLASS_OBJECT # an instance method's self is no class or module object

      ancestors, unknown = answers.ancestors(klass)
      return :"ancestry_unknown(#{klass})" if unknown
      next unless ancestors.include?(own)

      first = ancestors.find { |a| all.include?(a) }
      return :"answered_first_by(#{klass}:#{first})" unless first == own
    end
    nil
  end

  # CallFacts over the program's world (a core body is compiled with no closed world of its own).
  def core_self_call_facts
    @core_self_call_facts ||= CallFacts::Answers.new(
      CallFacts::World.new(closed_world: @core_program_world, registry: @registry, superclass_of: @superclass_of,
                           included: @included_modules, prepended: @prepended_modules,
                           unknown_mixins: @unknown_mixins, native_sources: @native_name_sources,
                           installed: symbol_installed_names, instance_installed: symbol_instance_installed_names,
                           compiled_core: ->(name) { core_compiled_definers(name) })
    )
  end

  # The model names the superclass of `klass`: core_hierarchy declares it, or the program does.
  def core_self_known_parent?(klass)
    CallFacts::CORE_SUPER.key?(klass) || CallFacts::CORE_MODULES.include?(klass) ||
      @core_program_world.class_declared?(klass) || @core_program_world.module_declared?(klass)
  end

  # mruby's own C may undefine a method by name (an `mrb_undef_method` on a subclass would hide the
  # owner's registration); a project native doing so is already a global refusal (ClosedWorld::NATIVE_DYNAMIC).
  def core_self_native_undef?(name)
    pattern = /\bmrb_undef_(?:class_)?method(?:_id)?\s*\([^;]*(?:"#{Regexp.escape(name)}"|MRB_\w*SYM\w*\(#{Regexp.escape(name)}\))/
    Array(@core_program_world.native_paths).any? do |path|
      (text = SourceText.read(path, 'core_self_native_undef')) && text.match?(pattern)
    end
  end
end

CodeGen.prepend(CoreSelfNative)
