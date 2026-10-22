# frozen_string_literal: true

require_relative 'sealed_int16_locals'

# CodeGen: emission for SealedInt16Locals (opt-in: BC2CPP_SEALED_INT16=1, see sealed_int16_locals.rb).
#
# A proven array becomes a std::vector<int16_t> local, declared with the method's registers. Its ARRAY instruction
# assigns the vector, each proven read and write goes to the vector, and the mrb_value register the array used to
# live in is left unused. Resumable methods are not rewritten: the resumable frame keeps every register in a struct.
class CodeGen
  # SealedInt16Locals.plan for +irep+, computed once per irep (the same irep can be compiled more than once).
  def sealed_int16_plans_for(irep)
    @sealed_int16_plans ||= {}.compare_by_identity
    @sealed_int16_plans[irep] ||= SealedInt16Locals.plan(irep)
  end

  # One std::vector declaration per proven array, placed with the register initializers.
  def sealed_int16_declarations(irep)
    return '' if @resumable || !SealedInt16Locals.enabled?

    sealed_int16_plans_for(irep).each_index.map { |k| "  std::vector<int16_t> sealed_int16_#{k};\n" }.join
  end

  # The emission action of instruction +idx+ of +irep+, or nil when the instruction is not a sealed form.
  def sealed_int16_action(irep, idx)
    return nil if idx.nil? || @resumable || !SealedInt16Locals.enabled?

    @sealed_int16_actions ||= {}.compare_by_identity
    table = (@sealed_int16_actions[irep] ||= sealed_int16_table(irep))
    table[idx]
  end

  def sealed_int16_table(irep)
    table = {}
    sealed_int16_plans_for(irep).each_with_index do |array, k|
      table[array.index] = { kind: :create, dst: array.dst, array: k, values: array.values, size: array.size }
      array.actions.each { |j, action| table[j] = action.merge(array: k, size: array.size, range: array.range) }
    end
    table
  end

  # The [lo, hi] interval of the element that the sealed GETIDX / GETIDX0 at +j+ of +irep+ reads, or nil. Only an
  # in-range literal read is a sealed element: an out-of-range read is nil, which has no interval. The same gates as
  # emission apply, so the fact is never asserted for code that is not rewritten.
  def sealed_element_range(irep, j)
    action = sealed_int16_action(irep, j)
    return nil unless action && action[:kind] == :get && action[:index] < action[:size]

    action[:range]
  end

  # The C++ for one sealed action. Reads are at most one register, so the mrb_value copy stays consistent.
  def sealed_int16_code(action, insn)
    name = "sealed_int16_#{action[:array]}"
    case action[:kind]
    when :create
      "  #{name} = std::vector<int16_t>{ #{action[:values].join(', ')} };\n" \
        "  r#{action[:dst]} = mrb_nil_value();\n"
    when :alias
      "  /* sealed int16 alias of #{name} (no copy) */\n"
    when :get
      if action[:index] < action[:size]
        "  r#{action[:dst]} = mrb_fixnum_value(#{name}[#{action[:index]}]);\n"
      else
        "  r#{action[:dst]} = mrb_nil_value();\n"
      end
    when :set
      "  #{name}[#{action[:index]}] = (int16_t)mrb_fixnum(r#{action[:value_reg]});\n" \
        "  r#{action[:dst]} = r#{action[:value_reg]};\n"
    when :size
      "  r#{action[:dst]} = mrb_fixnum_value(#{action[:size]});\n"
    else
      raise "bc2cpp: unknown sealed int16 action #{action[:kind].inspect} at #{insn.op}"
    end
  end
end
