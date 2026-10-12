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
# Keyed by const_group_key: the qualified definition a read reaches (LEXICAL_CONST, ADR 0421), or
# the bare name when that model is off. A name is tracked only when EVERY definition of it is
# visible: a CLASS/MODULE naming it, a native mrb_define_const family call, or a foreign Ruby
# definition (outside_const_names) poisons its bare name, and a site in an irep the flow cannot
# model or storing an unmodelled class fails it. A never-assigned constant raises NameError before
# any value exists, so it contributes nothing. A read with no key is not tracked and takes the
# fallback in numeric_const_mask.
class CodeGen
  NumericConstGroup = Struct.new(:name, :mask, :sites, :readers, :failed, :structural)

  # BC2CPP_LEXICAL_CONST=0 keys every constant by its bare name, the model before ADR 0421.
  def lexical_consts_enabled?
    return @lexical_consts_enabled if defined?(@lexical_consts_enabled)

    @lexical_consts_enabled = ENV.fetch('BC2CPP_LEXICAL_CONST', '1') != '0'
  end

  def lexical_const_info
    @lexical_const_info ||= LexicalConsts.analyze(@ireps, static: @closed_world&.constants_static? || false)
  end

  # The group key a GETCONST/GETMCNST reads, or nil when its definition is not proven.
  def const_group_key(insn)
    return insn.const_name unless lexical_consts_enabled?

    lexical_const_info.read_keys[insn]
  end

  # The group key a SETCONST/SETMCNST defines, or nil when its scope is unknown.
  def const_site_key(insn)
    return insn.const_name unless lexical_consts_enabled?

    lexical_const_info.site_keys[insn]
  end

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
          key = const_site_key(insn)
          next unless key

          group = (@numeric_const_groups[key] ||= NumericConstGroup.new(key, 0, [], Set.new, false, false))
          group.sites << [irep, idx, insn.regs.last]
        when 'GETCONST', 'GETMCNST'
          key = const_group_key(insn)
          next unless key

          (@numeric_const_groups[key] ||= NumericConstGroup.new(key, 0, [], Set.new, false, false)).readers << irep.label
        end
      end
    end
    @numeric_const_groups.each_value do |g|
      g.failed = g.structural = poisoned.include?(g.name.split('::').last) || g.sites.empty?
    end
  end

  def numeric_const_group(insn)
    key = const_group_key(insn)
    group = key && @numeric_const_groups && @numeric_const_groups[key]
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
        if mask.nil? || (mask & NumericFlow::OPAQUE) != 0
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
