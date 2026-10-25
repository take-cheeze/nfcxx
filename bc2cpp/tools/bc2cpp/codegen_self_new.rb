# frozen_string_literal: true

require_relative 'bytecode_ir'

# SELF_NEW_LEAF: `new` whose receiver is `self` in a singleton method of class C (`new(...)`,
# `self.new(...)`), or `self.class` in an instance method of C (`self.class.new(...)`).
#
# Such a receiver is C or a class below it: a singleton method runs with any class that inherits it as `self`, an
# instance method with an instance of any of them. ClosedWorld#known_subclasses lists that set when the closed world
# sees every class in it (no Class.new(C), no outside Ruby or native subclass). Then:
#   - a leaf C: the receiver is exactly C, so the site allocates and calls C's initialize directly, with no guard;
#   - C with known subclasses: one exact-class arm per class of the set, each a direct allocation plus the
#     initialize that class resolves to, and a closed-world guard violation for any other receiver.
# `self.class` additionally needs Kernel#class to be the only `class` (no Ruby definition, no unknown or dynamic
# definer) and no object to carry a singleton class (mrb_obj_class reads past it, a singleton `class` would not).
#
# It also closes a hole of the constructor paths in codegen_send.rb: an implicit-self `new` in a singleton method of
# a class whose constant is stable allocated that class unguarded, so `Kid.make` with `make` inherited from `Base`
# built a Base. When the set is unknown or an initialize does not resolve to a direct call, an inheritable `self`
# receiver now takes the by-name send, which is what Class#new does.
module SelfNewConstruct
  def compile_send(insn, **kwargs)
    self_new_construct(insn, **kwargs) || super
  end

  private

  def self_new_construct(insn, self_implicit:, irep: nil, idx: nil, owner_def: nil, call_receiver: nil,
                         call_arguments: nil, **)
    return nil unless insn.sym == 'new' && @closed_world && @closed_world.global_refusal.nil? && !@call_block_expr
    return nil unless irep && idx && call_receiver.nil? && call_arguments.nil? && insn.n_spec != '*' && !insn.nk_spec

    n = insn.n_spec.to_i
    return nil if n > CodeGen::FUNCALL_ARGC_MAX

    d = insn.reg
    klass, kind = self_new_receiver(insn, self_implicit, irep, idx, owner_def&.owner)
    return nil unless klass

    recv = self_implicit ? 'self' : "r#{d}"
    argv = (1..n).map { |k| "r#{d.to_i + k}" }
    # Every `new` and `allocate` definer is visible and none sits on C's singleton chain or on Class: Class#new is
    # what a class of the set runs unless a `def self.new` of its own (a named `.singleton` owner) replaces it.
    return nil unless @closed_world.standard_constructor_lookup? && exact_constructor_chain?(klass)

    set = @closed_world.known_subclasses(klass)
    classes = set || [klass]
    arms = classes.map { |k| [k, exact_constructor_chain?(k) ? self_new_initialize_call(k, argv) : :own_new] }
    # A leaf whose initialize is not a direct call keeps the paths of codegen_send.rb (they are exact for a leaf).
    return nil if set&.size == 1 && !arms.first[1].is_a?(String)

    @direct_alloc_used = true
    listed = set ? "the receiver is one of #{set.join(', ')}" :
                   "other classes may inherit it (Class.new(#{klass}) or an unseen subclass), so only exactly #{klass} is listed"
    note = "  // SELF_NEW_LEAF :new -- #{kind} of #{klass}: #{listed} (closed world, ADR 0468)\n"
    if set&.size == 1
      return "#{note}  {\n" \
             "    mrb_value bc2cpp_sn = bc2cpp_direct_alloc(M, mrb_class_ptr(#{recv}));\n" \
             "    #{format(arms.first[1], obj: 'bc2cpp_sn')}\n" \
             "    r#{d} = bc2cpp_sn;\n" \
             "  }\n"
    end

    args = argv.empty? ? '0, NULL' : "#{argv.size}, bc2cpp_sna"
    branches = arms.map do |k, call|
      # A class whose initialize is not one direct call is still built by Class#new itself: allocation plus the
      # dispatched initialize (mrb_obj_new), on the class the arm proved.
      # A class with a `def self.new` of its own (named, so listed) takes it through the owner call.
      build = case call
              when String then "bc2cpp_sn = bc2cpp_direct_alloc(M, bc2cpp_snc);\n      #{format(call, obj: 'bc2cpp_sn')}"
              when :own_new
                "bc2cpp_sn = #{outside_owner_call_line(d, recv, 'new', argv, self_new_class_new_owners).sub(/\Ar#{d} = /, '')}"
              else "bc2cpp_sn = mrb_obj_new(M, bc2cpp_snc, #{args});"
              end
      "if (bc2cpp_snc == #{owner_class_ptr_expr(k)}) {\n      #{build}\n    } else "
    end.join
    # The rest: a listed set ends in a violation; an open one (Class.new(C) and the like) in the owner call over the
    # definers of `new` (Class#new and every named `def self.new`), so an unlisted definer raises, never dispatches.
    rest = if set
             guard_violation_line(d, recv, 'new', argv, 'SELF_NEW_LEAF')
           else
             outside_owner_call_line(d, recv, 'new', argv, self_new_class_new_owners)
           end
    "#{note}  {\n" \
      "    struct RClass* bc2cpp_snc = mrb_class_ptr(#{recv});\n" \
      "    mrb_value bc2cpp_sn;\n" \
      "#{argv.empty? ? '' : "    mrb_value bc2cpp_sna[] = { #{argv.join(', ')} };\n"}" \
      "    #{branches}{\n" \
      "      bc2cpp_sn = #{rest.sub(/\Ar#{d} = /, '').chomp}\n" \
      "    }\n" \
      "    r#{d} = bc2cpp_sn;\n" \
      "  }\n"
  end

  # The owners a lookup of `new` on a class object can find: Class#new, and every class object's own `def self.new`
  # (registry `.singleton` owners). standard_constructor_lookup? has excluded unknown and outside Ruby definers.
  def self_new_class_new_owners
    singles = (@registry['new'] || []).map(&:owner).select { |owner| owner.end_with?('.singleton') }
    (['Class'] + singles).uniq.sort
  end

  # [C, kind] when the receiver register of this `new` is `self` of a singleton method of class C, or `self.class` of
  # an instance method of class C; nil otherwise.
  def self_new_receiver(insn, self_implicit, irep, idx, owner)
    return nil unless owner.is_a?(String)

    if owner.end_with?('.singleton')
      klass = owner.delete_suffix('.singleton')
      return nil unless @closed_world.class_declared?(klass)
      return [klass, 'self of a singleton method'] if self_implicit || self_register?(irep, idx, insn.reg)

      return nil
    end
    return nil if self_implicit || !@closed_world.class_declared?(owner) || !kernel_class_only?

    defs = BytecodeIR.reaching_definitions(irep, idx, insn.reg.to_s, through_handlers: true, shared: true)
    return nil unless defs&.size == 1 && !defs.first.entry?

    source = BytecodeIR.for(irep).source_at(defs.first.index)
    return nil unless source && source.sym == 'class' && %w[SEND0 SEND SSEND0 SSEND].include?(source.op) &&
                      source.n_spec.to_i.zero? && !source.nk_spec
    return nil unless source.op.start_with?('SSEND') || self_register?(irep, defs.first.index, source.reg)

    [owner, 'self.class in an instance method']
  end

  # Every definition of `reg` at `idx` is the method's own `self` (register 0 on entry).
  def self_register?(irep, idx, reg)
    defs = BytecodeIR.reaching_definitions(irep, idx, reg.to_s, through_handlers: true, shared: true)
    defs&.size == 1 && defs.first.entry? && defs.first.reg.to_s == '0'
  end

  def kernel_class_only?
    @kernel_class_only = begin
      ruby = (@registry['class'] || []).reject { |definition| definition.owner == '<native>' }
      installed = symbol_installed_names
      ruby.empty? && !@closed_world.unknown_definer?('class') && installed && !installed.include?('class') &&
        @closed_world.exact_instances_singleton_free?
    end if @kernel_class_only.nil?
    @kernel_class_only
  end

  # The direct initialize call for an exact instance of `klass` (format string with %<obj>s for the new object), or
  # nil: `klass`'s construction is the standard one, and the initialize its lookup reaches is one compiled Ruby
  # definition taking this many positional arguments (the conditions of DIRECT_CONSTRUCT_TARGETS in codegen_send.rb).
  def self_new_initialize_call(klass, argv)
    return nil unless exact_constructor_chain?(klass)

    definition = self_new_initialize_def(klass)
    return nil unless definition&.irep && compiles_clean?(definition.irep)

    owner = definition.owner
    return nil if @only_owners && !@only_owners.include?(owner) && !@other_owners&.include?(owner)

    init = @ireps.fetch(definition.irep)
    _, _, rest, post, = init.enter&.enter_fields
    return nil unless rest.to_i.zero? && post.to_i.zero?

    mand = mandatory_arity(init)
    opt = optional_arity(init)
    return nil unless argv.size.between?(mand, mand + opt)
    return nil if opt.positive? && !optional_arg_table(init)[1]
    return nil if mandatory_optional_and_keyword_arity?(init) || native_arg_types(definition, mand).any?

    args = argv.dup
    if opt.positive?
      args += Array.new(mand + opt - argv.size, 'mrb_nil_value()')
      args << (argv.size - mand).to_s
    end
    "#{cpp_name(owner, 'initialize')}_impl(M, %<obj>s#{args.map { |a| ", #{a}" }.join});"
  end

  # The one Ruby `initialize` the lookup of an exact `klass` instance reaches: the first class of its declared
  # superclass chain that defines it, with no mixin on the way. nil past the declared classes (a core or native
  # initialize) or when a class defines it twice.
  def self_new_initialize_def(klass)
    seen = Set.new
    while klass.is_a?(String) && seen.add?(klass) && @closed_world.class_declared?(klass)
      return nil if @unknown_mixins.include?(klass)
      return nil unless Array(@included_modules[klass]).empty? && Array(@prepended_modules[klass]).empty?

      defs = (@registry['initialize'] || []).select { |definition| definition.owner == klass }
      return nil if defs.size > 1
      return defs.first if defs.one?

      klass = @superclass_of[klass]
    end
    nil
  end
end

CodeGen.prepend(SelfNewConstruct)
