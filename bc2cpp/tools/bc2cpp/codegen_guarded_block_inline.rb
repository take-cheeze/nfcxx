# frozen_string_literal: true

require 'set'

# GUARDED_BLOCK_INLINE (docs/adr/0420): the inlined block loops of codegen_loop_inline.rb for a receiver whose class is
# NOT proven. The loop is emitted behind a run-time exact-class test (the same test as BLOCK_CORE_DIRECT's arm), and
# the ordinary BLOCK + SENDB code stays right behind it as the else, so every other receiver (a subclass, a singleton,
# a Hash, nil, a user class) dispatches exactly as before. A receiver that passes the test runs the block body in the
# method's own _impl: no RProc, no mrb_funcall_with_block, no yield.
#
# What makes the inline loop the same as the dispatch it replaces is what makes the proven inline loop the same
# (recognize_* in codegen_loop_regions.rb), plus the arm gate: block_core_arms(name, argc) names the class, which is
# the proof that no Ruby definition, prepend, outside definer or dynamic installer can answer `name` on that class
# (block_core_target). The root-context test of ADR 0269 is kept, so a Fiber's frames still reach the bytecode.
class CodeGen
  # The exact-class test of an unproven receiver, by the class the region's recognizer asked for.
  GUARDED_INLINE_TESTS = {
    'Array' => 'mrb_array_p(%<r>s) && mrb_obj_ptr(%<r>s)->c == M->array_class',
    'Hash' => 'mrb_hash_p(%<r>s) && mrb_obj_ptr(%<r>s)->c == M->hash_class'
  }.freeze

  # BC2CPP_GUARDED_BLOCK_INLINE=0 turns the guarded loops off, to measure them against the arms alone.
  def guarded_block_inline_enabled?
    ENV['BC2CPP_GUARDED_BLOCK_INLINE'] != '0'
  end

  # True while run_inline_loop_passes asks the recognizers (the whole-method pass only).
  def guarded_inline_sites?
    !@guarded_inline_sites.nil?
  end

  # The class each recognizer asks for (region_receiver?), so the emit loop knows which test a guarded region gets.
  GUARDED_INLINE_PASS_CLASS = {
    recognize_each_regions: 'Array', recognize_each_index_regions: 'Array', recognize_hash_each_regions: 'Hash',
    recognize_hash_each_value_regions: 'Hash', recognize_each_key_regions: 'Hash', recognize_sym_regions: 'Array',
    recognize_collect_regions: 'Array', recognize_accum_regions: 'Array', recognize_sort_regions: 'Array'
  }.freeze

  # Is an unproven `klass` receiver of this block send a candidate for a guarded inline loop? Records [send address,
  # class]; guarded_inline_finish settles it once the send's own BLOCK_CORE_DIRECT arms are known. One send may get a
  # loop per class (`each` with a |k, v| block: Array spread, then Hash): the exact-class tests are exclusive, and
  # each loop jumps over the rest.
  def guarded_inline_receiver?(insn, klass)
    return false unless guarded_inline_sites? && GUARDED_INLINE_TESTS.key?(klass)
    return false unless block_core_direct_enabled? && block_core_world && @native_name_sources

    @guarded_inline_sites[[insn.addr, klass]] = true
    true
  end

  # BC2CPP_GUARDED_INLINE_WHY=1 reports on stderr why a send that asked for a guarded loop did not get one.
  def guarded_inline_why(irep, insn, klass, reason)
    return unless ENV['BC2CPP_GUARDED_INLINE_WHY'] == '1'

    warn "guarded_inline_why: #{irep.label}@#{insn.addr} :#{insn.sym} #{klass} -- #{reason}"
  end

  # The same report for the sends no recognizer claimed at all: the block's shape is what refuses them.
  def guarded_inline_unclaimed(irep, regions, guarded, inlined)
    return unless ENV['BC2CPP_GUARDED_INLINE_WHY'] == '1'

    claimed = guarded[:pending].map { |pending| pending[:region][:sendb_addr] }
    regions.each do |region|
      next if claimed.include?(region[:sendb_addr]) || inlined.include?(region[:sendb_addr]) || region[:name].nil?

      block = region[:block_irep]
      arity = block ? mandatory_arity(block) : '?'
      pure = block ? pure_mandatory_arity?(block) : '?'
      shape = block ? (block.instructions.find { |i| i.op == 'ENTER' }&.then { |i| i.enter_fields.join(':') } || 'noenter') : '?'
      guarded_inline_why(irep, irep.instructions[irep.index_of_addr(region[:sendb_addr])], '-',
                         "unclaimed arity=#{arity} pure=#{pure} enter=#{shape} brk=#{region[:needs_brk] ? 1 : 0} ret=#{region[:needs_ret] ? 1 : 0}")
    end
  end

  # The arm gate, read where the send's own BLOCK_CORE_DIRECT arms are decided: block_core_arms(name, argc) names the
  # class when the compiled core body of that name is what the class answers with (no Ruby definition, prepend,
  # unattributed mixin, outside definer, native registration or dynamic installer on the chain, ADR 0270). It is only
  # READ from the cache the block-send wrapper filled for this very send, never computed here: computing it ahead of
  # the wrapper would change the context (and so the cached answer) other sends get it in.
  def guarded_inline_arm?(name, argc, klass)
    arms = @block_core_arms && @block_core_arms[[name, argc]]
    !arms.nil? && arms.any? { |arm| arm[:class] == klass }
  end

  # The guarded regions the passes emitted, settled after the fallback glue pass has run the wrapper for every send
  # of the method: a region whose class has no arm for the name gives its nested functions back.
  def guarded_inline_finish(irep, guarded)
    guarded[:pending].each do |pending|
      region = pending[:region]
      insn = irep.instructions[irep.index_of_addr(region[:sendb_addr])]
      argc = insn.argc_text.to_s[/n=(\d+)/, 1]&.to_i
      glue = argc && guarded_inline_arm?(insn.sym, argc, pending[:klass]) &&
             guarded_inline_glue(region, irep, pending[:inlined], pending[:klass], guarded[:after])
      if glue
        guarded[:at][pending[:anchor]] = "#{guarded[:at][pending[:anchor]]}#{glue}"
      else
        guarded_inline_why(irep, insn, pending[:klass], argc ? 'no BLOCK_CORE_DIRECT arm for the name' : 'argument shape')
        @inline_nested_pre.sub!(pending[:pre]) { '' } unless pending[:pre].empty?
      end
    end
  end

  # Did the whole-method pass put a guarded loop in front of the send at `addr` of `irep` (block_send_report)?
  def guarded_inline_site?(irep, addr)
    (@guarded_inline_done ||= Set.new).include?([irep.label, addr])
  end

  # run_inline_loop_passes with guarded sites collected: yields the class recorded for each send.
  def with_guarded_inline_sites
    saved = @guarded_inline_sites
    @guarded_inline_sites = guarded_block_inline_enabled? ? {} : nil
    yield
  ensure
    @guarded_inline_sites = saved
  end

  # The glue of a guarded region: the loop behind the class test, then a jump over the ordinary send. `after_at`
  # gets the label at the instruction after the SENDB.
  def guarded_inline_glue(region, irep, inlined, klass, after_at)
    recv = "r#{region[:dest_reg]}"
    send_idx = irep.index_of_addr(region[:sendb_addr])
    after = irep.instructions[send_idx + 1]
    return nil unless after

    (@guarded_inline_done ||= Set.new) << [irep.label, region[:sendb_addr]]
    label = "Lbc2cpp_guarded_end_#{region[:sendb_addr]}"
    after_at[after.addr] = "  #{label}:;\n"
    test = format(GUARDED_INLINE_TESTS.fetch(klass), r: recv)
    "  // GUARDED_BLOCK_INLINE :#{irep.instructions[send_idx].sym} -- exact #{klass} receiver runs " \
      "the block body inline; any other receiver takes the send below\n" \
      "  if (M->c == M->root_c && #{test}) {\n#{inlined}    goto #{label};\n  }\n"
  end
end
