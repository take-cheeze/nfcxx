# frozen_string_literal: true

require 'json'
require_relative 'dynamic_names'

# ADR 0337: named inputs are evidence, never a complete set of native slot writes.
class CodeGen
  NATIVE_SETTER_REPORT_CONTRACTS = {
    'contents=' => { slot: 'contents', owners: ['RGSS::Window'] },
    'bitmap=' => { slot: 'bitmap', owners: %w[RGSS::Sprite RGSS::Plane] }
  }.freeze

  def write_native_setter_report(path)
    sites = []
    mentions = []
    @ireps.each_value do |irep|
      owner = numeric_irep_owner[irep.label]
      irep.instructions.each_with_index do |insn, index|
        name = insn.sym
        if insn.op == 'STRING'
          literal = irep.pool[insn.pool_index.to_i]
          name = literal if literal.is_a?(String)
        end
        setter = NATIVE_SETTER_REPORT_CONTRACTS.key?(name) ? name : (name && NATIVE_SETTER_REPORT_CONTRACTS.key?(name + '=') ? name + '=' : nil)
        next unless setter

        row = { setter: setter, file: irep.file, owner: owner && "#{owner.owner}##{owner.name}",
                irep: irep.label, index: index, opcode: insn.op }
        unless RETURN_CALL_OPS.include?(insn.op) || %w[SENDB SSENDB].include?(insn.op)
          mentions << row.merge(spelling: name)
          next
        end
        next unless name == setter

        argc = insn.argc
        receiver = insn.reg && return_class_raw_mask(irep, index, insn.reg)
        input = argc == 1 && insn.reg && return_class_raw_mask(irep, index, insn.reg.to_i + 1)
        blockers = []
        blockers << 'unowned_callsite' unless owner
        blockers << 'non_single_positional_argument' unless argc == 1 && insn.plain_fixed_argc?
        blockers << 'receiver_unresolved' if native_setter_report_unknown?(receiver)
        blockers << 'input_unresolved' if native_setter_report_unknown?(input)
        sites << row.merge(dispatch: 'named_candidate_not_proven_native', argc: argc, receiver: receiver && class_mask_name(receiver),
                           input: input && class_mask_name(input), blockers: blockers)
      end
    end
    stems, computed = DynamicNames.analyze(@ireps)
    contracts = NATIVE_SETTER_REPORT_CONTRACTS.to_h do |setter, contract|
      scoped = @native_ivar_scopes[contract[:slot]]
      [setter, contract.merge(native_scope_audited: scoped == contract[:owners],
                              input_behavior: scoped == contract[:owners] ? 'functional body stores the supplied value unchanged; compiled-out body raises' : 'not_audited',
                              caller_completeness: 'not_proven', native_family_pooling: false,
                              named_calls: sites.count { |row| row[:setter] == setter },
                              dynamic_stems: stems.select { |name| name == setter || name + '=' == setter }.sort)]
    end
    report = { schema_version: 1, diagnostic_only: true, closed_world: !@closed_world.nil?,
               global_refusal: @closed_world&.global_refusal, computed_names_present: computed, contracts: contracts,
               sites: sites.sort_by { |row| [row[:file].to_s, row[:owner].to_s, row[:irep].to_s, row[:index]] },
               mentions: mentions.sort_by { |row| [row[:file].to_s, row[:irep].to_s, row[:index]] } }
    File.write(path, JSON.pretty_generate(report) + "\n")
  end

  def native_setter_report_unknown?(mask)
    !mask.is_a?(Integer) || mask.zero? || mask.anybits?(CLASS_POOL_UNSHIPPABLE)
  end
end
