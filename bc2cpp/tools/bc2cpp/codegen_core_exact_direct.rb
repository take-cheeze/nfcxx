# frozen_string_literal: true

require_relative 'codegen_block_core_direct'

# CORE_EXACT_DIRECT (docs/adr/0313): a send with no block whose receiver is proven an exact
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
    spec = site && BlockCoreDirectFallback::RECEIVERS[site[:klass]]
    return nil unless spec && tail == dynamic_dispatch_line(d, recv, name, argv)

    target = core_exact_target(site[:klass], spec[:chain], name, argv.size)
    return nil unless target

    impl = "#{cpp_name(target.owner, target.name)}_impl"
    args, = direct_call_args(target, argv, impl)
    "#{CORE_EXACT_DIRECT_NOTE}#{name} -- proven #{site[:klass]} receiver: calls the compiled #{target.owner}##{target.name} " \
      "body, no dispatch\n  r#{d} = #{impl}(M, #{([recv] + args).join(', ')});\n"
  end

  # compile_core_min_max with the receiver proof of this site, which compile_send builds only after it.
  def core_min_max_with_site(insn, name, n, d, recv, argv, irep, site_idx, reg, offset, self_implicit)
    site = core_extend_enabled? && !self_implicit && irep &&
           exact_core_site(irep, site_idx, unshift_proof_reg(reg, offset), argv, offset, nil, recv: recv, name: name)
    return compile_core_min_max(insn, name, n, d, recv, argv) unless site

    with_exact_core_site(site) { compile_core_min_max(insn, name, n, d, recv, argv) }
  end

  # The by-name send of an inline fast path's else arm, or the direct call when the receiver is proven.
  def core_exact_else(d, recv, name, argv)
    plain = dynamic_dispatch_line(d, recv, name, argv)
    (core_exact_direct_line(d, recv, name, argv, plain) || plain).chomp
  end

  # The compiled core definition a call to `name` with `arity` arguments and no block reaches on
  # an exact `klass`, or nil when anything else could answer or the body cannot run outside the
  # entry's guard.
  def core_exact_target(klass, chain, name, arity)
    @core_exact_targets ||= {}
    @core_exact_targets.fetch([klass, name, arity]) do
      @core_exact_targets[[klass, name, arity]] = core_exact_target_uncached(klass, chain, name, arity)
    end
  end

  def core_exact_target_uncached(klass, chain, name, arity)
    return nil if devirt_blocked_name?(name)

    target = block_core_target(klass, chain, name, arity, blockless: true)
    # An explicit-receiver call of a private method is a NoMethodError, not a call.
    return nil unless target && target.visibility == :public
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
