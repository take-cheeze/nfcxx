# frozen_string_literal: true

require_relative 'bytecode_ir'

# SELF_NEW_LEAF (docs/adr/0468): `new` whose receiver is `self` in a singleton method of class C (`new(...)`,
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
    set = @closed_world.known_subclasses(klass)
    arms = set&.map { |k| [k, self_new_initialize_call(k, argv)] }
    if arms.nil? || arms.any? { |_, call| call.nil? } || !@closed_world.standard_constructor_lookup?
      # A leaf whose construction is not direct keeps the ordinary paths; an inheritable receiver must not reach
      # the unguarded constant construction of codegen_send.rb.
      return nil if set&.size == 1
      # Unknown subclasses: the guarded constructions of codegen_send.rb compare the receiver with C first, which is
      # sound; only the unguarded one (a stable constant, taken for an inheritable `self`) is not.
      return nil if set.nil? && !(kind.start_with?('self of') && stable_standard_constructor_class?(klass))

      own = set.nil? && self_new_initialize_call(klass, argv)
      # Unknown subclasses with a direct construction of C itself: the codegen_send.rb path would take it unguarded,
      # so C gets its own exact arm here and any other class the by-name send.
      return nil if set.nil? && !own
      if own
        @direct_alloc_used = true
        return "  // SELF_NEW_LEAF :new -- #{kind} of #{klass}: other classes may inherit it (closed world cannot list " \
               "them), so only exactly #{klass} constructs directly\n" \
               "  if (mrb_class_ptr(#{recv}) == #{owner_class_ptr_expr(klass)}) {\n" \
               "    mrb_value bc2cpp_sn = bc2cpp_direct_alloc(M, mrb_class_ptr(#{recv}));\n" \
               "    #{format(own, obj: 'bc2cpp_sn')}\n" \
               "    r#{d} = bc2cpp_sn;\n" \
               "  } else {\n" \
               "    #{dynamic_dispatch_line(d, recv, 'new', argv)}" \
               "  }\n"
      end

      return "  // SELF_NEW_LEAF :new -- #{kind} of #{klass}: the classes it may be (#{set ? set.join(', ') : 'unknown'}) " \
             "do not all construct directly; Class#new by name\n  #{dynamic_dispatch_line(d, recv, 'new', argv)}"
    end

    @direct_alloc_used = true
    note = "  // SELF_NEW_LEAF :new -- #{kind} of #{klass}: the receiver is one of #{set.join(', ')} (closed world, ADR 0468)\n"
    if arms.size == 1
      return "#{note}  {\n" \
             "    mrb_value bc2cpp_sn = bc2cpp_direct_alloc(M, mrb_class_ptr(#{recv}));\n" \
             "    #{format(arms.first[1], obj: 'bc2cpp_sn')}\n" \
             "    r#{d} = bc2cpp_sn;\n" \
             "  }\n"
    end

    branches = arms.map do |k, call|
      "if (bc2cpp_snc == #{owner_class_ptr_expr(k)}) {\n" \
        "      bc2cpp_sn = bc2cpp_direct_alloc(M, bc2cpp_snc);\n" \
        "      #{format(call, obj: 'bc2cpp_sn')}\n" \
        "    } else "
    end.join
    "#{note}  {\n" \
      "    struct RClass* bc2cpp_snc = mrb_class_ptr(#{recv});\n" \
      "    mrb_value bc2cpp_sn;\n" \
      "    #{branches}{\n" \
      "      bc2cpp_sn = #{guard_violation_line(d, recv, 'new', argv, 'SELF_NEW_LEAF').sub(/\Ar#{d} = /, '').chomp}\n" \
      "    }\n" \
      "    r#{d} = bc2cpp_sn;\n" \
      "  }\n"
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

    defs = BytecodeIR.reaching_definitions(irep, idx, insn.reg.to_s, through_handlers: true)
    return nil unless defs&.size == 1 && !defs.first.entry?

    source = irep.instructions[defs.first.index]
    return nil unless source && source.sym == 'class' && %w[SEND0 SEND SSEND0 SSEND].include?(source.op) &&
                      source.n_spec.to_i.zero? && !source.nk_spec
    return nil unless source.op.start_with?('SSEND') || self_register?(irep, defs.first.index, source.reg)

    [owner, 'self.class in an instance method']
  end

  # Every definition of `reg` at `idx` is the method's own `self` (register 0 on entry).
  def self_register?(irep, idx, reg)
    defs = BytecodeIR.reaching_definitions(irep, idx, reg.to_s, through_handlers: true)
    defs&.size == 1 && defs.first.entry? && defs.first.reg.to_s == '0'
  end

  def kernel_class_only?
    @kernel_class_only = begin
      ruby = (@registry['class'] || []).reject { |definition| definition.owner == '<native>' }
      ruby.empty? && !@closed_world.unknown_definer?('class') && !symbol_installed_names.include?('class') &&
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
