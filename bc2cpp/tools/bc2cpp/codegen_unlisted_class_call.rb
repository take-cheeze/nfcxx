# frozen_string_literal: true

# UNLISTED_CLASS_CALL (docs/adr/0259, 0297): the arm of an UNLISTED_CLASS_GUARDS
# branch (docs/adr/0252). The receiver is exactly `klass`, so the send reaches
# whatever mruby's lookup finds from that class; the arm is that definition's
# direct call, the error its dispatch raises, or nil to keep the dispatch.
class CodeGen
  def unlisted_class_call(klass, name, d, recv, argv, site = nil)
    return nil if devirt_blocked_name?(name)

    chain = unlisted_lookup_chain(klass)
    return nil unless chain && @closed_world.exact_chain_lookup_safe?(name, klass, chain)

    target, known = closed_world_lookup_target(name, klass, Set.new, any_visibility: true)
    return nil unless known
    return unlisted_no_target_error(klass, name, d, recv, argv, site) unless target

    case target.visibility
    when :public
      # callable from any receiver
    when :private
      return nil unless @closed_world.visibility_stable?(name)
      return unlisted_private_call(target, klass, name, d, recv, argv, site) unless unlisted_ssend?(site, name)
    else
      return nil
    end
    return nil if target.owner == '<native>'

    target.irep ? unlisted_irep_call(target, klass, name, d, recv, argv) : unlisted_accessor_call(target, klass, name, d, recv, argv)
  end

  private

  # Every class and module the lookup from `klass` can visit, or nil when a mixin
  # cannot be named.
  def unlisted_lookup_chain(klass)
    chain = Set.new
    pending = [klass]
    until pending.empty?
      current = pending.pop
      next unless chain.add?(current)
      return nil if @unknown_mixins.include?(current)

      pending.concat(Array(@included_modules[current]), Array(@prepended_modules[current]))
      parent = @superclass_of[current]
      parent = 'Object' if parent == :none && current != 'Object'
      pending << parent if parent.is_a?(String)
    end
    chain
  end

  # The instruction whose visibility the VM checks: the site's own, or (INLINED_UNLISTED_SITE, ADR 0386) the
  # original SEND/SSEND an inlined block body was compiled from. Either is trusted only when its symbol is
  # the name being compiled (both callers check), so a synthetic send never borrows a neighbour's opcode.
  def unlisted_site_insn(site)
    site && (site[:insn] || (CodeGen.inlined_unlisted_site? ? site[:trace_insn] : nil))
  end

  # SSEND is the send of an implicit (or `self.`) receiver, which may call a
  # private method; every other send of the name is an explicit receiver.
  def unlisted_ssend?(site, name)
    insn = unlisted_site_insn(site)
    !insn.nil? && insn.sym == name && insn.op.start_with?('SSEND')
  end

  # An explicit, non-self receiver: vm.c's OP_SEND raises vis_error before the
  # callee runs. `self_owner` keeps a send that may still be an implicit one out.
  def unlisted_private_call(target, klass, name, d, recv, argv, site)
    insn = unlisted_site_insn(site)
    return nil unless insn && insn.sym == name && insn.op.match?(/\ASEND0?B?\z/) && site[:self_owner].nil?
    return nil if argv.size > FUNCALL_ARGC_MAX

    pack = argv.empty? ? 'mrb_ary_new(M)' : "({ mrb_value bc2cpp_pargs[] = { #{argv.join(', ')} }; mrb_ary_new_from_values(M, #{argv.size}, bc2cpp_pargs); })"
    "// UNLISTED_CLASS_PRIVATE :#{name} -> #{target.owner}##{target.name} is private (receiver exactly #{klass}, explicit receiver): " \
      "the NoMethodError OP_SEND raises\n" \
      "{ mrb_sym bc2cpp_mid = mrb_intern_lit(M, \"#{name}\");\n" \
      "  mrb_no_method_error(M, bc2cpp_mid, #{pack}, \"private method '%n' called for %T\", bc2cpp_mid, #{recv}); }\n" \
      "r#{d} = mrb_nil_value();\n"
  end

  # The lookup from `klass` ends without a definition (the closed world listed
  # the class only by simple-name ancestry): what bc2cpp_nomethod would raise.
  def unlisted_no_target_error(klass, name, d, recv, argv, site)
    return nil if argv.size > FUNCALL_ARGC_MAX

    args = argv.empty? ? '' : ", #{argv.size}, #{argv.join(', ')}"
    marker = NomethodReviewed.marker(name, self_receiver: !site[:self_owner].nil?)
    "// UNLISTED_CLASS_NO_TARGET :#{name} (receiver exactly #{klass}): no definition on its lookup chain, only the NoMethodError\n" \
      "r#{d} = bc2cpp_nomethod_named(M, #{recv}, \"#{name}\"#{args}); #{marker}\n"
  end

  def unlisted_irep_call(target, klass, name, d, recv, argv)
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

  # attr_reader/attr_writer: a bare mrb_iv_get/mrb_iv_set (src/class.c), or the
  # embedded field of the class that stores the ivar (ivar_accessor_call_code).
  def unlisted_accessor_call(target, klass, name, d, recv, argv)
    return nil unless target.kind == :ivar_accessor && [name, name.chomp('=')].all? { |n| @closed_world.visibility_stable?(n) }

    # attr_reader is defined MRB_ARGS_NONE and attr_writer MRB_ARGS_REQ(1): the
    # count check raises before the accessor runs.
    arity = name.end_with?('=') ? 1 : 0
    unless argv.size == arity
      return "// UNLISTED_CLASS_ACCESSOR :#{name} -> #{target.owner}##{target.name} (receiver exactly #{klass}) takes " \
             "#{arity} argument(s), called with #{argv.size}: the ArgumentError its argument check raises, no dispatch.\n" \
             "mrb_argnum_error(M, #{argv.size}, #{arity}, #{arity});\n" \
             "r#{d} = mrb_nil_value();\n"
    end

    storage = unlisted_accessor_storage(target.owner, klass, name.chomp('='))
    code = storage && ivar_accessor_call_code(storage, recv, name, d, argv, indent: '')
    return nil unless code

    "// UNLISTED_CLASS_ACCESSOR :#{name} -> #{target.owner}#@#{name.chomp('=')} (receiver exactly #{klass}), " \
      "#{name.end_with?('=') ? 'attr_writer' : 'attr_reader'} as a direct ivar access\n" \
      "#{code}\n"
  end

  # The class whose layout holds @ivar for an instance of exactly `klass`:
  # `owner` itself, or `klass` when it stores the ivar in its own struct. An
  # accessor reached through a mixin, or one whose ivar a class between `klass`
  # and `owner` embeds under another layout, is left to dispatch.
  def unlisted_accessor_storage(owner, klass, ivar)
    return owner if klass == owner

    current = klass
    seen = Set.new
    while current.is_a?(String) && current != owner && seen.add?(current)
      return nil if embed_type(current, ivar)

      current = @superclass_of[current]
    end
    current == owner ? owner : nil
  end
end
