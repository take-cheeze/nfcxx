# frozen_string_literal: true

require 'set'
require_relative 'bytecode_ir'
require_relative 'codegen_decided_branch'

# ARM_PRUNE: the instructions of a method's top-level body that no edge reaches, in a control-flow graph where a decided
# jump (codegen_decided_branch.rb) keeps only the edge it takes. The graph uses the same jump operands the emitter writes
# (`goto`), plus the catch-handler edges, and treats an unknown opcode as falling through, so it never reports an
# instruction reachable code can enter as dead.
#
# Stage A (always on) computes the set and counts it into CodeGen.arm_prune_stats; the C++ does not change.
# Stage B (on by default; BC2CPP_PRUNE_ARMS=0 turns it off) drops the text of those instructions in a method that passes the checks in
# CodeGen#arm_prune_resolve, and keeps the whole method otherwise. CodeGen.arm_prune_refusals counts why.
#
# Only a method's own body is analysed: a block body's registers are offset into its enclosing frame, so its reachability
# is not derived here (ADR 0535).
class CodeGen
  ARM_PRUNE_TERMINATORS = %w[RETURN RETURN_BLK STOP].freeze
  # A C++ declaration of an identifier: pruned text that declares one is kept, since live code could name it.
  ARM_PRUNE_DECLARATION = /\b(?:mrb_\w+|int|unsigned|long|bool|double|float|size_t|auto|char)\b\s*[*&]?\s*\w+\s*(?:=|;|\[)/
  ARM_PRUNE_MARKER = /\x01ARM_PRUNE:(\d+)\x01/

  def self.arm_prune_stats
    @arm_prune_stats ||= Hash.new(0)
  end

  def self.arm_prune_refusals
    @arm_prune_refusals ||= Hash.new(0)
  end

  def arm_prune_stage_b_enabled?
    ENV['BC2CPP_PRUNE_ARMS'] != '0'
  end

  # The indices of the instructions of +irep+ (its own top-level body) that no edge reaches, or nil when the graph cannot be
  # built exactly (an unresolved jump or handler target). Counts the result into arm_prune_stats.
  def arm_prune_analysis(irep, owner_def)
    prog = BytecodeIR.for(irep)
    return arm_prune_refuse(:unresolved_graph) unless prog.handlers_resolved?

    insns = irep.instructions
    addr_idx = insns.each_with_index.to_h { |insn, i| [insn.addr, i] }
    handler_succ = Hash.new { |h, k| h[k] = [] }
    prog.handler_edges.each { |edge| handler_succ[edge.src] << edge.target }
    entry_targets = jump_targets(irep).filter_map { |addr| addr_idx[addr] }
    jump_target = ->(addr) { addr_idx.fetch(addr, :unresolved) }
    seen = Set.new
    work = [0]
    until work.empty?
      i = work.pop
      next if i.nil? || i >= insns.size || seen.include?(i)

      seen << i
      insn = insns[i]
      succ =
        case insn.op
        when 'JMP', 'JMPUW' then [jump_target.call(insn.jmp_addr)]
        when 'JMPIF', 'JMPNOT', 'JMPNIL'
          outcome = decided_branch_outcome(insn, irep, owner_def, i)
          taken = outcome == :not_taken ? [] : [jump_target.call(insn.uint_operand.to_i)]
          taken + (outcome == :taken ? [] : [i + 1])
        when *ARM_PRUNE_TERMINATORS then []
        when 'ENTER' then [i + 1, *entry_targets]
        else [i + 1]
        end
      return arm_prune_refuse(:unresolved_graph) if succ.include?(:unresolved)

      work.concat(succ.compact, handler_succ[i])
    end
    unreachable = (0...insns.size).to_set - seen
    self.class.arm_prune_stats[:methods] += 1
    self.class.arm_prune_stats[:unreachable] += unreachable.size
    self.class.arm_prune_stats[:instructions] += insns.size
    unreachable
  end

  # Stage B's decision for the text it held back: true when the pruned text may be dropped. A declaration in it would be
  # a name live code could still use, so the method is kept whole.
  def arm_prune_resolve(out, texts)
    if texts.values.any? { |text| arm_prune_declares_outside_block?(text) }
      arm_prune_refuse(:declaration)
      return out.gsub(ARM_PRUNE_MARKER) { texts.fetch(Regexp.last_match(1).to_i) }
    end

    self.class.arm_prune_stats[:dropped] += texts.size
    out.gsub(ARM_PRUNE_MARKER, '')
  end

  private

  # A declaration inside its own `{ ... }` block is out of reach of live code, so only the text outside every balanced
  # block counts. Unbalanced braces are refused.
  def arm_prune_declares_outside_block?(text)
    return true unless text.count('{') == text.count('}')

    outside = text.dup
    outside = outside.gsub(/\{[^{}]*\}/, '') while outside.match?(/\{[^{}]*\}/)
    outside.match?(ARM_PRUNE_DECLARATION)
  end

  def arm_prune_refuse(reason)
    self.class.arm_prune_refusals[reason] += 1
    nil
  end
end
