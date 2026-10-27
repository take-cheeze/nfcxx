# frozen_string_literal: true

# CodeGen: KERNEL_LOOP_INLINE, an inlined `loop do ... end`.
#
# Kernel#loop (mruby mrblib/kernel.rb) is `while true; yield; end rescue StopIteration => e; e.result`. Called with a
# literal block it runs the block forever, so the block's `break` is the only normal exit, and a BLOCK_FALLBACK
# `break` is a C++ throw per call (LCF.read_ber's loop threw once per BER integer read). The inlined form is a `for
# (;;)` over the block body, with `break` a goto. The rescue is kept: the loop runs under its own mrb_jmpbuf, so an
# mruby exception raised in the body lands in bc2cpp_loop_rescue, which answers StopIteration's result and re-raises
# anything else, as the rescue clause does.
#
# The site must call Kernel's own `loop`: BLOCK_CORE_DIRECT's proof that mruby's Kernel body is the program's only
# definition of the name (block_core_kernel_definition). BC2CPP_KERNEL_LOOP=0 keeps the call.
class CodeGen
  def kernel_loop_inline_enabled?
    ENV['BC2CPP_KERNEL_LOOP'] != '0'
  end

  def recognize_kernel_loop_regions(irep)
    return [] unless kernel_loop_inline_enabled? && @closed_world && @native_name_sources &&
                     block_core_kernel_definition('loop', 0)

    regions = []
    each_block_site(irep, send_ops: %i[SSENDB], layout: named_layout('loop')) do |insn, _idx, block_insn, dest_reg, block_irep|
      next unless mandatory_arity(block_irep).zero? && pure_mandatory_arity?(block_irep)
      next unless block_blk_needs(block_irep) == []

      regions << { block_addr: block_insn.addr, sendb_addr: insn.addr, dest_reg: dest_reg, block_irep: block_irep }
    end
    regions
  end

  # The jmpbuf is installed before the `try` and put back by a guard, so a goto out of the loop, a method return
  # and a foreign C++ throw (a block break aimed at an outer frame) all leave M->jmp as they found it.
  def emit_kernel_loop_inline(region, irep, d)
    return nil if @resumable

    block_irep = region[:block_irep]
    offset = irep.nregs
    addr = region[:block_addr]
    iter_label = "Lbc2cpp_loop_iter_#{addr}"
    break_label = "Lbc2cpp_loop_end_#{addr}"
    body = compile_inline_block_body(region, irep, d, iter_label, break_label: break_label)
    return nil unless body

    jmp = "bc2cpp_loop_jmp_#{addr}"
    out = String.new
    out << "  // KERNEL_LOOP_INLINE: Kernel#loop with its block inlined; break leaves the for, StopIteration is rescued\n"
    out << "  {\n"
    out << "    struct mrb_jmpbuf #{jmp};\n"
    out << "    const Bc2cppVmMark #{jmp}_mark = bc2cpp_vm_mark(M);\n"
    out << "    const bc2cpp_jmp_restore #{jmp}_guard{M, M->jmp};\n"
    out << "    try {\n"
    out << "      M->jmp = &#{jmp};\n"
    out << "      for (;;) {\n"
    out << inline_block_frame(block_irep, offset)
    out << body
    out << "        #{iter_label}:;\n"
    out << "      }\n"
    out << "    } catch (struct mrb_jmpbuf* bc2cpp_loop_e) {\n"
    out << "      if (bc2cpp_loop_e != &#{jmp}) throw;\n"
    out << "      r#{region[:dest_reg]} = bc2cpp_loop_rescue(M, #{jmp}_mark);\n"
    out << "    }\n"
    out << "  }\n"
    out << "  #{break_label}:;\n"
    out
  end
end
