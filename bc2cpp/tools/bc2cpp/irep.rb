# frozen_string_literal: true

# Steps 1-5: run mrbc, parse its C and -v dumps into Ireps, and merge them.

# MRBC is passed explicitly by every real caller (e.g. mrbgem.rake passes
# `spec.build.mrbcfile`): the right mrbc depends on which build invokes this.
MRBC = ENV['MRBC'] || 'mrbc'

Irep = Struct.new(:label, :nlocals, :nregs, :pool, :syms, :reps, :lv, :instructions, :file,
                   :catch_handlers, keyword_init: true)
Insn = Struct.new(:lineno, :addr, :op, :args, :raw, keyword_init: true)
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
MethodDef = Struct.new(:name, :owner, :irep, :visibility, :kind, keyword_init: true)

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
