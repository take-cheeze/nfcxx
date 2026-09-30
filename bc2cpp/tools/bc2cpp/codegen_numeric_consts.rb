# frozen_string_literal: true

require_relative 'numeric_flow'

# CodeGen: NUMERIC_CONSTANT_PROOF (ADR 0276).
#
# What class set can constant `NAME` hold? INTEGER_CONSTANT_PROOF admits a name
# only when every definition is an Integer literal (or an alias/sum of such), so
# `HEADER_H = LINE_H + Window::BORDER * 2` or `ROWS = SCREEN_H / TILE + 1` --
# most of the layout constants -- never qualify. This is the same keyed-by-bare-
# name argument with NumericFlow deciding each definition: the name's mask is the
# join of the class sets its SETCONST/SETMCNST sites store, a least fixpoint with
# the other numeric facts (a constant can be defined from another).
#
# Keyed by bare name because a GETCONST resolves through lexical scope and
# ancestors this file does not model, so a name is tracked only when EVERY
# definition of it is visible: a CLASS/MODULE naming it, a native
# mrb_define_const family call, or a foreign Ruby definition (outside_const_names)
# poisons it, and a site in an irep the flow cannot model or storing an unmodelled
# class fails it. A never-assigned constant raises NameError before any value
# exists, so it contributes nothing.
class CodeGen
  NumericConstGroup = Struct.new(:name, :mask, :sites, :readers, :failed)

  def setup_numeric_consts
    @numeric_const_groups = {}
    return unless @outside_const_names && @closed_world && @closed_world.global_refusal.nil?

    poisoned = Set.new(@outside_const_names)
    @ireps.each_value do |irep|
      irep.instructions.each_with_index do |insn, idx|
        case insn.op
        when 'CLASS', 'MODULE'
          poisoned << insn.sym_token
        when 'SETCONST', 'SETMCNST'
          name = insn.const_name
          next unless name

          group = (@numeric_const_groups[name] ||= NumericConstGroup.new(name, 0, [], Set.new, false))
          group.sites << [irep, idx, insn.regs.last]
        when 'GETCONST', 'GETMCNST'
          name = insn.const_name
          next unless name

          (@numeric_const_groups[name] ||= NumericConstGroup.new(name, 0, [], Set.new, false)).readers << irep.label
        end
      end
    end
    @numeric_const_groups.each_value { |g| g.failed = poisoned.include?(g.name) || g.sites.empty? }
  end

  def numeric_const_group(insn)
    name = insn.const_name
    group = name && @numeric_const_groups && @numeric_const_groups[name]
    group unless group&.failed
  end

  def numeric_const_mask(insn)
    group = numeric_const_group(insn)
    return group.mask if group

    name = insn.const_name
    name && @integer_constants.include?(name) ? NumericFlow::INT : NumericFlow::OTHER
  end

  # One growth pass; true when any mask changed or a group failed.
  def grow_numeric_consts
    return false unless @numeric_const_groups

    changed = false
    @numeric_const_groups.each_value do |group|
      next if group.failed

      joined = 0
      ok = true
      group.sites.each do |irep, idx, reg|
        mask = numeric_raw_mask(irep, idx, reg, true)
        if mask.nil? || (mask & NumericFlow::OTHER) != 0
          ok = false
          break
        end
        joined |= mask
      end
      if !ok
        group.failed = true
      elsif (joined | group.mask) == group.mask
        next
      else
        group.mask |= joined
      end
      group.readers.each { |label| numeric_invalidate(label) }
      changed = true
    end
    changed
  end
end
