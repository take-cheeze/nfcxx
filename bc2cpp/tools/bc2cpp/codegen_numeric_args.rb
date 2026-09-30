# frozen_string_literal: true

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
    @entry_cand = entry_arg_candidates.reject { |(label, _k), _| numeric_dynamically_named?(@owner_of[label]&.name) }
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
  # call-site enumeration never sees. A name built from a Symbol literal is
  # already poisoned (entry_arg_call_index); this adds names a program spells as
  # a string, and the setter `stem=` a computed `"#{stem}="` names (the only
  # composition the closed-world lint baseline contains). Refusing costs a proof.
  def numeric_dynamically_named?(name)
    return true unless name

    @numeric_dynamic_names ||= numeric_dynamic_name_universe
    @numeric_dynamic_names.include?(name)
  end

  def numeric_dynamic_name_universe
    stems = Set.new
    computed = false
    @ireps.each_value do |irep|
      irep.instructions.each_with_index do |insn, idx|
        stems << insn.sym if insn.op == 'LOADSYM' && insn.sym
        if insn.op == 'STRING'
          entry = irep.pool[insn.pool_index.to_i]
          stems << entry if entry.is_a?(String) && entry.match?(/\A[A-Za-z_]\w*[?!=]?\z/)
        end
        next unless insn.op.include?('SEND') && %w[send __send__ public_send].include?(insn.sym)

        literal = insn.plain_fixed_argc? && insn.argc.to_i.positive? &&
                  irep.walk_writers(idx - 1, (insn.reg.to_i + 1).to_s, follow_moves: true) { |w| w.op == 'LOADSYM' }
        computed = true unless literal
      end
    end
    computed ? stems | stems.map { |n| "#{n}=" } : stems
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
