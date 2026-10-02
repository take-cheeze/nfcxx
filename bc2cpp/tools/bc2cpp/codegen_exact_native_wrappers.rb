# frozen_string_literal: true

# EXACT_NATIVE_WRAPPER (docs/adr/0307): a send of an RGSS wrapper whose receiver the exact-class
# flow proves is exactly one RGSS native class (an ivar pool, a constructor result, a call whose
# name only returns that class: ADR 0289/0296/0301) calls the wrapper's frame-independent body with
# no class test and no dispatch.
#
# compile_send's native-wrapper arms (codegen_send.rb) guard the same body with
# `mrb_obj_class(M, recv) == rgss::native_X_class()` and keep the send as their else, because the
# receiver class there is only a hint (`trace_new_target`). The flow's class is exactly what that
# test checks, so a flow-proven receiver makes the test constant: this is the same body with the
# test and the else removed. It needs no more than the arm it replaces (`native_wrapper_owner_safe?`),
# plus the proof, and a nil-or-K receiver reaches it through NILABLE_RECEIVER.
module ExactNativeWrappers
  # name => owner => [arities, builder]; the builder gets (receiver, arguments) and returns the C++
  # call expression. The bodies are the ones compile_send's guarded arms emit
  # (scripts/bc2cpp_exact_native_wrappers_check.rb compares the two).
  ONE_VALUE = lambda do |function|
    ->(recv, argv) { "rgss::#{function}(M, #{recv}, #{argv[0]})" }
  end

  CALLS = {
    'bitmap=' => { 'RGSS::Sprite' => [[1], ONE_VALUE.call('sprite_bitmap_set_direct')] },
    'text_size' => { 'RGSS::Bitmap' => [[1], ONE_VALUE.call('bitmap_text_size_direct')] },
    'fill_rect' => { 'RGSS::Bitmap' => [[5], lambda { |recv, argv|
      "rgss::bitmap_fill_rect_direct(M, #{recv}, #{argv.join(', ')})"
    }] },
    'copy_blt' => { 'RGSS::Bitmap' => [[4], lambda { |recv, argv|
      "rgss::bitmap_copy_blt_direct(M, #{recv}, #{argv.join(', ')})"
    }] },
    'blt' => { 'RGSS::Bitmap' => [[4, 5], lambda { |recv, argv|
      opacity = argv.size == 4 ? 'mrb_fixnum_value(255)' : argv[4]
      "rgss::bitmap_blt_direct(M, #{recv}, #{argv[0, 4].join(', ')}, #{opacity}, #{argv.size == 5 ? 'TRUE' : 'FALSE'})"
    }] },
    'stretch_blt' => { 'RGSS::Bitmap' => [[3, 4], lambda { |recv, argv|
      opacity = argv.size == 3 ? 'mrb_fixnum_value(255)' : argv[3]
      "rgss::bitmap_stretch_blt_direct(M, #{recv}, #{argv[0, 3].join(', ')}, #{opacity}, #{argv.size == 4 ? 'TRUE' : 'FALSE'})"
    }] },
    'openness=' => { 'RGSS::Window' => [[1], ONE_VALUE.call('window_openness_set_direct')] },
    'opacity=' => { 'RGSS::Sprite' => [[1], ONE_VALUE.call('sprite_opacity_set_direct')] },
    'tone=' => { 'RGSS::Window' => [[1], ONE_VALUE.call('window_tone_set_direct')],
                 'RGSS::Sprite' => [[1], ONE_VALUE.call('sprite_tone_set_direct')],
                 'RGSS::Viewport' => [[1], ONE_VALUE.call('viewport_tone_set_direct')] }
  }.freeze

  # `draw_text` packs its arguments into an array the body parses itself.
  DRAW_TEXT_ARITIES = [2, 3, 5, 6].freeze

  # BC2CPP_EXACT_NATIVE_WRAPPERS=0 restores the guarded arms for every site.
  def exact_native_wrappers_enabled?
    ENV.fetch('BC2CPP_EXACT_NATIVE_WRAPPERS', '1') != '0'
  end

  # The exact RGSS native class the flow proves for the receiver register of this send, or nil.
  def exact_native_wrapper_class(irep, idx, reg, name, argc)
    return nil unless exact_native_wrappers_enabled? && irep && idx && @closed_world && exact_native_wrapper_name?(name)

    klass = exact_flow_user_class(irep, idx, reg)
    return nil unless klass && CodeGen::NATIVE_WRAPPER_CLASS_ACCESSORS.key?(klass)
    return nil unless exact_native_wrapper_call(name, klass, argc)
    return nil if symbol_installed_names.nil? || symbol_installed_names.include?(name) || devirt_blocked_name?(name)

    return nil if argc.zero? && CodeGen::NATIVE_WRAPPER_ZERO_ARG_DIRECT.key?(name) && exact_native_direct_covers?(name, klass)

    native_wrapper_owner_safe?(name, klass) ? klass : nil
  end

  # compile_send tries NATIVE_EXACT_DIRECT (ADR 0281, a stricter name proof) on the flow class for a zero-argument
  # wrapper before its guarded arm; this call is for what that refuses. The other names meet their hint arm first.
  def exact_native_direct_covers?(name, klass)
    entry = NativeDirect::ENTRIES.dig(name, klass)
    !entry.nil? && entry.kinds.none? { |k| k == :int } && native_exact_owner_safe?(name, klass)
  end

  # Names some wrapper table above handles, so a send of any other name never asks the flow.
  def exact_native_wrapper_name?(name)
    @exact_native_wrapper_names ||= (CALLS.keys + CodeGen::NATIVE_WRAPPER_ZERO_ARG_DIRECT.keys + %w[draw_text dispose]).to_set
    @exact_native_wrapper_names.include?(name)
  end

  # [kind, builder] for `name` on +klass+ at +argc+ arguments, or nil.
  def exact_native_wrapper_call(name, klass, argc)
    if (spec = CALLS.dig(name, klass))
      arities, builder = spec
      return [:call, builder] if arities.include?(argc)
    elsif name == 'draw_text' && klass == 'RGSS::Bitmap' && DRAW_TEXT_ARITIES.include?(argc)
      return [:draw_text, nil]
    elsif argc.zero? && (function = CodeGen::NATIVE_WRAPPER_ZERO_ARG_DIRECT.dig(name, klass))
      return [:call, ->(recv, _argv) { "rgss::#{function}(M, #{recv})" }]
    elsif argc.zero? && name == 'dispose' && CodeGen::NATIVE_WRAPPER_DIRECT_OWNERS['dispose'].include?(klass)
      function = klass == 'RGSS::Tilemap' ? 'tilemap_dispose_direct' : 'dispose_direct'
      return [:call, ->(recv, _argv) { "rgss::#{function}(M, #{recv})" }]
    end
    nil
  end

  # The unguarded call for `recv.name(*argv)`, or nil when the receiver is not a proven exact wrapper class.
  def exact_native_wrapper_code(name, d, recv, argv, irep, idx, reg)
    return nil if @call_block_expr

    klass = exact_native_wrapper_class(irep, idx, reg, name, argv.size)
    return nil unless klass

    kind, builder = exact_native_wrapper_call(name, klass, argv.size)
    @native_construct_used << klass
    note = "  // EXACT_NATIVE_WRAPPER :#{name} -> #{klass} (receiver proven exact by the class flow, ADR 0307), " \
           "wrapper body without a class test or dispatch.\n"
    if kind == :draw_text
      return "#{note}  {\n    mrb_value bc2cpp_draw_text_args[] = { #{argv.join(', ')} };\n" \
             "    r#{d} = rgss::bitmap_draw_text_direct(M, #{recv}, #{argv.size}, bc2cpp_draw_text_args);\n  }\n"
    end

    "#{note}  r#{d} = #{builder.call(recv, argv)};\n"
  end
end

CodeGen.include(ExactNativeWrappers)
