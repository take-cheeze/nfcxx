# frozen_string_literal: true

require_relative 'site_census'
require_relative 'bytecode_ir'

# Exact receiver origins for the site census (see docs/bc2cpp-dynamic-site-census.md).
#
# With BC2CPP_SITE_ORIGIN_TABLE=<path>, every by-name line that dispatches on a register carries
# `/*SO:<label>:<index>:<reg>:<walk>*/`, and <path> receives one row per distinct tag:
#
#   label  index  reg  status  category  definition  walk
#
# `reg` is the register the line receives (its C++ name, the receiver of its first by-name call).
# `walk` is the register the reaching-definition walk runs on: `reg` less the offset of a shifted block
# body, which is the register the fast path's proof walks (unshift_proof_reg). The two differ only in a
# shifted body, where the line names the shifted register and the block's own register is `walk`.
#
# `status` is what BytecodeIR.reaching_definitions answers for `walk` at `index`: `exact` (one definition
# reaches it, MOVE chains followed), `ambiguous` (several definitions reach it through a join or a loop),
# `refused` (the dataflow cannot prove the set) or `none` (no definition). `category` is the origin of the
# single definition for `exact`, and `-` otherwise; `definition` is that writer as `OP@index` (`entry` for
# the method's incoming value).
#
# A definition is classified by the instruction that writes it: ENTRY and LOADSELF by their
# register, any other write by the right-hand side compile_insn emitted for it (the rules
# SiteCensus.origin_of applies to text), and by opcode when no text exists.
module SiteOriginTable
  BY_NAME = /\bbc2cpp_send\(|\bmrb_funcall\w*\(|\bbc2cpp_funcall_(?:argv|noarg|explicit)\(/
  # The receiver of a line's first by-name call: `bc2cpp_send(M, RECV`, `mrb_funcall(M, RECV`, ...
  DISPATCH_RECV = /(?:\bbc2cpp_send|\bmrb_funcall\w*|\bbc2cpp_funcall_(?:argv|noarg|explicit))\(M, (\w+)/
  TAG = %r{\s*/\*S[RO]:[^*]*\*/}
  # The ENTER fields that name a positional argument register: REQ, OPT, REST, POST.
  POSITIONAL_FIELDS = 4

  # Prepended into CodeGen, so only these hooks live here; the writer is separate.
  ROWS = {}
  INSN_TEXT = {}

  def compile_send(insn, **kwargs)
    code = super
    irep = kwargs[:irep]
    site = kwargs[:idx] || kwargs[:trace_idx]
    return code unless irep && site && !kwargs[:self_implicit] && insn.n_spec != '*' && !insn.nk_spec

    tag_dispatch_lines(code, irep, site, kwargs[:trace_reg_offset] || 0, nil)
  end

  # Lines compile_send did not tag: by-name calls a codegen helper emits directly (GETIDX and SETIDX
  # fallbacks, numeric slow paths), and the splat/keyword sends compile_send returns untagged. The line
  # must dispatch on a register the instruction names, so the walk is that instruction's own.
  def compile_insn(insn, irep, owner_def, idx = nil, reg_offset = 0)
    code = super
    INSN_TEXT[[irep.label, idx]] = code if irep && idx && reg_offset.zero?
    return code unless irep && idx

    tag_dispatch_lines(code, irep, idx, reg_offset, insn)
  end

  # Tags each by-name line with the register it receives and records the row for that tag. `insn`, when
  # given, restricts the tag to a register that insn names.
  def tag_dispatch_lines(code, irep, site, offset, insn)
    code.each_line.map do |l|
      recv = l[DISPATCH_RECV, 1]
      next l unless recv&.match?(/\Ar\d+\z/) && tag_eligible?(l)

      reg = recv[1..]
      walk = reg.to_i - offset
      next l if walk.negative? || (insn && !insn.regs.include?(reg))

      ROWS[[irep.label, site, reg, walk.to_s]] = { irep: irep, reg: reg, walk: walk.to_s }
      l.sub(/\n\z/, " /*SO:#{irep.label}:#{site}:#{reg}:#{walk}*/\n")
    end.join
  end

  def tag_eligible?(line)
    line.end_with?("\n") && !line.lstrip.start_with?('//') && !line.include?('/*SR:') && !line.include?('/*SO:') &&
      !line.rstrip.end_with?('\\')
  end

  module Writer
    module_function

    def write(path)
      File.open(path, 'w') do |f|
        SiteOriginTable::ROWS.each do |(label, index, reg, walk), row|
          status, category, definition = origin(row[:irep], index, walk)
          f.puts [label, index, reg, status, category, definition, walk].join("\t")
        end
      end
    end

    # The dataflow's state cap (DATAFLOW_MAX_STATES) only bounds work; a large method exceeds it without any
    # unmodelled state, so the table raises it. Refusals left are the sound ones (handlers, unmodelled ops).
    STATE_CAP = 200_000

    def origin(irep, index, reg)
      defs = BytecodeIR.reaching_definitions(irep, index, reg, max_states: STATE_CAP)
      return ['refused', '-', '-'] unless defs
      return ['none', '-', '-'] if defs.empty?
      return ['ambiguous', '-', '-'] if defs.size > 1

      definition = defs.first
      where = definition.entry? ? 'entry' : "#{irep.instructions[definition.index].op}@#{definition.index}"
      ['exact', category(irep, definition), where]
    end

    def category(irep, definition)
      return entry_category(irep, definition.reg) if definition.entry?

      insn = irep.instructions[definition.index]
      return 'self' if insn.op == 'LOADSELF'

      text = SiteOriginTable::INSN_TEXT[[irep.label, definition.index]]
      # The read's own opcode decides these: their emitted text can be a multi-line
      # block whose last assignment is a temporary (`r5 = r5_tmp;`), which says nothing.
      case insn.op
      when 'GETCONST', 'GETMCNST' then return 'constant'
      when 'GETIV' then return text&.match?(/_ivars\*\)DATA_PTR/) ? 'embedded_ivar' : 'ivar_read'
      end

      rhs = text ? assignment_rhs(text, definition.reg) : []
      if rhs.any?
        # Producers inside one instruction (a fast path and its dispatch): agreeing ones give the origin, else it is open.
        producers = rhs.map { |value| SiteCensus.origin_of([], 0, value, nil, [], 0) }.uniq
        return producers.size == 1 ? producers.first : 'unknown'
      end

      opcode_category(insn.op)
    end

    # The method's own value on entry: self, a positional parameter, or the nil every local starts as.
    def entry_category(irep, reg)
      return 'self' if reg == '0'

      fields = irep.enter ? irep.enter.enter_fields : []
      positional = fields.first(SiteOriginTable::POSITIONAL_FIELDS).sum
      reg.to_i.between?(1, positional) ? 'parameter' : 'literal_or_fresh'
    end

    # The right-hand sides of every assignment to +reg+ in +text+.
    def assignment_rhs(text, reg)
      text.each_line.filter_map do |l|
        l.sub(SiteOriginTable::TAG, '')[/^\s*(?:mrb_value )?r#{reg} = (.*);\s*$/, 1]
      end
    end

    # Used only when no emitted text exists for the defining instruction: a send's result is not
    # provable without its text, and other writes are 'other' as the text walk called them.
    def opcode_category(op)
      case op
      when 'GETIV' then 'ivar_read'
      when 'GETIDX', 'GETIDX0', 'AREF' then 'indexed_result'
      when 'GETUPVAR' then 'captured_upvar'
      when 'LOADNIL', 'LOADTRUE', 'LOADFALSE', 'LOADL', 'ARRAY', 'ARRAY2', 'HASH', 'STRING', /\ALOADI/
        'literal_or_fresh'
      when 'SEND', 'SEND0', 'SENDB', 'SSEND', 'SSEND0', 'SSENDB', 'SUPER', 'BLKCALL' then 'unknown'
      else 'other'
      end
    end
  end
end

CodeGen.prepend(SiteOriginTable)
at_exit { SiteOriginTable::Writer.write(ENV['BC2CPP_SITE_ORIGIN_TABLE']) if ENV['BC2CPP_SITE_ORIGIN_TABLE'] }
