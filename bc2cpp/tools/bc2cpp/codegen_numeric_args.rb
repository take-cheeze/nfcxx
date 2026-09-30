# frozen_string_literal: true

require_relative 'dynamic_names'

# CodeGen: NUMERIC_ENTRY_ARG_PROOF (ADR 0276).
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

    return NumericFlow::INT if fixnum_proof_entry_arg?(irep, reg.to_s, owner)

    pooled = @entry_arg_numeric && @entry_arg_numeric[[irep.label, reg.to_i]]
    pooled.nil? ? NumericFlow::OTHER : pooled
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
        mask = numeric_raw_mask(irep, idx, (recv + k).to_s, owner)
        if mask.nil? || (mask & NumericFlow::OTHER) != 0
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
