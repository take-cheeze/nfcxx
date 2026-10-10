# frozen_string_literal: true

# CodeGen: INTEGER_TAG_ELSE (ADR 0394). The by-name else of an Integer-tag guard on an index argument, where the receiver
# is already proven to be exactly an Array (INDEX_EXACT, ADR 0296), becomes a direct call to the native Array body the
# closed world answers `[]` / `[]=` with (INDEX_CLOSED, ADR 0365). The guard tests the INDEX, not the receiver, so
# the else runs for a receiver of exact class Array with a key that is not a fixnum (a Range, a String, a Float, nil).
#
# The direct call is taken only when no other definer can answer the name on Array: the name's definers are bounded
# (no Object/Kernel/BasicObject definer, no install, no hook), none is a singleton, none is a Ruby or foreign definer on
# Array's ancestry, and the Array body is the one the build links and the generator verified (INDEX_ARMS['Array']).
# Otherwise the else stays the by-name send, and the refusal reason is counted (stderr summary).
#
# BC2CPP_INTEGER_TAG_ELSE=0 restores the by-name else byte-for-byte.
class CodeGen
  # name => [exported body, C prototype], the bodies patches/mruby-expose-index-bodies.patch exports.
  INTEGER_TAG_ELSE_BODIES = {
    '[]' => ['mrb_ary_aget1_impl', 'mrb_value mrb_ary_aget1_impl(mrb_state*, mrb_value, mrb_value)'],
    '[]=' => ['mrb_ary_aset2_impl', 'mrb_value mrb_ary_aset2_impl(mrb_state*, mrb_value, mrb_value, mrb_value)']
  }.freeze

  def integer_tag_else_enabled?
    ENV['BC2CPP_INTEGER_TAG_ELSE'] != '0'
  end

  # [name, reason] => count, for the stderr summary; `:direct` counts the sites that took the body.
  def integer_tag_else_counts
    @integer_tag_else_counts ||= Hash.new(0)
  end

  # The C++ that replaces an exact Array receiver's by-name else (`recv`, `args` are register or key texts), or nil with
  # the refusal counted. The caller emits `r<d> = <text>;`.
  def integer_tag_else_array_call(name, exact, recv, args)
    return nil unless integer_tag_else_enabled?

    body, = INTEGER_TAG_ELSE_BODIES[name]
    reason = if !exact then :receiver_not_exact
             elsif body then integer_tag_else_array_refusal(name)
             else :no_body
             end
    if reason
      integer_tag_else_counts[[name, reason]] += 1
      return nil
    end
    integer_tag_else_counts[[name, :direct]] += 1
    @integer_tag_else_bodies_used ||= Set.new
    @integer_tag_else_bodies_used << name
    "#{body}(M, #{recv}, #{args.join(', ')})"
  end

  # The else of SETIDX's Array arm: the direct `[]=` body, or the by-name send that keeps the assigned value's place.
  def integer_tag_else_by_name_set(exact, d, idx_reg, val)
    direct = integer_tag_else_array_call('[]=', exact, "r#{d}", ["r#{idx_reg}", "r#{val}"])
    return "r#{d} = #{direct};" if direct

    "r#{d} = mrb_funcall(M, r#{d}, \"[]=\", 2, r#{idx_reg}, r#{val});"
  end

  # Why the closed world does not prove the Array body answers `name` on an exact Array receiver, or nil when it does.
  def integer_tag_else_array_refusal(name)
    return :disabled unless index_closed_world?
    return :blocked_name if devirt_blocked_name?(name)

    answers = call_facts_answers
    definers = answers.definers(name)
    return :unbounded if definers.nil?
    return :singleton_definer if definers[:singleton]
    return :no_native_array unless definers[:native].include?('Array')

    ancestors = Array(answers.ancestors('Array').first)
    return :ancestor_definer if (Array(definers[:ruby]) | Array(definers[:foreign])).any? { |owner| ancestors.include?(owner) }
    return :module_definer unless Array(definers[:modules]).none? { |owner| ancestors.include?(owner) }

    spec = INDEX_ARMS.fetch(name)['Array']
    return :arm_not_linked unless index_owner_linked?('Array', spec)
    return :arm_unverified unless index_arm_verified?(answers, name, 'Array', spec)

    nil
  end

  # File-scope prototypes of the bodies the direct calls use (the caller prepends them to the helpers).
  def integer_tag_else_prelude
    names = @integer_tag_else_bodies_used
    return '' if names.nil? || names.empty?

    out = +"// INTEGER_TAG_ELSE (ADR 0394): exported by patches/mruby-expose-index-bodies.patch\n"
    out << "extern \"C\" #{names.sort.map { |n| INTEGER_TAG_ELSE_BODIES.fetch(n)[1] }.map { |d| "#{d};" }.join("\nextern \"C\" ")}\n\n"
    out
  end

  def integer_tag_else_summary
    direct = integer_tag_else_counts.select { |(_, r), _| r == :direct }.values.sum
    refused = integer_tag_else_counts.reject { |(_, r), _| r == :direct }
    text = refused.map { |(n, r), c| "#{n} #{r} #{c}" }.sort.join(', ')
    "direct #{direct}#{text.empty? ? '' : ", refused #{text}"}"
  end
end
