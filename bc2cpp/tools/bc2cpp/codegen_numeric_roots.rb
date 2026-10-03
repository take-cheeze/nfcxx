# frozen_string_literal: true

# CodeGen: BC2CPP_NUMERIC_ROOTS=FILE writes, per guarded numeric operator whose operands NumericFlow could not prove,
# the class set of each operand and the leaves it is computed from (ADR 0311). Measurement only: the generated code
# is byte-identical with it on.
class CodeGen
  ROOT_ARITH = { 'ADD' => 1, 'SUB' => 1, 'MUL' => 1, 'DIV' => 1 }.freeze
  ROOT_ARITH_IMM = %w[ADDI SUBI ADDILV SUBILV].freeze
  # Core sends whose result is a number exactly when the receiver (and operand) is one.
  ROOT_PASSTHROUGH = %w[% -@ to_i to_f abs floor ceil round truncate sin cos sqrt fdiv].freeze
  # Ops that define their leading register (the rest of WRITES_LEADING_REG_OPS only read it or store elsewhere).
  ROOT_WRITERS = (BytecodeIR::WRITES_LEADING_REG_OPS -
                  %w[NOP SETGV SETSV SETIV SETCV SETCONST SETMCNST SETIDX JMP JMPIF JMPNOT JMPNIL ENTER KEYEND RETURN
                     RETURN_BLK RETSELF RETNIL RETTRUE RETFALSE BREAK DEBUG STOP]).freeze

  def numeric_root_probe(name, dest_reg, arg_reg, irep, idx, owner_def, reg_offset)
    return unless ENV['SKIP_UNSUPPORTED'] == '1' && numeric_op_native?(name) && reg_offset.zero?

    parts = []
    leaves = []
    [[dest_reg, 'L'], [arg_reg, 'R']].each do |reg, side|
      next unless reg

      raw = numeric_raw_mask(irep, idx, reg.to_i, owner_def)
      parts << "#{side}=#{raw.nil? ? 'unmodelled' : numeric_mask_name(raw)}"
      next if NumericFlow.numeric?(raw)

      begin
        leaves.concat(numeric_root_leaves(irep, idx - 1, reg.to_i, owner_def))
      rescue StandardError => e
        leaves << "ERR:#{e.class}:#{e.message[0, 80]}@#{e.backtrace&.first}"
      end
    end
    owner = owner_def ? "#{owner_def.owner}##{owner_def.name}" : '?'
    line = ['ROOT', owner, name, *parts, "LEAVES=#{leaves.uniq.join('|')}"].join("\t")
    # Latest compile of a site wins: earlier probes run with weaker facts.
    CodeGen.numeric_root_lines[[irep.label, idx]] = line.gsub(/[\r\n]/, ' ')
  end

  # One TUPLE line per position of every tuple fact that is not fully proven: the leaves its definitions put there.
  def numeric_root_tuple_dump
    (@tuple_returns || {}).each do |name, masks|
      masks.each_with_index do |mask, pos|
        next if NumericFlow.numeric?(mask)

        leaves = @tuple_sites[name].flat_map do |irep, idx, d, _n|
          numeric_root_leaves(irep, idx - 1, irep.instructions[idx].reg.to_i + pos, d)
        end
        CodeGen.numeric_root_lines[[:tuple, name, pos]] =
          ['TUPLE', name, pos, numeric_mask_name(mask), leaves.uniq.join('|')].join("\t").gsub(/[\r\n]/, ' ')
      end
    end
  end

  def numeric_root_forget(irep, idx)
    CodeGen.numeric_root_lines.delete([irep.label, idx])
  end

  # One table for every CodeGen of the run, written once at exit (the last compile of a site wins).
  def self.numeric_root_lines
    @numeric_root_lines ||= {}.tap do |lines|
      at_exit { File.write(ENV.fetch("BC2CPP_NUMERIC_ROOTS"), "#{lines.values.join("\n")}\n") }
    end
  end

  # The non-numeric leaves feeding +reg+ as read after instruction +idx+: the nearest earlier writer, looking
  # through arithmetic and moves, plus later MOVE/arithmetic writers of the same register (loop-carried values).
  def numeric_root_leaves(irep, idx, reg, owner_def)
    out = []
    seen = {}
    work = [[idx, reg.to_i]]
    until work.empty?
      from, r = work.pop
      w = irep.last_writer_index(from, r.to_s)
      w = nil if w && !numeric_root_writer?(irep.instructions[w])
      out << "param:#{numeric_root_param_status(irep, r, owner_def)}" if w.nil? && numeric_root_param?(irep, r)
      later = irep.instructions.each_index.select do |i|
        i > from && irep.instructions[i].reg.to_s == r.to_s && numeric_root_loop_writer?(irep.instructions[i])
      end
      ([w] + later).compact.each do |i|
        next if seen[i]

        seen[i] = true
        out.concat(numeric_root_writer_leaves(irep, i, irep.instructions[i], owner_def, work))
      end
    end
    out.uniq
  end

  def numeric_root_writer?(insn)
    insn.op.start_with?('LOADI') || ROOT_WRITERS.include?(insn.op)
  end

  def numeric_root_loop_writer?(insn)
    insn.op == 'MOVE' || ROOT_ARITH.key?(insn.op) || ROOT_ARITH_IMM.include?(insn.op)
  end

  # Why a method argument is not a proven number: the admission rule it fails (entry_arg_candidates), or, for an
  # admitted one, the leaves of the argument at the call sites that dropped it.
  def numeric_root_param_status(irep, reg, owner_def)
    return 'noowner' unless owner_def

    tag = "#{owner_def.owner}##{owner_def.name}:r#{reg}"
    key = [irep.label, reg]
    cand = @entry_cand && @entry_cand[key]
    return "#{tag}[#{numeric_root_not_admitted(owner_def)}]" unless cand

    pooled = @entry_arg_numeric && @entry_arg_numeric[key]
    return "#{tag}[pooled=#{numeric_mask_name(pooled)}]" if pooled

    sites, k = cand
    culprits = sites.filter_map do |(sirep, idx, recv, _argc, sowner)|
      mask = numeric_raw_mask(sirep, idx, recv + k, sowner)
      next if mask && (mask & NumericFlow::OPAQUE).zero?

      numeric_root_leaves(sirep, idx - 1, recv + k, sowner).first(2).join('+')
    end
    "#{tag}[dropped<#{culprits.uniq.first(3).join(';')}>]"
  end

  def numeric_root_not_admitted(d)
    name = d.name
    defs = @registry[name] || []
    sites, poisoned = entry_arg_call_index
    return "multidef#{defs.size}" unless defs.size == 1
    return 'foreign' if @foreign_method_names.include?(name)
    return 'outside_token' if @outside_tokens.include?(name)
    return 'initialize' if name == 'initialize'
    return 'poisoned' if poisoned.include?(name)
    return 'dynamic_name' if numeric_dynamically_named?(name)
    return 'no_irep' unless d.irep
    return 'arity' unless pure_mandatory_arity?(@ireps[d.irep])
    return 'nosites' if sites[name].empty?

    'site_argc_mismatch'
  end

  def numeric_root_ivar_status(irep, name)
    owner = numeric_irep_owner[irep.label]
    return 'noowner' unless owner
    return "nofamily#{@numeric_ivar_disabled ? '-disabled' : ''}" unless @numeric_family_find

    group = (@numeric_ivar_groups || {})[[numeric_family(owner.owner), name]]
    return 'nogroup' unless group
    return numeric_root_ivar_failure(owner, group) if group.failed

    numeric_mask_name(group.mask)
  end

  # Run the block one level deep only: leaves of leaves would recurse through ivar stores and index reads.
  def numeric_root_nest(default)
    return default if @numeric_root_depth.to_i.positive?

    @numeric_root_depth = 1
    begin
      yield
    ensure
      @numeric_root_depth = 0
    end
  end

  # The leaves of the stores into a failed ivar group that were not provably numeric.
  def numeric_root_flowfail(group)
    numeric_root_nest('flowfail') do
      leaves = group.sites.flat_map do |sirep, idx, reg|
        mask = numeric_raw_mask(sirep, idx, reg, numeric_irep_owner[sirep.label])
        next [] if mask && (mask & NumericFlow::OPAQUE).zero?

        numeric_root_leaves(sirep, idx - 1, reg, numeric_irep_owner[sirep.label])
      end
      "flowfail<#{leaves.uniq.first(4).join(';')}>"
    end
  end

  def numeric_root_ivar_failure(owner, group)
    return numeric_root_flowfail(group) unless group.structural

    return 'native-spelled' if numeric_ivar_native_poisoned?(group.family, group.name)
    return 'wild-family' if @numeric_wild_families.include?(group.family)

    "writer/other(#{owner.owner})"
  end

  def numeric_root_param?(irep, reg)
    enter = irep.enter
    return false unless enter

    mand, opt, rest, post = enter.enter_fields
    reg >= 1 && reg <= mand.to_i + opt.to_i + rest.to_i + post.to_i
  end

  def numeric_root_writer_leaves(irep, i, insn, owner_def, work)
    op = insn.op
    if op == 'MOVE'
      work << [i - 1, insn.regs[1].to_i]
      return []
    elsif ROOT_ARITH.key?(op) || ROOT_ARITH_IMM.include?(op)
      regs = [insn.reg.to_i]
      regs << (insn.reg.to_i + 1) if ROOT_ARITH.key?(op)
      regs.each do |r|
        m = numeric_raw_mask(irep, i, r, owner_def)
        work << [i - 1, r] unless NumericFlow.numeric?(m)
      end
      return []
    end
    if %w[SEND SEND0].include?(op) && ROOT_PASSTHROUGH.include?(insn.sym) && insn.sym != 'min' && insn.sym != 'max'
      regs = [insn.reg.to_i]
      regs << (insn.reg.to_i + 1) if insn.argc.to_i == 1 && %w[% fdiv clamp].include?(insn.sym)
      regs.each { |r| work << [i - 1, r] unless NumericFlow.numeric?(numeric_raw_mask(irep, i, r, owner_def)) }
      return []
    end
    case op
    when 'SEND', 'SEND0', 'SENDB', 'SSEND', 'SSEND0', 'SSENDB'
      recv = numeric_raw_mask(irep, i, insn.reg.to_i, owner_def)
      kind = if op.start_with?('SS') then 'self'
             else recv.nil? ? 'unmodelled' : numeric_mask_name(recv)
             end
      sname = insn.sym
      tracked = @numeric_return && @numeric_return[sname]
      defs = (@registry[sname] || []).map { |d| d.owner == '<native>' ? 'native' : 'ruby' }.tally
      ["send:#{sname}@#{kind}[#{tracked ? "ret=#{numeric_mask_name(tracked)}" : 'untracked'} defs=#{defs.map { |k, v| "#{k}#{v}" }.join(',')}]"]
    when 'GETIDX', 'GETIDX0'
      src = op == 'GETIDX0' ? insn.regs[1].to_i : insn.reg.to_i
      recv = numeric_raw_mask(irep, i, src, owner_def)
      key = if op == 'GETIDX0' then '0'
            else
              kw = irep.last_writer_index(i - 1, (insn.reg.to_i + 1).to_s)
              kins = kw && irep.instructions[kw]
              kins&.op == 'LOADSYM' ? ":#{kins.sym}" : (kins&.op || '?')
            end
      inner = numeric_root_nest('') { numeric_root_leaves(irep, i - 1, src, owner_def).first(2).join('+') }
      ["idx[#{key}]@#{recv.nil? ? 'unmodelled' : numeric_mask_name(recv)}<#{inner}>"]
    when 'AREF'
      src = insn.regs[1].to_i
      w = irep.last_writer_index(i - 1, src.to_s)
      wi = w && irep.instructions[w]
      what = if wi.nil? then 'param'
             elsif wi.op.start_with?('SEND', 'SSEND') then "send:#{wi.sym}"
             else wi.op
             end
      ["aref<#{what}>"]
    when 'GETIV' then ["iv:#{insn.args[/@\w+/]}[#{numeric_root_ivar_status(irep, insn.ivar)}]"]
    when 'GETCONST', 'GETMCNST'
      cname = insn.const_name || insn.mcnst_name
      group = @numeric_const_groups && @numeric_const_groups[cname]
      state = group ? (group.failed ? (group.structural ? 'structural' : 'flowfail') : numeric_mask_name(group.mask)) : 'nogroup'
      ["const:#{cname}[#{state}#{@integer_constants&.include?(cname) ? ',intconst' : ''}]"]
    when 'GETUPVAR' then ['upvar']
    when 'LOADI_0', 'LOADI_1', 'LOADI8', 'LOADI16', 'LOADI32', 'LOADL' then []
    else ["op:#{op}"]
    end
  end
end
