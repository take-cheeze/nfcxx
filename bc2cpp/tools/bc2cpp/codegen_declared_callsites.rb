# frozen_string_literal: true

require_relative 'codegen_return_classes'

# CodeGen: DECLARED_CALLSITE_CONTRADICTION (TC1018).
#
# A declared parameter (an RBS `Integer` / `Float` / `Symbol` / program-class parameter, `T?` included) is checked on
# entry (DECLARED_PARAM_GUARD) and seeds its argument pool with the declared class bit (setup_class_pools). Whole-program
# inference still sees what each call site passes: the class set NumericFlow computes for the argument register at the
# SEND, the same flow that feeds @class_arg_pools for an undeclared parameter. A site whose set is known (no unmodelled
# or pending-exception bit, not empty) and shares no bit with the declared one passes another class on every run that
# reaches it, so the guard raises BC2cppDeclarationViolation there: a proven contradiction, reported as an error. A set
# that merely contains the declared class beside others ("maybe") is silent, and so is every site the flow cannot name.
#
# The sites are the ones the pools read: admission rules 1-8 (entry_arg_candidates, constructor sites) for a name with
# one definition, the receiver-dispatched sites (poly_arg_reads) for a name with several. A parameter neither
# enumerates (an optional one, a name an outside definition shares) has no site list, so nothing is claimed about it.
class CodeGen
  # Hash rows, one per contradicting (call site, declared parameter): the caller turns them into diagnostics.
  # label/position/key/text identify the declaration, got the class names the site passes.
  def declared_callsite_contradictions
    rows = []
    declared_params_kept.each do |label, guards|
      guards.each do |pos, cls, key, text, kind = :class, nilable = false|
        declared = declared_callsite_bits(cls, kind, nilable)
        next if declared.nil? || declared.zero?

        pool_key = [label, pos + 1]
        declared_callsite_reads(pool_key)&.each do |irep, idx, reg|
          mask = declared_callsite_mask(irep, idx, reg)
          next if mask.nil? || mask.zero? || mask.anybits?(CLASS_POOL_UNSHIPPABLE | NumericFlow::OTHER | NumericFlow::CHECKED)
          next if mask.anybits?(declared)

          rows << { label: label, position: pos + 1, key: key, text: text, irep: irep, index: idx, mask: mask,
                    declared_mask: declared }
        end
      end
    end
    rows
  end

  # SHARD_COLOCATE_GUARDS (shard_colocate.rb): the markers ("DECLARED_PARAM_GUARD <key> arg <n>") of the program-class
  # parameter guards every call site the pools read proves: the flow gives each site's argument only the declared
  # class's bit (and nil's where `T?` admits it). A program class's bit is that one class and the guard tests the exact class,
  # so no program site can make that guard fire; a site the flow cannot name, or a parameter with no site list,
  # proves nothing. These are the sites that type an undeclared parameter's pool, so the claim rests on what the
  # pools already rest on. The guard itself stays in the `_impl` that outside callers reach.
  def site_proven_param_guards
    @site_proven_param_guards ||= declared_params_kept.each_with_object(Set.new) do |(label, guards), out|
      guards.each do |pos, cls, key, _text, kind = :class, nilable = false, optional = nil|
        # A core class's bit (RETURN_CORE_CLASS) is the flow's container bit, not one exact class.
        next unless kind == :class && optional.nil? && RETURN_CORE_CLASS.key(cls).nil?

        declared = declared_callsite_bits(cls, kind, nilable)
        next if declared.nil? || declared.zero?

        reads = declared_callsite_reads([label, pos + 1])
        next if reads.nil? || reads.empty?

        proven = reads.all? do |irep, idx, reg|
          mask = declared_callsite_mask(irep, idx, reg)
          mask && !mask.zero? && !mask.anybits?(CLASS_POOL_UNSHIPPABLE | NumericFlow::OTHER | NumericFlow::CHECKED) &&
            (mask & ~declared).zero?
        end
        out << "DECLARED_PARAM_GUARD #{key} arg #{pos + 1}" if proven
      end
    end
  end

  # The bits the flow gives a declaration's class. declared_arg_bits seeds a program class by numeric_class_bit, but
  # Array, Hash, String and Range have NumericFlow bits of their own (RETURN_CORE_CLASS), which is what a call site's
  # flow carries; any other class the flow gives no bit (TrueClass, FalseClass, ...) is skipped: nothing is claimed.
  def declared_callsite_bits(cls, kind, nilable)
    if kind == :class
      core = RETURN_CORE_CLASS.key(cls)
      return nil if core.nil? && RETURN_BITLESS_CLASSES.include?(cls)

      base = core || numeric_class_bit(cls)
      return nilable ? base | NumericFlow::NIL : base
    end
    declared_arg_bits(cls, kind, nilable)
  end

  # The argument pool flow's oracle with one refinement for this report: a Float or Integer pool literal is that class
  # (NumericOracle#pool_mask). The pools' own oracle leaves literals OTHER, which is right for a pool but would hide
  # `count(1.5)` here.
  # A plain forwarder, not SimpleDelegator: the self-compiled compiler (bc2cpp/tools/self_compile) binds only mruby's
  # classes, and `delegate` is CRuby's library.
  class CallsiteOracle
    def initialize(base, gen)
      @base = base
      @gen = gen
    end

    def pool_mask(irep, insn) = @gen.numeric_oracle_pool_mask(irep, insn)

    def method_missing(name, *args, &block) = @base.__send__(name, *args, &block)
    def respond_to_missing?(name, include_private = false) = @base.respond_to?(name, include_private) || super
  end

  # return_class_raw_mask under CallsiteOracle: nil when the irep is not modelled or a block may write the register,
  # 0 when the instruction is unreached.
  def declared_callsite_mask(irep, idx, reg)
    @declared_callsite_states ||= {}
    states = (@declared_callsite_states[irep.label] ||= BytecodeIR::NumericClasses.states(
      irep, CallsiteOracle.new(return_class_table_oracle(irep), self), fixnum_proof_ctx(irep)[:upvars], {}
    ) || false)
    return nil unless states

    state = states[idx]
    return 0 unless state

    r = reg.to_i
    return nil if r >= irep.nregs.to_i || fixnum_proof_ctx(irep)[:upvars].include?(r)

    state[r]
  end

  # [[irep, idx, argument register], ...] of the call sites that reach the declaration, or nil when none is enumerated.
  def declared_callsite_reads(pool_key)
    if (sites, k = (@entry_cand || {})[pool_key])
      return sites.map { |irep, idx, recv, _argc, _own| [irep, idx, recv + k] }
    end
    return nil unless (poly = poly_arg_candidates[pool_key])

    poly_arg_reads(*poly, pool_key)
  end
end
