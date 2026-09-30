# frozen_string_literal: true

# Run mrbc and build the whole Irep tree from its RITE binary (ADR 0249, 0251).

# MRBC is passed explicitly by every real caller (e.g. mrbgem.rake passes
# `spec.build.mrbcfile`): the right mrbc depends on which build invokes this.
require_relative 'insn_operands'
require_relative 'insn_decoder'
require_relative 'irep_scans'

MRBC = ENV['MRBC'] || 'mrbc'

Irep = Struct.new(:label, :nlocals, :nregs, :pool, :syms, :reps, :lv, :instructions, :file,
                   :catch_handlers, keyword_init: true) do
  include IrepScans

  # label => Irep of the whole tree this irep belongs to (set by load_ireps);
  # an ivar, not a member, so Struct#==/hash/inspect never walk the cycle.
  attr_accessor :tree

  # Instruction whose address is +addr+, as an index into #instructions.
  def index_of_addr(addr)
    @addr_index ||= instructions.each_with_index.to_h { |insn, index| [insn.addr, index] }
    @addr_index[addr]
  end

  # Yields `(insn, index)` for each instruction whose op is one of +ops+.
  def each_with_op(*ops)
    # Per-op index lists (built once; instructions never change after loading)
    # merged back into program order.
    @op_indices ||= instructions.each_with_index.group_by { |insn, _| insn.op }
                                .transform_values { |pairs| pairs.map(&:last).freeze }.freeze
    indices = ops.uniq.flat_map { |op| @op_indices.fetch(op, []) }
    indices.sort! if ops.uniq.size > 1
    indices.each { |index| yield instructions[index], index }
  end

  # The ENTER instruction (nil for a bodyless zero-argument method).
  def enter
    return @enter if defined?(@enter)

    @enter = instructions.find { |insn| insn.op == 'ENTER' }
  end

  def enter_index
    return @enter_index if defined?(@enter_index)

    @enter_index = instructions.index { |insn| insn.op == 'ENTER' }
  end

  # mrbc -v prints EXT1/EXT2/EXT3 as their own lines widening the next
  # instruction; this is the index of the nearest real opcode at or before
  # +from+, or -1.
  EXT_OPS = %w[EXT1 EXT2 EXT3].freeze

  def previous_real_index(from)
    index = from
    index -= 1 while index >= 0 && EXT_OPS.include?(instructions[index]&.op)
    index
  end

  # Nearest instruction at or before index +from+ whose first register operand
  # is +reg+ (digits), i.e. the write a register read at from + 1 sees.
  def last_writer(from, reg)
    index = last_writer_index(from, reg)
    index && instructions[index]
  end

  def last_writer_index(from, reg)
    previous_lead_index(reg.to_s, from)
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
# One decoded instruction. `args` is the disassembly's operand text, kept only
# for diagnostics and comments; every pass reads the typed operands through
# InsnOperands (see OperandSchema).
Insn = Struct.new(:lineno, :addr, :op, :args, :raw, keyword_init: true) do
  include InsnOperands

  # An Insn for code the compiler synthesizes (no disassembly line behind it).
  def self.synthetic(op, args)
    new(lineno: 0, addr: 0, op: op, args: args, raw: "#{op} #{args}")
  end
end
# One entry of an irep's catch handler table (mruby/irep.h
# `struct mrb_irep_catch_handler`) from the RITE binary. `type` is :rescue or
# :ensure; the addresses are Insn#addr byte offsets.
CatchHandler = Struct.new(:type, :begin_addr, :end_addr, :target, keyword_init: true)
# `kind`: nil for ordinary defs and most synthetic (irep: nil) entries. Set to
# :ivar_accessor only where the native body is known to be a plain
# attr_reader/writer (see build_registry), which lets IVAR_ACCESSOR_DEVIRT
# inline mrb_iv_get/mrb_iv_set. Other synthetic defs (Struct members, which are
# not ivars; module_function copies; NATIVE_SRCS names) must stay untagged:
# tagging them would be a silent wrong-value bug, not a missed optimization.
# `core`: the body comes from mruby's own Ruby (CoreDefs, set by the driver).
# `installer`: :define_method for a `define_method(:x) { }` body (DefineMethodSites), else nil.
MethodDef = Struct.new(:name, :owner, :irep, :visibility, :kind, :copy_irep, :copy_owner, :core, :installer,
                       keyword_init: true)

# ---------------------------------------------------------------------------
# mrbc compiles several files on one command line as one program (with class
# reopening across files), which is what makes a whole-gem closed world
# possible. The RITE binary (`-g`) carries everything bc2cpp needs: the irep
# tree, iseq bytes, pool, symbols, local-variable names, file and catch table.
# ---------------------------------------------------------------------------
RiteImage = Struct.new(:bytes)

def run_mrbc(src_paths, symbol, out_dir)
  mrb_path = File.join(out_dir, "#{symbol}.mrb")
  system(MRBC, '-g', '-o', mrb_path, *Array(src_paths), exception: true)
  RiteImage.new(File.binread(mrb_path))
end

# [ireps (label => Irep), root_label] for +src_paths+ compiled by mrbc.
def compile_ireps(src_paths, symbol, out_dir)
  load_ireps(run_mrbc(src_paths, symbol, out_dir))
end

CATCH_TYPES = { 0 => :rescue, 1 => :ensure }.freeze

# Labels are the numbers `mrbc -B -S` gave each irep (`<sym>_irep_<n>`), and
# generated C++ names embed them, so the counter must stay bug-for-bug: root 0;
# an irep with k children reserves k more numbers per child before descending
# (src/cdump.c cdump_irep_struct), starting from 1.
def assign_irep_labels(rites, pos, label, counter, labels, children)
  labels[pos] = label.to_s
  first = counter[0]
  rlen = rites[pos].rlen
  nxt = pos + 1
  rlen.times do |i|
    counter[0] += rlen
    children[pos] << nxt
    nxt = assign_irep_labels(rites, nxt, first + i, counter, labels, children)
  end
  nxt
end

# A pool entry in the shape passes consume: a String for a string literal,
# else `{ type:, raw: }` with `raw` the C initializer text `mrbc -S` printed.
def irep_pool_entry(entry)
  case entry.kind
  when :str then pool_string(entry.value)
  when :int32 then { type: :int32, raw: ".i32=#{entry.value}" }
  when :int64
    # mrbc -S narrows an int64 that fits into int32.
    if entry.value.between?(-0x8000_0000, 0x7fff_ffff)
      { type: :int32, raw: ".i32=#{entry.value}" }
    else
      { type: :int64, raw: ".i64=#{entry.value}" }
    end
  when :float then { type: :float, raw: ".f=#{c_double(entry.value)}" }
  when :bigint
    bytes = [entry.value.bytesize - 1].pack('C') + entry.value
    # `base` is signed (negative = negative literal) and `digits` are ASCII in
    # that base, exactly what vm.c's OP_LOADL hands to mrb_bint_new_str.
    { type: :bigint, raw: "\"#{bytes.unpack('C*').map { |b| format('\\x%02x', b) }.join}\"",
      base: entry.value.unpack1('c'), digits: entry.value.byteslice(1..) }
  else raise "bc2cpp: unknown pool entry kind #{entry.kind}"
  end
end

# ASCII text stays UTF-8; anything else is raw bytes, as the string
# consumers (c_string_literal) already expect.
def pool_string(bytes)
  bytes = bytes.dup
  bytes.force_encoding(bytes.ascii_only? ? Encoding::UTF_8 : Encoding::BINARY)
end

def c_double(value)
  return value.nan? ? 'nan' : (value.positive? ? 'inf' : '-inf') unless value.finite?

  format('%.17g', value)
end

def symbol_name(bytes)
  bytes && bytes.dup.force_encoding(Encoding::UTF_8)
end

# The whole Irep tree of a RITE image: [ireps (label => Irep), root_label].
def load_ireps(image)
  rites = RiteBinary.parse(image.bytes)
  labels = Array.new(rites.length)
  children = Array.new(rites.length) { [] }
  assign_irep_labels(rites, 0, 0, [1], labels, children)

  # Children before their parent (the order `mrbc -S` printed them in): passes
  # iterate the label => Irep hash, so its order shows in generated output.
  post_order = []
  emit = lambda do |pos|
    children[pos].each { |child| emit.call(child) }
    post_order << pos
  end
  emit.call(0)

  ireps = {}
  post_order.each do |pos|
    rite = rites[pos]
    insns, file = InsnDecoder.decode(rite)
    ireps[labels[pos]] = Irep.new(
      label: labels[pos], nlocals: rite.nlocals, nregs: rite.nregs,
      pool: rite.pool.map { |entry| irep_pool_entry(entry) },
      syms: rite.syms.map { |name| symbol_name(name) },
      reps: children[pos].map { |child| labels[child] },
      lv: (rite.lv || []).map { |name| symbol_name(name) },
      instructions: insns, file: file,
      catch_handlers: rite.catch_handlers.map do |h|
        type = CATCH_TYPES.fetch(h.type) { raise "bc2cpp: unknown catch handler type #{h.type}" }
        CatchHandler.new(type: type, begin_addr: h.begin_addr, end_addr: h.end_addr, target: h.target)
      end
    )
  end
  ireps.each_value { |irep| irep.tree = ireps }
  [ireps, labels.first]
end

# DFS pre-order of the tree (root, then each rep in order, recursively before
# the next sibling); the order the RITE binary lists the ireps in.
def dfs_order(ireps, root_label)
  order = []
  visit = lambda do |label|
    order << label
    ireps.fetch(label).reps.each { |child| visit.call(child) }
  end
  visit.call(root_label)
  order
end

# Unescapes a C string literal body read from native sources (mrb_define_*
# names); not used on mrbc output.
def unescape_c_string(s)
  s.gsub(/\\x([0-9a-fA-F]{2})/) { [Regexp.last_match(1)].pack('H2') }
   .gsub('\\\\', '\\').gsub('\\"', '"').gsub('\\n', "\n").gsub('\\t', "\t")
end
