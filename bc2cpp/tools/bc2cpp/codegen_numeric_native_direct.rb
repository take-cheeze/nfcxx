# frozen_string_literal: true

# NumericFlow's Integer includes fixnums and bigints; the audited public
# conversion preserves both without extracting an mrb_int (ADR 0357).
class CodeGen
  def numeric_conversion_entries(name)
    NativeCoreDirect::NUMERIC_CONVERSION_ENTRIES.select do |entry|
      entry.name == name && native_core_entry_safe?(entry)
    end
  end

  def numeric_native_direct_code(name, dest, recv, irep, index, reg, owner_def)
    return nil if ENV['BC2CPP_NUMERIC_NATIVE_DIRECT'] == '0'
    return nil unless %w[to_s to_i].include?(name) && @closed_world&.exact_instances_singleton_free?
    return nil unless @closed_world.visibility_stable?(name) && !devirt_blocked_name?(name)
    return nil unless numeric_operand_mask(irep, index, reg, owner_def) == NumericFlow::INT

    entry = numeric_conversion_entries(name).first
    return nil unless entry

    "  // NUMERIC_NATIVE_EXACT :#{name} -> Integer -- proven fixnum or bigint, audited zero-argument native\n" \
      "  r#{dest} = #{entry.call(recv, [])};\n"
  end
end
