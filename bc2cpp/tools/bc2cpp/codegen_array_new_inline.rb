# frozen_string_literal: true

# ARRAY_NEW_BLOCK (docs/adr/0391): `Array.new(n) { |i| BODY }` as an inlined loop.
#
# The send is a block-carrying native constructor: Class#new allocates, then Array#initialize
# (3rd/mruby/src/array.c `mrb_ary_init`, "|oo&") sizes the array with `mrb_as_int` and fills slot i with the
# block's value for i in 0...size. Compiled as BLOCK_FALLBACK that is an RProc, a block cfunc, a by-name
# `new` dispatch and a by-name `initialize` behind it, all to run a counted loop. Here the loop is inline, in
# the shape of the `map` inliner (emit_collect_inline): the accumulator is a fresh Array, each pass binds the
# index to the block's parameter, `next` (the block's value) is pushed, `break v` becomes the call's value.
#
# Soundness (every clause is a refusal reason, counted in array_new_report):
#   receiver       the register holds the constant `Array`, written on every path to the send (a straight-line
#                  walk that skips the BLOCK, as the profiler pass does), resolved without a lexically
#                  nested `Array`, and the constant is never rebound (stable_constant_identity?).
#   construction   Class#new / allocate cannot have been replaced for Array: no registry definition of either
#                  name on Array, Object, BasicObject, Class, Module or Kernel (or their singletons), no
#                  prepend/unresolved mixin on those singletons (exact_constructor_chain?), and no outside
#                  definer or installer of either name (standard_constructor_lookup?).
#   initialize     Array#initialize is mruby's own native: nothing in the registry, in mruby's hidden core
#                  definitions or in an outside Ruby source defines `initialize` on Array (core_native_arm_safe?),
#                  Array has no prepended or unresolved module, no runtime installer names `initialize`, and no
#                  native source other than array.c that spells `initialize` mentions the Array class.
#   shape          one argument (the size; `Array.new(n, obj) { }` ignores obj and stays a call), a block of 0 or
#                  1 mandatory parameters and no optional/rest shape, a block that does not forward the method's
#                  own block.
# What the loop reproduces from mrb_ary_init: `size = mrb_as_int(arg)` (the same conversion and its TypeError),
# a size <= 0 runs the block zero times and answers [] (array.c's `ARY_CAPA(a) < size` never expands),
# `mrb_ary_new_capa` raises the same "array size too big" as ary_expand_capa. Not reproduced, by design: the
# arena is not released per pass (mrb_ary_init releases it because it holds only the array; here the body
# may write a level-0 captured local that nothing else roots, exactly the reason emit_collect_inline does not
# either), and the half-built array is unreachable until the call returns, so a push instead of an indexed
# set is not observable.
# BC2CPP_ARRAY_NEW_INLINE=0 keeps the BLOCK_FALLBACK call.
class CodeGen
  ARRAY_NEW_CHAIN_OWNERS = %w[Array Object BasicObject Class Module Kernel].freeze

  def array_new_inline_enabled?
    ENV['BC2CPP_ARRAY_NEW_INLINE'] != '0'
  end

  # Outcome of the recognizer per site ([irep label, SENDB index] => 'inlined' or the refusal reason), so a
  # recognizer that runs again (a rescue try body, a probing compile) counts a site once. bc2cpp.rb prints the
  # tally.
  def array_new_sites
    @array_new_sites ||= {}
  end

  def array_new_report
    array_new_sites.values.tally
  end

  def note_array_new_site(irep, idx, outcome)
    array_new_sites[[irep.label, idx]] = outcome
  end

  def recognize_array_new_regions(irep, owner_name, _mand, _ivar_classes, _arg_classes)
    return [] unless array_new_inline_enabled?

    regions = []
    layout = ->(insn) { 2 if insn.sym == 'new' && insn.argc_text == 'n=1' }
    each_block_site(irep, send_ops: %w[SENDB], layout: layout) do |insn, idx, block_insn, dest_reg, block_irep|
      world = array_new_receiver_constant?(irep, idx, insn, owner_name)
      next note_array_new_site(irep, idx, world) if world.is_a?(String)
      next unless world

      reason = array_new_refusal(block_irep)
      next note_array_new_site(irep, idx, reason) if reason

      note_array_new_site(irep, idx, 'inlined')
      regions << { block_addr: block_insn.addr, sendb_addr: insn.addr, dest_reg: dest_reg, block_irep: block_irep,
                   bind_index: mandatory_arity(block_irep) == 1 }
    end
    regions
  end

  # The receiver register is the stable constant ::Array and Array.new / Array#initialize are mruby's own.
  # Anything else is not an Array.new site, so it is not counted.
  # true, false (not an Array.new site), or the refusal reason String.
  def array_new_receiver_constant?(irep, idx, insn, owner_name)
    return false unless @closed_world && straight_line_constant_name(irep, idx, insn.reg, skip_blocks: true) == 'Array'

    array_new_world_refusal(owner_name) || true
  end

  def array_new_world_refusal(owner_name)
    return 'receiver_not_toplevel_array' unless resolve_class_constant_name('Array', owner_name) == 'Array'
    return 'array_constant_unstable' unless @closed_world.stable_constant_identity?('Array')
    return 'construction_replaceable' unless array_new_construction_unreplaced?

    array_initialize_refusal
  end

  def array_new_refusal(block_irep)
    return 'block_arity' unless [0, 1].include?(mandatory_arity(block_irep)) && pure_mandatory_arity?(block_irep)
    return 'block_forwards_frame_block' unless block_blk_needs(block_irep) == []

    nil
  end

  def array_new_construction_unreplaced?
    return false unless @closed_world.standard_constructor_lookup? && exact_constructor_chain?('Array')

    %w[new allocate].all? do |name|
      (@registry[name] || []).none? do |definition|
        ARRAY_NEW_CHAIN_OWNERS.any? { |owner| [owner, "#{owner}.singleton"].include?(definition.owner) }
      end
    end &&
      %w[Object.singleton BasicObject.singleton Array.singleton Module Kernel].all? do |owner|
        Array(@prepended_modules[owner]).empty? && !@unknown_mixins.include?(owner) &&
          (owner == 'Kernel' || Array(@included_modules[owner]).empty?)
      end
  end

  # nil when Array#initialize is mruby's own native, else the reason it may not be.
  def array_initialize_refusal
    return 'initialize_outside_definer' if @closed_world.global_refusal || !@closed_world.core_native_arm_safe?('initialize', 'Array')
    return 'initialize_array_mixin' unless Array(@prepended_modules['Array']).empty? && !@unknown_mixins.include?('Array')

    installed = symbol_installed_destinations
    return 'initialize_installed' if installed.nil? || installed.include?('initialize')

    definitions = (@registry['initialize'] || []) + (self.class.core_hidden_defs || []).select { |d| d.name == 'initialize' }
    return 'initialize_defined_on_array' if definitions.any? { |definition| definition.owner == 'Array' }

    'initialize_native_spelled' unless array_new_natives_untouched?
  end

  # Native sources that spell `initialize` and name the Array class (other than array.c, which defines the one
  # being relied on) could replace it with C code no Ruby analysis sees.
  def array_new_natives_untouched?
    @closed_world.native_paths_spelling("initialize").all? do |path|
      path.end_with?('/src/array.c') || !File.read(path, encoding: 'BINARY').match?(/array_class|"Array"|MRB_SYM\(Array\)/)
    end
  end

  # ARRAY_NEW_BLOCK: the loop for one region, or nil when the body does not compile cleanly (the call stays).
  def emit_array_new_inline(region, irep, d)
    block_irep = region[:block_irep]
    offset = irep.nregs
    dest_reg = region[:dest_reg]
    size_reg = dest_reg.to_i + 1
    param_reg = 1 + offset
    addr = region[:block_addr]
    iter_label = "Lbc2cpp_anew_iter_#{addr}"
    break_label = "Lbc2cpp_anew_end_#{addr}"
    result_var = "bc2cpp_anew_v_#{addr}"
    broke = "bc2cpp_anew_broke_#{addr}"
    body = compile_inline_block_body(region, irep, d, iter_label, break_label: break_label, result_var: result_var,
                                                                  broke_flag: broke)
    return nil unless body

    out = String.new
    out << "  // ARRAY_NEW_BLOCK :new -- Array.new(n) { } as a counted loop; Array.new/Array#initialize are mruby's own " \
           "(docs/adr/0391), size by mrb_as_int as mrb_ary_init does\n"
    out << "  {\n"
    out << "    mrb_int bc2cpp_anew_n_#{addr} = mrb_as_int(M, r#{size_reg});\n"
    out << "    mrb_value bc2cpp_anew_acc_#{addr} = mrb_ary_new_capa(M, bc2cpp_anew_n_#{addr} > 0 ? bc2cpp_anew_n_#{addr} : 0);\n"
    out << "    mrb_bool #{broke} = FALSE;\n"
    out << "    for (mrb_int bc2cpp_anew_i_#{addr} = 0; bc2cpp_anew_i_#{addr} < bc2cpp_anew_n_#{addr}; " \
           "++bc2cpp_anew_i_#{addr}) {\n"
    out << inline_block_frame(block_irep, offset)
    out << "      mrb_value #{result_var} = mrb_nil_value();\n"
    out << "      r#{param_reg} = mrb_fixnum_value(bc2cpp_anew_i_#{addr});\n" if region[:bind_index]
    out << body
    out << "      #{iter_label}:;\n"
    out << "      mrb_ary_push(M, bc2cpp_anew_acc_#{addr}, #{result_var});\n"
    out << "    }\n"
    out << "    #{break_label}:;\n"
    out << "    if (!#{broke}) r#{dest_reg} = bc2cpp_anew_acc_#{addr};\n"
    out << "  }\n"
    out
  end
end
