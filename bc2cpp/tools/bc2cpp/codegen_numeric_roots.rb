# frozen_string_literal: true

require_relative 'bytecode_ir_containers'

# CodeGen: BC2CPP_NUMERIC_ROOTS=FILE writes, per guarded numeric operator whose operands NumericFlow could not prove,
# the class set of each operand and the leaves it is computed from. Measurement only: the generated code
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
        leaves.concat(numeric_root_leaves(irep, idx, reg.to_i, owner_def))
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
          numeric_root_leaves(irep, idx, BytecodeIR.for(irep).source_at(idx).reg.to_i + pos, d)
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

  # The writer a report label names for +reg+ as read by +use+: the instruction every reaching definition shares,
  # :entry when the value comes from the frame, or :unknown when the query refuses or the writers disagree.
  def numeric_label_source(irep, use, reg)
    defs = BytecodeIR.reaching_definitions(irep, use, reg.to_s)
    return :unknown if defs.nil? || defs.empty?
    return :entry if defs.all?(&:entry?)
    return :unknown if defs.any?(&:entry?)

    program = BytecodeIR.for(irep)
    sources = defs.map { |d| program.source_at(d.index) }
    first = sources.first
    sources.all? { |s| s.op == first.op && s.sym == first.sym } ? first : :unknown
  end

  # The non-numeric leaves of +reg+ as read by instruction +at+. Its writers are the reaching definitions
  # (BytecodeIR.reaching_definitions: joins, loops and handler edges; MOVEs followed), and each writer's own
  # operands are queried the same way. A refused query is a leaf of its own: the writes are unknown, not none.
  def numeric_root_leaves(irep, at, reg, owner_def)
    out = []
    seen = {}
    work = [[at, reg.to_i]]
    until work.empty?
      i, r = work.pop
      next if seen[[i, r]]

      seen[[i, r]] = true
      refusal = {}
      defs = BytecodeIR.reaching_definitions(irep, i, r.to_s, through_handlers: true, refusal: refusal)
      unless defs
        out << "unproven:#{refusal[:cause]}"
        next
      end
      defs.each do |d|
        writer = d.entry? ? nil : BytecodeIR.for(irep).source_at(d.index)
        if writer.nil? || !numeric_root_writer?(writer)
          next unless numeric_root_param?(irep, d.reg.to_i)

          out << "param:#{numeric_root_param_status(irep, d.reg.to_i, owner_def)}"
          next
        end
        out.concat(numeric_root_writer_leaves(irep, d.index, writer, owner_def, work))
      end
    end
    out.uniq
  end

  def numeric_root_writer?(insn)
    insn.op.start_with?('LOADI') || ROOT_WRITERS.include?(insn.op)
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

      numeric_root_leaves(sirep, idx, recv + k, sowner).first(2).join('+')
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
    return 'arity' unless entry_arg_shape?(@ireps[d.irep])
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

        numeric_root_leaves(sirep, idx, reg, numeric_irep_owner[sirep.label])
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
    # An arithmetic or passthrough writer's operands are read by it, so they are queried at it (MOVEs never
    # arrive here: reaching_definitions follows them).
    if ROOT_ARITH.key?(op) || ROOT_ARITH_IMM.include?(op)
      regs = [insn.reg.to_i]
      regs << (insn.reg.to_i + 1) if ROOT_ARITH.key?(op)
      regs.each do |r|
        m = numeric_raw_mask(irep, i, r, owner_def)
        work << [i, r] unless NumericFlow.numeric?(m)
      end
      return []
    end
    if %w[SEND SEND0].include?(op) && ROOT_PASSTHROUGH.include?(insn.sym) && insn.sym != 'min' && insn.sym != 'max'
      regs = [insn.reg.to_i]
      regs << (insn.reg.to_i + 1) if insn.argc.to_i == 1 && %w[% fdiv clamp].include?(insn.sym)
      regs.each { |r| work << [i, r] unless NumericFlow.numeric?(numeric_raw_mask(irep, i, r, owner_def)) }
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
              # Label only: the shared writer of the key register (not a feed set).
              kins = numeric_label_source(irep, i, insn.reg.to_i + 1)
              kins = nil unless kins.is_a?(Insn)
              kins&.op == 'LOADSYM' ? ":#{kins.sym}" : (kins&.op || '?')
            end
      inner = numeric_root_nest('') { numeric_root_leaves(irep, i, src, owner_def).first(2).join('+') }
      ["idx[#{key}]@#{recv.nil? ? 'unmodelled' : numeric_mask_name(recv)}<#{inner}>"]
    when 'AREF'
      src = insn.regs[1].to_i
      # Label only, as the GETIDX key above.
      wi = numeric_label_source(irep, i, src)
      what = if wi == :entry then 'param'
             elsif !wi.is_a?(Insn) then '?'
             elsif wi.op.start_with?('SEND', 'SSEND') then "send:#{wi.sym}"
             else wi.op
             end
      ["aref<#{what}>"]
    when 'GETIV' then ["iv:#{insn.ivar && "@#{insn.ivar}"}[#{numeric_root_ivar_status(irep, insn.ivar)}]"]
    when 'GETCONST', 'GETMCNST'
      cname = insn.const_name || insn.mcnst_name
      key = const_group_key(insn)
      group = key && @numeric_const_groups && @numeric_const_groups[key]
      state = group ? (group.failed ? (group.structural ? 'structural' : 'flowfail') : numeric_mask_name(group.mask)) : 'nogroup'
      ["const:#{cname}[#{state}#{@integer_constants&.include?(cname) ? ',intconst' : ''}]"]
    when 'GETUPVAR' then ['upvar']
    when 'LOADI_0', 'LOADI_1', 'LOADI8', 'LOADI16', 'LOADI32', 'LOADL' then []
    else ["op:#{op}"]
    end
  end
end
