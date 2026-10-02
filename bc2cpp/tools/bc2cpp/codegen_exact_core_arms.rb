# frozen_string_literal: true

# CodeGen: EXACT_CORE_ARMS (ADR 0309).
#
# The exact-class flow (ADR 0289, 0296) proves a receiver is exactly an Array, Hash, String or
# Range, and the NATIVE_CORE_DIRECT arms already trust it (exact_core_value_class). Two older arms
# kept a class test and a by-name else for such a receiver anyway: the inline Array push family
# and the TYPED call of a core class's own compiled body. They take the same proof here.
class CodeGen
  # BC2CPP_EXACT_CORE_ARMS=0 turns the extra proof off.
  def exact_core_arms_enabled?
    ENV.fetch('BC2CPP_EXACT_CORE_ARMS', '1') != '0'
  end

  # 'Array' | 'Hash' | 'String' | 'Range' when the receiver register of the send at +idx+ is exactly
  # that class on every path, else nil. Not for an implicit-self send.
  def exact_core_arm_class(irep, idx, reg, self_implicit)
    return nil unless exact_core_arms_enabled? && !self_implicit && irep && idx && reg

    exact_core_value_class(irep, idx, reg)
  end

  # `recv.push(v)` / `recv << v` on an Array the flow proves exact: the base Array push, no test.
  # The caller has checked builtin_class_send_safe?(name, Array).
  def exact_array_push_code(irep, idx, reg, self_implicit, name, dest, recv, value)
    return nil unless exact_core_arm_class(irep, idx, reg, self_implicit) == 'Array'

    "  // ARRAY_PUSH :#{name} -- receiver proven exactly Array (class flow, ADR 0309); no class test, no dispatch\n" \
      "  mrb_ary_push(M, #{recv}, #{value});\n" \
      "  r#{dest} = #{recv};\n"
  end
end
