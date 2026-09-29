# frozen_string_literal: true

# Steps 1-5: run mrbc, parse its C and -v dumps into Ireps, and merge them.

# MRBC is passed explicitly by every real caller (e.g. mrbgem.rake passes
# `spec.build.mrbcfile`): the right mrbc depends on which build invokes this.
require_relative 'operand_schema'

MRBC = ENV['MRBC'] || 'mrbc'

Irep = Struct.new(:label, :nlocals, :nregs, :pool, :syms, :reps, :lv, :instructions, :file,
                   :catch_handlers, keyword_init: true) do
  # Instruction whose address is +addr+, as an index into #instructions.
  def index_of_addr(addr)
    @addr_index ||= instructions.each_with_index.to_h { |insn, index| [insn.addr, index] }
    @addr_index[addr]
  end

  # Nearest instruction at or before index +from+ whose first register operand
  # is +reg+ (digits), i.e. the write a register read at from + 1 sees.
  def last_writer(from, reg)
    index = last_writer_index(from, reg)
    index && instructions[index]
  end

  def last_writer_index(from, reg)
    reg = reg.to_s
    [from, instructions.length - 1].min.downto(0) do |i|
      return i if instructions[i].reg == reg
    end
    nil
  end

  # The first non-MOVE instruction writing +reg+ at or before index +from+,
  # following MOVE copies to their source register. Nil when the register is
  # never written or a MOVE has no source.
  def source_writer(from, reg)
    loop do
      index = last_writer_index(from, reg)
      return nil unless index

      insn = instructions[index]
      return insn unless insn.op == 'MOVE'

      reg = insn.regs[1]
      return nil unless reg

      from = index - 1
    end
  end

  # Instructions whose address lies in +range+ (`b...e`, `(t + 1)..`).
  def instructions_at(range)
    instructions.select { |insn| range.cover?(insn.addr) }
  end
end
Insn = Struct.new(:lineno, :addr, :op, :args, :raw, keyword_init: true) do
  # Operand text without mrbc's trailing `; R5:name` local-variable comment,
  # which would otherwise be mistaken for the last operand.
  def operands
    args.sub(/\s*;.*\z/m, '')
  end

  # First register operand as digits ("R6" -> "6"), nil when the instruction
  # has none. Registers are Strings because callers key maps and compare
  # against `dest_reg.to_s`.
  def reg
    return @reg if defined?(@reg)

    @reg = args[/\AR(\d+)/, 1]
  end

  # Every register operand in order, excluding those named only in the
  # trailing comment.
  def regs
    @regs ||= operands.scan(/R(\d+)/).flatten.freeze
  end

  SYM_RE = /:([\w+\-*\/<>=!?\[\]&|^~%@]+)/

  # First `:symbol` operand (method or LOADSYM name), operators included.
  def sym
    return @sym if defined?(@sym)

    @sym = operands[SYM_RE, 1]
  end

  # `@name` operand of GETIV/SETIV, without the sigil.
  def ivar
    return @ivar if defined?(@ivar)

    @ivar = operands[/@(\w+)/, 1]
  end

  # Positional argument count of a SEND-family op (`n=3`, `n=3|nk=1`); nil
  # for a splat (`n=*`) or when absent.
  def argc
    return @argc if defined?(@argc)

    @argc = operands[/n=(\d+)/, 1]&.to_i
  end

  # The colon-separated ENTER operand fields as Integers
  # (req:opt:rest:post:key:kdict:block plus the trailing flags word).
  def enter_fields
    @enter_fields ||= operands.split(':').map { |f| f[/\d+/].to_i }.freeze
  end

  # `n=` and `nk=` of a SEND-family op as printed by mrbc: digits, `*` for a
  # splat, nil when absent. SEND0/SSEND0 print neither (n is 0).
  def n_spec
    argc_match&.[](1)
  end

  def nk_spec
    argc_match&.[](2)
  end

  # The matched `n=3|nk=1` text, for diagnostics.
  def argc_text
    argc_match&.[](0)
  end

  def argc_match
    return @argc_match if defined?(@argc_match)

    @argc_match = operands.match(/n=(\d+|\*)(?:\|nk=(\d+|\*))?/)
  end
  private :argc_match

  # An Insn for code the compiler synthesizes (no disassembly line behind it).
  def self.synthetic(op, args)
    new(lineno: 0, addr: 0, op: op, args: args, raw: "#{op} #{args}")
  end

  # First `:token` operand verbatim (globals such as `:$stdout` included, which
  # #sym's operator character class excludes).
  def sym_token
    return @sym_token if defined?(@sym_token)

    @sym_token = operands[/:(\S+)/, 1]
  end

  # Name after the `::` of GETMCNST/SETMCNST (`R6 (R6)::Foo`).
  def mcnst_name
    return @mcnst_name if defined?(@mcnst_name)

    @mcnst_name = operands[/::(\S+)/, 1]
  end

  # Register named in parentheses, the second operand of the binary ops
  # (`R1 (R2)`).
  def paren_reg
    return @paren_reg if defined?(@paren_reg)

    @paren_reg = operands[/\(R(\d+)\)/, 1]
  end

  # Text of the first parenthesized operand: the literal of LOADI/LOADL forms
  # (`R1 (5)`), the level of BLKPUSH.
  def paren_value
    return @paren_value if defined?(@paren_value)

    @paren_value = operands[/\(([^)]+)\)/, 1]
  end

  # Unsigned integer right after the destination register (`R1 3`), the size
  # of ARRAY/HASH/STRCAT-style ops and the target of conditional jumps.
  def uint_operand
    return @uint_operand if defined?(@uint_operand)

    @uint_operand = operands[/\AR\d+\s+(\d+)/, 1]&.to_i
  end

  # Signed literal right after the destination register (`R1 -5`).
  def imm_operand
    return @imm_operand if defined?(@imm_operand)

    @imm_operand = operands[/\AR\d+\s+(-?\d+)/, 1]
  end

  # First register operand spelled as in the disassembly (`R6`).
  def upvar_ref
    return nil unless %w[GETUPVAR SETUPVAR].include?(op)

    a = tokens
    a.length == 3 ? [a[1].to_i, a[2].to_i] : nil
  end

  def operand_kinds
    OperandSchema.parse(op, args).map(&:kind)
  end

  def reg_operand
    typed_ops = OperandSchema.parse(op, args)
    typed_ops.find { |operand| operand.kind == :reg }&.value&.to_s
  end

  def reg_token
    reg && "R#{reg}"
  end

  # Whether register +number+ is named by any operand.
  def mentions_reg?(number)
    regs.include?(number.to_s)
  end

  # `n=*` with no keyword part: the call passes a single splatted array.
  def pure_splat?
    n_spec == '*' && nk_spec.nil?
  end

  # A fixed positional-argument count with no keyword part (`n=3`).
  def plain_fixed_argc?
    n_spec && n_spec != '*' && nk_spec.nil?
  end

  # ARGARY's `m1:rest:post:kd` field group as Integers, nil when absent.
  def argary_spec
    operands[/\s(\d+:\d+:\d+:\d+)\s*\(/, 1]&.split(':')&.map(&:to_i)
  end

  # `R1 :name I[2]` (DEF/SDEF/TDEF): the child irep index of a definition
  # whose operands are exactly a register, a symbol and a child, else nil.
  def def_child_index
    tokens.length == 3 && reg && sym_token && block_index
  end

  # A copy with every register operand moved up by +offset+, for compiling a
  # block body inside its parent's register file.
  def shift_regs(offset)
    Insn.new(lineno: lineno, addr: addr, op: op, raw: raw,
             args: args.gsub(/R(\d+)/) { "R#{Regexp.last_match(1).to_i + offset}" })
  end

  # `R1 R2 3`: [source register, literal] as Strings, for the ops that read a
  # register and carry a literal index or count (AREF, ARRAY, ADDI, SUBI).
  def src_and_literal
    m = operands.match(/\AR\d+\s+R(\d+)\s+(-?\d+)/)
    m && [m[1], m[2]]
  end

  # `$name` operand of GETGV/SETGV.
  def global_name
    return @global_name if defined?(@global_name)

    @global_name = operands[/(\$\S+)/, 1]
  end

  # Whitespace-separated operands, comment excluded.
  def tokens
    @tokens ||= operands.split(/\s+/).freeze
  end

  def no_operands?
    operands.strip.empty?
  end

  # Index into the irep's child `reps` (`I[2]` of BLOCK/LAMBDA/METHOD).
  def block_index
    return @block_index if defined?(@block_index)

    @block_index = operands[/I\[(\d+)\]/, 1]&.to_i
  end

  # Index into the irep's literal pool (`L[3]`).
  def pool_index
    return @pool_index if defined?(@pool_index)

    @pool_index = operands[/L\[(\d+)\]/, 1]&.to_i
  end

  # Address operand of an unconditional JMP/JMPUW (0 when absent).
  def jmp_addr
    operands.strip[/\d+/].to_i
  end

  # Constant name read or written by GETCONST/SETCONST/GETMCNST/SETMCNST.
  def const_name
    case op
    when 'SETCONST' then tokens[0]
    when 'GETCONST' then tokens[1]
    when 'GETMCNST', 'SETMCNST' then operands[/::(\S+)/, 1]
    end
  end

  # Target address of any branch op (JMP/JMPUW/JMPIF/JMPNOT/JMPNIL), nil for
  # every other op. JMPUW has JMP's operand shape.
  def branch_target
    case op
    when 'JMP', 'JMPUW' then jmp_addr
    when 'JMPIF', 'JMPNOT', 'JMPNIL' then uint_operand.to_i
    end
  end

  # Absolute target address of a JMP/JMPIF/JMPNOT/JMPNIL, nil for anything else.
  def jump_target
    return nil unless %w[JMP JMPIF JMPNOT JMPNIL].include?(op)

    token = operands.split.last
    token&.match?(/\A\d+\z/) ? token.to_i : nil
  end
end
# One entry of an irep's catch handler table (mruby/irep.h
# `struct mrb_irep_catch_handler`), from mrbc -v's "catch type:" header line.
# `type` is "rescue" or "ensure"; the addresses are Insn#addr byte offsets.
CatchHandler = Struct.new(:type, :begin_addr, :end_addr, :target, keyword_init: true)
# `kind`: nil for ordinary defs and most synthetic (irep: nil) entries. Set to
# :ivar_accessor only where the native body is known to be a plain
# attr_reader/writer (see build_registry), which lets IVAR_ACCESSOR_DEVIRT
# inline mrb_iv_get/mrb_iv_set. Other synthetic defs (Struct members, which are
# not ivars; module_function copies; NATIVE_SRCS names) must stay untagged:
# tagging them would be a silent wrong-value bug, not a missed optimization.
MethodDef = Struct.new(:name, :owner, :irep, :visibility, :kind, :copy_irep, :copy_owner, keyword_init: true)

# ---------------------------------------------------------------------------
# Step 1: run mrbc's two debug dumps. mrbc compiles several files on one
# command line as one program (with class reopening across files), which is
# what makes a whole-gem closed world possible.
# ---------------------------------------------------------------------------
def run_mrbc(src_paths, symbol, out_dir)
  src_paths = Array(src_paths)
  c_dump = File.join(out_dir, "#{symbol}_dump.c")
  disasm_txt = File.join(out_dir, "#{symbol}_disasm.txt")

  system(MRBC, '-B', symbol, '-S', '-o', c_dump, *src_paths, exception: true)
  # Source has non-ASCII comments/literals; don't trust the locale default.
  disasm = IO.popen([MRBC, '-v', '-o', File.join(out_dir, "#{symbol}.mrb"), *src_paths],
                     external_encoding: 'UTF-8', &:read)
  raise "mrbc -v failed" unless $?.success?
  File.write(disasm_txt, disasm)

  [File.read(c_dump, encoding: 'UTF-8'), disasm]
end

# ---------------------------------------------------------------------------
# Step 2: parse the C dump into a label -> Irep map (no tree order yet).
# ---------------------------------------------------------------------------
def parse_c_dump(c_src, symbol)
  ireps = {}

  # Pool entries are not all strings (IREP_TT_FLOAT, IREP_TT_INT64, ...). Every
  # entry must be counted in order regardless of type, or a later STRING's L[k]
  # index points at the wrong slot.
  pools = {}
  c_src.scan(/static const mrb_irep_pool #{Regexp.escape(symbol)}_pool_(\d+)\[\d+\] = \{(.*?)\n\};/m) do |label, body|
    entries = body.scan(/\{IREP_TT_(\w+)(?:\|[^,]+)?,\s*\{(.*?)\}\},/m).map do |tag, val|
      if tag == 'SSTR' || tag == 'STR'
        str = val[/"((?:[^"\\]|\\.)*)"/, 1] || ''
        unescape_c_string(str)
      else
        { type: tag.downcase.to_sym, raw: val.strip } # not string-typed -- positional placeholder only.
      end
    end
    pools[label] = entries
  end

  # Symbol arrays: mrb_DEFINE_SYMS_VAR(SYM_syms_N, count, (MRB_SYM(name), MRB_IVSYM(name), ...), const);
  syms = {}
  c_src.scan(/mrb_DEFINE_SYMS_VAR\(#{Regexp.escape(symbol)}_syms_(\d+), \d+, \((.*?)\), const\);/m) do |label, body|
    names = body.scan(/MRB_I?VSYM\((\w+)\)/).map { |m| m[0] }
    syms[label] = names
  end

  # Local-variable-name arrays: mrb_DEFINE_SYMS_VAR(SYM_lv_N, count, (MRB_SYM(a), MRB_SYM(b), 0,), const);
  lvs = {}
  c_src.scan(/mrb_DEFINE_SYMS_VAR\(#{Regexp.escape(symbol)}_lv_(\d+), \d+, \((.*?)\), const\);/m) do |label, body|
    names = body.split(',').map(&:strip).reject(&:empty?).map { |t| t == '0' ? nil : t[/MRB_SYM\((\w+)\)/, 1] }
    lvs[label] = names
  end

  # reps arrays: static const mrb_irep *const SYM_reps_N[k] = { &SYM_irep_A, &SYM_irep_B, ... };
  # (`*const` since patches/mruby-cdump-const-reps.patch; the bare form is still accepted.)
  reps = {}
  c_src.scan(/static const mrb_irep \*(?:const )?#{Regexp.escape(symbol)}_reps_(\d+)\[\d+\] = \{(.*?)\n\};/m) do |label, body|
    children = body.scan(/&#{Regexp.escape(symbol)}_irep_(\d+)/).map { |m| m[0] }
    reps[label] = children
  end

  # irep structs themselves: static const mrb_irep SYM_irep_N = { nlocals,nregs,clen, ... , ilen,plen,slen,rlen,... };
  c_src.scan(/static const mrb_irep #{Regexp.escape(symbol)}_irep_(\d+) = \{\s*\n\s*(\d+),(\d+),(\d+),\s*\n(.*?)\n\};/m) do |label, nlocals, nregs, _clen, rest|
    ireps[label] = Irep.new(
      label: label,
      nlocals: nlocals.to_i,
      nregs: nregs.to_i,
      pool: pools[label] || [],
      syms: syms[label] || [],
      reps: reps[label] || [],
      lv: lvs[label] || [],
      instructions: []
    )
  end

  # The root is whichever irep label is never referenced as someone else's child.
  all_children = reps.values.flatten.to_set
  root_label = ireps.keys.find { |l| !all_children.include?(l) }
  raise 'could not find root irep (ambiguous or malformed C dump)' unless root_label

  [ireps, root_label]
end

def unescape_c_string(s)
  s.gsub(/\\x([0-9a-fA-F]{2})/) { [Regexp.last_match(1)].pack('H2') }
   .gsub('\\\\', '\\').gsub('\\"', '"').gsub('\\n', "\n").gsub('\\t', "\t")
end

# ---------------------------------------------------------------------------
# Step 3: DFS pre-order over the C-dump tree (root, then each rep in order,
# recursively before the next sibling) -- matches mrbc -v's own block order.
# ---------------------------------------------------------------------------
def dfs_order(ireps, root_label)
  order = []
  visit = lambda do |label|
    order << label
    ireps.fetch(label).reps.each { |child| visit.call(child) }
  end
  visit.call(root_label)
  order
end

# ---------------------------------------------------------------------------
# Step 4: parse the -v disassembly into per-irep instruction blocks, in the
# same order they appear (verified to match dfs_order above).
# ---------------------------------------------------------------------------
def parse_disasm_blocks(text)
  blocks = []
  # Parallel to `blocks`: each irep's `file:` path, needed by
  # Annotations.extract to find a magic comment's source line.
  block_files = []
  # Parallel to `blocks`: the "catch type: ..." headers seen before each
  # block (see CatchHandler); consumed by RESCUE_SUPPORT.
  block_catches = []
  current = nil
  text.each_line do |line|
    if line =~ /^irep 0x[0-9a-f]+ /
      blocks << current if current
      current = []
      block_files << nil # overwritten by this block's own `file:` line below, if any.
      block_catches << []
      next
    end
    next unless current
    if line =~ /^file: (.+)$/
      block_files[-1] = Regexp.last_match(1)
      next
    end
    if line =~ /^catch type: (\w+)\s+begin: (\d+)\s+end: (\d+)\s+target: (\d+)/
      type, b, e, t = Regexp.last_match.captures
      block_catches[-1] << CatchHandler.new(type: type.to_sym, begin_addr: b.to_i, end_addr: e.to_i, target: t.to_i)
      next
    end
    if line =~ /^\s*(\d+)\s+(\d+)\s+([A-Z][A-Z0-9_]*)\s*(.*)$/
      lineno, addr, op, rest = Regexp.last_match.captures
      current << Insn.new(lineno: lineno.to_i, addr: addr.to_i, op: op, args: rest.strip, raw: line.rstrip)
    end
  end
  blocks << current if current
  [blocks, block_files, block_catches]
end

# ---------------------------------------------------------------------------
# Step 5: merge -- zip DFS label order against disassembly block order, and
# attach each block's instructions onto its Irep.
# ---------------------------------------------------------------------------
def merge!(ireps, order, blocks, block_files = [], block_catches = [])
  raise "irep count mismatch: #{order.size} (C dump) vs #{blocks.size} (disasm)" unless order.size == blocks.size

  order.each_with_index do |label, i|
    irep = ireps.fetch(label)
    irep.instructions = blocks[i]
    irep.file = block_files[i]
    irep.catch_handlers = block_catches[i] || []
  end
end
