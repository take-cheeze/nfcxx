# frozen_string_literal: true

require_relative 'dynamic_names'

# CodeGen: NUMERIC_ENTRY_ARG_PROOF.
#
# ENTRY_ARG_CALLSITE_PROOF with class sets instead of "Fixnum". A mandatory
# argument register holds the join of what EVERY call site that can reach the
# method passes there, as NumericFlow computes it. Admission
# (entry_arg_candidates) and the exhaustive-site argument are that proof's,
# unchanged; a candidate is dropped for good as soon as a site passes an
# unmodelled class or sits in an irep the flow cannot model.
class CodeGen
  def setup_numeric_entry_args
    @entry_cand = entry_arg_candidates
    @entry_arg_numeric = @entry_cand.keys.to_h { |key| [key, 0] }
  end

  def numeric_entry_mask(irep, reg)
    owner = numeric_owner_of(irep)
    return NumericFlow::OTHER unless owner

    return NumericFlow::INT if fixnum_proof_entry_arg?(irep, reg, owner)

    pooled = @entry_arg_numeric && @entry_arg_numeric[[irep.label, reg.to_i]]
    declared = declared_numeric_entry(irep, reg)
    return pooled.nil? ? declared : pooled & declared if declared

    pooled.nil? ? (lcf_entry_class_pool(irep, reg) || NumericFlow::OTHER) : pooled
  end

  # DECLARED_NUMERIC_ENTRY: a mandatory parameter declared Integer or Float (`T?` too) holds that on entry, because the
  # body's DECLARED_PARAM_GUARD raises for anything else before the first instruction runs and such a body is never
  # inlined (codegen_call_inline). These are the bits the class pools already seed (setup_class_pools); an optional one is
  # left out, as its register holds the default only after the body's own code. BC2CPP_DECLARED_NUMERIC_ENTRY=0 drops it.
  def declared_numeric_entry(irep, reg)
    return nil if ENV['BC2CPP_DECLARED_NUMERIC_ENTRY'] == '0' || @declared_arg_pools.nil?

    # Keyed by the pools' identity: setup_class_pools replaces the Hash when it runs again.
    @declared_numeric_entries = [@declared_arg_pools, declared_numeric_entries] unless @declared_numeric_entries&.first.equal?(@declared_arg_pools)
    @declared_numeric_entries[1][[irep.label, reg.to_i]]
  end

  def declared_numeric_entries
    declared_params_kept.each_with_object({}) do |(label, guards), out|
      guards.each do |pos, cls, _key, _text, kind = :class, nilable = false, optional = nil|
        next if optional || !%i[integer float].include?(kind)

        bits = declared_arg_bits(cls, kind, nilable)
        out[[label, pos + 1]] = bits if @declared_arg_pools[[label, pos + 1]] == bits
      end
    end
  end

  # EXACT_LCF_ENTRY: a parameter with no numeric pool (a call site the numeric flow cannot name) still holds what its
  # exact-class pool proves when that is LCF kinds only (rows, tables, files; nil): the class pools are final before
  # the first numeric pass (compute_numeric_facts), and a CHECKED pool is only checked at run time, so it is not used.
  # BC2CPP_EXACT_LCF_ENTRY=0 leaves such a parameter OTHER.
  def lcf_entry_class_pool(irep, reg)
    return nil unless @lcf_rows && ENV['BC2CPP_EXACT_LCF_ENTRY'] != '0'

    mask = class_pool_entry_mask(irep, reg)
    return nil if mask.nil? || mask.zero? || mask.anybits?(NumericFlow::CHECKED)

    kinds = exact_lcf_file_kinds(mask)
    kinds if @lcf_rows.lcf_bits(kinds).nonzero? && (kinds & ~(@lcf_rows.mask | NumericFlow::NIL)).zero?
  end

  # Sends whose method name is computed at run time can reach a candidate the
  # call-site enumeration never sees (DynamicNames). Refusing costs a proof.
  def numeric_dynamically_named?(name)
    return true unless name

    @numeric_dynamic_names ||= DynamicNames.universe(@ireps)
    @numeric_dynamic_names.include?(name)
  end

  # One growth pass; true when a mask grew or a candidate was dropped.
  def grow_entry_arg_numeric
    changed = false
    @entry_cand.each do |key, (sites, k)|
      current = @entry_arg_numeric[key]
      next unless current

      joined = 0
      sites.each do |(irep, idx, recv, _argc, owner)|
        mask = numeric_raw_mask(irep, idx, recv + k, owner)
        if mask.nil? || (mask & NumericFlow::OPAQUE) != 0
          joined = nil
          break
        end
        joined |= mask
      end
      grown = joined && current | joined
      next if grown == current

      changed = true
      grown.nil? ? @entry_arg_numeric.delete(key) : @entry_arg_numeric[key] = grown
      # Only the method's own irep reads its entry masks; nested blocks see
      # captured variables as unknown.
      numeric_invalidate(key[0])
    end
    changed
  end
end
