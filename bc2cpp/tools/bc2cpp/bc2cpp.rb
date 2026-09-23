#!/usr/bin/env ruby
# frozen_string_literal: true

# A small mruby bytecode -> C++ AOT compiler (docs/adr/0139).
#
# Compiles method-body IREPs only; top-level and class-body IREPs stay on the
# interpreter (mrb_load_irep), which defines the classes and installs the
# compiled bodies via mrb_define_method. A method using an unsupported opcode
# or argument shape gets a loud `#error` marker, never a silently wrong
# translation, and keeps running interpreted.
#
# The core analysis is closed-world: a method name defined by exactly one class
# anywhere in the program is provably monomorphic, so its call sites compile to
# a direct C++ call instead of mrb_funcall; names with several definitions keep
# dynamic dispatch.
#
# Input comes from mrbc's two debug dumps of the same sources: `-v` (opcode
# mnemonics, DFS pre-order blocks) and `-B -S` (the C irep structs, with exact
# pool/symbol/lv arrays and reps[] parent/child pointers). Neither alone is
# enough, so the C dump's tree is walked in DFS pre-order and zipped against
# the disassembly's block sequence.

require 'shellwords'
require 'set'

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

  # reps arrays: static const mrb_irep *SYM_reps_N[k] = { &SYM_irep_A, &SYM_irep_B, ... };
  reps = {}
  c_src.scan(/static const mrb_irep \*#{Regexp.escape(symbol)}_reps_(\d+)\[\d+\] = \{(.*?)\n\};/m) do |label, body|
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

# STRUCT_MEMBERS_ANALYSIS: `Const = Struct.new(:a, :b, ...)` (with or without
# a block, keyword_init or not) stores member i at array index i: mruby-struct
# struct.c writes mrb_ary_set(self, i, ...) for the i-th __members__ entry, and
# MRB_TT_STRUCT is RArray-backed (value.h), so RARRAY_PTR/LEN work directly.
#
# Returns `[owner, [member names in declared order]]` or nil when anything is
# not confidently recognized (anonymous Struct, receiver not a bare `Struct`
# GETCONST, LOADSYM scan count mismatch). A miss only means GETIDX keeps
# dynamic dispatch for that owner.
#
# Two argument shapes: n <= CALL_MAXARGS members in consecutive LOADSYM
# registers, or more (`n=*`) packed into one ARRAY first.
def detect_struct_new_members(irep, idx, insn, namespace)
  name = insn.args[/:([\w+\-*\/<>=!?\[\]&|^~%@]+)/, 1]
  return nil unless name == 'new'

  d = insn.args[/^R(\d+)/, 1]
  return nil unless d

  struct_recv = false
  (idx - 1).downto(0) do |i|
    prev = irep.instructions[i]
    pd = prev.args[/^R(\d+)/, 1]
    next unless pd == d

    struct_recv = prev.op == 'GETCONST' && prev.args[/^R\d+\s+(\S+)/, 1] == 'Struct'
    break
  end
  return nil unless struct_recv

  # The Struct's name comes from a SETCONST right after the call on the same
  # register; an unnamed Struct.new is left unrecognized.
  next_insn = irep.instructions[idx + 1]
  struct_name = if next_insn && next_insn.op == 'SETCONST'
                  sc_name, sc_reg = next_insn.args.split(/\s+/, 2)
                  sc_name if sc_reg == "R#{d}"
                end
  return nil unless struct_name

  owner = namespace ? "#{namespace}::#{struct_name}" : struct_name

  scan_from = idx - 1
  if %w[SENDB SSENDB].include?(insn.op)
    return nil unless irep.instructions[scan_from]&.op == 'BLOCK'

    scan_from -= 1
  end

  # `keyword_init:` is Struct.new's only keyword; skip its (key, value) pair.
  nk = insn.args[/nk=(\d+)/, 1].to_i
  scan_from -= 2 * nk
  return nil if scan_from < 0 && nk.positive?

  pos = insn.args[/n=(\*|\d+)/, 1]
  return nil unless pos

  if pos == '*'
    array_insn = scan_from >= 0 ? irep.instructions[scan_from] : nil
    return nil unless array_insn&.op == 'ARRAY'

    n = array_insn.args[/^R\d+\s+(\d+)/, 1]&.to_i
    return nil unless n

    scan_from -= 1
  else
    n = pos.to_i
    return nil if n.zero?
  end

  members = []
  i = scan_from
  while i >= 0 && members.size < n
    prev = irep.instructions[i]
    break unless prev.op == 'LOADSYM'

    members.unshift(prev.args[/:(\S+)/, 1])
    i -= 1
  end
  return nil unless members.size == n && members.all?

  [owner, members]
end

# ---------------------------------------------------------------------------
# Step 6: whole-program class/method registry, walking the tree from the
# root: CLASS/EXEC pairs define classes and recurse into their class-body
# irep; TDEF (anywhere) defines one method, owned by the innermost class
# being walked (or "Object" for a top-level TDEF).
# ---------------------------------------------------------------------------
def build_registry(ireps, root_label)
  registry = Hash.new { |h, k| h[k] = [] }
  # SUPER_SUPPORT: class name -> declared superclass name, :none (no explicit
  # superclass; OP_SUPER searches from one level above the current class either
  # way), or absent (unrecognized superclass expression, never guessed). Only
  # CLASS populates it; modules have no superclass.
  superclass_of = {}
  # ANCESTOR_MIXINS_SUPPORT: class name -> modules its own body `include`s, in
  # source order, plus the parallel `prepend` table. `super` soundness needs to
  # know that no included module sits between the caller and its superclass
  # (mruby's method search would hit the module's method first). Only the
  # self-implicit `include M` / `prepend M` form (SSEND R(self) :include n=1
  # after a GETCONST/GETMCNST) is recognized; anything else lands in
  # `unknown_mixins` so `super` in that owner declines. Prepended modules sit
  # above the class, so they never intervene and are not consulted by that check.
  included_modules = {}
  prepended_modules = {}
  unknown_mixins = Set.new
  # CONST_CONTAINER_SUPPORT: qualified constant name -> 'Array'/'Hash'/'Range'
  # when every SETCONST of that name writes a proven literal_container_class
  # value. Disagreeing sites poison the name to nil; poisoned entries are
  # removed before returning. A literal's shape is a one-shot syntactic fact,
  # so no fixed point is needed (unlike ClassLayout).
  container_constants = {}
  # STRUCT_MEMBERS_ANALYSIS result: qualified Struct owner -> member names in
  # storage-index order. See detect_struct_new_members.
  struct_member_lists = {}
  # CLOSED_WORLD: every CLASS opcode's superclass ref (nil when unresolved) and
  # whether its outer was implicit, plus every irep this walk visited.
  class_decls = Hash.new { |h, k| h[k] = [] }
  walked = Set.new

  walk = lambda do |label, namespace|
    walked << label
    irep = ireps.fetch(label)
    # Which register holds the class/module/singleton class just opened by
    # CLASS/MODULE/SCLASS, so its EXEC can be matched. pending_idx pins the EXEC to
    # the literal next instruction: mrbc always emits it there, and an empty body
    # (`class Timeout < StandardError; end`) emits no EXEC at all, so matching "the
    # next EXEC on this register" would attach an unrelated later body to the empty
    # class (this registered RGSS.asset_archive under RGSS::Timeout).
    pending_reg = nil
    pending_name = nil
    pending_idx = nil
    # `private`/`protected`/`public` tracking, scoped to this body. A bare call
    # (n=0) switches the mode for later defs; a call with Symbol arguments marks
    # already-defined methods without changing the mode. Getting visibility wrong
    # would let a register.cxx registration expose a private method.
    default_visibility = :public

    # Resolve a singleton receiver's name by walking back from `before_idx` to
    # `reg`'s last write. Only LOADSELF (the innermost namespace) and a GETCONST are
    # trusted; anything else is unrecognized (a safe miss). Shared by the SCLASS
    # body case and the unfused DEF case below.
    resolve_singleton_receiver = lambda do |reg, before_idx|
      recv = nil
      (before_idx - 1).downto(0) do |i|
        prev = irep.instructions[i]
        pd = prev.args[/^(R\d+)/, 1]
        next unless pd == reg

        case prev.op
        when 'LOADSELF'
          recv = namespace || 'Object'
        when 'GETCONST'
          const_name = prev.args[/^R\d+\s+(\S+)/, 1]
          recv = namespace ? "#{namespace}::#{const_name}" : const_name
        end
        break
      end
      recv
    end

    # Shared by TDEF and the unfused TCLASS+METHOD+DEF case: both need the builtin
    # always-private names (see the TDEF case).
    resolve_def_visibility = lambda do |method_name|
      %w[initialize initialize_copy
         respond_to_missing?].include?(method_name) ? :private : default_visibility
    end

    # mrbc -v prints OP_EXT1/EXT2/EXT3 as their own lines between instructions
    # codegen emits back to back (src/codedump.c; each widens the next
    # instruction's operands). The unfused DEF case always has one (its METHOD
    # index is > 0xff by construction). Returns the index of the first real opcode
    # before `from_idx`, or -1.
    skip_ext_back = lambda do |from_idx|
      i = from_idx
      i -= 1 while i >= 0 && %w[EXT1 EXT2 EXT3].include?(irep.instructions[i]&.op)
      i
    end

    irep.instructions.each_with_index do |insn, idx|
      case insn.op
      when 'CLASS', 'MODULE'
        # "CLASS R4 :Animal" / "MODULE R1 :Game" -- args "R4\t:Animal"
        reg, name = insn.args.split(/\s+/, 2)
        pending_reg = reg
        pending_idx = idx
        # Qualified name (Game::CharSet) so same-named nested classes stay distinct.
        pending_name = namespace ? "#{namespace}::#{name.sub(/^:/, '')}" : name.sub(/^:/, '')
        # SUPER_SUPPORT: OP_CLASS is `R[a] = newclass(R[a], Syms[b], R[a+1])`
        # (mruby/ops.h, vm.c), and the superclass expression is evaluated right before
        # it, so resolve_superclass_ref walks back from this CLASS.
        if insn.op == 'CLASS'
          superclass_reg = (reg[/\d+/].to_i + 1).to_s
          resolved = resolve_superclass_ref(irep, idx, superclass_reg, namespace)
          superclass_of[pending_name] = resolved if resolved
          outer_nil = resolve_superclass_ref(irep, idx, reg[/\d+/], nil) == :none
          class_decls[pending_name] << { super: resolved, outer_nil: outer_nil }
        end
      when 'SCLASS'
        # "SCLASS R1": R[a] = R[a].singleton_class. A `class << self` / `class <<
        # SomeConst` body holds ordinary TDEFs, so it is walked like a CLASS/MODULE body
        # by the same EXEC-matching code below. Without this, defs inside it (e.g.
        # RGSS::Bitmap.extensions) were unregistered.
        # The receiver is resolved by resolve_singleton_receiver (LOADSELF or GETCONST
        # only; anything else is a safe miss).
        reg = insn.args[/^(R\d+)/, 1]
        recv = resolve_singleton_receiver.call(reg, idx)
        pending_reg = reg
        pending_idx = idx
        # "X.singleton" is a pseudo-owner, never a real constant path, so ONLY_OWNERS
        # can never select it. nil (unrecognized receiver) keeps EXEC from recursing.
        pending_name = recv ? "#{recv}.singleton" : nil
      when 'SETCONST'
        # CONST_CONTAINER_SUPPORT: "SETCONST NAME Rsrc" in a class/module body;
        # `namespace` is this body's lexical nesting. Only the literal (optionally
        # frozen) shape is recognized; anything else is a safe miss (nil).
        const_name = insn.args[/^(\S+)/, 1]
        src_reg = insn.args[/R(\d+)/, 1]
        qualified = namespace ? "#{namespace}::#{const_name}" : const_name
        klass = literal_container_class(irep, idx, src_reg)
        # Two disagreeing (or unresolvable) sites poison the name to nil; never
        # guess which one wins.
        if container_constants.key?(qualified)
          container_constants[qualified] = nil if container_constants[qualified] != klass
        else
          container_constants[qualified] = klass
        end
      when 'EXEC'
        reg, irep_ref = insn.args.split(/\s+/, 2)
        idx2 = irep_ref[/I\[(\d+)\]/, 1].to_i
        child_label = irep.reps[idx2]
        walk.call(child_label, pending_name) if reg == pending_reg && pending_name && idx == pending_idx + 1
        pending_reg = nil
        pending_name = nil
        pending_idx = nil
      when 'TDEF'
        # "TDEF R1 :speak I[1]"
        _reg, name, irep_ref = insn.args.split(/\s+/, 3)
        idx2 = irep_ref[/I\[(\d+)\]/, 1].to_i
        child_label = irep.reps[idx2]
        method_name = name.sub(/^:/, '')
        owner = namespace || 'Object' # a top-level `def` lands on Object.
        # #initialize, #initialize_copy and #respond_to_missing? are always private,
        # whatever mode is in effect: src/class.c's define_method path sets
        # MRB_METHOD_PRIVATE_FL for them unconditionally. default_visibility cannot
        # see that rule, and reporting them public would let register.cxx expose them.
        visibility = resolve_def_visibility.call(method_name)
        registry[method_name] << MethodDef.new(name: method_name, owner: owner, irep: child_label,
                                                visibility: visibility)
      when 'SDEF'
        # "SDEF R1 :clamp I[5]": `def self.foo` / `def SomeConst.foo`. codegen_sdef
        # (mruby-compiler codegen.c) fuses SCLASS+METHOD+DEF into SDEF whenever the
        # child irep index fits a byte, installing Irep[c] on R[a]'s singleton class.
        #
        # It must be registered (under the "Owner.singleton" pseudo-owner) or a
        # same-named instance method elsewhere looks MONO and call sites devirtualize
        # into the wrong body (Game.clamp vs RPG2k::Scene::MapViewer#clamp). Adding a
        # def can only turn an unsound MONO into POLY, never lose a sound one.
        #
        # I[c] is a real child irep, so it is recorded as `irep:` (docs/adr/0139);
        # with irep: nil the method could never become a compile target. That is safe
        # for every `d.irep` reader: natively_exposed? only compares against instance
        # owners from ivar_layout, never ".singleton" ones.
        #
        # The receiver is an arbitrary expression (codegen_sdef runs `codegen(s, recv,
        # VAL)`, and vm.c's OP_SDEF uses mrb_singleton_class(regs[a])), so it is
        # resolved with resolve_singleton_receiver rather than assuming `self`; that
        # scan already skips interposed EXT lines. An unrecognized receiver is not
        # registered rather than attributed to `namespace`.
        reg, sname, irep_ref = insn.args.split(/\s+/, 3)
        sdef_name = sname.sub(/^:/, '')
        sdef_idx = irep_ref[/I\[(\d+)\]/, 1].to_i
        sdef_child_label = irep.reps[sdef_idx]
        recv = resolve_singleton_receiver.call(reg, idx)
        if recv
          registry[sdef_name] << MethodDef.new(name: sdef_name, owner: "#{recv}.singleton",
                                                irep: sdef_child_label, visibility: :public)
        end
      when 'DEF'
        # "DEF R1 :toned? (R2)": codegen_def/codegen_sdef fuse into TDEF/SDEF only
        # when the child irep index fits a byte; past 255 children (RPG2k::Scene::Map)
        # they emit the unfused sequence instead:
        #   TCLASS  R1            LOADSELF R1 / SCLASS R1   (for `def self.x`)
        #   EXT2
        #   METHOD  R2  I[380]
        #   EXT2
        #   DEF     R1  :toned?  (R2)
        # skip_ext_back steps over the interposed EXT lines.
        reg, name, recv_arg = insn.args.split(/\s+/, 3)
        method_idx = skip_ext_back.call(idx - 1)
        method_insn = method_idx >= 0 ? irep.instructions[method_idx] : nil
        next unless method_insn && method_insn.op == 'METHOD'

        method_reg, irep_ref = method_insn.args.split(/\s+/, 2)
        # Registers must line up as codegen emits them (opener at R<n>, METHOD at
        # R<n+1>, DEF at R<n> referencing (R<n+1>)); adjacency alone is not trusted.
        next unless recv_arg == "(#{method_reg})"

        opener_idx = skip_ext_back.call(method_idx - 1)
        opener_insn = opener_idx >= 0 ? irep.instructions[opener_idx] : nil
        next unless opener_insn && %w[TCLASS SCLASS].include?(opener_insn.op)

        opener_reg = opener_insn.args[/^(R\d+)/, 1]
        next unless opener_reg == reg

        idx2 = irep_ref[/I\[(\d+)\]/, 1].to_i
        child_label = irep.reps[idx2]
        def_name = name.sub(/^:/, '')

        if opener_insn.op == 'TCLASS'
          # Unfused `def foo`: registered exactly like a TDEF, with a real irep.
          owner = namespace || 'Object' # a top-level `def` lands on Object.
          visibility = resolve_def_visibility.call(def_name)
          registry[def_name] << MethodDef.new(name: def_name, owner: owner, irep: child_label,
                                               visibility: visibility)
        else
          # Unfused `def self.foo`: same "X.singleton" pseudo-owner and real irep as
          # SDEF, receiver resolved by resolve_singleton_receiver (unrecognized: not
          # registered). Visibility is always :public: singleton-method privacy is not
          # modelled for either shape.
          recv = resolve_singleton_receiver.call(opener_reg, opener_idx)
          if recv
            owner = "#{recv}.singleton"
            registry[def_name] << MethodDef.new(name: def_name, owner: owner, irep: child_label,
                                                 visibility: :public)
          end
        end
      when 'SEND0', 'SEND', 'SSEND0', 'SSEND'
        # Same charset as compile_send's name extraction; keep the two in sync.
        name = insn.args[/:([\w+\-*\/<>=!?\[\]&|^~%@]+)/, 1]
        if name == 'new'
          # STRUCT_MEMBERS_ANALYSIS for the block-less `Const = Struct.new(...)` shape.
          # Additive only: returns nil for anything but a SETCONST-named Struct.new.
          found = detect_struct_new_members(irep, idx, insn, namespace)
          struct_member_lists[found[0]] = found[1] if found
        end
        if %w[include prepend].include?(name)
          # ANCESTOR_MIXINS_SUPPORT: a self-implicit `include M`/`prepend M` in this
          # body (walk only recurses into CLASS/MODULE/SCLASS bodies, so `namespace` is
          # the owner). mrbc emits `GETCONST R(a+1) M` right before `SSEND R(a) :include
          # n=1`. An explicit receiver, several arguments or a non-constant module flags
          # the owner in `unknown_mixins` so `super` there declines.
          mixin_owner = namespace || 'Object'
          self_reg = insn.args[/^R(\d+)/, 1]
          mixin_n = insn.args[/n=(\d+)/, 1]&.to_i
          recognized = %w[SSEND SSEND0].include?(insn.op) && mixin_n == 1 && self_reg
          mod = recognized ? resolve_superclass_ref(irep, idx, (self_reg.to_i + 1).to_s, namespace) : nil
          if recognized && mod.is_a?(String)
            table = name == 'include' ? included_modules : prepended_modules
            (table[mixin_owner] ||= []) << mod
          else
            unknown_mixins << mixin_owner
          end
          next
        end
        next unless %w[private protected public attr_reader attr_writer attr_accessor
                       module_function].include?(name)

        n = insn.args[/n=(\d+)/, 1].to_i
        # 15+ arguments are packed into one ARRAY (CALL_MAXARGS) and sent as n=*.
        packed = insn.args.include?('n=*')
        if packed
          arr = idx.positive? && irep.instructions[idx - 1]
          n = arr && arr.op == 'ARRAY' ? arr.args[/R\d+\s+(\d+)/, 1].to_i : -1
          raise "bc2cpp: #{name} with a splat argument at #{irep.label}:#{insn.addr} names methods statically unknown" if n <= 0
        end
        # `private :a, :b` / `attr_reader :a, :b`: the Symbol arguments are LOADSYM'd
        # into consecutive registers right before the send; walk back to collect them.
        collect_loadsym_names = lambda do
          names = []
          (idx - (packed ? 2 : 1)).downto(0) do |i|
            break if names.size >= n

            prev = irep.instructions[i]
            break unless prev.op == 'LOADSYM'

            names.unshift(prev.args[/:(\S+)/, 1])
          end
          names
        end

        if %w[private protected public].include?(name)
          if n.zero?
            default_visibility = name.to_sym
          else
            # `private :a, :b, ...` -- retroactively marks already-defined
            # methods, without changing the mode for whatever comes after.
            collect_loadsym_names.call.each do |mname|
              def_ = registry[mname]&.find { |d| d.owner == namespace }
              def_.visibility = name.to_sym if def_
            end
          end
        elsif name == 'module_function'
          # `module_function :a, :b` installs a public copy of each instance method on
          # the module's singleton class. In mruby (src/class.c
          # mrb_mod_module_function), unlike CRuby, the instance method stays as it was
          # (the make-private call is commented out), so only the singleton copy needs a
          # registry entry. It is added as "Owner.singleton" with irep: nil: the registry
          # cannot express "two owners, one irep", and irep: nil can only prevent a
          # direct call, never enable a wrong one. Only the retroactive (n >= 1) form is
          # handled; the bare mode-switch form does not occur in this closed world.
          collect_loadsym_names.call.each do |mname|
            registry[mname] << MethodDef.new(name: mname, owner: "#{namespace || 'Object'}.singleton",
                                              irep: nil, visibility: :public)
          end
        else
          # attr_reader/attr_writer/attr_accessor are native, so their accessors get no
          # TDEF. Each name is registered as a synthetic MethodDef (irep: nil) so a
          # same-named bytecode def elsewhere is not MONO: Game::Battle#critical?'s
          # `b.crit_chance` (b an Actor or an Enemy) otherwise devirtualized into
          # Game::Actor#crit_chance and raised NoMethodError for enemies. This can only
          # turn an unsound MONO into POLY.
          getter_flag = %w[attr_reader attr_accessor].include?(name)
          setter_flag = %w[attr_writer attr_accessor].include?(name)
          collect_loadsym_names.call.each do |mname|
            owner = namespace || 'Object'
            # kind: :ivar_accessor (see MethodDef): src/class.c's attr_reader/attr_writer
            # are exactly mrb_iv_get/mrb_iv_set on the bare `@name`; consumed by
            # IVAR_ACCESSOR_DEVIRT.
            if getter_flag
              registry[mname] << MethodDef.new(name: mname, owner: owner, irep: nil, visibility: :public,
                                                kind: :ivar_accessor)
            end
            if setter_flag
              registry["#{mname}="] << MethodDef.new(name: "#{mname}=", owner: owner, irep: nil,
                                                       visibility: :public, kind: :ivar_accessor)
            end
          end
        end
      when 'SENDB'
        # STRUCT_MEMBERS_ANALYSIS for the block-taking form; additive only.
        found = detect_struct_new_members(irep, idx, insn, namespace)
        struct_member_lists[found[0]] = found[1] if found

        # `Const = Struct.new(:a, ...) do ... end`: no CLASS opcode opens the block,
        # and the member accessors are native (struct.c), so both the block's defs and
        # the member names are invisible to the plain walk. Without registering them,
        # Game::Battle::Combatant#state? and #actor looked MONO and devirtualized into
        # Game::Actor/RPG2k::Scene::EquipMenu bodies that read ivars a Struct does not
        # have (Struct members are positional, not iv_tbl).
        name = insn.args[/:([\w+\-*\/<>=!?\[\]&|^~%@]+)/, 1]
        next unless name == 'new'

        d = insn.args[/^R(\d+)/, 1]
        # Only a bare `Struct` GETCONST receiver is trusted; anything else is a safe
        # miss.
        struct_recv = false
        (idx - 1).downto(0) do |i|
          prev = irep.instructions[i]
          pd = prev.args[/^R(\d+)/, 1]
          next unless pd == d

          struct_recv = prev.op == 'GETCONST' && prev.args[/^R\d+\s+(\S+)/, 1] == 'Struct'
          break
        end
        next unless struct_recv

        # The block operand is the BLOCK right before the SENDB (codegen emits it
        # there).
        block_insn = irep.instructions[idx - 1]
        next unless block_insn && block_insn.op == 'BLOCK'

        block_idx = block_insn.args[/I\[(\d+)\]/, 1]
        next unless block_idx

        block_label = irep.reps[block_idx.to_i]
        next unless block_label

        # The owner name comes from a SETCONST right after the SENDB. An unnamed
        # Struct still gets a placeholder owner: soundness only needs a distinct
        # owner so `defs.size == 1` sees more than one definition.
        next_insn = irep.instructions[idx + 1]
        struct_name = if next_insn && next_insn.op == 'SETCONST'
                         sc_name, sc_reg = next_insn.args.split(/\s+/, 2)
                         sc_name if sc_reg == "R#{d}"
                       end
        owner = struct_name ? (namespace ? "#{namespace}::#{struct_name}" : struct_name) : "<struct:#{label}:#{idx}>"

        # Member names are LOADSYM'd right before the ARRAY that packs the splat.
        # Struct installs a reader and a writer for each (struct.c), like
        # attr_accessor.
        array_insn = irep.instructions[idx - 2]
        if array_insn && array_insn.op == 'ARRAY'
          n = array_insn.args[/^R\d+\s+(\d+)/, 1].to_i
          members = []
          (idx - 3).downto(0) do |i|
            break if members.size >= n

            prev = irep.instructions[i]
            break unless prev.op == 'LOADSYM'

            members.unshift(prev.args[/:(\S+)/, 1])
          end
          members.each do |m|
            registry[m] << MethodDef.new(name: m, owner: owner, irep: nil, visibility: :public)
            registry["#{m}="] << MethodDef.new(name: "#{m}=", owner: owner, irep: nil, visibility: :public)
          end
        end

        # Walk the block body like a class body, so its defs get real ireps.
        walk.call(block_label, owner)
      end
    end
  end

  walk.call(root_label, nil)
  [registry, superclass_of, container_constants.compact, included_modules, prepended_modules, unknown_mixins,
   struct_member_lists, class_decls, walked]
end

# SUPER_SUPPORT: resolve `class X < SUPER_EXPR` to a class name by walking back
# from the CLASS instruction. Only a bare GETCONST (resolved against the real
# lexical `namespace`, one level, like resolve_singleton_receiver), GETMCNST,
# or a MOVE of one is recognized; anything else returns nil (absent from
# superclass_of, never a wrong guess).
def resolve_superclass_ref(irep, before_idx, reg, namespace)
  path = []
  (before_idx - 1).downto(0) do |i|
    insn = irep.instructions[i]
    d = insn.args[/^R(\d+)/, 1]
    next unless d == reg

    case insn.op
    when 'MOVE'
      reg = insn.args.scan(/R(\d+)/).flatten[1]
    when 'LOADNIL'
      return :none # no explicit superclass written -- real Ruby default is Object.
    when 'GETMCNST'
      path.unshift(insn.args[/::(\w+)/, 1])
    when 'GETCONST'
      const_name = insn.args[/^R\d+\s+(\S+)/, 1]
      return path.empty? ? (namespace ? "#{namespace}::#{const_name}" : const_name) : path.unshift(const_name).join('::')
    else
      return nil
    end
  end
  nil
end

# ---------------------------------------------------------------------------
# Step 5b: native method names. mrb_define_method-family call sites in C
# sources are invisible to mrbc, so a name defined once in bytecode would look
# MONO even when a C class defines the same name (Game::Shop#name vs
# Class#name/Symbol#name). Only the flat set of names is extracted: that is
# all MONO/POLY soundness needs, and calling a native function directly would
# skip the ci frame mrb_funcall sets up for mrb_get_args.
# ---------------------------------------------------------------------------
# Inverse of mruby's presym OPERATORS table (lib/mruby/presym.rb):
# MRB_OPSYM(cmp) is how C source spells `<=>`.
OPSYM_TO_RUBY = {
  'not' => '!', 'mod' => '%', 'and' => '&', 'mul' => '*', 'add' => '+',
  'sub' => '-', 'div' => '/', 'lt' => '<', 'gt' => '>', 'xor' => '^',
  'tick' => '`', 'or' => '|', 'neg' => '~', 'neq' => '!=', 'nmatch' => '!~',
  'andand' => '&&', 'pow' => '**', 'plus' => '+@', 'minus' => '-@',
  'lshift' => '<<', 'le' => '<=', 'eq' => '==', 'match' => '=~',
  'ge' => '>=', 'rshift' => '>>', 'aref' => '[]', 'oror' => '||',
  'cmp' => '<=>', 'eqq' => '===', 'aset' => '[]=',
}.freeze

# mruby core registers most methods through ROM tables rather than literal
# string names (src/symbol.c):
#   static const mrb_mt_entry symbol_rom_entries[] = {
#     MRB_MT_ENTRY(sym_name, MRB_SYM(name), MRB_ARGS_NONE()),
#     MRB_MT_ENTRY(sym_cmp,  MRB_OPSYM(cmp), MRB_ARGS_REQ(1)),   // <=>
#   };
#   MRB_MT_INIT_ROM(mrb, sym, symbol_rom_entries);
# and some gems call mrb_define_method_id(mrb, klass, MRB_SYM(name), ...).
# Both use this token. One MRB_SYM/SYM_Q/SYM_B/SYM_E/OPSYM token, shared by
# extract_native_method_names and extract_native_call_names so the resolution
# logic lives in one place.
MRB_SYM_TOKEN_RE = /MRB_(SYM_Q|SYM_B|SYM_E|SYM|OPSYM)\((\w+)\)/

def resolve_mrb_sym_token(macro, name)
  case macro
  when 'SYM_Q' then "#{name}?"
  when 'SYM_B' then "#{name}!"
  when 'SYM_E' then "#{name}="
  when 'OPSYM' then OPSYM_TO_RUBY[name] || name
  else name # bare MRB_SYM(name)
  end
end

require_relative 'native_expression_devirt'
require_relative 'symbol_cache'
require_relative 'const_site_cache'
require_relative 'static_dispatch_unregistered'
require_relative 'unique_class_names'
require_relative 'closed_world'

# ---------------------------------------------------------------------------
# INTEGER_CONSTANT_PROOF: the bare constant names that can only ever resolve
# to an Integer; FIXNUM_OPERAND_PROOF's fifth proof source (see
# fixnum_proof_source?).
#
# Keyed by BARE name, which is the soundness argument: `GETCONST R4 FOO`
# resolves through lexical nesting and ancestors, which this file does not
# model, so a name is admitted only when EVERY definition of it anywhere is
# integral. Poison sources, all required:
#   1. a SETCONST/SETMCNST whose source is not an integer literal
#      (literal_int_const_source?);
#   2. a CLASS/MODULE naming it (OP_CLASS binds the constant itself);
#   3. a native mrb_define_const / mrb_define_global_const /
#      mrb_define_const_id;
#   4. a definition in a foreign Ruby source sharing the VM
#      (foreign_mrblib_srcs, compiled_gems.rb).
# A name with no integer definition is never admitted, so an unseen constant
# only costs a missed proof.
#
# CONST_ALIAS_CHAINING: `SCREEN_W = RPG2k::WIDTH` records an alias to the bare
# name instead of poisoning; resolve_integral settles the graph (see its
# header for why it must be the greatest fixpoint).
module IntegerConstants
  # `SETCONST NAME R1` / `SETMCNST (R2)::NAME R1` (codedump.c): the name comes
  # first and the source register last, the reverse of GETCONST. print_lv_a may
  # append a `; R1:name` comment, which is stripped before reading the register.
  def self.analyze(ireps, native_paths, foreign_paths)
    # name -> list of one entry per real definition of that bare name:
    # `:literal` (an integer literal), `[:alias, M]` (a read of bare constant
    # name M), or nil (anything else -- an unconditional poison).
    defs = Hash.new { |h, k| h[k] = [] }
    poisoned = Set.new
    ireps.each_value do |irep|
      entries = const_entry_addrs(irep)
      irep.instructions.each_with_index do |insn, i|
        case insn.op
        when 'SETCONST', 'SETMCNST'
          name = insn.op == 'SETCONST' ? insn.args[/\A(\S+)/, 1] : insn.args[/::(\S+)/, 1]
          next unless name

          src = insn.args.sub(/;.*\z/m, '').scan(/R(\d+)/).flatten.last
          defs[name] << (src && const_source_kind(irep, i, src, entries))
        when 'CLASS', 'MODULE'
          nm = insn.args[/:(\S+)/, 1]
          poisoned << nm if nm
        end
      end
    end
    poisoned.merge(native_const_names(native_paths))
    poisoned.merge(foreign_const_names(foreign_paths))
    resolve_integral(defs, poisoned)
  end

  # CONST_ALIAS_CHAINING: the GREATEST fixpoint of "every definition of this bare
  # name assigns an integer literal or the value of another such name": start
  # from every classifiable, unpoisoned name and drop names aliasing a dropped
  # one until stable. The least fixpoint would refuse `Scene::Map::TILE =
  # Game::TILE`, which aliases its own bare name.
  #
  # Soundness is an induction on runtime assignment order: each binding of an
  # admitted name N executes either an integer literal (LOADI*, a Fixnum) or a
  # read of admitted name M, which must succeed (an unassigned constant raises
  # NameError), so an earlier binding of M already stored a Fixnum. A cycle with
  # no literal (`A = B; B = A`) is admitted but can never execute. This needs
  # every binding to be classified, which the four poison sources guarantee.
  def self.resolve_integral(defs, poisoned)
    cand = Set.new
    defs.each do |name, kinds|
      next if poisoned.include?(name)
      next if kinds.empty? || kinds.any?(&:nil?)

      cand << name
    end
    loop do
      dropped = cand.reject do |name|
        defs[name].all? { |k| k == :literal || cand.include?(k[1]) }
      end
      break if dropped.empty?

      dropped.each { |n| cand.delete(n) }
    end
    cand
  end

  # Every address control can enter other than by falling through: the targets
  # of the five pc-moving JMP* opcodes (as in fixnum_proof_edge_sources) plus
  # every catch handler target.
  def self.const_entry_addrs(irep)
    addrs = Set.new
    irep.instructions.each do |insn|
      case insn.op
      when 'JMP', 'JMPUW'
        addrs << insn.args.strip[/\d+/].to_i
      when 'JMPIF', 'JMPNOT', 'JMPNIL'
        # `"JMPIF\t\tR%d\t%03d"` -- register first, target last.
        t = insn.args.sub(/;.*\z/m, '').strip.split(/\s+/).last
        addrs << t.to_i if t
      end
    end
    (irep.catch_handlers || []).each { |ch| addrs << ch.target }
    addrs
  end

  # How is `reg` written at this point of the class body? Returns :literal,
  # [:alias, NAME] or nil (poison), using the same bounded backward walk as
  # proven_fixnum_operand?. Any complication returns nil.
  # The walk must not step over a jump target: `X = cond ? "s" : 1` compiles to
  # JMPNOT/STRING/JMP/LOADI_1/SETCONST, whose nearest backward writer is a LOADI
  # even though the other arm binds a String.
  def self.const_source_kind(irep, idx, reg, entries)
    cur = reg.to_s
    j = idx - 1
    while j >= 0
      insn = irep.instructions[j]
      return nil unless insn
      return nil if entries.include?(insn.addr)

      if insn.args =~ /\AR#{cur}\b/
        return :literal if insn.op.start_with?('LOADI')

        case insn.op
        when 'MOVE'
          # `regs[a] = regs[b]` -- keep looking for whatever wrote the source.
          src = insn.args.scan(/R(\d+)/).flatten[1]
          return nil unless src

          cur = src
        when 'GETCONST'
          # `"GETCONST\tR%d\t%s"` -- register first, bare name second.
          n = insn.args.split(/\s+/)[1]
          return n && [:alias, n]
        when 'GETMCNST'
          # `"GETMCNST\tR%d\t(R%d)::%s"`: only the bare name after `::` is used; the
          # scope register is not modelled, so the proof must hold for every constant
          # of that name.
          n = insn.args[/::(\S+)/, 1]
          return n && [:alias, n]
        else
          return nil
        end
      end
      j -= 1
    end
    nil
  end

  # INTEGER_CONSTANT_VALUE_PROOF: analyze proves a bare name always binds a
  # Fixnum; this proves it always binds the SAME Fixnum, so GETCONST/GETMCNST can
  # be replaced by the literal. Sound by resolve_integral's induction: if every
  # classified definition (through aliases) resolves to one number, every run
  # binds that number. `admitted` is analyze's Set, so its poison sources are
  # already applied.
  # A literal-less alias cycle resolves to nil by cycle detection, not memoized:
  # a cycle is a property of the path, not the name.
  def self.analyze_values(ireps, admitted)
    return {} if admitted.empty?

    defs = Hash.new { |h, k| h[k] = [] }
    ireps.each_value do |irep|
      entries = const_entry_addrs(irep)
      irep.instructions.each_with_index do |insn, i|
        next unless insn.op == 'SETCONST' || insn.op == 'SETMCNST'

        name = insn.op == 'SETCONST' ? insn.args[/\A(\S+)/, 1] : insn.args[/::(\S+)/, 1]
        next unless name && admitted.include?(name)

        src = insn.args.sub(/;.*\z/m, '').scan(/R(\d+)/).flatten.last
        defs[name] << (src && literal_value_kind(irep, i, src, entries))
      end
    end

    memo = {}
    resolve = lambda do |name, visiting|
      return memo[name] if memo.key?(name)
      return nil if visiting.include?(name)

      kinds = defs[name]
      next nil if kinds.empty? || kinds.any?(&:nil?)

      seen = visiting + [name]
      values = kinds.map { |k| k[0] == :literal ? k[1] : resolve.call(k[1], seen) }
      result = values.any?(&:nil?) || values.uniq.size != 1 ? nil : values.first
      memo[name] = result
      result
    end

    admitted.each_with_object({}) do |name, out|
      value = resolve.call(name, Set.new)
      out[name] = value unless value.nil?
    end
  end

  # const_source_kind's walk, returning `[:literal, N]` for LOADI*. Everything
  # else is identical on purpose, so this runs over exactly the shapes the kind
  # proof validated.
  def self.literal_value_kind(irep, idx, reg, entries)
    cur = reg.to_s
    j = idx - 1
    while j >= 0
      insn = irep.instructions[j]
      return nil unless insn
      return nil if entries.include?(insn.addr)

      if insn.args =~ /\AR#{cur}\b/
        if insn.op.start_with?('LOADI')
          value = loadi_value(insn)
          return value.nil? ? nil : [:literal, value]
        end

        case insn.op
        when 'MOVE'
          src = insn.args.scan(/R(\d+)/).flatten[1]
          return nil unless src

          cur = src
        when 'GETCONST'
          n = insn.args.split(/\s+/)[1]
          return n && [:alias, n]
        when 'GETMCNST'
          n = insn.args[/::(\S+)/, 1]
          return n && [:alias, n]
        else
          return nil
        end
      end
      j -= 1
    end
    nil
  end

  # Duplicate of CodeGen's loadi_literal/loadi_proven_fixnum? (this module has no
  # CodeGen instance). Only LOADI32 can leave the LOADI_FIXNUM_MIN/MAX margin, so
  # it is range-checked and refused (nil) outside it.
  def self.loadi_value(insn)
    tok = insn.args.split(/\s+/)[1]
    return nil unless tok&.match?(/\A-?\d+\z/)

    value = tok.to_i
    return nil if insn.op == 'LOADI32' && !value.between?(CodeGen::LOADI_FIXNUM_MIN, CodeGen::LOADI_FIXNUM_MAX)

    value
  end

  # Poison source 3 -- see the header above for the three real call forms.
  def self.native_const_names(paths)
    names = Set.new
    Array(paths).each do |path|
      src = begin
        File.read(path, encoding: 'UTF-8')
      rescue StandardError
        next
      end
      src.scan(/mrb_define_(?:global_)?const(?:_id)?\s*\(.{0,200}?/m) do
        seg = Regexp.last_match(0)
        seg.scan(/"([A-Za-z_][A-Za-z_0-9]*)"/) { names << Regexp.last_match(1) }
        seg.scan(/MRB_SYM[A-Z_]*\(\s*([A-Za-z_][A-Za-z_0-9]*)\s*\)/) { names << Regexp.last_match(1) }
      end
    end
    names
  end

  # KEYWORD_NEVER_DEFINED_CONST_RECEIVER_SUPPORT: native constant definitions,
  # with a bounded `[^;]{0,200}` window over the call's arguments. It does not
  # reuse native_const_names, whose lazy `.{0,200}?` matches zero characters (a
  # latent miss left alone because INTEGER_CONSTANT_PROOF depends on it); a missed
  # definition is the unsound direction for a never-defined proof. Reads:
  #   * mrb_define_const / mrb_define_global_const (+ _id);
  #   * mrb_const_set;
  #   * mrb_define_class / mrb_define_module (+ _id/_under): class.c's
  #     mrb_define_class_id does its own const_set.
  # Deliberately over-broad; over-collecting only costs a proof.
  def self.native_defined_const_names(paths)
    names = Set.new
    Array(paths).each do |path|
      src = begin
        File.read(path, encoding: 'UTF-8')
      rescue StandardError
        next
      end
      src.scan(/mrb_define_(?:global_)?const(?:_id)?\s*\([^;]{0,200}/m) do
        seg = Regexp.last_match(0)
        seg.scan(/"([A-Z][A-Za-z_0-9]*)"/) { names << Regexp.last_match(1) }
        seg.scan(/MRB_SYM[A-Z_]*\(\s*([A-Za-z_][A-Za-z_0-9]*)\s*\)/) { names << Regexp.last_match(1) }
      end
      src.scan(/mrb_const_set\s*\([^;]{0,200}/m) do
        seg = Regexp.last_match(0)
        seg.scan(/"([A-Z][A-Za-z_0-9]*)"/) { names << Regexp.last_match(1) }
        seg.scan(/MRB_SYM[A-Z_]*\(\s*([A-Za-z_][A-Za-z_0-9]*)\s*\)/) { names << Regexp.last_match(1) }
      end
      src.scan(/mrb_define_(?:class|module)(?:_[a-z_]*)?\s*\([^;]{0,200}/m) do
        seg = Regexp.last_match(0)
        seg.scan(/"([A-Z][A-Za-z_0-9]*)"/) { names << Regexp.last_match(1) }
        seg.scan(/MRB_SYM[A-Z_]*\(\s*([A-Za-z_][A-Za-z_0-9]*)\s*\)/) { names << Regexp.last_match(1) }
      end
    end
    names
  end

  # KEYWORD_NEVER_DEFINED_CONST_RECEIVER_SUPPORT: every constant name with a
  # visible definition: SETCONST/SETMCNST/CLASS/MODULE opcodes, native
  # definitions and foreign Ruby sources. What stays invisible (runtime
  # const_set, unscanned gems, eval) is listed at
  # compile_keyword_never_defined_const_send.
  def self.defined_name_universe(ireps, native_paths, foreign_paths)
    names = Set.new
    ireps.each_value do |irep|
      irep.instructions.each do |insn|
        case insn.op
        when 'SETCONST'
          names << insn.args[/\A(\S+)/, 1]
        when 'SETMCNST'
          names << insn.args[/::(\S+)/, 1]
        when 'CLASS', 'MODULE'
          names << insn.args[/:(\S+)/, 1]
        end
      end
    end
    names.delete(nil)
    names.merge(native_defined_const_names(native_paths))
    names.merge(foreign_const_names(foreign_paths))
    names
  end

  # Poison source 4: any `NAME =` at line start, whatever the right-hand side.
  # Over-collecting only costs a proof; under-collecting would be wrong.
  def self.foreign_const_names(paths)
    names = Set.new
    Array(paths).each do |path|
      src = begin
        File.read(path, encoding: 'UTF-8')
      rescue StandardError
        next
      end
      src.scan(/^\s*([A-Z][A-Za-z_0-9]*)\s*=[^=~]/) { names << Regexp.last_match(1) }
      # `class Foo` / `module Foo` bind a constant too (poison source 2).
      src.scan(/^\s*(?:class|module)\s+([A-Z][A-Za-z_0-9]*)/) { names << Regexp.last_match(1) }
    end
    names
  end
end

# ---------------------------------------------------------------------------
# FIXNUM_RETURN_PROOF's out-of-closed-world poison source, the method twin of
# IntegerConstants.foreign_const_names. A method defined in 3rd/mruby/mrblib
# (same VM, invisible to build_registry) can make a name look MONO. A wrong
# return-type proof emits an unchecked mrb_fixnum() (undefined behavior, not a
# wrong answer), so FIXNUM_RETURN_PROOF refuses any name defined here at all
# (e.g. enumerator.rb's `size`, enum.rb's `max`/`min`, mruby-complex's `abs`).
#
# Textual and over-broad on purpose. Fully dynamic definitions (`alias_method
# :"string_#{v}", v`) cannot be enumerated, which is why this is only a poison
# source, never positive evidence.
# ---------------------------------------------------------------------------
# One method-name token, same charset as the SEND-name extraction (so `def
# <=>` / `def []=` are seen).
FOREIGN_METHOD_NAME_RE = %r{[\w+\-*/<>=!?\[\]&|^~%@]+}

def foreign_method_names(paths)
  names = Set.new
  Array(paths).each do |path|
    src = begin
      File.read(path, encoding: 'UTF-8')
    rescue StandardError
      next
    end
    # `def name`, `def self.name`, `def obj.name`.
    src.scan(/^\s*def\s+(?:[A-Za-z_][A-Za-z_0-9]*\.)?(#{FOREIGN_METHOD_NAME_RE})/o) do
      names << Regexp.last_match(1)
    end
    # All three accessor spellings are collected for all three macros:
    # over-collection on purpose.
    src.scan(/^\s*attr_(?:reader|writer|accessor)\s+(.+)$/) do
      Regexp.last_match(1).scan(/:(\w+)/) do
        n = Regexp.last_match(1)
        names << n
        names << "#{n}="
      end
    end
    # A second body installed under a name with no `def` of its own.
    src.scan(/^\s*alias\s+:?(#{FOREIGN_METHOD_NAME_RE})/o) { names << Regexp.last_match(1) }
    src.scan(/alias_method\s*\(?\s*:"?(#{FOREIGN_METHOD_NAME_RE})/o) { names << Regexp.last_match(1) }
    src.scan(/define_method\s*\(?\s*:"?(#{FOREIGN_METHOD_NAME_RE})/o) { names << Regexp.last_match(1) }
  end
  names
end

# ---------------------------------------------------------------------------
# ENTRY_ARG_CALLSITE_PROOF's out-of-closed-world poison source: can anything
# outside the closed world CALL this name? A `mrb_funcall(M, obj,
# "tile_color", ...)` in C++ or a call in 3rd/mruby/mrblib is a site whose
# argument cannot be proven, and one unseen site makes the proof wrong.
#
# Deliberately blunt: a name is poisoned if it appears as any identifier token
# in those files at all (call, definition, comment, ...). Over-collecting costs
# a proof; under-collecting emits an unchecked mrb_fixnum(). It needs no model
# of C++ or of mruby's dispatch surface. Operator names are refused by the
# mechanism itself (its `\A[A-Za-z_]` gate).
#
# Read as bytes: some mruby C sources are not valid UTF-8, and String#scan on
# an invalid string raises. The pattern is ASCII, so the matches are the same.
# ---------------------------------------------------------------------------
OUTSIDE_TOKEN_RE = /[A-Za-z_][A-Za-z_0-9]*[?!=]?/.freeze

def outside_world_tokens(paths)
  names = Set.new
  Array(paths).each do |path|
    src = begin
      File.binread(path)
    rescue StandardError
      next
    end
    src.scan(OUTSIDE_TOKEN_RE) { |t| names << t }
  end
  names
end

def extract_native_method_names(src_paths)
  names = Set.new
  # MRB_SYM(name) is the bare name, MRB_OPSYM(op) an operator (OPSYM_TO_RUBY).
  # presym.h also defines MRB_SYM_Q -> "name?", MRB_SYM_B -> "name!" and
  # MRB_SYM_E -> "name=", which core uses constantly (Array#empty?, Kernel#nil?,
  # ...). Missing them made names like :empty? look MONO (Game::MoveRoute#empty?
  # devirtualized `@commands.empty?` into itself). The longer SYM_Q/SYM_B/SYM_E
  # alternatives must come before bare SYM in the regex, or SYM matches first
  # and "_Q(empty)" is left unconsumed.
  Array(src_paths).each do |path|
    # A missing path (an uninitialized submodule) contributes nothing: that only
    # costs a missed proof or MONO->POLY flip. Rescued broadly like the other
    # native-source readers; an unreadable file is equally unusable.
    src = begin
      File.read(path, encoding: 'UTF-8')
    rescue StandardError
      next
    end
    # Multi-line call shapes match too; the regex ignores newlines between args.
    src.scan(/mrb_define_(?:method|class_method|module_function)\s*\(\s*\w+\s*,\s*\w+\s*,\s*"((?:[^"\\]|\\.)*)"/m) do |name|
      names << unescape_c_string(name.first)
    end

    # MRB_MT_ENTRY(fn, MRB_SYM(name), flags) / MRB_MT_ENTRY(fn, MRB_OPSYM(op), flags)
    # -- mruby core's own ROM method-table idiom.
    src.scan(/MRB_MT_ENTRY\s*\(\s*\w+\s*,\s*#{MRB_SYM_TOKEN_RE}/) { |tok| names << resolve_mrb_sym_token(tok[0], tok[1]) }

    # mrb_define_method_id(mrb, klass, MRB_SYM(name)/MRB_OPSYM(op), func, aspec)
    # (and the _class_method_id/_module_function_id siblings) -- the direct-call
    # form some core mrbgems (mruby-task, ...) use instead of a ROM table.
    src.scan(/mrb_define_(?:method|class_method|module_function)_id\s*\(\s*\w+\s*,\s*\w+\s*,\s*#{MRB_SYM_TOKEN_RE}/) do |tok|
      names << resolve_mrb_sym_token(tok[0], tok[1])
    end

    # mrb_define_method_raw(mrb, klass, MRB_SYM/MRB_OPSYM, m) (src/class.c
    # bob_init) installs a prebuilt mrb_method_t, sometimes a hand-written RProc.
    # Without it `!=` would have no definition at all, and native_only_mono? (which
    # needs a `<native>` entry) could never fire for it. Only the literal-token
    # calls (Class#new, BasicObject#!=, Proc#call/[]) are matchable; the rest pass
    # runtime values.
    src.scan(/mrb_define_method_raw\s*\(\s*\w+\s*,\s*\w+\s*,\s*#{MRB_SYM_TOKEN_RE}/) do |tok|
      names << resolve_mrb_sym_token(tok[0], tok[1])
    end
  end
  names
end

# ZSUPER_NATIVE_SUPPORT: like extract_native_method_names, but keeps which
# source file contributed each name. The registry wants the flat set, but
# ZSUPER_NATIVE_TARGETS must know whether the `<native>` definition of a name is
# the one mruby-core function being reproduced or some other gem's. Each path
# is still read once; the driver derives the flat set from this map.
def extract_native_method_sources(src_paths)
  sources = Hash.new { |h, k| h[k] = [] }
  Array(src_paths).each do |path|
    extract_native_method_names([path]).each { |name| sources[name] << path }
  end
  sources
end

# Method names native C/C++ *calls* by literal name (mrb_funcall family, a
# string or MRB_SYM-family token). Feeds only the "never called" diagnostic,
# never codegen.
# Uses a bounded non-greedy lookahead instead of an argument split, because
# the receiver argument is often itself a call with commas. A false match only
# adds a name to the "reachable" set, which is safe here.
def extract_native_call_names(src_paths)
  names = Set.new
  Array(src_paths).each do |path|
    # Same missing-path skip as extract_native_method_names; a missed call name
    # only costs a diagnostic line.
    src = begin
      File.read(path, encoding: 'UTF-8')
    rescue StandardError
      next
    end
    src.scan(/mrb_funcall(?:_id|_argv|_with_block)?\s*\(.{0,200}?(?:"((?:[^"\\]|\\.)*)"|#{MRB_SYM_TOKEN_RE})/m) do |str, macro, sym|
      names << (str ? unescape_c_string(str) : resolve_mrb_sym_token(macro, sym))
    end
  end
  names
end

# ---------------------------------------------------------------------------
# NATIVE_CONSTRUCT_SCHEMA_AUDIT: derive each NATIVE_CONSTRUCT_TARGETS row's
# (arity, arg_type) from the native `mrb_get_args` format string and compare it
# with the hand-written row. A row narrower than the format (Tone's "|ffff"
# vs arity 4) is conservative and passes; a wider row or a type disagreement
# is reported as MISMATCH. Audit-only: never consulted by codegen.
#
# Every failure mode (lambda init, Ruby-defined initialize, missing or
# unrecognized format, non-uniform types) resolves to :unresolved, so MISMATCH
# always means a real disagreement read off the source.
# ---------------------------------------------------------------------------
module NativeConstructSchema
  # mrb_get_args format characters -> NATIVE_CONSTRUCT_TARGETS arg_type tokens.
  # `i` is int-coerced; pass-through arguments are :object. `*` and `&` add no
  # position. Anything else makes the derivation :unresolved.
  FORMAT_TYPES = {
    'i' => :int, 'f' => :float,
    'o' => :object, 'n' => :object, 's' => :object, 'S' => :object,
    'c' => :object, 'b' => :object, 'z' => :object, 'p' => :object,
    'C' => :object, 'a' => :object, 'A' => :object, 'Z' => :object,
  }.freeze

  # `"|o"` -> ([0, 1], :object); `"ii"` -> ([2, 2], :int); `"i|ii"` -> ([1, 3],
  # :int). Non-uniform types and unknown characters are nil: a single-arg_type
  # row cannot express them.
  def self.derive(format)
    return nil unless format =~ /\A[|oifnscbzpCaAZ*!&]*\z/

    pre, post = format.split('|', 2)
    req = post.nil? ? pre : pre + post
    min = pre.delete('*&').length
    max = post.nil? ? min : min + post.delete('*&').length
    types = req.delete('*&').chars.map { |c| FORMAT_TYPES[c] }
    return nil if types.any?(&:nil?) || types.uniq.size > 1

    [[min, max], types.first || :object]
  end

  # The brace-matched body of C++ function `fn`, or nil. Literals and comments
  # are skipped so a `}` in them does not end the match. First definition wins;
  # a wrong body can only produce a MISMATCH, never a miscompile.
  def self.fn_body(src, fn)
    idx = 0
    loop do
      i = src.index(fn, idx)
      return nil unless i

      rest = src[i..]
      m = rest.match(/\A#{Regexp.escape(fn)}\s*\([^)]*\)\s*\{/)
      if m
        depth = 0
        j = i + m[0].length - 1
        start = j
        in_str = nil
        in_line = false
        in_block = false
        prev = nil
        src[start..].each_char.with_index do |ch, k|
          nxt = src[start + k + 1]
          if in_line
            in_line = false if ch == "\n"
          elsif in_block
            in_block = false if prev == '*' && ch == '/'
          elsif in_str
            in_str = nil if ch == in_str && prev != '\\'
          elsif ch == '"' || ch == "'"
            in_str = ch
          elsif ch == '/' && nxt == '/'
            in_line = true
          elsif ch == '/' && nxt == '*'
            in_block = true
          elsif ch == '{'
            depth += 1
          elsif ch == '}'
            depth -= 1
            return src[start..(start + k)] if depth.zero?
          end
          prev = ch
        end
        return nil
      end
      idx = i + 1
    end
  end

  # Scrape [init_fn, format] for native class `klass`: the class variable from
  # mrb_define_class_under, the init from mrb_define_method(..., "initialize",
  # FN), the format from FN's first mrb_get_args. nil means :unresolved.
  def self.scrape(native_paths, klass)
    Array(native_paths).each do |path|
      src = begin
        File.read(path, encoding: 'UTF-8')
      rescue StandardError
        next
      end
      cm = src.match(/(\w+)\s*=\s*mrb_define_class_under\s*\(\s*\w+\s*,\s*\w+\s*,\s*"#{Regexp.escape(klass)}"/)
      next unless cm

      im = src.match(/mrb_define_method\s*\(\s*\w+\s*,\s*#{Regexp.escape(cm[1])}\s*,\s*"initialize"\s*,\s*(\w+)/)
      next unless im

      body = fn_body(src, im[1])
      next unless body

      fm = body.match(/mrb_get_args\s*\(\s*\w+\s*,\s*"([^"]*)"/)
      next unless fm

      return [im[1], fm[1]]
    end
    nil
  end

  # :ok (arities within the derived range, types agree), :mismatch (with
  # details) or :unresolved.
  def self.audit(native_paths, klass, row)
    scraped = scrape(native_paths, klass)
    return [:unresolved, 'no (init_fn, format) scraped'] unless scraped

    fn, fmt = scraped
    derived = derive(fmt)
    return [:unresolved, "#{fn} format #{fmt.inspect} underivable"] unless derived

    (range, type) = derived
    arities = Array(row[:arity])
    unless arities.all? { |a| a.between?(range[0], range[1]) }
      return [:mismatch, "#{fn} format #{fmt.inspect} admits #{range[0]}..#{range[1]}, row pins #{arities.inspect}"]
    end
    unless row[:arg_type] == type
      return [:mismatch, "#{fn} format #{fmt.inspect} is #{type.inspect}, row says #{row[:arg_type].inspect}"]
    end

    [:ok, "#{fn} #{fmt.inspect}"]
  end
end

# Opcodes that print a READ-only register as their first `R<n>` operand --
# see IvarLayout.trace_type's own `when *READ_ONLY_OPCODE_SKIP` arm.
READ_ONLY_OPCODE_SKIP = %w[RETURN RETURN_BLK BREAK JMPIF JMPNOT JMPNIL RAISEIF MATCHERR SETUPVAR].freeze

# ---------------------------------------------------------------------------
# Step 6b: ivar embedding: which ivars can move out of iv_tbl into typed C
# struct fields on an RData payload.
#
# An ivar is embeddable as type T when EVERY SETIV of it, in every method of
# every class (closed world), traces (through MOVEs, within one method body)
# to a source that is always T: a literal, a proven arithmetic result, or an
# ivar already known to be T. One opaque source or a type mismatch makes it
# permanently dynamic.
#
# A fixed point: `@count = @count + 1` needs initialize's `@count = 0` to be
# known first, so all methods are swept until the type map stops changing.
class IvarLayout
  UNKNOWN = :unknown

  # `arg_types` (ArgTypes.analyze) and `annotations` (Annotations.extract) can
  # only make more ivars embeddable, never fewer. Annotations also reach
  # #initialize, which ArgTypes cannot.
  def self.analyze(ireps, registry, arg_types = {}, annotations = {}, integer_constants = nil,
                    fixnum_return_names = nil)
    # class -> labels of its leaf methods. Native MethodDefs have no irep and are
    # skipped.
    methods_of = Hash.new { |h, k| h[k] = [] }
    registry.each_value { |defs| defs.each { |d| methods_of[d.owner] << d.irep if d.irep } }
    # irep label -> MethodDef, so a trace ending at an incoming argument can look
    # up that method's name/arity.
    def_of_irep = {}
    registry.each_value { |defs| defs.each { |d| def_of_irep[d.irep] = d if d.irep } }

    types = Hash.new { |h, k| h[k] = {} } # class_name -> {ivar_name => type or UNKNOWN}

    10.times do
      changed = false
      methods_of.each do |klass, irep_labels|
        irep_labels.each do |label|
          irep = ireps.fetch(label)
          d = def_of_irep[label]
          enter = irep.instructions.find { |i| i.op == 'ENTER' }
          mand = enter ? enter.args.split(':').first.to_i : 0
          irep.instructions.each_with_index do |insn, idx|
            next unless insn.op == 'SETIV'
            ivar = insn.args[/@(\w+)/, 1]
            # Not `$`-anchored: "SETIV @x R1 ; R1:v" carries a trailing local-name comment
            # whenever the source is a named local.
            src_reg = insn.args[/R(\d+)/, 1]
            inferred = trace_type(irep, idx, src_reg, types[klass], arg_types, mand, d&.name, annotations, registry,
                                   integer_constants, fixnum_return_names)
            before = types[klass][ivar]
            merged = join(before, inferred)
            if merged != before
              types[klass][ivar] = merged
              changed = true
            end
          end
        end
      end
      break unless changed
    end

    # Only embeddable (non-UNKNOWN) entries matter to codegen.
    types.each_with_object({}) do |(klass, ivars), out|
      embeddable = ivars.reject { |_, t| t == UNKNOWN }
      out[klass] = embeddable unless embeddable.empty?
    end
  end

  # Two contributions must agree or the ivar is poisoned to UNKNOWN, and UNKNOWN
  # joins to UNKNOWN from either side. The sweep has no fixed order across
  # methods, so dropping an UNKNOWN because a concrete type arrived first would
  # make the result order-dependent and unsound (it wrongly embedded ivars in
  # Game::Screen and Game::State; see ADR 0139).
  def self.join(a, b)
    return b if a.nil?
    return UNKNOWN if b == UNKNOWN || b.nil?
    return UNKNOWN if a != b

    a
  end

  # Walk back from `idx` for the last writer of `reg`, following MOVEs, until a
  # type-determining opcode or the top of the body (an incoming argument).
  def self.trace_type(irep, idx, reg, known_ivar_types, arg_types = nil, mand = 0, method_name = nil, annotations = nil,
                       registry = nil, integer_constants = nil, fixnum_return_names = nil)
    (idx - 1).downto(0) do |i|
      insn = irep.instructions[i]
      case insn.op
      when 'MOVE'
        d, s = insn.args.scan(/R(\d+)/).flatten
        next unless d == reg

        reg = s
      when /^LOADI/
        d = insn.args[/^R(\d+)/, 1]
        next unless d == reg

        return :fixnum
      when 'LOADSYM'
        d = insn.args[/^R(\d+)/, 1]
        next unless d == reg
        # A Symbol is as safe to embed as a Fixnum: an mrb_sym is an interned id, not a
        # GC object (symbol.c frees the table only at mrb_close). See CodeGen::TYPE_OPS.
        return :symbol
      when 'LOADNIL'
        d = insn.args[/^R(\d+)/, 1]
        next unless d == reg

        return UNKNOWN
      when 'LOADTRUE', 'LOADFALSE'
        # BOOL_EMBED_SUPPORT: LOADT/LOADF. true/false are immediates in every boxing
        # this project targets (word, no-float, nan), so an mrb_bool field needs no GC
        # keep-alive. See CodeGen::TYPE_OPS :bool.
        d = insn.args[/^R(\d+)/, 1]
        next unless d == reg

        return :bool
      when 'GETCONST', 'GETMCNST'
        # INTEGER_CONST_EMBED_SUPPORT: `@x = SOME_CONST` is Fixnum when
        # IntegerConstants.analyze admitted the bare name (the proof GETCONST's fast
        # path trusts). `integer_constants` is nil for callers that never ran the scan
        # (ArgTypes), and then nothing is proven. GETMCNST keys on the bare name after
        # `::`; see IntegerConstants.analyze for why that is required.
        d = insn.args[/^R(\d+)/, 1]
        next unless d == reg

        name = insn.op == 'GETCONST' ? insn.args.split(/\s+/)[1] : insn.args[/::(\S+)/, 1]
        return :fixnum if name && integer_constants&.include?(name)

        return UNKNOWN
      when 'ADD', 'ADDI'
        d = insn.args[/^R(\d+)/, 1]
        next unless d == reg
        # ADD/ADDI's destination holds a Fixnum on this prototype's fast path (see
        # CodeGen#compile_insn).
        return :fixnum
      when 'SUB', 'MUL'
        d = insn.args[/^R(\d+)/, 1]
        next unless d == reg

        # FIXNUM_SUBMUL_EMBED_SUPPORT: SUB/MUL (vm.c OP_MATH) dispatch on both operand
        # types, so they are Fixnum only when both operands are proven Fixnum
        # recursively. Overflow could make the value wrong but not the type, and the
        # embedded SETIV re-checks the type before storing (TypeError, not memory
        # corruption).
        s = insn.args[/\(R(\d+)\)/, 1]
        if s
          left = trace_type(irep, i, d, known_ivar_types, arg_types, mand, method_name, annotations, registry, integer_constants, fixnum_return_names)
          right = trace_type(irep, i, s, known_ivar_types, arg_types, mand, method_name, annotations, registry, integer_constants, fixnum_return_names)
          return :fixnum if left == :fixnum && right == :fixnum
        end
        return UNKNOWN
      when 'SUBI'
        d = insn.args[/^R(\d+)/, 1]
        next unless d == reg

        # FIXNUM_SUBMUL_EMBED_SUPPORT for the immediate form: only the destination's
        # prior value needs proving.
        return trace_type(irep, i, d, known_ivar_types, arg_types, mand, method_name, annotations, registry, integer_constants, fixnum_return_names)
      when 'GETIV'
        d = insn.args[/^R(\d+)/, 1]
        next unless d == reg

        other_ivar = insn.args[/@(\w+)/, 1]
        return known_ivar_types[other_ivar] || UNKNOWN
      when 'SEND', 'SEND0', 'SSEND', 'SSEND0'
        d = insn.args[/^R(\d+)/, 1]
        next unless d == reg

        # FIXNUM_BINOP_EMBED_SUPPORT: %, &, |, ^ never promote to Bignum (like
        # compile_send's FIXNUM_BINARY fast path; +/-/* and << can overflow). Sound only
        # when both operands are proven Fixnum AND the operator has no override
        # anywhere (native_only_mono?).
        name = insn.args[/:([\w+\-*\/<>=!?\[\]&|^~%@]+)/, 1]
        n = insn.args[/n=(\d+)/, 1]
        if registry && %w[% & | ^].include?(name) && n == '1' && native_only_mono?(registry, name)
          arg_reg = (d.to_i + 1).to_s
          left = trace_type(irep, i, d, known_ivar_types, arg_types, mand, method_name, annotations, registry, integer_constants, fixnum_return_names)
          right = trace_type(irep, i, arg_reg, known_ivar_types, arg_types, mand, method_name, annotations, registry, integer_constants, fixnum_return_names)
          return :fixnum if left == :fixnum && right == :fixnum
        end

        # FIXNUM_RETURN_IVAR_HINT: a send of a name in FIXNUM_RETURN_PROOF's set
        # leaves a Fixnum in its destination for any receiver: that proof already
        # requires exactly one MethodDef, so the call either raises NoMethodError or
        # reaches that definition. No native_only_mono? re-check needed.
        # `fixnum_return_names` is nil for callers without a CodeGen (ArgTypes).
        return :fixnum if name && fixnum_return_names&.include?(name)

        return UNKNOWN
      when *READ_ONLY_OPCODE_SKIP
        # READ_ONLY_OPCODE_SKIP: these opcodes print a register as their first `R%d`
        # token but only READ it (mruby/ops.h: RETURN/RETURN_BLK "return R[a]", BREAK,
        # JMPIF/JMPNOT/JMPNIL "if R[a] ...", RAISEIF, MATCHERR, SETUPVAR
        # "uvset(b,c,R[a])"; codedump.c prints them that way). Skipping a non-writer is
        # as sound as skipping a MOVE to another register. Without this an early
        # `return v if v == @flag` stopped the trace for a later `@flag = v`.
        # SETUPVAR's `b`/`c` are slot/level numbers in an ancestor frame, not this
        # irep's registers, so its only `R` token is a same-frame read.
      when 'RESCUE'
        # RESCUE is `R[b] = R[a].isa?(R[b])` (ops.h), printed `RESCUE\tR%d\tR%d`: the
        # write lands on the SECOND register. `a` is a read; `b` is a real write and
        # must stop the trace like the generic `else`.
        a, b = insn.args.scan(/R(\d+)/).flatten
        return UNKNOWN if b == reg
        next unless a == reg
      else
        # Any other opcode's first operand is almost always its destination, so stop
        # at UNKNOWN. Skipping an unrecognized writer could reach an unrelated earlier
        # write to a reused register and misattribute its type.
        d = insn.args[/^R(\d+)/, 1]
        return UNKNOWN if d == reg
      end
    end
    # Never written in this block: an incoming argument. Register N is argument N
    # for N <= mand (as in CodeGen#compile_method). Use ArgTypes' whole-program
    # inference if it has one; otherwise the value is opaque.
    pos = reg.to_i
    if pos.between?(1, mand)
      # An annotation is per-definition (keyed by irep), so it is trusted whether
      # the name is MONO or POLY; tried first.
      # EMBED_TYPE_SAFETY: only :fixnum and :symbol pass. Other tokens (:array) have
      # no TYPE_OPS entry, and letting them through surfaced later as a KeyError in
      # GETIV/SETIV codegen of an unrelated owner.
      t = annotations && annotations[irep.label]&.args&.[](pos - 1)
      return t if t == :fixnum || t == :symbol

      t = arg_types && method_name && arg_types[method_name]&.[](pos - 1)
      return t if t
    end
    UNKNOWN
  end

  # Same guarantee as CodeGen#native_only_mono?, duplicated because that one
  # reads CodeGen's @registry. `fetch`, not `[]`: the default proc would insert
  # `name` while analyze iterates the registry (a name can have no def since
  # docs/adr/0203).
  def self.native_only_mono?(registry, name)
    defs = registry.fetch(name) { return false }
    defs.size == 1 && defs.first.irep.nil?
  end
end

# ---------------------------------------------------------------------------
# Step 6c: whole-program call-site argument-type inference. For a MONO name
# every call site reaches the one definition, so if every caller's argument
# at position k traces to Fixnum (IvarLayout.trace_type), position k is Fixnum.
# POLY names are skipped: their call sites may target different methods.
# Feeds IvarLayout's incoming-argument fallback.
class ArgTypes
  def self.analyze(ireps, registry)
    types = {}

    registry.each do |name, defs|
      next unless defs.size == 1 # MONO names only -- see this class's own comment.
      next unless defs.first.irep # native-only definition -- no bytecode body to walk.

      irep = ireps.fetch(defs.first.irep)
      enter = irep.instructions.find { |i| i.op == 'ENTER' }
      mand = enter ? enter.args.split(':').first.to_i : 0
      next if mand.zero?

      arg_types = Array.new(mand)
      ireps.each_value do |caller_irep|
        caller_irep.instructions.each_with_index do |insn, idx|
          next unless %w[SEND0 SEND SSEND0 SSEND].include?(insn.op)
          # Same charset as compile_send's name extraction (so operator names match).
          next unless insn.args[/:([\w+\-*\/<>=!?\[\]&|^~%@]+)/, 1] == name

          d = insn.args[/^R(\d+)/, 1].to_i
          n = insn.args[/n=(\d+)/, 1].to_i
          next unless n == mand # a real call site to a MONO name always matches its one definition's arity.

          (1..mand).each do |k|
            # No caller ivar context here: a GETIV-sourced argument traces to UNKNOWN,
            # which is safe.
            t = IvarLayout.trace_type(caller_irep, idx, (d + k).to_s, {}, nil, 0, nil, nil, registry)
            arg_types[k - 1] = IvarLayout.join(arg_types[k - 1], t)
          end
        end
      end

      types[name] = arg_types.map { |t| t == IvarLayout::UNKNOWN ? nil : t }
    end

    types
  end
end

# ---------------------------------------------------------------------------
# Step 6d: magic-comment argument-type annotations, for what ArgTypes cannot
# see: #initialize's arguments (`X.new` is a native SEND :new, never SEND
# :initialize). An annotation sits on one `def`, so it is sound for POLY names
# too. Syntax, on the line above the def (blank lines skipped):
#   # bc2cpp: (fixnum, fixnum) -> fixnum
#   def initialize(x, y)
# mrbc drops comments, so the interpreted path is unaffected. A wrong
# annotation cannot corrupt memory: every embedded SETIV re-checks the type
# and raises TypeError. Only fixnum/Integer and symbol tokens mean anything
# for arguments; other tokens contribute nothing.
class Annotations
  TYPES = { 'fixnum' => :fixnum, 'Fixnum' => :fixnum, 'Integer' => :fixnum,
            'symbol' => :symbol, 'Symbol' => :symbol, 'Array' => :array }.freeze
  COMMENT_RE = /^\s*#\s*bc2cpp:\s*\(([^)]*)\)(?:\s*->\s*(\S+))?\s*$/

  Annotation = Struct.new(:args, :ret, keyword_init: true)

  # `:array` (the `Array` token) feeds ONLY the block-receiver return-type gate
  # (annotated_array_return; the emitter's mrb_array_p tripwire checks it at
  # runtime). It must never reach struct-field codegen: native_arg_types has no
  # `:array` arm (KeyError, fail-loud), and IvarLayout.trace_type filters
  # annotation args to :fixnum/:symbol (see EMBED_TYPE_SAFETY there).

  # irep label -> Annotation, for every real `def` (any registry entry with
  # a bytecode body -- a native MethodDef's `irep` is nil, nothing to
  # annotate) whose immediately-preceding source line matches COMMENT_RE.
  def self.extract(ireps, registry)
    result = {}
    file_lines = Hash.new { |h, path| h[path] = File.readlines(path, encoding: 'UTF-8') }

    registry.each_value do |defs|
      defs.each do |d|
        next unless d.irep

        irep = ireps.fetch(d.irep)
        next unless irep.file

        enter = irep.instructions.find { |i| i.op == 'ENTER' }
        next unless enter

        lines = file_lines[irep.file]
        # `enter.lineno` is the `def` line (1-indexed); the annotation is on the
        # preceding non-blank line.
        idx = enter.lineno - 2
        idx -= 1 while idx >= 0 && lines[idx].strip.empty?
        next if idx < 0

        m = COMMENT_RE.match(lines[idx])
        next unless m

        arg_types = m[1].split(',').map { |t| TYPES[t.strip] }
        # ELEMENT_CLASS_SUPPORT: `-> Array<Klass>` is still an `Array` return here; the
        # element half is read separately by ElementAnnotations. Stripping `<...>`
        # keeps `-> Array<Klass>` a strict superset of `-> Array`, and an unknown inner
        # class degrades to plain `-> Array`.
        ret_token = m[2]&.sub(/<.*>\z/, '')
        ret_type = ret_token && TYPES[ret_token]
        result[irep.label] = Annotation.new(args: arg_types, ret: ret_type)
      end
    end

    result
  end
end

# ---------------------------------------------------------------------------
# Step 6f: class-name argument annotations. Same `# bc2cpp: (...)` syntax as
# Annotations, separate reader and claim: "this argument is always exactly this
# class". Never shares Annotations' TYPES: a class name must not reach
# IvarLayout's embedding lattice (no C type to unbox into; C_TYPE.fetch would
# raise). Both readers can share one comment line, since each ignores the
# other's tokens.
class ClassAnnotations
  Annotation = Struct.new(:args, keyword_init: true)

  # `known_owners` (every owner in the registry) gates a token as a class hint,
  # so a random capitalized word is not one. `Array<Klass>`/`Hash<Klass>` read as
  # the outer container class even without registry methods for it;
  # ElementAnnotations handles the inner class.
  def self.extract(ireps, registry, known_owners)
    result = {}
    file_lines = Hash.new { |h, path| h[path] = File.readlines(path, encoding: 'UTF-8') }

    registry.each_value do |defs|
      defs.each do |d|
        next unless d.irep

        irep = ireps.fetch(d.irep)
        next unless irep.file

        enter = irep.instructions.find { |i| i.op == 'ENTER' }
        next unless enter

        lines = file_lines[irep.file]
        idx = enter.lineno - 2
        idx -= 1 while idx >= 0 && lines[idx].strip.empty?
        next if idx < 0

        m = Annotations::COMMENT_RE.match(lines[idx])
        next unless m

        args = m[1].split(',').map do |token|
          token = token.strip
          container_arg = /\A(Array|Hash)<([A-Za-z_][\w:]*)>\z/.match(token)
          token = container_arg[1] if container_arg && %w[Array Hash].include?(container_arg[1]) &&
                                      known_owners.include?(container_arg[2])
          token if known_owners.include?(token) || %w[Array Hash].include?(token)
        end
        next if args.all?(&:nil?)

        result[irep.label] = Annotation.new(args: args)
      end
    end

    result
  end
end

# ---------------------------------------------------------------------------
# Step 6f-ter: ELEMENT_CLASS_SUPPORT, the third reader of the `# bc2cpp:`
# comment: element classes of array results and array arguments.
#   # bc2cpp: () -> Array<Game::Actor>
#   def stat_targets(cmd)
#   # bc2cpp: (Array<Game::Actor>)
#   def initialize(actors)
# Separate from Annotations::TYPES because a class name has no C type.
# `known_owners` gates the inner token; an unknown name contributes nothing.
#
# Trust model (as annotated_array_return): a hand-placed claim, made sound by
# (1) every consumer guarding it at runtime with the exact
# `mrb_class_ptr(...) == mrb_obj_class(M, elem)` check and falling back to
# mrb_funcall, so a wrong claim only costs a failed guard; and (2)
# ArrayElementLayout re-deriving the fact and poisoning on disagreement.
# Two claims from the `-> T` token:
#   - `-> Array<Game::Actor>` (`element`): an Array whose elements are exactly
#     Game::Actor;
#   - `-> Game::Actor` (`ret_class`): the result itself is exactly that class
#     (trace_new_target has no return-type inference, so this is the only
#     source for e.g. what `Game::Actors#[]` returns).
# Both mean "every non-nil value is exactly this class". A nil always fails
# the guard (mrb_obj_class(nil) is NilClass), so nil-returning methods can be
# annotated truthfully.
# `ret_class` also feeds the guarded TYPED tracer; GETIDX/GETIDX0 are included
# because mrbc emits them for `receiver[index]`.
class ElementAnnotations
  Annotation = Struct.new(:element, :ret_class, :arg_elements, :arg_containers, keyword_init: true)

  # One `::`-joined class path, spelled like build_registry's owners. Anchored,
  # so a heterogeneous `Array<Foo, Bar>` does not match.
  ELEMENT_RE = /\AArray<([A-Za-z_][\w:]*)>\z/
  ARG_ELEMENT_RE = /\A(?:Array|Hash)<([A-Za-z_][\w:]*)>\z/
  RET_CLASS_RE = /\A([A-Za-z_][\w:]*)\z/

  # Tokens that already mean something to Annotations::TYPES must not also read
  # as a return class. `Array` is a registry owner (mruby-rgss reopens it), so a
  # plain `-> Array` would otherwise gain a second meaning.
  NON_CLASS_RET_TOKENS = (Annotations::TYPES.keys + ['Array']).uniq.freeze

  # irep label -> Annotation, for defs whose comment has a recognized element or
  # return-class token.
  def self.extract(ireps, registry, known_owners)
    result = {}
    file_lines = Hash.new { |h, path| h[path] = File.readlines(path, encoding: 'UTF-8') }

    registry.each_value do |defs|
      defs.each do |d|
        next unless d.irep

        irep = ireps.fetch(d.irep)
        next unless irep.file

        enter = irep.instructions.find { |i| i.op == 'ENTER' }
        next unless enter

        lines = file_lines[irep.file]
        idx = enter.lineno - 2
        idx -= 1 while idx >= 0 && lines[idx].strip.empty?
        next if idx < 0

        m = Annotations::COMMENT_RE.match(lines[idx])
        next unless m

        arg_elements = m[1].split(',').map do |arg|
          em = ARG_ELEMENT_RE.match(arg.strip)
          em && known_owners.include?(em[1]) ? em[1] : nil
        end
        arg_containers = m[1].split(',').map do |arg|
          cm = /\A(Array|Hash)<([A-Za-z_][\w:]*)>\z/.match(arg.strip)
          cm && known_owners.include?(cm[2]) ? cm[1] : nil
        end

        element = nil
        ret_class = nil
        if m[2]
          tok = m[2]
          if (em = ELEMENT_RE.match(tok))
            element = em[1] if known_owners.include?(em[1])
          elsif !NON_CLASS_RET_TOKENS.include?(tok) && (rm = RET_CLASS_RE.match(tok))
            ret_class = rm[1] if known_owners.include?(rm[1])
          end
        end
        next unless element || ret_class || arg_elements.any?

        result[irep.label] = Annotation.new(element: element, ret_class: ret_class,
                                            arg_elements: arg_elements, arg_containers: arg_containers)
      end
    end

    result
  end
end

# ---------------------------------------------------------------------------
# Step 6f-bis: the shared "this expression is a proven fresh Array" rule, used
# by Step 6g's SETIV sites and (via CodeGen#proven_array_source) by every
# block recognizer, so the two cannot drift apart.
# ---------------------------------------------------------------------------
# INTERP_UNLOCK: when the static Array trace misses, the nearest write to the
# register (following MOVEs) proves an Array when it is:
#   - a block-carrying `select`/`reject`/`map` (CHAINED_ARRAY_METHODS);
#   - a MONO method with a `-> Array` annotation (annotated_array_return);
#   - a core method verified to return a fresh Array and not redefined in this
#     program (core_array_return?).
# Sound because of SKIP_UNSUPPORTED's per-method partitioning: a producer with
# any gap drops the whole method to the interpreter.
#
# CORE_ARRAY_CHAIN block gate: these three count only from SENDB/SSENDB. A
# blockless map/select/reject returns an Enumerator in mruby (enum.rb:
# `return to_enum(...) unless block`), and an attr_reader is always a
# blockless send; the bare-name rule misclassified `@map = map || state.map`
# (Game::State#map is an attr_accessor) as Array.
# Known narrowing: select/reject on a Hash returns a Hash (hash.rb). Every
# block consumer has an mrb_array_p raise-tripwire and ClassLayout readers
# re-check the class at runtime.
CHAINED_ARRAY_METHODS = %w[select reject map].freeze

# CORE_ARRAY_CHAIN: core methods that return a fresh Array whenever they
# return. Admitted only after core_array_return? confirms nothing in this
# program redefines the name (so a future `def keys` withdraws the claim).
# Verified against 3rd/mruby:
#   - keys/values: mrb_hash_keys/mrb_hash_values (src/hash.c);
#   - compact: ary_compact (mruby-array-ext), a dup;
#   - flatten: ary_flatten -> flatten_internal, a new Array;
#   - split: String#split (src/string.c);
#   - uniq: Array#uniq (dup / __uniq) and Enumerable#uniq (hash.values).
# A receiver without the method raises before returning, and every site
# still passes the emitter's mrb_array_p tripwire.
# Not here: to_a/dup (receiver-dependent), to_h (Hash), blockless sort_by
# (CORE_ARRAY_CHAIN_NEEDS_BLOCK), argless first/last
# (CORE_ARRAY_CHAIN_NEEDS_ARG).
CORE_ARRAY_RETURN_METHODS = %w[keys values compact flatten split uniq].freeze

# CORE_ARRAY_CHAIN: a fresh Array only with an explicit argument (n >= 1):
# src/array.c mrb_ary_first/mrb_ary_last return an ELEMENT with no argument
# and ary_subseq/mrb_ary_new_from_values with one. Neither is redefined in
# this program.
CORE_ARRAY_CHAIN_NEEDS_ARG = %w[first last].freeze

# CORE_ARRAY_CHAIN: a fresh Array only with a block: Array#sort_by and
# Enumerable#sort_by (mruby-enum-ext) both `return to_enum(:sort_by) unless
# block`.
CORE_ARRAY_CHAIN_NEEDS_BLOCK = %w[sort_by].freeze

# CORE_ARRAY_CHAIN: vetted bytecode overrides, by exact Owner#name (a bare name
# here would defeat core_array_return?). mruby-rgss/mrblib/array_sort.rb
# redefines Array#sort; both of its paths return `_rgss_native_sort` (mruby's
# Array#sort, `self.dup.sort!`), and Enumerable#sort returns an Array too.
VETTED_ARRAY_RETURN_OVERRIDES = Set['Array#sort'].freeze

# CORE_ARRAY_CHAIN: does `name`'s fresh-Array claim hold against this
# program's registry? Every MethodDef must be mruby core (`'<native>'`;
# mruby-rgss/src defines none of these names) or a vetted override. No entry
# at all (uniq, sort_by live in mruby's mrblib) is fine too.
# This rejects attr_reader/attr_accessor defs (real owner, no irep):
# Game::State#map is one, so "no bytecode body" is not "cannot be redefined".
def core_array_return?(name, block_carrying, registry, argc: 0)
  vetted_by_name = VETTED_ARRAY_RETURN_OVERRIDES.any? { |o| o.end_with?("##{name}") }
  if CORE_ARRAY_CHAIN_NEEDS_BLOCK.include?(name)
    return false unless block_carrying
  elsif CORE_ARRAY_CHAIN_NEEDS_ARG.include?(name)
    return false unless argc >= 1
  elsif !CORE_ARRAY_RETURN_METHODS.include?(name) && !vetted_by_name
    return false
  end

  (registry[name] || []).all? do |md|
    md.owner == '<native>' || VETTED_ARRAY_RETURN_OVERRIDES.include?("#{md.owner}##{md.name}")
  end
end

# ARRAY_RETURN_PROOF: `ret_proof` is an optional second oracle ("a call to
# this name leaves an Array"), beside the `-> Array` annotation. nil keeps the
# old behavior (ClassLayout's SETIV call has no CodeGen). See
# CodeGen#compute_array_return_names.
# Consulted only for non-block sends: a `break` in the caller's block makes
# the send evaluate to the BREAK operand (ops.h OP_BREAK). Same argument as
# compute_fixnum_return_names.
def proven_array_source_scan(irep, idx, dest_reg, registry, annotated = nil, ret_proof = nil)
  reg = dest_reg
  (idx - 1).downto(0) do |i|
    pin = irep.instructions[i]
    next unless pin
    # The block proc register (BLOCK writes dest+1) sits between the call and its
    # receiver write; skip it.
    next if pin.op == 'BLOCK'
    next unless pin.args[/^R(\d+)/, 1] == reg

    # CORE_ARRAY_CHAIN: follow MOVE (`regs[a] = regs[b]`, vm.c OP_MOVE) to the
    # register actually written. Skipping a MOVE would let the scan reach an older,
    # overwritten result on a reused register.
    if pin.op == 'MOVE'
      src = pin.args.scan(/R(\d+)/).flatten[1]
      return nil unless src

      reg = src
      next
    end
    return nil unless %w[SEND SSEND SENDB SSENDB SEND0 SSEND0].include?(pin.op)

    called = pin.args[/:([\w+\-*\/<>=!?\[\]&|^~%@]+)/, 1]
    return nil unless called

    block_carrying = %w[SENDB SSENDB].include?(pin.op)
    # SEND0/SSEND0 print no `n=` field: absent means 0 args.
    argc = pin.args[/n=(\d+)/, 1]&.to_i || 0
    return 'Array' if block_carrying && CHAINED_ARRAY_METHODS.include?(called)
    return 'Array' if annotated&.call(called)
    return 'Array' if core_array_return?(called, block_carrying, registry, argc: argc)
    # ARRAY_RETURN_PROOF: non-block sends only (see ret_proof above).
    return 'Array' if !block_carrying && ret_proof&.call(called)

    return nil
  end
  nil
end

# ---------------------------------------------------------------------------
# Step 6g: whole-program "this ivar always holds exactly this class" analysis,
# the object-reference analogue of IvarLayout. Never an embedding candidate:
# it only feeds compile_send's devirtualization, which guards every use with a
# runtime mrb_obj_class check.
# A fixed point, because one ivar's class can depend on another's.
class ClassLayout
  UNKNOWN = :unknown

  # ANY_OPAQUE_SUPPORT: see ArrayElementLayout.analyze's `poison_reason`.
  # ARRAY_RETURN_IVAR_HINT: `array_ret_proof` (compute_array_return_names) is
  # passed to proven_array_source_scan as `ret_proof`.
  # RETCLASS_SELF_CALL_SUPPORT: `ret_class_proof` (compute_class_return_names)
  # is passed to trace_new_target. Both default to nil (old behavior), which is
  # also what the driver's first probing pass passes; see that call site for
  # the stratification.
  def self.analyze(ireps, registry, class_annotations = {}, container_constants = {}, annotated_array_return = nil,
                    poison_reason: nil, array_ret_proof: nil, ret_class_proof: nil)
    methods_of = Hash.new { |h, k| h[k] = [] }
    registry.each_value { |defs| defs.each { |d| methods_of[d.owner] << d.irep if d.irep } }

    classes = Hash.new { |h, k| h[k] = {} } # owner -> {ivar_name => class_name or UNKNOWN}

    10.times do
      changed = false
      methods_of.each do |owner, irep_labels|
        irep_labels.each do |label|
          irep = ireps.fetch(label)
          enter = irep.instructions.find { |i| i.op == 'ENTER' }
          mand = enter ? enter.args.split(':').first.to_i : 0
          arg_classes = class_annotations[label]&.args

          irep.instructions.each_with_index do |insn, idx|
            next unless insn.op == 'SETIV'

            ivar = insn.args[/@(\w+)/, 1]
            src_reg = insn.args[/R(\d+)/, 1]
            # Never hand an UNKNOWN entry to trace_new_target's GETIV lookup.
            known_so_far = classes[owner].reject { |_, c| c == UNKNOWN }
            # CHAINED_ACCESSOR_SUPPORT: the full, unfiltered in-progress table, so another
            # class's ivar hints can be read; trace_new_target itself refuses UNKNOWN
            # entries from it.
            found = trace_new_target(irep, idx, src_reg, known_so_far, mand, arg_classes, owner: owner,
                                      class_layout: classes, registry: registry,
                                      container_constants: container_constants,
                                      ret_class_proof: ret_class_proof)
            # CORE_ARRAY_CHAIN: when the trace misses, ask proven_array_source_scan. It
            # only answers 'Array' for an expression that allocates a new Array, the same
            # kind of fact as an ARRAY literal. It runs only where the trace gave up, and
            # the join still poisons on any disagreeing site.
            # ANNOTATED_ARRAY_RETURN_THREADING: `annotated_array_return` is the same
            # MONO-keyed `-> Array` lookup the block recognizers use (see
            # CodeGen#annotated_array_return), so a self-call to an annotated method
            # (`@base = base_stats(1)`) is Array evidence here too.
            # ARRAY_RETURN_IVAR_HINT: `array_ret_proof` makes a non-block call to a method
            # proven to return an Array count as Array evidence (Game::Battle#@queue =
            # turn_order). Monotone: it only turns UNKNOWN into 'Array'; the join is
            # unchanged, and LOADNIL writes still reach NIL_TOLERANT_JOIN.
            found ||= proven_array_source_scan(irep, idx, src_reg, registry, annotated_array_return,
                                               array_ret_proof)

            # NIL_TOLERANT_JOIN: `@x = nil` (LOADNIL Rn; SETIV @x Rn) is evidence of
            # nothing, so it is skipped rather than joined. Poisoning on it would kill
            # every ivar that #initialize nils out. Sound because every consumer re-checks
            # the class at runtime and falls back to mrb_funcall. IvarLayout (embedding) is
            # separate and still treats nilable ivars as unembeddable.
            next if found.nil? && nil_literal_write?(irep, idx, src_reg)

            found ||= UNKNOWN

            before = classes[owner][ivar]
            # Disagreeing sites poison to UNKNOWN, sticky across passes.
            merged = if before.nil?
                       found
                     elsif before == UNKNOWN || found == UNKNOWN || before != found
                       UNKNOWN
                     else
                       before
                     end
            if merged != before
              classes[owner][ivar] = merged
              if merged == UNKNOWN && poison_reason
                # See `poison_reason` (same :any/:opaque split as ArrayElementLayout).
                (poison_reason[owner] ||= {})[ivar] = found == UNKNOWN ? :opaque : :any
              end
              changed = true
            end
          end
        end
      end
      break unless changed
    end

    classes
  end

  # analyze's result minus UNKNOWN entries and empty owners. The raw result is
  # kept so poisoned ivars can be reported (`== ivar-class candidates (poisoned
  # to unknown) ==`); every consumer sees only this filtered shape.
  def self.known(classes)
    classes.each_with_object({}) do |(owner, ivars), out|
      known = ivars.reject { |_, c| c == UNKNOWN }
      out[owner] = known unless known.empty?
    end
  end

  def self.unknowns(classes)
    classes.flat_map { |owner, ivars| ivars.select { |_, c| c == UNKNOWN }.keys.map { |i| "#{owner}#@#{i}" } }
  end

  # ANY_OPAQUE_SUPPORT: same filter as ArrayElementLayout.unknowns_by_reason.
  def self.unknowns_by_reason(classes, poison_reason, reason)
    unknowns(classes).select do |name|
      owner, ivar = name.split('#@', 2)
      poison_reason.dig(owner, ivar) == reason
    end
  end
end

# ---------------------------------------------------------------------------
# Step 6g-bis: ELEMENT_CLASS_SUPPORT: "every element of this Array ivar is
# exactly class X", so calls on an inlined loop's element register can be
# devirtualized (`party.each { |a| a.dead? }`).
#
# Not a proof: the sweep sees only this program's bytecode, and an Array is
# mutable through aliases (`party.actors.push(x)`). Mutations it can attribute
# (ARRAY_ELEMENT_WRITERS on a receiver tracing to `GETIV @x` in the owner) are
# checked; unattributable ones are a named residual. That is harmless because
# every consumer re-checks `mrb_class_ptr(...) == mrb_obj_class(M, elem)` and
# falls back to mrb_funcall. The table is never used to embed, pick a C type or
# skip a check.
# A fixed point (ten passes, sticky UNKNOWN join), as in ClassLayout.
# ---------------------------------------------------------------------------

# ELEMENT_CLASS_SUPPORT: core methods whose result's elements are a subset (or
# permutation) of the receiver's: compact, uniq, sort, reverse, dup (verified
# in 3rd/mruby); plus first/last with an argument, take/drop, and block-carrying
# select/reject (they push the element itself). dup is fine here because the
# receiver is already known to be an Array. map/collect/flat_map replace
# elements and have their own rule.
ARRAY_ELEMENT_PRESERVING = %w[compact uniq sort reverse dup].freeze
ARRAY_ELEMENT_PRESERVING_NEEDS_ARG = %w[first last take drop].freeze
ARRAY_ELEMENT_PRESERVING_NEEDS_BLOCK = %w[select reject].freeze

# ELEMENT_CLASS_SUPPORT: core methods returning one ELEMENT of the receiver:
# `[]`/`at`/`fetch` with one argument (`a[i, n]`/`a[range]` return Arrays),
# argless first/last (mrb_ary_first/mrb_ary_last), sample, min, max.
ARRAY_ELEMENT_INDEXERS_NEEDS_ARG = %w[[] at fetch].freeze
ARRAY_ELEMENT_INDEXERS_NO_ARG = %w[first last sample min max].freeze

# ELEMENT_CLASS_SUPPORT: every in-place element writer. All must agree, or
# `@a = []` followed by `@a.push(x)` would "prove" a class from the empty
# literal.
#   - push/<</unshift: every argument is an element;
#   - insert: every argument after the index;
#   - []=: with two arguments `v` is an element; three (splice) poisons;
#   - concat/replace: the argument is an Array; recurse on it.
# Any other listed writer, or an unmodeled shape, poisons the ivar.
ARRAY_ELEMENT_WRITERS = %w[push << unshift insert []= concat replace fill collect! map! flatten! sort_by!].freeze

# HASH_ELEMENT_SUPPORT: Hash VALUE writers only (the payoff is the value in
# `hash.each { |k, v| v.foo }`). `h[k] = v` compiles to SETIDX (see
# HashElementLayout.analyze); this list covers the explicit `h.[]=(k, v)` /
# `h.store(k, v)` spellings (both hash_set, src/hash.c). No preserving-chain
# rule; unmodeled shapes poison.
HASH_ELEMENT_WRITERS = %w[[]= store].freeze

# PRIMITIVE_ELEMENT_SUPPORT: element tags element_value_class returns for
# literal primitives. `.known` strips them explicitly: consumers
# (with_element_hint et al.) only guard with mrb_obj_class and were never meant
# to receive them. Diagnostic only, distinct from ELEM_HINT and ELEM_CANDIDATE
# (ANY/OPAQUE; see ArrayElementLayout.analyze).
PRIMITIVE_ELEMENT_CLASSES = %w[Integer Hash String Symbol].freeze

# ELEMENT_CLASS_SUPPORT: element class of the Array in `reg` at `idx`, built
# like proven_array_source_scan (nearest write, MOVEs followed, nil on anything
# unmodelled). nil is always safe: the caller poisons the ivar.
def array_element_source_scan(irep, idx, dest_reg, ctx, depth = 0)
  # Two ivars can reference each other (`@a = @b.compact`, `@b = @a.compact`),
  # so the depth cap makes termination local to this function.
  return nil if depth > 8

  reg = dest_reg
  (idx - 1).downto(0) do |i|
    insn = irep.instructions[i]
    next unless insn

    # Skip the block proc register (see proven_array_source_scan).
    next if insn.op == 'BLOCK'
    next unless insn.args[/^R(\d+)/, 1] == reg

    case insn.op
    when 'MOVE'
      src = insn.args.scan(/R(\d+)/).flatten[1]
      return nil unless src

      reg = src
      next
    when 'ARRAY', 'ARRAY2'
      # "ARRAY R3 2": N consecutive registers from Rd.
      # An EMPTY literal is VACUOUS, not unknown: it satisfies "every element is X"
      # for every X, so it must not poison (nearly every array ivar starts as
      # `@x = []`). VACUOUS is skipped by the join, so an ivar whose only site is
      # `[]` gets no entry.
      n = insn.args[/^R\d+\s+(\d+)/, 1]&.to_i
      return nil if n.nil?
      return ArrayElementLayout::VACUOUS if n.zero?

      base = reg.to_i
      classes = (0...n).map { |k| element_value_class(irep, i, (base + k).to_s, ctx, depth + 1) }
      return nil if classes.any?(&:nil?) || classes.uniq.size != 1

      return classes.first
    when 'GETIV'
      ivar = insn.args[/@(\w+)/, 1]
      return nil unless ivar

      return ivar_element_hint(ctx[:owner], ivar, ctx)
    when 'SEND', 'SEND0', 'SENDB', 'SSENDB', 'SSEND', 'SSEND0'
      return send_element_class(irep, i, reg, insn, ctx, depth)
    else
      return nil
    end
  end
  # An `Array<Klass>` argument annotation counts only when the walk reaches the
  # untouched incoming argument register; consumers still guard each element.
  pos = reg.to_i
  return ctx[:arg_elements][pos - 1] if ctx[:arg_elements] && pos.between?(1, ctx[:mand])

  nil
end

# HASH_ELEMENT_SUPPORT: VALUE class of the Hash in `reg` at `idx`. Narrower
# than array_element_source_scan: only a literal and a chained ivar read, plus
# MOVE-following; nil on anything else.
def hash_element_source_scan(irep, idx, dest_reg, ctx, depth = 0)
  return nil if depth > 8

  reg = dest_reg
  (idx - 1).downto(0) do |i|
    insn = irep.instructions[i]
    next unless insn

    next if insn.op == 'BLOCK'
    next unless insn.args[/^R(\d+)/, 1] == reg

    case insn.op
    when 'MOVE'
      src = insn.args.scan(/R(\d+)/).flatten[1]
      return nil unless src

      reg = src
      next
    when 'HASH'
      # "HASH R2 2": N key/value PAIRS from Rd (vm.c OP_HASH sets regs[i] =>
      # regs[i+1]), so values are at odd offsets Rd+1, Rd+3, ... An empty literal is
      # VACUOUS, as in array_element_source_scan.
      n = insn.args[/^R\d+\s+(\d+)/, 1]&.to_i
      return nil if n.nil?
      return HashElementLayout::VACUOUS if n.zero?

      base = reg.to_i
      classes = (0...n).map { |k| element_value_class(irep, i, (base + 2 * k + 1).to_s, ctx, depth + 1) }
      return nil if classes.any?(&:nil?) || classes.uniq.size != 1

      return classes.first
    when 'GETIV'
      ivar = insn.args[/@(\w+)/, 1]
      return nil unless ivar

      return ivar_hash_element_hint(ctx[:owner], ivar, ctx)
    else
      return nil
    end
  end
  nil
end

# ELEMENT_CLASS_SUPPORT: the SEND arm of the scan above.
def send_element_class(irep, i, reg, insn, ctx, depth)
  # Same charset as compile_send's own name extraction (see its comment).
  name = insn.args[/:([\w+\-*\/<>=!?\[\]&|^~%@]+)/, 1]
  return nil unless name

  block_carrying = %w[SENDB SSENDB].include?(insn.op)
  # SEND0/SSEND0 print no "n=": zero arguments.
  argc = insn.args[/n=(\d+)/, 1]&.to_i || 0
  self_recv = %w[SSEND SSEND0 SSENDB].include?(insn.op)

  # A `-> Array<Klass>` annotation is trusted only when its irep is the only
  # definition of the name (else the call may reach another method).
  annotated = ctx[:annotated_element]&.call(name)
  return annotated if annotated

  # A preserving chain yields the receiver's elements. SSEND has no receiver
  # register to trace.
  preserving =
    ARRAY_ELEMENT_PRESERVING.include?(name) ||
    (ARRAY_ELEMENT_PRESERVING_NEEDS_ARG.include?(name) && argc >= 1) ||
    (ARRAY_ELEMENT_PRESERVING_NEEDS_BLOCK.include?(name) && block_carrying)
  if preserving
    return nil if self_recv

    return array_element_source_scan(irep, i, reg, ctx, depth + 1)
  end

  # `map`/`collect` with a block: elements are the block's yielded values (see
  # block_return_class). `flat_map` splices, so it is excluded.
  if block_carrying && %w[map collect].include?(name) && argc.zero?
    block_irep = adjacent_block_irep(irep, i, reg, ctx)
    return nil unless block_irep

    return block_return_class(block_irep, ctx, depth + 1)
  end

  if block_carrying && name == 'filter_map' && argc.zero?
    block_irep = adjacent_block_irep(irep, i, reg, ctx)
    return nil unless block_irep

    input_class = array_element_source_scan(irep, i - 1, reg, ctx, depth + 1)
    return filter_map_block_return_class(block_irep, ctx, depth + 1, input_class)
  end

  # CHAINED_ACCESSOR_SUPPORT, element dimension (`@state.party.actors`): the
  # receiver resolves to class R, R defines the name as an :ivar_accessor, and
  # R's entry in this table names an element class. Same check as
  # trace_new_target's chained-accessor branch.
  return nil if self_recv || argc.positive? || block_carrying

  recv_class = traced_owner(irep, i, reg, ctx)
  return nil unless recv_class

  accessor = ctx[:registry][name]&.find { |md| md.owner == recv_class && md.kind == :ivar_accessor }
  return nil unless accessor

  ivar_element_hint(recv_class, name, ctx)
end

# ELEMENT_CLASS_SUPPORT: read the in-progress table without returning UNKNOWN.
# `key?` because `[]` on the `Hash.new { {} }` table would insert an entry and
# perturb the diagnostic ordering.
def ivar_element_hint(owner, ivar, ctx)
  table = ctx[:elements]
  return nil unless owner && ivar && table&.key?(owner)

  hint = table[owner][ivar]
  return nil if hint.nil? || hint == ArrayElementLayout::UNKNOWN

  hint
end

# HASH_ELEMENT_SUPPORT: ivar_element_hint for `ctx[:hash_elements]`.
def ivar_hash_element_hint(owner, ivar, ctx)
  table = ctx[:hash_elements]
  return nil unless owner && ivar && table&.key?(owner)

  hint = table[owner][ivar]
  return nil if hint.nil? || hint == HashElementLayout::UNKNOWN

  hint
end

# ELEMENT_CLASS_SUPPORT: the block irep of the SENDB at `i`, re-checking the
# `BLOCK R(a+1) I[k]` adjacency.
def adjacent_block_irep(irep, i, recv_reg, ctx)
  block_insn = i.positive? ? irep.instructions[i - 1] : nil
  return nil unless block_insn && block_insn.op == 'BLOCK'
  return nil unless block_insn.args[/^R(\d+)/, 1] == (recv_reg.to_i + 1).to_s

  k = block_insn.args[/I\[(\d+)\]/, 1]
  return nil unless k

  label = irep.reps[k.to_i]
  label && ctx[:ireps][label]
end

# ELEMENT_CLASS_SUPPORT: class of a `map` block's yielded value. Every RETURN
# must agree; RETNIL (a bare `next`), RETFALSE/RETTRUE or a break make the
# answer unknown, as does a block with no RETURN.
def block_return_class(block_irep, ctx, depth)
  # A block's `self` is the method's self, so owner and ivar hints carry over.
  # Its parameters are not method arguments: `mand: 0` disables the
  # argument-annotation terminal.
  irep_return_class(block_irep, ctx.merge(arg_classes: nil, mand: 0), depth)
end

# ELEMENT_CLASS_SUPPORT: filter_map drops falsy results, so nil/false exits
# are ignored; every other RETURN must prove the same class.
def filter_map_block_return_class(block_irep, ctx, depth, input_class)
  return nil if depth > 8

  found = nil
  subctx = ctx.merge(arg_classes: nil, mand: 0)
  block_irep.instructions.each_with_index do |insn, i|
    case insn.op
    when 'RETURN'
      reg = insn.args.strip.empty? ? '0' : insn.args[/^R(\d+)/, 1]
      previous = i.positive? ? block_irep.instructions[i - 1] : nil
      if previous && %w[LOADNIL LOADFALSE].include?(previous.op) && previous.args[/^R(\d+)/, 1] == reg
        next
      end

      klass = element_value_class(block_irep, i, reg, subctx, depth + 1)
      klass ||= input_class if block_mandatory_param_source?(block_irep, i, reg)
      return nil unless klass && ctx[:known_owners].include?(klass)
      return nil if found && found != klass

      found = klass
    when 'RETNIL', 'RETFALSE'
      # Both are discarded by filter_map's own truthiness check.
      next
    when 'RETTRUE', 'BREAK', 'RETURN_BLK'
      return nil
    end
  end
  found
end

def block_mandatory_param_source?(irep, idx, reg)
  enter = irep.instructions.find { |insn| insn.op == 'ENTER' }
  mandatory = enter ? enter.args.split(':').first.to_i : 0
  return false if mandatory.zero?

  current = reg
  (idx - 1).downto(0) do |i|
    insn = irep.instructions[i]
    next unless insn.args[/^R(\d+)/, 1] == current
    return false unless insn.op == 'MOVE'

    current = insn.args.scan(/R(\d+)/).flatten[1]
    return false unless current
  end
  current.to_i.between?(1, mandatory)
end

# ELEMENT_CLASS_SUPPORT: trace a register to a class the REGISTRY knows.
# trace_new_target returns bare names ("Actors" for `Actors.new` in
# Game::Party) while the registry says "Game::Actors", so an unresolved bare
# name is a dead hint. Resolve it like Ruby: lexical nesting innermost first,
# accepting only registry classes; otherwise nil.
# Kept local to this analysis: changing trace_new_target's result would change
# TYPED devirtualization everywhere.
def traced_owner(irep, idx, reg, ctx)
  cls = trace_new_target(irep, idx, reg, ctx[:ivar_classes], ctx[:mand], ctx[:arg_classes],
                         owner: ctx[:owner], class_layout: ctx[:class_layout], registry: ctx[:registry])
  resolve_owner_name(cls, ctx)
end

def resolve_owner_name(name, ctx)
  return nil unless name

  known = ctx[:known_owners]
  # Core containers are valid annotation targets without registry methods.
  return name if known.include?(name) || %w[Array Hash].include?(name)
  # Already qualified and unknown: no lexical search can help.
  return nil if name.include?('::')

  nesting = ctx[:owner].to_s.sub(/\.singleton\z/, '').split('::')
  nesting.length.downto(1) do |n|
    candidate = "#{nesting.first(n).join('::')}::#{name}"
    return candidate if known.include?(candidate)
  end
  nil
end

# ELEMENT_CLASS_SUPPORT: mandatory arity from ENTER, 0 if none.
def mand_of(ireps, label)
  enter = ireps.fetch(label).instructions.find { |i| i.op == 'ENTER' }
  enter ? enter.args.split(':').first.to_i : 0
end

# ELEMENT_CLASS_SUPPORT: every irep reachable through `reps`; `seen` guards
# against cycles.
def nested_block_labels(ireps, label, seen = Set.new)
  out = []
  stack = [label]
  until stack.empty?
    cur = stack.pop
    irep = ireps[cur]
    next unless irep

    (irep.reps || []).each do |child|
      next if child.nil? || seen.include?(child) || !ireps.key?(child)

      seen << child
      out << child
      stack << child
    end
  end
  out
end

# ELEMENT_CLASS_SUPPORT: the one class every RETURN of this irep hands back,
# or nil. Shared by block_return_class and mono_fresh_return_class.
def irep_return_class(irep, ctx, depth)
  return nil if depth > 8

  found = nil
  irep.instructions.each_with_index do |insn, i|
    case insn.op
    when 'RETURN'
      r = insn.args.strip.empty? ? '0' : insn.args[/^R(\d+)/, 1]
      cls = element_value_class(irep, i, r, ctx, depth)
      return nil unless cls
      return nil if found && found != cls

      found = cls
    when 'RETNIL', 'RETFALSE', 'RETTRUE', 'BREAK', 'RETURN_BLK'
      # nil/false/true is not an object class, and a non-local return leaves by a
      # path not read here.
      return nil
    end
  end
  found
end

# ELEMENT_CLASS_SUPPORT: return class of a call whose RECEIVER traces to one
# exact class, looked up class-exactly. Needed for names like `:[]`, which are
# POLY program-wide (Game::Party builds `@actors` from `@roster[i]`, and
# Game::Actors#[] returns a Game::Actor or nil).
# The class-exact definition counts when it has a `-> Klass` annotation or
# provably returns a fresh `Klass.new` on every path (X.new never allocates a
# subclass). Guarded downstream like every other fact here.
def receiver_scoped_return_class(irep, i, recv_reg, name, ctx, depth)
  return nil if depth > 8

  recv_class = traced_owner(irep, i, recv_reg, ctx)
  return nil unless recv_class

  class_scoped_return_class(recv_class, name, ctx, depth)
end

# ELEMENT_CLASS_SUPPORT: what `name` returns on an exact receiver class.
def class_scoped_return_class(recv_class, name, ctx, depth)
  return nil if depth > 8

  md = ctx[:registry][name]&.find { |m| m.owner == recv_class && m.irep }
  return nil unless md

  ann = ctx[:element_annotations][md.irep]&.ret_class
  return ann if ann

  callee = ctx[:ireps][md.irep]
  return nil unless callee

  sub = ctx.merge(owner: md.owner, ivar_classes: (ctx[:class_layout][md.owner] || {}),
                  mand: mandatory_arity(callee), arg_classes: ctx[:class_annotations][md.irep]&.args)
  irep_return_class(callee, sub, depth + 1)
end

# ELEMENT_CLASS_SUPPORT: the exact class of `self` in a method of `owner`,
# for implicit-self calls (`@members << member(db, m)`, where :member is POLY).
# Only answered when no class declares `owner` as its superclass (`subclassed`,
# from resolve_superclass_ref): a subclass instance could dispatch to an
# override. `.singleton` owners are refused: their self is the class object.
def self_receiver_class(ctx)
  owner = ctx[:owner]
  return nil if owner.nil? || owner.end_with?('.singleton')
  return nil unless ctx[:known_owners].include?(owner)
  return nil if ctx[:subclassed].include?(owner)

  owner
end

def mono_fresh_return_class(name, ctx, depth)
  defs = ctx[:registry][name]
  return nil unless defs && defs.size == 1 && defs.first.irep

  d = defs.first
  irep = ctx[:ireps][d.irep]
  return nil unless irep

  sub = ctx.merge(owner: d.owner, ivar_classes: (ctx[:class_layout][d.owner] || {}),
                  mand: mandatory_arity(irep), arg_classes: ctx[:class_annotations][d.irep]&.args)
  irep_return_class(irep, sub, depth + 1)
end

# ELEMENT_CLASS_SUPPORT: class of the SCALAR value in `reg` at `idx`, from:
#   1. trace_new_target (fresh `X.new`, known ivar, argument annotation,
#      chained accessor);
#   2. a `-> Klass` return annotation (ElementAnnotations);
#   3. an indexer on an array with a known element class (`@actors[i]`), which
#      lets a self-referential reorder (`@a = order.map { |i| @a[i] }`) agree
#      instead of poisoning.
def element_value_class(irep, idx, reg, ctx, depth = 0)
  return nil if depth > 8

  direct = traced_owner(irep, idx, reg, ctx)
  return direct if direct

  cur = reg
  (idx - 1).downto(0) do |i|
    insn = irep.instructions[i]
    next unless insn

    next if insn.op == 'BLOCK'
    next unless insn.args[/^R(\d+)/, 1] == cur

    if insn.op == 'MOVE'
      src = insn.args.scan(/R(\d+)/).flatten[1]
      return nil unless src

      cur = src
      next
    end

    # PRIMITIVE_ELEMENT_SUPPORT: a literal Integer/Hash/String/Symbol element.
    # Diagnostic only (`.known` strips these; see PRIMITIVE_ELEMENT_CLASSES): it
    # separates "provably Integer" from "untraceable" in the ANY/OPAQUE report.
    # LOADNIL is deliberately absent; a nil element was not a real shape here.
    case insn.op
    when 'HASH'
      return 'Hash'
    when 'STRING'
      return 'String'
    when /^LOADI/
      return 'Integer'
    when 'LOADSYM'
      return 'Symbol'
    end

    # ELEMENT_CLASS_SUPPORT: `a[i]` is an index opcode, not SEND :[] (the VM only
    # sends :[] for non-Array/Hash receivers), so element reads are recognized by
    # opcode. Receiver position differs:
    #   GETIDX  R2 (R3)      -- R[a] = R[a][R[a+1]]: receiver is R2 itself.
    #   GETIDX0 R7 R4[0]     -- R[a] = R[b][0]:      receiver is R4.
    #   AREF    R2 R6 0      -- R[a] = R[b][c]:      receiver is R6.
    if %w[GETIDX GETIDX0 AREF].include?(insn.op)
      recv = insn.op == 'GETIDX' ? cur : insn.args.scan(/R(\d+)/).flatten[1]
      return nil unless recv

      hit = array_element_source_scan(irep, i, recv, ctx, depth + 1)
      return hit if hit && hit != ArrayElementLayout::VACUOUS
      # Not a known-element array. For GETIDX/GETIDX0 the VM's non-Array/non-Hash
      # path is a real `:[]` send, so resolve it like one (`@roster[i]` on a
      # Game::Actors). AREF is excluded: its non-Array behavior (index 0 yields the
      # receiver) is destructuring, not a `:[]` dispatch.
      return nil if insn.op == 'AREF'

      return receiver_scoped_return_class(irep, i, recv, '[]', ctx, depth)
    end
    return nil unless %w[SEND SEND0 SENDB SSEND SSEND0 SSENDB].include?(insn.op)

    name = insn.args[/:([\w+\-*\/<>=!?\[\]&|^~%@]+)/, 1]
    return nil unless name

    annotated = ctx[:annotated_ret_class]&.call(name)
    return annotated if annotated

    argc = insn.args[/n=(\d+)/, 1]&.to_i || 0
    self_recv = %w[SSEND SSEND0 SSENDB].include?(insn.op)
    indexer =
      (ARRAY_ELEMENT_INDEXERS_NEEDS_ARG.include?(name) && argc == 1) ||
      (ARRAY_ELEMENT_INDEXERS_NO_ARG.include?(name) && argc.zero?)
    # An indexer on a known-element array. Allowed to miss (not fail) so
    # `@roster[i]` on a non-Array falls through to the receiver-scoped rule.
    if indexer && !self_recv
      hit = array_element_source_scan(irep, i, cur, ctx, depth + 1)
      return hit if hit && hit != ArrayElementLayout::VACUOUS
    end

    scoped = if self_recv
               sc = self_receiver_class(ctx)
               sc && class_scoped_return_class(sc, name, ctx, depth)
             else
               receiver_scoped_return_class(irep, i, cur, name, ctx, depth)
             end
    return scoped if scoped

    # Last resort: a MONO name whose body returns one exact class on every path.
    mono_fresh_return_class(name, ctx, depth)
  end
  nil
end

class ArrayElementLayout
  UNKNOWN = :unknown
  # "This site provably introduces no elements"; kept apart from unreadable (see
  # array_element_source_scan's ARRAY arm).
  VACUOUS = :vacuous

  # owner -> {ivar => element class}, only for ivars ClassLayout proved always
  # hold an Array (every consumer has already proved its receiver is an Array).
  # ANY_OPAQUE_SUPPORT: when given a Hash, `poison_reason` records, at the moment
  # an ivar first becomes UNKNOWN:
  #   :any    -- two traced sites disagree: provably heterogeneous; no
  #              annotation can help.
  #   :opaque -- some site could not be traced: a candidate for an annotation.
  # nil (the default) changes nothing.
  def self.analyze(ireps, registry, class_layout, class_annotations, element_annotations, superclass_of = {},
                    poison_reason: nil)
    methods_of = Hash.new { |h, k| h[k] = [] }
    registry.each_value { |defs| defs.each { |d| methods_of[d.owner] << d.irep if d.irep } }
    # Registry classes, used by resolve_owner_name for bare GETCONST tokens.
    known_owners = Set.new(registry.values.flatten.map(&:owner))
    # Classes some other class declares as its superclass (see
    # self_receiver_class). :none and unrecognized expressions are dropped.
    subclassed = Set.new(superclass_of.values.select { |v| v.is_a?(String) })

    # name -> element/return class, only for MONO names: an annotation sits on one
    # irep, so it can only speak for a call no other method could receive.
    mono_ann = lambda do |field|
      lambda do |name|
        defs = registry[name]
        next nil unless defs && defs.size == 1 && defs.first.irep

        element_annotations[defs.first.irep]&.public_send(field)
      end
    end
    annotated_element = mono_ann.call(:element)
    annotated_ret_class = mono_ann.call(:ret_class)

    elements = Hash.new { |h, k| h[k] = {} }

    10.times do
      changed = false
      methods_of.each do |owner, labels|
        array_ivars = (class_layout[owner] || {}).select { |_, c| c == 'Array' }.keys
        next if array_ivars.empty?

        labels.each do |label|
          # ELEMENT_CLASS_SUPPORT: sweep the method AND every nested block body.
          # Populating code often lives in blocks, which have no MethodDef
          # (`row.members.each { |_, m| @members << member(db, m) }`); stopping at the
          # method would miss those writers. Blocks share self, but their parameters are
          # not method arguments, so mand/arg_classes are zeroed (as in
          # block_return_class).
          sweep = [[label, mand_of(ireps, label), class_annotations[label]&.args,
                    element_annotations[label]&.arg_elements]]
          nested_block_labels(ireps, label).each { |bl| sweep << [bl, 0, nil, nil] }

          sweep.each do |(cur_label, mand, arg_classes, arg_elements)|
            irep = ireps.fetch(cur_label)
            ctx = { owner: owner, registry: registry, class_layout: class_layout, ireps: ireps,
                    class_annotations: class_annotations, element_annotations: element_annotations,
                    known_owners: known_owners, subclassed: subclassed,
                    ivar_classes: (class_layout[owner] || {}), mand: mand,
                    arg_classes: arg_classes, arg_elements: arg_elements, elements: elements,
                    annotated_element: annotated_element, annotated_ret_class: annotated_ret_class }

            irep.instructions.each_with_index do |insn, idx|
              found = nil
              ivar = nil
              if insn.op == 'SETIV'
                ivar = insn.args[/@(\w+)/, 1]
                next unless array_ivars.include?(ivar)

                src_reg = insn.args[/R(\d+)/, 1]
                found = array_element_source_scan(irep, idx, src_reg, ctx)
                # NIL_TOLERANT_JOIN (element dimension): `@x = nil` says nothing about the
                # elements; see ClassLayout.analyze.
                next if found.nil? && nil_literal_write?(irep, idx, src_reg)
              # SSEND/SSENDB excluded: their receiver is self, and the `^R` register is the
              # destination.
              elsif %w[SEND SEND0 SENDB].include?(insn.op)
                name = insn.args[/:([\w+\-*\/<>=!?\[\]&|^~%@]+)/, 1]
                next unless name && ARRAY_ELEMENT_WRITERS.include?(name)

                recv = insn.args[/^R(\d+)/, 1]
                ivar = mutated_ivar_target(irep, idx, recv)
                next unless ivar && array_ivars.include?(ivar)

                found = written_element_class(irep, idx, insn, recv, name, ctx)
              elsif insn.op == 'SETIDX'
                # ELEMENT_CLASS_SUPPORT: `@a[0] = x` is OP_SETIDX, not SEND :[]=.
                # "SETIDX R4 (R5) (R6)" is `R[a][R[a+1]] = R[a+2]`: receiver R4, element R6.
                recv, _i_reg, val = insn.args.scan(/R(\d+)/).flatten
                next unless recv && val

                ivar = mutated_ivar_target(irep, idx, recv)
                next unless ivar && array_ivars.include?(ivar)

                found = element_value_class(irep, idx, val, ctx, 1)
              else
                next
              end

              # An element-free site (`@x = []`) must not reach the join.
              next if found == VACUOUS

              found ||= UNKNOWN
              before = elements[owner][ivar]
              # Sticky join as in ClassLayout: disagreement or an unreadable site poisons
              # permanently. Never a majority vote.
              merged = if before.nil?
                         found
                       elsif before == UNKNOWN || found == UNKNOWN || before != found
                         UNKNOWN
                       else
                         before
                       end
              if merged != before
                elements[owner][ivar] = merged
                if merged == UNKNOWN && poison_reason
                  # First poisoning: `found == UNKNOWN` means some site was never traced
                  # (:opaque); otherwise two traced sites conflict (:any).
                  (poison_reason[owner] ||= {})[ivar] = found == UNKNOWN ? :opaque : :any
                end
                changed = true
              end
            end
          end
        end
      end
      break unless changed
    end

    elements
  end

  # analyze's result minus UNKNOWN and empty owners. Kept separate so poisoned
  # entries can be reported (`== array-element candidates ==`).
  def self.known(table)
    table.each_with_object({}) do |(owner, ivars), out|
      # PRIMITIVE_ELEMENT_SUPPORT: primitive tags are dropped too; CodeGen consumers
      # only guard with mrb_obj_class against registry classes.
      known = ivars.reject { |_, c| c == UNKNOWN || PRIMITIVE_ELEMENT_CLASSES.include?(c) }
      out[owner] = known unless known.empty?
    end
  end

  # PRIMITIVE_ELEMENT_SUPPORT: diagnostic-only counterpart of `.known`, so
  # provably-primitive ivars are not listed with the OPAQUE ones.
  def self.primitives(table)
    table.each_with_object({}) do |(owner, ivars), out|
      prim = ivars.select { |_, c| PRIMITIVE_ELEMENT_CLASSES.include?(c) }
      out[owner] = prim unless prim.empty?
    end
  end

  def self.unknowns(table)
    table.flat_map { |owner, ivars| ivars.select { |_, c| c == UNKNOWN }.keys.map { |i| "#{owner}#@#{i}" } }
  end

  # ANY_OPAQUE_SUPPORT: `.unknowns` split by `poison_reason`; a filter over
  # `.unknowns` so the two cannot disagree.
  def self.unknowns_by_reason(table, poison_reason, reason)
    unknowns(table).select do |name|
      owner, ivar = name.split('#@', 2)
      poison_reason.dig(owner, ivar) == reason
    end
  end
end

# ELEMENT_CLASS_SUPPORT: the ivar a mutation's receiver names: back-scan to a
# `GETIV @x` in this body (following MOVEs), else nil. nil means "not
# attributed" (the aliasing residual in this section's header), not "no
# mutation".
def mutated_ivar_target(irep, idx, reg)
  return nil unless reg

  (idx - 1).downto(0) do |i|
    insn = irep.instructions[i]
    next unless insn

    next if insn.op == 'BLOCK'
    next unless insn.args[/^R(\d+)/, 1] == reg

    return insn.args[/@(\w+)/, 1] if insn.op == 'GETIV'

    if insn.op == 'MOVE'
      src = insn.args.scan(/R(\d+)/).flatten[1]
      return nil unless src

      reg = src
      next
    end
    return nil
  end
  nil
end

# ELEMENT_CLASS_SUPPORT: element class one in-place mutation writes, or nil
# (poison). See ARRAY_ELEMENT_WRITERS for the argument layouts.
def written_element_class(irep, idx, insn, recv, name, ctx)
  # A splat call ("n=*") has no fixed register list, so it poisons.
  n_match = insn.args.match(/n=(\d+|\*)/)
  return nil if n_match && n_match[1] == '*'

  argc = n_match ? n_match[1].to_i : 0
  base = recv.to_i
  arg_regs = (1..argc).map { |k| (base + k).to_s }

  value_regs =
    case name
    when 'push', '<<', 'unshift' then arg_regs
    when 'insert' then argc >= 2 ? arg_regs.drop(1) : nil
    when '[]=' then argc == 2 ? [arg_regs.last] : nil
    when 'concat', 'replace'
      return nil unless argc == 1

      # The argument is an Array: ask the same scan about it.
      return array_element_source_scan(irep, idx, arg_regs.first, ctx, 1)
    end
  return nil if value_regs.nil? || value_regs.empty?

  classes = value_regs.map { |r| element_value_class(irep, idx, r, ctx, 1) }
  return nil if classes.any?(&:nil?) || classes.uniq.size != 1

  classes.first
end

# HASH_ELEMENT_SUPPORT: value class written by `h[]=`/`h.store` (both
# hash_set, src/hash.c, same (key, value) layout): arity must be 2; read the
# second argument.
def written_hash_element_class(irep, idx, insn, recv, ctx)
  n_match = insn.args.match(/n=(\d+|\*)/)
  return nil unless n_match && n_match[1] == '2'

  val_reg = (recv.to_i + 2).to_s
  element_value_class(irep, idx, val_reg, ctx, 1)
end

# HASH_ELEMENT_SUPPORT: "every VALUE of this Hash ivar is class X"
# (HASH_ELEM_HINT). Narrower than ArrayElementLayout: values only, no
# preserving-chain rule; unmodeled writers poison. Mirrors ArrayElementLayout's
# analyze/known/unknowns, kept as its own class rather than parameterized.
class HashElementLayout
  UNKNOWN = :unknown
  VACUOUS = :vacuous

  # owner -> {ivar => value class}, only for ivars ClassLayout proved are Hashes.
  # `array_elements` (ArrayElementLayout's finished raw table, so this must run
  # after it) lets `@h[k] = @roster[i]` resolve; empty means such chains poison.
  # ANY_OPAQUE_SUPPORT: `poison_reason` as in ArrayElementLayout.analyze.
  def self.analyze(ireps, registry, class_layout, class_annotations, element_annotations, array_elements = {},
                    superclass_of = {}, poison_reason: nil)
    methods_of = Hash.new { |h, k| h[k] = [] }
    registry.each_value { |defs| defs.each { |d| methods_of[d.owner] << d.irep if d.irep } }
    known_owners = Set.new(registry.values.flatten.map(&:owner))
    subclassed = Set.new(superclass_of.values.select { |v| v.is_a?(String) })

    mono_ann = lambda do |field|
      lambda do |name|
        defs = registry[name]
        next nil unless defs && defs.size == 1 && defs.first.irep

        element_annotations[defs.first.irep]&.public_send(field)
      end
    end
    annotated_element = mono_ann.call(:element)
    annotated_ret_class = mono_ann.call(:ret_class)

    hash_elements = Hash.new { |h, k| h[k] = {} }

    10.times do
      changed = false
      methods_of.each do |owner, labels|
        hash_ivars = (class_layout[owner] || {}).select { |_, c| c == 'Hash' }.keys
        next if hash_ivars.empty?

        labels.each do |label|
          # Transitive block-body sweep, as in ArrayElementLayout.analyze.
          sweep = [[label, mand_of(ireps, label), class_annotations[label]&.args]]
          nested_block_labels(ireps, label).each { |bl| sweep << [bl, 0, nil] }

          sweep.each do |(cur_label, mand, arg_classes)|
            irep = ireps.fetch(cur_label)
            ctx = { owner: owner, registry: registry, class_layout: class_layout, ireps: ireps,
                    class_annotations: class_annotations, element_annotations: element_annotations,
                    known_owners: known_owners, subclassed: subclassed,
                    ivar_classes: (class_layout[owner] || {}), mand: mand,
                    arg_classes: arg_classes, elements: array_elements, hash_elements: hash_elements,
                    annotated_element: annotated_element, annotated_ret_class: annotated_ret_class }

            irep.instructions.each_with_index do |insn, idx|
              found = nil
              ivar = nil
              if insn.op == 'SETIV'
                ivar = insn.args[/@(\w+)/, 1]
                next unless hash_ivars.include?(ivar)

                src_reg = insn.args[/R(\d+)/, 1]
                found = hash_element_source_scan(irep, idx, src_reg, ctx)
                # NIL_TOLERANT_JOIN (hash-value dimension); see ArrayElementLayout.analyze.
                next if found.nil? && nil_literal_write?(irep, idx, src_reg)
              # SSEND/SSENDB excluded, as in ArrayElementLayout.analyze.
              elsif %w[SEND SEND0 SENDB].include?(insn.op)
                name = insn.args[/:([\w+\-*\/<>=!?\[\]&|^~%@]+)/, 1]
                next unless name && HASH_ELEMENT_WRITERS.include?(name)

                recv = insn.args[/^R(\d+)/, 1]
                ivar = mutated_ivar_target(irep, idx, recv)
                next unless ivar && hash_ivars.include?(ivar)

                found = written_hash_element_class(irep, idx, insn, recv, ctx)
              elsif insn.op == 'SETIDX'
                # `h[k] = v` is OP_SETIDX: "SETIDX R4 (R5) (R6)", receiver R4, value R6 (the
                # key is not read).
                recv, _i_reg, val = insn.args.scan(/R(\d+)/).flatten
                next unless recv && val

                ivar = mutated_ivar_target(irep, idx, recv)
                next unless ivar && hash_ivars.include?(ivar)

                found = element_value_class(irep, idx, val, ctx, 1)
              else
                next
              end

              # A value-free site (`@h = {}`) is VACUOUS (see hash_element_source_scan).
              next if found == VACUOUS

              found ||= UNKNOWN
              before = hash_elements[owner][ivar]
              # Sticky join, as in ArrayElementLayout.analyze.
              merged = if before.nil?
                         found
                       elsif before == UNKNOWN || found == UNKNOWN || before != found
                         UNKNOWN
                       else
                         before
                       end
              if merged != before
                hash_elements[owner][ivar] = merged
                if merged == UNKNOWN && poison_reason
                  # See ArrayElementLayout.analyze's `poison_reason`.
                  (poison_reason[owner] ||= {})[ivar] = found == UNKNOWN ? :opaque : :any
                end
                changed = true
              end
            end
          end
        end
      end
      break unless changed
    end

    hash_elements
  end

  # As ArrayElementLayout.known, including the primitive-tag exclusion.
  def self.known(table)
    table.each_with_object({}) do |(owner, ivars), out|
      known = ivars.reject { |_, c| c == UNKNOWN || PRIMITIVE_ELEMENT_CLASSES.include?(c) }
      out[owner] = known unless known.empty?
    end
  end

  # As ArrayElementLayout.primitives.
  def self.primitives(table)
    table.each_with_object({}) do |(owner, ivars), out|
      prim = ivars.select { |_, c| PRIMITIVE_ELEMENT_CLASSES.include?(c) }
      out[owner] = prim unless prim.empty?
    end
  end

  def self.unknowns(table)
    table.flat_map { |owner, ivars| ivars.select { |_, c| c == UNKNOWN }.keys.map { |i| "#{owner}#@#{i}" } }
  end

  # As ArrayElementLayout.unknowns_by_reason.
  def self.unknowns_by_reason(table, poison_reason, reason)
    unknowns(table).select do |name|
      owner, ivar = name.split('#@', 2)
      poison_reason.dig(owner, ivar) == reason
    end
  end
end

# ---------------------------------------------------------------------------
# Step 6e: annotation-candidate report (diagnostic only): SETIV sites whose
# source is an untouched incoming mandatory argument not already resolved by
# ArgTypes or an annotation, i.e. where a magic comment would matter.
# ---------------------------------------------------------------------------

# Like IvarLayout.trace_type, but returns nil at any writer: non-nil means
# `reg` (after MOVEs) is a bare incoming argument.
def opaque_argument_position(irep, idx, reg, mand)
  (idx - 1).downto(0) do |i|
    insn = irep.instructions[i]
    if insn.op == 'MOVE'
      d, s = insn.args.scan(/R(\d+)/).flatten
      next unless d == reg

      reg = s
    else
      d = insn.args[/^R(\d+)/, 1]
      return nil if d == reg
    end
  end
  pos = reg.to_i
  pos.between?(1, mand) ? pos : nil
end

# The typed-_impl calling convention models plain mandatory arguments only.
# ENTER's aspec is m1:opt:rest:m2:key:kwrest:block; anything past m1
# (`def foo(n = 0)`, `*args`, keywords, `&block`) does not fit, and reading
# only m1 once produced a direct call with an extra argument. Shared with
# report_annotation_candidates so it counts what drop_unsafe_embeddings would
# accept (see pure_mandatory_arity?).

# Native RGSS classes (mruby-rgss/src/lib.cxx DataType<T>) whose `SEND :new`
# can be devirtualized ("MONO :new -> direct native construct" in compile_send)
# when trace_new_target proves the receiver class: a hand-written lib.cxx entry
# point (`fn`) builds T from the argument registers, behind a runtime
# class-identity check against `class_fn` (see compile_send).
#
# `arity` must match the call site exactly (no default filling); an Array
# lists several accepted counts. Other counts fall back to dynamic dispatch.
# `arg_type` (:int/:float, uniform per class, matching the lib.cxx structs) is
# how each argument is unboxed before calling `fn`, which takes native
# mrb_int/mrb_float; mrb_as_int/mrb_as_float raise the same TypeError they
# raised inside `fn`.
NATIVE_CONSTRUCT_TARGETS = {
  'Tone' => { fn: 'rgss::tone_new_direct', class_fn: 'rgss::native_tone_class', arity: 4, arg_type: :float },
  'Color' => { fn: 'rgss::color_new_direct', class_fn: 'rgss::native_color_class', arity: 4, arg_type: :float },
  'Rect' => { fn: 'rgss::rect_new_direct', class_fn: 'rgss::native_rect_class', arity: 4, arg_type: :int },
  # Sprite: spr_init is `mrb_get_args(M, "|o", &vp)` plus a fixed body that
  # rgss::sprite_new_direct (include/rgss_construct.hxx) reproduces. "|o" never
  # coerces or raises, so there is no TypeError behavior to preserve.
  'Sprite' => { fn: 'rgss::sprite_new_direct', class_fn: 'rgss::native_sprite_class', arity: [0, 1],
                arg_type: :object },
  # Bitmap: bmp_init_size is `mrb_get_args(M, "ii", ...)` + alloc_obj, which
  # rgss::bitmap_new_direct reproduces. Bitmap#initialize also accepts a String
  # (file load), so `type_guard: :int` checks mrb_integer_p on every argument and
  # falls back to mrb_funcall otherwise.
  'Bitmap' => { fn: 'rgss::bitmap_new_direct', class_fn: 'rgss::native_bitmap_class', arity: 2, arg_type: :int,
                type_guard: :int },
}.freeze

# bc2cpp-COMPILED classes whose `Owner.new` may become bc2cpp_direct_alloc +
# the compiled `#initialize` _impl (emit_direct_construct_decls), the compiled
# counterpart of NATIVE_CONSTRUCT_TARGETS. The arity comes from the real
# #initialize and is re-checked at the call site; only the class-identity
# accessor is implied (`class_fn`-style, guarding a reassigned constant).
#
# Hand-listed, not derived from compiled_gems.rb owners: each entry needs a
# gem-init-captured RClass* and accessor function in that gem's register.cxx.
#
# Soundness bar for an entry, re-checked live by compile_send:
#   - no `self.new`/`self.allocate` anywhere for the class (checked against
#     @registry every run);
#   - #initialize compiles clean with pure mandatory arity
#     (pure_mandatory_arity?), or, for the keyword path, mandatory + optional
#     + keyword parameters (mandatory_optional_and_keyword_arity?,
#     compile_keyword_direct_construct);
#   - the call site's argument count matches.
# A site whose enclosing method does not compile is dropped with it
# (SKIP_UNSUPPORTED is per method), so an entry can be listed with no active
# site. #initialize is always private (src/class.c), which does not matter: a
# direct call bypasses the visibility lookup, as Class#new does.
# Receivers written relative to the enclosing module (`Scene::Map` inside
# `module RPG2k`) are resolved by lexically_resolve_construct_target, which
# only returns members of this table and refuses cross-level ambiguity.
# Classes whose #initialize has `= default` arguments and no keywords
# (Game::Vehicle, Game::Character, ...) are omitted: they could never fire.
DIRECT_CONSTRUCT_TARGETS = %w[Game::Transition Game::Map
                               Game::Switches Game::Timer Game::MessageConfig
                               Game::Screen Game::ChipSet Game::Interpreter
                               RPG2k::Scene::Menu RPG2k::Scene::DebugMenu
                               RPG2k::Scene::ItemMenu Game::NumberInput
                               Game::MoveRoute RPG2k::Scene::Map
                               RPG2k::Scene::MapViewer
                               RPG2k::Scene::ChipsetEditor
                               Game::Battle].freeze

# NATIVE_ARG_TARGETS (the Set after sanitize_c_ident below): human-vetted
# "Owner#name" allowlist that moves a compiled method's mandatory argument
# from mrb_value to a native mrb_int/mrb_sym parameter. A position is retyped
# only when BOTH the method is listed AND its own `# bc2cpp: (fixnum, ...)`
# annotation (never ArgTypes inference) names fixnum/symbol there. Annotations
# alone would be sound (a wrong one raises TypeError), but the native entry
# unboxes with mrb_get_args("i")/mrb_as_int, which raise on nil, so each entry
# must meet this bar:
#   - no nil-guard on the annotated position (`id.nil? || ...`, `x && x > 0`):
#     such a body tolerates nil today and would start raising
#     (Game::Actor#knows_skill?/#learn_skill, Game::EnemyAi#enemy and
#     RPG2k::Scene::Base#value_font_color are excluded for this);
#   - either the position already raises on a non-Integer (unguarded
#     arithmetic/comparison, so only the exception class changes), or every
#     real caller was traced to a provably Integer/Symbol value (needed for
#     "assign-only" bodies like `@x = x`);
#   - the method compiles clean with pure mandatory arity; otherwise there is
#     no `_impl` to retype and the entry is moot. Check the generated BODY,
#     not just the signature: the `_impl` signature is printed even when the
#     body is all `#error` lines;
#   - the class is not in DIRECT_CONSTRUCT_TARGETS, whose construct path
#     passes mrb_value arguments to `#initialize` and would desync from a
#     retyped signature.
# Unresolved nil paths were excluded rather than guessed (Game::State#
# initialize: SAVE_MOVABLE map_id/x/y have no schema default; Game::Interpreter
# #apply: `when 0 then val` returns operand_value unguarded;
# Game::Interpreter#resume_battle: battle.result may still be nil in
# leave_battle_event_phase).
#
# CPP_RESERVED_WORDS: a Ruby parameter name can be a C++ keyword
# (RPG2k::Scene::Map#page_field(name, default)). Not a full keyword table,
# just plausible names; every arg_names entry goes through sanitize_c_ident.
CPP_RESERVED_WORDS = Set[
  'default', 'class', 'new', 'delete', 'template', 'namespace', 'operator',
  'this', 'true', 'false', 'nullptr', 'try', 'catch', 'throw', 'const',
  'static', 'struct', 'union', 'enum', 'typedef', 'sizeof', 'goto',
  'if', 'else', 'for', 'while', 'do', 'switch', 'case', 'break', 'continue',
  'return', 'void', 'int', 'float', 'double', 'char', 'bool', 'long',
  'short', 'auto', 'extern', 'volatile', 'explicit', 'typename', 'using',
  'public', 'private', 'protected', 'virtual', 'friend', 'export', 'mutable',
].freeze

def sanitize_c_ident(name)
  CPP_RESERVED_WORDS.include?(name) ? "#{name}_" : name
end

NATIVE_ARG_TARGETS = Set[
  'Game::Actor#gain_exp',
  'Game::Actor#change_level_by',
  'Game::Actor#change_mp',
  'Game::Actor#exp_for_level',
  'Game::Actor#free_two_handed_slot',
  'Game::Actor#slot_cursed?',
  'Game::Actor#base_param_limit',
  'Game::Actor#unequip',
  'Game::Actor#base_stats',
  'Game::Actor#change_param',
  'Game::Actor#change_class',
  'Game::Actor#battle_row=',
  'Game::Map#in_bounds?',
  'Game::Map#substitute_tile',
  'Game::Map#set_tile',
  'Game::Map#tile',
  'Game::Transition#half',
  'Game::Transition#block_count_through',
  'Game::Screen#tint_to',
  'Game::Screen#restore_tint',
  'Game::Screen#shake',
  'Game::Screen#flash',
  'Game::Screen#approach',
  'Game::State#set_screen_transition',
  'Game::Interpreter#character_ref',
  'Game::Interpreter#trunc_div',
  'Game::Interpreter#skip_to',
  'Game::Interpreter#find_choice_option',
  'Game::Interpreter#do_control_vars_range_variable',
  'Game::Interpreter#vehicle_operand',
  'Game::Interpreter#screen_operand',
  'Game::Interpreter#queue_level_up_messages',
  'Game::Interpreter#trunc_mod',
  'LCF::EventCommand#initialize',
  'LCF::MoveCommand#initialize',
  'RPG2k::Scene::SaveLoad#move_selection',
  'RPG2k::Scene::Title#move_selection',
  'RPG2k::Scene::ItemMenu#move_item_cursor',
  'RPG2k::Scene::ItemMenu#move_teleport_cursor',
  'RPG2k::Scene::Order#move_cursor',
  'RPG2k::Scene::Map::LRUBitmapCache#initialize',
  'RPG2k::Scene::SaveLoad#draw_slot_label',
  'RPG2k::Scene::Base#draw_stat_segment',
  'RPG2k::Scene::Base#sticky_list_top',
  'RPG2k::Scene::SaveLoad#build_arrow_sprite',
  'RPG2k::Scene::Menu#wait_term_for',
  'RPG2k::Scene::Menu#enter_actor_selection',
  'RPG2k::Scene::VehicleWorld#initialize',
  'RPG2k::Scene::Battle#battler_z',
  'RPG2k::Scene::Battle#actor_sprite_z',
  'RPG2k::Scene::Battle#battle_grid_position',
  'RPG2k::Scene::Battle#move_battle_target_cursor',
  'RPG2k::Scene::Battle#move_battle_list_index',
  'RPG2k::Scene::Battle#battle_skill_unavailable?',
  'RPG2k::Scene::Battle#draw_gauge_system2',
  'RPG2k::Scene::Battle#draw_number_system2',
  'RPG2k::Scene::Battle#refresh_battle_list_arrows',
].freeze

# SUPER_SUPPORT (ADR 0146): human-vetted "Owner#name" allowlist for compiling
# `super`/`super(...)`, because soundness depends on whole-program facts
# compile_insn cannot re-derive per site:
#   - Block forwarding: OP_SUPER always forwards the current method's block
#     (vm.c L_SENDB_SYM; OP_SUPER is not in the SET_NIL_VALUE(regs[new_bidx])
#     list), but a compiled `_impl` has no block parameter, so the forwarded
#     block is nil. That is correct only if no caller of the listed method
#     ever passes a block. Re-check this for every new entry.
#   - No include/prepend between the caller and the superclass: OP_SUPER
#     follows CI_TARGET_CLASS(ci - 1)->super, which passes through an ICLASS
#     per included module, so a module's same-named method would win over
#     "jump to @superclass_of". Now also checked mechanically (ADR 0158).
#   - The target must compile clean (super_target gates on compiles_clean?).
# Supported shapes: `super parent` (SUPER n=1 into RPG2k::Scene::Base#
# initialize) and bare `super` in a zero-parameter method (SUPER n=0).
# Not here: `super` into a native method (RGSS::Bitmap::LoadError#initialize,
# Object#method_missing/#respond_to_missing? on LCF::Sections/Array1D/File):
# there is no bytecode `_impl` to call; see ZSUPER_NATIVE_TARGETS for those.
# A zsuper in a method with parameters (`ARGARY` + `SUPER n=*`) is the other
# shape, not matched by the `n=(\d+)` parse (ADR 0159).
SUPER_TARGETS = Set[
  'RPG2k::Scene::Battle#initialize',
  'RPG2k::Scene::DebugMenu#initialize',
  'RPG2k::Scene::ItemMenu#initialize',
  'RPG2k::Scene::Menu#initialize',
  'RPG2k::Scene::ChipsetEditor#initialize',
  'RPG2k::Scene::EquipMenu#initialize',
  'RPG2k::Scene::GameOver#initialize',
  'RPG2k::Scene::MapViewer#initialize',
  'RPG2k::Scene::Order#initialize',
  'RPG2k::Scene::SkillMenu#initialize',
  'RPG2k::Scene::StatusMenu#initialize',
  'RPG2k::Scene::Title#initialize',
  'RPG2k3::Scene::Battle#update',
  'RPG2k3::Scene::Battle#drive_battle_command',
  'RPG2k3::Scene::Battle#enter_command_phase',
  'RPG2k3::Scene::Battle#open_battle_options',
  'RPG2k3::Scene::Battle#advance_actor',
  'RPG2k3::Scene::Battle#prev_commandable_actor_index',
  'RPG2k::Scene::Map#initialize',
  'RPG2k::Scene::SaveLoad#initialize',
  'RPG2k3::Scene::Battle#finish_round_animation',

  # tools/optcarrot_probe's separate closed world (see its README.md); inert for
  # real gem builds. Bare `super` (SUPER R2 n=0) into Optcarrot::APU::Oscillator;
  # no caller passes a block and no include intervenes. #initialize/#poke_0/
  # #poke_3 are `SUPER n=*` zsupers, not this shape.
  'Optcarrot::APU::Pulse#reset',
  'Optcarrot::APU::Pulse#active?',
  'Optcarrot::APU::Triangle#reset',
  'Optcarrot::APU::Triangle#active?',
  'Optcarrot::APU::Noise#reset',
].freeze

# ---------------------------------------------------------------------------
# ZSUPER_NATIVE_SUPPORT: a bare `super` in a method WITH parameters, reaching a
# native mruby method. mrbc's codegen_zsuper emits:
#
#     ARGARY  R(a+1)  m1:r:m2:lv (kd)      ; this method's arguments as an Array
#     SUPER   R(a)    n=*                  ; forward that Array as the arg list
#
# super_target cannot help (no bytecode `_impl`), so the two native targets are
# reproduced exactly:
#
#   * Object#respond_to_missing? is Kernel's ROM entry `mrb_false`
#     (src/kernel.c): `return mrb_false_value();`, ignoring self and arguments.
#     It is `static`, so the body is reproduced, not called.
#
#   * Object#method_missing is BasicObject's `mrb_obj_missing` (src/class.c).
#     It reads its arguments via mrb_get_args off the current ci frame, which
#     only VM dispatch sets up, so it cannot be called directly (the same
#     hazard as extract_native_method_names). It only tail-calls
#     `mrb_method_missing(mrb, name, self, args)` (mruby/internal.h), which
#     takes plain C parameters, so that is called with the same values:
#       - name = mrb_obj_to_sym(first argument): what mrb_get_args "n" does
#         (it accepts a String too, unlike mrb_symbol());
#       - args = a fresh Array copy of the remaining arguments, matching
#         mrb_ary_new_from_values: the array is stored in the exception's @args
#         (src/error.c), so aliasing the method's own *args would be observable.
#     mrb_method_missing has no C-linkage guard, so it is declared `extern "C"`
#     in the generated prologue.
#
# Divergence: the interpreter pushes a cfunc frame and mrb_obj_missing zeroes
# its mid; the only consumer of mid there is pack_backtrace (src/backtrace.c),
# which skips cfunc frames with mid == 0, so having no frame gives the same
# backtrace.
#
# Dropping ARGARY/SUPER is sound (vm.c): ARGARY (lv == 0) only builds the Array
# and raises only for "super called outside of method", impossible in a def
# body. SUPER raises only for that, a prepended/module target class, or a self
# not kind_of its own class. check_argument_count cannot raise:
# method_missing is MRB_ARGS_ANY(), and respond_to_missing? is
# MRB_ARGS_ARG(1,1) against an ARGARY spec of 2:0:0:0 (exactly 2 values).
# OP_SUPER skips the visibility check, so MRB_MT_PRIVATE is inert.
#
# This table carries the hand-verified remainder zsuper_native_kind cannot
# derive (see its comment for what it re-checks per site): the closed world
# has three `include`s (Enumerable in LCF::Array2D and Game::Party, `class
# Object; include RGSS; end`) and no `prepend`, so each listed owner's chain is
# Owner -> Object -> ICLASS(RGSS) -> ICLASS(Kernel) -> BasicObject, none with a
# Ruby definition of either name. zsuper_native_kind re-checks that exactly
# one native source defines each name (extract_native_method_sources).
ZSUPER_NATIVE_TARGETS = {
  'LCF::Sections#respond_to_missing?' => :kernel_respond_to_missing,
  'LCF::Array1D#respond_to_missing?' => :kernel_respond_to_missing,
  'LCF::File#respond_to_missing?' => :kernel_respond_to_missing,
  'LCF::Sections#method_missing' => :basic_object_method_missing,
}.freeze

# Per kind: the method name, the ARGARY operand spec mrbc must have emitted,
# and the single NATIVE_SRCS file that must be the only native definer of the
# name. zsuper_native_kind re-checks all three per site; any mismatch keeps the
# `#error`.
ZSUPER_NATIVE_SHAPES = {
  # `def respond_to_missing? sym, include_private = false` -> ENTER 1:1:...,
  # zsuper rebuilds both positional slots: m1=2, r=0, m2=0, kd=0, lv=0.
  kernel_respond_to_missing: {
    name: 'respond_to_missing?',
    argary: '2:0:0:0',
    native_src: '3rd/mruby/src/kernel.c',
  }.freeze,
  # `def method_missing sym, *args` -> ENTER 1:0:1:..., m1=1, r=1: the array is
  # `[sym, *args]` (vm.c OP_ARGARY copies m1 values, then splices the rest), the
  # same split mrb_obj_missing's `mrb_get_args(mrb, "n*!", ...)` performs.
  basic_object_method_missing: {
    name: 'method_missing',
    argary: '1:1:0:0',
    native_src: '3rd/mruby/src/class.c',
  }.freeze,
}.freeze

# Owners on every listed owner's chain whose Ruby definition of the name would
# intercept `super`. Modules cannot be listed (they can be included anywhere);
# zsuper_native_kind refuses any owner missing from `superclass_of`, which
# only real CLASS opcodes populate, so modules and singletons are excluded.
ZSUPER_NATIVE_BLOCKED_OWNERS = %w[Object Kernel BasicObject].freeze

# Call-site devirtualization: is THIS receiver provably an instance of one
# exact class? Unlike monomorphic_target this can resolve a POLY name.
# Walks back from `idx` for the last writer of `reg` (following MOVEs) to a
# `Klass.new(...)` SEND, then through the GETMCNST/GETCONST chain on the same
# register (each segment overwrites it in place) to a `::`-joined name spelled
# like MethodDef#owner. `Klass.new` always allocates exactly Klass, so no
# inheritance model is needed. Anything unrecognized returns nil (dynamic
# dispatch).
# Optional extra terminals: `ivar_classes` (ClassLayout, this owner) and
# `arg_classes` (ClassAnnotations). `resolving_new:` starts inside the SEND
# :new case, to resolve that call's own receiver (NATIVE_CONSTRUCT_TARGETS).
# CHAINED_ACCESSOR_SUPPORT: with `class_layout` (all owners) and `registry`, a
# mid-chain SEND (`@state.screen.foo`) resolves when its receiver traces to
# class R (recursing on a strictly smaller index), R defines the name as an
# :ivar_accessor getter, and R's class_layout entry names that ivar's class.
# Every consumer still guards these hints with mrb_obj_class.
# LEXICAL_NEW_TARGET_RESOLUTION: map the constant path a `.new` site WRITES
# (`Scene::MapViewer` inside `module RPG2k`, or a bare `Switches`) to the
# registry name, using Module.nesting:
#
#     module RPG2k; module Scene; class DebugMenu
#       def f; Scene::MapViewer.new; end
#     end; end; end
#
#   Module.nesting there is [RPG2k::Scene::DebugMenu, RPG2k::Scene, RPG2k]:
#   the owner's name prefixes, innermost first; the first prefix that holds
#   the first segment wins. `Scene::Battle` inside `module RPG2k3` resolves to
#   RPG2k3::Scene::Battle, never RPG2k's.
# Owner prefixes equal Module.nesting only for nested (not compact `class
# A::B`) definitions; the closed world has no compact ones. Lexical scope only;
# the cref's ancestors are not searched.
# Soundness: only returns an existing DIRECT_CONSTRUCT_TARGETS entry; a match
# at more than one level is ambiguous and returns nil; no owner returns nil;
# nil falls back to the written path (dynamic dispatch / `#error`).
def lexically_resolve_construct_target(written, owner)
  return nil if written.nil? || written.empty?
  return nil if owner.nil?

  nesting = owner.to_s.sub(/\.singleton\z/, '').split('::')
  return nil if nesting.empty?

  hits = []
  nesting.length.downto(1) do |n|
    candidate = "#{nesting.first(n).join('::')}::#{written}"
    hits << candidate if DIRECT_CONSTRUCT_TARGETS.include?(candidate)
  end

  # Ambiguous across nesting levels: refuse (see above).
  return nil if hits.length > 1

  hits.first
end

# `dominated:` (RETURN-site proofs only): `->(w_idx, use_idx, reg)` that must
# accept every hop, so no hop can skip past a join (ADR 0198).
def trace_new_target(irep, idx, reg, ivar_classes = nil, mand = 0, arg_classes = nil, resolving_new: false, owner: nil,
                      class_layout: nil, registry: nil, container_constants: nil, element_annotations: nil,
                      known_owners: nil, capture_hints: nil, ret_class_proof: nil, dominated: nil, canonical: true)
  path = []
  use = idx
  # GETCONST/GETMCNST are class-name evidence only while resolving a `.new`
  # receiver: `@position = POS_BOTTOM` is an Integer constant, not a class.
  # `resolving_new` becomes true right after a SEND :new (with an empty `path`),
  # or starts true for the `resolving_new:` caller.
  (idx - 1).downto(0) do |i|
    insn = irep.instructions[i]

    if insn.op == 'RESCUE'
      # RESCUE_DUAL_REGISTER_SUPPORT: `R[b] = R[a].isa?(R[b])` (see
      # IvarLayout.trace_type's RESCUE arm): `b`, the SECOND token, is a write.
      # Checked before the `d == reg` filter, which only reads the first token and
      # would otherwise treat the instruction as not touching `reg`.
      a, b = insn.args.scan(/R(\d+)/).flatten
      next unless [a, b].include?(reg)
      return nil if b == reg

      next
    end

    d = insn.args[/^R(\d+)/, 1]
    next unless d == reg

    if dominated && !READ_ONLY_OPCODE_SKIP.include?(insn.op)
      return nil unless dominated.call(i, use, reg)

      use = i
    end

    case insn.op
    when 'MOVE'
      reg = insn.args.scan(/R(\d+)/).flatten[1]
    when 'GETIDX', 'GETIDX0'
      return nil unless element_annotations && class_layout && registry

      # GETIDX overwrites its receiver register; GETIDX0 has a separate source.
      recv_reg = if insn.op == 'GETIDX'
                   reg
                 else
                   insn.args.scan(/R(\d+)/).flatten[1]
                 end
      return nil unless recv_reg

      recv_class = trace_new_target(irep, i, recv_reg, ivar_classes, mand, arg_classes, owner: owner,
                                     class_layout: class_layout, registry: registry,
                                     container_constants: container_constants,
                                     element_annotations: element_annotations,
                                     known_owners: known_owners, capture_hints: capture_hints,
                                     ret_class_proof: ret_class_proof, dominated: dominated, canonical: canonical)
      # An annotated Hash<Klass> parameter is a safe source for indexed values.
      # Only plain MOVE aliases back to the untouched argument register count;
      # GETIDX keeps its Hash and subclass dispatch guards at codegen.
      arg_reg = recv_reg
      captured_reg = nil
      (i - 1).downto(0) do |j|
        prior = irep.instructions[j]
        next unless prior.args[/^R(\d+)/, 1] == arg_reg
        if prior.op == 'MOVE'
          arg_reg = prior.args.scan(/R(\d+)/).flatten[1]
          break unless arg_reg
        else
          upvar = prior.args.split(/\s+/) if prior.op == 'GETUPVAR'
          captured_reg = prior.args[/^R(\d+)/, 1].to_i if upvar && upvar[2] == '0'
          arg_reg = nil
          break
        end
      end
      # The trace can stop at a block's GETUPVAR before reaching the captured
      # container; the callsite hint is limited to annotated Hash arguments.
      recv_class ||= capture_hints&.dig(irep.label, captured_reg, :container_class) if captured_reg
      recv_class = resolve_owner_name(recv_class, { owner: owner, known_owners: known_owners }) if known_owners
      arg_pos = arg_reg&.to_i
      if recv_class == 'Hash' && arg_pos && arg_pos.between?(1, mand) &&
         element_annotations[irep.label]&.arg_containers&.[](arg_pos - 1) == 'Hash'
        annotated_value = element_annotations[irep.label]&.arg_elements&.[](arg_pos - 1)
        return annotated_value if annotated_value
      end
      if recv_class == 'Hash' && captured_reg
        captured_value = capture_hints&.dig(irep.label, captured_reg, :element_class)
        return captured_value if captured_value
      end
      md = registry['[]']&.find { |candidate| candidate.owner == recv_class && candidate.irep }
      return md && element_annotations[md.irep]&.ret_class
    when 'SEND0', 'SEND'
      return nil if resolving_new || !path.empty?

      # Same charset as compile_send's name extraction.
      name = insn.args[/:([\w+\-*\/<>=!?\[\]&|^~%@]+)/, 1]
      if name == 'new'
        resolving_new = true
      elsif name == 'dup' && registry && (registry['dup'] || []).all? { |md| md.owner == '<native>' }
        # DUP_PRESERVES_CLASS: a blockless, argless `.dup` returns an object of exactly
        # its receiver's class: mrb_obj_dup (src/class.c) does
        # `mrb_obj_alloc(mrb, mrb_type(obj), mrb_obj_class(mrb, obj))`, bound as
        # Kernel#dup with MRB_ARGS_NONE (src/kernel.c). The `registry['dup']` check
        # above rejects any program-level `def dup`. So the receiver's class (traced by
        # recursion on a strictly smaller index; SEND overwrites its receiver register)
        # is the result's class.
        # SEND0 prints no `n=`; a `.dup(x)` with arguments is an ArgumentError and
        # proves nothing.
        n_match = insn.args.match(/n=(\d+|\*)/)
        return nil if n_match && n_match[1] != '0'

        return trace_new_target(irep, i, reg, ivar_classes, mand, arg_classes, owner: owner,
                                 class_layout: class_layout, registry: registry,
                                 container_constants: container_constants,
                                 element_annotations: element_annotations,
                                 known_owners: known_owners, capture_hints: capture_hints,
                                 ret_class_proof: ret_class_proof, dominated: dominated, canonical: canonical)
      else
        # CHAINED_ACCESSOR_SUPPORT (see the header): a non-`new` SEND may be a chained
        # :ivar_accessor read. A no-op unless the caller passes class_layout and
        # registry; `resolving_new` callers already returned above.
        return nil unless class_layout && registry

        # attr_reader takes zero arguments (src/class.c), so require n=0 to rule out a
        # same-named POLY method of another arity (as the MONO/TYPED arity guards do).
        # SEND0 prints no "n=" (vm.c OP_SEND0 has c=0).
        # The receiver is whatever wrote `reg` before `i` (SEND overwrites its
        # receiver register in place); recursing on a strictly smaller index
        # terminates.
        recv_class = trace_new_target(irep, i, reg, ivar_classes, mand, arg_classes, owner: owner,
                                       class_layout: class_layout, registry: registry,
                                       container_constants: container_constants,
                                       element_annotations: element_annotations,
                                       known_owners: known_owners, capture_hints: capture_hints,
                                       ret_class_proof: ret_class_proof, dominated: dominated, canonical: canonical)
        return nil unless recv_class
        recv_class = resolve_owner_name(recv_class, { owner: owner, known_owners: known_owners }) if known_owners

        if element_annotations
          annotated = registry[name]&.find do |md|
            md.owner == recv_class && md.irep && element_annotations[md.irep]&.ret_class
          end
          return element_annotations[annotated.irep].ret_class if annotated
        end

        n_match = insn.args.match(/n=(\d+|\*)/)
        return nil if n_match && n_match[1] != '0'

        # An attr_writer is registered as "name=", so `registry[name]` only matches
        # getters.
        accessor = registry[name]&.find { |md| md.owner == recv_class && md.kind == :ivar_accessor }
        return nil unless accessor

        # R's own hint for this ivar (getter name == ivar name). class_layout can be
        # ClassLayout.analyze's in-progress table, so never return UNKNOWN from it.
        # `key?`, not `[]`: the table is `Hash.new { |h, k| h[k] = {} }`, and `[]`
        # would insert entries and reorder the `== known-ivar-class hints ==`
        # diagnostic.
        recv_ivars = class_layout[recv_class] if class_layout.key?(recv_class)
        hint = recv_ivars && recv_ivars[name]
        return nil unless hint && hint != ClassLayout::UNKNOWN

        return hint
      end
    when 'SSEND0', 'SSEND'
      # RETCLASS_SELF_CALL_SUPPORT: an implicit-receiver call has no receiver
      # register (and a bare `new(...)` here is an instance method, not Class#new),
      # so the only evidence is `ret_class_proof` (compute_class_return_names); nil
      # for callers that do not opt in. Never contributes to a `.new` path.
      return nil if resolving_new || !path.empty?
      return nil unless ret_class_proof

      name = insn.args[/:([\w+\-*\/<>=!?\[\]&|^~%@]+)/, 1]
      return nil unless name

      # Explicit `return`: this is inside the downto block, so a bare expression
      # would only end this iteration and the walk would continue past the answer.
      # `owner`: CodeGen#self_call_reaches_def? (never method_missing).
      return ret_class_proof.call(name, owner)
    when 'SENDB'
      # BLOCK_CARRYING_NEW: `Klass.new(...) { ... }` compiles to SENDB. A block
      # passed to #initialize does not change which class `.new` allocates, so set
      # `resolving_new` like the blockless case and share the GETCONST walk.
      # SSENDB (`self.new { }`) is excluded: self's class is not a fixed name, and
      # no such site exists.
      return nil if resolving_new || !path.empty?

      name = insn.args[/:([\w+\-*\/<>=!?\[\]&|^~%@]+)/, 1]
      return nil unless name == 'new'

      resolving_new = true
    # Same register: SEND overwrites its receiver register with the result.
    when 'GETIV'
      return nil if resolving_new || !path.empty?

      ivar = insn.args[/@(\w+)/, 1]
      klass = ivar_classes && ivar_classes[ivar]
      return known_owners ? resolve_owner_name(klass, { owner: owner, known_owners: known_owners }) : klass
    when 'GETUPVAR'
      return nil if resolving_new || !path.empty?

      dst, _upvar, level = insn.args.split(/\s+/)
      return nil unless level == '0'

      capture_class = capture_hints&.dig(irep.label, dst[/\d+/].to_i, :container_class)
      capture_class
    when 'ARRAY', 'ARRAY2'
      # EACH_BLOCK_SUPPORT: an ARRAY literal is always an Array (vm.c OP_ARRAY). Only
      # valid at the end of a trace: during a `.new` chain or constant path the
      # register belongs to another expression.
      return nil if resolving_new || !path.empty?

      return 'Array'
    when 'HASH'
      # HASH_EACH_SUPPORT: a HASH literal is always a Hash (vm.c OP_HASH); same
      # end-of-trace gating.
      return nil if resolving_new || !path.empty?

      return 'Hash'
    when 'RANGE_INC', 'RANGE_EXC'
      # INTERP_UNLOCK: RANGE_INC/RANGE_EXC always create a Range (vm.c,
      # mrb_range_new); same end-of-trace gating.
      return nil if resolving_new || !path.empty?

      return 'Range'
    when 'GETMCNST'
      # CONST_CONTAINER_SUPPORT: collecting a segment is harmless either way; what
      # happens with `path` is decided at GETCONST.
      # Not `$`-anchored: a trailing "; R6:name" comment would end up in the segment.
      path.unshift(insn.args[/::(\w+)/, 1])
    when 'GETCONST'
      # "GETCONST R4 Integer" or "GETCONST R3 MAX_DIGITS\t; R3:d": \S+ stops before
      # the local-name comment.
      const_name = insn.args[/^R\d+\s+(\S+)/, 1]

      # CONST_CONTAINER_SUPPORT: without `resolving_new` this chain is the receiver
      # of an ordinary call (`Game::Vehicle::TYPES.each`), and the useful fact is
      # "this constant's value is a proven Array/Hash" from build_registry's
      # `container_constants`, keyed by `[const_name] + path` (root first).
      unless resolving_new
        return nil unless container_constants

        unless path.empty?
          full = ([const_name] + path).join('::')
          return container_constants[full]
        end

        # A bare reference (`STAT_NAMES.each`): lexical lookup innermost first against
        # `container_constants`; absent everywhere means nil.
        if owner
          nesting = owner.to_s.sub(/\.singleton\z/, '').split('::')
          nesting.length.downto(1) do |n|
            candidate = "#{nesting.first(n).join('::')}::#{const_name}"
            return container_constants[candidate] if container_constants.key?(candidate)
          end
        end
        return container_constants[const_name]
      end

      # Resolve the written path (bare `Switches` or qualified `Scene::MapViewer`)
      # with lexically_resolve_construct_target (see its comment): innermost first,
      # DIRECT_CONSTRUCT_TARGETS members only, ambiguity refused. A general lookup
      # is not sound here: Ruby may fall through to a same-named top-level constant,
      # which this function cannot rule out. A miss falls back to the written path;
      # an already-qualified `Game::Transition` resolves through that fallback.
      # Consumers also guard with `mrb_class_ptr(recv) == ...` at runtime, but this
      # does not rely on it.
      written = ([const_name] + path).join('::')
      resolved = lexically_resolve_construct_target(written, owner)
      return resolved if resolved
      # UNIQUE_CLASS_NAME: construct-target callers (canonical: false) key their
      # tables by the written name.
      if canonical && path.empty? && (unique = UniqueClassNames.resolve(const_name, owner))
        return unique
      end

      path.unshift(const_name)
      return path.join('::')
    when *READ_ONLY_OPCODE_SKIP
      # READ_ONLY_OPCODE_SKIP (ClassLayout counterpart; ADR 0188, ADR 0191): skip
      # opcodes that only read their `R%d` operand, as IvarLayout.trace_type does.
      # RESCUE is handled above the register filter instead.
    else
      return nil
    end
  end
  # Never written: an incoming argument (register N is argument N for N <=
  # mand). Only a class annotation can name its class; pooling call sites is
  # unsound for POLY names.
  return nil if dominated && !dominated.call(-1, use, reg)

  pos = reg.to_i
  return arg_classes[pos - 1] if arg_classes && pos.between?(1, mand)

  nil
end

# NIL_TOLERANT_JOIN predicate: true only when `reg` at `idx` was just loaded by
# LOADNIL (following MOVEs). A false negative only falls back to the ordinary
# join; a false positive would drop real evidence.
def nil_literal_write?(irep, idx, reg)
  (idx - 1).downto(0) do |i|
    insn = irep.instructions[i]
    d = insn.args[/^R(\d+)/, 1]
    next unless d == reg

    case insn.op
    when 'MOVE'
      reg = insn.args.scan(/R(\d+)/).flatten[1]
    when 'LOADNIL'
      return true
    else
      return false
    end
  end
  false
end

# CONST_CONTAINER_SUPPORT predicate: `reg` at `idx` is a fresh
# Array/Hash/Range literal, optionally followed by exactly one `.freeze` on the
# same register (`ARRAY R1 2` / `SEND0 R1 :freeze` / `SETCONST NAME R1`).
# `.freeze` is accepted only directly on such a literal, never as a general
# passthrough: RGSS::Transition#freeze is an unrelated override with a
# different return value.
def literal_container_class(irep, idx, reg)
  (idx - 1).downto(0) do |i|
    insn = irep.instructions[i]
    d = insn.args[/^R(\d+)/, 1]
    next unless d == reg

    case insn.op
    when 'MOVE'
      reg = insn.args.scan(/R(\d+)/).flatten[1]
    when 'SEND0'
      return nil unless insn.args[/:([\w+\-*\/<>=!?\[\]&|^~%@]+)/, 1] == 'freeze'
    when 'ARRAY', 'ARRAY2'
      return 'Array'
    when 'HASH'
      return 'Hash'
    when 'RANGE_INC', 'RANGE_EXC'
      return 'Range'
    else
      return nil
    end
  end
  nil
end

# LITERAL_EQQ_SUPPORT: find a literal Fixnum/Symbol written to a `:===`
# receiver register, the `case x; when 5; when :bar` desugaring:
#   LOADI_5  R4  (5)
#   MOVE     R5  R3   ; R3 holds the case value
#   SEND     R4  :===  n=1
#   ...
#   LOADSYM  R4  :bar
#   MOVE     R5  R3
#   SEND     R4  :===  n=1
# Separate from trace_new_target: a different question with no shared
# terminals. Follows MOVEs defensively. Returns {type: :fixnum, value: "5"} /
# {type: :symbol, name: "bar"}, or nil (compile_send keeps POLY dispatch).
def trace_eqq_literal_receiver(irep, idx, reg)
  (idx - 1).downto(0) do |i|
    insn = irep.instructions[i]
    d = insn.args[/^R(\d+)/, 1]
    next unless d == reg

    case insn.op
    when 'MOVE'
      reg = insn.args.scan(/R(\d+)/).flatten[1]
    when 'LOADSYM'
      # Same extraction as LOADSYM's codegen (stops before a local-name comment).
      name = insn.args[/:(\S+)/, 1]
      return name ? { type: :symbol, name: name } : nil
    when /^LOADI/
      # Same two literal shapes as LOADI's codegen.
      lit = insn.args[/\(([^)]+)\)/, 1] || insn.args[/^R\d+\s+(-?\d+)/, 1]
      return lit ? { type: :fixnum, value: lit } : nil
    else
      # Anything else writing `reg` means the receiver is not a literal.
      return nil
    end
  end
  # Never written: an argument or block-entry register, not a literal. No
  # "argument is always literal N" fact exists to fall back on.
  nil
end

def pure_mandatory_arity?(irep)
  enter = irep.instructions.find { |i| i.op == 'ENTER' }
  return true unless enter # no ENTER at all: a 0-arg method, trivially fine.

  fields = enter.args.split(':').map { |f| f[/\d+/].to_i }
  fields[1..].all?(&:zero?)
end

# ENTER's mandatory count (fields[0]), used by compile_send's MONO guard to
# refuse a direct call whose argument count differs from the target's arity.
def mandatory_arity(irep)
  enter = irep.instructions.find { |i| i.op == 'ENTER' }
  return 0 unless enter

  enter.args.split(':').first.to_i
end

# KEYWORD_HASH_POSITIONAL_OPTIONAL_ARG_SUPPORT: can this def receive `nk`
# keyword pairs packed into one trailing positional Hash, with `total`
# positionals? (see compile_keyword_hash_positional_send). Sound when ENTER has
# kd == 0 (no KEY, no KDICT): vm.c OP_ENTER's `if (!kd) { ci->n++; argc++; }`
# then treats the Hash as the next positional, so optional positionals are
# fine (`def foo(a, b = 1)` gets the Hash in b). `total.between?(mand, mand +
# opt)` accepts only what the VM accepts without raising. rest/post/block/
# noblock stay excluded (they move where the Hash lands). ENTER's fields are
# REQ:OPT:REST:POST:KEY:KDICT:BLOCK:NOBLOCK (src/codedump.c).
def keyword_hash_positional_callee?(irep, total)
  enter = irep.instructions.find { |i| i.op == 'ENTER' }
  return false unless enter

  mand, opt, rest, post, kw, kdict, block, noblock =
    enter.args.split(':').map { |f| f[/\d+/].to_i }
  kw.zero? && kdict.zero? && rest.zero? && post.zero? && block.zero? && noblock.zero? &&
    total.between?(mand, mand + opt)
end

# KEYWORD_DIRECT_CONSTRUCT_SUPPORT: ENTER with mandatory positionals, optional
# positionals, and KEYWORD parameters (kw > 0); rest/post/kwrest/block/noblock
# must be zero. pure_mandatory_arity? requires kw == 0, so a keyword
# #initialize never reaches the non-keyword construct path.
# e.g. `Game::MoveRoute#initialize(commands, repeat: true, skippable: false)`
# is `ENTER 1:0:0:0:2:0:0:0`.
# KEYWORD_CONSTRUCT_OPTIONAL_POSITIONAL_SUPPORT: optional positionals are
# allowed because compile_keyword_direct_construct pads the `_impl` call with
# mrb_nil_value() up to `mand + opt` plus `bc2cpp_given_opt` (the same splice
# as compile_keyword_call); without that padding, g++ fails with "too few
# arguments". With opt == 0 the output is unchanged.
def mandatory_optional_and_keyword_arity?(irep)
  enter = irep.instructions.find { |i| i.op == 'ENTER' }
  return false unless enter

  fields = enter.args.split(':').map { |f| f[/\d+/].to_i }
  _mand, _opt, rest, post, kw, kwrest, block, noblock = fields
  kw.to_i.positive? && rest.to_i.zero? && post.to_i.zero? &&
    kwrest.to_i.zero? && block.to_i.zero? && noblock.to_i.zero?
end

# BLOCK_CFUNC_FALLBACK_SUPPORT: can this block's irep be compiled as a
# top-level C++ function wrapped in a cfunc RProc
# (mrb_proc_new_cfunc_with_env)?
#
# `self` is fine: mrb_proc_get_self (src/proc.c) returns nil for a cfunc proc,
# so the enclosing method's self is captured in env slot 0 and read back with
# mrb_proc_cfunc_env_get(M, 0), ignoring the self mrb_yield passes. See
# emit_proc_fallback_fn/emit_block_fallback_glue.
#
# UPVAR_CAPTURE_SUPPORT: GETUPVAR/SETUPVAR capture a POINTER to the enclosing
# function's register local (mrb_cptr_value(M, &rN)). uvenv(mrb, up) walks `up`
# proc->upper hops (vm.c), so each captured level needs a matching frame (see
# collect_block_upvars). E.g. `GETUPVAR R3 4 0` in `list.each { |x| total +=
# x }` is the method's R4 at depth 0.
# Pointer capture is sound only if the callee runs the block synchronously and
# never stores it (LCF.lazy stores its block). That gate is
# BLOCK_FALLBACK_UPVAR_SAFE_METHODS in recognize_block_fallback_regions, not
# here.
#
# EXCEPTION_BREAK_SUPPORT: `break` becomes `throw bc2cpp_block_break`, caught
# at the SENDB call site (emit_block_fallback_glue); OP_BREAK unwinds to the
# yielding call with the break value as its result. mruby is built with
# MRB_USE_CXX_EXCEPTION (CMakeLists.txt), so MRB_TRY/MRB_CATCH are real C++
# try/catch and the throw unwinds through VM frames correctly.
# EXCEPTION_RETURN_SUPPORT: RETURN_BLK throws `bc2cpp_method_return`, caught
# around the whole enclosing method (compile_method's needs_return_catch). The
# per-call-site catch is for bc2cpp_block_break only, and C++ catch matching is
# exact, so the return passes through.
# NESTED_BLOCK_FALLBACK_SUPPORT: BLOCK/SENDB/SSENDB inside the block are
# handled by emit_proc_fallback_fn running the same recognize -> suppress ->
# glue pass recursively; an unresolved nested region leaves the raw opcodes,
# which still produce `#error`. A nested block's depth-0 upvar is the outer
# block's C++ local, which exists because the recursive pass runs inside the
# outer body's compile. @block_fallback_upvars/@block_fallback_active need no
# stack: each nested pass finishes and clears them before the outer level sets
# its own.
# BLOCK_FALLBACK_RESCUE_SUPPORT: RESCUE/RAISEIF/EXCEPT in the block are handled
# by running recognize_rescue_regions/emit_rescue_try_body/emit_rescue_glue on
# the block irep too. RESCUE/RAISEIF are always-correct translations; EXCEPT
# needs a recognized region, so unrecognized shapes still produce `#error`.
BLOCK_FALLBACK_UNSAFE_OPS = [].freeze

# UPVAR_CAPTURE_SUPPORT: sorted, de-duplicated outer registers the block's
# GETUPVAR/SETUPVAR reference. nil means "unsafe to capture" (distinct from []
# "nothing to capture").
def collect_block_upvars(block_irep)
  upvars = []
  block_irep.instructions.each do |insn|
    next unless %w[GETUPVAR SETUPVAR].include?(insn.op)

    _reg, upvar_idx, depth = insn.args.split(/\s+/)
    return nil unless depth == '0'

    upvars << upvar_idx.to_i
  end
  upvars.uniq.sort
end

# DEEP_UPVAR_CAPTURE_SUPPORT: a captured pointer is named by (level, index),
# not index alone: the same index at two levels names two variables, e.g. in
# `2.times do |j| 2.times do |i| ... quarters[j][i] ... end end`:
#   GETUPVAR R5 1 1   ; level 1, index 1 -- the METHOD's R1, `quarters`
#   GETUPVAR R6 1 0   ; level 0, index 1 -- the OUTER BLOCK's R1, `j`
# Level 0 keeps the un-suffixed spelling so existing output is unchanged.
def upvar_var_name(level, idx)
  level.zero? ? "bc2cpp_upvar_#{idx}" : "bc2cpp_upvar_u#{level}_#{idx}"
end

# UPVAR_CAPTURE_SUPPORT: the call-site half of the pointer-capture argument:
# the callee must run the block synchronously and never store it. A hand-vetted
# allowlist by NAME; every entry's body was read (mruby core, or this
# program's own methods such as each_event_position, page_field, section,
# cached_bitmap, auto_battle_best_target). Never add storage-like methods
# (lazy, define_method, callback registration) without the same check.
# A callee's own rescue/ensure (loop, page_field, File.open) is fine: under
# MRB_USE_CXX_EXCEPTION, MRB_CATCH (mruby/throw.h) catches only mrb_jmpbuf*,
# so a bc2cpp_block_break thrown through the yield passes through.
# Name-gated entries that depend on the current build, re-verify before
# changing it:
#   - `new`: assumed to be Array.new (mrb_ary_init yields synchronously). No
#     bytecode #initialize or native constructor here takes a block; adding
#     one breaks this assumption.
#   - `flat_map`, `zip`, `with_index`: Enumerator::Lazy's versions STORE the
#     block (mruby-enum-lazy). Safe only because mruby-enum-lazy is not in
#     build_config.rb and nothing here redefines these names. Re-verify
#     before adding that gem.
#   - `step`: this program's domain `def step` methods take no block and no
#     `.step {` call site exists, so only Numeric#step is reachable.
BLOCK_FALLBACK_UPVAR_SAFE_METHODS = %w[
  each each_with_index each_index each_key each_event_position
  times map select reject reject! delete_if
  find find_index any? all? none? count index sort_by
  _rgss_native_sort _rgss_native_sort! loop each_char
  page_field section open new reduce inject each_with_object downto
  auto_battle_best_target cached_bitmap flat_map gsub gsub! scan zip each_value
  sub sub! with_index step
].freeze

# The irep-only half of the block-fallback gate (arity plus the unsafe-op
# scan). The upvar-depth check lives in recognize_block_fallback_regions
# (`available_upvars`), which knows what the enclosing level can supply.
def block_fallback_safe?(block_irep)
  return false unless pure_mandatory_arity?(block_irep)

  block_irep.instructions.none? { |insn| BLOCK_FALLBACK_UNSAFE_OPS.include?(insn.op) }
end

# LAMBDA_FALLBACK_SUPPORT: the LAMBDA counterpart of block_fallback_safe?,
# sharing emit_proc_fallback_fn. A LAMBDA proc is always MRB_PROC_STRICT
# (opcode.h `OP_L_LAMBDA (OP_L_STRICT|OP_L_CAPTURE)`, codegen_lambda), and vm.c
# OP_RETURN_BLK/OP_BREAK both start with `if (MRB_PROC_STRICT_P(ci->proc)) goto
# NORMAL_RETURN;`. The child irep uses the same RETURN_BLK/BREAK opcodes as a
# block (lambda_body with blk=1), so only the constructing opcode tells them
# apart; this recognizer fires only for LAMBDA, so RETURN_BLK/BREAK are allowed
# here and compile to a plain return.
# Nested LAMBDA/BLOCK/SENDB/SSENDB and RESCUE/RAISEIF/EXCEPT are still
# rejected.
# CONFINED_LAMBDA_UPVAR_SUPPORT: upvars are captured as raw pointers into the
# enclosing C++ frame, so the proc must not outlive it. A lambda has no call
# site to vet, so recognize_lambda_fallback_regions requires
# lambda_proc_frame_confined? over the enclosing irep instead. A lambda with no
# upvars needs no such proof.
LAMBDA_FALLBACK_UNSAFE_OPS = %w[
  LAMBDA BLOCK SENDB SSENDB
  RESCUE RAISEIF EXCEPT
].freeze

def lambda_fallback_safe?(lambda_irep)
  return false unless pure_mandatory_arity?(lambda_irep)

  lambda_irep.instructions.none? { |insn| LAMBDA_FALLBACK_UNSAFE_OPS.include?(insn.op) }
end

# RUNTIME_DEF_FALLBACK_SUPPORT (SDEF_FALLBACK / SCLASS_FALLBACK+EXEC_FALLBACK):
# kinds emit_proc_fallback_fn compiles as a METHOD or CLASS body, not a block:
#   * `self` is the receiver mruby passes the cfunc, not env slot 0 (a block
#     ignores the passed self; a method or class body must use it);
#   * `@block_fallback_active` is false, so a BREAK keeps its `#error` (mrbc
#     rejects `break` at def/class top level anyway).
RUNTIME_DEF_FALLBACK_KINDS = %w[sdef_fallback tdef_fallback exec_fallback].freeze

# RUNTIME_DEF_FALLBACK_SUPPORT: the single predicate both consequences above
# key off.
def runtime_def_fallback_kind?(kind)
  RUNTIME_DEF_FALLBACK_KINDS.include?(kind)
end

# RUNTIME_DEF_FALLBACK_SUPPORT: can this `def` body be installed on a runtime
# class as a cfunc method?
# pure_mandatory_arity? is the load-bearing part: the entry wrapper binds
# parameters with `mrb_get_args(M, "oo...")`, which raises unless exactly
# `mand` arguments arrive. That matches a mandatory-only def and is wrong for
# any optional/rest/keyword/block parameter.
# Everything else already fails closed: the body is compiled with no captured
# upvars (GETUPVAR/SETUPVAR -> `#error`), no block parameter (BLKPUSH ->
# `#error`), and emit_proc_fallback_fn returns nil for any `#error`, which
# callers treat as "keep the original marker".
def runtime_def_body_safe?(def_irep)
  pure_mandatory_arity?(def_irep)
end

# CALLSITE_OPTIONAL_ARG_SUPPORT: ENTER's optional count (field 1), 0 when
# absent. compile_send uses it to pad a direct call with mrb_nil_value() and
# pass `bc2cpp_given_opt`, mirroring the entry wrapper's `mrb_get_argc(M) -
# mand`.
def optional_arity(irep)
  enter = irep.instructions.find { |i| i.op == 'ENTER' }
  return 0 unless enter

  fields = enter.args.split(':').map { |f| f[/\d+/].to_i }
  fields[1] || 0
end

# CALLSITE_OPTIONAL_ARG_SUPPORT: pure_mandatory_arity? that also accepts plain
# optional positionals (`def foo(a, b = 1)`); every other non-mandatory field
# must be zero. Callers still check compiles_clean? separately.
def pure_mandatory_or_optional_arity?(irep)
  enter = irep.instructions.find { |i| i.op == 'ENTER' }
  return true unless enter # no ENTER at all: a 0-arg method, trivially fine.

  fields = enter.args.split(':').map { |f| f[/\d+/].to_i }
  fields[2..].all?(&:zero?)
end

# OPTIONAL_ARG_SUPPORT: models ENTER's optional field only. Returns
# [optional_count, jump_source_addrs, jump_target_addrs] for the recognized
# shape, else [0, nil, nil] (compile_method then emits `#error`).
# `def foo(a, b = 1, c = 2)` is `ENTER 1:2:0:0:0:0:0:0` followed by exactly
# optional + 1 JMPs; entry k (arguments supplied) jumps to the code computing
# default k+1, or to the body when all were supplied. This is OP_ENTER's
# PC skip (vm.c), reproduced as a switch/goto (emit_optional_dispatch), so any
# default expression the compiler can translate works.
# JMPNOT/JMPIF/JMPNIL print "R<reg>\t<target>", optionally followed by
# "; R<reg>:<name>" when the register is a named local. Anchor after the
# register: an end-anchored `/(\d+)\s*$/` returns nil there, and `nil.to_i` is
# a silent `goto L0`.
def jmp_target_after_reg(args)
  args[/^R\d+\s+(\d+)/, 1].to_i
end

def optional_arg_table(irep)
  enter = irep.instructions.find { |i| i.op == 'ENTER' }
  return [0, nil, nil] unless enter

  fields = enter.args.split(':').map { |f| f[/\d+/].to_i }
  _mand, opt, rest, mand2, kw, kwrest, block = fields
  # OPTIONAL_KEYWORD_COMBINED_SUPPORT: `kw` may be non-zero (`def f(a, b = 1, k:
  # nil)`): the default-value code falls through into the KEY_P/KARG/KEYEND
  # sequence keyword_arg_table recognizes independently.
  return [0, nil, nil] unless opt.positive? && rest.zero? && mand2.zero? && kwrest.zero? && block.zero?

  enter_idx = irep.instructions.index { |i| i.op == 'ENTER' }
  jmps = irep.instructions[enter_idx + 1, opt + 1]
  return [opt, nil, nil] unless jmps && jmps.size == opt + 1 && jmps.all? { |i| i.op == 'JMP' }

  [opt, jmps.map(&:addr), jmps.map { |i| i.args.strip[/\d+/].to_i }]
end

# KEYWORD_ARG_SUPPORT: parameter name for a keyword. compile_method (signature,
# mrb_kwargs extraction) and compile_insn's KEY_P/KARG cases (which only see
# the instruction's `:sym`) agree only because both use this function.
def kwarg_param_name(sym)
  "bc2cpp_kwarg_#{sanitize_c_ident(sym)}"
end

def kw_given_param_name(sym)
  "bc2cpp_kw_given_#{sanitize_c_ident(sym)}"
end

# KEYWORD_ARG_SUPPORT: plain keyword arguments with kwrest == 0 (a `**rest`
# register is filled by OP_ENTER itself, a different shape). KEY_P/KARG/KEYEND
# translate in place, so no region is needed; this only lists the keywords in
# bytecode order and whether each is required (a lone `KARG R4 :c` with no
# KEY_P) or optional (KEY_P/JMPIF guard). Returns [{name:, required:}], or nil
# for unmodeled fields or a count mismatch with ENTER.
def keyword_arg_table(irep)
  enter = irep.instructions.find { |i| i.op == 'ENTER' }
  return nil unless enter

  fields = enter.args.split(':').map { |f| f[/\d+/].to_i }
  _mand, opt, rest, mand2, kw, kwrest, block = fields
  # OPTIONAL_KEYWORD_COMBINED_SUPPORT: `opt` may be non-zero (see
  # optional_arg_table); this scan already covers the whole irep.
  return nil unless kw.positive? && rest.zero? && mand2.zero? && kwrest.zero? && block.zero?

  order = []
  required = {}
  irep.instructions.each do |insn|
    next unless insn.op == 'KEY_P' || insn.op == 'KARG'

    sym = insn.args[/:(\S+)/, 1]
    next unless sym

    unless required.key?(sym)
      order << sym
      required[sym] = true
    end
    required[sym] = false if insn.op == 'KEY_P'
  end
  return nil unless order.size == kw

  order.map { |sym| { name: sym, required: required[sym] } }
end

# REST_ARG_SUPPORT: `def foo(a, *rest)` (ENTER 1:0:1:0:0:0:0:0) with no other
# non-mandatory field. OP_ENTER (vm.c) fills the rest register with an Array
# before the body runs, and it sits right after the mandatory registers, so
# compile_method treats it as one more contiguous `total_args` slot.
def rest_only_arity?(irep)
  enter = irep.instructions.find { |i| i.op == 'ENTER' }
  return false unless enter

  fields = enter.args.split(':').map { |f| f[/\d+/].to_i }
  _mand, opt, rest, mand2, kw, kwrest, block = fields
  # REST_BLOCK_COMBINED_SUPPORT: `block` may be non-zero (`def m(name, *args,
  # &block)`, ENTER 1:0:1:0:0:0:1:0): the block arrives at register
  # mand+rest+1. Both are pure ENTER-field facts, so no bytecode recognition is
  # involved.
  rest.positive? && opt.zero? && mand2.zero? && kw.zero? && kwrest.zero?
end

# EXPLICIT_BLOCK_PARAM_SUPPORT: mandatory arguments plus `&blk` (ENTER
# 0:0:0:0:0:0:1:0, then `MOVE R2 R1 ; R2:blk`). The block arrives at register
# mand+1 through the ordinary entry convention, not BLKPUSH/BLKCALL.
def block_param_arity?(irep)
  enter = irep.instructions.find { |i| i.op == 'ENTER' }
  return false unless enter

  fields = enter.args.split(':').map { |f| f[/\d+/].to_i }
  _mand, opt, rest, mand2, kw, kwrest, block = fields
  # REST_BLOCK_COMBINED_SUPPORT: `rest` may be non-zero (see rest_only_arity?).
  block.positive? && opt.zero? && mand2.zero? && kw.zero? && kwrest.zero?
end

def report_annotation_candidates(ireps, registry, arg_types, annotations)
  candidates = []
  registry.each_value do |defs|
    defs.each do |d|
      next unless d.irep

      # Mirrors drop_unsafe_embeddings: nothing on this class embeds unless its
      # #initialize is registered and compilable, so annotating is pointless
      # otherwise.
      init = registry.fetch('initialize', []).find { |md| md.owner == d.owner }
      next unless init&.irep && pure_mandatory_arity?(ireps.fetch(init.irep))

      irep = ireps.fetch(d.irep)
      enter = irep.instructions.find { |i| i.op == 'ENTER' }
      mand = enter ? enter.args.split(':').first.to_i : 0
      next if mand.zero?

      already_at = lambda do |pos|
        annotations[irep.label]&.args&.[](pos - 1) || arg_types[d.name]&.[](pos - 1)
      end
      seen_pos = Set.new

      irep.instructions.each_with_index do |insn, idx|
        next unless insn.op == 'SETIV'

        src_reg = insn.args[/R(\d+)/, 1]
        pos = opaque_argument_position(irep, idx, src_reg, mand)
        next unless pos
        next if already_at.call(pos)

        ivar = insn.args[/@(\w+)/, 1]
        candidates << { owner: d.owner, name: d.name, ivar: ivar, pos: pos, mand: mand, via: 'SETIV' }
        seen_pos << pos
      end

      # Diagnostic only: an opaque argument used directly by fixnum-fastpath
      # arithmetic/comparison. Annotating it changes no output (trace_type only
      # reaches arguments from SETIV traces); it documents intent.
      irep.instructions.each_with_index do |insn, idx|
        regs = case insn.op
               when 'ADD', 'SUB', 'MUL', 'EQ', 'LT', 'LE', 'GT', 'GE'
                 [insn.args[/^R(\d+)/, 1], insn.args[/\(R(\d+)\)/, 1]]
               when 'ADDI', 'SUBI'
                 [insn.args[/^R(\d+)/, 1]]
               else
                 []
               end
        regs.compact.each do |reg|
          pos = opaque_argument_position(irep, idx, reg, mand)
          next unless pos
          next if seen_pos.include?(pos) || already_at.call(pos)

          candidates << { owner: d.owner, name: d.name, ivar: nil, pos: pos, mand: mand, via: insn.op }
          seen_pos << pos
        end
      end
    end
  end
  candidates
end

# ---------------------------------------------------------------------------
# Step 6h: static call-target reachability (diagnostic only, feeds "== never
# called =="): is a name ever a call target in the program's bytecode? A
# compiled entry point missing here and from extract_native_call_names has no
# known caller. Names are collected from:
#   - SEND0/SEND/SSEND0/SSEND/SENDB/SSENDB `:name` operands;
#   - fixed-name opcodes (ADD/SUB/.../GETIDX/SETIDX and *I variants), whose
#     fallback calls a hardcoded name: IMPLICIT_DISPATCH_NAMES must stay in
#     sync with compile_insn/compile_cmp's mrb_funcall fallbacks;
#   - LOADSYM symbol literals (send, method, &:name, respond_to?, or plain
#     data): over-counting only shrinks the "never called" list.
# ---------------------------------------------------------------------------

IMPLICIT_DISPATCH_NAMES = {
  'ADD' => '+', 'ADDI' => '+', 'ADDILV' => '+',
  'SUB' => '-', 'SUBI' => '-', 'SUBILV' => '-',
  'MUL' => '*', 'DIV' => '/',
  'EQ' => '==', 'LT' => '<', 'LE' => '<=', 'GT' => '>', 'GE' => '>=',
  'GETIDX' => '[]', 'GETIDX0' => '[]', 'SETIDX' => '[]=',
}.freeze

def collect_static_call_target_names(ireps)
  names = Set.new
  ireps.each_value do |irep|
    (irep.instructions || []).each do |insn|
      case insn.op
      # SENDB/SSENDB count too (docs/adr/0203): a method only called with a block
      # is still called.
      when 'SEND0', 'SEND', 'SSEND0', 'SSEND', 'SENDB', 'SSENDB', 'LOADSYM'
        name = insn.args[/:([\w+\-*\/<>=!?\[\]&|^~%@]+)/, 1]
        names << name if name
      else
        fixed = IMPLICIT_DISPATCH_NAMES[insn.op]
        names << fixed if fixed
      end
    end
  end
  names
end

# ---------------------------------------------------------------------------
# Step 7: codegen -- one C++ function pair per leaf method-body irep.
#
# Each compiled method gets two C++ functions:
#   - `<Owner>_<name>_impl(mrb_state*, mrb_value self[, mrb_value arg1, ...])`
#     the real translated body, taking every argument as a plain typed C++
#     parameter -- no marshalling. This is what a monomorphic call site
#     compiles to a direct call to.
#   - `<Owner>_<name>(mrb_state*, mrb_value self)` the normal mrb_func_t
#     shape, which fetches its args the ordinary way (mrb_get_args) and
#     forwards to _impl. This is what gets registered with
#     mrb_define_method, so the method is still reachable the normal way --
#     from interpreted code, via #send, or from a call site this analysis
#     could not prove monomorphic.
# ---------------------------------------------------------------------------
class CodeGen
  # EMBED_WIRED (compiled_gems.rb BC2CPP_WIRED_EMBEDDINGS): nil leaves embedding
  # unrestricted (unit checks); the driver sets it for a real gem build.
  # struct_members: STRUCT_MEMBERS_ANALYSIS result (Struct owner -> members in
  # storage order); nil proves nothing.
  # embed_ivar_limits: owner -> the only ivars it may embed
  # (BC2CPP_EMBED_IVAR_LIMITS); nil or an absent owner means no cap.
  class << self
    attr_accessor :wired_embeddings, :embed_ivar_limits, :stable_class_constants, :struct_members,
                  :integer_constant_values
  end

  C_TYPE = { fixnum: 'mrb_int', symbol: 'mrb_sym', bool: 'mrb_bool' }.freeze

  # box/check/unbox/err per embeddable type for GETIV/SETIV codegen. An mrb_sym
  # field needs no GC keep-alive (see IvarLayout.trace_type's LOADSYM arm).
  # `:bool` has no single check macro (MRB_TT_TRUE/MRB_TT_FALSE are separate
  # tags), so bc2cpp_bool_p (emit_bool_check_helper) ORs mrb_true_p/mrb_false_p;
  # emitted only when an embedded :bool needs it.
  TYPE_OPS = {
    fixnum: { box: 'mrb_fixnum_value', check: 'mrb_integer_p', unbox: 'mrb_integer', err: 'Integer' },
    symbol: { box: 'mrb_symbol_value', check: 'mrb_symbol_p', unbox: 'mrb_symbol', err: 'Symbol' },
    bool: { box: 'mrb_bool_value', check: 'bc2cpp_bool_p', unbox: 'mrb_true_p', err: 'boolean' },
  }.freeze

  def initialize(ireps, registry, ivar_layout, class_layout = {}, class_annotations = {}, annotations = {},
                 superclass_of = {}, element_layout = {}, element_annotations = {}, container_constants = {},
                 hash_element_layout = {}, integer_constants = Set.new,
                 foreign_method_names = nil, outside_tokens = nil,
                  native_name_sources = nil, included_modules = {}, prepended_modules = {},
                  unknown_mixins = Set.new, analysis_only: false, native_expression_devirt: {},
                  native_registered_expressions: {}, closed_world: nil)
    @ireps = ireps
    # CLOSED_WORLD: a ClosedWorld (closed_world.rb) when BC2CPP_CLOSED_WORLD=1.
    @closed_world = closed_world
    # ENTRY_ARG_CALLSITE_PROOF: identifier tokens from NATIVE_SRCS and
    # FOREIGN_RUBY_SRCS (outside_world_tokens). nil means the scan did not run;
    # compute_entry_arg_fixnum then proves nothing.
    @outside_tokens = outside_tokens
    # FIXNUM_RETURN_PROOF: method names defined in foreign Ruby sources
    # (foreign_method_names). nil: compute_fixnum_return_names proves nothing
    # rather than use an incomplete poison set.
    @foreign_method_names = foreign_method_names
    # ZSUPER_NATIVE_SUPPORT: name -> NATIVE_SRCS files registering it
    # (extract_native_method_sources). nil: zsuper_native_kind declines every
    # site.
    @native_name_sources = native_name_sources
    # NATIVE_EXPRESSION_DEVIRT: single-expression implementations of zero-argument
    # C methods; only the allowlisted subset in native_expression_devirt.rb.
    @native_expression_devirt = native_expression_devirt
    # NATIVE_CONTAINER_DEVIRT: class-specific expressions from mruby's ROM
    # registration owner, instance tag and C body, including direct calls to
    # public C methods whose source reads no VM frame.
    @native_registered_expressions = native_registered_expressions
    # INTEGER_CONSTANT_PROOF: IntegerConstants.analyze's admitted names; read by
    # fixnum_proof_source?'s GETCONST/GETMCNST arms. Empty proves nothing.
    @integer_constants = integer_constants
    # CONST_CONTAINER_SUPPORT: qualified constant -> 'Array'/'Hash'/'Range'
    # (build_registry). Read by the block recognizers' receiver-class gate.
    @container_constants = container_constants
    # ELEMENT_CLASS_SUPPORT: ArrayElementLayout's filtered table and
    # ElementAnnotations. Read only by the block emitters, which guard every use
    # with mrb_obj_class.
    @element_layout = element_layout
    @element_annotations = element_annotations
    # HASH_ELEMENT_SUPPORT: HashElementLayout's filtered table; read only by
    # recognize_hash_each_regions/emit_hash_each_inline, guarded the same way.
    @hash_element_layout = hash_element_layout
    # Element class in scope, set by block emitters around one inlined body; nil
    # elsewhere.
    @elem_class_hint = nil
    # INLINE_BLOCK_CAPTURE_HINTS: captured Hash<Klass> arguments proven at the
    # enclosing block call site, keyed by block irep and GETUPVAR destination.
    # Scoped by emit_each_inline; nil elsewhere.
    @block_hash_capture_hints = nil
    # UPVAR_CAPTURE_SUPPORT: registers capturable by pointer, set by
    # emit_proc_fallback_fn around one BLOCK_FALLBACK body; read by compile_insn's
    # GETUPVAR/SETUPVAR. nil elsewhere.
    @block_fallback_upvars = nil
    # EXCEPTION_BREAK_SUPPORT: true only while compiling a BLOCK_FALLBACK body;
    # BREAK then throws bc2cpp_block_break instead of returning.
    @block_fallback_active = false
    # BLKPUSH_YIELD_SUPPORT: the method's block parameter name ('bc2cpp_blk'), set
    # by compile_method around its body; read by BLKPUSH. nil elsewhere.
    # BLOCK_FALLBACK_YIELD_SUPPORT: also set by emit_proc_fallback_fn for a body
    # that forwards the method's block (`region[:needs_blk]`). Saved and restored
    # (not cleared) because that function recurses and compile_method sets it too.
    @blk_param_name = nil
    # BLOCK_FALLBACK_YIELD_SUPPORT: the BLKPUSH `lv` that `@blk_param_name`
    # answers: 0 in a method body (vm.c `if (lv == 0) stack = regs + 1`), else the
    # body's nesting depth below its method (codegen.c counts scopes up to the
    # method scope, so a direct child block has lv == 1). Other lv keep `#error`.
    @blk_param_level = 0
    @registry = registry
    @known_owners = Set.new(registry.values.flatten.map(&:owner))
    # FIBER_REACHABILITY_UNSAFE_SUPPORT: must exist before drop_unsafe_embeddings,
    # which reaches compile_method through compiles_clean?. See
    # compute_fiber_unsafe_methods.
    compute_fiber_unsafe_methods
    # SUPER_SUPPORT: resolve_superclass_ref's table (name, :none, or absent); read
    # by compile_insn's SUPER case.
    @superclass_of = superclass_of
    # ANCESTOR_MIXINS_SUPPORT: build_registry's include/prepend tables. Prepended
    # modules are never consulted by `super`'s intervening-module check (they sit
    # above the class).
    @included_modules = included_modules
    @prepended_modules = prepended_modules
    @unknown_mixins = unknown_mixins
    # irep label -> Annotations::Annotation. Also the only trigger for
    # NATIVE_ARG_TARGETS' native calling convention (never ArgTypes); read by
    # native_arg_types for compile_method and compile_send.
    @annotations = annotations
    # irep label -> {owner:, name:} for every leaf body. Native MethodDefs have no
    # body.
    @owner_of = {}
    registry.each_value do |defs|
      defs.each { |d| @owner_of[d.irep] = d if d.irep }
    end
    @class_layout = class_layout # class_name -> {ivar_name => class_name} -- see ClassLayout's own comment.
    @class_annotations = class_annotations # irep label -> ClassAnnotations::Annotation
    @only_owners = nil # set by compile_all -- see its own comment.
    # Set when a compiled method needs bc2cpp_const_get_or_object;
    # emit_const_lookup_helper emits it (and mruby/error.h) only then.
    @const_lookup_helper_used = false
    # NATIVE_CONSTRUCT_TARGETS keys actually used; read by
    # emit_native_construct_decls.
    @native_construct_used = Set.new
    # DIRECT_CONSTRUCT_TARGETS actually used; read by
    # emit_direct_construct_decls.
    @direct_construct_used = Set.new
    @clean_cache = {} # irep label -> does compile_method(label) end up #error-free? (memoized -- see compiles_clean?'s own comment)
    @probing = Set.new # recursion guard for compiles_clean? (mutually-MONO-recursive methods)
    # ATTR_STRUCT_DEVIRT: [owner, ivar] pairs embedded only because a synthesized
    # struct-aware accessor (emit_ivar_accessor_pair) replaces the native attr_*
    # one. Filled by drop_unsafe_embeddings, read by emit_synthesized_accessors.
    @synthesize_accessor_for = Set.new
    # Temporarily the RAW layout: drop_unsafe_embeddings calls compiles_clean? ->
    # compile_method, which reads @ivar_layout[d.owner] (nil would raise).
    # Replaced by the filtered result right after.
    @ivar_layout = ivar_layout
    # FIXNUM_RETURN_PROOF: must exist (empty) before drop_unsafe_embeddings
    # (compiles_clean? -> compile_method -> proven_fixnum_operand?). Probing with
    # the empty set is exact: this proof chooses between two `#error`-free arms,
    # so the memoized compiles_clean? answers are the same. The real fixpoint runs
    # once @ivar_layout is final (proof source 3 reads it).
    @fixnum_return_names = Set.new
    # ENTRY_ARG_CALLSITE_PROOF: nil (not empty) until its fixpoint runs;
    # fixnum_proof_entry_arg? refuses on nil, so the first
    # compute_fixnum_return_names pass has no circular seeding.
    @entry_arg_fixnum = nil
    # ARRAY_RETURN_PROOF: must exist (empty) before drop_unsafe_embeddings, for the
    # same reason as @fixnum_return_names: a recognizer's region is all-or-nothing
    # and otherwise falls back to the `#error`-free BLOCK_FALLBACK, so
    # compiles_clean? answers are unchanged.
    @array_return_names = Set.new
    # ARRAY_RETURN_IVAR_HINT: `analysis_only` builds just enough to answer
    # array_return_names so the driver can feed it into a second ClassLayout pass
    # (see the driver's stratification comment). Exact, not approximate:
    # compute_array_return_names reads only ivars already final here, and not
    # @ivar_layout or @fixnum_return_names (its predicate is trace_new_target, a
    # top-level function, plus proven_array_source).
    # FIXNUM_RETURN_IVAR_HINT (`analysis_only == :fixnum_return`): stop after
    # FIXNUM_RETURN_PROOF instead. Its proof source 3 reads @ivar_layout, so
    # drop_unsafe_embeddings runs first, or an ivar it would reject could leak a
    # false proof. The ENTRY_ARG alternation is skipped; the final CodeGen runs it.
    if analysis_only == :fixnum_return
      @ivar_layout = drop_unsafe_embeddings(ivar_layout)
      compute_fixnum_return_names
      return
    end
    if analysis_only
      compute_array_return_names
      # RETCLASS_SELF_CALL_SUPPORT: computed in the same probing pass as
      # compute_array_return_names, for the same reason.
      compute_class_return_names
      return
    end
    @ivar_layout = drop_unsafe_embeddings(ivar_layout) # class_name -> {ivar_name => :fixnum}
    compute_fixnum_return_names
    # ARRAY_RETURN_PROOF: once, after @class_layout and @ivar_layout are final. It
    # neither reads nor feeds the Fixnum sets, so it is outside the alternation.
    compute_array_return_names
    # RETCLASS_SELF_CALL_SUPPORT: recomputed against the final @class_layout.
    compute_class_return_names
    # ENTRY_ARG_CALLSITE_PROOF <-> FIXNUM_RETURN_PROOF alternation. Each is a
    # greatest fixpoint that is sound given the other's current set (joint
    # induction: see compute_entry_arg_fixnum), and each re-seeds from all
    # candidates, so both sets only grow and the loop converges. The limit keeps
    # it linear if a future proof source converges slowly.
    ENTRY_ARG_ALTERNATION_LIMIT.times do
      before_args = @entry_arg_fixnum
      before_rets = @fixnum_return_names
      compute_entry_arg_fixnum
      compute_fixnum_return_names
      break if @entry_arg_fixnum == before_args && @fixnum_return_names == before_rets
    end
  end

  def const_lookup_helper_used?
    @const_lookup_helper_used
  end

  # FIXNUM_RETURN_PROOF result, for the diagnostic.
  def fixnum_return_names
    @fixnum_return_names
  end

  # Embedded ivars live in a struct allocated by the compiled #initialize's
  # mrb_data_init. If #initialize does not compile (or is inherited), other
  # compiled methods would use DATA_PTR(self) on a plain MRB_TT_OBJECT: memory
  # corruption, not a missed optimization.
  # An arity check is not enough (Game::Actor#initialize has pure mandatory
  # arity but its body has a block); compiles_clean? is the exact test, and is
  # also sufficient: the mrb_data_init emission is unconditional for a compiled
  # #initialize with an embedded layout and comes before any control flow,
  # including emit_optional_dispatch. (SUPER and other pure_mandatory_arity?
  # callers still need pure arity because they call `_impl` directly, bypassing
  # the entry wrapper.)
  def drop_unsafe_embeddings(ivar_layout)
    embedding_owners = ivar_layout.keys.to_set
    subclass_of = lambda do |klass, ancestor|
      seen = Set.new
      superclass = @superclass_of[klass]
      while superclass.is_a?(String) && !seen.include?(superclass)
        return true if superclass == ancestor

        seen << superclass
        superclass = @superclass_of[superclass]
      end
      false
    end

    ivar_layout.each_with_object({}) do |(owner, ivars), out|
      # One object has one DATA_PTR: a base class and a subclass that both embed
      # would overwrite it with different layouts. Keep both in iv_tbl unless one
      # shared struct covers the whole chain.
      inherited_layout = embedding_owners.any? do |other|
        other != owner && (subclass_of.call(owner, other) || subclass_of.call(other, owner))
      end
      next if inherited_layout

      next if self.class.wired_embeddings && !self.class.wired_embeddings.include?(owner)

      limit = self.class.embed_ivar_limits&.[](owner)
      ivars = ivars.select { |name, _| limit.include?(name) } if limit
      init = @registry['initialize']&.find { |d| d.owner == owner }
      next unless init && compiles_clean?(init.irep)

      # Every read/write of an embedded ivar must go through this compiler's
      # GETIV/SETIV or a replacement it controls. A native attr_reader/attr_writer
      # (src/class.c, plain mrb_iv_get/mrb_iv_set on iv_tbl) would read nil or write
      # into iv_tbl (LCF::EventCommand's `attr_reader :code`). build_registry
      # registers such accessors as synthetic irep-nil MethodDefs, checked here.
      # ATTR_STRUCT_DEVIRT: a `kind: :ivar_accessor` exposure (and only that; a
      # Struct member accessor is different storage) can be replaced by
      # emit_ivar_accessor_pair, registered via register.cxx. mrb_define_method
      # replaces the class's method-table entry, so dynamic calls (send, unproven
      # receivers) reach the struct-aware accessor too; IVAR_ACCESSOR_DEVIRT is only
      # a call-site shortcut on top. Only ivars whose native reader and writer are
      # all :ivar_accessor qualify.
      safe = ivars.reject do |name, _|
        reader_native = natively_exposed?(owner, name)
        writer_native = natively_exposed?(owner, "#{name}=")
        reader_blocked = reader_native && !synthesizable_accessor_only?(owner, name)
        writer_blocked = writer_native && !synthesizable_accessor_only?(owner, "#{name}=")
        next true if reader_blocked || writer_blocked || !every_accessor_compiles?(owner, name)

        # Synthesize only the accessor that exists natively: adding an `x=` to a class
        # with only `attr_reader :x` would change behavior.
        @synthesize_accessor_for << [owner, name, :reader] if reader_native
        @synthesize_accessor_for << [owner, name, :writer] if writer_native
        false
      end
      out[owner] = safe unless safe.empty?
    end
  end

  # Is `name` on `owner` exposed by a native (irep-nil) accessor that uses
  # iv_tbl and would bypass the embedded struct?
  def natively_exposed?(owner, name)
    (@registry[name] || []).any? { |d| d.owner == owner && d.irep.nil? }
  end

  # ATTR_STRUCT_DEVIRT: are all native definitions of `name` on `owner` plain
  # attr_* accessors (:ivar_accessor)? Vacuously true when there are none. False
  # when another native definition shares the name, e.g. a Struct member
  # accessor (positional storage, nothing to synthesize).
  def synthesizable_accessor_only?(owner, name)
    (@registry[name] || []).select { |d| d.owner == owner }.all? { |d| d.kind == :ivar_accessor }
  end

  # Every method touching an embedded ivar must compile, not just #initialize.
  # struct RData (mruby/data.h) has its own `iv` table separate from `data`
  # (DATA_PTR), so an interpreted method would read/write iv_tbl while compiled
  # siblings use the struct: two diverging copies of the same ivar (e.g.
  # Game::Interpreter#update, left interpreted, read nil @frame_steps).
  def every_accessor_compiles?(owner, ivar_name)
    # `@registry` auto-vivifies on `[]`, and compiles_clean? below can reach such a
    # read (natively_exposed?), which would add keys while this loop iterates.
    # `.values` snapshots the arrays first.
    @registry.values.each do |defs|
      defs.each do |d|
        next unless d.irep

        # A subclass's own GETIV/SETIV addresses its own (struct-less) layout,
        # so it would reach iv_tbl even when compiled: never embed then.
        return false if d.owner != owner && strict_subclass?(d.owner, owner) && irep_subtree_touches_ivar?(d.irep, ivar_name)
        next unless d.owner == owner

        touches = irep_subtree_touches_ivar?(d.irep, ivar_name)
        return false if touches && !compiles_clean?(d.irep)
      end
    end
    true
  end

  def strict_subclass?(klass, ancestor)
    seen = Set.new
    superclass = @superclass_of[klass]
    while superclass.is_a?(String) && seen.add?(superclass)
      return true if superclass == ancestor

      superclass = @superclass_of[superclass]
    end
    false
  end

  # Does this method's irep, or any irep nested in it (block bodies are separate
  # child ireps), touch this ivar? An interpreted method runs its blocks too, so
  # Game::Transition#clip's `rects.each { ... @width ... }` counts even though
  # its top-level irep never mentions @width. `seen` skips ireps shared by
  # several call sites.
  def irep_subtree_touches_ivar?(label, ivar_name, seen = Set.new)
    return false if seen.include?(label)

    seen << label
    irep = @ireps.fetch(label)
    return true if irep.instructions.any? do |insn|
      (insn.op == 'SETIV' || insn.op == 'GETIV') && insn.args[/@(\w+)/, 1] == ivar_name
    end

    irep.reps.any? { |child| irep_subtree_touches_ivar?(child, ivar_name, seen) }
  end

  def cpp_name(owner, name)
    sanitize("#{owner}_#{name}")
  end

  # NATIVE_ARG_TARGETS' per-position types, shared by compile_method (signature)
  # and compile_send (call-site unboxing) so they cannot disagree. Returns `mand`
  # slots of :fixnum/:symbol or nil (plain mrb_value). Requires a real irep AND
  # NATIVE_ARG_TARGETS membership; an annotation alone is not enough (see that
  # constant).
  def native_arg_types(d, mand)
    return Array.new(mand) unless d.irep && NATIVE_ARG_TARGETS.include?("#{d.owner}##{d.name}")

    ann = @annotations[d.irep]
    return Array.new(mand) unless ann

    Array.new(mand) { |i| ann.args[i] }
  end

  # C++ type for a native_arg_types slot: C_TYPE.fetch(t) or mrb_value. No
  # `:array` arm on purpose: an Array token in argument position raises KeyError
  # (fail loud). Return-type gates read `.ret` directly.
  def native_c_type(t)
    t ? C_TYPE.fetch(t) : 'mrb_value'
  end

  # Owner names are constant paths ("Game::Actor"); `::` is not valid in a C++
  # identifier, so every generated name goes through this.
  def sanitize(s)
    s.gsub(/[^a-zA-Z0-9_]/, '_')
  end

  # Lexical scope segments (innermost last) for a bare constant in a def body,
  # used by GETCONST codegen and const_chain_value_expr. A trailing ".singleton"
  # is stripped: `def self.x` inside `class Bitmap` has Module.nesting
  # [RGSS::Bitmap, RGSS]. Splitting "RGSS::Bitmap.singleton" as-is looked up a
  # constant named "Bitmap.singleton" in the unguarded scope-chain part of
  # GETCONST, a NameError at runtime. No effect on real constant paths.
  def lexical_scope_path(owner)
    owner.sub(/\.singleton\z/, '').split('::')
  end

  # Names with exactly one definition in the whole program: static method
  # resolution. A name whose only definition is native (irep nil) is not a
  # target: there is no `_impl`, and calling the C function directly would
  # leave mrb_get_args reading a stale mrb->c->ci frame (see vm.c
  # mrb_funcall_with_block).
  def monomorphic_target(name)
    # RUNTIME_DEF_DEVIRT_GUARD: a name the current method may install on a
    # singleton class at runtime cannot be bound statically (see
    # devirt_blocked_name?/class_body_installed_names).
    return nil if devirt_blocked_name?(name)

    defs = @registry[name]
    return nil unless defs && defs.size == 1
    return nil unless defs.first.irep
    return nil unless compiles_clean?(defs.first.irep)

    defs.first
  end

  # POLY_SMALL_N_SUPPORT: a POLY name can still become a chain of
  # runtime-class-checked direct calls, one `if` per eligible owner, ending in
  # mrb_funcall for every other class. A single eligible target is useful too;
  # the fallback covers native, unclean or filtered definitions.
  # Bounded by POLY_SMALL_N_MAX: past that a linear chain of class compares is
  # no longer clearly cheaper than mruby's method-table lookup, and code size
  # keeps growing. 16 covers the `dispose` family and leaves `update` (21)
  # dynamic.
  # C++ vtables are not an option: mruby objects are tagged mrb_values, not C++
  # polymorphic instances; the mrb_obj_class chain reuses the TYPED/IVAR_ACCESSOR
  # trust model.
  # Narrower than TYPED/MONO: only pure-mandatory candidates whose arity equals
  # the call's `n` join; others are left to the fallback. Same
  # @only_owners/@other_owners gate (no `_impl` for owners not emitted).
  POLY_SMALL_N_MAX = 16

  def poly_small_n_targets(name, n)
    # RUNTIME_DEF_DEVIRT_GUARD: same gate as monomorphic_target. The chain's
    # `mrb_obj_class(M, recv) == Widget` guard still matches an object whose
    # singleton class was just given its own `shared_name`.
    return nil if devirt_blocked_name?(name)

    defs = @registry[name]
    # LONE_ACCESSOR_CHAIN: a name whose only definition is a plain attr_reader/
    # attr_writer (LCF::EventCommand `indent`/`code`) cannot be MONO (no bytecode).
    # The receiver may be any class (rpgxp/rpgvx/wolf define their own), so it is
    # a one-candidate exact-class chain with the funcall fallback.
    lone_accessor = defs && defs.size == 1 && defs.first.kind == :ivar_accessor && defs.first.irep.nil?
    return nil unless defs && (defs.size >= 2 || lone_accessor)

    # An owner with two definitions of the name (attr_reader later redefined by a
    # def, or the reverse) never joins: which one is live depends on definition
    # order.
    repeated_owners = defs.group_by(&:owner).select { |_, group| group.size > 1 }.keys
    candidates = defs.select do |t|
      next false if repeated_owners.include?(t.owner)

      # POLY_SMALL_N_ACCESSOR: an :ivar_accessor definition (no irep) joins the chain
      # as a bare mrb_iv_get/mrb_iv_set behind the IVAR_ACCESSOR_DEVIRT guard. The
      # shape check is its arity (0 reader, 1 writer); no ONLY_OWNERS gate needed.
      if t.kind == :ivar_accessor && t.irep.nil?
        next false if t.owner.end_with?('.singleton')
        next false unless n == (name.end_with?('=') ? 1 : 0)

        # EMBEDDED_ACCESSOR_CHAIN: an embedded ivar is only reachable through its
        # synthesized accessor, which IVAR_ACCESS uses when it is linkable from
        # here; otherwise leave the candidate out (the funcall reaches it).
        next !ivar_accessor_call_code(t.owner, 'recv', name, 0, ['arg']).nil?
      end
      next false unless t.irep
      # SINGLETON_OWNER_EXCLUSION: a `.singleton` owner can never match the guard:
      # mrb_obj_class is mrb_class_real(mrb_class(obj)) (src/class.c), which skips
      # SCLASS/ICLASS and returns e.g. Module, and const_chain_value_expr strips the
      # suffix. Such a candidate would be dead code, so it is excluded.
      next false if t.owner.end_with?('.singleton')
      next false unless compiles_clean?(t.irep)

      t_irep = @ireps.fetch(t.irep)
      next false unless pure_mandatory_arity?(t_irep)
      next false unless n == mandatory_arity(t_irep)
      next false unless native_arg_types(t, n).compact.empty?

      if @only_owners && !@only_owners.include?(t.owner)
        next false unless @other_owners&.include?(t.owner)
      end

      true
    end
    return nil unless candidates.size.between?(1, POLY_SMALL_N_MAX)

    candidates
  end

  # True when `owner`'s ivar behind accessor `name` (a reader `code`, or a writer
  # `code=`) is embedded in the RData struct and therefore served by a synthesized
  # accessor pair (ATTR_STRUCT_DEVIRT, emit_ivar_accessor_pair) instead of the
  # native attr_reader/attr_writer.
  def embedded_accessor?(owner, name)
    writer = name.end_with?('=')
    @synthesize_accessor_for.include?([owner, name.chomp('='), writer ? :writer : :reader])
  end

  # IVAR_ACCESS: the only emitter of ivar access on `recv`, an object of exact
  # class `klass` (nil: unknown). GETIV/SETIV and every devirtualized accessor go
  # through here, so an embedded ivar never touches iv_tbl, where it reads nil.
  # `self_of_klass` means `recv` is self inside klass's own compiled body, whose
  # struct is always in this file. Returns nil when only dispatch can reach it.
  def ivar_get_code(klass, recv, ivar, dst, self_of_klass: false)
    type = ivar_embed_type(klass, ivar)
    return "#{dst} = mrb_iv_get(M, #{recv}, mrb_intern_cstr(M, \"@#{ivar}\"));" if type.nil?
    return nil if type == :unknown

    if self_of_klass
      "#{dst} = #{TYPE_OPS.fetch(type)[:box]}(((#{struct_name(klass)}*)DATA_PTR(#{recv}))->#{ivar});"
    elsif embedded_accessor_linkable?(klass, ivar)
      "#{dst} = #{sanitize(klass)}_#{sanitize(ivar)}_impl(M, #{recv});"
    end
  end

  # IVAR_ACCESS's write half: the statement storing `src` into @ivar, or nil.
  # Same rules as ivar_get_code. With `dst`, it also leaves `src` (attr_writer's
  # return value) in `dst`.
  def ivar_set_code(klass, recv, ivar, src, self_of_klass: false, dst: nil, indent: '  ')
    type = ivar_embed_type(klass, ivar)
    tail = dst ? "\n#{indent}#{dst} = #{src};" : ''
    return "mrb_iv_set(M, #{recv}, mrb_intern_cstr(M, \"@#{ivar}\"), #{src});#{tail}" if type.nil?
    return nil if type == :unknown

    if self_of_klass
      unless src.match?(/\A\w+\z/)
        store = ivar_set_code(klass, recv, ivar, 'bc2cpp_iv_val', self_of_klass: true, indent: indent)
        return "{ mrb_value bc2cpp_iv_val = #{src}; #{store} }#{tail}"
      end

      ops = TYPE_OPS.fetch(type)
      # Guarded: an uncompiled writer could still store another type. (Not
      # E_TYPE_ERROR: that macro hardcodes `mrb`; generated code names it `M`.)
      "if (!#{ops[:check]}(#{src})) mrb_raise(M, mrb_exc_get_id(M, mrb_intern_lit(M, \"TypeError\")), \"@#{ivar}: expected #{ops[:err]}\");\n" \
        "#{indent}((#{struct_name(klass)}*)DATA_PTR(#{recv}))->#{ivar} = #{ops[:unbox]}(#{src});#{tail}"
    elsif embedded_accessor_linkable?(klass, "#{ivar}=")
      "#{dst ? "#{dst} = " : ''}#{sanitize(klass)}_#{sanitize(ivar)}_eq_impl(M, #{recv}, #{src});"
    end
  end

  # IVAR_ACCESS for an attr_reader/attr_writer call `name` on `recv`: the
  # statements leaving the call's value in r<d>, or nil.
  def ivar_accessor_call_code(klass, recv, name, d, argv, self_of_klass: false, indent: '  ')
    ivar = name.chomp('=')
    return ivar_get_code(klass, recv, ivar, "r#{d}", self_of_klass: self_of_klass) unless name.end_with?('=')

    ivar_set_code(klass, recv, ivar, argv.first, self_of_klass: self_of_klass, dst: "r#{d}", indent: indent)
  end

  # nil: an ordinary iv_tbl ivar. :unknown: `klass` is not known but some class
  # embeds an ivar of this name, so iv_tbl may be the wrong storage.
  def ivar_embed_type(klass, ivar)
    return embed_type(klass, ivar) if klass

    @ivar_layout.each_value.any? { |ivars| ivars.key?(ivar) } ? :unknown : nil
  end

  # The synthesized accessor (reader `name`, writer `name=`) exists and is
  # defined by this file or declared by another compiled gem's header.
  def embedded_accessor_linkable?(owner, name)
    return false unless embedded_accessor?(owner, name)

    !@only_owners || @only_owners.include?(owner) || @other_owners&.include?(owner) || false
  end

  POLY_SMALL_N_INHERITED_MAX = 16

  # INHERITED_GUARD: closed-world strict subclasses of `owner` whose instances'
  # lookup of `name` provably ends at `owner`'s own def: no class on the way
  # defines it or mixes anything in, and nothing aliases/undefines the name.
  def inheriting_subclasses(name, owner)
    installed = symbol_installed_names
    return [] if installed.nil? || installed.include?(name)
    return [] unless Array(@prepended_modules[owner]).empty? && !@unknown_mixins.include?(owner)
    # A native def outside mruby's core (which only touches core classes) could
    # sit on a subclass; without the source map any native def declines.
    natives = @native_name_sources ? @native_name_sources.fetch(name, []) : nil
    if natives.nil?
      return [] if @registry.fetch(name, []).any? { |md| md.owner == '<native>' }
    elsif natives.any? { |path| !path.match?(%r{/3rd/mruby/(?:src|mrbgems)/}) }
      return []
    end

    def_owners = @registry.fetch(name, []).map(&:owner).to_set
    mixed = lambda do |klass|
      !Array(@included_modules[klass]).empty? || !Array(@prepended_modules[klass]).empty? ||
        @unknown_mixins.include?(klass)
    end
    @superclass_of.keys.sort.select do |klass|
      next false unless strict_subclass?(klass, owner)

      k = klass
      k = @superclass_of[k] until k == owner || def_owners.include?(k) || mixed.call(k)
      k == owner
    end.first(POLY_SMALL_N_INHERITED_MAX)
  end

  def compile_poly_small_n(name, d, recv, argv, n, closed_world_site: nil)
    candidates = poly_small_n_targets(name, n)
    return nil unless candidates

    inherited = candidates.to_h do |t|
      subs = inheriting_subclasses(name, t.owner)
      # An accessor's storage is the owner's; skip a subclass that embeds the ivar itself.
      if t.kind == :ivar_accessor && t.irep.nil?
        subs = subs.reject do |s|
          k = s
          k = @superclass_of[k] until k == t.owner || embed_type(k, name.chomp('='))
          k != t.owner
        end
      end
      [t.owner, subs]
    end
    # INHERITED_GUARD: a subclass that inherits a candidate's def joins its
    # branch; the receiver's class is then read once instead of per compare.
    hoist = inherited.values.any?(&:any?)
    recv_class = hoist ? 'bc2cpp_recv_class' : "mrb_obj_class(M, #{recv})"
    branches = candidates.map do |target|
      check = ([target.owner] + inherited[target.owner]).map do |owner|
        "#{owner_class_ptr_expr(owner)} == #{recv_class}"
      end.join(' || ')
      call = if target.kind == :ivar_accessor && target.irep.nil?
               # POLY_SMALL_N_ACCESSOR: attr_reader/attr_writer are a bare
               # mrb_iv_get / mrb_iv_set (3rd/mruby/src/class.c), or the
               # synthesized accessor for an embedded ivar; the writer returns
               # the assigned value, not the ivar read back.
               ivar_accessor_call_code(target.owner, recv, name, d, argv, indent: '    ')
             else
               impl = cpp_name(target.owner, target.name) + '_impl'
               "r#{d} = #{impl}(M, #{([recv] + argv).join(', ')});"
             end
      "if (#{check}) {\n    #{call}\n  } else "
    end
    owners_note = candidates.map(&:owner).join(', ')
    note = "  // POLY_SMALL_N :#{name} -> #{owners_note} (#{candidates.size} known real definitions), " \
           "runtime-class-checked direct C++ calls chained, mrb_funcall fallback for any other class\n"
    listed = candidates.flat_map { |t| [t.owner] + inherited[t.owner] }
    fallback = guarded_fallback_line(d, recv, name, argv, listed, closed_world_site)
    chain = "#{branches.join}{\n    #{fallback}  }\n"
    return "#{note}  #{chain}" unless hoist

    subs = inherited.flat_map { |owner, list| list.map { |s| "#{s} < #{owner}" } }
    "#{note}  // INHERITED_GUARD :#{name} -- also #{subs.join(', ')}\n" \
      "  {\n  struct RClass* #{recv_class} = mrb_obj_class(M, #{recv});\n  #{chain}  }\n"
  end

  # Bounded like POLY_SMALL_N_MAX; few Struct owners share a member name.
  STRUCT_INDEX_MAX = 8

  # STRUCT_INDEX_CACHE: `event[:page]` on an unknown receiver used to
  # mrb_funcall "[]", and Struct's native [] (mrb_struct_aref, mruby-struct
  # struct.c) scans __members__ each call. For a known Struct owner
  # (STRUCT_MEMBERS_ANALYSIS) and a literal Symbol key the index is a constant,
  # so read RARRAY_PTR directly behind an exact-class guard per owner,
  # bounds-checked like struct_aref_sym (`i < plen ? ptr[i] : nil`).
  # Reached only from GETIDX's INDEX_CHAIN tail; other keys keep the existing
  # chain and fallback.
  def compile_struct_literal_index_read(irep, idx, s, d)
    return nil unless CodeGen.struct_members && !CodeGen.struct_members.empty?

    literal = trace_eqq_literal_receiver(irep, idx, s)
    return nil unless literal && literal[:type] == :symbol

    candidates = CodeGen.struct_members.filter_map do |owner, members|
      i = members.index(literal[:name])
      [owner, i] if i
    end
    return nil if candidates.empty? || candidates.size > STRUCT_INDEX_MAX

    candidates.map do |owner, i|
      "else if (mrb_type(r#{d}) == MRB_TT_STRUCT && " \
        "mrb_obj_ptr(r#{d})->c == #{owner_class_ptr_expr(owner)}) {\n" \
        "    r#{d} = (#{i} < RARRAY_LEN(r#{d})) ? RARRAY_PTR(r#{d})[#{i}] : mrb_nil_value();\n" \
        "  } "
    end.join
  end

  # OUTLINED_INDEX_OPS (ADR 0216): the generic part of an untyped GETIDX/
  # GETIDX0/SETIDX (exact-class Array/Hash/String fast paths, and for GETIDX
  # INDEX_CHAIN's POLY_SMALL_N `#[]` chain) does not depend on the site, so it
  # is one static helper per file. STRUCT_INDEX_CACHE's literal-Symbol branches
  # stay inline ahead of the call (a Struct never matches the Array/Hash/String
  # arms, so the order is unobservable), as do the TYPED/static-receiver paths.
  INDEX_HELPERS = {
    'getidx' => 'mrb_value recv, mrb_value key',
    'getidx0' => 'mrb_value recv',
    'setidx' => 'mrb_value recv, mrb_value idx, mrb_value val'
  }.freeze

  # `dst = bc2cpp_<kind>(M, args...);`, building the helper on first use.
  def outlined_index_call(kind, dst, *args)
    index_helper_code(kind)
    "#{dst} = bc2cpp_#{kind}(M, #{args.join(', ')});\n"
  end

  # GETIDX's generic tail, after any STRUCT_INDEX_CACHE branches. nil under
  # RUNTIME_DEF_DEVIRT_GUARD for `[]`: that chain must skip POLY_SMALL_N and
  # the shared helper does not, so the caller keeps the inline form.
  def outlined_getidx_code(d, s, struct_read)
    return nil if devirt_blocked_name?('[]')

    call = outlined_index_call('getidx', "r#{d}", "r#{d}", "r#{s}")
    return call if struct_read.nil? || struct_read.empty?

    "#{struct_read.delete_prefix('else ')}else {\n  #{call}}\n"
  end

  # Built once per run under with_fresh_method_state, so the enclosing method's
  # RUNTIME_DEF_DEVIRT_GUARD cannot leak into the shared chain; building during
  # compilation allocates OWNER_CLASS_CACHE slots before that table is printed.
  def index_helper_code(kind)
    @index_helper_code ||= {}
    @index_helper_code[kind] ||= with_fresh_method_state { build_index_helper(kind) }
  end

  def build_index_helper(kind)
    body = case kind
           when 'getidx'
             # INDEX_CHAIN's tail, with the result in r0 (the name
             # compile_poly_small_n spells as `r<d>`).
             tail = compile_poly_small_n('[]', 0, 'recv', ['key'], 1) ||
                    "  r0 = mrb_funcall(M, recv, \"[]\", 1, key);\n"
             <<~CPP.chomp + "\n#{tail}  return r0;\n"
               if (mrb_array_p(recv) && mrb_obj_ptr(recv)->c == M->array_class && mrb_integer_p(key)) {
                 return bc2cpp_ary_entry(M, recv, mrb_integer(key));
               } else if (mrb_hash_p(recv) && mrb_obj_ptr(recv)->c == M->hash_class) {
                 return mrb_hash_get(M, recv, key);
               } else if (mrb_string_p(recv) && mrb_obj_ptr(recv)->c == M->string_class &&
                          (mrb_integer_p(key) || mrb_string_p(key) || mrb_range_p(key))) {
                 return mrb_str_aref(M, recv, key, mrb_undef_value());
               }
               mrb_value r0 = mrb_nil_value();
             CPP
           when 'getidx0'
             <<~CPP
               if (mrb_array_p(recv) && mrb_obj_ptr(recv)->c == M->array_class) {
                 return bc2cpp_ary_entry(M, recv, 0);
               } else if (mrb_hash_p(recv) && mrb_obj_ptr(recv)->c == M->hash_class) {
                 return mrb_hash_get(M, recv, mrb_fixnum_value(0));
               }
               return mrb_funcall(M, recv, "[]", 1, mrb_fixnum_value(0));
             CPP
           when 'setidx'
             # The fast paths leave the assigned value in the register, the
             # fallback whatever `[]=` returned (vm.c's OP_SETIDX).
             <<~CPP
               if (mrb_array_p(recv) && mrb_obj_ptr(recv)->c == M->array_class && mrb_integer_p(idx)) {
                 mrb_ary_set(M, recv, mrb_integer(idx), val);
                 return val;
               } else if (mrb_hash_p(recv) && mrb_obj_ptr(recv)->c == M->hash_class) {
                 mrb_hash_set(M, recv, idx, val);
                 return val;
               }
               return mrb_funcall(M, recv, "[]=", 2, idx, val);
             CPP
           end
    "// OUTLINED_INDEX_OPS -- #{kind.upcase}'s generic chain, see bc2cpp.rb's INDEX_HELPERS comment.\n" \
      "static mrb_value bc2cpp_#{kind}(mrb_state* M, #{INDEX_HELPERS.fetch(kind)}) {\n" \
      "#{body.gsub(/^(?=.)/, '  ')}}\n\n"
  end

  # The helpers `codes` (generated C++ texts, or compiled entries' hashes)
  # call, in INDEX_HELPERS order. A helper built for a method that was then
  # dropped (a probe, or an unsupported method) is not emitted.
  def index_helpers_used(codes)
    texts = codes.map { |c| c.is_a?(Hash) ? c[:code] : c }
    INDEX_HELPERS.keys.select do |kind|
      @index_helper_code&.key?(kind) && texts.any? { |t| t.include?("bc2cpp_#{kind}(M,") }
    end
  end

  # File-scope definitions of the helpers `codes` call; '' when none.
  def emit_index_helpers(codes)
    index_helpers_used(codes).map { |kind| @index_helper_code.fetch(kind) }.join
  end

  # How many sites call each helper, for the stderr summary.
  def index_helper_site_counts(codes)
    texts = codes.map { |c| c.is_a?(Hash) ? c[:code] : c }
    INDEX_HELPERS.keys.to_h { |kind| [kind, texts.sum { |t| t.scan(/= bc2cpp_#{kind}\(M,/).size }] }
  end

  # LITERAL_EQQ_SUPPORT soundness gate, re-checked against this run's @registry:
  # both `#==` and `#===` must be MONO native. `LITERAL === arg` must reach
  # mrb_eqq_m (src/kernel.c), which calls mrb_equal (src/object.c); mrb_equal
  # dispatches to the receiver's `#==` unless mrb_func_basic_p, and the Symbol
  # (mrb_obj_equal_m) and Fixnum (int_equal, src/numeric.c) branches rely on
  # those defaults. A reopened `#==` on any class could change that, so the
  # check is by name, not by owner. Any reopening flips this to false and the
  # sites fall back to POLY dispatch. Memoized: @registry is fixed after
  # CodeGen.new.
  def eqq_literal_devirt_safe?
    return @eqq_literal_devirt_safe if defined?(@eqq_literal_devirt_safe)

    @eqq_literal_devirt_safe = %w[== ===].all? do |n|
      defs = @registry[n]
      defs && defs.size == 1 && defs.first.owner == '<native>'
    end
  end

  # NATIVE_PRIMITIVE_SEND_ARITY: native methods compile_native_primitive_send can
  # inline, with the exact arity a call site must match (MRB_ARGS_NONE /
  # MRB_ARGS_REQ(1) in src/kernel.c, class.c, hash.c, string.c, numeric.c,
  # array.c, range.c). to_s/length/first/dup/=== have several native bodies;
  # see their *_TYPE_TAG_DISPATCH comments. to_i is arity 0 only (see
  # TO_I_TYPE_TAG_DISPATCH).
  # Not listed because a bytecode override makes native_only_mono? false (they
  # would be dead code): push (RPG2k#push), << (RGSS::ErrorReport::Tee#<<),
  # clear (RGSS::ErrorReport.clear), include? (mruby-rgss array_include.rb),
  # member? (Game::Battle::Combatant#member?). empty? and size also have
  # bytecode definitions (Game::MoveRoute#empty?, Game::Party#size), so they use
  # per-class guards below; size excludes String because its body uses the
  # private, build-flag-dependent RSTRING_CHAR_LEN.
  NATIVE_PRIMITIVE_SEND_ARITY = { '!' => 0, 'nil?' => 0, 'is_a?' => 1, 'kind_of?' => 1,
                                   'equal?' => 1, 'class' => 0, 'object_id' => 0, 'keys' => 0,
                                   'values' => 0,
                                   'to_s' => 0, 'length' => 0, 'first' => 0, 'dup' => 0,
                                   '===' => 1, '!=' => 1, 'to_i' => 0, 'respond_to?' => 1 }.freeze

  # Shared gate for NATIVE_PRIMITIVE_SEND_ARITY: `name` has exactly one registry
  # def and it is the native placeholder (irep nil). The opposite of
  # monomorphic_target, which needs an `_impl`. A game-side `def nil?` would add
  # a second def and fall back to POLY dispatch. Without NATIVE_SRCS there is no
  # placeholder, so nothing is proven.
  def native_only_mono?(name)
    defs = @registry[name]
    defs && defs.size == 1 && defs.first.irep.nil?
  end

  # Permit per-class fast paths only for exact built-in receivers, with a
  # native registration present and no Ruby replacement on those classes.
  # A prepend can sit ahead of the native method, so decline the fast path
  # for any base class with a known or unresolved prepend.
  def builtin_class_send_safe?(name, builtins)
    @builtin_class_send_safe ||= {}
    cache_key = [name, builtins]
    return @builtin_class_send_safe[cache_key] if @builtin_class_send_safe.key?(cache_key)

    defs = @registry[name]
    @builtin_class_send_safe[cache_key] = defs && defs.any? { |d| d.owner == '<native>' && d.irep.nil? } &&
                                          defs.none? { |d| builtins.include?(d.owner) } &&
                                          builtins.none? do |owner|
                                            !Array(@prepended_modules[owner]).empty? || @unknown_mixins.include?(owner)
                                          end
  end

  # Guarded direct C++ for one NATIVE_PRIMITIVE_SEND_ARITY name, or an exact-class
  # expression generated from registered native C methods. The per-method
  # soundness notes are at compile_send's call site.
  def compile_native_primitive_send(name, d, recv, argv)
    return compile_native_registered_expression(name, d, recv, argv) if @native_registered_expressions.key?(name)

    case name
    when 'respond_to?'
      # Kernel#respond_to? converts its name with mrb_obj_to_sym, then calls
      # mrb_respond_to; on a miss it may call an overridden respond_to_missing?.
      # Answer hits directly and keep the original call for misses. compile_send's
      # arity and native-only gates ensure the core method is the target.
      method_name = argv.first
      fallback = dynamic_dispatch_line(d, recv, name, argv)
      <<~CPP
          // respond_to? -- answer native hits directly; preserve missing-hook behavior on misses
          {
            // Braced so the symbol neither redeclares across sends that reuse
            // register #{d} nor sits between a goto and its label.
            mrb_sym bc2cpp_respond_to_id = mrb_obj_to_sym(M, #{method_name});
            if (mrb_respond_to(M, #{recv}, bc2cpp_respond_to_id)) {
              r#{d} = mrb_true_value();
            } else {
              #{fallback.chomp}
            }
          }
      CPP
    when '!'
      expression = @native_expression_devirt[name]
      if expression
        "  // ! -- generated from mruby's registered C implementation\n" \
          "  r#{d} = #{expression.gsub('recv', recv)};\n"
      else
        "  r#{d} = mrb_funcall(M, #{recv}, \"!\", 0);\n"
      end
    when 'nil?'
      "  // nil? -- native primitive, no lookup needed\n" \
      "  r#{d} = mrb_bool_value(mrb_nil_p(#{recv}));\n"
    when 'is_a?', 'kind_of?'
      arg = argv.first
      "  // #{name} -- native primitive, no lookup needed (argument type-checked at " \
      "runtime -- see compile_send's own comment)\n" \
      "  if (mrb_class_p(#{arg}) || mrb_module_p(#{arg})) {\n" \
      "    r#{d} = mrb_bool_value(mrb_obj_is_kind_of(M, #{recv}, mrb_class_ptr(#{arg})));\n" \
      "  } else {\n" \
      "    #{dynamic_dispatch_line(d, recv, name, argv)}" \
      "  }\n"
    when 'equal?'
      arg = argv.first
      "  // equal? -- native primitive, no lookup needed (mrb_obj_equal is a real\n" \
      "  // public MRB_API, safe for any receiver/argument pair -- no struct cast)\n" \
      "  r#{d} = mrb_bool_value(mrb_obj_equal(M, #{recv}, #{arg}));\n"
    when 'class'
      "  // class -- native primitive, no lookup needed (mrb_obj_class is a real\n" \
      "  // public MRB_API, safe for any receiver -- no struct cast)\n" \
      "  r#{d} = mrb_obj_value(mrb_obj_class(M, #{recv}));\n"
    when 'object_id'
      "  // object_id -- native primitive, no lookup needed (mrb_obj_id is a real\n" \
      "  // public MRB_API, safe for any receiver -- no struct cast)\n" \
      "  r#{d} = mrb_fixnum_value(mrb_obj_id(#{recv}));\n"
    when 'keys'
      # KEYS_TYPE_TAG_GUARD: mrb_hash_keys casts through mrb_hash_ptr unchecked
      # (mruby/hash.h), so a non-Hash receiver would be undefined behavior. Guard on
      # mrb_hash_p; otherwise mrb_funcall raises the real NoMethodError
      # (native_only_mono? proved no other `keys` exists).
      "  // keys -- native primitive, runtime-guarded (mrb_hash_keys casts straight\n" \
      "  // to struct RHash*, unsafe on a non-Hash receiver -- see compile_native_\n" \
      "  // primitive_send's own KEYS_TYPE_TAG_GUARD comment)\n" \
      "  if (mrb_hash_p(#{recv})) {\n" \
      "    r#{d} = mrb_hash_keys(M, #{recv});\n" \
      "  } else {\n" \
      "    #{dynamic_dispatch_line(d, recv, name, argv)}" \
      "  }\n"
    when 'values'
      # mrb_hash_values (mruby/hash.h) is the public native body for
      # Hash#values, but like mrb_hash_keys it casts through mrb_hash_ptr
      # without checking the receiver tag. Require an exact base Hash so a
      # subclass override keeps ordinary Ruby lookup; all other receiver
      # types also stay on that path.
      fallback = dynamic_dispatch_line(d, recv, name, argv)
      <<~CPP
          // HASH_VALUES :values -- exact base Hash only; preserve subclass overrides and non-Hash errors
          if (mrb_hash_p(#{recv}) && mrb_obj_ptr(#{recv})->c == M->hash_class) {
            r#{d} = mrb_hash_values(M, #{recv});
          } else {
            #{fallback.chomp}
          }
      CPP
    when 'key?'
      # mrb_hash_key_p is Hash-specific and casts through mrb_hash_ptr
      # without checking the receiver tag. Exact base Hash preserves
      # subclass/singleton overrides; every other value keeps Ruby lookup.
      key = argv.first
      fallback = dynamic_dispatch_line(d, recv, name, argv)
      <<~CPP
          // HASH_KEY_P :key? -- exact base Hash only; preserve overrides and non-Hash errors
          if (mrb_hash_p(#{recv}) && mrb_obj_ptr(#{recv})->c == M->hash_class) {
            r#{d} = mrb_bool_value(mrb_hash_key_p(M, #{recv}, #{key}));
          } else {
            #{fallback.chomp}
          }
      CPP
    when 'to_s'
      # TO_S_TYPE_TAG_DISPATCH: `to_s` has many native bodies (Array, String, Hash,
      # Integer, Float, Range, Module, Kernel) collapsed into one `<native>` entry,
      # so this switches on mrb_type(recv) and handles only tags whose body is safe
      # to run outside a dispatched frame; everything else uses mrb_funcall.
      #   MRB_TT_STRING: mrb_str_to_s (string.c, static) is `mrb_obj_class(mrb,
      #   self) != mrb->string_class ? mrb_str_dup(mrb, self) : self`, reproduced.
      #   MRB_TT_INTEGER: int_to_s is mrb_integer_to_str(mrb, self, 10) for n == 0
      #   (a public MRB_API).
      # Array/Hash are excluded: mrb_ary_to_s/mrb_hash_to_s start with
      # `mrb->c->ci->mid = MRB_SYM(inspect);`, which would corrupt the current
      # frame. Float/Range (static, no public equivalent) and Class/Module
      # (mrb_mod_to_s is internal.h-only) are excluded too.
      "  // to_s -- native primitive, runtime-guarded per real receiver type\n" \
      "  // (only String/Integer are handled directly -- see compile_native_\n" \
      "  // primitive_send's own TO_S_TYPE_TAG_DISPATCH comment for why Array/\n" \
      "  // Hash/Float/Range/Class are deliberately left to ordinary dispatch)\n" \
      "  switch (mrb_type(#{recv})) {\n" \
      "  case MRB_TT_STRING:\n" \
      "    r#{d} = mrb_obj_class(M, #{recv}) != M->string_class ? mrb_str_dup(M, #{recv}) : #{recv};\n" \
      "    break;\n" \
      "  case MRB_TT_INTEGER:\n" \
      "    r#{d} = mrb_integer_to_str(M, #{recv}, 10);\n" \
      "    break;\n" \
      "  default:\n" \
      "    #{dynamic_dispatch_line(d, recv, name, argv)}" \
      "    break;\n" \
      "  }\n"
    when 'length'
      # LENGTH_TYPE_TAG_DISPATCH: Array (mrb_ary_size: ARY_LEN) and Hash
      # (mrb_hash_size, public) are handled. String is excluded: mrb_str_size uses
      # RSTRING_CHAR_LEN, defined only inside string.c and dependent on
      # MRB_UTF8_STRING, so hardcoding it would couple to the build config.
      "  // length -- native primitive, runtime-guarded per real receiver type\n" \
      "  // (only Array/Hash are handled directly -- String is deliberately left\n" \
      "  // to ordinary dispatch, see compile_native_primitive_send's own\n" \
      "  // LENGTH_TYPE_TAG_DISPATCH comment for why)\n" \
      "  switch (mrb_type(#{recv})) {\n" \
      "  case MRB_TT_ARRAY:\n" \
      "    r#{d} = mrb_int_value(M, ARY_LEN(mrb_ary_ptr(#{recv})));\n" \
      "    break;\n" \
      "  case MRB_TT_HASH:\n" \
      "    r#{d} = mrb_int_value(M, mrb_hash_size(M, #{recv}));\n" \
      "    break;\n" \
      "  default:\n" \
      "    #{dynamic_dispatch_line(d, recv, name, argv)}" \
      "    break;\n" \
      "  }\n"
    when 'first'
      # FIRST_TYPE_TAG_DISPATCH: arity 0 only (`x.first(n)` never reaches here).
      # MRB_TT_ARRAY: reproduce mrb_ary_first's zero-argument body (calling it would
      # make mrb_get_argc read the caller's frame), behind exact base-Array identity
      # so subclasses and singletons keep Ruby dispatch.
      # MRB_TT_RANGE: range_beg (registered as `first`, ARGS_NONE) is
      # mrb_range_beg(mrb, range), a public macro.
      # Everything else uses mrb_funcall.
      "  // first -- native primitive, runtime-guarded for Range and exact Array\n" \
      "  // directly -- see compile_native_primitive_send's own\n" \
      "  // FIRST_TYPE_TAG_DISPATCH comment for Array's zero-arg expression)\n" \
      "  if (mrb_range_p(#{recv})) {\n" \
      "    r#{d} = mrb_range_beg(M, #{recv});\n" \
      "  } else if (mrb_array_p(#{recv}) && mrb_obj_ptr(#{recv})->c == M->array_class) {\n" \
      "    struct RArray* bc2cpp_first_array = mrb_ary_ptr(#{recv});\n" \
      "    r#{d} = ARY_LEN(bc2cpp_first_array) > 0 ? ARY_PTR(bc2cpp_first_array)[0] : mrb_nil_value();\n" \
      "  } else {\n" \
      "    #{dynamic_dispatch_line(d, recv, name, argv)}" \
      "  }\n"
    when '==='
      # EQQ_TYPE_TAG_DISPATCH: `===` has three native bodies, all static and reading
      # their argument via mrb_get_arg1 (a frame read), so each is reproduced from
      # public APIs:
      #   - CLASS/MODULE/SCLASS: mrb_mod_eqq is mrb_obj_is_kind_of(mrb, arg,
      #     mrb_class_ptr(mod)).
      #   - RANGE: range_include (range.c) with mrb_range_beg/end/excl_p and mrb_cmp
      #     in place of its static r_le/r_gt/r_ge; the switch is the type guard.
      #   - INTEGER/FLOAT/STRING/SYMBOL/TRUE/FALSE/ARRAY/HASH: mrb_eqq_m is
      #     mrb_bool_value(mrb_equal(mrb, self, arg)). nil is MRB_TT_FALSE
      #     (mruby/value.h), so no MRB_TT_NIL case exists (it would not compile).
      # Excluded: MRB_TT_DATA (mruby-onig-regexp's Regexp has a bytecode `#===`
      # outside closed_world_mrblib_srcs, and many wrapper types share the tag) and
      # MRB_TT_PROC (mruby-proc-ext's bytecode Proc#===). They use mrb_funcall.
      arg = argv.first
      # EQQ_INTEGER_FAST: `case cmd.code when Cmd::X` is one `===` per arm, and for
      # an Integer receiver mrb_equal falls back to funcall("==") whenever the values
      # differ (Integer#== is not the basic identity method). Two Integers are
      # decided natively whenever no Ruby-defined Integer#== is observable (the
      # closed-world gate); mixed Integer/Float or bigint still goes through
      # mrb_equal.
      integer_case =
        if builtin_class_send_safe?('==', %w[Integer])
          "  case MRB_TT_INTEGER:\n" \
            "    if (mrb_integer_p(#{arg})) {\n" \
            "      r#{d} = mrb_bool_value(mrb_integer(#{recv}) == mrb_integer(#{arg}));\n" \
            "      break;\n" \
            "    }\n" \
            "    r#{d} = mrb_bool_value(mrb_equal(M, #{recv}, #{arg}));\n" \
            "    break;\n"
        else
          "  case MRB_TT_INTEGER:\n"
        end
      "  // === -- native primitive, runtime-guarded per real receiver type\n" \
      "  // (see compile_native_primitive_send's own EQQ_TYPE_TAG_DISPATCH\n" \
      "  // comment for why MRB_TT_DATA/MRB_TT_PROC and everything else fall\n" \
      "  // through to ordinary dispatch)\n" \
      "  switch (mrb_type(#{recv})) {\n" \
      "  case MRB_TT_CLASS:\n" \
      "  case MRB_TT_MODULE:\n" \
      "  case MRB_TT_SCLASS:\n" \
      "    r#{d} = mrb_bool_value(mrb_obj_is_kind_of(M, #{arg}, mrb_class_ptr(#{recv})));\n" \
      "    break;\n" \
      "  case MRB_TT_RANGE: {\n" \
      "    mrb_value bc2cpp_eqq_beg#{d} = mrb_range_beg(M, #{recv});\n" \
      "    mrb_value bc2cpp_eqq_end#{d} = mrb_range_end(M, #{recv});\n" \
      "    mrb_bool bc2cpp_eqq_excl#{d} = mrb_range_excl_p(M, #{recv});\n" \
      "    mrb_bool bc2cpp_eqq_r#{d} = FALSE;\n" \
      "    if (mrb_nil_p(bc2cpp_eqq_beg#{d})) {\n" \
      "      mrb_int bc2cpp_eqq_c#{d} = mrb_cmp(M, bc2cpp_eqq_end#{d}, #{arg});\n" \
      "      bc2cpp_eqq_r#{d} = bc2cpp_eqq_excl#{d} ? (bc2cpp_eqq_c#{d} == 1) : (bc2cpp_eqq_c#{d} == 0 || bc2cpp_eqq_c#{d} == 1);\n" \
      "    } else {\n" \
      "      mrb_int bc2cpp_eqq_cb#{d} = mrb_cmp(M, bc2cpp_eqq_beg#{d}, #{arg});\n" \
      "      if (bc2cpp_eqq_cb#{d} == 0 || bc2cpp_eqq_cb#{d} == -1) {\n" \
      "        if (mrb_nil_p(bc2cpp_eqq_end#{d})) {\n" \
      "          bc2cpp_eqq_r#{d} = TRUE;\n" \
      "        } else {\n" \
      "          mrb_int bc2cpp_eqq_ce#{d} = mrb_cmp(M, bc2cpp_eqq_end#{d}, #{arg});\n" \
      "          bc2cpp_eqq_r#{d} = bc2cpp_eqq_excl#{d} ? (bc2cpp_eqq_ce#{d} == 1) : (bc2cpp_eqq_ce#{d} == 0 || bc2cpp_eqq_ce#{d} == 1);\n" \
      "        }\n" \
      "      }\n" \
      "    }\n" \
      "    r#{d} = mrb_bool_value(bc2cpp_eqq_r#{d});\n" \
      "    break;\n" \
      "  }\n" \
      "#{integer_case}" \
      "  case MRB_TT_FLOAT:\n" \
      "  case MRB_TT_STRING:\n" \
      "  case MRB_TT_SYMBOL:\n" \
      "  case MRB_TT_TRUE:\n" \
      "  case MRB_TT_FALSE:\n" \
      "  case MRB_TT_ARRAY:\n" \
      "  case MRB_TT_HASH:\n" \
      "    r#{d} = mrb_bool_value(mrb_equal(M, #{recv}, #{arg}));\n" \
      "    break;\n" \
      "  default:\n" \
      "    #{dynamic_dispatch_line(d, recv, name, argv)}" \
      "    break;\n" \
      "  }\n"
    when 'dup'
      # DUP_TYPE_TAG_DISPATCH: exhaustive, no mrb_funcall arm. `dup` has two native
      # registrations: mrb_obj_dup (Kernel, MRB_API; immediates return self, others
      # mrb_obj_alloc + init_copy, which still dispatches #initialize_copy) and
      # mrb_mod_dup (Class/Module, static: `mrb_obj_clone` then clear `frozen`,
      # reproduced). The default arm calls mrb_obj_dup directly.
      "  // dup -- native primitive, no lookup needed for any receiver (exactly\n" \
      "  // two real native implementations exist, both handled directly -- see\n" \
      "  // compile_native_primitive_send's own DUP_TYPE_TAG_DISPATCH comment)\n" \
      "  switch (mrb_type(#{recv})) {\n" \
      "  case MRB_TT_CLASS:\n" \
      "  case MRB_TT_MODULE:\n" \
      "  case MRB_TT_SCLASS:\n" \
      "    r#{d} = mrb_obj_clone(M, #{recv});\n" \
      "    mrb_obj_ptr(r#{d})->frozen = 0;\n" \
      "    break;\n" \
      "  default:\n" \
      "    r#{d} = mrb_obj_dup(M, #{recv});\n" \
      "    break;\n" \
      "  }\n"
    when '!='
      # NEQ_UNCONDITIONAL: `!=` is a hand-written bytecode RProc in class.c bob_init
      # (`return !(self == other)`), registered via mrb_define_method_raw (hence that
      # scan in extract_native_method_names). vm.c OP_EQ is identity, then a
      # hardcoded false for Symbols, then numeric fast paths or SEND :==. mrb_equal
      # (src/object.c) gives the same answer for every type (for a Symbol with the
      # default `==`, mrb_func_basic_p skips dispatch and returns false), so
      # `!mrb_equal(...)` needs no fallback.
      arg = argv.first
      "  // != -- native primitive, no lookup needed for any receiver (real\n" \
      "  // bytecode is exactly `!(self == other)`, mrb_equal reproduces ==\n" \
      "  // exactly for every type -- see compile_native_primitive_send's own\n" \
      "  // NEQ_UNCONDITIONAL comment)\n" \
      "  r#{d} = mrb_bool_value(!mrb_equal(M, #{recv}, #{arg}));\n"
    when 'to_i'
      # TO_I_TYPE_TAG_DISPATCH: `to_i` natives reachable in this build: Integer,
      # Float, String, and Time (mruby-time; complex/rational/object-ext are not in
      # build_config.rb).
      #   INTEGER: mrb_obj_itself (`return self;`).
      #   FLOAT: flo_to_i checks NaN/Infinity (mrb_check_num_exact, internal.h
      #   only, so reproduced with isinf/isnan + mrb_raise) and promotes to Bignum
      #   when !FIXABLE_FLOAT (mrb_bint_new_float/mrb_int_overflow, internal.h only).
      #   Only the finite, in-range case is handled (floor/ceil + mrb_int_value);
      #   the rest uses mrb_funcall.
      #   STRING: mrb_str_to_i reads `mrb_get_args(mrb, "|i", &base)`, but for the
      #   arity-0 shape base is always 10, so it is mrb_str_to_integer(mrb, self,
      #   10, FALSE). `str.to_i(base)` never reaches this table.
      # Time is excluded: time_to_i reads `struct mrb_time`, private to time.c.
      "  // to_i -- native primitive, runtime-guarded per real receiver type\n" \
      "  // (Integer/Float/String handled directly -- see compile_native_\n" \
      "  // primitive_send's own TO_I_TYPE_TAG_DISPATCH comment for why Time\n" \
      "  // and Float's own NaN/Infinity/overflow edge are deliberately left\n" \
      "  // to ordinary dispatch)\n" \
      "  switch (mrb_type(#{recv})) {\n" \
      "  case MRB_TT_INTEGER:\n" \
      "    r#{d} = #{recv};\n" \
      "    break;\n" \
      "  case MRB_TT_FLOAT: {\n" \
      "    mrb_float bc2cpp_toi_f#{d} = mrb_float(#{recv});\n" \
      "    if (isnan(bc2cpp_toi_f#{d}) || isinf(bc2cpp_toi_f#{d}) || !FIXABLE_FLOAT(bc2cpp_toi_f#{d})) {\n" \
      "      #{dynamic_dispatch_line(d, recv, name, argv)}" \
      "    } else {\n" \
      "      if (bc2cpp_toi_f#{d} > 0.0) bc2cpp_toi_f#{d} = floor(bc2cpp_toi_f#{d});\n" \
      "      if (bc2cpp_toi_f#{d} < 0.0) bc2cpp_toi_f#{d} = ceil(bc2cpp_toi_f#{d});\n" \
      "      r#{d} = mrb_int_value(M, (mrb_int)bc2cpp_toi_f#{d});\n" \
      "    }\n" \
      "    break;\n" \
      "  }\n" \
      "  case MRB_TT_STRING:\n" \
      "    r#{d} = mrb_str_to_integer(M, #{recv}, 10, FALSE);\n" \
      "    break;\n" \
      "  default:\n" \
      "    #{dynamic_dispatch_line(d, recv, name, argv)}" \
      "    break;\n" \
      "  }\n"
    end
  end

  # INTEGER_UNARY: an Integer runs Numeric#-@ (`0 - self`), Numeric#zero? (`self == 0`),
  # both Ruby in libmruby, and int_round (`self`); see docs/adr/0200.
  INTEGER_UNARY_OPS = {
    '-@' => ['mrb_int_value(M, -mrb_integer(%<r>s))', ' && mrb_integer(%<r>s) != MRB_INT_MIN'],
    'zero?' => ['mrb_bool_value(mrb_integer(%<r>s) == 0)', ''],
    'round' => ['%<r>s', '']
  }.freeze

  def compile_integer_unary(name, n, d, recv, argv)
    value, extra_guard = INTEGER_UNARY_OPS[name]
    return nil unless value && n.zero? && native_only_mono?(name) && integer_ancestry_native?(name)

    <<~CPP
        // INTEGER_UNARY :#{name} -- Integer receiver computed inline; anything else keeps the dispatch
        if (mrb_integer_p(#{recv})#{format(extra_guard, r: recv)}) {
          r#{d} = #{format(value, r: recv)};
        } else {
          #{dynamic_dispatch_line(d, recv, name, argv).chomp}
        }
    CPP
  end

  # builtin_class_send_safe? over Integer's ancestry and every module mixed into it.
  def integer_ancestry_native?(name)
    owners = %w[Integer Numeric Comparable]
    queue = owners.dup
    until queue.empty?
      owner = queue.shift
      (Array(@included_modules[owner]) + Array(@prepended_modules[owner])).each do |mod|
        next if owners.include?(mod)

        owners << mod
        queue << mod
      end
    end
    builtin_class_send_safe?(name, owners)
  end

  # Emit a generated native expression behind a runtime type-tag guard. Heap
  # objects also require their exact built-in class pointer; Float and Symbol
  # are immediate values and use only their unambiguous type tags.
  def compile_native_registered_expression(name, d, recv, argv)
    entries = @native_registered_expressions[name]
    fallback = dynamic_dispatch_line(d, recv, name, argv)
    return fallback unless entries && !entries.empty?
    return fallback unless entries.all? { |entry| entry[:arity] == argv.length }

    cases = entries.map do |entry|
      owner = entry[:owner]
      expression = entry[:expression].gsub('recv', recv)
      expression = expression.gsub('BC2CPP_ARG0', argv.fetch(0)) if entry[:arity] == 1
      source_comment = if name == 'clear' && owner[:class_name] == 'Array' && expression.include?('mrb_ary_clear')
                         '// ARRAY_CLEAR :clear -- generated from mruby core C'
                       end
      class_check = if %w[Float Symbol].include?(owner[:class_name])
                      "r#{d} = #{expression};"
                    else
                      <<~CPP.chomp
                        if (mrb_obj_ptr(#{recv})->c == M->#{owner[:field]}) {
                          r#{d} = #{expression};
                        } else {
                          #{fallback.chomp}
                        }
                      CPP
      end
      <<~CPP
        #{source_comment}
        case #{owner[:tag]}:
          #{class_check.gsub("\n", "\n  ")}
          break;
      CPP
    end.join
    <<~CPP
      // #{name} -- generated from native registrations and C method bodies
      switch (mrb_type(#{recv})) {
      #{cases}
      default:
        #{fallback.chomp}
        break;
      }
    CPP
  end

  # INTERP_UNLOCK: does MONO method `name` carry a hand-placed `-> Array`
  # annotation? Consumed by proven_array_source's chained rule. MONO-only (an
  # annotation sits on one irep). No compiles_clean? requirement: the fact is
  # about the return value only. Sound because the annotation is hand-placed
  # AND every admitted site passes the emitter's mrb_array_p tripwire, which
  # raises on a wrong claim. Unknown tokens resolve to nil.
  def annotated_array_return(name)
    defs = @registry[name]
    return false unless defs && defs.size == 1 && defs.first.irep

    label = defs.first.irep
    # `Array<Klass>` also claims an Array result, so it opens the same gate;
    # annotated_element_return supplies the element class.
    @annotations[label]&.ret == :array || !@element_annotations[label]&.element.nil?
  end

  # ELEMENT_CLASS_SUPPORT: annotated_array_return's MONO-keyed lookup for the
  # element dimension (see ElementAnnotations).
  def annotated_element_return(name)
    defs = @registry[name]
    return nil unless defs && defs.size == 1 && defs.first.irep

    @element_annotations[defs.first.irep]&.element
  end

  def annotated_ret_class(name)
    defs = @registry[name]
    return nil unless defs && defs.size == 1 && defs.first.irep

    @element_annotations[defs.first.irep]&.ret_class
  end

  # ELEMENT_CLASS_SUPPORT: element class of a proven-Array block receiver, from
  # the same scan ArrayElementLayout uses (so they cannot drift). nil (the usual
  # answer) leaves per-element calls as POLY mrb_funcall.
  def proven_element_class(irep, idx, dest_reg, ivar_classes, mand, arg_classes, owner_name)
    array_element_source_scan(irep, idx, dest_reg, element_ctx(ivar_classes, mand, arg_classes, owner_name))
  end

  # Memoized: the registry is fixed after CodeGen.new.
  def known_owner_set
    @known_owner_set ||= Set.new(@registry.values.flatten.map(&:owner))
  end

  # Classes some other class inherits from (see self_receiver_class). Memoized;
  # @superclass_of is fixed.
  def subclassed_set
    @subclassed_set ||= Set.new(@superclass_of.values.select { |v| v.is_a?(String) })
  end

  # The class whose instance `self` is while compiling `owner_def`'s code, or nil
  # inside a runtime-def/EXEC body, whose self is whatever receiver mruby passes.
  def self_class(owner_def)
    @self_class_unknown ? nil : owner_def.owner
  end

  # LEXICAL_SELF_SUPPORT: compile_send's version of self_receiver_class (see it
  # for the soundness argument: no subclass anywhere, and `.singleton` owners
  # refused), using this CodeGen's memoized sets instead of a `ctx` hash.
  def lexical_self_owner(owner_def)
    return nil unless owner_def && self_class(owner_def)

    owner = owner_def.owner
    return nil if owner.nil? || owner.end_with?('.singleton')
    return nil unless known_owner_set.include?(owner)
    return nil if subclassed_set.include?(owner)

    owner
  end

  # SINGLETON_LEXICAL_SELF: `self` in `def self.x` of X is X itself unless X is a
  # subclassed class (a module never is), and X's own singleton def wins lookup.
  def lexical_self_singleton_owner(owner_def)
    return nil unless owner_def && self_class(owner_def)

    owner = owner_def.owner
    return nil unless owner&.end_with?('.singleton')

    base = owner.delete_suffix('.singleton')
    # Top-level `def self.x` is main's singleton, also spelled "Object.singleton".
    return nil if base == 'Object' || subclassed_set.include?(base)
    return nil unless Array(@prepended_modules[owner]).empty?
    return nil if @unknown_mixins.include?(owner) || @unknown_mixins.include?(base)

    owner
  end

  # The one irep def `name` has on that singleton owner (module_function copies
  # have no irep; a second def would make "which one is live" order-dependent).
  def lexical_self_singleton_def(name, owner_def)
    owner = lexical_self_singleton_owner(owner_def)
    return nil unless owner

    defs = (@registry[name] || []).select { |md| md.owner == owner }
    defs.size == 1 && defs.first.irep ? defs.first : nil
  end

  # LEXICAL_SELF_KEYWORD_SUPPORT: monomorphic_target's role for
  # compile_keyword_call, for a POLY name sent with no explicit receiver. `self`
  # in a method of C is a C, and lexical_self_owner has proven no subclass of C
  # exists, so dispatch can only reach C's definition (the same reasoning as
  # super_target and compile_send's LEXICAL_SELF branch).
  # Extra guard: devirt_blocked_name? up front (a name installed on a runtime
  # singleton class can shadow even a known self's method); the LEXICAL_SELF
  # marker is not in RUNTIME_DEF_DYNAMIC_MARKERS, so the text audit still
  # applies. Arity/keyword-shape checks stay in compile_keyword_call.
  # Limit: subclassed_set comes from @superclass_of, which has no entry for an
  # unresolvable superclass expression, so such a subclass would not mark its
  # parent. The closed world has none (every superclass resolves, no
  # Class.new), and the same limit applies to LEXICAL_SELF and
  # self_receiver_class.
  # nil for explicit-receiver sends.
  def lexical_self_keyword_target(name, self_implicit:, owner_def:)
    return nil unless self_implicit
    return nil if devirt_blocked_name?(name)

    lex_owner = lexical_self_owner(owner_def)
    candidate = if lex_owner
                  @registry[name]&.find { |md| md.owner == lex_owner }
                else
                  lexical_self_singleton_def(name, owner_def)
                end
    return nil unless candidate&.irep
    return nil unless compiles_clean?(candidate.irep)

    candidate
  end

  def element_ctx(ivar_classes, mand, arg_classes, owner_name)
    { owner: owner_name, registry: @registry, class_layout: @class_layout, ireps: @ireps,
      class_annotations: @class_annotations, element_annotations: @element_annotations,
      known_owners: known_owner_set, subclassed: subclassed_set,
      ivar_classes: ivar_classes || {}, mand: mand, arg_classes: arg_classes,
      elements: @element_layout,
      annotated_element: ->(n) { annotated_element_return(n) },
      annotated_ret_class: ->(n) { annotated_ret_class(n) } }
  end

  # HASH_ELEMENT_SUPPORT: proven_element_class for Hash values.
  def proven_hash_element_class(irep, idx, dest_reg, ivar_classes, mand, arg_classes, owner_name)
    hash_element_source_scan(irep, idx, dest_reg, hash_element_ctx(ivar_classes, mand, arg_classes, owner_name))
  end

  def hash_element_ctx(ivar_classes, mand, arg_classes, owner_name)
    { owner: owner_name, registry: @registry, class_layout: @class_layout, ireps: @ireps,
      class_annotations: @class_annotations, element_annotations: @element_annotations,
      known_owners: known_owner_set, subclassed: subclassed_set,
      ivar_classes: ivar_classes || {}, mand: mand, arg_classes: arg_classes,
      elements: @element_layout, hash_elements: @hash_element_layout,
      annotated_element: ->(n) { annotated_element_return(n) },
      annotated_ret_class: ->(n) { annotated_ret_class(n) } }
  end

  # SYM_DEVIRT: resolve a `&:sym` target inside emit_sym_inline. Returns
  # [:mono, def], [:poly, defs] or nil, applying compile_send's MONO guards
  # (pure-mandatory arity, arity 0 since recognize_sym_regions requires n=0,
  # ONLY_OWNERS/OTHER_OWNERS). POLY needs a per-element class guard per
  # candidate and is capped at SYM_DEVIRT_CHAIN_CAP. Anything else keeps
  # mrb_funcall.
  SYM_DEVIRT_CHAIN_CAP = 4

  def sym_call_target(sym)
    defs = @registry[sym]
    return nil unless defs

    usable = defs.select do |d|
      next false unless d.irep
      next false unless pure_mandatory_arity?(@ireps.fetch(d.irep))
      next false unless mandatory_arity(@ireps.fetch(d.irep)).zero?
      next false unless compiles_clean?(d.irep)
      next false if @only_owners && !@only_owners.include?(d.owner) && !(@other_owners&.include?(d.owner))

      true
    end
    # All or nothing: skipping a def is unsound for MONO and would misroute
    # elements in a partial POLY chain if the fallback were ever dropped.
    return nil unless usable.size == defs.size && !usable.empty?

    return [:mono, usable.first] if usable.size == 1
    return [:poly, usable] if usable.size <= SYM_DEVIRT_CHAIN_CAP

    nil
  end

  # ANCESTOR_MIXINS_SUPPORT: can `super` in owner_def provably reach the declared
  # superclass, i.e. no included module in between (mruby searches [class,
  # included modules newest-first, superclass, ...])?
  # Declines whenever the owner has ANY plain `include`: a bare `include M` in a
  # class body is resolved relative to the class ("Foo::M"), while
  # build_registry names the module's methods by the module's own path ("M"),
  # so matching module owners could wrongly prove a `super` safe. Only
  # presence is consulted. Prepended modules sit above the class and are not
  # consulted.
  def super_reaches_superclass?(owner_def)
    owner = owner_def.owner
    return false if @unknown_mixins.include?(owner)

    Array(@included_modules[owner]).empty?
  end

  # ZSUPER_GENERAL_SUPPORT (ADR 0159): a bare `super` forwarding the current
  # method's arguments to a COMPILED superclass method. codegen_zsuper emits:
  #
  #   ARGARY R(a+1)  m1:0:0:0 (0)   # packs the CURRENT frame's regs[1..m1]
  #   SUPER  R(a)    n=*            # superes ci->mid, reading that array
  #
  # OP_ARGARY with lv==0 copies regs + 1, so the forwarded arguments are r1..rm1
  # and the call is `Super#name_impl(M, self, r1, ..., rm1)`. `idx` may name
  # either half; both resolve to the same answer (as in zsuper_native_kind).
  # Every fact is re-checked per site from the bytecode:
  def zsuper_forward_plan(owner_def, irep, idx)
    return nil unless owner_def && irep && idx

    instructions = irep.instructions

    # (1) The adjacent ARGARY + SUPER pair (`SUPER R(a)` + `ARGARY R(a+1)`). An
    # interposed EXT declines.
    argary_idx = instructions[idx]&.op == 'ARGARY' ? idx : idx - 1
    return nil if argary_idx.negative?

    argary = instructions[argary_idx]
    super_insn = instructions[argary_idx + 1]
    return nil unless argary && super_insn
    return nil unless argary.op == 'ARGARY' && super_insn.op == 'SUPER'

    # (2) SUPER is the `n=*` zsuper splat, not the fixed `n=N` shape or the
    # keyword `nk=` variant.
    return nil unless super_insn.args.split(/\s+/, 2)[1].to_s.strip == 'n=*'

    # (3) ARGARY is `m1:0:0:0 (0)`: no rest, post, kd, and lv==0 (this frame's
    # registers). m1 is the forwarded count.
    am = argary.args.match(/\AR(\d+)\s+(\d+):(\d):(\d+):(\d)\s+\((\d+)\)/)
    return nil unless am

    argary_dest = am[1]
    m = am[2].to_i
    return nil unless am[3].to_i.zero? && am[4].to_i.zero? && am[5].to_i.zero? && am[6].to_i.zero?
    return nil if m.zero? # zero-param bare `super` is `SUPER ... n=0`, no ARGARY at all

    # (4) OP_SUPER reads regs[a+1], so ARGARY's dest must be SUPER's dest + 1.
    super_dest = super_insn.args[/^R(\d+)/, 1]
    return nil unless argary_dest && super_dest
    return nil unless argary_dest.to_i == super_dest.to_i + 1

    # (5) ENTER is exactly m mandatory and nothing else (REQ:OPT:REST:POST:KEY:
    # KDICT:BLOCK:NOBLOCK, src/codedump.c), so regs[1..m] is the whole argument
    # list and there is no block parameter.
    enter = instructions.find { |i| i.op == 'ENTER' }
    return nil unless enter

    em = enter.args.match(/\A(\d+):(\d+):(\d+):(\d+):(\d+):(\d+):(\d+)/)
    return nil unless em
    return nil unless em[2..7].all? { |x| x.to_i.zero? }
    return nil unless em[1].to_i == m

    # (6) The same-named method on the registered superclass exists, is bytecode
    # and compiles clean. A clean `_impl` never yields, so a caller's block is
    # unobservable (no caller grep needed, unlike SUPER_TARGETS).
    # super_reaches_superclass? rules out an included module in between.
    superclass = @superclass_of[owner_def.owner]
    return nil unless superclass.is_a?(String)
    return nil unless super_reaches_superclass?(owner_def)

    target_def = @registry[owner_def.name].find { |d| d.owner == superclass }
    return nil unless target_def && target_def.irep && compiles_clean?(target_def.irep)

    { target_def: target_def, m: m }
  end

  # ZSUPER_GENERAL_SUPPORT: a direct `_impl` call forwarding r1..m (what ARGARY
  # would have packed). `d_reg` is SUPER's destination.
  def compile_zsuper_forward(target_def, d_reg, m)
    args = (1..m).map { |i| ", r#{i}" }.join
    "  r#{d_reg} = #{cpp_name(target_def.owner, target_def.name)}_impl(M, self#{args});\n"
  end

  # SUPER_SUPPORT: the target of `super` in owner_def's method: the same-named
  # MethodDef on the declared superclass, only when "Owner#name" is in
  # SUPER_TARGETS (see it for the block-forwarding fact). The no-include fact is
  # re-derived by super_reaches_superclass?. Owner-relative, so a POLY name
  # still resolves, as real `super` does.
  def super_target(owner_def)
    return nil unless SUPER_TARGETS.include?("#{owner_def.owner}##{owner_def.name}")

    superclass = @superclass_of[owner_def.owner]
    return nil unless superclass.is_a?(String)
    # ANCESTOR_MIXINS_SUPPORT: re-derived every time; see
    # super_reaches_superclass?.
    return nil unless super_reaches_superclass?(owner_def)

    target_def = @registry[owner_def.name].find { |d| d.owner == superclass }
    return nil unless target_def && target_def.irep
    return nil unless compiles_clean?(target_def.irep)

    target_def
  end

  # ZSUPER_NATIVE_SUPPORT: which native method (a ZSUPER_NATIVE_SHAPES kind)
  # the ARGARY + `SUPER n=*` pair at `idx` reaches; nil keeps `#error`. `idx`
  # may be either half; both give the same answer so the two arms cannot emit
  # half a translation. Everything here is re-checked per site;
  # ZSUPER_NATIVE_TARGETS holds only the non-derivable remainder.
  def zsuper_native_kind(owner_def, irep, idx)
    return nil unless owner_def && irep && idx

    kind = ZSUPER_NATIVE_TARGETS["#{owner_def.owner}##{owner_def.name}"]
    return nil unless kind

    shape = ZSUPER_NATIVE_SHAPES.fetch(kind)
    # (1) Pin the name off the MethodDef, not the allowlist key.
    return nil unless owner_def.name == shape[:name]

    # (2) The adjacent pair codegen_zsuper emits (`SUPER R(a)` + `ARGARY R(a+1)`;
    # OP_SUPER reads the packed argument from regs[a+1]). `idx - 1` must not go
    # negative: Ruby would index from the end of the list.
    argary_idx = irep.instructions[idx]&.op == 'ARGARY' ? idx : idx - 1
    return nil if argary_idx.negative?

    argary = irep.instructions[argary_idx]
    super_insn = irep.instructions[argary_idx + 1]
    return nil unless argary && super_insn
    # Strict adjacency: an interposed EXT declines.
    return nil unless argary.op == 'ARGARY' && super_insn.op == 'SUPER'

    argary_dest = argary.args[/^R(\d+)/, 1]
    super_dest = super_insn.args[/^R(\d+)/, 1]
    return nil unless argary_dest && super_dest
    return nil unless argary_dest.to_i == super_dest.to_i + 1

    # (3) The `n=*` splat shape, not SUPER_TARGETS' fixed `n=N`.
    return nil unless super_insn.args.split(/\s+/, 2)[1].to_s.strip == 'n=*'

    # (4) The ARGARY spec this kind was derived against (`2:0:0:0` or `1:1:0:0`)
    # with lv=0 (plain regs+1) and kd=0. A changed parameter list declines.
    return nil unless argary.args[/\s(\d+:\d+:\d+:\d+)\s*\(/, 1] == shape[:argary]
    return nil unless argary.args[/\((\d+)\)\s*\z/, 1].to_s == '0'

    # (5) The superclass is the implicit Object (:none means a CLASS with no
    # superclass expression, not "unrecognized").
    return nil unless @superclass_of[owner_def.owner] == :none

    # (6) Nothing can intercept the name before the native target: every
    # registered definition belongs to a real CLASS in @superclass_of (so modules,
    # `.singleton` owners and unresolved classes refuse) that is not one of the
    # chain classes. Such a class cannot sit between the owner and Object, since
    # (5) made Object the owner's superclass. `<native>` is checked in (7).
    return nil unless @registry[owner_def.name].all? { |d|
      d.owner == '<native>' ||
        (@superclass_of.key?(d.owner) && !ZSUPER_NATIVE_BLOCKED_OWNERS.include?(d.owner))
    }

    # (7) NATIVE_SRCS has exactly the one definition being reproduced; a second
    # could be an override in the chain. A missing map (scan not run) declines.
    return nil unless @native_name_sources

    srcs = @native_name_sources[owner_def.name] || []
    return nil unless srcs.size == 1 && srcs.first.end_with?(shape[:native_src])

    kind
  end

  # Does compile_method(label) come out without `#error`? A MONO target with the
  # right arity can still have an unsupported opcode in its body; SKIP_UNSUPPORTED
  # then drops its `_impl` and a direct call to it fails to link. Compiling for
  # real (memoized) is the only way to answer without duplicating compile_insn's
  # opcode list. A label already being probed reports "not known clean" (safe
  # direction), so mutually recursive MONO methods just keep mrb_funcall.
  def compiles_clean?(label)
    return @clean_cache[label] if @clean_cache.key?(label)
    return false if @probing.include?(label)

    @probing << label
    begin
      result = with_fresh_method_state { compile_method(label) }
      @clean_cache[label] = !result[:code].include?('#error')
    ensure
      @probing.delete(label)
    end
  end

  # Every ivar one compile_method call sets and clears for itself, with its
  # top-level value. A probe runs mid-way through another method's compile.
  METHOD_COMPILE_STATE = {
    :@elem_class_hint => nil, :@block_hash_capture_hints => nil, :@block_fallback_upvars => nil,
    :@block_fallback_active => false, :@blk_param_name => nil, :@blk_param_level => 0,
    :@inline_nested => nil, :@inline_nested_pre => nil, :@suppress_native_expression_send => nil,
    :@runtime_installed_names => nil, :@ensure_except_remaps => nil, :@self_class_unknown => nil
  }.freeze

  # Runs a nested compile against top-level state, then restores the caller's
  # state, so neither compile sees or clobbers the other's (ADR 0202).
  def with_fresh_method_state
    saved = METHOD_COMPILE_STATE.keys.map { |ivar| instance_variable_get(ivar) }
    METHOD_COMPILE_STATE.each { |ivar, initial| instance_variable_set(ivar, initial) }
    yield
  ensure
    METHOD_COMPILE_STATE.keys.zip(saved).each { |ivar, value| instance_variable_set(ivar, value) } if saved
  end

  def embed_type(owner, ivar)
    (@ivar_layout[owner] || {})[ivar]
  end

  def embedding_classes
    owners = @ivar_layout.keys.to_set
    @superclass_of.each do |klass, superclass|
      next unless superclass.is_a?(String) && !klass.end_with?('.singleton')

      seen = Set.new
      while superclass.is_a?(String) && !seen.include?(superclass)
        break if @ivar_layout.key?(superclass) && owners.add?(klass)

        seen << superclass
        superclass = @superclass_of[superclass]
      end
    end
    owners.to_a.sort
  end

  # INSTANCE_TT_SETUP: every class in embedding_classes stores ivars in an RData
  # payload, so its instances must be MRB_TT_DATA (GETIV/SETIV and mrb_data_init
  # assume it). This generates the MRB_SET_INSTANCE_TT setup for exactly those
  # classes instead of hand-kept register.cxx calls that drifted. A class whose
  # constant is not defined yet is skipped: each compiled gem calls this at its
  # gem_init, and a later gem's call picks it up. Idempotent.
  # OWNER_METHOD_REGISTRATION: generates the method registration for every
  # compiled entry of `owners` from the same :aspec data the entry wrapper's
  # mrb_get_args uses, so the two cannot drift (hand registration missed many
  # entries, leaving interpreted fallbacks reading nil from embedded ivars).
  # Idempotent with an identical hand registration: mrb_define_method overwrites.
  # :protected is skipped (mruby has no mrb_define_protected_method, and
  # mrb_define_method would make it public). A `.singleton` owner registers via
  # mrb_define_class_method; a private one via
  # bc2cpp_define_private_class_method (below).
  # STATIC_DISPATCH_UNREGISTRATION (docs/adr/0203): entries in `unregistered` are
  # skipped: static_dispatch_registrations.rb proved no runtime lookup reaches
  # them, so the wrapper is dead, and with no dynamic lookup there is no
  # interpreted fallback to read iv_tbl.
  def emit_owner_registrations(compiled, owners, unregistered: STATIC_DISPATCH_UNREGISTERED)
    by_owner = compiled.group_by { |m| m[:owner] }
    targets = owners.select { |o| by_owner.key?(o) }

    # PRIVATE_CLASS_METHOD_SUPPORT: mruby has no mrb_define_private_class_method.
    # mrb_define_method_raw (src/class.c) only forces a singleton-class method
    # public while its visibility is still the MT_VDEFAULT sentinel, so setting
    # MRB_METHOD_PRIVATE_FL first keeps it private -- public MRB_API only, no
    # submodule patch.
    needs_private_class_method = targets.any? do |o|
      o.end_with?('.singleton') && by_owner[o].any? { |m| m[:visibility] == :private }
    end

    # Always emitted, even empty, so every gem_init can call it unconditionally.
    out = +"// OWNER_METHOD_REGISTRATION -- see bc2cpp.rb's own emit_owner_registrations comment.\n"
    if needs_private_class_method
      out << <<~CPP
        static void bc2cpp_define_private_class_method(mrb_state* M, struct RClass* c, const char* name, mrb_func_t func, mrb_aspec aspec) {
          int ai = mrb_gc_arena_save(M);
          struct RClass* sc = mrb_singleton_class_ptr(M, mrb_obj_value(c));
          mrb_method_t m;
          MRB_METHOD_FROM_FUNC(m, func);
          m.flags |= aspec;
          MRB_METHOD_SET_VISIBILITY(m, MRB_METHOD_PRIVATE_FL);
          mrb_define_method_raw(M, sc, mrb_intern_cstr(M, name), m);
          mrb_gc_arena_restore(M, ai);
        }
      CPP
    end
    out << "static void bc2cpp_register_owner_methods(mrb_state* M) {\n"
    targets.each do |owner|
      singleton = owner.end_with?('.singleton')
      var = "bc2cpp_owner_reg_#{sanitize(owner)}"
      out << "  struct RClass* #{var} = mrb_class_ptr(#{const_chain_value_expr(owner)});\n"
      by_owner[owner].each do |m|
        fn = if singleton
               m[:visibility] == :private ? 'bc2cpp_define_private_class_method' : 'mrb_define_class_method'
             elsif m[:visibility] == :private
               'mrb_define_private_method'
             elsif m[:visibility] == :public
               'mrb_define_method'
             end
        unless fn
          out << "  // #{owner}##{m[:name]} left unregistered (:#{m[:visibility]} has no safe registration call).\n"
          next
        end
        if unregistered.include?("#{owner}##{m[:name]}")
          out << "  // #{owner}##{m[:name]} left unregistered: statically dispatched only (docs/adr/0203).\n"
          next
        end
        out << "  #{fn}(M, #{var}, #{c_string_literal(m[:name])}, #{m[:entry]}, #{m[:aspec]});\n"
      end
    end
    out << "}\n\n"
    out
  end

  def emit_instance_tt_setup
    out = +"// INSTANCE_TT_SETUP -- see bc2cpp.rb's own emit_instance_tt_setup comment.\n"
    out << "static void bc2cpp_set_instance_tts(mrb_state* M) {\n"
    out << "  static const char* const paths[][6] = {\n"
    embedding_classes.each do |klass|
      next if klass.end_with?('.singleton')

      segments = klass.split('::')
      raise "INSTANCE_TT_SETUP: #{klass} nests deeper than 5 levels" if segments.size > 5

      out << "    { #{(segments.map { |seg| "\"#{seg}\"" } + ['nullptr']).join(', ')} },\n"
    end
    out << "    { nullptr },\n  };\n"
    out << <<~CPP
      for (const auto& path : paths) {
        if (!path[0]) break;
        mrb_value scope = mrb_obj_value(M->object_class);
        bool found = true;
        for (int i = 0; path[i]; ++i) {
          mrb_sym name = mrb_intern_cstr(M, path[i]);
          if (!mrb_const_defined_at(M, scope, name)) { found = false; break; }
          scope = mrb_const_get(M, scope, name);
        }
        if (found && mrb_type(scope) == MRB_TT_CLASS) MRB_SET_INSTANCE_TT(mrb_class_ptr(scope), MRB_TT_DATA);
      }
    CPP
    out << "}\n"
    out
  end

  def struct_name(owner)
    sanitize("#{owner}_ivars")
  end

  def type_var(owner)
    sanitize("#{owner}_ivars_type")
  end

  # ATTR_STRUCT_DEVIRT: the compiled getter/setter for one [owner, ivar,
  # :reader | :writer] from @synthesize_accessor_for (see
  # drop_unsafe_embeddings: once registered, every access path is
  # struct-aware). Built with the same box/check/unbox code as GETIV/SETIV.
  # Returns a `compiled`-shaped Hash so it needs no special-casing downstream.
  def emit_ivar_accessor_pair(owner, ivar, which)
    type = embed_type(owner, ivar)
    return nil unless type

    sname = struct_name(owner)
    ops = TYPE_OPS.fetch(type)
    base = "#{sanitize(owner)}_#{sanitize(ivar)}"

    case which
    when :reader
      impl = "#{base}_impl"
      entry = base
      code = <<~CPP
        // #{owner}##{ivar} -- synthesized attr_reader override (@#{ivar} is
        // embedded; this replaces the plain native accessor -- see
        // drop_unsafe_embeddings' own ATTR_STRUCT_DEVIRT comment).
        mrb_value #{impl}(mrb_state* M, mrb_value self) {
          return #{ops[:box]}(((#{sname}*)DATA_PTR(self))->#{ivar});
        }

        static mrb_value #{entry}(mrb_state* M, mrb_value self) {
          return #{impl}(M, self);
        }

      CPP
      { label: "synth:#{owner}##{ivar}", owner: owner, name: ivar, entry: entry, impl: impl,
        arity: 0, arg_c_types: [], aspec: 'MRB_ARGS_NONE()', code: code, visibility: :public }
    when :writer
      impl = "#{base}_eq_impl"
      entry = "#{base}_eq"
      code = <<~CPP
        // #{owner}##{ivar}= -- synthesized attr_writer override (@#{ivar} is
        // embedded; this replaces the plain native accessor -- see
        // drop_unsafe_embeddings' own ATTR_STRUCT_DEVIRT comment). Same
        // guarded check-then-unbox as SETIV's own embedded-ivar codegen
        // (compile_insn's own SETIV case) -- the whole-program analysis
        // proved every *compiled* write site is this type, but an
        // external caller (this accessor's own whole reason to exist) is
        // exactly the case that analysis can't see, so this checks rather
        // than blindly trusting it. Returns the assigned value, never the
        // struct field read back -- real attr_writer's own behavior
        // (3rd/mruby/src/class.c: `mrb_iv_set(...); return val;`, see
        // MethodDef's own kind: :ivar_accessor comment for the citation).
        mrb_value #{impl}(mrb_state* M, mrb_value self, mrb_value arg) {
          if (!#{ops[:check]}(arg)) mrb_raise(M, mrb_exc_get_id(M, mrb_intern_lit(M, "TypeError")), "@#{ivar}: expected #{ops[:err]}");
          ((#{sname}*)DATA_PTR(self))->#{ivar} = #{ops[:unbox]}(arg);
          return arg;
        }

        static mrb_value #{entry}(mrb_state* M, mrb_value self) {
          mrb_value arg;
          mrb_get_args(M, "o", &arg);
          return #{impl}(M, self, arg);
        }

      CPP
      { label: "synth:#{owner}##{ivar}=", owner: owner, name: "#{ivar}=", entry: entry, impl: impl,
        arity: 1, arg_c_types: ['mrb_value'], aspec: 'MRB_ARGS_REQ(1)', code: code, visibility: :public }
    end
  end

  # Every synthesized accessor, built after compile_all. A nil from
  # emit_ivar_accessor_pair should be impossible (the same pass fills both
  # tables) but is checked. `only_owners` mirrors compile_all's filter: no
  # accessor for a class this run does not emit.
  def emit_synthesized_accessors(only_owners: nil)
    pairs = @synthesize_accessor_for.to_a
    pairs = pairs.select { |owner, _, _| only_owners.include?(owner) } if only_owners
    pairs.sort.filter_map { |owner, ivar, which| emit_ivar_accessor_pair(owner, ivar, which) }
  end

  # One C struct + mrb_data_type per class with embeddable ivars. Other ivars
  # stay in iv_tbl: RData has both `data` and `iv` (mruby/data.h), the same
  # hybrid mruby-rgss/src/lib.cxx uses.
  def emit_structs
    out = String.new
    @ivar_layout.each do |owner, ivars|
      # As compile_all's only_owners filter: no struct for a class this run does not
      # emit (it would be dead code and an unused-static warning).
      next if @only_owners && !@only_owners.include?(owner)

      out << "struct #{struct_name(owner)} {\n"
      ivars.each { |name, type| out << "  #{C_TYPE.fetch(type)} #{name};\n" }
      out << "};\n"
      out << "static void #{sanitize(owner)}_ivars_free(mrb_state* mrb, void* p) { mrb_free(mrb, p); }\n"
      out << "static const mrb_data_type #{type_var(owner)} = " \
             "{ \"#{struct_name(owner)}\", #{sanitize(owner)}_ivars_free };\n\n"
    end
    out
  end

  # ARY_ENTRY_INLINE: a same-TU copy of mrb_ary_entry (src/array.c):
  #
  #   struct RArray *a = mrb_ary_ptr(ary);
  #   mrb_int len = ARY_LEN(a);
  #   if (n < 0) n += len;
  #   if (n < 0 || len <= n) return mrb_nil_value();
  #   return ARY_PTR(a)[n];
  #
  # Every emitted "mrb_ary_ref(M, ...)" becomes "bc2cpp_ary_entry(M, ...)"; the
  # real macro is `#define mrb_ary_ref(mrb, ary, n) mrb_ary_entry(ary, n)`
  # (mruby/array.h), so behavior is identical. It exists because mrb_ary_entry
  # lives in libmruby.a and the build has no LTO (docs/adr/0133, 0135), so the
  # call could never be inlined. An unboxed element representation is not an
  # option: the GC marks elements through a real RArray (src/gc.c).
  # Emitted only when some compiled code calls it (checked on the output).
  def emit_ary_entry_helper(compiled)
    # OUTLINED_INDEX_OPS' GETIDX/GETIDX0 helpers call it too.
    return '' unless compiled.any? { |m| m[:code].include?('bc2cpp_ary_entry(') } ||
                     emit_index_helpers(compiled).include?('bc2cpp_ary_entry(')

    <<~CPP
      static inline mrb_value bc2cpp_ary_entry(mrb_state*, mrb_value ary, mrb_int n) {
        struct RArray* a = mrb_ary_ptr(ary);
        mrb_int len = ARY_LEN(a);
        if (n < 0) n += len;
        if (n < 0 || len <= n) return mrb_nil_value();
        return ARY_PTR(a)[n];
      }

    CPP
  end

  # bc2cpp_bool_p (TYPE_OPS :bool check), emitted only when the output uses it.
  # There is no single macro for both boolean tags, so it ORs
  # mrb_true_p/mrb_false_p (mruby/value.h).
  def emit_bool_check_helper(compiled)
    return '' unless compiled.any? { |m| m[:code].include?('bc2cpp_bool_p(') }

    <<~CPP
      static inline mrb_bool bc2cpp_bool_p(mrb_value v) { return mrb_true_p(v) || mrb_false_p(v); }

    CPP
  end

  # GETCONST's owner-scope-first helper (see compile_insn). mrb_const_get raises
  # via longjmp, so it cannot be tried then polled; mrb_protect_error
  # (mruby/error.h) takes a C function pointer and a void* payload, hence
  # LookupCtx/lookup_body as a static function. Emitted once, only when used.
  def emit_const_lookup_helper
    return '' unless const_lookup_helper_used?

    <<~CPP
      // Shared by every GETCONST site whose owner isn't Object -- tries one
      // scope in the owner's own real lexical nesting chain and reports
      // success via *ok rather than choosing a fallback itself, so the call
      // site (compile_insn's own GETCONST case) can walk the whole chain,
      // innermost scope first, the way real Ruby constant lookup does. See
      // that comment for why this has to be mrb_protect_error-based rather
      // than a simpler try/poll (a raw mrb_const_get failure longjmps
      // straight past any code that would poll mrb->exc afterward).
      struct Bc2cppConstLookupCtx { mrb_value scope; mrb_sym name; };
      static mrb_value bc2cpp_const_lookup_body(mrb_state* M, void* ud) {
        Bc2cppConstLookupCtx* ctx = (Bc2cppConstLookupCtx*)ud;
        return mrb_const_get(M, ctx->scope, ctx->name);
      }
      static mrb_value bc2cpp_const_try(mrb_state* M, mrb_value scope, mrb_sym name, mrb_bool* ok) {
        // A miss is the common case (most scopes in the chain do not define the
        // name), and mrb_const_get reports one by raising NameError, which
        // allocates an exception, its message and a backtrace before
        // mrb_protect_error swallows it -- measured at ~70k allocations/s in the
        // RPG2k map scene. Answer the miss without raising: walk the same
        // ancestor chain const_get_nohook does (3rd/mruby/src/variable.c: the
        // scope and its superclasses/included modules, skipping a prepended
        // origin, stopping before Object) using the public defined_at test, and
        // only call mrb_const_get once the name is known to be there. It also
        // stops running a user const_missing on an intermediate scope, which
        // Ruby's lexical lookup never does.
        if (mrb_type(scope) == MRB_TT_CLASS || mrb_type(scope) == MRB_TT_MODULE || mrb_type(scope) == MRB_TT_SCLASS) {
          for (struct RClass* c = mrb_class_ptr(scope); c;) {
            if (!MRB_FLAG_TEST(c, MRB_FL_CLASS_IS_PREPENDED) && mrb_const_defined_at(M, mrb_obj_value(c), name)) {
              *ok = TRUE;
              return mrb_const_get(M, scope, name);
            }
            c = c->super;
            if (c == M->object_class) break;
          }
          *ok = FALSE;
          return mrb_nil_value();
        }
        Bc2cppConstLookupCtx ctx{scope, name};
        mrb_bool err = FALSE;
        mrb_value result = mrb_protect_error(M, bc2cpp_const_lookup_body, &ctx, &err);
        *ok = !err;
        return result;
      }

    CPP
  end

  # Declarations for the NATIVE_CONSTRUCT_TARGETS entry points actually used,
  # via include/rgss_construct.hxx (namespace `rgss`). Do not re-spell the
  # signatures here: the header is the single source of truth, and parameter
  # types must match exactly (`RClass*` klass, native arg_type parameters). The
  # three *-compiled mrbgem.rake files add repo include/ to cxx.include_paths.
  def emit_native_construct_decls
    return '' unless @native_construct_used.any?

    out = String.new
    out << "// mruby-rgss/src/lib.cxx's own devirtualized-construction entry\n"
    out << "// points (see that file's own DataType<T> comment) -- called\n"
    out << "// directly in place of Class#new's own allocate+initialize\n"
    out << "// dispatch when a `.new` call site's receiver is provably one of\n"
    out << "// these native DataType<T>-backed classes (compile_send's own\n"
    out << "// \"MONO :new -> direct native construct\" path). Declared in\n"
    out << "// include/rgss_construct.hxx, defined in namespace `rgss` at\n"
    out << "// file scope in lib.cxx -- plain C++ linkage both sides, no\n"
    out << "// `extern \"C\"` anywhere.\n"
    out << "#include \"rgss_construct.hxx\"\n"
    out << "\n"
    out
  end

  # Class-identity accessor name for a DIRECT_CONSTRUCT_TARGETS owner
  # ("Game::Transition" -> "Game__Transition_compiled_class"), derived with
  # `sanitize`; the owning gem's register.cxx defines it with this spelling.
  def direct_construct_class_fn(owner)
    "#{sanitize(owner)}_compiled_class"
  end

  # Declarations for DIRECT_CONSTRUCT_TARGETS actually used:
  # 1. bc2cpp_direct_alloc: a generic replacement for Class#new's allocate step
  #    (see its body). Defined here, since every consumer needs the same body.
  # 2. One class-identity accessor per used owner (direct_construct_class_fn),
  #    defined in the same gem's register.cxx. That file #includes this
  #    generated code, so both are in one TU and plain C++ linkage matches. A
  #    cross-gem consumer would need the OTHER_DECLS_HEADER treatment
  #    (emit_decls_header); none exists yet.
  def emit_direct_construct_decls
    return '' unless @direct_construct_used.any?

    out = String.new
    out << "// A generic replacement for Class#new's own `self.allocate` step,\n"
    out << "// correct for ANY class C regardless of its own MRB_INSTANCE_TT --\n"
    out << "// including one with an embedded MRB_TT_DATA ivar struct, since\n"
    out << "// MRB_INSTANCE_TT(c) reads the class's OWN stored instance type\n"
    out << "// (set once, at gem-init time, by MRB_SET_INSTANCE_TT), never\n"
    out << "// guesses it from the class's shape. This is exactly what\n"
    out << "// mrb_instance_alloc (3rd/mruby/src/class.c, Class#allocate's own\n"
    out << "// real implementation) does internally -- confirmed by reading that\n"
    out << "// function directly -- just reimplemented here since it is `static`\n"
    out << "// (no external linkage, so this generated file -- a different\n"
    out << "// translation unit -- cannot call it directly) using only the two\n"
    out << "// PUBLIC mruby APIs that do the same two steps: MRB_INSTANCE_TT(c)\n"
    out << "// (mruby/class.h) and mrb_obj_alloc (mruby.h). Called directly in\n"
    out << "// place of Class#new's own real allocate+initialize dispatch chain\n"
    out << "// when a `.new` call site's receiver is provably one of\n"
    out << "// DIRECT_CONSTRUCT_TARGETS' own bc2cpp-COMPILED classes\n"
    out << "// (compile_send's own \"MONO :new -> direct compiled construct\" path)\n"
    out << "// -- #initialize's own already-compiled _impl function is called\n"
    out << "// right after, for its side effects only (its own return value is\n"
    out << "// discarded, never assigned to the result register: real Ruby\n"
    out << "// Class#new always returns the newly allocated object, never\n"
    out << "// whatever #initialize itself returns).\n"
    out << "static inline mrb_value bc2cpp_direct_alloc(mrb_state* M, RClass* c) {\n"
    out << "  return mrb_obj_value(mrb_obj_alloc(M, MRB_INSTANCE_TT(c), c));\n"
    out << "}\n\n"
    out << "// Class-identity accessor functions DIRECT_CONSTRUCT_TARGETS' own\n"
    out << "// owners define in their compiled gem's own register.cxx (mirroring\n"
    out << "// NATIVE_CONSTRUCT_TARGETS' own class_fn precedent) -- a real,\n"
    out << "// durable RClass* captured once at that gem's own gem-init time, NOT\n"
    out << "// a second mrb_const_get/mrb_class_get_under lookup (see\n"
    out << "// compile_send's own comment on why: that would just observe\n"
    out << "// whatever the constant currently names, exactly what a\n"
    out << "// reassignment would already have changed, so it could never\n"
    out << "// actually detect one happened).\n"
    @direct_construct_used.sort.each do |owner|
      out << "RClass* #{direct_construct_class_fn(owner)}(void);\n"
    end
    out << "\n"
    out
  end

  # `only_owners` limits which classes are emitted, but the registry and
  # ivar_layout must come from the WHOLE closed world: analyzed alone,
  # mruby-lcf has one :rpg2003? definition, while the game has four.
  # `other_owners`: classes compiled in another TU of the same link; their
  # `_impl`s are declared via emit_decls_header and resolved at link time.
  # A ".singleton" pseudo-owner needs no special handling here: it is selected
  # exactly when an `owners:` list names it, and SDEF defs now carry an irep so
  # they are in @owner_of (see build_registry). compile_send's
  # `@only_owners.include?` guard works the same way.
  def compile_all(only_owners: nil, other_owners: nil)
    @only_owners = only_owners
    @other_owners = other_owners
    # SYM_DEVIRT: sym_call_target probes callees with compiles_clean?, whose
    # compile_method reads @only_owners/@other_owners, so both are set before any
    # compile_method runs. compile_method never assigns them.
    leaves = @owner_of.keys
    leaves = leaves.select { |l| only_owners.include?(@owner_of.fetch(l).owner) } if only_owners
    leaves.map { |label| compile_method(label) }
  end

  # Forward declarations first: a direct call can target a method defined later
  # in the file.
  def emit_forward_decls(compiled)
    out = String.new
    compiled.each do |m|
      out << "#{decl_line(m)};\n"
      # The entry wrapper stays static: only this gem's registration calls it.
      out << "static mrb_value #{m[:entry]}(mrb_state*, mrb_value);\n"
    end
    out << "\n"
    out
  end

  # The same declarations as a `#pragma once` header, for other gems' generated
  # code (OTHER_DECLS_HEADER in mrbgem.rake) so the linker resolves cross-gem
  # direct calls. `_impl`/entry are not `static` for this reason.
  def emit_decls_header(compiled)
    out = String.new
    out << "#pragma once\n"
    out << "#include <mruby.h>\n\n"
    compiled.each { |m| out << "#{decl_line(m)};\n" }
    out << "\n"
    out
  end

  # `m[:arg_c_types]`: each mandatory position's C++ type (mrb_value, or
  # mrb_int/mrb_sym for NATIVE_ARG_TARGETS). `self` is never retyped. Absent (an
  # `#error` stub) means all mrb_value.
  def decl_line(m)
    arg_c_types = m[:arg_c_types] || Array.new(m[:arity], 'mrb_value')
    impl_params = (['mrb_state*', 'mrb_value'] + arg_c_types).join(', ')
    "mrb_value #{m[:impl]}(#{impl_params})"
  end

  def compile_method(label)
    irep = @ireps.fetch(label)
    d = @owner_of.fetch(label)
    enter = irep.instructions.find { |i| i.op == 'ENTER' }
    mand = enter ? enter.args.split(':').first.to_i : 0

    # RUNTIME_DEF_DEVIRT_GUARD: cleared at the single entry point so no early
    # return can leak one method's blocked-name set into the next compile.
    @runtime_installed_names = nil

    # EXCEPTION_RETURN_SUPPORT: computed early (a pure function of `irep`) so the
    # function body can be wrapped in the try/catch a RETURN_BLK thrown from a
    # region needs; the same list is reused by the region loop below.
    # BLOCK_FALLBACK_YIELD_SUPPORT: `blk_available` is the same condition as
    # `mandatory_ok` below, so a region is never marked `needs_blk` for a method
    # whose wrapper will not extract `bc2cpp_blk`.
    block_fallback_regions = recognize_block_fallback_regions(irep, blk_available: pure_mandatory_arity?(irep))
    # NESTED_BLOCK_FALLBACK_SUPPORT: a RETURN_BLK nested at any depth throws
    # bc2cpp_method_return out to this same top-level catch (the per-call-site
    # catches only match bc2cpp_block_break), so search regions recursively.
    needs_return_catch = block_fallback_regions.any? { |region| block_fallback_region_has_return_blk?(region) }

    # OPTIONAL_ARG_SUPPORT: `opt` > 0 only for the recognized optional-only shape
    # (see optional_arg_table); other non-mandatory shapes get the `#error` stub.
    # `mandatory_ok` skips that scan in the common case.
    mandatory_ok = pure_mandatory_arity?(irep)
    # BLKPUSH_YIELD_SUPPORT: a bare `yield` (BLKCALL) needs the call's block
    # fetched by `BLKPUSH R7 2:0:0:0 (0)`. Only lv == 0 (vm.c OP_BLKPUSH: `if (lv
    # == 0) stack = regs + 1`, this frame's block) is modelled, and only for
    # mandatory_ok methods, so the opt/kw/rest wrapper branches are unaffected.
    # BLOCK_FALLBACK_YIELD_SUPPORT: the same parameter also supplies a block
    # forwarded from inside a BLOCK_FALLBACK body (`BLKPUSH R4 0:0:0:0 (1)` in
    # LCF::Array2D#each), found by block_fallback_regions and read by
    # emit_rproc_construction. Both stay gated on mandatory_ok, so this is
    # exclusive with `has_blk`.
    needs_blk_param = mandatory_ok &&
                      (irep.instructions.any? { |i| i.op == 'BLKPUSH' && i.args[/\((\d+)\)/, 1] == '0' } ||
                       block_fallback_regions.any? { |r| r[:needs_blk] })
    opt, opt_jmp_addrs, opt_jmp_targets = mandatory_ok ? [0, nil, nil] : optional_arg_table(irep)
    # KEYWORD_ARG_SUPPORT / OPTIONAL_KEYWORD_COMBINED_SUPPORT: tried whenever
    # mandatory_ok is false, whether or not the optional table resolved (the
    # KEY_P/KARG scan is whole-irep).
    kw_table = mandatory_ok ? nil : keyword_arg_table(irep)
    # Each of `opt` (jump table) and `kw` must resolve or the whole method is
    # unsupported. Either failure also clears `opt_jmp_targets`, the flag
    # `supported` trusts; otherwise a recognized optional shape with an
    # unrecognized keyword shape would compile with its keywords dropped.
    enter_kw = enter ? enter.args.split(':').map { |f| f[/\d+/].to_i }[4] : 0
    if (opt.positive? && !opt_jmp_targets) || (enter_kw.positive? && !kw_table)
      opt_jmp_targets = nil
      kw_table = nil
    end
    # REST_ARG_SUPPORT: one more contiguous `total_args` slot (see
    # rest_only_arity?).
    # REST_BLOCK_COMBINED_SUPPORT: `has_rest` and `has_blk` can both hold (`def
    # method_missing(name, *args, &block)`); both are exclusive with
    # mandatory_ok/opt_jmp_targets/kw_table, whose predicates require rest and
    # block to be zero.
    has_rest = (mandatory_ok || opt_jmp_targets || kw_table) ? false : rest_only_arity?(irep)
    has_blk = (mandatory_ok || opt_jmp_targets || kw_table) ? false : block_param_arity?(irep)
    supported = mandatory_ok || opt_jmp_targets || kw_table || has_rest || has_blk

    total_args = supported ? mand + opt + (has_rest ? 1 : 0) : mand
    arg_names = irep.lv.first(total_args).each_with_index.map { |n, i| n ? sanitize_c_ident(n) : "arg#{i + 1}" }
    # NATIVE_ARG_TARGETS per-position types (see native_arg_types). Optional
    # positions are never retyped; the padding is explicit.
    arg_native_types = native_arg_types(d, mand) + Array.new(total_args - mand)

    impl_name = "#{cpp_name(d.owner, d.name)}_impl"
    entry_name = cpp_name(d.owner, d.name)
    embedded_ivars = @ivar_layout[d.owner]

    unless supported
      # Not modelled: emit `#error` rather than a signature that disagrees with what
      # callers pass.
      code = "// #{d.owner}##{d.name} (compiled from irep #{label}, #{irep.instructions.size} insns)\n" \
             "#error #{d.owner}##{d.name} has non-mandatory arguments (optional/rest/keyword/block) -- not in this prototype's supported subset\n\n"
      return { label: label, owner: d.owner, name: d.name, entry: entry_name, impl: impl_name,
               arity: arg_names.size, code: code, unsupported: true, visibility: d.visibility }
    end

    if calls_fiber_yield?(irep) || @fiber_unsafe_methods.include?(label)
      # FIBER_YIELD_UNSAFE_SUPPORT / FIBER_REACHABILITY_UNSAFE_SUPPORT: never compile
      # a method that calls Fiber.yield or is reachable from a Fiber.new block (see
      # those methods).
      reason = calls_fiber_yield?(irep) ? 'calls Fiber.yield directly' : 'is reachable from a Fiber.new block'
      code = "// #{d.owner}##{d.name} (compiled from irep #{label}, #{irep.instructions.size} insns)\n" \
             "#error #{d.owner}##{d.name} #{reason} -- not in this prototype's supported subset\n\n"
      return { label: label, owner: d.owner, name: d.name, entry: entry_name, impl: impl_name,
               arity: arg_names.size, code: code, unsupported: true, visibility: d.visibility }
    end

    out = String.new
    out << "// #{d.owner}##{d.name} (compiled from irep #{label}, #{irep.instructions.size} insns)\n"
    # Not `static`: another gem's generated code may call it (OTHER_DECLS_HEADER;
    # see emit_decls_header).
    # Mandatory parameter types come from arg_native_types; `self` is never
    # retyped.
    arg_params = arg_names.each_with_index.map { |a, i| "#{native_c_type(arg_native_types[i])} #{a}" }
    # BLKPUSH_YIELD_SUPPORT / EXPLICIT_BLOCK_PARAM_SUPPORT: one extra parameter,
    # the call's block (Proc or nil), extracted by the wrapper with mrb_get_args
    # `&`. BLKPUSH reads it directly; `&blk` stores it into register mand+1 below.
    # Never both for one method (needs_blk_param requires ENTER's block field to
    # be zero, has_blk requires it non-zero).
    arg_params << 'mrb_value bc2cpp_blk' if needs_blk_param || has_blk
    # OPTIONAL_ARG_SUPPORT: `bc2cpp_given_opt`, how many optionals this call
    # supplied (0..opt), read by emit_optional_dispatch's switch. Unsupplied
    # slots still get a placeholder argument.
    arg_params << 'mrb_int bc2cpp_given_opt' if opt.positive?
    # KEYWORD_ARG_SUPPORT: one mrb_value per keyword, plus an mrb_int "given" flag
    # per optional keyword (mrb_get_args already raises for a missing required
    # one). Bytecode declaration order, matching the wrapper.
    kw_table&.each do |kw|
      arg_params << "mrb_value #{kwarg_param_name(kw[:name])}"
      arg_params << "mrb_int #{kw_given_param_name(kw[:name])}" unless kw[:required]
    end
    out << "mrb_value #{impl_name}(mrb_state* M, #{(['mrb_value self'] + arg_params).join(', ')}) {\n"
    # EXCEPTION_RETURN_SUPPORT: wrap the body in one try/catch only when a
    # BLOCK_FALLBACK region can throw bc2cpp_method_return. Cheap under zero-cost
    # exceptions but not free, hence the gate. Statements inside the `try` behave
    # the same; only a throw changes control flow.
    out << "  Bc2cppVmMark bc2cpp_ret_mark = bc2cpp_vm_mark(M);\n  try {\n" if needs_return_catch
    (0...irep.nregs).each { |i| out << "  mrb_value r#{i}" << (i.zero? ? ' = self;' : ' = mrb_nil_value();') << "\n" }
    # A native-typed argument's register is still an mrb_value (NATIVE_ARG_TARGETS
    # moves the coercion, it does not specialize registers), so box it with
    # TYPE_OPS[:box] on entry.
    arg_names.each_with_index do |a, i|
      t = arg_native_types[i]
      out << if t
                "  r#{i + 1} = #{TYPE_OPS.fetch(t)[:box]}(#{a});\n"
              else
                "  r#{i + 1} = #{a};\n"
              end
    end
    # EXPLICIT_BLOCK_PARAM_SUPPORT: store the block into its register once, where
    # ENTER would put it: mand+1, or mand+rest+1 with a rest parameter (ENTER
    # 1:0:1:0:0:0:1:0 puts it in R3); `total_args + 1` covers both. The following
    # MOVE etc. is ordinary bytecode.
    out << "  r#{total_args + 1} = bc2cpp_blk;\n" if has_blk
    if embedded_ivars && d.name == 'initialize'
      # At the start of #initialize self is a bare MRB_TT_DATA shell (data == NULL):
      # allocate the struct before any embedded SETIV.
      sname = struct_name(d.owner)
      out << "  {\n"
      out << "    #{sname}* embedded = (#{sname}*)mrb_calloc(M, 1, sizeof(#{sname}));\n"
      out << "    mrb_data_init(self, embedded, &#{type_var(d.owner)});\n"
      out << "  }\n"
    end
    # Goto-threaded control flow: every JMP/JMPNOT/JMPIF target gets a C label and
    # jumps become `goto`, reproducing any control flow without rebuilding a CFG.
    # All registers are declared before any label, so no goto skips an
    # initialization.
    # RESCUE_SUPPORT: each recognized region (recognize_rescue_regions) gets an
    # extracted try-body function, emitted ahead of this one. Its [begin_addr,
    # end_addr] range and the EXCEPT address are skipped here; emit_rescue_glue
    # emits the mrb_protect_error call and early-out at begin_addr and folds
    # EXCEPT's capture into its last line. Everything else continues through the
    # normal loop.
    rescue_regions = top_level_rescue_regions(recognize_rescue_regions(irep))
    rescue_pre = String.new
    suppressed = Set.new
    glue_at = {}

    # RUNTIME_DEF_DEVIRT_GUARD: set before any code is emitted, since every nested
    # fallback body and the main loop reach compile_send through this ivar. nil
    # (no SDEF and no SCLASS+EXEC) makes devirt_blocked_name? always false;
    # :unknown blocks devirtualization of every name in this method.
    # recognize_exec_fallback_regions is pure and is simply called again later.
    if irep.instructions.any? { |i| i.op == 'SDEF' } || !recognize_exec_fallback_regions(irep).empty?
      @runtime_installed_names =
        runtime_installed_names_for(irep, recognize_exec_fallback_regions(irep)) || :unknown
    end

    # OPTIONAL_ARG_SUPPORT: replace the ENTER jump table with a `switch` on
    # `bc2cpp_given_opt` (suppressed/glue_at mechanism); default-value code is
    # untouched and reached by goto, like OP_ENTER's PC skip.
    if opt.positive? && opt_jmp_targets
      opt_jmp_addrs.each { |a| suppressed << a }
      glue_at[opt_jmp_addrs.first] = emit_optional_dispatch(opt_jmp_targets)
    end

    rescue_regions.each_with_index do |region, i|
      suppressed.merge((region[:begin_addr]..region[:end_addr]).to_a)
      suppressed << region[:except_addr]
      try_name = "#{impl_name}_rescue_try#{rescue_regions.size > 1 ? "_#{i}" : ''}"
      saved = rescue_entry_saved_fields(irep, region)
      rescue_pre << emit_rescue_try_body(try_name, region, irep, d, arg_names, arg_native_types, extra_fields: saved)
      glue_at[region[:begin_addr]] = emit_rescue_glue(try_name, region, arg_names, arg_native_types,
                                                      extra_field_values: saved.map { |f| f[:name].sub('bc2cpp_saved_', '') })
    end

    # BLOCK_SUPPORT: a recognized `.times` region replaces BLOCK and SENDB with one
    # inlined loop at the BLOCK address. An unclean body (nil) leaves both to the
    # normal loop, which emits `#error`.
    # INLINE_NESTED_BLOCK_SUPPORT: file-scope code for cfuncs backing blocks nested
    # inside inlined loops (inline_nested_block_pass). It must land at file scope
    # ahead of this function, like block_fallback_pre/rescue_pre. Saved and
    # restored (not just cleared) because compile_method can be re-entered from
    # the emitter loops via compiles_clean?/compile_send, and the inner call must
    # not drop the outer one's code.
    bc2cpp_saved_inline_pre = @inline_nested_pre
    @inline_nested_pre = String.new
    # RESCUE_INLINE_BLOCK_FIX: every inlined-loop pass below must skip regions
    # whose addresses the rescue loop above already claimed. That range lives in
    # the extracted try body; here, a loop registered at its block_addr would be
    # emitted after the rescue glue, on the exception-only path, with its receiver
    # register holding whatever that path left (possibly the exception), not the
    # value the recognizer proved (scripts/bc2cpp_rescue_inline_block_check.rb).
    rescue_claimed = suppressed.dup
    in_rescue = ->(*addrs) { addrs.any? { |a| rescue_claimed.include?(a) } }
    recognize_times_regions(irep).each do |region|
      next if in_rescue.call(region[:block_addr], region[:sendb_addr])

      inlined = emit_times_inline(region, irep, d)
      next unless inlined

      suppressed << region[:block_addr] << region[:sendb_addr]
      glue_at[region[:block_addr]] = inlined
    end

    # EACH_BLOCK_SUPPORT: `ary.each` and `&:sym` regions. The Array gate is in the
    # recognizers; a failed check or unclean body leaves the opcodes to `#error`.
    each_ctx_ivar = @class_layout[d.owner]
    each_ctx_args = @class_annotations[irep.label]&.args
    recognize_each_regions(irep, d.owner, mand, each_ctx_ivar, each_ctx_args).each do |region|
      next if in_rescue.call(region[:block_addr], region[:sendb_addr])

      inlined = emit_each_inline(region, irep, d)
      next unless inlined

      suppressed << region[:block_addr] << region[:sendb_addr]
      glue_at[region[:block_addr]] = inlined
    end
    # EACH_INDEX_SUPPORT: `ary.each_index { |i| }` regions; same contract.
    recognize_each_index_regions(irep, d.owner, mand, each_ctx_ivar, each_ctx_args).each do |region|
      next if in_rescue.call(region[:block_addr], region[:sendb_addr])

      inlined = emit_each_index_inline(region, irep, d)
      next unless inlined

      suppressed << region[:block_addr] << region[:sendb_addr]
      glue_at[region[:block_addr]] = inlined
    end
    # HASH_EACH_SUPPORT: `hash.each { |k, v| }` regions; the receiver-class gates
    # make it exclusive with the Array `each` recognizer.
    recognize_hash_each_regions(irep, d.owner, mand, each_ctx_ivar, each_ctx_args).each do |region|
      next if in_rescue.call(region[:block_addr], region[:sendb_addr])

      inlined = emit_hash_each_inline(region, irep, d)
      next unless inlined

      suppressed << region[:block_addr] << region[:sendb_addr]
      glue_at[region[:block_addr]] = inlined
    end
    # EACH_KEY_SUPPORT: `hash.each_key { |k| }` regions; same contract.
    recognize_each_key_regions(irep, d.owner, mand, each_ctx_ivar, each_ctx_args).each do |region|
      next if in_rescue.call(region[:block_addr], region[:sendb_addr])

      inlined = emit_each_key_inline(region, irep, d)
      next unless inlined

      suppressed << region[:block_addr] << region[:sendb_addr]
      glue_at[region[:block_addr]] = inlined
    end
    # INTERP_UNLOCK: Range#each regions; same contract.
    recognize_range_each_regions(irep, d.owner, mand, each_ctx_ivar, each_ctx_args).each do |region|
      next if in_rescue.call(region[:block_addr], region[:sendb_addr])

      inlined = emit_range_each_inline(region, irep, d)
      next unless inlined

      suppressed << region[:block_addr] << region[:sendb_addr]
      glue_at[region[:block_addr]] = inlined
    end
    recognize_sym_regions(irep, d.owner, mand, each_ctx_ivar, each_ctx_args).each do |region|
      next if in_rescue.call(region[:sym_addr], region[:sendb_addr])

      inlined = emit_sym_inline(region, irep, d)
      next unless inlined

      suppressed << region[:sym_addr] << region[:sendb_addr]
      glue_at[region[:sym_addr]] = inlined
    end
    # MAP_BLOCK_SUPPORT: map/select/reject/find/each_with_index regions.
    recognize_collect_regions(irep, d.owner, mand, each_ctx_ivar, each_ctx_args).each do |region|
      next if in_rescue.call(region[:block_addr], region[:sendb_addr])

      inlined = emit_collect_inline(region, irep, d)
      next unless inlined

      suppressed << region[:block_addr] << region[:sendb_addr]
      glue_at[region[:block_addr]] = inlined
    end
    # ACCUM_BLOCK_SUPPORT: any?/all?/none?/count and reduce/inject(init) regions.
    recognize_accum_regions(irep, d.owner, mand, each_ctx_ivar, each_ctx_args).each do |region|
      next if in_rescue.call(region[:block_addr], region[:sendb_addr])

      inlined = emit_accum_inline(region, irep, d)
      next unless inlined

      suppressed << region[:block_addr] << region[:sendb_addr]
      glue_at[region[:block_addr]] = inlined
    end
    # SORT_BLOCK_SUPPORT: sort_by/uniq key blocks (sort comparators are rejected
    # inside the emitter).
    recognize_sort_regions(irep, d.owner, mand, each_ctx_ivar, each_ctx_args).each do |region|
      next if in_rescue.call(region[:block_addr], region[:sendb_addr])

      inlined = emit_sort_inline(region, irep, d)
      next unless inlined

      suppressed << region[:block_addr] << region[:sendb_addr]
      glue_at[region[:block_addr]] = inlined
    end

    # BLOCK_CFUNC_FALLBACK_SUPPORT: the catch-all, run last, for BLOCK/SENDB pairs
    # no named inliner claimed (checked via `suppressed`). A qualifying region
    # (see block_fallback_safe?) gets a standalone cfunc (emit_proc_fallback_fn)
    # plus glue that builds an RProc and dispatches dynamically.
    # EXPLICIT_BLOCK_ARG_SUPPORT: `&expr` has no BLOCK instruction, so only
    # sendb_addr is suppressed.
    # RESCUE_BODY_BLOCK_SUPPORT: shared with emit_rescue_try_body (see
    # emit_block_fallback_glue_pass).
    block_fallback_pre = emit_block_fallback_glue_pass(block_fallback_regions, recognize_explicit_block_arg_regions(irep),
                                                        d, suppressed, glue_at)

    # LAMBDA_FALLBACK_SUPPORT: like BLOCK_CFUNC_FALLBACK_SUPPORT, but the RProc is
    # stored into the destination register with no dispatch
    # (emit_lambda_fallback_glue). LAMBDA is disjoint from BLOCK/SENDB, so the
    # order and the `suppressed` check are defensive only. See
    # lambda_fallback_safe? for why RETURN_BLK/BREAK are allowed.
    recognize_lambda_fallback_regions(irep).each do |region|
      next if suppressed.include?(region[:block_addr])

      fn_result = emit_proc_fallback_fn(region, d)
      next unless fn_result

      fn_name, fn_code = fn_result
      block_fallback_pre << fn_code
      suppressed << region[:block_addr]
      glue_at[region[:block_addr]] = emit_lambda_fallback_glue(region, fn_name)
      # CONFINED_LAMBDA_UPVAR_SUPPORT: replace this lambda's proven `.call` sites
      # with direct calls to the emitted body; this is required, not an
      # optimization (see emit_lambda_confined_call_glue). Escaping lambdas claim
      # nothing.
      region[:call_sites].each do |site|
        next if suppressed.include?(site[:send_addr])

        suppressed << site[:send_addr]
        glue_at[site[:send_addr]] = emit_lambda_confined_call_glue(region, fn_name, site)
      end
    end

    # RUNTIME_DEF_FALLBACK_SUPPORT: SDEF and SCLASS+EXEC fallbacks, same
    # suppressed/glue_at mechanism and emit_proc_fallback_fn; nil keeps the
    # `#error`. Disjoint opcodes, so order is convention only. SDEF first: one
    # method onto one singleton class, no class body (see
    # emit_sdef_fallback_glue).
    irep.instructions.each do |insn|
      next unless insn.op == 'SDEF'
      next if suppressed.include?(insn.addr)

      region = sdef_fallback_region(insn, irep)
      next unless region

      fn_result = emit_proc_fallback_fn(region, d)
      next unless fn_result

      fn_name, fn_code = fn_result
      block_fallback_pre << fn_code
      suppressed << insn.addr
      glue_at[insn.addr] = emit_sdef_fallback_glue(region, fn_name)
    end

    # SCLASS+EXEC: `block_addr` is the SCLASS (where the replacement starts, so it
    # keeps any label; see JUMP_TARGET_GLUE_FIX) and the EXEC is suppressed with no
    # glue, like a BLOCK_FALLBACK sendb_addr.
    recognize_exec_fallback_regions(irep).each do |region|
      next if suppressed.include?(region[:block_addr]) || suppressed.include?(region[:exec_addr])

      fn_result = emit_proc_fallback_fn(region, d)
      next unless fn_result

      fn_name, fn_code = fn_result
      block_fallback_pre << fn_code
      suppressed << region[:block_addr] << region[:exec_addr]
      glue_at[region[:block_addr]] = emit_exec_fallback_glue(region, fn_name)
    end

    # JUMP_TARGET_GLUE_FIX: only drop labels for suppressed addresses WITHOUT
    # replacement code. A suppressed block_addr with glue_at code can be a real
    # jump target (`(h[:x] || {}).each { }`: the `||` JMPIF lands on the BLOCK),
    # and dropping its label left `goto L68;` with no `L68:;`, a g++ error that no
    # `#error` check catches. Only the interior of a suppressed range (e.g. a
    # rescue region minus its begin_addr) loses its label.
    targets = jump_targets(irep) - (suppressed - glue_at.keys)
    # BLKPUSH_YIELD_SUPPORT: set for this method's top-level loop only (cleared
    # after). emit_proc_fallback_fn manages its own value.
    @blk_param_name = needs_blk_param ? 'bc2cpp_blk' : nil
    # BLOCK_FALLBACK_YIELD_SUPPORT: in a METHOD body only lv == 0 can be answered
    # (vm.c `if (lv == 0) stack = regs + 1`). codegen_yield stops at the first
    # method scope, so a method's own yield is always level 0.
    @blk_param_level = 0
    # ENSURE_RAII_SUPPORT: an ensure needs code emitted AROUND instructions: the
    # guard and `{` before the protected range's first instruction, and `}`
    # before the handler (the `}` runs the ensure body via the guard's
    # destructor). glue_at REPLACES an address's code, so `prefix_at` is emitted
    # ahead of the suppression check and the label.
    prefix_at = {}
    ensure_region = recognize_ensure_region(irep)
    if ensure_region
      open_glue, ok = emit_ensure_guard(ensure_region, irep, d)
      if ok
        prefix_at[ensure_region[:begin_addr]] = open_glue
        prefix_at[ensure_region[:except_addr]] = "  } // ensure guard leaves scope: runs the ensure body\n"
        # ENSURE_DISPATCH_MERGE_SUPPORT: jumps landing exactly on the handler address
        # (see recognize_ensure_region) become `goto L<raiseif_addr>`: leave the guard
        # scope (running the ensure body) and continue past the folded handler. The
        # remap is keyed on this irep object, so a nested block's irep with the same
        # numeric address is unaffected. The label is emitted as a prefix at the
        # RAISEIF address because the suppressed handler range skips the normal label.
        # Jumping OUT of a scope with goto is legal and runs the destructor.
        unless ensure_region[:except_jump_srcs].empty?
          prefix_at[ensure_region[:raiseif_addr]] = "  L#{ensure_region[:raiseif_addr]}:;\n"
          @ensure_except_remaps = { irep => { ensure_region[:except_addr] => ensure_region[:raiseif_addr] } }
        end
        # EXCEPT, the ensure body, and the terminating RAISEIF are all
        # folded into the guard above -- none of them is emitted inline.
        suppressed.merge((ensure_region[:except_addr]..ensure_region[:raiseif_addr]).to_a)
        targets -= (ensure_region[:except_addr]..ensure_region[:raiseif_addr]).to_a
      end
    end
    irep.instructions.each_with_index do |insn, idx|
      out << prefix_at[insn.addr] if prefix_at.key?(insn.addr)
      next if suppressed.include?(insn.addr) && !glue_at.key?(insn.addr)

      out << "  L#{insn.addr}:;\n" if targets.include?(insn.addr)
      out << (glue_at[insn.addr] || compile_insn(insn, irep, d, idx))
    end
    @blk_param_name = nil
    @ensure_except_remaps = nil
    out << "  return mrb_nil_value(); // unreachable if every path RETURNs\n"
    if needs_return_catch
      out << "  } catch (bc2cpp_method_return& bc2cpp_ret) {\n"
      out << "    bc2cpp_vm_restore(M, bc2cpp_ret_mark);\n"
      out << "    return bc2cpp_ret.value;\n"
      out << "  }\n"
    end
    out << "}\n\n"
    # INLINE_NESTED_BLOCK_SUPPORT: `@inline_nested_pre` goes first so a nested
    # block's cfunc is defined before the loop that uses it.
    out = @inline_nested_pre + block_fallback_pre + rescue_pre + out
    @inline_nested_pre = bc2cpp_saved_inline_pre
    out << runtime_def_devirt_audit(out)
    @runtime_installed_names = nil

    out << "static mrb_value #{entry_name}(mrb_state* M, mrb_value self) {\n"
    if arg_names.empty? && !kw_table && !needs_blk_param && !has_blk
      out << "  return #{impl_name}(M, self);\n"
    elsif arg_names.empty? && (needs_blk_param || has_blk)
      # BLKPUSH_YIELD_SUPPORT/EXPLICIT_BLOCK_PARAM_SUPPORT with zero mandatory
      # arguments: a standalone mrb_get_args("&") call.
      out << "  mrb_value bc2cpp_blk = mrb_nil_value();\n"
      out << "  mrb_get_args(M, \"&\", &bc2cpp_blk);\n"
      out << "  return #{impl_name}(M, self, bc2cpp_blk);\n"
    elsif kw_table
      # KEYWORD_ARG_SUPPORT: mrb_get_args ":" with mrb_kwargs (mruby.h). `required`
      # counts the leading required entries in `table`; an omitted optional keyword
      # comes back mrb_undef_p and is replaced by mrb_nil_value() below. `rest:
      # NULL` makes an unknown keyword raise ArgumentError here, which KEYEND relies
      # on. Positional arguments are unpacked as in the plain case.
      # OPTIONAL_KEYWORD_COMBINED_SUPPORT: with opt > 0, optional positions get the
      # same mrb_nil_value() default and `|` marker as the plain optional branch;
      # `|` and `:` are independent mrb_get_args markers.
      arg_names.each_with_index do |a, i|
        default = i >= mand ? ' = mrb_nil_value()' : ''
        out << "  #{native_c_type(arg_native_types[i])} #{a}#{default};\n"
      end
      required_kws = kw_table.select { |kw| kw[:required] }
      optional_kws = kw_table.reject { |kw| kw[:required] }
      ordered_kws = required_kws + optional_kws
      table_entries = ordered_kws.map { |kw| "mrb_intern_cstr(M, \"#{kw[:name]}\")" }.join(', ')
      out << "  mrb_sym bc2cpp_kw_table[#{ordered_kws.size}] = { #{table_entries} };\n"
      out << "  mrb_value bc2cpp_kw_values[#{ordered_kws.size}];\n"
      out << "  mrb_kwargs bc2cpp_kwargs = { #{ordered_kws.size}, #{required_kws.size}, " \
             "bc2cpp_kw_table, bc2cpp_kw_values, NULL };\n"
      fmt = arg_native_types.each_with_index.map do |t, i|
        ch = t == :fixnum ? 'i' : (t == :symbol ? 'n' : 'o')
        i == mand && opt.positive? ? "|#{ch}" : ch
      end.join + ':'
      ptrs = (arg_names.map { |a| "&#{a}" } + ['&bc2cpp_kwargs']).join(', ')
      out << "  mrb_get_args(M, \"#{fmt}\", #{ptrs});\n"
      ordered_kws.each_with_index do |kw, i|
        var = kwarg_param_name(kw[:name])
        if kw[:required]
          out << "  mrb_value #{var} = bc2cpp_kw_values[#{i}];\n"
        else
          out << "  mrb_value #{var} = mrb_undef_p(bc2cpp_kw_values[#{i}]) ? mrb_nil_value() : bc2cpp_kw_values[#{i}];\n"
          out << "  mrb_int #{kw_given_param_name(kw[:name])} = mrb_undef_p(bc2cpp_kw_values[#{i}]) ? 0 : 1;\n"
        end
      end
      call_args = arg_names.dup
      if opt.positive?
        # mrb_get_argc counts positional arguments only, independent of keywords.
        out << "  mrb_int bc2cpp_given_opt = mrb_get_argc(M) - #{mand};\n"
        out << "  if (bc2cpp_given_opt < 0) bc2cpp_given_opt = 0;\n"
        out << "  if (bc2cpp_given_opt > #{opt}) bc2cpp_given_opt = #{opt};\n"
        call_args << 'bc2cpp_given_opt'
      end
      call_args += kw_table.flat_map do |kw|
        kw[:required] ? [kwarg_param_name(kw[:name])] : [kwarg_param_name(kw[:name]), kw_given_param_name(kw[:name])]
      end
      out << "  return #{impl_name}(M, self, #{call_args.join(', ')});\n"
    elsif has_rest
      # REST_ARG_SUPPORT: mrb_get_args `*` returns a pointer into the live VM stack,
      # so copy it into an Array (mrb_ary_new_from_values) right away, matching the
      # Array the interpreter puts in the rest register.
      mand_names = arg_names.first(mand)
      rest_name = arg_names.last
      mand_names.each_with_index { |a, i| out << "  #{native_c_type(arg_native_types[i])} #{a};\n" }
      out << "  const mrb_value* bc2cpp_rest_ptr;\n"
      out << "  mrb_int bc2cpp_rest_len;\n"
      fmt = arg_native_types.first(mand).map { |t| t == :fixnum ? 'i' : (t == :symbol ? 'n' : 'o') }.join + '*'
      ptrs = (mand_names.map { |a| "&#{a}" } + ['&bc2cpp_rest_ptr', '&bc2cpp_rest_len']).join(', ')
      # REST_BLOCK_COMBINED_SUPPORT: `*` and `&` combine in one mrb_get_args call.
      if has_blk
        out << "  mrb_value bc2cpp_blk = mrb_nil_value();\n"
        fmt += '&'
        ptrs += ', &bc2cpp_blk'
      end
      out << "  mrb_get_args(M, \"#{fmt}\", #{ptrs});\n"
      out << "  mrb_value #{rest_name} = mrb_ary_new_from_values(M, bc2cpp_rest_len, bc2cpp_rest_ptr);\n"
      call_args = mand_names + [rest_name]
      call_args << 'bc2cpp_blk' if has_blk
      out << "  return #{impl_name}(M, self, #{call_args.join(', ')});\n"
    else
      # Each local's type must match what its mrb_get_args format character writes:
      # 'o' writes an mrb_value, 'i'/'n' (NATIVE_ARG_TARGETS) an mrb_int*/mrb_sym*
      # (src/class.c mrb_get_args). One declaration per argument, since types can
      # differ.
      # OPTIONAL_ARG_SUPPORT: optional positions start as mrb_nil_value(): `|` leaves
      # an omitted out-param untouched, and reading uninitialized memory would be UB
      # even though the default-value code overwrites it.
      arg_names.each_with_index do |a, i|
        default = i >= mand ? ' = mrb_nil_value()' : ''
        out << "  #{native_c_type(arg_native_types[i])} #{a}#{default};\n"
      end
      # 'i' is mrb_as_int, 'n' is mrb_obj_to_sym: the same coercions compile_send
      # applies at a devirtualized call site; keep them in lockstep. The `|` marker
      # goes at the mandatory/optional boundary.
      fmt = arg_native_types.each_with_index.map do |t, i|
        ch = t == :fixnum ? 'i' : (t == :symbol ? 'n' : 'o')
        i == mand && opt.positive? ? "|#{ch}" : ch
      end.join
      ptrs = arg_names.map { |a| "&#{a}" }.join(', ')
      # BLKPUSH_YIELD_SUPPORT: mrb_get_args `&` is this call's block (src/class.c
      # `case '&':`), nil when none (plain `&`, not `&!`), appended to the same call.
      # Neither needs_blk_param nor has_blk methods have optionals.
      if needs_blk_param || has_blk
        out << "  mrb_value bc2cpp_blk = mrb_nil_value();\n"
        fmt += '&'
        ptrs += ', &bc2cpp_blk'
      end
      out << "  mrb_get_args(M, \"#{fmt}\", #{ptrs});\n"
      if opt.positive?
        # OPTIONAL_ARG_SUPPORT: mrb_get_argc(M) - mand is the quantity OP_ENTER uses to
        # pick the jump-table entry. The clamp to [0, opt] is a formality
        # (mrb_get_args already raised for out-of-range counts).
        out << "  mrb_int bc2cpp_given_opt = mrb_get_argc(M) - #{mand};\n"
        out << "  if (bc2cpp_given_opt < 0) bc2cpp_given_opt = 0;\n"
        out << "  if (bc2cpp_given_opt > #{opt}) bc2cpp_given_opt = #{opt};\n"
        out << "  return #{impl_name}(M, self, #{arg_names.join(', ')}, bc2cpp_given_opt);\n"
      else
        call_args = (needs_blk_param || has_blk) ? arg_names + ['bc2cpp_blk'] : arg_names
        out << "  return #{impl_name}(M, self, #{call_args.join(', ')});\n"
      end
    end
    out << "}\n\n"
    # arg_c_types: the emitted per-position parameter types, read by decl_line so
    # every forward declaration (same gem or OTHER_DECLS_HEADER) matches.
    arg_c_types = arg_names.each_index.map { |i| native_c_type(arg_native_types[i]) }
    # BLKPUSH_YIELD_SUPPORT/EXPLICIT_BLOCK_PARAM_SUPPORT: must appear in the
    # declaration too. No devirtualized direct call passes it today (callers are
    # block-carrying sends, never devirtualized), but a mismatch must be a
    # compile error, not a wrong signature.
    arg_c_types << 'mrb_value' if needs_blk_param || has_blk
    # OPTIONAL_ARG_SUPPORT: `bc2cpp_given_opt` is part of the signature, so the
    # declaration needs it too.
    arg_c_types << 'mrb_int' if opt.positive?
    # KEYWORD_ARG_SUPPORT: the keyword parameters, in the same order as
    # arg_params, for the declaration.
    kw_table&.each do |kw|
      arg_c_types << 'mrb_value'
      arg_c_types << 'mrb_int' unless kw[:required]
    end
    # REGISTRATION_ASPEC: the mrb_aspec a registration of this entry needs, built
    # from the very variables the wrapper above was generated from (mand/opt/rest/
    # keywords/block), so it cannot drift from the arguments the wrapper actually
    # binds. The count of keywords is all an aspec can carry (mruby has no
    # required-keyword field); the wrapper itself enforces which are required.
    aspec = mand.zero? && opt.to_i.zero? && !has_rest && !kw_table && !needs_blk_param && !has_blk ? ['MRB_ARGS_NONE()'] : ["MRB_ARGS_REQ(#{mand})"]
    aspec << "MRB_ARGS_OPT(#{opt})" if opt.to_i.positive?
    aspec << 'MRB_ARGS_REST()' if has_rest
    aspec << "MRB_ARGS_KEY(#{kw_table.size}, 0)" if kw_table
    aspec << 'MRB_ARGS_BLOCK()' if needs_blk_param || has_blk
    { label: label, owner: d.owner, name: d.name, entry: entry_name, impl: impl_name,
      arity: arg_names.size, arg_c_types: arg_c_types, aspec: aspec.join(' | '),
      code: out, visibility: d.visibility }
  end

  # OPTIONAL_ARG_SUPPORT: the switch replacing ENTER's jump table (see
  # optional_arg_table); `targets` are the table's target addresses in order.
  def emit_optional_dispatch(targets)
    out = String.new
    out << "  switch (bc2cpp_given_opt) {\n"
    targets.each_with_index do |addr, i|
      out << (i == targets.size - 1 ? "    default: goto L#{addr};\n" : "    case #{i}: goto L#{addr};\n")
    end
    out << "  }\n"
    out
  end

  # Every address a JMP/JMPNOT/JMPIF/JMPUW can land on needs a C label. JMPUW
  # has JMP's operand shape (ops.h `OPCODE(JMPUW, S)`). Listing it even when
  # jmpuw_is_plain_jump? rejects it only adds a harmless label to a method that
  # will not ship.
  def jump_targets(irep)
    targets = Set.new
    irep.instructions.each do |insn|
      case insn.op
      when 'JMP', 'JMPUW'
        targets << insn.args.strip[/\d+/].to_i
      when 'JMPNOT', 'JMPIF', 'JMPNIL'
        targets << jmp_target_after_reg(insn.args)
      end
    end
    targets
  end

  # JMPUW_SUPPORT: is every OP_JMPUW in this irep a plain OP_JMP?
  # mrbc emits JMPUW for loop `break`/`next` (LOOP_NORMAL), `redo` and `retry`
  # (codegen.c), with or without an ensure. vm.c's OP_JMPUW:
  #
  #     a = (uint32_t)((ci->pc - irep->iseq) + (int16_t)a);
  #     CHECKPOINT_RESTORE(RBREAK_TAG_JUMP) { ...resume after ensure... }
  #     CHECKPOINT_MAIN(RBREAK_TAG_JUMP) {
  #       if (irep->clen > 0 &&
  #           (ch = catch_handler_find(irep, ci->pc, MRB_CATCH_FILTER_ENSURE))) {
  #         if (a < ...ch->begin || a > ...ch->end) {
  #           THROW_TAGGED_BREAK(mrb, RBREAK_TAG_JUMP, mrb->c->ci, mrb_fixnum_value(a));
  #         }
  #       }
  #     }
  #     CHECKPOINT_END(RBREAK_TAG_JUMP);
  #     mrb->exc = NULL;
  #     ci->pc = irep->iseq + a;
  #     JUMP;
  #
  # With `irep->clen == 0` it can never throw (and CHECKPOINT_RESTORE is only
  # re-entered by its own throw), so it is exactly OP_JMP.
  # The whole-irep clen == 0 test is used rather than the per-pc range check
  # because: it is vm.c's own first condition (no half-open range subtleties);
  # a real unsound case exists (a `break` inside `begin ... ensure` jumping out
  # of the ensure range must run the ensure body, which a bare goto would skip);
  # and it keeps JMPUW away from RESCUE_SUPPORT's extracted regions (a rescue
  # region implies clen > 0).
  def jmpuw_is_plain_jump?(irep)
    irep.catch_handlers.nil? || irep.catch_handlers.empty?
  end

  # ENSURE_RAII_SUPPORT: the branch target of one instruction, or nil. Same arg
  # shapes as const_entry_addrs.
  def ensure_jump_target(insn)
    case insn.op
    when 'JMP', 'JMPUW'
      insn.args.strip[/\d+/].to_i
    when 'JMPIF', 'JMPNOT', 'JMPNIL'
      insn.args.sub(/;.*\z/m, '').strip.split(/\s+/).last&.to_i
    end
  end

  # ENSURE_DISPATCH_MERGE_SUPPORT: compile_method's per-irep remap of jumps onto
  # an ensure handler address. nil outside compile_method (hence `&.`); keyed on
  # the irep object so a nested irep's same numeric address is unaffected.
  # JMPUW never consults it (it only compiles with no catch handlers).
  def ensure_remapped_jump_target(irep, target)
    return target unless target && @ensure_except_remaps

    map = @ensure_except_remaps[irep]
    map ? map.fetch(target, target) : target
  end

  # ENSURE_RAII_SUPPORT: recognize one `begin BODY ensure ENSURE_BODY end` and
  # return {begin_addr:, except_addr:, raiseif_addr:, body_insns:,
  # except_jump_srcs:}, or nil (keeps `#error unhandled opcode EXCEPT`).
  # `except_jump_srcs` are jumps from inside the protected range onto the
  # handler address (ENSURE_DISPATCH_MERGE_SUPPORT below).
  # Shape (checked against mrbc -v):
  #
  #   catch type: ensure   begin: B   end: E   target: E
  #     [B, E)   the protected computation
  #     E        EXCEPT Rx      -- captures whatever is unwinding (a real
  #                               exception OR an MRB_TT_BREAK break
  #                               object) into Rx
  #     (E, R)   the ensure body itself
  #     R        RAISEIF Rx     -- re-raises/resumes unless Rx is nil
  #     R+       the method continues (or RETURNs)
  #
  # Under RAII, EXCEPT and RAISEIF disappear: C++ unwinding carries the
  # in-flight exception, and the guard's destructor runs the ensure body on
  # every exit. A mruby unwind is carried in M->exc (saved and restored by
  # bc2cpp_ensure_guard); this file's own C++ break/return exceptions run the
  # destructor and continue to their catch sites.
  # Everything below rejects unproven shapes.
  def recognize_ensure_region(irep)
    return nil if irep.catch_handlers.nil?
    # Exactly one handler, the ensure; nesting or a rescue in the same irep is not
    # modelled.
    return nil unless irep.catch_handlers.size == 1
    ch = irep.catch_handlers.first
    return nil unless ch.type == :ensure
    # `end == target` is the only shape reasoned about.
    return nil unless ch.end_addr == ch.target

    by_addr = irep.instructions.each_with_object({}) { |insn, h| h[insn.addr] = insn }
    b, t = ch.begin_addr, ch.target
    return nil unless by_addr.key?(b)

    exc = by_addr[t]
    return nil unless exc && exc.op == 'EXCEPT'
    exc_reg = exc.args.strip[/R(\d+)/, 1]
    return nil unless exc_reg

    # Find this handler's own terminating `RAISEIF Rx` (same register).
    after = irep.instructions.select { |i| i.addr > t }
    raiseif = after.find { |i| i.op == 'RAISEIF' && i.args.strip[/R(\d+)/, 1] == exc_reg }
    return nil unless raiseif

    body = after.select { |i| i.addr < raiseif.addr }
    # The ensure body must only fall off its end: a RETURN would have to return
    # from the method, not the destructor's lambda, and BREAK/BLOCK/SENDB/LAMBDA
    # could throw a C++ exception out of a destructor that may already be running
    # during unwinding (std::terminate).
    return nil if body.any? do |i|
      %w[RETURN RETURN_BLK BREAK BLOCK SENDB SSENDB LAMBDA EXCEPT RAISEIF].include?(i.op)
    end
    # Branches inside the ensure body must stay inside it; its RAISEIF address is
    # allowed (mrbc's "skip the rest" target for a conditional ensure body) and
    # becomes a label at the end of the lambda.
    return nil if body.any? do |i|
      jt = ensure_jump_target(i)
      jt && !(jt > t && jt <= raiseif.addr)
    end
    # No branch may cross into or out of the protected range: the guard is a C++
    # scope, and jumping in would skip its initialization (ill-formed), jumping
    # out would run the ensure where the bytecode does not.
    # ENSURE_DISPATCH_MERGE_SUPPORT: except a jump from INSIDE the range to `t`
    # (== ch.end_addr), mrbc's tail-merge of a trailing conditional onto the
    # ensure region, e.g. optcarrot NES#run:
    #
    #   catch type: ensure   begin: 0004 end: 0122 target: 0122
    #     ...
    #     93 117 JMP              122    <- the merged branch exit
    #     93 120 LOADNIL   R3      (nil) <- the branch's other (fall-in) arm
    #     93 122 EXCEPT    R5
    #     96 124 SSEND0    R6      :dispose
    #     96 127 RAISEIF   R5
    #     96 129 RETURN    R3
    #
    # On the VM that runs EXCEPT (nil on the normal path), the ensure body, and
    # continues after RAISEIF; the RAII equivalent is leaving the guard scope and
    # landing just after it, so these jumps are remapped to raiseif_addr by
    # compile_method (which also emits that label). A jump from OUTSIDE onto `t`
    # stays rejected: it would skip the body but run the ensure.
    inside = ->(a) { a >= b && a < ch.end_addr }
    except_jump_srcs = []
    irep.instructions.each do |i|
      jt = ensure_jump_target(i)
      next unless jt
      # The ensure body was already checked above with a stricter rule.
      next if i.addr > t && i.addr < raiseif.addr
      if jt == t
        return nil unless inside.call(i.addr)

        except_jump_srcs << i.addr
        next
      end
      return nil if inside.call(i.addr) != inside.call(jt)
    end
    # An optional-argument jump table is ordinary JMPs in this irep, so the
    # crossing test already covered it.
    { begin_addr: b, except_addr: t, raiseif_addr: raiseif.addr, body_insns: body,
      except_jump_srcs: except_jump_srcs }
  end

  # ENSURE_RAII_SUPPORT: the opening half of an ensure region: `{`, the ensure
  # body compiled into a by-reference lambda, and the guard whose destructor
  # runs it. Returns [text, ok]; ok false (a body instruction failed) makes
  # compile_method emit nothing, keeping `#error`.
  # The lambda captures `[&]`, so it uses the function's own `rN` locals. Those
  # are declared at the top, before the guard, so reverse destruction order
  # keeps them alive when the guard runs.
  def emit_ensure_guard(region, irep, d)
    body = String.new
    ok = true
    # The ensure body's branches target the body or the RAISEIF; both become
    # labels inside the lambda, so compile_insn's gotos need no rewriting.
    body_targets = region[:body_insns].filter_map { |i| ensure_jump_target(i) }.to_set
    region[:body_insns].each do |insn|
      idx = irep.instructions.index(insn)
      body << "    L#{insn.addr}:;\n" if body_targets.include?(insn.addr)
      code = compile_insn(insn, irep, d, idx)
      ok = false if code.include?('#error')
      body << code
    end
    # mrbc's "skip the rest of the ensure body" target (RAISEIF) means "the
    # lambda is done".
    body << "    L#{region[:raiseif_addr]}:;\n" if body_targets.include?(region[:raiseif_addr])
    text = String.new
    text << "  { // ensure region [#{region[:begin_addr]}, #{region[:except_addr]})\n"
    text << "  auto bc2cpp_ensure_fn = [&]() {\n"
    text << body
    text << "  };\n"
    text << "  bc2cpp_ensure_guard<decltype(bc2cpp_ensure_fn)> " \
            "bc2cpp_ensure_g{M, bc2cpp_ensure_fn};\n"
    text << "  (void)bc2cpp_ensure_g;\n"
    [text, ok]
  end

  # RESCUE_SUPPORT: recognize `begin BODY rescue C => e; HANDLER; end` (also a
  # whole-method `rescue` and the `EXPR rescue FALLBACK` modifier: same
  # EXCEPT/RESCUE/RAISEIF shape). Chained single-class clauses and namespaced
  # classes are supported (recognize_rescue_class_handler), and proper nesting
  # (NESTED_RESCUE_SUPPORT). Not supported: `retry`, `ensure`, a multi-class
  # clause `rescue A, B`, partial overlap. Unrecognized shapes keep
  # `#error unhandled opcode EXCEPT`: RESCUE/RAISEIF translate anywhere, but
  # EXCEPT only means something inside this mrb_protect_error wrapping.
  #
  # Shape behind a "catch type: rescue" entry (checked against mrbc -v):
  #
  #   [begin, end)   -- the protected computation itself (BODY above).
  #   end            -- exactly one instruction, `JMP S` -- BODY's own
  #                     normal (non-raising) exit, landing on address S,
  #                     which every rescue-match path also converges on
  #                     (a final RETURN/RETURN_BLK for a whole-method
  #                     rescue, otherwise just the next instruction).
  #   target         -- exactly `EXCEPT Rexc` (captures the raised
  #                     exception -- mrb->exc -- into Rexc, clearing it).
  #   target+1..    -- one or more chained rescue CLAUSE TESTS: a class
  #                     chain (`GETCONST Rcls <Root>`, then zero or more
  #                     `GETMCNST Rcls (Rcls)::<Seg>`), `RESCUE Rexc Rcls`,
  #                     `JMPIF Rcls match`, `JMP next` (the next clause's
  #                     test head, or `raise` for the last clause); see
  #                     recognize_rescue_class_handler.
  #   raise          -- exactly `RAISEIF Rexc` (re-raises unless nil).
  #
  # Rexc is also the register holding the construct's RESULT on every path:
  # codegen_rescue compiles BODY at cursp(), takes `exc = cursp()` for
  # OP_EXCEPT, and compiles each handler at the same cursp(). So the value
  # flowing into S is always r<exc_reg>, whatever instruction S is.
  # emit_rescue_glue's early return for a RETURN/RETURN_BLK S is only a
  # shortcut; the goto-to-S path is correct for both.
  # Every address in the chain is cross-checked.
  #
  # DEFINED_CONST_RESCUE_SUPPORT: a second shape, the compiler-generated
  # `defined?` constant probe (a bare EXCEPT, no RESCUE); see
  # recognize_defined_const_handler.
  #
  # Returns one Hash per non-nested handler:
  # {begin_addr:, end_addr:, except_addr:, exc_reg:, cls_name:, match_addr:,
  #  raise_addr:, shared_target:, connector_reg:, tail_return:, kind:}.
  # `kind` is :rescue_class or :defined_const; the emitters read neither
  # it nor cls_name/match_addr/raise_addr (nil for :defined_const).
  def recognize_rescue_regions(irep)
    return [] if irep.catch_handlers.nil? || irep.catch_handlers.empty?
    return [] unless irep.catch_handlers.all? { |ch| ch.type == :rescue }

    by_addr = irep.instructions.each_with_object({}) { |insn, h| h[insn.addr] = insn }
    by_index = irep.instructions.each_with_index.to_h

    regions = []
    irep.catch_handlers.each do |ch|
      b, e, t = ch.begin_addr, ch.end_addr, ch.target
      # NESTED_RESCUE_SUPPORT: proper nesting (one range inside another, e.g. a
      # `(x rescue nil)` modifier inside a method-level rescue) is allowed. Only a
      # partial overlap, which mrbc never produces, is rejected: it would mean the
      # shape assumptions are wrong. compile_method and emit_rescue_try_body each
      # claim only top-level regions of their scope (top_level_rescue_regions);
      # nested ones become further-nested try-body functions.
      next if irep.catch_handlers.any? do |o|
        next false if o == ch

        overlaps = o.begin_addr <= e && b <= o.end_addr
        nested = (o.begin_addr <= b && e <= o.end_addr) || (b <= o.begin_addr && o.end_addr <= e)
        overlaps && !nested
      end

      except_i = by_addr[t]
      next unless except_i && except_i.op == 'EXCEPT'
      exc_reg = except_i.args[/^R(\d+)/, 1]
      next unless exc_reg

      # Two exclusive handler shapes, each with its own recognizer (nil means "not
      # this shape"): the classic `rescue SomeClass` chain, and the `defined?`
      # constant probe (see recognize_defined_const_handler).
      handler = recognize_rescue_class_handler(irep, by_addr, by_index, except_i, exc_reg) ||
                recognize_defined_const_handler(irep, by_index, except_i, exc_reg, b, e)
      next unless handler

      cls_name = handler[:cls_name]
      match_addr = handler[:match_addr]
      raise_addr = handler[:raise_addr]

      exit_i = by_addr[e]
      next unless exit_i && exit_i.op == 'JMP'
      shared_target = exit_i.args.strip[/\d+/].to_i
      # shared_target can never be this region's except_addr in mrbc output
      # (OP_EXCEPT is emitted before the success JMP is patched); rejected anyway,
      # since that address is suppressed and has no label.
      next if shared_target == t
      shared_i = by_addr[shared_target]
      next unless shared_i
      # DEFINED_CONST_RESCUE_SUPPORT: the success path must land on `STRING
      # R<exc_reg> L[n]` (codegen_defined_const's "constant" push,
      # patches/mruby-defined-keyword.patch), which overwrites r<exc_reg>. That makes
      # the try body's result dead on success; anything else is unverified.
      if handler[:kind] == :defined_const
        next unless shared_i.op == 'STRING' && shared_i.args[/^R(\d+)/, 1] == exc_reg
        next unless handler[:join_addr] > shared_target
      end
      # connector_reg is always exc_reg (see the header). tail_return stays a
      # checked distinction: emit_rescue_glue takes the early return only then, and
      # verifies connector_reg against the RETURN operand.
      tail_return = %w[RETURN RETURN_BLK].include?(shared_i.op)
      connector_reg = exc_reg
      if tail_return
        tail_reg = shared_i.args.strip.empty? ? '0' : shared_i.args[/^R(\d+)/, 1]
        next unless tail_reg == connector_reg
      end

      # Containment, checked by jump SOURCE address:
      #   1. No jump from outside [b, e] may target inside it, except a jump from
      #      strictly before `b` landing exactly on `b` (an `if ...; return; end`
      #      guard or an optional-argument default dispatch entering the region).
      #      A `retry` would jump back from the handler, after `e`, so it is still
      #      rejected.
      #   2. No jump from inside [b, e) may leave it; the only exits are `e`
      #      (checked above) or a raise (mrb_protect_error's job).
      jump_target_of = lambda do |insn|
        case insn.op
        when 'JMP' then insn.args.strip[/\d+/].to_i
        when 'JMPNOT', 'JMPIF', 'JMPNIL' then jmp_target_after_reg(insn.args)
        end
      end
      escapes = irep.instructions.any? do |src|
        tgt = jump_target_of.call(src)
        next false unless tgt
        if src.addr >= b && src.addr < e
          !(tgt >= b && tgt <= e) # (2): an internal source jumping outside the region
        elsif src.addr < b && tgt == b
          false # legitimate explicit-branch entry into the region, see above
        else
          tgt >= b && tgt <= e # (1): an external source jumping into the region
        end
      end
      next if escapes

      regions << { begin_addr: b, end_addr: e, except_addr: t, exc_reg: exc_reg, cls_name: cls_name,
                   match_addr: match_addr, raise_addr: raise_addr, shared_target: shared_target,
                   connector_reg: connector_reg, tail_return: tail_return, kind: handler[:kind] }
    end
    regions
  end

  # RESCUE_SUPPORT: the classic `rescue SomeClass` handler shape. Returns nil
  # unless it matches completely.
  #
  # NAMESPACED_RESCUE_SUPPORT / MULTI_RESCUE_SUPPORT: a clause-chain walk.
  # (a) A namespaced class (`rescue RGSS::Timeout`, RPG2k#start):
  #
  #       catch type: rescue   begin: 0004 end: 0011 target: 0014
  #        004 BLOCK     R3  I[0]
  #        007 SSENDB    R2  :loop  n=0
  #        011 JMP       039           <- e, the non-raising exit
  #        014 EXCEPT    R2            <- t
  #        016 GETCONST  R3  RGSS      <- class chain ROOT
  #        019 GETMCNST  R3  (R3)::Timeout   <- ...and its one segment
  #        022 RESCUE    R2  R3
  #        025 JMPIF     R3  032       <- match
  #        029 JMP       037           <- no match: straight to RAISEIF
  #        032 LOADNIL   R2  (nil)     <- the (empty) handler body
  #        034 JMP       039
  #        037 RAISEIF   R2
  #        039 RETURN    R2            <- shared_target
  #
  # (b) Chained clauses (RGSS::Graphics.singleton#_transition_map):
  #
  #       catch type: rescue   begin: 0004 end: 0038 target: 0041
  #        038 JMP       166           <- e; shared_target 166
  #        041 EXCEPT    R4            <- t
  #        043 GETCONST  R5  Bitmap              -- clause 1 test
  #        046 GETMCNST  R5  (R5)::LoadError
  #        049 RESCUE    R4  R5
  #        052 JMPIF     R5  059       <- match -> body 1
  #        056 JMP       105           <- NO match -> clause 2's GETCONST
  #        059 ... body 1 ...
  #        102 JMP       166           <- body 1 converges on shared_target
  #        105 GETCONST  R5  StandardError      -- clause 2 test
  #        108 RESCUE    R4  R5
  #        111 JMPIF     R5  118       <- match -> body 2
  #        115 JMP       164           <- NO match -> RAISEIF (last clause)
  #        118 ... body 2 ...
  #        161 JMP       166
  #        164 RAISEIF   R4
  #        166 RETURN    R4            <- shared_target
  #
  # Each clause's no-match JMP must land on the next clause's GETCONST or on
  # `RAISEIF Rexc` (first-match-wins). vm.c OP_RESCUE is only `regs[b] =
  # mrb_bool_value(mrb_obj_is_kind_of(mrb, exc, ec))` and OP_RAISEIF re-raises
  # regs[a] unless nil.
  # Soundness of chaining: the no-match path never enters a handler body (bodies
  # clobber r<exc_reg> but are only reached via a matched JMPIF and exit to
  # shared_target), and GETCONST/GETMCNST/RESCUE/JMPIF/JMP never write
  # r<exc_reg> (`cls_reg != exc_reg` is checked), so the exception is intact at
  # every later RESCUE.
  # Nothing downstream changes: cls_name/match_addr/raise_addr are not read by
  # any emitter; compile_method suppresses [begin_addr, end_addr] and
  # except_addr only and compiles everything after through compile_insn, which
  # translates each of these opcodes unconditionally. The protected range and
  # its checks are untouched.
  def recognize_rescue_class_handler(irep, by_addr, by_index, except_i, exc_reg)
    clause_idx = by_index[except_i]
    return nil unless clause_idx

    clause_idx += 1
    cls_names = []
    first_match_addr = nil

    loop do
      # The class name: a GETCONST root then GETMCNST segments, all reading and
      # writing the root's register; anything else is rejected.
      getconst_i = irep.instructions[clause_idx]
      return nil unless getconst_i && getconst_i.op == 'GETCONST'
      cls_reg = getconst_i.args[/^R(\d+)/, 1]
      cls_name = getconst_i.args[/^R\d+\s+(\S+)/, 1]
      return nil unless cls_reg && cls_name
      # The class chain must not target the exception register (RESCUE/RAISEIF
      # still need it); codegen_rescue puts it at cursp() above exc, checked here.
      return nil if cls_reg == exc_reg

      seg_idx = clause_idx + 1
      while (seg_i = irep.instructions[seg_idx]) && seg_i.op == 'GETMCNST'
        seg_m = seg_i.args.strip.match(/^R#{cls_reg}\s+\(R#{cls_reg}\)::(\S+?)\s*(?:;.*)?$/)
        return nil unless seg_m
        cls_name = "#{cls_name}::#{seg_m[1]}"
        seg_idx += 1
      end

      rescue_i, jmpif_i, jmp_i = irep.instructions[seg_idx, 3]
      return nil unless rescue_i && jmpif_i && jmp_i
      return nil unless rescue_i.op == 'RESCUE' && rescue_i.args.strip =~ /^R#{exc_reg}\s+R#{cls_reg}$/
      return nil unless jmpif_i.op == 'JMPIF' && jmpif_i.args[/^R(\d+)/, 1] == cls_reg

      match_addr = jmp_target_after_reg(jmpif_i.args)
      return nil unless match_addr && match_addr > jmpif_i.addr
      return nil unless jmp_i.op == 'JMP'
      next_addr = jmp_i.args.strip[/\d+/].to_i
      # Strictly forward: bounds the walk and excludes a backward `retry`.
      return nil unless next_addr > jmp_i.addr

      cls_names << cls_name
      first_match_addr ||= match_addr

      next_i = by_addr[next_addr]
      return nil unless next_i

      # Last clause: the no-match path re-raises.
      if next_i.op == 'RAISEIF'
        return nil unless next_i.args[/^R(\d+)/, 1] == exc_reg

        return { kind: :rescue_class, cls_name: cls_names.join(', '),
                 match_addr: first_match_addr, raise_addr: next_addr }
      end

      # Otherwise it must be the next clause's class-test head, never a handler
      # body (the soundness property above).
      return nil unless next_i.op == 'GETCONST'

      clause_idx = by_index[next_i]
      return nil unless clause_idx
    end
  end

  # DEFINED_CONST_RESCUE_SUPPORT: the other shape behind a "catch type: rescue"
  # entry: this repo's `defined?(CONST)` / `defined?(A::B)` / `defined?(::B)`
  # (patches/mruby-defined-keyword.patch; upstream codegen_defined returns nil).
  # It has no RESCUE and no RAISEIF, e.g. RPG2k::Scene::Map#try_open_debug_menu:
  #
  #   catch type: rescue   begin: 0051 end: 0057 target: 0060
  #    051 GETCONST  R2  Scene            <- b, the probe itself
  #    054 GETMCNST  R2  (R2)::DebugMenu
  #    057 JMP       067                  <- e, the non-raising exit
  #    060 EXCEPT    R2                   <- t, a BARE EXCEPT
  #    062 LOADNIL   R2  (nil)
  #    064 JMP       070                  <- join, past the STRING
  #    067 STRING    R2  L[0]  ; constant <- shared_target
  #    070 JMPIF     R2  075
  #
  # Sound with the existing mrb_protect_error machinery and no new emitter:
  #  1. emit_rescue_glue's non-tail_return output is exactly right: on success
  #     its assignment is overwritten by the STRING; on failure the exception
  #     lands in r<exc_reg> and falls through to the LOADNIL, as EXCEPT would.
  #  2. The handler is two ordinary instructions (LOADNIL, JMP), compiled
  #     normally.
  #  3. The protected range must have no live-in registers:
  #     emit_rescue_try_body nil-initializes everything but self and mandatory
  #     arguments, which is only valid at a region entered right after ENTER,
  #     and a `defined?` probe can sit anywhere. `defined?(x.bar::Baz)` reads a
  #     live local inside the range, so only these chains are accepted (all on
  #     r<exc_reg>, codegen_defined_const's `r = cursp()`):
  #     GETCONST Rd <Name>                                (`defined?(C)`)
  #     GETCONST Rd <Base>  (GETMCNST Rd (Rd)::<Name>)+   (`defined?(A::B)`)
  #     OCLASS   Rd         (GETMCNST Rd (Rd)::<Name>)+   (`defined?(::B)`)
  #     Each writes r<exc_reg> before reading it and calls no Ruby method, so
  #     the only live-in is `self` (for GETCONST's lexical lookup).
  # codegen_defined_const is the only catch_handler_new the patch adds, so no
  # other compiler-generated rescue region exists.
  # Returns {kind:, cls_name:, match_addr:, raise_addr:, join_addr:}; the three
  # classic fields are nil and unused by the emitters.
  def recognize_defined_const_handler(irep, by_index, except_i, exc_reg, b, e)
    idx = by_index[except_i]
    seq = irep.instructions[idx + 1, 2]
    return nil unless seq && seq.size == 2

    loadnil_i, jmp_i = seq
    return nil unless loadnil_i.op == 'LOADNIL' && loadnil_i.args[/^R(\d+)/, 1] == exc_reg
    return nil unless jmp_i.op == 'JMP'

    join_addr = jmp_i.args.strip[/\d+/].to_i
    # The handler only runs forward into the join.
    return nil unless join_addr > jmp_i.addr

    body = irep.instructions.select { |i| i.addr >= b && i.addr < e }
    head, *rest = body
    return nil unless head
    case head.op
    when 'GETCONST'
      return nil unless head.args[/^R(\d+)/, 1] == exc_reg && head.args[/^R\d+\s+(\S+)/, 1]
    when 'OCLASS'
      # `::Name` always has a GETMCNST after OCLASS; a lone OCLASS cannot raise and
      # is never emitted by codegen_defined_const.
      return nil unless head.args[/^R(\d+)/, 1] == exc_reg && !rest.empty?
    else
      return nil
    end
    rest.each do |i|
      return nil unless i.op == 'GETMCNST'
      return nil unless i.args.strip =~ /^R#{exc_reg}\s+\(R#{exc_reg}\)::\w+\s*(;.*)?$/
    end

    { kind: :defined_const, cls_name: nil, match_addr: nil, raise_addr: nil, join_addr: join_addr }
  end

  # NESTED_RESCUE_SUPPORT: the regions not contained in another region of the
  # same list: what the current scope (compile_method, or emit_rescue_try_body
  # for its own range) claims directly; nested ones are left to the child's
  # recursive extraction.
  def top_level_rescue_regions(regions)
    regions.reject do |r|
      regions.any? { |o| o != r && o[:begin_addr] <= r[:begin_addr] && r[:end_addr] <= o[:end_addr] }
    end
  end

  # RESCUE_SUPPORT: the extracted try body for one region, a top-level static
  # function (mrb_protect_error takes a C function pointer; see
  # emit_const_lookup_helper). It covers [begin_addr, end_addr] including the
  # exit JMP, which becomes a C++ `return` of the value the JMP would pass on
  # (the function's result is mrb_protect_error's result on success). A
  # by-value Ctx carries self and the mandatory arguments; mrb_protect_error's
  # `void*` is its address. Other registers are temporaries, declared and
  # nil-initialized like `_impl`'s preamble; internal jumps use the usual labels.
  # `extra_fields` ([{name:, c_type:}]) adds Ctx members restored into
  # same-named locals: BLOCK_FALLBACK_RESCUE_SUPPORT passes captured upvar
  # pointers (`bc2cpp_upvar_N`), so GETUPVAR/SETUPVAR (keyed by name) work
  # unchanged.
  # DEEP_UPVAR_CAPTURE_SUPPORT: `available_upvars` is the enclosing function's
  # captured-pointer set (empty for a method-level rescue), threaded in by name
  # via `extra_fields`, so nested block calls may forward them further.
  # rescue_entry_saved_fields: self + raw arguments are the whole live-in state
  # only when begin_addr directly follows ENTER. A region entered by a branch
  # (an optional default like `def drive_battle(it = @interpreter)`, or an `if
  # ...; return; end` guard) can have any register set, so the whole register
  # file is captured by value, as for NESTED_RESCUE_SUPPORT.
  def rescue_entry_saved_fields(irep, region)
    return [] if irep.instructions.all? { |insn| insn.addr >= region[:begin_addr] || insn.op == 'ENTER' }

    (1...irep.nregs).map { |i| { name: "bc2cpp_saved_r#{i}", c_type: 'mrb_value' } }
  end

  def emit_rescue_try_body(try_name, region, irep, d, arg_names, arg_native_types, extra_fields: [],
                           available_upvars: [])
    ctx_struct = "#{try_name}_Ctx"
    ctx_fields = ['mrb_value self'] + arg_names.each_with_index.map { |a, i| "#{native_c_type(arg_native_types[i])} #{a}" } +
                 extra_fields.map { |f| "#{f[:c_type]} #{f[:name]}" }
    # RESCUE_BODY_BLOCK_SUPPORT: block-carrying calls inside the protected range
    # (`RGSS::Profiler.section("...") { ... }` in RPG2k#start_new_game) go through
    # emit_block_fallback_glue_pass like compile_method's top-level pass,
    # restricted to [begin_addr, end_addr]. The top-level pass never claims them
    # (this range is already in its `suppressed`). Local suppressed/glue_at: a
    # separate C++ function. Emitted before this function's opening brace, since
    # a cfunc cannot be defined inside another function.
    range = (region[:begin_addr]..region[:end_addr])
    local_suppressed = Set.new
    local_glue_at = {}
    # NESTED_RESCUE_SUPPORT: nested rescue ranges are claimed before the
    # block-fallback pass, as compile_method does, so a block inside a nested
    # region belongs to that region's recursive extraction. Claiming it here too
    # would emit the same block function twice (`redefinition of ...`).
    nested_rescue_regions = top_level_rescue_regions(
      recognize_rescue_regions(irep).select do |r|
        r != region && region[:begin_addr] <= r[:begin_addr] && r[:end_addr] <= region[:end_addr]
      end
    )
    nested_rescue_regions.each do |nregion|
      local_suppressed.merge((nregion[:begin_addr]..nregion[:end_addr]).to_a)
      local_suppressed << nregion[:except_addr]
    end
    nested_block_regions = recognize_block_fallback_regions(irep, available_upvars: available_upvars)
                           .select { |r| range.cover?(r[:block_addr]) }
    nested_arg_regions = recognize_explicit_block_arg_regions(irep).select { |r| range.cover?(r[:sendb_addr]) }
    out = emit_block_fallback_glue_pass(nested_block_regions, nested_arg_regions, d, local_suppressed, local_glue_at)

    # NESTED_RESCUE_SUPPORT: each direct child region gets its own further-nested
    # try body. Its begin_addr is reached after arbitrary code in this body, so
    # its live-in state may be any register: the whole register file r1..nregs-1
    # (all plain mrb_values) is captured by value via extra_fields/
    # extra_field_values, the mechanism upvar pointers already use. This body's
    # own extra_fields are inherited too. arg_names/arg_native_types are empty for
    # the recursive call (no named argument locals exist here). The init loop
    # below uses a `bc2cpp_saved_r<N>` field instead of nil when present.
    saved_regs = (1...irep.nregs).to_a
    nested_saved_fields = saved_regs.map { |i| { name: "bc2cpp_saved_r#{i}", c_type: 'mrb_value' } }
    # This body's own saved-register fields are superseded by the fresh capture.
    inherited_fields = extra_fields.reject { |f| f[:name].start_with?('bc2cpp_saved_r') }
    nested_extra_fields = inherited_fields + nested_saved_fields
    nested_extra_values = inherited_fields.map { |f| f[:name] } + saved_regs.map { |i| "r#{i}" }
    nested_rescue_regions.each_with_index do |nregion, ni|
      # (Already claimed into local_suppressed above.)
      nested_try_name = "#{try_name}_nested#{nested_rescue_regions.size > 1 ? "_#{ni}" : ''}"
      out << emit_rescue_try_body(nested_try_name, nregion, irep, d, [], [], extra_fields: nested_extra_fields,
                                                                            available_upvars: available_upvars)
      local_glue_at[nregion[:begin_addr]] =
        emit_rescue_glue(nested_try_name, nregion, [], [], extra_field_values: nested_extra_values)
    end

    out << "struct #{ctx_struct} { #{ctx_fields.join('; ')}; };\n"
    out << "static mrb_value #{try_name}(mrb_state* M, void* ud) {\n"
    out << "  #{ctx_struct}* ctx = (#{ctx_struct}*)ud;\n"
    extra_fields.each { |f| out << "  #{f[:c_type]} #{f[:name]} = ctx->#{f[:name]};\n" }
    (0...irep.nregs).each do |i|
      if i.zero?
        # GETIV/SETIV codegen uses the bare identifier `self`; this function receives
        # it through ctx, so alias it.
        out << "  mrb_value self = ctx->self;\n"
        out << "  mrb_value r0 = self;\n"
      elsif (saved = extra_fields.find { |f| f[:name] == "bc2cpp_saved_r#{i}" })
        # A saved-register capture is the register's value at begin_addr, so it wins
        # over the raw argument (an optional default may have replaced it).
        out << "  mrb_value r#{i} = #{saved[:name]};\n"
      elsif i <= arg_names.size
        a = arg_names[i - 1]
        t = arg_native_types[i - 1]
        out << if t
                  "  mrb_value r#{i} = #{TYPE_OPS.fetch(t)[:box]}(ctx->#{a});\n"
                else
                  "  mrb_value r#{i} = ctx->#{a};\n"
                end
      else
        out << "  mrb_value r#{i} = mrb_nil_value();\n"
      end
    end
    body_targets = jump_targets(irep).select { |t| t >= region[:begin_addr] && t <= region[:end_addr] } -
                   (local_suppressed.to_a - local_glue_at.keys)
    irep.instructions.each_with_index do |insn, idx|
      next unless insn.addr >= region[:begin_addr] && insn.addr <= region[:end_addr]
      next if local_suppressed.include?(insn.addr) && !local_glue_at.key?(insn.addr)

      out << "  L#{insn.addr}:;\n" if body_targets.include?(insn.addr)
      out << if insn.addr == region[:end_addr]
                "  return r#{region[:connector_reg]};\n"
              else
                local_glue_at[insn.addr] || compile_insn(insn, irep, d, idx)
              end
    end
    out << "  return mrb_nil_value(); // unreachable\n"
    out << "}\n\n"
    out
  end

  # RESCUE_SUPPORT: glue at begin_addr replacing [begin_addr, end_addr]: run the
  # try body under mrb_protect_error (vm.c), which returns the body's result with
  # err == FALSE, or the exception with err == TRUE, exception state cleared and
  # the ci stack unwound to here. On failure assign the exception to r<exc_reg>
  # and fall through into the clause tests (EXCEPT itself is suppressed).
  # On success:
  #   tail_return  -- a whole-method rescue: `return` the result directly.
  #   otherwise    -- assign it to r<connector_reg> (== r<exc_reg>) and goto
  #                   shared_target, which is a real jump target and so has a
  #                   label.
  # `extra_field_values`: C++ expressions for emit_rescue_try_body's
  # `extra_fields`, appended in order to the aggregate `ctx{...}` initializer.
  def emit_rescue_glue(try_name, region, arg_names, arg_native_types, extra_field_values: [])
    ctx_struct = "#{try_name}_Ctx"
    ctx_args = (['self'] + arg_names + extra_field_values).join(', ')
    err_var = "#{try_name}_err"
    result_var = "#{try_name}_result"
    out = String.new
    out << "  {\n"
    out << "    #{ctx_struct} ctx{#{ctx_args}};\n"
    out << "    mrb_bool #{err_var} = FALSE;\n"
    out << "    mrb_value #{result_var} = mrb_protect_error(M, #{try_name}, &ctx, &#{err_var});\n"
    out << if region[:tail_return]
              "    if (!#{err_var}) { return #{result_var}; }\n"
            else
              "    if (!#{err_var}) { r#{region[:connector_reg]} = #{result_var}; goto L#{region[:shared_target]}; }\n"
            end
    out << "    r#{region[:exc_reg]} = #{result_var};\n"
    out << "  }\n"
    out
  end

  # BLOCK_SUPPORT (ADR 0147): inline `receiver.times { |i| BODY }` as a native
  # `for` loop instead of building a Proc. mrb_proc_new would build a Proc with
  # no captured environment, while blocks close over outer locals; inlined, the
  # block body shares the method's `r0..rN`, so level-0 GETUPVAR/SETUPVAR are the
  # same variables and RETURN_BLK is a plain C++ return.
  # `#times` has no bytecode definition anywhere in the registry, so a
  # non-Integer receiver already raises NoMethodError when interpreted; the
  # emitted mrb_integer_p guard (raising on mismatch) is equivalent to real
  # dispatch for every receiver.
  # Shape: `SENDB Ra :times n=0` right after `BLOCK R(a+1) I[k]` (the block
  # argument goes in the register after the destination for n=0), with I[k]
  # taking exactly one mandatory argument.
  def recognize_times_regions(irep)
    regions = []
    irep.instructions.each_with_index do |insn, idx|
      next unless insn.op == 'SENDB' && idx.positive?

      dest, name, nstr = insn.args.split(/\s+/, 3)
      next unless name == ':times' && nstr == 'n=0'

      block_insn = irep.instructions[idx - 1]
      next unless block_insn && block_insn.op == 'BLOCK'

      dest_reg = dest[/^R(\d+)/, 1]
      block_reg = block_insn.args[/^R(\d+)/, 1]
      next unless dest_reg && block_reg && block_reg == (dest_reg.to_i + 1).to_s

      block_irep_idx = block_insn.args[/I\[(\d+)\]/, 1]
      next unless block_irep_idx

      block_label = irep.reps[block_irep_idx.to_i]
      block_irep = block_label && @ireps[block_label]
      next unless block_irep && mandatory_arity(block_irep) == 1 && pure_mandatory_arity?(block_irep)

      regions << { block_addr: block_insn.addr, sendb_addr: insn.addr, dest_reg: dest_reg, block_irep: block_irep }
    end
    regions
  end

  # EACH_BLOCK_SUPPORT (ADR 0152): inline `ary.each { |x| ... }`. Same BLOCK +
  # `SENDB`/`SSENDB Ra :each n=0` adjacency as times. `#each` has bytecode
  # definitions (Game::Actors, Game::Party, LCF::Array2D), so the receiver must
  # trace (trace_new_target) to exactly "Array". An SSENDB (self receiver) is
  # admitted only when the owner is Array itself. Anything unproven gives no
  # region.
  def recognize_each_regions(irep, owner_name, mand, ivar_classes, arg_classes)
    regions = []
    irep.instructions.each_with_index do |insn, idx|
      next unless %w[SENDB SSENDB].include?(insn.op) && idx.positive?

      dest, name, nstr = insn.args.split(/\s+/, 3)
      next unless name == ':each' && nstr == 'n=0'

      block_insn = irep.instructions[idx - 1]
      next unless block_insn && block_insn.op == 'BLOCK'

      dest_reg = dest[/^R(\d+)/, 1]
      block_reg = block_insn.args[/^R(\d+)/, 1]
      next unless dest_reg && block_reg && block_reg == (dest_reg.to_i + 1).to_s

      block_irep_idx = block_insn.args[/I\[(\d+)\]/, 1]
      next unless block_irep_idx

      block_label = irep.reps[block_irep_idx.to_i]
      block_irep = block_label && @ireps[block_label]
      next unless block_irep && mandatory_arity(block_irep) == 1 && pure_mandatory_arity?(block_irep)

      if insn.op == 'SSENDB'
        next unless owner_name == 'Array'
      else
        # CHAINED_ACCESSOR_SUPPORT: passing @class_layout/@registry can only turn nil
        # into 'Array'.
        traced = trace_new_target(irep, idx, dest_reg, ivar_classes, mand, arg_classes, owner: owner_name,
                                   class_layout: @class_layout, registry: @registry,
                                   container_constants: @container_constants)
        traced = proven_array_source(irep, idx, dest_reg) if traced != 'Array'
        next unless traced == 'Array'
      end

      regions << { block_addr: block_insn.addr, sendb_addr: insn.addr, dest_reg: dest_reg, block_irep: block_irep,
                   ssendb: insn.op == 'SSENDB',
                   elem_class: region_element_class(insn, irep, idx, dest_reg, ivar_classes, mand, arg_classes,
                                                   owner_name) }
    end
    regions
  end

  # HASH_EACH_SUPPORT: inline `hash.each { |k, v| ... }`. Same adjacency and
  # `:each` name as recognize_each_regions; the receiver gates ('Array' vs
  # 'Hash') make them exclusive. Hash#each (mrblib/hash.rb) always yields key
  # and value; the emitter assigns them directly to the block's R1/R2 (as the
  # reduce/inject and each_with_index emitters do). No bytecode Hash#each
  # override or Hash subclass exists here; the SSENDB/owner-is-Hash rule is
  # kept for symmetry.
  def recognize_hash_each_regions(irep, owner_name, mand, ivar_classes, arg_classes)
    regions = []
    irep.instructions.each_with_index do |insn, idx|
      next unless %w[SENDB SSENDB].include?(insn.op) && idx.positive?

      dest, name, nstr = insn.args.split(/\s+/, 3)
      next unless name == ':each' && nstr == 'n=0'

      block_insn = irep.instructions[idx - 1]
      next unless block_insn && block_insn.op == 'BLOCK'

      dest_reg = dest[/^R(\d+)/, 1]
      block_reg = block_insn.args[/^R(\d+)/, 1]
      next unless dest_reg && block_reg && block_reg == (dest_reg.to_i + 1).to_s

      block_irep_idx = block_insn.args[/I\[(\d+)\]/, 1]
      next unless block_irep_idx

      block_label = irep.reps[block_irep_idx.to_i]
      block_irep = block_label && @ireps[block_label]
      next unless block_irep && mandatory_arity(block_irep) == 2 && pure_mandatory_arity?(block_irep)

      if insn.op == 'SSENDB'
        next unless owner_name == 'Hash'
      else
        traced = trace_new_target(irep, idx, dest_reg, ivar_classes, mand, arg_classes, owner: owner_name,
                                   class_layout: @class_layout, registry: @registry,
                                   container_constants: @container_constants)
        next unless traced == 'Hash'
      end

      regions << { block_addr: block_insn.addr, sendb_addr: insn.addr, dest_reg: dest_reg, block_irep: block_irep,
                   ssendb: insn.op == 'SSENDB',
                   elem_class: region_hash_element_class(insn, irep, idx, dest_reg, ivar_classes, mand, arg_classes,
                                                        owner_name) }
    end
    regions
  end

  # EACH_INDEX_SUPPORT: inline `ary.each_index { |i| ... }`. Array#each_index
  # (mrblib/array.rb):
  #
  #   def each_index(&block)
  #     return to_enum(:each_index) unless block
  #     idx = 0
  #     while idx < length
  #       yield idx
  #       idx += 1
  #     end
  #     self
  #   end
  #
  # `length` is re-read every pass, the block gets the index, and the result is
  # the receiver. Same adjacency and Array receiver gate as each. No bytecode
  # override exists (the only Array reopens are array_include.rb and
  # array_sort.rb, and LCF::Array1D/Array2D are not Array subclasses).
  def recognize_each_index_regions(irep, owner_name, mand, ivar_classes, arg_classes)
    regions = []
    irep.instructions.each_with_index do |insn, idx|
      next unless %w[SENDB SSENDB].include?(insn.op) && idx.positive?

      dest, name, nstr = insn.args.split(/\s+/, 3)
      next unless name == ':each_index' && nstr == 'n=0'

      block_insn = irep.instructions[idx - 1]
      next unless block_insn && block_insn.op == 'BLOCK'

      dest_reg = dest[/^R(\d+)/, 1]
      block_reg = block_insn.args[/^R(\d+)/, 1]
      next unless dest_reg && block_reg && block_reg == (dest_reg.to_i + 1).to_s

      block_irep_idx = block_insn.args[/I\[(\d+)\]/, 1]
      next unless block_irep_idx

      block_label = irep.reps[block_irep_idx.to_i]
      block_irep = block_label && @ireps[block_label]
      next unless block_irep && mandatory_arity(block_irep) == 1 && pure_mandatory_arity?(block_irep)

      if insn.op == 'SSENDB'
        next unless owner_name == 'Array'
      else
        traced = trace_new_target(irep, idx, dest_reg, ivar_classes, mand, arg_classes, owner: owner_name,
                                   class_layout: @class_layout, registry: @registry,
                                   container_constants: @container_constants)
        traced = proven_array_source(irep, idx, dest_reg) if traced != 'Array'
        next unless traced == 'Array'
      end

      regions << { block_addr: block_insn.addr, sendb_addr: insn.addr, dest_reg: dest_reg, block_irep: block_irep,
                   ssendb: insn.op == 'SSENDB' }
    end
    regions
  end

  # EACH_KEY_SUPPORT: inline `hash.each_key { |k| ... }`. Hash#each_key
  # (mrblib/hash.rb):
  #
  #   def each_key(&block)
  #     return to_enum(:each_key) unless block
  #     self.keys.each {|k| block.call(k)}
  #     self
  #   end
  #
  # It iterates a snapshot (`keys` is a fresh Array, mrb_hash_keys), yields the
  # key, returns the receiver. Same adjacency and Hash receiver gate as
  # recognize_hash_each_regions; no bytecode override exists.
  def recognize_each_key_regions(irep, owner_name, mand, ivar_classes, arg_classes)
    regions = []
    irep.instructions.each_with_index do |insn, idx|
      next unless %w[SENDB SSENDB].include?(insn.op) && idx.positive?

      dest, name, nstr = insn.args.split(/\s+/, 3)
      next unless name == ':each_key' && nstr == 'n=0'

      block_insn = irep.instructions[idx - 1]
      next unless block_insn && block_insn.op == 'BLOCK'

      dest_reg = dest[/^R(\d+)/, 1]
      block_reg = block_insn.args[/^R(\d+)/, 1]
      next unless dest_reg && block_reg && block_reg == (dest_reg.to_i + 1).to_s

      block_irep_idx = block_insn.args[/I\[(\d+)\]/, 1]
      next unless block_irep_idx

      block_label = irep.reps[block_irep_idx.to_i]
      block_irep = block_label && @ireps[block_label]
      next unless block_irep && mandatory_arity(block_irep) == 1 && pure_mandatory_arity?(block_irep)

      if insn.op == 'SSENDB'
        next unless owner_name == 'Hash'
      else
        traced = trace_new_target(irep, idx, dest_reg, ivar_classes, mand, arg_classes, owner: owner_name,
                                   class_layout: @class_layout, registry: @registry,
                                   container_constants: @container_constants)
        next unless traced == 'Hash'
      end

      regions << { block_addr: block_insn.addr, sendb_addr: insn.addr, dest_reg: dest_reg, block_irep: block_irep,
                   ssendb: insn.op == 'SSENDB' }
    end
    regions
  end

  # ELEMENT_CLASS_SUPPORT: element class of a region's receiver, or nil. SSENDB
  # answers nil: its receiver is self (only admitted when the owner is Array),
  # with no register to scan.
  def region_element_class(insn, irep, idx, dest_reg, ivar_classes, mand, arg_classes, owner_name)
    return nil if insn.op == 'SSENDB'

    proven_element_class(irep, idx, dest_reg, ivar_classes, mand, arg_classes, owner_name)
  end

  # HASH_ELEMENT_SUPPORT: region_element_class for Hash values.
  def region_hash_element_class(insn, irep, idx, dest_reg, ivar_classes, mand, arg_classes, owner_name)
    return nil if insn.op == 'SSENDB'

    proven_hash_element_class(irep, idx, dest_reg, ivar_classes, mand, arg_classes, owner_name)
  end

  # INTERP_UNLOCK / CORE_ARRAY_CHAIN: the chained-receiver rule lives at top
  # level in proven_array_source_scan (ClassLayout.analyze needs it too; one copy
  # of a soundness-critical rule). This wrapper adds the registry and the
  # `-> Array` annotations.
  # ARRAY_RETURN_PROOF: the return fixpoint is passed as the second oracle here
  # but not from ClassLayout.analyze's call (it needs @class_layout, which
  # ClassLayout is still building), so ClassLayout's facts are unaffected.
  def proven_array_source(irep, idx, dest_reg)
    proven_array_source_scan(irep, idx, dest_reg, @registry, ->(n) { annotated_array_return(n) },
                             ->(n) { @array_return_names.include?(n) })
  end

  # GETIDX_STATIC_RECEIVER_SUPPORT: is this GETIDX/GETIDX0/SETIDX receiver
  # provably Array or Hash, using the facts recognize_each_regions trusts
  # (trace_new_target, plus proven_array_source for Arrays; there is no Hash
  # literal scan yet, which only costs proofs)? Also returns an exact custom
  # class with a compiled `[]`/`[]=` so compile_send's guarded TYPED lowering
  # can be reused. Other callers match only Array/Hash.
  # `idx.nil?` bails: the backward scan needs a position.
  # BLOCK_BODY_INDEX_SUPPORT: inlined block bodies pass the real index in
  # block_irep.instructions plus the register shift, and compile_insn maps `reg`
  # back with unshift_proof_reg, so `irep`, `idx` and `reg` share one numbering.
  def static_indexable_class(irep, idx, reg, owner_def)
    return nil unless owner_def && idx

    enter = irep.instructions.find { |i| i.op == 'ENTER' }
    mand = enter ? enter.args.split(':').first.to_i : 0
    arg_classes = @class_annotations[irep.label]&.args
    ivar_classes = @class_layout[owner_def.owner]
    traced = trace_new_target(irep, idx, reg, ivar_classes, mand, arg_classes, owner: owner_def.owner,
                               class_layout: @class_layout, registry: @registry,
                               container_constants: @container_constants,
                               element_annotations: @element_annotations,
                               known_owners: @known_owners, capture_hints: @block_hash_capture_hints)
    traced = resolve_owner_name(traced, { owner: owner_def.owner, known_owners: @known_owners }) if traced
    return traced if %w[Array Hash].include?(traced)
    return traced if traced && %w[[] []=].any? do |name|
      @registry[name]&.any? { |md| md.owner == traced && md.irep }
    end

    proven_array_source(irep, idx, reg) == 'Array' ? 'Array' : nil
  end

  # INDEX_SEND_DEVIRT: when GETIDX's dynamic `[]` fallback receiver has an exact
  # compiled user class, reuse compile_send's guarded TYPED call. Only a TYPED
  # result is accepted: MONO would drop GETIDX's container semantics for
  # unproven receivers.
  def compile_typed_index_send(irep, idx, owner_def, dest_reg, receiver_reg, index_expr, reg_offset, receiver_class,
                               fallback_code)
    return nil unless owner_def && idx && receiver_class
    return nil unless @registry['[]']&.any? { |md| md.owner == receiver_class && md.irep }

    saved_hint = @elem_class_hint
    code = compile_send("R#{dest_reg} :[] n=1", self_implicit: false, irep: irep,
                        idx: reg_offset.zero? ? idx : nil, owner_def: owner_def,
                        call_receiver: "r#{receiver_reg}", call_arguments: [index_expr],
                        trace_idx: idx, trace_reg_offset: reg_offset,
                        trace_receiver_reg: receiver_reg, typed_fallback: fallback_code)
    return code if code.include?('TYPED :[] ->')

    @elem_class_hint = saved_hint
    nil
  end

  def compile_typed_index_write(irep, idx, owner_def, receiver_reg, index_reg, value_reg, reg_offset, receiver_class,
                                fallback_code)
    return nil unless owner_def && idx && receiver_class
    return nil unless @registry['[]=']&.any? { |md| md.owner == receiver_class && md.irep }

    saved_hint = @elem_class_hint
    code = compile_send("R#{receiver_reg} :[]= n=2", self_implicit: false, irep: irep,
                        idx: reg_offset.zero? ? idx : nil, owner_def: owner_def,
                        call_receiver: "r#{receiver_reg}", call_arguments: ["r#{index_reg}", "r#{value_reg}"],
                        trace_idx: idx, trace_reg_offset: reg_offset,
                        trace_receiver_reg: receiver_reg, typed_fallback: fallback_code)
    return code if code.include?('TYPED :[]= ->')

    @elem_class_hint = saved_hint
    nil
  end

  # ---------------------------------------------------------------------------
  # FIXNUM_OPERAND_PROOF: is THIS register provably a Fixnum at THIS point? When
  # both operands of ADD/ADDI/SUB/SUBI/MUL/DIV/EQ/LT/LE/GT/GE prove, compile_insn
  # emits only the native computation, with no mrb_funcall fallback.
  #
  # Proof sources (facts this file already relies on, not a general prover):
  #   1. A LOADI-family literal within the Fixnum range (see
  #      LOADI_FIXNUM_RANGE).
  #   2. A NATIVE_ARG_TARGETS :fixnum mandatory argument not reassigned since
  #      entry: the C++ parameter is an mrb_int (fixnum_proof_entry_arg?).
  #   3. A GETIV of an ivar embedded as :fixnum: an mrb_int struct field whose
  #      every write is guarded by mrb_integer_p.
  #   4. ADD/SUB/MUL/ADDI/SUBI whose operands prove (bounded by
  #      FIXNUM_PROOF_MAX_DEPTH): such an op is emitted as a bare
  #      mrb_fixnum_value(a <op> b). DIV is not a source: mrb_div_int_value's
  #      result type is not audited.
  #   5. GETCONST/GETMCNST of an IntegerConstants name.
  #   (6. FIXNUM_RETURN_PROOF and 7. ENTRY_ARG_CALLSITE_PROOF, below.)
  # MOVE chains are followed (`regs[a] = regs[b]`).
  #
  # The backward "most recent write" is only meaningful if control cannot enter
  # between the write and the use. Entry points, all honoured:
  #   - goto targets (jump_targets). REGION_DOMINANCE (fixnum_proof_region_ok?,
  #     with the edge map from fixnum_proof_edge_sources) lets the walk step
  #     past a label when every branch to it lies inside the write..use region.
  #     JOIN_REACHING_DEFS: when no single write dominates (`x = c ? 5 : 7`),
  #     fixnum_proof_reaching_defs? requires every reaching definition to prove.
  #   - exception handlers: each catch handler's target is an entry, and its
  #     whole begin_addr..end_addr range refuses outright, at the use and at
  #     every step. RESCUE_SUPPORT extracts that range into a separate function
  #     whose registers are re-initialized, yet compile_insn is called there
  #     with the enclosing irep, so the walk must not step back out of it.
  #   - nested blocks writing an enclosing local: SETUPVAR compiles to a write
  #     of r<b> (inlined bodies) or *bc2cpp_upvar_<b> (BLOCK_FALLBACK), outside
  #     this instruction list. Every SETUPVAR destination in the child subtree
  #     (any level) is refused.
  # Anything else declines and keeps the dual-path codegen.
  # ---------------------------------------------------------------------------

  # Opcodes the backward scan may STEP OVER: verified (ops.h, vm.c) to write at
  # most the register named by their first `R<n>` operand and to create no entry
  # point. Everything else ends the scan with a refusal, e.g. RESCUE (writes its
  # second operand), APOST (a range), ARGARY (a and a+1), ASET, SETUPVAR (an
  # enclosing frame), EXCEPT/RAISEIF/MATCHERR/JMPUW (exception edges), EXT*,
  # CALL, ERR, and any future opcode. A whitelist: an over-approximated write
  # only costs a proof, an under-approximated one is a wrong answer.
  FIXNUM_PROOF_STEP_OVER_OPS = Set[
    'NOP', 'MOVE', 'LOADL', 'LOADSYM', 'LOADNIL', 'LOADSELF', 'LOADTRUE', 'LOADFALSE',
    'GETGV', 'SETGV', 'GETSV', 'SETSV', 'GETIV', 'SETIV', 'GETCV', 'SETCV',
    'GETCONST', 'SETCONST', 'GETMCNST', 'SETMCNST', 'GETUPVAR',
    'GETIDX', 'GETIDX0', 'SETIDX',
    'JMP', 'JMPIF', 'JMPNOT', 'JMPNIL',
    'SSEND', 'SSEND0', 'SSENDB', 'SEND', 'SEND0', 'SENDB', 'SUPER', 'BLKCALL', 'BLKPUSH',
    'ENTER', 'KEY_P', 'KEYEND', 'KARG',
    'RETURN', 'RETURN_BLK', 'RETSELF', 'RETNIL', 'RETTRUE', 'RETFALSE', 'BREAK',
    'ADD', 'ADDI', 'SUB', 'SUBI', 'ADDILV', 'SUBILV', 'MUL', 'DIV',
    'EQ', 'LT', 'LE', 'GT', 'GE',
    'ARRAY', 'ARRAY2', 'ARYCAT', 'ARYPUSH', 'ARYSPLAT', 'AREF',
    'INTERN', 'SYMBOL', 'STRING', 'STRCAT', 'HASH', 'HASHADD', 'HASHCAT',
    'LAMBDA', 'BLOCK', 'METHOD', 'RANGE_INC', 'RANGE_EXC',
    'OCLASS', 'CLASS', 'MODULE', 'EXEC', 'DEF', 'TDEF', 'SDEF', 'ALIAS', 'UNDEF',
    'SCLASS', 'TCLASS', 'DEBUG', 'STOP'
  ].freeze

  # Members of FIXNUM_PROOF_STEP_OVER_OPS whose leading register is READ, not
  # written: ops.h gives JMPIF/JMPNOT/JMPNIL the BS format (register first), and
  # vm.c's handlers only test regs[a] (`if (mrb_test(regs[a])) { ci->pc += b;
  # ... }`). Treating them as writes was safe but stopped the walk at `a && 5`,
  # `a || 7`, `h&.size || 3`, where the condition register is the result. This
  # affects only the write test; they stay steppable and remain branch sources
  # for the dominance and reaching-definition machinery.
  FIXNUM_PROOF_READONLY_REG_OPS = Set['JMPIF', 'JMPNOT', 'JMPNIL'].freeze

  # Does `insn` write register `reg`? Shared by the single-path walk and the
  # JOIN_REACHING_DEFS worklist. For every whitelisted op except the three
  # read-only ones, the leading `R<n>` is the destination (the audited
  # property). Under-reporting a write would be a wrong answer, so this is an
  # explicit exception list, nothing inferred.
  def fixnum_proof_writes_reg?(insn, reg)
    return false if FIXNUM_PROOF_READONLY_REG_OPS.include?(insn.op)

    !(insn.args =~ /\AR#{reg}\b/).nil?
  end

  # Nested proven-arithmetic hops for source 4. `(a + b) * (c - d)` needs two;
  # unbounded recursion could go exponential on long chains.
  FIXNUM_PROOF_MAX_DEPTH = 4

  # Per-irep, memoized: entry addresses (goto targets and catch targets),
  # protected-range addresses, SETUPVAR destinations, and (REGION_DOMINANCE)
  # the branch-edge map and catch-target set.
  def fixnum_proof_ctx(irep)
    @fixnum_proof_ctx ||= {}
    return @fixnum_proof_ctx[irep.label] if @fixnum_proof_ctx.key?(irep.label)

    entries = jump_targets(irep).dup
    protected_addrs = Set.new
    catch_targets = Set.new
    (irep.catch_handlers || []).each do |ch|
      entries << ch.target
      catch_targets << ch.target
      protected_addrs.merge(ch.begin_addr..ch.end_addr)
    end
    edges = fixnum_proof_edge_sources(irep)
    entries.merge(edges.keys)
    @fixnum_proof_ctx[irep.label] =
      { entries: entries, protected: protected_addrs, upvars: subtree_upvar_written_regs(irep),
        edge_sources: edges, catch_targets: catch_targets }
  end

  # REGION_DOMINANCE: target address -> addresses branching to it. Exactly five
  # opcodes move pc within a frame (ops.h): JMP/JMPUW (S, target only) and
  # JMPIF/JMPNOT/JMPNIL (BS, register then target). OP_ENTER does not branch
  # (optional-argument dispatch is an ordinary JMP table after it).
  # RETURN/RETURN_BLK/BREAK/STOP leave the frame; RAISEIF/ERR/EXCEPT reach a
  # handler only through a catch entry, which has no source instruction, so
  # catch targets always refuse.
  # JMPUW is included although jump_targets omits it: the proof still runs in
  # such a body during a compiles_clean? probe, and an unmodelled edge is the
  # one miss this test cannot afford.
  def fixnum_proof_edge_sources(irep)
    edges = Hash.new { |h, k| h[k] = Set.new }
    irep.instructions.each do |insn|
      case insn.op
      when 'JMP', 'JMPUW'
        edges[insn.args.strip[/\d+/].to_i] << insn.addr
      when 'JMPIF', 'JMPNOT', 'JMPNIL'
        edges[jmp_target_after_reg(insn.args)] << insn.addr
      end
    end
    edges
  end

  # REGION_DOMINANCE: does the write at `w_idx` dominate the use at `u_idx`?
  # The region [w_idx, u_idx] is contiguous (the walk only steps back, and
  # addresses grow with index). The forward walk checked that nothing in
  # (w_idx, u_idx] writes the register, so a path reaching the use can only have
  # entered the region by falling into w_idx (the write ran) or by branching to
  # a label inside (w_idx, u_idx] (skipping it). So W dominates U iff every
  # source of every entry address inside the region lies within [lo, hi]. A
  # source below lo skips the write; a source above hi is a back-edge that could
  # bring a later write around to U.
  #
  #     x = 5          # W  -- LOADI_5
  #     if cond        #    -- JMPNOT ... L1
  #       ...
  #     end            # L1:
  #     y = x + 1      # U  -- ADD, operand x
  #
  # A loop wholly between W and U is admitted; a loop whose back-edge follows U
  # is refused. A catch target, or an entry with no recorded in-edge (an
  # unmodelled edge), refuses. `w_idx` -1 means "the method preamble wrote it":
  # the region is the whole body up to the use, and back-edges from below still
  # refuse.
  def fixnum_proof_region_ok?(irep, ctx, w_idx, u_idx)
    lo = irep.instructions[[w_idx, 0].max].addr
    hi = irep.instructions[u_idx].addr
    ((w_idx + 1)..u_idx).each do |k|
      addr = irep.instructions[k].addr
      next unless ctx[:entries].include?(addr)
      return false if ctx[:catch_targets].include?(addr)

      srcs = ctx[:edge_sources][addr]
      return false if srcs.nil? || srcs.empty?
      return false unless srcs.all? { |s| s >= lo && s <= hi }
    end
    true
  end

  # SETUPVAR destinations (operand B) anywhere in the child subtree. The level is
  # ignored: over-collecting only costs a proof.
  def subtree_upvar_written_regs(irep, acc = Set.new, seen = Set.new)
    (irep.reps || []).each do |label|
      next if seen.include?(label)

      seen << label
      child = @ireps[label]
      next unless child

      child.instructions.each do |insn|
        next unless insn.op == 'SETUPVAR'

        b = insn.args.split(/\s+/)[1]
        acc << b if b =~ /\A\d+\z/
      end
      subtree_upvar_written_regs(child, acc, seen)
    end
    acc
  end

  # FIXNUM_OPERAND_PROOF entry point (see the header). `reg` is a register
  # number string. true only for an exact proof; false means "not provable",
  # not "not a Fixnum".
  def proven_fixnum_operand?(irep, idx, reg, owner_def, depth = 0)
    return false unless irep && idx && reg && owner_def
    return false if depth > FIXNUM_PROOF_MAX_DEPTH

    ctx = fixnum_proof_ctx(irep)
    return false unless ctx

    cur = reg.to_s
    return false if ctx[:upvars].include?(cur)

    # JOIN_REACHING_DEFS: where `cur` is actually READ. It moves back to each MOVE
    # crossed, since `MOVE Ra Rb` reads Rb at its own address; asking at the
    # original use would ask about a register later code may overwrite.
    need_idx = idx
    j = idx
    while j >= 0
      insn = irep.instructions[j]
      return false unless insn
      # Inside a protected range: compiled into a separate function with
      # re-initialized registers, so neither using nor stepping here means anything.
      return false if ctx[:protected].include?(insn.addr)
      # An unaudited opcode could write `cur` from an operand this test does not
      # read: refuse.
      return false unless FIXNUM_PROOF_STEP_OVER_OPS.include?(insn.op) || insn.op.start_with?('LOADI')

      if j < idx && fixnum_proof_writes_reg?(insn, cur)
        if insn.op == 'MOVE'
          # `regs[a] = regs[b]`: continue with the source register.
          src = insn.args.scan(/R(\d+)/).flatten[1]
          return false unless src
          return false if ctx[:upvars].include?(src)

          cur = src
          need_idx = j
        else
          # REGION_DOMINANCE: the write is found; check nothing enters the region except
          # through it.
          if fixnum_proof_region_ok?(irep, ctx, j, idx)
            return fixnum_proof_source?(irep, j, insn, cur, owner_def, depth)
          end

          # JOIN_REACHING_DEFS: the write does not dominate, so ask the multi-path
          # question: every reaching definition must prove.
          return fixnum_proof_reaching_defs?(irep, ctx, need_idx, cur, owner_def, depth)
        end
      end

      j -= 1
    end

    # Fell off the top: `cur` holds the preamble's value. REGION_DOMINANCE with -1
    # still rejects a back-edge from below the use.
    unless fixnum_proof_region_ok?(irep, ctx, -1, idx)
      return fixnum_proof_reaching_defs?(irep, ctx, need_idx, cur, owner_def, depth)
    end

    fixnum_proof_entry_arg?(irep, cur, owner_def)
  end

  # JOIN_REACHING_DEFS -------------------------------------------------------
  # Cap on (index, register) states the multi-path walk expands. Refusing on
  # exhaustion is safe and keeps codegen linear.
  FIXNUM_PROOF_REACHING_MAX_STATES = 400

  # Predecessor map: index -> indices control can come from (-1 = method entry).
  # An extra predecessor only costs a proof; a missing one is a wrong answer. So
  # fall-through is assumed for every opcode except those that never fall
  # through (JMP/JMPUW; RETURN/RETURN_BLK/RETSELF/RETNIL/RETTRUE/RETFALSE/BREAK/
  # STOP), and branch edges are the five JMP* opcodes. A jump to an address with
  # no instruction makes the whole map nil, so every query refuses.
  FIXNUM_PROOF_NO_FALLTHROUGH_OPS = Set[
    'JMP', 'JMPUW',
    'RETURN', 'RETURN_BLK', 'RETSELF', 'RETNIL', 'RETTRUE', 'RETFALSE', 'BREAK', 'STOP'
  ].freeze

  def fixnum_proof_preds(irep)
    @fixnum_proof_preds ||= {}
    return @fixnum_proof_preds[irep.label] if @fixnum_proof_preds.key?(irep.label)

    @fixnum_proof_preds[irep.label] = build_fixnum_proof_preds(irep)
  end

  def build_fixnum_proof_preds(irep)
    insns = irep.instructions
    addr_to_idx = {}
    insns.each_with_index { |ins, k| addr_to_idx[ins.addr] = k }
    preds = Hash.new { |h, k| h[k] = Set.new }
    preds[0] << -1
    insns.each_with_index do |ins, k|
      unless FIXNUM_PROOF_NO_FALLTHROUGH_OPS.include?(ins.op)
        preds[k + 1] << k if k + 1 < insns.size
      end
      t =
        case ins.op
        when 'JMP', 'JMPUW' then ins.args.strip[/\d+/].to_i
        when 'JMPIF', 'JMPNOT', 'JMPNIL' then jmp_target_after_reg(ins.args)
        end
      next if t.nil?

      ti = addr_to_idx[t]
      return nil if ti.nil?

      preds[ti] << k
    end
    preds
  end

  # JOIN_REACHING_DEFS: does EVERY definition of `reg` reaching the read at
  # `need_idx` prove Fixnum? Handles joins no single write dominates, e.g.
  # `x = c ? 5 : 7; x + 1`:
  #
  #     007 JMPNOT  R4  016
  #     011 LOADI_5 R4  (5)
  #     013 JMP     018
  #     016 LOADI_7 R4  (7)
  #     018 MOVE    R3  R4        <- the join
  #
  # A backward worklist of (index, register) states meaning "the value flowing
  # into index i must be a Fixnum". For each predecessor p: if p writes r it is
  # a reaching definition (MOVE continues with the source register, anything
  # else must satisfy fixnum_proof_source?); otherwise ask (p, r). Method entry
  # uses the entry-argument test.
  # Each state is expanded once and true is only returned once the worklist is
  # empty, so re-reaching a state over a loop back-edge is memoization, not an
  # optimistic assumption. The single-path barriers all apply: protected ranges,
  # catch targets, unaudited opcodes, SETUPVAR destinations.
  def fixnum_proof_reaching_defs?(irep, ctx, need_idx, reg, owner_def, depth)
    return false if depth > FIXNUM_PROOF_MAX_DEPTH

    preds = fixnum_proof_preds(irep)
    return false if preds.nil?

    seen = Set.new
    work = [[need_idx, reg.to_s]]
    until work.empty?
      state = work.pop
      next if seen.include?(state)

      seen << state
      return false if seen.size > FIXNUM_PROOF_REACHING_MAX_STATES

      i, r = state
      return false if ctx[:upvars].include?(r)

      here = irep.instructions[i]
      return false unless here
      return false if ctx[:catch_targets].include?(here.addr)
      return false if ctx[:protected].include?(here.addr)

      ps = preds[i]
      return false if ps.nil? || ps.empty?

      ps.each do |p|
        if p < 0
          # Method entry: the preamble's value; use the entry-argument proof.
          return false unless fixnum_proof_entry_arg?(irep, r, owner_def)

          next
        end

        insn = irep.instructions[p]
        return false unless insn
        return false if ctx[:protected].include?(insn.addr)
        return false unless FIXNUM_PROOF_STEP_OVER_OPS.include?(insn.op) || insn.op.start_with?('LOADI')

        if fixnum_proof_writes_reg?(insn, r)
          if insn.op == 'MOVE'
            src = insn.args.scan(/R(\d+)/).flatten[1]
            return false unless src
            return false if ctx[:upvars].include?(src)

            work << [p, src]
          else
            return false unless fixnum_proof_source?(irep, p, insn, r, owner_def, depth)
          end
        else
          work << [p, r]
        end
      end
    end

    true
  end

  # LOADI_FIXNUM_RANGE: the narrowest Fixnum range of any shipped target (the
  # proof runs once, in the host diagnostic). mrb_int is 32-bit on
  # Emscripten/Wio/PSP and word boxing (no build uses nan boxing) tags one bit:
  # MRB_FIXNUM_MIN/MAX = (INT32_MIN>>1)..(INT32_MAX>>1) (mruby/boxing_word.h,
  # TYPED_FIXABLE in mruby/numeric.h).
  # Every LOADI form but LOADI32 runs SET_FIXNUM_VALUE (vm.c). LOADI32 runs
  # SET_INT_VALUE -> mrb_boxing_int_value (src/etc.c), which returns a heap
  # Integer for non-FIXABLE literals (`z = 2000000000` emits LOADI32), and the
  # proof's codegen would apply a bare mrb_fixnum() to it: silent UB. Hence the
  # range check.
  LOADI_FIXNUM_MIN = -1_073_741_824
  LOADI_FIXNUM_MAX = 1_073_741_823

  # A LOADI* literal, or nil: the second whitespace-separated token
  # (`LOADI32\tR1\t9999999\t; R1:x`). LOADINEG prints the negated value.
  def loadi_literal(insn)
    tok = insn.args.split(/\s+/)[1]
    tok && tok.match?(/\A-?\d+\z/) ? tok.to_i : nil
  end

  def loadi_proven_fixnum?(insn)
    # LOADI8/LOADI16/LOADINEG/LOADI_n stay within +-2^15, FIXABLE everywhere. Only
    # LOADI32 needs the bound check.
    return true unless insn.op == 'LOADI32'

    lit = loadi_literal(insn)
    !lit.nil? && lit >= LOADI_FIXNUM_MIN && lit <= LOADI_FIXNUM_MAX
  end

  # Classify the instruction found writing `reg` (MOVE is handled by the caller).
  def fixnum_proof_source?(irep, j, insn, reg, owner_def, depth)
    return loadi_proven_fixnum?(insn) if insn.op.start_with?('LOADI')

    case insn.op
    when 'GETIV'
      ivar = insn.args[/@(\w+)/, 1]
      !ivar.nil? && embed_type(owner_def.owner, ivar) == :fixnum
    when 'ADD', 'SUB', 'MUL'
      s = insn.args[/\(R(\d+)\)/, 1]
      !s.nil? && proven_fixnum_operand?(irep, j, reg, owner_def, depth + 1) &&
        proven_fixnum_operand?(irep, j, s, owner_def, depth + 1)
    when 'ADDI', 'SUBI'
      proven_fixnum_operand?(irep, j, reg, owner_def, depth + 1)
    when 'GETCONST'
      # "GETCONST R4 WEAPON_SLOT": register first, bare name second
      # (`"GETCONST\tR%d\t%s"`); a trailing print_lv_a comment follows the name.
      @integer_constants.include?(insn.args.split(/\s+/)[1])
    when 'GETMCNST'
      # "GETMCNST R4 (R4)::DEPTH": only the bare name after `::`, as IntegerConstants
      # keys on (the scope register is not modelled).
      @integer_constants.include?(insn.args[/::(\S+)/, 1])
    when 'SEND', 'SEND0', 'SSEND', 'SSEND0'
      # FIXNUM_RETURN_PROOF (source 6): see compute_fixnum_return_names. SENDB/SSENDB
      # are excluded: a `break` in the caller's block becomes the send's result.
      nm = insn.args[/:([\w+\-*\/<>=!?\[\]&|^~%@]+)/, 1]
      !nm.nil? && @fixnum_return_names.include?(nm)
    else
      false
    end
  end

  # Proof source 2: a mandatory argument register of THIS method's own irep whose
  # NATIVE_ARG_TARGETS parameter is mrb_int (boxed by the preamble).
  # `owner_def.irep == irep.label` is load-bearing: compile_insn also runs on a
  # BLOCK_FALLBACK child irep with the enclosing method's owner_def, and there
  # r1.. are block parameters. pure_mandatory_arity? likewise: with optionals the
  # registers no longer map 1:1 onto native_arg_types.
  def fixnum_proof_entry_arg?(irep, reg, owner_def)
    return false unless owner_def.irep == irep.label
    return false unless pure_mandatory_arity?(irep)

    enter = irep.instructions.find { |i| i.op == 'ENTER' }
    mand = enter ? enter.args.split(':').first.to_i : 0
    r = reg.to_i
    return false unless r >= 1 && r <= mand

    return true if native_arg_types(owner_def, mand)[r - 1] == :fixnum

    # ENTRY_ARG_CALLSITE_PROOF (source 7): every call site passes a Fixnum here
    # (compute_entry_arg_fixnum). nil until that fixpoint runs.
    !@entry_arg_fixnum.nil? && @entry_arg_fixnum.include?([irep.label, r])
  end

  # ---------------------------------------------------------------------------
  # ENTRY_ARG_CALLSITE_PROOF (proof source 7): a mandatory argument register
  # holds a Fixnum on entry because EVERY call site that can reach the method
  # passes a proven Fixnum there (unlike source 2, which is the hand-vetted
  # NATIVE_ARG_TARGETS retyping).
  #
  # The enumeration must be exhaustive: a wrong operand proof emits an unchecked
  # mrb_fixnum(), i.e. silent UB. Why it can be:
  #   - No Ruby runs that the compiler cannot see: mrb_load_string/file/irep/
  #     nstring are not called by mruby-rgss/rpg2k/lcf native code, so all Ruby
  #     is closed-world mrblib (parsed here) or foreign mrblib (poisoned).
  #   - The closed world has no send/__send__/public_send/method(:x)/
  #     define_method/*_eval; alias_method and `&:sym` materialize as LOADSYM,
  #     which poisons anyway.
  # So a call into M under name N can only be:
  #   (a) a bytecode SEND-family instruction naming `:N` -- enumerated;
  #   (b) symbol-mediated dispatch -- `:N` in a non-call opcode poisons N;
  #   (c) native C++ or foreign mrblib -- poisons N if the token appears in
  #       NATIVE_SRCS or FOREIGN_RUBY_SRCS at all (outside_world_tokens);
  #   (d) `super` into M -- impossible, N must be MONO (native definitions add a
  #       second registry entry);
  #   (e) `X.new` reaching #initialize -- no SEND :initialize exists, so
  #       `initialize` is refused by name and at least one real site is
  #       required;
  #   (f) method_missing -- only fires when no method is found.
  # The opcodes that can carry a `:name` operand were inventoried:
  # SEND/SEND0/SENDB/SSEND/SSEND0/SSENDB, DEF/SDEF/TDEF, LOADSYM, KARG/KEY_P,
  # CLASS/MODULE, and ARGARY/BLKPUSH/ENTER/GETMCNST (numeric fields or `::`).
  # Only the four positional call opcodes are sites; the rest poison. Any other
  # opcode naming something raises (ENTRY_ARG_CLASSIFIED_OPS), fail-loud.
  #
  # ADMISSION: (method M named N, argument position k) is admitted only when:
  #   1. @registry[N] has exactly one MethodDef, with a bytecode body.
  #   2. N is not in foreign_method_names.
  #   3. N is not in outside_tokens.
  #   4. N starts with a letter or underscore (operator names cannot be
  #      tokenized for rule 3).
  #   5. N is not `initialize`.
  #   6. pure_mandatory_arity? on M, and 1 <= k <= mand.
  #   7. N is not poisoned: no LOADSYM :N, no other DEF/SDEF/TDEF :N, no
  #      SEND0/SSEND0 :N (a zero-argument call to a mand >= 1 method means this
  #      model is wrong), no `:N` in any other opcode.
  #   8. At least one site exists, and every site is SEND/SENDB/SSEND/SSENDB
  #      with a literal `n=` equal to mand (`n=*` refuses), in an irep
  #      attributable to a known method body.
  #   9. At every site, argument k's register R[a+k] (OP_SEND's
  #      regs[a+1..a+n]) is proven_fixnum_operand?.
  #
  # Greatest fixpoint: start from every (M, k) passing 1-8 and drop pairs whose
  # sites stop proving. This admits recursion (`def f(n); n <= 0 ? 0 : f(n -
  # 1); end`). Soundness is by induction over the events of one real run in
  # time order ("invocation of M begins" / "invocation of P returns"): an entry
  # event's argument was proven from unconditional sources, from the caller's
  # own entry arguments (an earlier event), or from a FIXNUM_RETURN_PROOF'd
  # call's return (an earlier event); a return event likewise. So this proof and
  # FIXNUM_RETURN_PROOF can alternate to convergence, each trusting the other's
  # current set. A non-terminating cycle produces no events (it raises
  # SystemStackError), so it is vacuous.
  #
  # Not done on purpose:
  #   - Block parameters: filled by whatever the callee yields (each, times, a
  #     native mrb_yield), a different enumeration problem.
  #   - Trusting `# bc2cpp: (fixnum, ...)` alone: other consumers re-check at
  #     runtime (mrb_integer_p guards, the NATIVE_ARG_TARGETS FFI TypeError);
  #     this proof has no check by design, so a wrong comment would be silent
  #     UB. Use NATIVE_ARG_TARGETS after its per-entry review instead.
  # ---------------------------------------------------------------------------

  # Bound on the ENTRY_ARG_CALLSITE_PROOF <-> FIXNUM_RETURN_PROOF alternation.
  # Both sets grow monotonically; stopping early only proves less.
  ENTRY_ARG_ALTERNATION_LIMIT = 4

  # Call opcodes an enumerable site may use. SEND0/SSEND0 pass no arguments, so
  # one aimed at a mand >= 1 method means the model is wrong; they poison.
  ENTRY_ARG_CALL_OPS = Set['SEND', 'SENDB', 'SSEND', 'SSENDB'].freeze

  # Opcodes that DEFINE a method (`DEF R1 :name (R2)`, SDEF, TDEF). Neutral, not
  # poison: a definition is not a call path, and a second definition already
  # fails rule 1. Treating them as poison would make every method poison itself.
  ENTRY_ARG_DEF_OPS = Set['DEF', 'SDEF', 'TDEF'].freeze

  # Every opcode verified (from the real instruction stream) to carry a `:token`
  # operand. Any other one that does raises.
  ENTRY_ARG_CLASSIFIED_OPS = Set[
    'SEND', 'SEND0', 'SENDB', 'SSEND', 'SSEND0', 'SSENDB',
    'DEF', 'SDEF', 'TDEF', 'LOADSYM', 'KARG', 'KEY_P', 'CLASS', 'MODULE',
    'ARGARY', 'BLKPUSH', 'ENTER', 'GETMCNST'
  ].freeze

  # Same method-name charset as every SEND-name extraction.
  ENTRY_ARG_NAME_RE = %r{:([\w+\-*/<>=!?\[\]&|^~%@]+)}

  # codedump.c appends "\t; R<n>:<local>" (or "\t; <literal>") comments; a local
  # named `tile` must not count as the method `tile`. Operands end at the first
  # "\t;".
  def entry_arg_operands(insn)
    insn.args.to_s.split(/\t;/, 2).first.to_s
  end

  # irep label -> the MethodDef whose body it is, following `reps` into nested
  # blocks/lambdas (a call site in a block is proven against the enclosing
  # method, as compile_insn does for BLOCK_FALLBACK). An uncovered label (root,
  # class body) poisons its call sites.
  def entry_arg_body_owner
    @entry_arg_body_owner ||= begin
      map = {}
      @registry.each_value do |defs|
        defs.each do |d|
          next unless d.irep

          stack = [d.irep]
          until stack.empty?
            label = stack.pop
            next if map.key?(label)

            map[label] = d
            child = @ireps[label]
            (child&.reps || []).each { |c| stack << c }
          end
        end
      end
      map
    end
  end

  # One pass over every irep, splitting each `:name` mention into a call site or
  # a poison. Memoized (@ireps/@registry are fixed).
  def entry_arg_call_index
    @entry_arg_call_index ||= begin
      sites = Hash.new { |h, k| h[k] = [] }
      poisoned = Set.new
      owner_of_body = entry_arg_body_owner
      @ireps.each_value do |irep|
        owner = owner_of_body[irep.label]
        irep.instructions.each_with_index do |insn, i|
          operands = entry_arg_operands(insn)
          name = operands[ENTRY_ARG_NAME_RE, 1]
          next unless name

          unless ENTRY_ARG_CLASSIFIED_OPS.include?(insn.op)
            raise "ENTRY_ARG_CALLSITE_PROOF: opcode #{insn.op} names :#{name} " \
                  "(#{operands.inspect}) but is not classified -- refusing to " \
                  'guess whether that is a call site'
          end

          # A def naming itself is neither a site nor poison (ENTRY_ARG_DEF_OPS).
          next if ENTRY_ARG_DEF_OPS.include?(insn.op)

          unless ENTRY_ARG_CALL_OPS.include?(insn.op) && owner
            poisoned << name
            next
          end

          recv = operands[/\AR(\d+)/, 1]
          argc = operands[/\bn=(\d+)\b/, 1]
          # `n=*` (packed arguments): argument k has no register, so it poisons.
          if recv.nil? || argc.nil?
            poisoned << name
            next
          end

          sites[name] << [irep, i, recv.to_i, argc.to_i, owner]
        end
      end
      [sites, poisoned]
    end
  end

  # ENTRY_ARG_CALLSITE_PROOF greatest fixpoint (see the header). Returns a Set
  # of [irep label, mandatory argument register].
  def compute_entry_arg_fixnum
    @entry_arg_fixnum = Set.new
    # A missing scan is a missing poison source: prove nothing.
    return @entry_arg_fixnum unless @foreign_method_names && @outside_tokens

    sites, poisoned = entry_arg_call_index
    cand = {}
    @registry.each do |name, defs|
      next unless defs.size == 1                       # rule 1
      next if @foreign_method_names.include?(name)     # rule 2
      next if @outside_tokens.include?(name)           # rule 3
      next unless name =~ /\A[A-Za-z_]/                # rule 4
      next if name == 'initialize'                     # rule 5
      next if poisoned.include?(name)                  # rule 7

      d = defs.first
      next unless d.irep

      irep = @ireps[d.irep]
      next unless irep && pure_mandatory_arity?(irep)  # rule 6

      mand = mandatory_arity(irep)
      next if mand.zero?

      here = sites[name]
      next if here.empty?                              # rule 8
      next unless here.all? { |(_ir, _i, _a, argc, _own)| argc == mand }

      (1..mand).each { |k| cand[[d.irep, k]] = [here, k] }
    end

    @entry_arg_fixnum = Set.new(cand.keys)
    loop do
      dropped = cand.keys.select do |key|
        @entry_arg_fixnum.include?(key) && !entry_arg_sites_proven?(*cand[key])
      end
      break if dropped.empty?

      dropped.each { |key| @entry_arg_fixnum.delete(key) }
    end
    @entry_arg_fixnum
  end

  # Admission rule 9: R[a+k] at every site proves (OP_SEND regs[a+1..a+n]).
  def entry_arg_sites_proven?(sites, k)
    sites.all? do |(irep, idx, recv, _argc, owner)|
      proven_fixnum_operand?(irep, idx, (recv + k).to_s, owner)
    end
  end

  # ENTRY_ARG_CALLSITE_PROOF's own result, for the whole-program diagnostic.
  def entry_arg_fixnum_facts
    @entry_arg_fixnum || Set.new
  end

  # ---------------------------------------------------------------------------
  # FIXNUM_RETURN_PROOF (proof source 6): bare method names whose
  # SEND/SEND0/SSEND/SSEND0 provably leaves a Fixnum in the destination.
  #
  # Admission, all required:
  #   1. @registry[N] has exactly one MethodDef, with a bytecode body (the MONO
  #      test; a native definition adds a second, irep-nil entry).
  #   2. N is not in foreign_method_names: stricter than MONO on purpose, since
  #      a wrong proof is an unchecked mrb_fixnum() (UB), not a wrong call.
  #   3. The body is return-analyzable (fixnum_return_analyzable?): no catch
  #      handlers, no child ireps, at least one RETURN.
  #   4. Every return site proves (fixnum_return_sites_proven?) against the
  #      callee's own irep and MethodDef.
  #
  # Only SEND/SEND0/SSEND/SSEND0, never SENDB/SSENDB: a `break` in the caller's
  # block makes the BREAK operand the send's result (ops.h OP_BREAK), whatever
  # the callee returns. The four admitted opcodes cannot carry a block.
  #
  # Greatest fixpoint: start from names passing 1-3 and drop names whose return
  # sites stop proving, which admits self and mutual recursion. Induction over
  # the dynamic call tree of one completed call: the returned register came from
  # a Fixnum source or from a call to an admitted name that returned earlier in
  # the same tree. A cycle that never returns raises SystemStackError, so it is
  # vacuous.
  #
  # Only `RETURN R[a]` is accepted. RETURN_BLK, BREAK, RETSELF, RETNIL, RETTRUE,
  # RETFALSE (and STOP) refuse, and every RETURN in the body is checked.
  # ---------------------------------------------------------------------------
  def compute_fixnum_return_names
    @fixnum_return_names = Set.new
    # No foreign scan means poison source 2 is missing: prove nothing.
    return @fixnum_return_names unless @foreign_method_names

    cand = {}
    accessors = Set.new
    @registry.each do |name, defs|
      next unless defs.size == 1

      d = defs.first
      next if @foreign_method_names.include?(name)

      # ADMISSION VARIANT B: a MONO attr_reader/attr_accessor whose ivar is embedded
      # as :fixnum (no irep; proof source 3 moved to the callee's return).
      # drop_unsafe_embeddings keeps such an ivar embedded only when
      # ATTR_STRUCT_DEVIRT replaces the native accessor program-wide with
      # emit_ivar_accessor_pair's getter, `return
      # mrb_fixnum_value(((Owner_ivars*)DATA_PTR(self))->name);` over an mrb_int
      # field; the same gate guarantees the struct is allocated and every write went
      # through SETIV's mrb_integer_p guard. The name is MONO, so another receiver
      # raises NoMethodError. Not iterated: a field read depends on no other return
      # type.
      if d.irep.nil?
        accessors << name if d.kind == :ivar_accessor && embed_type(d.owner, name) == :fixnum
        next
      end

      irep = @ireps[d.irep]
      next unless irep && fixnum_return_analyzable?(irep)

      cand[name] = d
    end

    # Greatest fixpoint from every candidate. Variant B accessors are seeded and
    # never re-examined, but are visible to the bytecode candidates' proofs (a
    # method returning `other.code`).
    @fixnum_return_names = Set.new(cand.keys) | accessors
    loop do
      dropped = cand.keys.select do |n|
        @fixnum_return_names.include?(n) && !fixnum_return_sites_proven?(cand[n])
      end
      break if dropped.empty?

      dropped.each { |n| @fixnum_return_names.delete(n) }
    end
    @fixnum_return_names
  end

  # Structural preconditions for reading a body's return sites.
  # Catch handlers refuse: a rescue arm is an extra return path (and its range
  # is extracted into a separate function).
  # Child ireps are allowed (fixnum_proof_ctx already refuses registers a nested
  # SETUPVAR writes), but a descendant RETURN_BLK is a return from THIS method
  # not in this instruction list (`ary.each { return "x" }`), so it refuses.
  # BREAK refuses too, conservatively: it only affects a block-carrying send's
  # result, and SENDB/SSENDB are not proof sources anyway.
  def fixnum_return_analyzable?(irep)
    return false unless (irep.catch_handlers || []).empty?
    return false if subtree_has_nonlocal_exit?(irep)

    irep.instructions.any? { |i| i.op == 'RETURN' }
  end

  # Does any nested block/lambda under `irep` contain a non-local exit? All
  # depths, `seen`-guarded.
  def subtree_has_nonlocal_exit?(irep, seen = Set.new)
    (irep.reps || []).any? do |label|
      next false if seen.include?(label)

      seen << label
      child = @ireps[label]
      next false unless child

      child.instructions.any? { |i| i.op == 'RETURN_BLK' || i.op == 'BREAK' } ||
        subtree_has_nonlocal_exit?(child, seen)
    end
  end

  # Every return path of the body holds a Fixnum (see
  # compute_fixnum_return_names for the opcode split).
  def fixnum_return_sites_proven?(d)
    irep = @ireps[d.irep]
    return false unless irep

    irep.instructions.each_with_index do |insn, idx|
      case insn.op
      when 'RETURN'
        # `"RETURN\tR%d"` -- the returned register is the first operand.
        reg = insn.args[/\AR(\d+)/, 1]
        return false unless reg
        return false unless proven_fixnum_operand?(irep, idx, reg, d)
      when 'RETURN_BLK', 'BREAK', 'RETSELF', 'RETNIL', 'RETTRUE', 'RETFALSE', 'STOP'
        return false
      end
    end
    true
  end

  # ---------------------------------------------------------------------------
  # ARRAY_RETURN_PROOF: names whose SEND/SEND0/SSEND/SSEND0 provably leaves an
  # Array in the destination. Same admission rules, greatest fixpoint and
  # soundness argument as compute_fixnum_return_names, with the return-site
  # predicate "holds an Array" (proven_array_operand?):
  #   1. exactly one MethodDef, with a bytecode body;
  #   2. not in foreign_method_names (this refuses values/sort/first/... from
  #      3rd/mruby/mrblib);
  #   3. array_return_analyzable? (= fixnum_return_analyzable?);
  #   4. every `RETURN R[a]` proves; any other exit opcode refuses.
  # Rules 1+2 mean the name has one body in the whole program, so no receiver
  # can reach another definition, and one that lacks the method raises before
  # returning (as for CORE_ARRAY_RETURN_METHODS).
  # Trust level: the predicate is exactly what the loop recognizers apply to
  # their own receiver, including trace_new_target's ClassLayout-hint terminal
  # (a whole-program agreement fact), and every consumer is a loop emitter with
  # an mrb_array_p raise-tripwire, so a wrong fact raises TypeError, never UB.
  # No compiles_clean? requirement (see annotated_array_return).
  # ---------------------------------------------------------------------------
  def compute_array_return_names
    @array_return_names = Set.new
    # No foreign scan means rule 2 is missing: prove nothing.
    return @array_return_names unless @foreign_method_names

    cand = {}
    @registry.each do |name, defs|
      next unless defs.size == 1

      d = defs.first
      next if @foreign_method_names.include?(name)
      # attr_* defs (no irep) are refused: unlike FIXNUM_RETURN_PROOF variant B,
      # an Array ivar is never embedded, so there is nothing to fall back on.
      next unless d.irep

      irep = @ireps[d.irep]
      next unless irep && array_return_analyzable?(irep)

      cand[name] = d
    end

    @array_return_names = Set.new(cand.keys)
    loop do
      dropped = cand.keys.select do |n|
        @array_return_names.include?(n) && !array_return_sites_proven?(cand[n])
      end
      break if dropped.empty?

      dropped.each { |n| @array_return_names.delete(n) }
    end
    @array_return_names
  end

  # ARRAY_RETURN_PROOF result, for the diagnostic.
  def array_return_names
    @array_return_names || Set.new
  end

  # fixnum_return_analyzable?'s rule, reused (the question is type-independent).
  def array_return_analyzable?(irep)
    return false unless (irep.catch_handlers || []).empty?
    return false if subtree_has_nonlocal_exit?(irep)

    irep.instructions.any? { |i| i.op == 'RETURN' }
  end

  # Every return path holds an Array; same opcode split as
  # fixnum_return_sites_proven?.
  def array_return_sites_proven?(d)
    irep = @ireps[d.irep]
    return false unless irep

    # The same context compile_method builds for the loop recognizers, so the
    # question is identical, asked of the callee's body.
    ivar_classes = @class_layout[d.owner]
    arg_classes = @class_annotations[irep.label]&.args
    mand = mandatory_arity(irep)
    dominated = ->(w_idx, use_idx, r) { return_write_dominates?(irep, w_idx, use_idx, r) }

    irep.instructions.each_with_index do |insn, idx|
      case insn.op
      when 'RETURN'
        # `"RETURN\tR%d"` -- the returned register is the first operand.
        reg = insn.args[/\AR(\d+)/, 1]
        return false unless reg
        return false unless straightline_return_reg?(irep, idx, reg)
        return false unless proven_array_operand?(irep, idx, reg, d.owner, mand, ivar_classes, arg_classes,
                                                  dominated: dominated)
      when 'RETURN_BLK', 'BREAK', 'RETSELF', 'RETNIL', 'RETTRUE', 'RETFALSE', 'STOP'
        return false
      end
    end
    true
  end

  # RETCLASS_SELF_CALL_SUPPORT (ADR 0194): "every return path of this MONO method
  # holds an instance of exactly THIS class", so an implicit self-call can feed
  # ClassLayout.analyze's SETIV arm like `@x = Klass.new`. Same MONO admission as
  # ARRAY_RETURN_PROOF. RETCLASS_NILABLE_JOIN widens it to agreeing POLY names.
  # Unlike ARRAY_RETURN_PROOF the target class varies and one name's proof can
  # depend on another's, so this GROWS from empty (a name is added once every
  # return site traces to the same class), like ClassLayout's sweep. Terminates:
  # the set only grows.
  # RETCLASS_NILABLE_JOIN (ADR 0199): the fact is "K or nil", the contract every
  # ClassLayout hint already has (NIL_TOLERANT_JOIN), so a nil source is no evidence.
  def class_return_sites_proven(d, ret_class_proof)
    irep = @ireps[d.irep]
    return nil unless irep

    ivar_classes = @class_layout[d.owner]
    arg_classes = @class_annotations[irep.label]&.args
    mand = mandatory_arity(irep)

    proven = nil
    irep.instructions.each_with_index do |insn, idx|
      case insn.op
      # RETURN_BLK in a method body is a plain return (methods are strict procs).
      when 'RETURN', 'RETURN_BLK'
        reg = insn.args[/\AR(\d+)/, 1]
        return nil unless reg

        sources = return_value_sources(irep, idx, reg)
        return nil unless sources

        sources.each do |src|
          next if src == :nil

          writer, r = src
          # The writer itself is a reaching definition already; every deeper
          # hop (a `.new`/`.dup`/accessor receiver) must dominate (ADR 0198).
          dominated = lambda do |w_idx, use_idx, hop_reg|
            (w_idx == writer && use_idx == writer + 1) || return_write_dominates?(irep, w_idx, use_idx, hop_reg)
          end
          klass = trace_new_target(irep, writer + 1, r, ivar_classes, mand, arg_classes, owner: d.owner,
                                    class_layout: @class_layout, registry: @registry,
                                    container_constants: @container_constants,
                                    ret_class_proof: ret_class_proof, dominated: dominated)
          return nil unless klass
          return nil if proven && proven != klass

          proven = klass
        end
      when 'RETNIL'
        next
      when 'BREAK', 'RETSELF', 'RETTRUE', 'RETFALSE', 'STOP'
        return nil
      end
    end
    proven
  end

  # A Ruby callee's frame starts at R(a), so it may overwrite every register above a.
  RETURN_SOURCE_CALLS = Set['SEND', 'SEND0', 'SENDB', 'SSEND', 'SSEND0', 'SSENDB', 'SUPER', 'EXEC'].freeze

  # RETCLASS_NILABLE_JOIN: the definitions of `reg` reaching `idx` (`:nil` or
  # `[writer_idx, reg]`), or nil if a path is unaccounted for. JOIN_REACHING_DEFS'
  # walk and barriers with ADR 0198's level-aware block-write barrier, minus the
  # protected range (a codegen concern, not a value one).
  def return_value_sources(irep, idx, reg)
    preds = fixnum_proof_preds(irep)
    return nil unless preds

    ctx = fixnum_proof_ctx(irep)
    block_written = own_upvar_written_regs(irep)
    out = []
    seen = Set.new
    work = [[idx, reg.to_s]]
    until work.empty?
      state = work.pop
      next unless seen.add?(state)
      return nil if seen.size > FIXNUM_PROOF_REACHING_MAX_STATES

      i, r = state
      return nil if block_written.include?(r)
      return nil if ctx[:catch_targets].include?(irep.instructions[i].addr)

      ps = preds[i]
      return nil if ps.nil? || ps.empty?

      ps.each do |p|
        return nil if p.negative?

        insn = irep.instructions[p]
        # vm.c only falls through a `RAISEIF Ra` when regs[a] is nil.
        if insn.op == 'RAISEIF'
          if insn.args[/\AR(\d+)/, 1] == r
            out << :nil
          else
            work << [p, r]
          end
          next
        end
        return nil unless FIXNUM_PROOF_STEP_OVER_OPS.include?(insn.op) || insn.op.start_with?('LOADI')
        return nil if RETURN_SOURCE_CALLS.include?(insn.op) && insn.args[/\AR(\d+)/, 1].to_i < r.to_i

        if !fixnum_proof_writes_reg?(insn, r)
          work << [p, r]
        elsif insn.op == 'MOVE'
          src = insn.args.scan(/R(\d+)/).flatten[1]
          return nil unless src

          work << [p, src]
        elsif insn.op == 'LOADNIL'
          out << :nil
        else
          out << [p, r]
        end
      end
    end
    out
  end

  # array_return_analyzable?, but a rescue handler is allowed: its entry is a
  # barrier return_value_sources never crosses. `ensure` stays refused.
  def class_return_analyzable?(irep)
    return false unless (irep.catch_handlers || []).all? { |h| h.type == :rescue }
    return false if subtree_has_nonlocal_exit?(irep)

    irep.instructions.any? { |i| i.op == 'RETURN' || i.op == 'RETURN_BLK' }
  end

  # Sends that can give a name a body (or remove one) the registry does not list.
  NAME_INSTALLER_SENDS = %w[alias_method define_method undef_method remove_method].freeze

  # Names the closed world aliases, defines by Symbol or undefines; nil when some
  # such call's names are not literal (or the installer itself is a Symbol).
  def symbol_installed_names
    return @symbol_installed_names if defined?(@symbol_installed_names)

    names = Set.new
    @ireps.each_value do |irep|
      irep.instructions.each_with_index do |insn, idx|
        operands = entry_arg_operands(insn)
        case insn.op
        when 'ALIAS', 'UNDEF'
          operands.scan(ENTRY_ARG_NAME_RE) { |m| names << m[0] }
        when 'LOADSYM'
          return @symbol_installed_names = nil if NAME_INSTALLER_SENDS.include?(operands[ENTRY_ARG_NAME_RE, 1])
        when 'SEND', 'SEND0', 'SENDB', 'SSEND', 'SSEND0', 'SSENDB'
          m = operands.match(/\AR(\d+)\s+:(\S+?)(?:\s+n=(\S+))?\s*\z/)
          next unless m && NAME_INSTALLER_SENDS.include?(m[2])

          syms = m[3]&.match?(/\A\d+\z/) && literal_symbol_args(irep, idx, m[1].to_i, m[3].to_i)
          return @symbol_installed_names = nil unless syms && !syms.empty?

          names.merge(syms)
        end
      end
    end
    @symbol_installed_names = names
  end

  # A self-call from `owner` never reaches method_missing when `owner`'s own
  # superclass chain defines `name`; anything found earlier is a registry def too.
  def self_call_reaches_def?(name, owner)
    def_owners = @registry.fetch(name, []).map(&:owner)
    seen = Set.new
    o = owner
    while o.is_a?(String) && seen.add?(o)
      return true if def_owners.include?(o)

      o = @superclass_of[o]
    end
    false
  end

  # The fact ClassLayout.analyze consumes at a self-call SETIV site.
  def class_return_for_self_call(name, owner)
    klass = class_return_names[name]
    klass if klass && self_call_reaches_def?(name, owner)
  end

  # RETCLASS_SELF_CALL_SUPPORT fixpoint. Every registry def of the name needs a
  # bytecode body (no native/attr_*); a POLY name is admitted when all of its
  # defs prove the same class, since a self-call may reach any.
  def compute_class_return_names
    @class_return_names = {}
    return @class_return_names unless @foreign_method_names

    installed = symbol_installed_names
    return @class_return_names unless installed

    cand = {}
    @registry.each do |name, defs|
      next if @foreign_method_names.include?(name)
      next if installed.include?(name)
      next unless defs.all? { |d| d.irep && @ireps[d.irep] && class_return_analyzable?(@ireps[d.irep]) }

      cand[name] = defs
    end

    proven = {}
    ret_class_proof = lambda do |n, owner|
      proven[n] if self_call_reaches_def?(n, owner)
    end
    loop do
      changed = false
      cand.each do |name, defs|
        next if proven.key?(name)

        classes = defs.map { |d| class_return_sites_proven(d, ret_class_proof) }
        klass = classes.first
        next unless klass && classes.all? { |c| c == klass }

        proven[name] = klass
        changed = true
      end
      break unless changed
    end
    @class_return_names = proven
  end

  # RETCLASS_SELF_CALL_SUPPORT result, for the diagnostic and ClassLayout's
  # driver call.
  def class_return_names
    @class_return_names || {}
  end

  # ARRAY_RETURN_PROOF's control-flow guard (ADR 0198). The backward scans walk
  # the instruction array linearly and see only the textually preceding writer,
  # not the other predecessors of a join. At a receiver site that is backed by
  # the mrb_array_p tripwire; for a claim about EVERY return path it is unsound:
  # `def extensions; @extensions || EXTENSIONS; end` would be proved from the
  # GETCONST arm alone.
  # Rule: walking back from the RETURN (following MOVEs), every write must
  # dominate the instruction that reads it (return_write_dominates?), and the
  # same test is passed to trace_new_target as `dominated:` for its deeper hops.
  # "Only one writer" is not enough: method entry is an invisible second
  # definition, so `x = Foo.new if c; bar; x` must be refused. Falling off the
  # front is refused.
  def straightline_return_reg?(irep, idx, reg)
    r = reg
    use = idx
    (idx - 1).downto(0) do |i|
      pin = irep.instructions[i]
      next if READ_ONLY_OPCODE_SKIP.include?(pin.op) || pin.args[/^R(\d+)/, 1] != r
      # proven_array_source_scan steps over BLOCK, so it must not end this walk.
      return false if pin.op == 'BLOCK'
      return false unless return_write_dominates?(irep, i, use, r)
      return true unless pin.op == 'MOVE'

      r = pin.args.scan(/R(\d+)/).flatten[1]
      return false unless r

      use = i
    end
    false
  end

  # Does the write of `reg` at `w_idx` (-1: method entry) reach `use_idx` on
  # every path? FIXNUM_OPERAND_PROOF's own region test, over its audited
  # step-over whitelist (a hidden writer such as RESCUE/APOST refuses).
  def return_write_dominates?(irep, w_idx, use_idx, reg)
    ctx = fixnum_proof_ctx(irep)
    return false if own_upvar_written_regs(irep).include?(reg)

    stepped = ((w_idx + 1)...use_idx).all? do |k|
      op = irep.instructions[k].op
      FIXNUM_PROOF_STEP_OVER_OPS.include?(op) || op.start_with?('LOADI')
    end
    stepped && fixnum_proof_region_ok?(irep, ctx, w_idx, use_idx)
  end

  # Registers of `irep` ITSELF that a nested block writes: unlike
  # subtree_upvar_written_regs, a SETUPVAR `depth` blocks down counts only
  # when its level is `depth - 1` (vm.c's `uvenv` walks that many uppers).
  def own_upvar_written_regs(irep)
    @own_upvar_written_regs ||= {}
    @own_upvar_written_regs[irep.label] ||= collect_own_upvar_writes(irep, 1, Set.new)
  end

  def collect_own_upvar_writes(irep, depth, acc)
    (irep.reps || []).each do |label|
      child = @ireps[label]
      next unless child

      child.instructions.each do |insn|
        next unless insn.op == 'SETUPVAR'

        _src, b, lv = insn.args.split(/\s+/)
        # An unparsable level is kept: over-collecting only costs a proof.
        acc << b if b =~ /\A\d+\z/ && !(lv =~ /\A\d+\z/ && lv.to_i != depth - 1)
      end
      collect_own_upvar_writes(child, depth + 1, acc)
    end
    acc
  end

  # "Is `reg` at `idx` provably an Array?": recognize_each_regions' two-step
  # receiver gate, shared so the two cannot drift.
  def proven_array_operand?(irep, idx, reg, owner_name, mand, ivar_classes, arg_classes, dominated: nil)
    traced = trace_new_target(irep, idx, reg, ivar_classes, mand, arg_classes, owner: owner_name,
                               class_layout: @class_layout, registry: @registry,
                               container_constants: @container_constants, dominated: dominated)
    return true if traced == 'Array'

    !proven_array_source(irep, idx, reg).nil?
  end

  # BLOCK_BODY_INDEX_SUPPORT: map a register number compile_insn extracted back
  # to `irep`'s own numbering. Identity (offset 0) for method bodies, rescue try
  # bodies and BLOCK/LAMBDA_FALLBACK bodies. compile_block_body_insn splices an
  # inlined block into the enclosing function and shifts its `R<n>` to
  # `R<n + offset>` to keep the frames' `r<n>` disjoint; the proofs read
  # block_irep.instructions, so they must be asked about `n`. Every register in
  # the instruction is shifted, so a negative result means a malformed
  # extraction and returns nil (not provable).
  def unshift_proof_reg(reg, reg_offset)
    return reg if reg_offset.zero?
    return nil if reg.nil?

    n = reg.to_i - reg_offset
    n.negative? ? nil : n.to_s
  end

  # Both operand registers of one binary opcode, proven at the same point.
  def proven_fixnum_pair?(irep, idx, dreg, sreg, owner_def)
    return false unless dreg && sreg

    proven_fixnum_operand?(irep, idx, dreg, owner_def) &&
      proven_fixnum_operand?(irep, idx, sreg, owner_def)
  end

  # Emitted above a devirtualized arithmetic/comparison op, like the embedded
  # ivar `// @x embedded` marker, so the generated body says why it has no
  # fallback.
  FIXNUM_PROOF_NOTE = "  // operands proven Fixnum -- no runtime check, no mrb_funcall fallback\n"

  # MAP_BLOCK_SUPPORT: inline map/select/reject/find/filter_map (1-arg blocks),
  # each_with_index (2-arg) and flat_map. Same BLOCK + `SENDB/SSENDB Ra :name
  # n=0` adjacency and Array gate as recognize_each_regions. Only block arities
  # matching the method are admitted (a mismatch would raise when interpreted),
  # so the rest keep `#error`. Per-method semantics are in emit_collect_inline.
  # filter_map is Enumerable#filter_map (mruby-enum-ext/mrblib/enum.rb, a
  # dependency of the build):
  #
  #   def filter_map(&blk)
  #     return to_enum(:filter_map) unless blk
  #     ary = []
  #     self.each do |*x|
  #       x = blk.call(*x)
  #       ary.push x if x
  #     end
  #     ary
  #   end
  #
  # For an Array receiver the block gets one element; the block's RESULT is
  # pushed when truthy. Not redefined anywhere here.
  COLLECT_BLOCK_METHODS = %w[map select reject find each_with_index flat_map filter_map].freeze

  # ACCUM_BLOCK_SUPPORT: inline any?/all?/none?/count (1-arg blocks) and
  # reduce/inject(init) (2-arg blocks, n=1). Semantics (emit_accum_inline):
  #   - any?: false default, first truthy result exits with true;
  #   - all?: true default, first falsy result exits with false;
  #   - none?: true default, first truthy result exits with false;
  #   - count: tally of truthy results;
  #   - reduce/inject(init): init is in R(dest+1) (checked by register), the
  #     accumulator goes through the block's two params.
  # No-init `reduce` (n=0) stays out (empty-array/seeding semantics). Arity
  # mismatches keep `#error`.
  ACCUM_BLOCK_METHODS = %w[any? all? none? count].freeze
  ACCUM_FOLD_METHODS = %w[reduce inject].freeze

  def recognize_accum_regions(irep, owner_name, mand, ivar_classes, arg_classes)
    regions = []
    irep.instructions.each_with_index do |insn, idx|
      next unless %w[SENDB SSENDB].include?(insn.op) && idx.positive?

      dest, name, nstr = insn.args.split(/\s+/, 3)
      meth = name&.sub(/\A:/, '')
      n = nstr.to_s[/n=(\d+)/, 1]&.to_i
      is_pred = n == 0 && ACCUM_BLOCK_METHODS.include?(meth)
      is_fold = n == 1 && ACCUM_FOLD_METHODS.include?(meth)
      next unless is_pred || is_fold

      block_insn = irep.instructions[idx - 1]
      next unless block_insn && block_insn.op == 'BLOCK'

      dest_reg = dest[/^R(\d+)/, 1]
      block_reg = block_insn.args[/^R(\d+)/, 1]
      if is_fold
        # `reduce(init)`: dest, init, block, so BLOCK is at dest+2 (`BLOCK R4` +
        # `SENDB R2 :reduce n=1`).
        next unless dest_reg && block_reg && block_reg == (dest_reg.to_i + 2).to_s
      else
        next unless dest_reg && block_reg && block_reg == (dest_reg.to_i + 1).to_s
      end

      block_irep_idx = block_insn.args[/I\[(\d+)\]/, 1]
      next unless block_irep_idx

      block_label = irep.reps[block_irep_idx.to_i]
      block_irep = block_label && @ireps[block_label]
      want_arity = is_fold ? 2 : 1
      next unless block_irep && mandatory_arity(block_irep) == want_arity && pure_mandatory_arity?(block_irep)

      if insn.op == 'SSENDB'
        next unless owner_name == 'Array'
      else
        # CHAINED_ACCESSOR_SUPPORT: passing @class_layout/@registry can only turn nil
        # into 'Array'.
        traced = trace_new_target(irep, idx, dest_reg, ivar_classes, mand, arg_classes, owner: owner_name,
                                   class_layout: @class_layout, registry: @registry,
                                   container_constants: @container_constants)
        traced = proven_array_source(irep, idx, dest_reg) if traced != 'Array'
        next unless traced == 'Array'
      end

      regions << { block_addr: block_insn.addr, sendb_addr: insn.addr, dest_reg: dest_reg, block_irep: block_irep,
                   method_name: meth, init_reg: is_fold ? (dest_reg.to_i + 1).to_s : nil,
                   ssendb: insn.op == 'SSENDB',
                   elem_class: region_element_class(insn, irep, idx, dest_reg, ivar_classes, mand, arg_classes,
                                                   owner_name) }
    end
    regions
  end

  def recognize_collect_regions(irep, owner_name, mand, ivar_classes, arg_classes)
    regions = []
    irep.instructions.each_with_index do |insn, idx|
      next unless %w[SENDB SSENDB].include?(insn.op) && idx.positive?

      dest, name, nstr = insn.args.split(/\s+/, 3)
      meth = name&.sub(/\A:/, '')
      next unless nstr == 'n=0' && COLLECT_BLOCK_METHODS.include?(meth)

      block_insn = irep.instructions[idx - 1]
      next unless block_insn && block_insn.op == 'BLOCK'

      dest_reg = dest[/^R(\d+)/, 1]
      block_reg = block_insn.args[/^R(\d+)/, 1]
      next unless dest_reg && block_reg && block_reg == (dest_reg.to_i + 1).to_s

      block_irep_idx = block_insn.args[/I\[(\d+)\]/, 1]
      next unless block_irep_idx

      block_label = irep.reps[block_irep_idx.to_i]
      block_irep = block_label && @ireps[block_label]
      want_arity = meth == 'each_with_index' ? 2 : 1
      next unless block_irep && mandatory_arity(block_irep) == want_arity && pure_mandatory_arity?(block_irep)

      if insn.op == 'SSENDB'
        next unless owner_name == 'Array'
      else
        # CHAINED_ACCESSOR_SUPPORT: passing @class_layout/@registry can only turn nil
        # into 'Array'.
        traced = trace_new_target(irep, idx, dest_reg, ivar_classes, mand, arg_classes, owner: owner_name,
                                   class_layout: @class_layout, registry: @registry,
                                   container_constants: @container_constants)
        traced = proven_array_source(irep, idx, dest_reg) if traced != 'Array'
        next unless traced == 'Array'
      end

      regions << { block_addr: block_insn.addr, sendb_addr: insn.addr, dest_reg: dest_reg, block_irep: block_irep,
                   method_name: meth, ssendb: insn.op == 'SSENDB',
                   elem_class: region_element_class(insn, irep, idx, dest_reg, ivar_classes, mand, arg_classes,
                                                   owner_name) }
    end
    regions
  end

  # EACH_BLOCK_SUPPORT: `ary.reject(&:dead?)` and friends: `LOADSYM R(a+1) :sym`
  # then `SENDB`/`SSENDB Ra :name n=0`, no BLOCK. OP_SENDB turns regs[bidx] into
  # a symbol proc (ensure_block), so there is nothing to inline or capture; each
  # element gets one call (emit_sym_inline). Same Array gate as
  # recognize_each_regions.
  SYM_BLOCK_METHODS = %w[each map select reject find any? all? none? count].freeze

  def recognize_sym_regions(irep, owner_name, mand, ivar_classes, arg_classes)
    regions = []
    irep.instructions.each_with_index do |insn, idx|
      next unless %w[SENDB SSENDB].include?(insn.op) && idx.positive?

      dest, name, nstr = insn.args.split(/\s+/, 3)
      next unless nstr == 'n=0' && SYM_BLOCK_METHODS.include?(name&.sub(/\A:/, ''))

      loadsym_insn = irep.instructions[idx - 1]
      next unless loadsym_insn && loadsym_insn.op == 'LOADSYM'
      # No BLOCK check needed: OP_SENDB takes its block from regs[bidx] (dest+1 for
      # n=0), which the LOADSYM just wrote (register match below).
      # A keyword call also LOADSYMs its key symbols into later registers, but it is
      # always SEND/SSEND, never SENDB/SSENDB, so it cannot form a region here.

      dest_reg = dest[/^R(\d+)/, 1]
      sym_reg = loadsym_insn.args[/^R(\d+)/, 1]
      next unless dest_reg && sym_reg && sym_reg == (dest_reg.to_i + 1).to_s

      sym_name = loadsym_insn.args[/:(\S+)/, 1]&.sub(/\A:/, '')
      next unless sym_name && !sym_name.empty?

      if insn.op == 'SSENDB'
        next unless owner_name == 'Array'
      else
        # CHAINED_ACCESSOR_SUPPORT: passing @class_layout/@registry can only turn nil
        # into 'Array'.
        traced = trace_new_target(irep, idx, dest_reg, ivar_classes, mand, arg_classes, owner: owner_name,
                                   class_layout: @class_layout, registry: @registry,
                                   container_constants: @container_constants)
        traced = proven_array_source(irep, idx, dest_reg) if traced != 'Array'
        next unless traced == 'Array'
      end

      regions << { sym_addr: loadsym_insn.addr, sendb_addr: insn.addr, dest_reg: dest_reg,
                   method_name: name.sub(/\A:/, ''), sym_name: sym_name, ssendb: insn.op == 'SSENDB' }
    end
    regions
  end

  # INTERP_UNLOCK: inline `r.each { |id| ... }` for a receiver tracing to Range
  # (a RANGE_INC/RANGE_EXC literal or `range(cmd)` below). Same adjacency and
  # 1-arg gate as recognize_each_regions. No SSENDB: no game class is a Range.
  def recognize_range_each_regions(irep, owner_name, mand, ivar_classes, arg_classes)
    regions = []
    irep.instructions.each_with_index do |insn, idx|
      next unless insn.op == 'SENDB' && idx.positive?

      dest, name, nstr = insn.args.split(/\s+/, 3)
      next unless name == ':each' && nstr == 'n=0'

      block_insn = irep.instructions[idx - 1]
      next unless block_insn && block_insn.op == 'BLOCK'

      dest_reg = dest[/^R(\d+)/, 1]
      block_reg = block_insn.args[/^R(\d+)/, 1]
      next unless dest_reg && block_reg && block_reg == (dest_reg.to_i + 1).to_s

      block_irep_idx = block_insn.args[/I\[(\d+)\]/, 1]
      next unless block_irep_idx

      block_label = irep.reps[block_irep_idx.to_i]
      block_irep = block_label && @ireps[block_label]
      next unless block_irep && mandatory_arity(block_irep) == 1 && pure_mandatory_arity?(block_irep)

      traced = trace_new_target(irep, idx, dest_reg, ivar_classes, mand, arg_classes, owner: owner_name,
                                 container_constants: @container_constants)
      traced = range_return_call(irep, idx, dest_reg) if traced != 'Range'
      next unless traced == 'Range'

      regions << { block_addr: block_insn.addr, sendb_addr: insn.addr, dest_reg: dest_reg, block_irep: block_irep }
    end
    regions
  end

  # INTERP_UNLOCK: Game::Interpreter#range returns a Range on every path (`a..b`
  # or `1..0`). A single exact Owner#name allowlist (SUPER_TARGETS style), so a
  # `range` method elsewhere never matches and a non-Range change to #range
  # must update this.
  RANGE_RETURN_METHODS = Set['Game::Interpreter#range'].freeze

  def range_return_call(irep, idx, dest_reg)
    (idx - 1).downto(0) do |i|
      pin = irep.instructions[i]
      next unless pin
      next unless pin.args[/^R(\d+)/, 1] == dest_reg
      # Only a `range` call made FROM a Game::Interpreter method counts (checked via
      # the irep's MethodDef owner), not just the name.
      next unless %w[SEND SSEND SEND0 SSEND0].include?(pin.op)

      called = pin.args[/:([\w+\-*\/<>=!?\[\]&|^~%@]+)/, 1]
      return nil unless called == 'range'

      return 'Range' if RANGE_RETURN_METHODS.include?("#{@owner_of.fetch(irep.label).owner}#range")

      return nil
    end
    nil
  end

  # SORT_BLOCK_SUPPORT: inline sort_by (1-arg key), sort (2-arg comparator) and
  # uniq (1-arg key), with the proven_array_source gate. Semantics in
  # emit_sort_inline.
  # Not supported, with no block-form call sites in the closed world:
  #   - sort_by!/uniq!: could replace the receiver via mrb_ary_replace after the
  #     existing passes (as mruby's own sort_by!/uniq! do);
  #   - max/min (2-arg comparator: a single fold, block not called for the first
  #     element) and max_by/min_by (1-arg key, called for every element); ties
  #     keep the first element, empty is nil.
  # Arity mismatches keep `#error`.
  SORT_BLOCK_METHODS = %w[sort sort_by uniq].freeze

  def recognize_sort_regions(irep, owner_name, mand, ivar_classes, arg_classes)
    regions = []
    irep.instructions.each_with_index do |insn, idx|
      next unless %w[SENDB SSENDB].include?(insn.op) && idx.positive?

      dest, name, nstr = insn.args.split(/\s+/, 3)
      meth = name&.sub(/\A:/, '')
      next unless nstr == 'n=0' && SORT_BLOCK_METHODS.include?(meth)

      block_insn = irep.instructions[idx - 1]
      next unless block_insn && block_insn.op == 'BLOCK'

      dest_reg = dest[/^R(\d+)/, 1]
      block_reg = block_insn.args[/^R(\d+)/, 1]
      next unless dest_reg && block_reg && block_reg == (dest_reg.to_i + 1).to_s

      block_irep_idx = block_insn.args[/I\[(\d+)\]/, 1]
      next unless block_irep_idx

      block_label = irep.reps[block_irep_idx.to_i]
      block_irep = block_label && @ireps[block_label]
      want_arity = meth == 'sort' ? 2 : 1
      next unless block_irep && mandatory_arity(block_irep) == want_arity && pure_mandatory_arity?(block_irep)

      if insn.op == 'SSENDB'
        next unless owner_name == 'Array'
      else
        # CHAINED_ACCESSOR_SUPPORT: passing @class_layout/@registry can only turn nil
        # into 'Array'.
        traced = trace_new_target(irep, idx, dest_reg, ivar_classes, mand, arg_classes, owner: owner_name,
                                   class_layout: @class_layout, registry: @registry,
                                   container_constants: @container_constants)
        traced = proven_array_source(irep, idx, dest_reg) if traced != 'Array'
        next unless traced == 'Array'
      end

      regions << { block_addr: block_insn.addr, sendb_addr: insn.addr, dest_reg: dest_reg, block_irep: block_irep,
                   method_name: meth, ssendb: insn.op == 'SSENDB',
                   elem_class: region_element_class(insn, irep, idx, dest_reg, ivar_classes, mand, arg_classes,
                                                   owner_name) }
    end
    regions
  end
  # compile_block_body_insn (below): translate one instruction of an INLINED
  # block body. `offset` is added to every `R<N>` before delegating to
  # compile_insn, keeping the block's registers apart from the method's.
  # BLOCK_BODY_INDEX_SUPPORT: the delegation passes the instruction's real index
  # in block_irep and the shift; unshift_proof_reg undoes the shift wherever a
  # register reaches a proof. Addresses are unchanged. `owner_def` stays the
  # enclosing method's (the block shares its self), and
  # fixnum_proof_entry_arg?'s `owner_def.irep == irep.label` guard keeps the
  # method's NATIVE_ARG_TARGETS types off the block's parameters.
  # Block-specific opcodes:
  #   - RETURN/RETNIL/RETFALSE/RETTRUE: the block's yielded value (`next` is
  #     RETNIL); for #times, a goto to this iteration's end label.
  #   - RETURN_BLK: a real `return`; the block's frame is inlined into the
  #     method's function, so it is a plain C++ return.
  #   - GETUPVAR/SETUPVAR at level 0: the outer scope is this same function, so
  #     `b` names `r<b>` directly, without the offset.
  # INLINE_BLOCK_CAPTURE_HINTS: a block GETUPVAR keeps a Hash<Klass> hint only
  # when the exact SENDB site captures an untouched mandatory Hash<Klass>
  # argument; the generated index and typed call keep their runtime guards and
  # fallbacks.
  def inline_hash_capture_hints(host_irep, region)
    block_irep = region[:block_irep]
    return {} if block_irep.instructions.any? { |insn| %w[SETUPVAR BLOCK SENDB SSENDB].include?(insn.op) }

    call_idx = host_irep.instructions.index { |insn| insn.addr == region[:sendb_addr] }
    return {} unless call_idx

    enter = host_irep.instructions.find { |insn| insn.op == 'ENTER' }
    mandatory = enter ? enter.args.split(':').first.to_i : 0
    elements = @element_annotations[host_irep.label]
    return {} unless elements

    captures = {}
    block_irep.instructions.each do |insn|
      next unless insn.op == 'GETUPVAR'

      dst, upvar, level = insn.args.split(/\s+/)
      next unless level == '0'

      reg = upvar
      (call_idx - 1).downto(0) do |i|
        prior = host_irep.instructions[i]
        next unless prior.args[/^R(\d+)/, 1] == reg

        if prior.op == 'MOVE'
          reg = prior.args.scan(/R(\d+)/).flatten[1]
          break unless reg
        else
          reg = nil
          break
        end
      end
      arg_pos = reg&.to_i
      next unless arg_pos && arg_pos.between?(1, mandatory)
      next unless elements.arg_containers&.[](arg_pos - 1) == 'Hash'

      element_class = elements.arg_elements&.[](arg_pos - 1)
      next unless element_class

      captures[dst[/\d+/].to_i] = { container_class: 'Hash', element_class: element_class }
    end
    captures.empty? ? {} : { block_irep.label => captures }
  end

  def with_block_hash_capture_hints(hints)
    previous = @block_hash_capture_hints
    @block_hash_capture_hints = hints
    yield
  ensure
    @block_hash_capture_hints = previous
  end

  # ELEMENT_CLASS_SUPPORT: publish "this instruction's receiver is the loop
  # element, of class `elem_class`" for exactly one instruction. compile_send
  # consumes the hint on read, so a nested compile (compiles_clean? on another
  # body) never sees it, and the `ensure` clears it regardless. Only
  # explicit-receiver sends qualify (SSEND receivers are self).
  def with_element_hint(block_irep, insn, i, elem_reg, elem_class)
    hint = nil
    if elem_class && elem_reg && %w[SEND SEND0].include?(insn.op) &&
       element_receiver?(block_irep, i, insn.args[/^R(\d+)/, 1], elem_reg)
      hint = elem_class
    end
    prev = @elem_class_hint
    @elem_class_hint = hint
    yield
  ensure
    @elem_class_hint = prev
  end

  # ELEMENT_CLASS_SUPPORT: does `reg` still hold the loop element at `idx`? mrbc
  # MOVEs a parameter into a scratch register before sending (`MOVE R10 R8`,
  # `SEND R10 :dead?`), so follow MOVEs back to the element register with no
  # other write in between; reassigning the parameter stops the scan.
  # Straight-line and control-flow-insensitive, which is only a precision
  # limit: the emitted code checks mrb_obj_class before the direct call.
  def element_receiver?(block_irep, idx, reg, elem_reg)
    return false unless reg

    (idx - 1).downto(0) do |i|
      insn = block_irep.instructions[i]
      next unless insn
      next unless insn.args[/^R(\d+)/, 1] == reg
      return false unless insn.op == 'MOVE'

      src = insn.args.scan(/R(\d+)/).flatten[1]
      return false unless src

      reg = src
    end
    reg == elem_reg
  end

  # INLINE_NESTED_BLOCK_SUPPORT: the shift-then-compile_insn step of
  # compile_block_body_insn's `else` arm, named so the BLOCK/SENDB/SSENDB case
  # can reuse it for an unclaimed nested region (one copy, no drift).
  def compile_shifted_body_insn(insn, block_irep, owner_def, offset, idx)
    shifted_args = insn.args.gsub(/R(\d+)/) { "R#{Regexp.last_match(1).to_i + offset}" }
    shifted = Insn.new(lineno: insn.lineno, addr: insn.addr, op: insn.op, args: shifted_args, raw: insn.raw)
    compile_insn(shifted, block_irep, owner_def, idx, offset)
  end

  def compile_block_body_insn(insn, block_irep, owner_def, offset, iter_end_label, label_prefix,
                                break_dest: nil, break_label: nil, idx: nil)
    case insn.op
    # INLINE_NESTED_BLOCK_SUPPORT: a nested block-carrying call in this inlined
    # body. `@inline_nested` holds the regions inline_nested_block_pass claimed
    # for the body loop running now. A claimed region's BLOCK address carries the
    # whole replacement (RProc construction and dispatch) and its SENDB address
    # nothing, as in compile_method's and emit_proc_fallback_fn's passes.
    # An unclaimed one falls through to compile_insn, which emits `#error`, so the
    # driving emitter gives up and the loop falls back to BLOCK_FALLBACK as
    # before.
    when 'BLOCK', 'SENDB', 'SSENDB'
      glue = @inline_nested&.glue&.[](insn.addr)
      if glue
        glue
      elsif @inline_nested&.skip?(insn.addr)
        # A claimed region's SENDB/SSENDB: already emitted at its BLOCK address.
        ''
      else
        # Unclaimed: the plain shift-then-compile_insn, i.e. `#error`, which makes
        # the driving emitter abandon the region.
        compile_shifted_body_insn(insn, block_irep, owner_def, offset, idx)
      end
    when 'RETURN', 'RETNIL', 'RETFALSE', 'RETTRUE'
      "  goto #{iter_end_label};\n"
    when 'RETURN_BLK'
      r = insn.args.strip.empty? ? '0' : insn.args[/^R(\d+)/, 1]
      "  return r#{r.to_i + offset};\n"
    when 'BREAK'
      # EACH_BLOCK_SUPPORT: `break` (bare breaks carry a LOADNIL'd register) makes
      # the value the whole SEND's result (vm.c OP_BREAK L_UNWINDING). Inlined:
      # assign the SENDB destination and jump past the loop. Only the each/sym
      # emitters pass break_dest/break_label; in #times a break keeps its `#error`.
      if break_dest && break_label
        r = insn.args.strip.empty? ? '0' : insn.args[/^R(\d+)/, 1]
        "  r#{break_dest} = r#{r.to_i + offset};\n  goto #{break_label};\n"
      else
        "  #error unhandled opcode BREAK -- not in this prototype's supported subset\n"
      end
    when 'GETUPVAR'
      dst, upvar_idx, level = insn.args.split(/\s+/)
      if level == '0'
        "  r#{dst[/\d+/].to_i + offset} = r#{upvar_idx};\n"
      else
        "  #error unhandled opcode GETUPVAR -- not in this prototype's supported subset\n"
      end
    when 'SETUPVAR'
      src, upvar_idx, level = insn.args.split(/\s+/)
      if level == '0'
        "  r#{upvar_idx} = r#{src[/\d+/].to_i + offset};\n"
      else
        "  #error unhandled opcode SETUPVAR -- not in this prototype's supported subset\n"
      end
    # JMP/JMPNOT/JMPIF/JMPNIL are handled here, not by compile_insn, whose bare
    # `goto L<target>;` would miss this body's `label_prefix`-qualified labels or
    # collide with a same-numbered label of the enclosing method (goto labels have
    # function scope). `.to_i`: disassembly zero-pads addresses ("016") but labels
    # use the integer value.
    when 'JMP'
      "  goto #{label_prefix}#{insn.args.strip[/\d+/].to_i};\n"
    when 'JMPUW'
      # JMPUW_SUPPORT: as compile_insn's JMPUW case, but against `block_irep`'s own
      # catch handlers and jump targets, and with prefixed labels (see JMP above).
      if jmpuw_is_plain_jump?(block_irep)
        "  goto #{label_prefix}#{insn.args.strip[/\d+/].to_i};\n"
      else
        "  #error unhandled opcode JMPUW -- not in this prototype's supported subset\n"
      end
    when 'JMPNOT'
      reg = insn.args[/^R(\d+)/, 1]
      "  if (!mrb_test(r#{reg.to_i + offset})) goto #{label_prefix}#{jmp_target_after_reg(insn.args)};\n"
    when 'JMPIF'
      reg = insn.args[/^R(\d+)/, 1]
      "  if (mrb_test(r#{reg.to_i + offset})) goto #{label_prefix}#{jmp_target_after_reg(insn.args)};\n"
    when 'JMPNIL'
      reg = insn.args[/^R(\d+)/, 1]
      "  if (mrb_nil_p(r#{reg.to_i + offset})) goto #{label_prefix}#{jmp_target_after_reg(insn.args)};\n"
    else
      # BLOCK_BODY_INDEX_SUPPORT: `idx` is the instruction's real position in
      # block_irep.instructions (the emitters walk it in order, skipping only
      # ENTER), and `offset` the register shift; with both, FIXNUM_OPERAND_PROOF and
      # GETIDX_STATIC_RECEIVER_SUPPORT run against block_irep's own facts, via
      # unshift_proof_reg.
      compile_shifted_body_insn(insn, block_irep, owner_def, offset, idx)
    end
  end

  # INLINE_NESTED_BLOCK_SUPPORT: the result of the BLOCK_FALLBACK recognize ->
  # emit -> suppress pipeline on ONE inlined body (inline_nested_block_pass).
  # `pre` is file-scope code for the cfuncs; `suppressed`/`glue` drive the
  # emitter's loop like compile_method's suppressed/glue_at. InlineNested.none
  # (nothing claimed) leaves the emitted code unchanged.
  InlineNested = Struct.new(:pre, :suppressed, :glue) do
    def self.none = new(String.new, [], {})

    # JUMP_TARGET_GLUE_FIX's rule: a suppressed address that still carries glue
    # keeps its label; one without code loses it.
    def targets(all) = all - (suppressed - glue.keys)

    def skip?(addr) = suppressed.include?(addr) && !glue.key?(addr)
  end

  # inline_nested_block_pass (below), INLINE_NESTED_BLOCK_SUPPORT:
  # recognize/emit/suppress the BLOCK/SENDB regions NESTED in one inlined loop
  # body, so an already-proven outer region is no longer abandoned just because
  # its body contains another block call (compile_insn has no BLOCK case, so the
  # body got `#error` and the whole loop fell back to BLOCK_FALLBACK). The same
  # pipeline NESTED_BLOCK_FALLBACK_SUPPORT runs inside emit_proc_fallback_fn.
  # E.g. Game::ChipsetLayout.quads_from_quarters:
  #     out = []
  #     2.times do |j|
  #       2.times do |i|
  #         qc, qr = quarters[j][i]
  #         out << [i * HTS, j * HTS, qc * TS + i * HTS, qr * TS + j * HTS, HTS, HTS]
  #       end
  #     end
  # where the inner block has `GETUPVAR R5 1 1` (the method's `quarters`) and
  # `GETUPVAR R6 1 0` (the outer block's `j`).
  # Both levels are directly addressable without pointer forwarding: an inlined
  # body is emitted into the method's own `_impl`, where the method's registers
  # are `r0 .. r<nregs-1>` and the inlined block's are `r<offset> ..` with
  # offset == irep.nregs. So level 0 is `&r<x + offset>` and level 1 is
  # `&r<x>`. Sound only because the inlined-loop emitters are called from
  # compile_method and nowhere else (so `irep` is a method body); re-verify
  # before calling one from a nested context. `available_upvars` = [0, x] for
  # every method register expresses this: the recognizer admits levels 0 and 1
  # and refuses >= 2.
  # RETURN_BLK is refused: it would throw bc2cpp_method_return, and
  # needs_return_catch (which arms the catch) is computed before these emitters
  # run, so nothing would catch it (std::terminate).
  # `blk_available: false`: forwarding the method's block through a nested
  # yield depends on BLKPUSH level counts over real VM frames, which inlining
  # collapses.
  # All-or-nothing: an unclaimable nested region leaves `#error`, and the loop
  # falls back as before.
  #
  # inline_nested_region_has_break?: does the nested region's body contain a
  # BREAK at any depth? Refused: a BLOCK_FALLBACK `break` throws
  # bc2cpp_block_break through the VM frames mrb_funcall_with_block pushed, and
  # that unwind is already broken (mruby's mrb_vm_run callinfo assertion fires
  # for `rows.each { |row| acc << row.each { |v| break v * 100 if v > 1 } }`),
  # so nothing newly admitted may depend on it. MRB_CATCH (mruby/throw.h) does
  # not swallow the foreign type; the VM state is what breaks.
  # `available_upvars` must match the real emit pass (see
  # block_fallback_region_has_return_blk?).
  def inline_nested_region_has_break?(region, available_upvars)
    block_irep = region[:block_irep]
    return true if block_irep.instructions.any? { |i| i.op == 'BREAK' }

    recognize_block_fallback_regions(block_irep, available_upvars: region[:upvars] || available_upvars)
      .any? { |nregion| inline_nested_region_has_break?(nregion, available_upvars) }
  end

  def inline_nested_block_pass(block_irep, irep, d, offset, outer_addr)
    host_upvars = (0...irep.nregs).map { |x| [0, x] }
    regions = recognize_block_fallback_regions(block_irep, available_upvars: host_upvars)
    return InlineNested.none if regions.empty?

    fn_prefix = "#{cpp_name(d.owner, d.name)}_inline_#{outer_addr}"
    nested = InlineNested.none
    regions.each do |nregion|
      next if block_fallback_region_has_return_blk?(nregion)
      next if inline_nested_region_has_break?(nregion, host_upvars)

      fn_result = emit_proc_fallback_fn(nregion, d, fn_prefix)
      next unless fn_result

      nfn_name, nfn_code = fn_result
      nested.pre << nfn_code
      nested.suppressed << nregion[:block_addr] << nregion[:sendb_addr]
      nested.glue[nregion[:block_addr]] = emit_block_fallback_glue(nregion, nfn_name, inline_offset: offset)
    end
    nested
  end

  # BLOCK_SUPPORT: the inlined loop for one `.times` region, or nil if the body
  # is not clean (never emitted partially; the caller then leaves BLOCK/SENDB as
  # `#error`).
  # `offset` (the method's nregs) keeps block registers apart. R0 (the block's
  # self, the method's self) is aliased to `self`, which GETIV/SETIV codegen
  # names directly. Other block registers are reset to nil at the top of EVERY
  # iteration, as a fresh block activation would be.
  def emit_times_inline(region, irep, d)
    block_irep = region[:block_irep]
    offset = irep.nregs
    dest_reg = region[:dest_reg]
    param_reg = 1 + offset # the block's own single mandatory arg, R1 in its own numbering.

    label_prefix = "LBLK#{region[:block_addr]}_"
    body = String.new
    iter_label = "Lbc2cpp_times_iter_#{region[:block_addr]}"
    # INLINE_NESTED_BLOCK_SUPPORT: claim nested block calls before compiling the
    # body (inline_nested_block_pass); compile_block_body_insn consumes
    # `@inline_nested`. Saved and restored, not cleared: compile_method is
    # re-entrant (compiles_clean? -> monomorphic_target -> compile_send ->
    # compile_insn can re-enter it from this body loop), and clearing would disarm
    # an enclosing body's map.
    bc2cpp_saved_nested = @inline_nested
    @inline_nested = inline_nested_block_pass(block_irep, irep, d, offset, region[:block_addr])
    body_targets = @inline_nested.targets(jump_targets(block_irep))
    block_irep.instructions.each_with_index do |insn, i|
      next if insn.op == 'ENTER'

      body << "    #{label_prefix}#{insn.addr}:;\n" if body_targets.include?(insn.addr)
      body << '  ' << compile_block_body_insn(insn, block_irep, d, offset, iter_label, label_prefix, idx: i)
    end
    # INLINE_NESTED_BLOCK_SUPPORT: restore before the early return so the ivar
    # never outlives this loop. The nested cfunc code goes to compile_method only
    # on success; a failed region would leave it unreferenced.
    bc2cpp_nested_pre = @inline_nested.pre
    @inline_nested = bc2cpp_saved_nested
    return nil if body.include?('#error')

    @inline_nested_pre << bc2cpp_nested_pre

    out = String.new
    out << "  {\n"
    # Not E_TYPE_ERROR: that macro hardcodes `mrb`; generated code names it `M`.
    out << "    if (!mrb_integer_p(r#{dest_reg})) { mrb_raise(M, mrb_exc_get_id(M, mrb_intern_lit(M, \"TypeError\")), \"bc2cpp: expected Integer receiver for inlined #times\"); }\n"
    out << "    mrb_int bc2cpp_times_n_#{region[:block_addr]} = mrb_integer(r#{dest_reg});\n"
    out << "    for (mrb_int bc2cpp_times_i_#{region[:block_addr]} = 0; " \
           "bc2cpp_times_i_#{region[:block_addr]} < bc2cpp_times_n_#{region[:block_addr]}; " \
           "++bc2cpp_times_i_#{region[:block_addr]}) {\n"
    (0...block_irep.nregs).each do |i|
      next if i.zero? # R0: the block's own `self` -- aliased below, never renumbered.

      out << "      mrb_value r#{i + offset} = mrb_nil_value();\n"
    end
    out << "      mrb_value r#{offset} = self;\n"
    out << "      r#{param_reg} = mrb_fixnum_value(bc2cpp_times_i_#{region[:block_addr]});\n"
    out << body
    out << "      #{iter_label}:;\n"
    out << "    }\n"
    out << "  }\n"
    # Integer#times returns the receiver, which r<dest_reg> still holds.
    out
  end

  # EACH_BLOCK_SUPPORT: the inlined loop for one `ary.each` region (nil if not
  # clean). Differences from times:
  #   - LIVE length: `i < RARRAY_LEN(recv)` every iteration, as array.c does;
  #     Array#each visits elements pushed during iteration. Elements via
  #     mrb_ary_ref.
  #   - An mrb_array_p raise-guard (a tripwire; the recognizer's gate should
  #     make it unreachable). Not an mrb_funcall fallback: mrb_funcall cannot
  #     pass a block (the reason ADR 0147 rejected proc-wrapping). Unproven
  #     sites stay interpreted.
  #   - BREAK wired (break_dest/break_label). A completed loop leaves the
  #     receiver in the destination, which is what Array#each returns.
  def emit_each_inline(region, irep, d)
    block_irep = region[:block_irep]
    offset = irep.nregs
    dest_reg = region[:dest_reg]
    recv_expr = region[:ssendb] ? 'self' : "r#{dest_reg}"
    param_reg = 1 + offset # the block's own single mandatory arg, R1 in its own numbering.

    label_prefix = "LBLK#{region[:block_addr]}_"
    iter_label = "Lbc2cpp_each_iter_#{region[:block_addr]}"
    break_label = "Lbc2cpp_each_end_#{region[:block_addr]}"
    body = String.new
    # INLINE_NESTED_BLOCK_SUPPORT: save/claim/restore as in emit_times_inline.
    bc2cpp_saved_nested = @inline_nested
    @inline_nested = inline_nested_block_pass(block_irep, irep, d, offset, region[:block_addr])
    body_targets = @inline_nested.targets(jump_targets(block_irep))
    capture_hints = inline_hash_capture_hints(irep, region)
    with_block_hash_capture_hints(capture_hints) do
      block_irep.instructions.each_with_index do |insn, i|
        next if insn.op == 'ENTER'

        body << "    #{label_prefix}#{insn.addr}:;\n" if body_targets.include?(insn.addr)
        # ELEMENT_CLASS_SUPPORT: the block's single parameter R1 is bound to the
        # element below, so R1 is the loop element.
        with_element_hint(block_irep, insn, i, '1', region[:elem_class]) do
          body << '  ' << compile_block_body_insn(insn, block_irep, d, offset, iter_label, label_prefix,
                                                  break_dest: dest_reg, break_label: break_label, idx: i)
        end
      end
    end
    # INLINE_NESTED_BLOCK_SUPPORT: restore before the early return (see
    # emit_times_inline).
    bc2cpp_nested_pre = @inline_nested.pre
    @inline_nested = bc2cpp_saved_nested
    return nil if body.include?('#error')

    @inline_nested_pre << bc2cpp_nested_pre

    out = String.new
    out << "  {\n"
    out << "    if (!mrb_array_p(#{recv_expr})) { mrb_raise(M, mrb_exc_get_id(M, mrb_intern_lit(M, \"TypeError\")), \"bc2cpp: expected Array receiver for inlined #each\"); }\n"
    out << "    for (mrb_int bc2cpp_each_i_#{region[:block_addr]} = 0; " \
           "bc2cpp_each_i_#{region[:block_addr]} < RARRAY_LEN(#{recv_expr}); " \
           "++bc2cpp_each_i_#{region[:block_addr]}) {\n"
    (0...block_irep.nregs).each do |i|
      next if i.zero? # R0: the block's own `self` -- aliased below, never renumbered.

      out << "      mrb_value r#{i + offset} = mrb_nil_value();\n"
    end
    out << "      mrb_value r#{offset} = self;\n"
    out << "      r#{param_reg} = bc2cpp_ary_entry(M, #{recv_expr}, bc2cpp_each_i_#{region[:block_addr]});\n"
    out << body
    out << "      #{iter_label}:;\n"
    out << "    }\n"
    out << "    #{break_label}:;\n"
    out << "  }\n"
    out
  end

  # EACH_INDEX_SUPPORT: emit_each_inline's live-length loop, but the parameter is
  # the counter (`mrb_fixnum_value(i)`): Array#each_index yields idx, not
  # self[idx]. No element hint (the value is an Integer). Returns the receiver.
  def emit_each_index_inline(region, irep, d)
    block_irep = region[:block_irep]
    offset = irep.nregs
    dest_reg = region[:dest_reg]
    recv_expr = region[:ssendb] ? 'self' : "r#{dest_reg}"
    param_reg = 1 + offset # the block's own single mandatory arg, R1 in its own numbering.

    label_prefix = "LBLK#{region[:block_addr]}_"
    iter_label = "Lbc2cpp_eachidx_iter_#{region[:block_addr]}"
    break_label = "Lbc2cpp_eachidx_end_#{region[:block_addr]}"
    body = String.new
    # INLINE_NESTED_BLOCK_SUPPORT: save/claim/restore as in emit_times_inline.
    bc2cpp_saved_nested = @inline_nested
    @inline_nested = inline_nested_block_pass(block_irep, irep, d, offset, region[:block_addr])
    body_targets = @inline_nested.targets(jump_targets(block_irep))
    block_irep.instructions.each_with_index do |insn, i|
      next if insn.op == 'ENTER'

      body << "    #{label_prefix}#{insn.addr}:;\n" if body_targets.include?(insn.addr)
      body << '  ' << compile_block_body_insn(insn, block_irep, d, offset, iter_label, label_prefix,
                                              break_dest: dest_reg, break_label: break_label, idx: i)
    end
    # INLINE_NESTED_BLOCK_SUPPORT: restore before the early return (see
    # emit_times_inline).
    bc2cpp_nested_pre = @inline_nested.pre
    @inline_nested = bc2cpp_saved_nested
    return nil if body.include?('#error')

    @inline_nested_pre << bc2cpp_nested_pre

    out = String.new
    out << "  {\n"
    out << "    if (!mrb_array_p(#{recv_expr})) { mrb_raise(M, mrb_exc_get_id(M, mrb_intern_lit(M, \"TypeError\")), \"bc2cpp: expected Array receiver for inlined #each_index\"); }\n"
    out << "    for (mrb_int bc2cpp_eachidx_i_#{region[:block_addr]} = 0; " \
           "bc2cpp_eachidx_i_#{region[:block_addr]} < RARRAY_LEN(#{recv_expr}); " \
           "++bc2cpp_eachidx_i_#{region[:block_addr]}) {\n"
    (0...block_irep.nregs).each do |i|
      next if i.zero? # R0: the block's own `self` -- aliased below, never renumbered.

      out << "      mrb_value r#{i + offset} = mrb_nil_value();\n"
    end
    out << "      mrb_value r#{offset} = self;\n"
    out << "      r#{param_reg} = mrb_fixnum_value(bc2cpp_eachidx_i_#{region[:block_addr]});\n"
    out << body
    out << "      #{iter_label}:;\n"
    out << "    }\n"
    out << "    #{break_label}:;\n"
    out << "  }\n"
    out
  end

  # HASH_EACH_SUPPORT: the inlined loop for `hash.each` (nil if not clean).
  # Differences from emit_each_inline (mrblib/hash.rb):
  #   - SNAPSHOT: Hash#each takes keys/values/size once. mrb_hash_keys and
  #     mrb_hash_values (public MRB_API) return fresh Arrays, so mutation during
  #     iteration cannot affect the loop.
  #   - Key and value are assigned directly to the block's R1/R2 (as the
  #     reduce/inject fold does).
  # An mrb_hash_p raise-guard; BREAK wired; returns the receiver.
  def emit_hash_each_inline(region, irep, d)
    block_irep = region[:block_irep]
    offset = irep.nregs
    dest_reg = region[:dest_reg]
    recv_expr = region[:ssendb] ? 'self' : "r#{dest_reg}"
    key_reg = 1 + offset
    val_reg = 2 + offset # the block's own two mandatory args, R1/R2 in its own numbering.

    label_prefix = "LBLK#{region[:block_addr]}_"
    iter_label = "Lbc2cpp_heach_iter_#{region[:block_addr]}"
    break_label = "Lbc2cpp_heach_end_#{region[:block_addr]}"
    body = String.new
    # INLINE_NESTED_BLOCK_SUPPORT: save/claim/restore as in emit_times_inline.
    bc2cpp_saved_nested = @inline_nested
    @inline_nested = inline_nested_block_pass(block_irep, irep, d, offset, region[:block_addr])
    body_targets = @inline_nested.targets(jump_targets(block_irep))
    block_irep.instructions.each_with_index do |insn, i|
      next if insn.op == 'ENTER'

      body << "    #{label_prefix}#{insn.addr}:;\n" if body_targets.include?(insn.addr)
      # HASH_ELEMENT_SUPPORT: R2 is bound to the value below, so R2 is the loop value
      # (values only; see HashElementLayout).
      with_element_hint(block_irep, insn, i, '2', region[:elem_class]) do
        body << '  ' << compile_block_body_insn(insn, block_irep, d, offset, iter_label, label_prefix,
                                                 break_dest: dest_reg, break_label: break_label, idx: i)
      end
    end
    # INLINE_NESTED_BLOCK_SUPPORT: restore before the early return (see
    # emit_times_inline).
    bc2cpp_nested_pre = @inline_nested.pre
    @inline_nested = bc2cpp_saved_nested
    return nil if body.include?('#error')

    @inline_nested_pre << bc2cpp_nested_pre

    out = String.new
    out << "  {\n"
    out << "    if (!mrb_hash_p(#{recv_expr})) { mrb_raise(M, mrb_exc_get_id(M, mrb_intern_lit(M, \"TypeError\")), \"bc2cpp: expected Hash receiver for inlined #each\"); }\n"
    out << "    mrb_value bc2cpp_heach_keys_#{region[:block_addr]} = mrb_hash_keys(M, #{recv_expr});\n"
    out << "    mrb_value bc2cpp_heach_vals_#{region[:block_addr]} = mrb_hash_values(M, #{recv_expr});\n"
    out << "    mrb_int bc2cpp_heach_len_#{region[:block_addr]} = mrb_hash_size(M, #{recv_expr});\n"
    out << "    for (mrb_int bc2cpp_heach_i_#{region[:block_addr]} = 0; " \
           "bc2cpp_heach_i_#{region[:block_addr]} < bc2cpp_heach_len_#{region[:block_addr]}; " \
           "++bc2cpp_heach_i_#{region[:block_addr]}) {\n"
    (0...block_irep.nregs).each do |i|
      next if i.zero? # R0: the block's own `self` -- aliased below, never renumbered.

      out << "      mrb_value r#{i + offset} = mrb_nil_value();\n"
    end
    out << "      mrb_value r#{offset} = self;\n"
    out << "      r#{key_reg} = bc2cpp_ary_entry(M, bc2cpp_heach_keys_#{region[:block_addr]}, " \
           "bc2cpp_heach_i_#{region[:block_addr]});\n"
    out << "      r#{val_reg} = bc2cpp_ary_entry(M, bc2cpp_heach_vals_#{region[:block_addr]}, " \
           "bc2cpp_heach_i_#{region[:block_addr]});\n"
    out << body
    out << "      #{iter_label}:;\n"
    out << "    }\n"
    out << "    #{break_label}:;\n"
    out << "  }\n"
    out
  end

  # EACH_KEY_SUPPORT: emit_hash_each_inline's snapshot loop over keys only
  # (Hash#each_key never calls values); one value bound. Same guard; returns the
  # receiver.
  def emit_each_key_inline(region, irep, d)
    block_irep = region[:block_irep]
    offset = irep.nregs
    dest_reg = region[:dest_reg]
    recv_expr = region[:ssendb] ? 'self' : "r#{dest_reg}"
    key_reg = 1 + offset # the block's own single mandatory arg, R1 in its own numbering.

    label_prefix = "LBLK#{region[:block_addr]}_"
    iter_label = "Lbc2cpp_ekey_iter_#{region[:block_addr]}"
    break_label = "Lbc2cpp_ekey_end_#{region[:block_addr]}"
    body = String.new
    # INLINE_NESTED_BLOCK_SUPPORT: save/claim/restore as in emit_times_inline.
    bc2cpp_saved_nested = @inline_nested
    @inline_nested = inline_nested_block_pass(block_irep, irep, d, offset, region[:block_addr])
    body_targets = @inline_nested.targets(jump_targets(block_irep))
    block_irep.instructions.each_with_index do |insn, i|
      next if insn.op == 'ENTER'

      body << "    #{label_prefix}#{insn.addr}:;\n" if body_targets.include?(insn.addr)
      body << '  ' << compile_block_body_insn(insn, block_irep, d, offset, iter_label, label_prefix,
                                               break_dest: dest_reg, break_label: break_label, idx: i)
    end
    # INLINE_NESTED_BLOCK_SUPPORT: restore before the early return (see
    # emit_times_inline).
    bc2cpp_nested_pre = @inline_nested.pre
    @inline_nested = bc2cpp_saved_nested
    return nil if body.include?('#error')

    @inline_nested_pre << bc2cpp_nested_pre

    out = String.new
    out << "  {\n"
    out << "    if (!mrb_hash_p(#{recv_expr})) { mrb_raise(M, mrb_exc_get_id(M, mrb_intern_lit(M, \"TypeError\")), \"bc2cpp: expected Hash receiver for inlined #each_key\"); }\n"
    out << "    mrb_value bc2cpp_ekey_keys_#{region[:block_addr]} = mrb_hash_keys(M, #{recv_expr});\n"
    out << "    mrb_int bc2cpp_ekey_len_#{region[:block_addr]} = mrb_hash_size(M, #{recv_expr});\n"
    out << "    for (mrb_int bc2cpp_ekey_i_#{region[:block_addr]} = 0; " \
           "bc2cpp_ekey_i_#{region[:block_addr]} < bc2cpp_ekey_len_#{region[:block_addr]}; " \
           "++bc2cpp_ekey_i_#{region[:block_addr]}) {\n"
    (0...block_irep.nregs).each do |i|
      next if i.zero? # R0: the block's own `self` -- aliased below, never renumbered.

      out << "      mrb_value r#{i + offset} = mrb_nil_value();\n"
    end
    out << "      mrb_value r#{offset} = self;\n"
    out << "      r#{key_reg} = bc2cpp_ary_entry(M, bc2cpp_ekey_keys_#{region[:block_addr]}, " \
           "bc2cpp_ekey_i_#{region[:block_addr]});\n"
    out << body
    out << "      #{iter_label}:;\n"
    out << "    }\n"
    out << "    #{break_label}:;\n"
    out << "  }\n"
    out
  end

  # INTERP_UNLOCK: the inlined loop for Range#each (nil if not clean), following
  # mrblib/range.rb's integer fast path:
  #   - the element is the counter (`mrb_fixnum_value(i)`);
  #   - beg/end/excl are read once (Ranges are frozen by range_initialize);
  #   - `excl ? i < e : i <= e` instead of mrblib's `lim = end + 1`, which
  #     overflows at MRB_INT_MAX;
  #   - the guard is mrb_range_p AND Integer beg/end: Float edges, the `succ`
  #     path and endless ranges (an infinite loop) raise instead. The real excl
  #     flag (mrb_range_excl_p) is used, never `begin == end`.
  # Returns the receiver; BREAK, RETURN_BLK, upvars and jumps as in
  # compile_block_body_insn.
  def emit_range_each_inline(region, irep, d)
    block_irep = region[:block_irep]
    offset = irep.nregs
    dest_reg = region[:dest_reg]
    recv = "r#{dest_reg}"
    param_reg = 1 + offset
    addr = region[:block_addr]

    label_prefix = "LBLK#{addr}_"
    iter_label = "Lbc2cpp_range_iter_#{addr}"
    break_label = "Lbc2cpp_range_end_#{addr}"
    body = String.new
    # INLINE_NESTED_BLOCK_SUPPORT: save/claim/restore as in emit_times_inline.
    bc2cpp_saved_nested = @inline_nested
    @inline_nested = inline_nested_block_pass(block_irep, irep, d, offset, region[:block_addr])
    body_targets = @inline_nested.targets(jump_targets(block_irep))
    block_irep.instructions.each_with_index do |insn, i|
      next if insn.op == 'ENTER'

      body << "    #{label_prefix}#{insn.addr}:;\n" if body_targets.include?(insn.addr)
      body << '  ' << compile_block_body_insn(insn, block_irep, d, offset, iter_label, label_prefix,
                                              break_dest: dest_reg, break_label: break_label, idx: i)
    end
    # INLINE_NESTED_BLOCK_SUPPORT: restore before the early return (see
    # emit_times_inline).
    bc2cpp_nested_pre = @inline_nested.pre
    @inline_nested = bc2cpp_saved_nested
    return nil if body.include?('#error')

    @inline_nested_pre << bc2cpp_nested_pre

    out = String.new
    out << "  {\n"
    out << "    if (!mrb_range_p(#{recv})) { mrb_raise(M, mrb_exc_get_id(M, mrb_intern_lit(M, \"TypeError\")), \"bc2cpp: expected Range receiver for inlined #each\"); }\n"
    out << "    mrb_value bc2cpp_range_b_#{addr} = mrb_range_beg(M, #{recv});\n"
    out << "    mrb_value bc2cpp_range_e_#{addr} = mrb_range_end(M, #{recv});\n"
    out << "    if (!mrb_integer_p(bc2cpp_range_b_#{addr}) || !mrb_integer_p(bc2cpp_range_e_#{addr})) { mrb_raise(M, mrb_exc_get_id(M, mrb_intern_lit(M, \"TypeError\")), \"bc2cpp: non-Integer Range#each left to interpreter\"); }\n"
    out << "    mrb_int bc2cpp_range_a_#{addr} = mrb_integer(bc2cpp_range_b_#{addr});\n"
    out << "    mrb_int bc2cpp_range_z_#{addr} = mrb_integer(bc2cpp_range_e_#{addr});\n"
    out << "    mrb_bool bc2cpp_range_x_#{addr} = mrb_range_excl_p(M, #{recv});\n"
    out << "    for (mrb_int bc2cpp_range_i_#{addr} = bc2cpp_range_a_#{addr}; " \
           "bc2cpp_range_x_#{addr} ? bc2cpp_range_i_#{addr} < bc2cpp_range_z_#{addr} : bc2cpp_range_i_#{addr} <= bc2cpp_range_z_#{addr}; " \
           "++bc2cpp_range_i_#{addr}) {\n"
    (0...block_irep.nregs).each do |i|
      next if i.zero?

      out << "      mrb_value r#{i + offset} = mrb_nil_value();\n"
    end
    out << "      mrb_value r#{offset} = self;\n"
    out << "      r#{param_reg} = mrb_fixnum_value(bc2cpp_range_i_#{addr});\n"
    out << body
    out << "      #{iter_label}:;\n"
    out << "    }\n"
    out << "    #{break_label}:;\n"
    out << "  }\n"
    out
  end

  # MAP_BLOCK_SUPPORT: the inlined loop for a collection-block region (nil if not
  # clean). Differences from emit_each_inline:
  #   - result: map pushes each yielded value into a fresh accumulator (the
  #     destination gets it, not the receiver); select/reject push the element
  #     on a truthy/falsy result; find takes the first truthy element and exits
  #     (nil otherwise); each_with_index binds a second parameter to the index.
  #   - the yielded value (RETURN/RETNIL/RETFALSE/RETTRUE, i.e. `next`) is
  #     stored into the per-iteration result by compile_collect_body_insn; a
  #     bare `next` collects nil, as in Ruby.
  #   - `break v` sets the destination and jumps past the loop.
  #   - live RARRAY_LEN and mrb_array_p guard as in each.
  def emit_collect_inline(region, irep, d)
    block_irep = region[:block_irep]
    offset = irep.nregs
    dest_reg = region[:dest_reg]
    recv_expr = region[:ssendb] ? 'self' : "r#{dest_reg}"
    meth = region[:method_name]
    param_reg = 1 + offset
    param2_reg = 2 + offset # each_with_index's own index arg, R2 in block numbering.

    label_prefix = "LBLK#{region[:block_addr]}_"
    iter_label = "Lbc2cpp_collect_iter_#{region[:block_addr]}"
    break_label = "Lbc2cpp_collect_end_#{region[:block_addr]}"
    result_var = "bc2cpp_collect_v_#{region[:block_addr]}"
    body = String.new
    # INLINE_NESTED_BLOCK_SUPPORT: save/claim/restore as in emit_times_inline.
    bc2cpp_saved_nested = @inline_nested
    @inline_nested = inline_nested_block_pass(block_irep, irep, d, offset, region[:block_addr])
    body_targets = @inline_nested.targets(jump_targets(block_irep))
    block_irep.instructions.each_with_index do |insn, i|
      next if insn.op == 'ENTER'

      body << "    #{label_prefix}#{insn.addr}:;\n" if body_targets.include?(insn.addr)
      # ELEMENT_CLASS_SUPPORT: R1 is the element for every admitted method;
      # each_with_index's R2 (the index) is not hinted.
      with_element_hint(block_irep, insn, i, '1', region[:elem_class]) do
        body << '  ' << compile_collect_body_insn(insn, block_irep, d, offset, iter_label, label_prefix,
                                                  result_var: result_var, break_dest: dest_reg,
                                                  break_label: break_label,
                                                  broke_flag: "bc2cpp_collect_broke_#{region[:block_addr]}", idx: i)
      end
    end
    # INLINE_NESTED_BLOCK_SUPPORT: restore before the early return (see
    # emit_times_inline).
    bc2cpp_nested_pre = @inline_nested.pre
    @inline_nested = bc2cpp_saved_nested
    return nil if body.include?('#error')

    @inline_nested_pre << bc2cpp_nested_pre

    out = String.new
    out << "  {\n"
    out << "    if (!mrb_array_p(#{recv_expr})) { mrb_raise(M, mrb_exc_get_id(M, mrb_intern_lit(M, \"TypeError\")), \"bc2cpp: expected Array receiver for inlined ##{meth}\"); }\n"
    out << "    mrb_value bc2cpp_collect_acc_#{region[:block_addr]} = mrb_ary_new(M);\n" if %w[map select reject flat_map filter_map].include?(meth)
    out << "    mrb_value bc2cpp_collect_found_#{region[:block_addr]} = mrb_nil_value();\n" if meth == 'find'
    out << "    mrb_bool bc2cpp_collect_broke_#{region[:block_addr]} = FALSE;\n" if meth != 'each_with_index'
    out << "    for (mrb_int bc2cpp_collect_i_#{region[:block_addr]} = 0; " \
           "bc2cpp_collect_i_#{region[:block_addr]} < RARRAY_LEN(#{recv_expr}); " \
           "++bc2cpp_collect_i_#{region[:block_addr]}) {\n"
    (0...block_irep.nregs).each do |i|
      next if i.zero?

      out << "      mrb_value r#{i + offset} = mrb_nil_value();\n"
    end
    out << "      mrb_value r#{offset} = self;\n"
    out << "      mrb_value #{result_var} = mrb_nil_value();\n"
    out << "      r#{param_reg} = bc2cpp_ary_entry(M, #{recv_expr}, bc2cpp_collect_i_#{region[:block_addr]});\n"
    out << "      r#{param2_reg} = mrb_fixnum_value(bc2cpp_collect_i_#{region[:block_addr]});\n" if meth == 'each_with_index'
    out << body
    out << "      #{iter_label}:;\n"
    case meth
    when 'map'
      out << "      mrb_ary_push(M, bc2cpp_collect_acc_#{region[:block_addr]}, #{result_var});\n"
    when 'flat_map'
      # INTERP_UNLOCK: mruby's flat_map (mruby-enum-ext enum.rb) pushes a yielded
      # value whole unless it responds to `each`, else pushes its elements (one
      # level). The same respond_to? test is used, but expansion goes through
      # RARRAY_LEN only after an mrb_array_p tripwire: a Hash/Range yielder responds
      # to `each` without being an Array, and RARRAY_LEN on it would misread memory.
      # So yielding a non-Array each-responder raises here where the VM would
      # expand it: a deliberate narrowing (the game's flat_map blocks yield Arrays).
      out << "      if (mrb_test(mrb_funcall(M, #{result_var}, \"respond_to?\", 1, mrb_symbol_value(mrb_intern_cstr(M, \"each\"))))) {\n"
      out << "      if (!mrb_array_p(#{result_var})) { mrb_raise(M, mrb_exc_get_id(M, mrb_intern_lit(M, \"TypeError\")), \"bc2cpp: flat_map yielded non-Array\"); }\n"
      out << "      mrb_int bc2cpp_collect_fm_n_#{region[:block_addr]} = RARRAY_LEN(#{result_var});\n"
      out << "      for (mrb_int bc2cpp_collect_fm_i_#{region[:block_addr]} = 0; bc2cpp_collect_fm_i_#{region[:block_addr]} < bc2cpp_collect_fm_n_#{region[:block_addr]}; ++bc2cpp_collect_fm_i_#{region[:block_addr]}) {\n"
      out << "        mrb_ary_push(M, bc2cpp_collect_acc_#{region[:block_addr]}, bc2cpp_ary_entry(M, #{result_var}, bc2cpp_collect_fm_i_#{region[:block_addr]}));\n"
      out << "      }\n"
      out << "      } else {\n"
      out << "        mrb_ary_push(M, bc2cpp_collect_acc_#{region[:block_addr]}, #{result_var});\n"
      out << "      }\n"
    when 'select'
      out << "      if (mrb_test(#{result_var})) mrb_ary_push(M, bc2cpp_collect_acc_#{region[:block_addr]}, r#{param_reg});\n"
    when 'reject'
      out << "      if (!mrb_test(#{result_var})) mrb_ary_push(M, bc2cpp_collect_acc_#{region[:block_addr]}, r#{param_reg});\n"
    when 'find'
      out << "      if (mrb_test(#{result_var})) { bc2cpp_collect_found_#{region[:block_addr]} = r#{param_reg}; goto #{break_label}; }\n"
    when 'filter_map'
      # filter_map pushes the block's RESULT when truthy (Enumerable#filter_map
      # reassigns `x = blk.call(*x)` before `ary.push x if x`).
      out << "      if (mrb_test(#{result_var})) mrb_ary_push(M, bc2cpp_collect_acc_#{region[:block_addr]}, #{result_var});\n"
    end
    out << "    }\n"
    out << "    #{break_label}:;\n"
    # A BREAK jumps here with the destination already holding the break value, so
    # the final accumulator assignment must not run on that path. A dedicated
    # flag set only by BREAK is used: comparing the loop index fails when
    # elements are popped during iteration. each_with_index needs neither the flag
    # nor the assignment.
    if meth != 'each_with_index'
      out << "    if (!bc2cpp_collect_broke_#{region[:block_addr]}) {\n"
      case meth
      when 'map', 'select', 'reject', 'flat_map', 'filter_map'
        out << "    r#{dest_reg} = bc2cpp_collect_acc_#{region[:block_addr]};\n"
      when 'find'
        out << "    r#{dest_reg} = bc2cpp_collect_found_#{region[:block_addr]};\n"
      end
      out << "    }\n"
    end
    out << "  }\n"
    out
  end

  # ACCUM_BLOCK_SUPPORT: the inlined loop for an accumulator/predicate region
  # (nil if not clean), cloned from emit_collect_inline:
  #   - any?/all?/none?: boolean destination with early exit (defaults and
  #     exits as in recognize_accum_regions); `break v` overrides via the
  #     broke flag; empty arrays get the defaults.
  #   - count: a fixnum tally, no early exit; `break v` overrides.
  #   - reduce/inject(init): the accumulator is seeded ONCE from R(dest+1)
  #     before the loop, bound to param 1 with the element in param 2, and
  #     replaced by the yielded value. Reading init before the loop makes a
  #     later level-0 SETUPVAR to that register irrelevant.
  def emit_accum_inline(region, irep, d)
    block_irep = region[:block_irep]
    offset = irep.nregs
    dest_reg = region[:dest_reg]
    recv_expr = region[:ssendb] ? 'self' : "r#{dest_reg}"
    meth = region[:method_name]
    is_fold = !region[:init_reg].nil?
    param_reg = 1 + offset
    param2_reg = 2 + offset
    acc_var = "bc2cpp_accum_acc_#{region[:block_addr]}"

    label_prefix = "LBLK#{region[:block_addr]}_"
    iter_label = "Lbc2cpp_accum_iter_#{region[:block_addr]}"
    break_label = "Lbc2cpp_accum_end_#{region[:block_addr]}"
    result_var = "bc2cpp_accum_v_#{region[:block_addr]}"
    body = String.new
    # INLINE_NESTED_BLOCK_SUPPORT: save/claim/restore as in emit_times_inline.
    bc2cpp_saved_nested = @inline_nested
    @inline_nested = inline_nested_block_pass(block_irep, irep, d, offset, region[:block_addr])
    body_targets = @inline_nested.targets(jump_targets(block_irep))
    block_irep.instructions.each_with_index do |insn, i|
      next if insn.op == 'ENTER'

      body << "    #{label_prefix}#{insn.addr}:;\n" if body_targets.include?(insn.addr)
      # ELEMENT_CLASS_SUPPORT: predicates take the element in R1; a fold takes the
      # accumulator in R1 and the element in R2. Read from the same `is_fold` flag
      # as the binding below.
      with_element_hint(block_irep, insn, i, is_fold ? '2' : '1', region[:elem_class]) do
        body << '  ' << compile_collect_body_insn(insn, block_irep, d, offset, iter_label, label_prefix,
                                                  result_var: result_var, break_dest: dest_reg,
                                                  break_label: break_label,
                                                  broke_flag: "bc2cpp_accum_broke_#{region[:block_addr]}", idx: i)
      end
    end
    # INLINE_NESTED_BLOCK_SUPPORT: restore before the early return (see
    # emit_times_inline).
    bc2cpp_nested_pre = @inline_nested.pre
    @inline_nested = bc2cpp_saved_nested
    return nil if body.include?('#error')

    @inline_nested_pre << bc2cpp_nested_pre

    out = String.new
    out << "  {\n"
    out << "    if (!mrb_array_p(#{recv_expr})) { mrb_raise(M, mrb_exc_get_id(M, mrb_intern_lit(M, \"TypeError\")), \"bc2cpp: expected Array receiver for inlined ##{meth}\"); }\n"
    out << "    mrb_bool bc2cpp_accum_broke_#{region[:block_addr]} = FALSE;\n"
    case meth
    when 'any?'
      out << "    mrb_value bc2cpp_accum_res_#{region[:block_addr]} = mrb_false_value();\n"
    when 'all?', 'none?'
      out << "    mrb_value bc2cpp_accum_res_#{region[:block_addr]} = mrb_true_value();\n"
    when 'count'
      out << "    mrb_int bc2cpp_accum_n_#{region[:block_addr]} = 0;\n"
    when 'reduce', 'inject'
      out << "    mrb_value #{acc_var} = r#{region[:init_reg]};\n"
    end
    out << "    for (mrb_int bc2cpp_accum_i_#{region[:block_addr]} = 0; " \
           "bc2cpp_accum_i_#{region[:block_addr]} < RARRAY_LEN(#{recv_expr}); " \
           "++bc2cpp_accum_i_#{region[:block_addr]}) {\n"
    (0...block_irep.nregs).each do |i|
      next if i.zero?

      out << "      mrb_value r#{i + offset} = mrb_nil_value();\n"
    end
    out << "      mrb_value r#{offset} = self;\n"
    out << "      mrb_value #{result_var} = mrb_nil_value();\n"
    if is_fold
      out << "      r#{param_reg} = #{acc_var};\n"
      out << "      r#{param2_reg} = bc2cpp_ary_entry(M, #{recv_expr}, bc2cpp_accum_i_#{region[:block_addr]});\n"
    else
      out << "      r#{param_reg} = bc2cpp_ary_entry(M, #{recv_expr}, bc2cpp_accum_i_#{region[:block_addr]});\n"
    end
    out << body
    out << "      #{iter_label}:;\n"
    case meth
    when 'any?'
      out << "      if (mrb_test(#{result_var})) { bc2cpp_accum_res_#{region[:block_addr]} = mrb_true_value(); goto #{break_label}; }\n"
    when 'all?'
      out << "      if (!mrb_test(#{result_var})) { bc2cpp_accum_res_#{region[:block_addr]} = mrb_false_value(); goto #{break_label}; }\n"
    when 'none?'
      out << "      if (mrb_test(#{result_var})) { bc2cpp_accum_res_#{region[:block_addr]} = mrb_false_value(); goto #{break_label}; }\n"
    when 'count'
      out << "      if (mrb_test(#{result_var})) ++bc2cpp_accum_n_#{region[:block_addr]};\n"
    when 'reduce', 'inject'
      out << "      #{acc_var} = #{result_var};\n"
    end
    out << "    }\n"
    out << "    #{break_label}:;\n"
    out << "    if (!bc2cpp_accum_broke_#{region[:block_addr]}) {\n"
    case meth
    when 'any?', 'all?', 'none?'
      out << "    r#{dest_reg} = bc2cpp_accum_res_#{region[:block_addr]};\n"
    when 'count'
      out << "    r#{dest_reg} = mrb_fixnum_value(bc2cpp_accum_n_#{region[:block_addr]});\n"
    when 'reduce', 'inject'
      out << "    r#{dest_reg} = #{acc_var};\n"
    end
    out << "    }\n"
    out << "  }\n"
    out
  end

  # MAP_BLOCK_SUPPORT: compile_block_body_insn, except the ordinary return forms
  # (`next`, with or without a value) store their value into `result_var` before
  # jumping to iter-end, since collection methods use it. RETURN_BLK is still a
  # plain C++ return.
  def compile_collect_body_insn(insn, block_irep, owner_def, offset, iter_end_label, label_prefix,
                                result_var:, break_dest:, break_label:, broke_flag:, idx: nil)
    case insn.op
    when 'RETURN', 'RETNIL', 'RETFALSE', 'RETTRUE'
      r = insn.op == 'RETURN' ? (insn.args.strip.empty? ? '0' : insn.args[/^R(\d+)/, 1]) : nil
      store = case insn.op
              when 'RETURN' then "r#{r.to_i + offset}"
              when 'RETNIL' then 'mrb_nil_value()'
              when 'RETFALSE' then 'mrb_false_value()'
              when 'RETTRUE' then 'mrb_true_value()'
              end
      "  #{result_var} = #{store};\n  goto #{iter_end_label};\n"
    when 'BREAK'
      # Same value semantics as compile_block_body_insn's BREAK, plus the broke
      # flag so the post-loop accumulator assignment is skipped.
      r = insn.args.strip.empty? ? '0' : insn.args[/^R(\d+)/, 1]
      "  r#{break_dest} = r#{r.to_i + offset};\n  #{broke_flag} = TRUE;\n  goto #{break_label};\n"
    else
      compile_block_body_insn(insn, block_irep, owner_def, offset, iter_end_label, label_prefix,
                              break_dest: break_dest, break_label: break_label, idx: idx)
    end
  end

  # EACH_BLOCK_SUPPORT: the inlined loop for a `&:sym` site. Each iteration does
  # `mrb_funcall(M, elem, "<sym>", 0)`, which is what Symbol#to_proc does, and
  # accumulates per method:
  #   each: discard (destination keeps the receiver);
  #   map: push each result into a fresh Array;
  #   select/reject: push the ELEMENT when the result is truthy/falsy;
  #   find: first element with a truthy result (else nil), early exit;
  #   any?/all?/none?: boolean with early exit (all?/none? default true);
  #   count: tally of truthy results.
  # Live length and mrb_array_p guard as in emit_each_inline.
  def emit_sym_inline(region, _irep, _d)
    dest_reg = region[:dest_reg]
    recv_expr = region[:ssendb] ? 'self' : "r#{dest_reg}"
    meth = region[:method_name]
    sym = region[:sym_name]
    return nil unless SYM_BLOCK_METHODS.include?(meth)

    iter_label = "Lbc2cpp_sym_iter_#{region[:sym_addr]}"
    end_label = "Lbc2cpp_sym_end_#{region[:sym_addr]}"
    out = String.new
    out << "  {\n"
    out << "    if (!mrb_array_p(#{recv_expr})) { mrb_raise(M, mrb_exc_get_id(M, mrb_intern_lit(M, \"TypeError\")), \"bc2cpp: expected Array receiver for inlined &:#{sym}\"); }\n"
    case meth
    when 'map', 'select', 'reject'
      out << "    mrb_value bc2cpp_sym_acc_#{region[:sym_addr]} = mrb_ary_new(M);\n"
    when 'find'
      out << "    mrb_value bc2cpp_sym_acc_#{region[:sym_addr]} = mrb_nil_value();\n"
    when 'any?', 'none?'
      out << "    mrb_value bc2cpp_sym_acc_#{region[:sym_addr]} = mrb_false_value();\n"
    when 'all?'
      out << "    mrb_value bc2cpp_sym_acc_#{region[:sym_addr]} = mrb_true_value();\n"
    when 'count'
      out << "    mrb_int bc2cpp_sym_acc_#{region[:sym_addr]} = 0;\n"
    end
    out << "    for (mrb_int bc2cpp_sym_i_#{region[:sym_addr]} = 0; " \
           "bc2cpp_sym_i_#{region[:sym_addr]} < RARRAY_LEN(#{recv_expr}); " \
           "++bc2cpp_sym_i_#{region[:sym_addr]}) {\n"
    out << "      mrb_value bc2cpp_sym_e_#{region[:sym_addr]} = " \
           "bc2cpp_ary_entry(M, #{recv_expr}, bc2cpp_sym_i_#{region[:sym_addr]});\n"
    if meth == 'each'
      out << "      #{sym_call_line(sym, "bc2cpp_sym_e_#{region[:sym_addr]}")}\n"
    else
      out << "      #{sym_call_value(sym, "bc2cpp_sym_e_#{region[:sym_addr]}", "bc2cpp_sym_r_#{region[:sym_addr]}")}\n"
      case meth
      when 'map'
        out << "      mrb_ary_push(M, bc2cpp_sym_acc_#{region[:sym_addr]}, bc2cpp_sym_r_#{region[:sym_addr]});\n"
      when 'select'
        out << "      if (mrb_test(bc2cpp_sym_r_#{region[:sym_addr]})) " \
               "mrb_ary_push(M, bc2cpp_sym_acc_#{region[:sym_addr]}, bc2cpp_sym_e_#{region[:sym_addr]});\n"
      when 'reject'
        out << "      if (!mrb_test(bc2cpp_sym_r_#{region[:sym_addr]})) " \
               "mrb_ary_push(M, bc2cpp_sym_acc_#{region[:sym_addr]}, bc2cpp_sym_e_#{region[:sym_addr]});\n"
      when 'find'
        out << "      if (mrb_test(bc2cpp_sym_r_#{region[:sym_addr]})) { " \
               "bc2cpp_sym_acc_#{region[:sym_addr]} = bc2cpp_sym_e_#{region[:sym_addr]}; " \
               "goto #{end_label}; }\n"
      when 'any?'
        out << "      if (mrb_test(bc2cpp_sym_r_#{region[:sym_addr]})) { " \
               "bc2cpp_sym_acc_#{region[:sym_addr]} = mrb_true_value(); goto #{end_label}; }\n"
      when 'all?'
        out << "      if (!mrb_test(bc2cpp_sym_r_#{region[:sym_addr]})) { " \
               "bc2cpp_sym_acc_#{region[:sym_addr]} = mrb_false_value(); goto #{end_label}; }\n"
      when 'none?'
        out << "      if (mrb_test(bc2cpp_sym_r_#{region[:sym_addr]})) { " \
               "bc2cpp_sym_acc_#{region[:sym_addr]} = mrb_false_value(); goto #{end_label}; }\n"
      when 'count'
        out << "      if (mrb_test(bc2cpp_sym_r_#{region[:sym_addr]})) ++bc2cpp_sym_acc_#{region[:sym_addr]};\n"
      end
    end
    out << "      #{iter_label}:;\n"
    out << "    }\n"
    out << "    #{end_label}:;\n"
    case meth
    when 'each'
      # `each` returns the receiver, already in the destination register.
    when 'count'
      out << "    r#{dest_reg} = mrb_fixnum_value(bc2cpp_sym_acc_#{region[:sym_addr]});\n"
    else
      out << "    r#{dest_reg} = bc2cpp_sym_acc_#{region[:sym_addr]};\n"
    end
    out << "  }\n"
    out
  end

  # SYM_DEVIRT: the per-element call for a `&:sym` site, devirtualized where
  # sym_call_target allows. sym_call_value declares `mrb_value <result_var> =
  # ...`; sym_call_line emits the discarded call for `each`. The element is the
  # loop's `bc2cpp_sym_e_N` local.
  # A POLY chain is an if/else-if/else statement (C has no if-expression), hence
  # two helpers.
  # Sound: the mrb_funcall fallback is exactly Symbol#to_proc (no closure to
  # lose); MONO needs no guard (one def); each POLY branch guards exact class.
  def sym_call_value(sym, elem_expr, result_var)
    kind, target = sym_call_target(sym) || [nil, nil]
    fallback = "mrb_funcall(M, #{elem_expr}, \"#{sym}\", 0)"
    return "mrb_value #{result_var} = #{fallback};" unless kind

    if kind == :mono
      impl = cpp_name(target.owner, target.name) + '_impl'
      return "// MONO &:#{sym} -> #{target.owner}##{target.name}, direct C++ call (no mrb_funcall)\n" \
             "      mrb_value #{result_var} = #{impl}(M, #{elem_expr});"
    end

    out = String.new
    out << "// POLY &:#{sym} (#{target.size} defs) -- per-element exact-class guard chain, mrb_funcall fallback\n"
    out << "      mrb_value #{result_var} = mrb_nil_value();\n"
    target.each_with_index do |d, i|
      impl = cpp_name(d.owner, d.name) + '_impl'
      check = "#{owner_class_ptr_expr(d.owner)} == mrb_obj_class(M, #{elem_expr})"
      out << (i.zero? ? '      ' : '      else ')
      out << "if (#{check}) { #{result_var} = #{impl}(M, #{elem_expr}); }\n"
    end
    out << "      else { #{result_var} = #{fallback}; }\n"
    out
  end

  def sym_call_line(sym, elem_expr)
    kind, target = sym_call_target(sym) || [nil, nil]
    fallback = "mrb_funcall(M, #{elem_expr}, \"#{sym}\", 0);"
    return fallback unless kind

    if kind == :mono
      impl = cpp_name(target.owner, target.name) + '_impl'
      return "// MONO &:#{sym} -> #{target.owner}##{target.name}, direct C++ call (no mrb_funcall)\n" \
             "      #{impl}(M, #{elem_expr});"
    end

    out = String.new
    out << "// POLY &:#{sym} (#{target.size} defs) -- per-element exact-class guard chain, mrb_funcall fallback\n"
    target.each_with_index do |d, i|
      impl = cpp_name(d.owner, d.name) + '_impl'
      check = "#{owner_class_ptr_expr(d.owner)} == mrb_obj_class(M, #{elem_expr})"
      out << (i.zero? ? '      ' : '      else ')
      out << "if (#{check}) { #{impl}(M, #{elem_expr}); }\n"
    end
    out << "      else { #{fallback} }\n"
    out
  end

  # SORT_BLOCK_SUPPORT: the inlined replacement for a sort-family region (nil if
  # not clean).
  # - `sort { |a, b| ... }`: returns nil (stays interpreted): the comparator runs
  #   inside the native sort, which cannot be reproduced as a loop. Bare `sort`
  #   is an ordinary SEND.
  # - `sort_by`/`uniq` with a key block: a Schwartzian transform:
  #     1. keys[i] = block(elem[i]) (compile_collect_body_insn: `next` collects
  #        nil, `break` overrides via the broke flag);
  #     2. pairs[i] = [keys[i], i, elem[i]]; the index keeps the sort stable
  #        (mruby's sort is not, CRuby's sort_by is);
  #     3. sort pairs by (key, index) with mrb_cmp (public; -2 when
  #        incomparable, like the native sort);
  #     4. dest[i] = pairs[i][2].
  #   `uniq` keeps the first element per key (drop adjacent equal keys,
  #   mrb_cmp == 0, after the stable sort). All temporaries are fresh arrays;
  #   the receiver is only read.
  def emit_sort_inline(region, irep, d)
    return nil if region[:method_name] == 'sort'

    block_irep = region[:block_irep]
    offset = irep.nregs
    dest_reg = region[:dest_reg]
    recv_expr = region[:ssendb] ? 'self' : "r#{dest_reg}"
    meth = region[:method_name]
    param_reg = 1 + offset

    label_prefix = "LBLK#{region[:block_addr]}_"
    iter_label = "Lbc2cpp_sort_iter_#{region[:block_addr]}"
    break_label = "Lbc2cpp_sort_end_#{region[:block_addr]}"
    result_var = "bc2cpp_sort_v_#{region[:block_addr]}"
    body = String.new
    # INLINE_NESTED_BLOCK_SUPPORT: save/claim/restore as in emit_times_inline.
    bc2cpp_saved_nested = @inline_nested
    @inline_nested = inline_nested_block_pass(block_irep, irep, d, offset, region[:block_addr])
    body_targets = @inline_nested.targets(jump_targets(block_irep))
    block_irep.instructions.each_with_index do |insn, i|
      next if insn.op == 'ENTER'

      body << "    #{label_prefix}#{insn.addr}:;\n" if body_targets.include?(insn.addr)
      # ELEMENT_CLASS_SUPPORT: a sort_by/uniq key block takes the element as R1.
      with_element_hint(block_irep, insn, i, '1', region[:elem_class]) do
        body << '  ' << compile_collect_body_insn(insn, block_irep, d, offset, iter_label, label_prefix,
                                                  result_var: result_var, break_dest: dest_reg,
                                                  break_label: break_label,
                                                  broke_flag: "bc2cpp_sort_broke_#{region[:block_addr]}", idx: i)
      end
    end
    # INLINE_NESTED_BLOCK_SUPPORT: restore before the early return (see
    # emit_times_inline).
    bc2cpp_nested_pre = @inline_nested.pre
    @inline_nested = bc2cpp_saved_nested
    return nil if body.include?('#error')

    @inline_nested_pre << bc2cpp_nested_pre

    addr = region[:block_addr]
    out = String.new
    out << "  {\n"
    out << "    if (!mrb_array_p(#{recv_expr})) { mrb_raise(M, mrb_exc_get_id(M, mrb_intern_lit(M, \"TypeError\")), \"bc2cpp: expected Array receiver for inlined ##{meth}\"); }\n"
    out << "    mrb_bool bc2cpp_sort_broke_#{addr} = FALSE;\n"
    out << "    mrb_int bc2cpp_sort_n_#{addr} = RARRAY_LEN(#{recv_expr});\n"
    out << "    mrb_value bc2cpp_sort_keys_#{addr} = mrb_ary_new_capa(M, bc2cpp_sort_n_#{addr});\n"
    out << "    for (mrb_int bc2cpp_sort_i_#{addr} = 0; bc2cpp_sort_i_#{addr} < RARRAY_LEN(#{recv_expr}); ++bc2cpp_sort_i_#{addr}) {\n"
    (0...block_irep.nregs).each do |i|
      next if i.zero?

      out << "      mrb_value r#{i + offset} = mrb_nil_value();\n"
    end
    out << "      mrb_value r#{offset} = self;\n"
    out << "      mrb_value #{result_var} = mrb_nil_value();\n"
    out << "      r#{param_reg} = bc2cpp_ary_entry(M, #{recv_expr}, bc2cpp_sort_i_#{addr});\n"
    out << body
    out << "      #{iter_label}:;\n"
    out << "      mrb_ary_push(M, bc2cpp_sort_keys_#{addr}, #{result_var});\n"
    out << "    }\n"
    # The key loop re-checks live RARRAY_LEN (the same live-length rule as the
    # other emitters), so keys are 1:1 with visited elements. The sort phase loops
    # over the key array's length and fetches elements with mrb_ary_ref (nil if
    # the receiver shrank). Only a body that mutates the receiver can make them
    # differ, and the native sort raises "array modified during sort" there anyway.
    out << "    #{break_label}:;\n"
    out << "    if (!bc2cpp_sort_broke_#{addr}) {\n"
    out << "    mrb_int bc2cpp_sort_m_#{addr} = RARRAY_LEN(bc2cpp_sort_keys_#{addr});\n"
    out << "    mrb_value bc2cpp_sort_pairs_#{addr} = mrb_ary_new_capa(M, bc2cpp_sort_m_#{addr});\n"
    out << "    for (mrb_int bc2cpp_sort_j_#{addr} = 0; bc2cpp_sort_j_#{addr} < bc2cpp_sort_m_#{addr}; ++bc2cpp_sort_j_#{addr}) {\n"
    out << "      mrb_value bc2cpp_sort_e_#{addr} = bc2cpp_ary_entry(M, #{recv_expr}, bc2cpp_sort_j_#{addr});\n"
    out << "      mrb_value bc2cpp_sort_k_#{addr} = bc2cpp_ary_entry(M, bc2cpp_sort_keys_#{addr}, bc2cpp_sort_j_#{addr});\n"
    out << "      mrb_value bc2cpp_sort_trip_#{addr} = mrb_ary_new_capa(M, 3);\n"
    out << "      mrb_ary_push(M, bc2cpp_sort_trip_#{addr}, bc2cpp_sort_k_#{addr});\n"
    out << "      mrb_ary_push(M, bc2cpp_sort_trip_#{addr}, mrb_fixnum_value(bc2cpp_sort_j_#{addr}));\n"
    out << "      mrb_ary_push(M, bc2cpp_sort_trip_#{addr}, bc2cpp_sort_e_#{addr});\n"
    out << "      mrb_ary_push(M, bc2cpp_sort_pairs_#{addr}, bc2cpp_sort_trip_#{addr});\n"
    out << "    }\n"
    # Insertion sort on (key, index): O(n^2) but these arrays are small, and the
    # index tiebreak makes it stable at any size. mrb_cmp returns 1/0/-1, or -2 when
    # incomparable (the native sort_cmp contract; incomparable keys raise). The
    # decorated index is always our own fixnum, so mrb_integer cannot fail.
    out << "    for (mrb_int bc2cpp_sort_a_#{addr} = 1; bc2cpp_sort_a_#{addr} < bc2cpp_sort_m_#{addr}; ++bc2cpp_sort_a_#{addr}) {\n"
    out << "      mrb_value bc2cpp_sort_tmp_#{addr} = bc2cpp_ary_entry(M, bc2cpp_sort_pairs_#{addr}, bc2cpp_sort_a_#{addr});\n"
    out << "      mrb_int bc2cpp_sort_b_#{addr} = bc2cpp_sort_a_#{addr} - 1;\n"
    out << "      while (bc2cpp_sort_b_#{addr} >= 0) {\n"
    out << "        mrb_value bc2cpp_sort_pa_#{addr} = bc2cpp_ary_entry(M, bc2cpp_sort_pairs_#{addr}, bc2cpp_sort_b_#{addr});\n"
    out << "        mrb_value bc2cpp_sort_ka_#{addr} = bc2cpp_ary_entry(M, bc2cpp_sort_pa_#{addr}, 0);\n"
    out << "        mrb_value bc2cpp_sort_ia_#{addr} = bc2cpp_ary_entry(M, bc2cpp_sort_pa_#{addr}, 1);\n"
    out << "        mrb_value bc2cpp_sort_kb_#{addr} = bc2cpp_ary_entry(M, bc2cpp_sort_tmp_#{addr}, 0);\n"
    out << "        mrb_value bc2cpp_sort_ib_#{addr} = bc2cpp_ary_entry(M, bc2cpp_sort_tmp_#{addr}, 1);\n"
    out << "        mrb_int bc2cpp_sort_c_#{addr} = mrb_cmp(M, bc2cpp_sort_kb_#{addr}, bc2cpp_sort_ka_#{addr});\n"
    out << "        if (bc2cpp_sort_c_#{addr} == -2) { mrb_raise(M, mrb_exc_get_id(M, mrb_intern_lit(M, \"ArgumentError\")), \"bc2cpp: sort_by comparison failed\"); }\n"
    out << "        if (bc2cpp_sort_c_#{addr} == 0) { bc2cpp_sort_c_#{addr} = (mrb_integer(bc2cpp_sort_ib_#{addr}) < mrb_integer(bc2cpp_sort_ia_#{addr})) ? -1 : 1; }\n"
    out << "        if (bc2cpp_sort_c_#{addr} >= 0) break;\n"
    out << "        mrb_ary_set(M, bc2cpp_sort_pairs_#{addr}, bc2cpp_sort_b_#{addr} + 1, bc2cpp_sort_pa_#{addr});\n"
    out << "        --bc2cpp_sort_b_#{addr};\n"
    out << "      }\n"
    out << "      mrb_ary_set(M, bc2cpp_sort_pairs_#{addr}, bc2cpp_sort_b_#{addr} + 1, bc2cpp_sort_tmp_#{addr});\n"
    out << "    }\n"
    out << "    r#{dest_reg} = mrb_ary_new_capa(M, bc2cpp_sort_m_#{addr});\n"
    if meth == 'uniq'
      out << "    mrb_value bc2cpp_sort_lastk_#{addr} = mrb_nil_value();\n"
      out << "    mrb_bool bc2cpp_sort_havek_#{addr} = FALSE;\n"
      out << "    for (mrb_int bc2cpp_sort_u_#{addr} = 0; bc2cpp_sort_u_#{addr} < bc2cpp_sort_m_#{addr}; ++bc2cpp_sort_u_#{addr}) {\n"
      out << "      mrb_value bc2cpp_sort_pu_#{addr} = bc2cpp_ary_entry(M, bc2cpp_sort_pairs_#{addr}, bc2cpp_sort_u_#{addr});\n"
      out << "      mrb_value bc2cpp_sort_ku_#{addr} = bc2cpp_ary_entry(M, bc2cpp_sort_pu_#{addr}, 0);\n"
      out << "      mrb_int bc2cpp_sort_eq_#{addr} = (bc2cpp_sort_havek_#{addr} && mrb_cmp(M, bc2cpp_sort_ku_#{addr}, bc2cpp_sort_lastk_#{addr}) == 0) ? 1 : 0;\n"
      out << "      if (!bc2cpp_sort_eq_#{addr}) { mrb_ary_push(M, r#{dest_reg}, bc2cpp_ary_entry(M, bc2cpp_sort_pu_#{addr}, 2)); }\n"
      out << "      bc2cpp_sort_lastk_#{addr} = bc2cpp_sort_ku_#{addr};\n"
      out << "      bc2cpp_sort_havek_#{addr} = TRUE;\n"
      out << "    }\n"
    else
      out << "    for (mrb_int bc2cpp_sort_u_#{addr} = 0; bc2cpp_sort_u_#{addr} < bc2cpp_sort_m_#{addr}; ++bc2cpp_sort_u_#{addr}) {\n"
      out << "      mrb_ary_push(M, r#{dest_reg}, bc2cpp_ary_entry(M, bc2cpp_ary_entry(M, bc2cpp_sort_pairs_#{addr}, bc2cpp_sort_u_#{addr}), 2));\n"
      out << "    }\n"
    end
    out << "    }\n"
    out << "  }\n"
    out
  end

  # BLOCK_CFUNC_FALLBACK_SUPPORT: recognize BLOCK/SENDB(SSENDB) regions not
  # claimed by a named inliner (compile_method filters by `suppressed`). Any
  # method name qualifies; the gate is that the block BODY can run standalone
  # (block_fallback_safe?). vm.c OP_SENDB puts the block at `a + c + 1`, so a
  # BLOCK at `dest + n + 1` is the layout checked (see
  # EXPLICIT_ARGS_BLOCK_FALLBACK_SUPPORT below). recognize_lambda_fallback_regions
  # is the LAMBDA sibling.
  #
  # block_fallback_region_has_return_blk?, NESTED_BLOCK_FALLBACK_SUPPORT: does
  # the region's body contain a RETURN_BLK at any depth, including inside its own
  # nested regions? needs_return_catch needs the whole-subtree answer; a nested
  # `return` always throws bc2cpp_method_return and must find the top-level
  # catch.
  def block_fallback_region_has_return_blk?(region)
    block_irep = region[:block_irep]
    return true if block_irep.instructions.any? { |i| i.op == 'RETURN_BLK' }

    # DEEP_UPVAR_CAPTURE_SUPPORT: `available_upvars` must be the same set
    # emit_proc_fallback_fn will use for this body; a pre-scan recognizing fewer
    # nested regions could miss a RETURN_BLK and leave the throw uncaught
    # (std::terminate). One shared expression.
    recognize_block_fallback_regions(block_irep, available_upvars: region[:upvars] || [])
      .any? { |nregion| block_fallback_region_has_return_blk?(nregion) }
  end

  # DEEP_UPVAR_CAPTURE_SUPPORT: every enclosing-scope register this irep needs,
  # including those only its nested blocks reference, as [level, index] pairs
  # (level as GETUPVAR/SETUPVAR count it, 0 = the immediately enclosing scope).
  # A block that references nothing itself must still capture what a nested
  # block needs: in quads_from_quarters the outer `2.times do |j|` has no
  # GETUPVAR while the inner one reads the method's `quarters`/`out` at level 1,
  # which resolves through the outer block's captured pointers. So a child's
  # [l, x] contributes [l - 1, x] here for l >= 1 (level 0 is this irep's own
  # locals), recursively.
  # Every child irep is walked, not only those that will be compiled: an extra
  # capture costs an unused slot, a missing one is a dangling C++ name. A region
  # that then needs a pointer its frame cannot supply is declined by the
  # recognizer (stays `#error`); named inliners claim their sites first.
  # nil means not modelable. MAX_UPVAR_NEST_DEPTH only guards pathological
  # graphs.
  MAX_UPVAR_NEST_DEPTH = 16

  def block_upvar_needs(irep, depth = 0)
    return nil if depth > MAX_UPVAR_NEST_DEPTH

    needs = []
    irep.instructions.each do |insn|
      next unless %w[GETUPVAR SETUPVAR].include?(insn.op)

      _reg, upvar_idx, level = insn.args.split(/\s+/)
      return nil unless upvar_idx =~ /\A\d+\z/ && level =~ /\A\d+\z/

      needs << [level.to_i, upvar_idx.to_i]
    end
    (irep.reps || []).each do |child_label|
      child = child_label && @ireps[child_label]
      next unless child

      child_needs = block_upvar_needs(child, depth + 1)
      return nil if child_needs.nil?

      child_needs.each { |(l, x)| needs << [l - 1, x] if l >= 1 }
    end
    needs.uniq.sort
  end

  # BLOCK_FALLBACK_YIELD_SUPPORT: which enclosing frames' received blocks does
  # this irep (or anything nested) need for its `yield`s? LCF::Array2D#each:
  #
  #     irep (method each)  nregs=4 nlocals=2      -- R1 is the block slot
  #       GETIV R2 @data / SEND0 R2 :size
  #       BLOCK R3 I[0] / SENDB R2 :times n=0
  #     irep (block |i|)    nregs=8 nlocals=4  R1:i  R3:v
  #       ...
  #       BLKPUSH  R4  0:0:0:0 (1)     ; <-- lv == 1
  #       BLKCALL  R4  2
  #
  # versus a method's own `yield` (`BLKPUSH R2 0:0:0:0 (0)`, lv == 0). vm.c
  # OP_BLKPUSH decodes `lv=(b>>0)&0xf`, then `if (lv == 0) stack = regs + 1; else
  # { struct REnv *e = uvenv(mrb, lv-1); ... stack = e->stack + 1; }`, so lv
  # names a frame like GETUPVAR's level. codegen_yield computes lv by walking out
  # to the first METHOD scope:
  #
  #     int lv = 0; codegen_scope *s2 = s;
  #     while (!s2->mscope) { lv++; s2 = s2->prev; if (!s2) break; }
  #
  # so inside a block lv >= 1 and always lands on the enclosing method (a yield
  # outside a method is a SyntaxError).
  # Returns the sorted set of levels this frame must supply, with
  # block_upvar_needs' propagation (a child's l becomes l - 1 for l >= 1; a
  # child's l == 0 is a nested def's own block). nil means an unparsable BLKPUSH.
  def block_blk_needs(irep, depth = 0)
    return nil if depth > MAX_UPVAR_NEST_DEPTH

    needs = []
    irep.instructions.each do |insn|
      next unless insn.op == 'BLKPUSH'

      lv = insn.args[/\((\d+)\)\s*\z/, 1]
      return nil unless lv

      needs << lv.to_i
    end
    (irep.reps || []).each do |child_label|
      child = child_label && @ireps[child_label]
      next unless child

      child_needs = block_blk_needs(child, depth + 1)
      return nil if child_needs.nil?

      child_needs.each { |l| needs << l - 1 if l >= 1 }
    end
    needs.uniq.sort
  end

  # FIBER_NEW_BLOCK_UNSAFE_SUPPORT: `Fiber.new { ... }` must never go through
  # BLOCK_FALLBACK. mruby-fiber's init_fiber raises FiberError for a cfunc-backed
  # RProc (MRB_PROC_CFUNC_P), and removing that check would not help: fiber
  # resume saves/restores a bytecode pc in the proc's irep
  # (`mrb_vm_exec(mrb, c->ci->proc, c->ci->pc)`, and init_fiber reads
  # `p->body.irep->nregs`), which a cfunc proc does not have. So the region is
  # not admitted; the unclaimed BLOCK/SENDB gets `#error` and the method stays
  # interpreted (tools/optcarrot_probe/README.md, Optcarrot::PPU#run).
  # Matches a bare `GETCONST ... Fiber` in the receiver register, following
  # MOVEs only. A miss only means the site is treated as before. Generic name
  # because calls_fiber_yield? reuses it for a plain SEND receiver.
  def fiber_const_receiver?(irep, call_idx, dest_reg)
    reg = dest_reg
    (call_idx - 1).downto(0) do |i|
      insn = irep.instructions[i]
      case insn.op
      when 'MOVE'
        d, s = insn.args.scan(/R(\d+)/).flatten
        next unless d == reg

        reg = s
      when 'GETCONST'
        d = insn.args[/^R(\d+)/, 1]
        next unless d == reg

        return insn.args.split(/\s+/)[1] == 'Fiber'
      else
        d = insn.args[/^R(\d+)/, 1]
        return false if d == reg
      end
    end
    false
  end

  # FIBER_YIELD_UNSAFE_SUPPORT: `Fiber.yield` is a plain SEND (`GETCONST R2
  # Fiber` + `SEND R2 :yield n=1`), so it would compile as an ordinary call into
  # mrb_fiber_yield from a native compiled frame. mruby's reentrant fiber-resume
  # path (fiber_switch/fiber_resume) breaks with a VM-invisible native frame
  # between the fiber entry and the yield ("resuming dead fiber"; see
  # tools/optcarrot_probe/README.md). A method that calls Fiber.yield directly
  # gets an early `#error` stub. Transitive callers are handled by
  # compute_fiber_unsafe_methods.
  def calls_fiber_yield?(irep)
    irep.instructions.each_with_index do |insn, idx|
      next unless %w[SEND SEND0].include?(insn.op)

      name = insn.args[/:([\w+\-*\/<>=!?\[\]&|^~%@]+)/, 1]
      next unless name == 'yield'

      dest_reg = insn.args[/^R(\d+)/, 1]
      next unless dest_reg
      next unless fiber_const_receiver?(irep, idx, dest_reg)

      return true
    end
    false
  end

  # FIBER_REACHABILITY_UNSAFE_SUPPORT: refusing direct Fiber.yield callers is not
  # enough: any compiled frame between the fiber entry and a yield breaks resume
  # (Optcarrot::PPU#main_loop, which calls the yielding methods, still crashed).
  # This takes the transitive closure from every `Fiber.new { }` block body over
  # self-implicit sends (SSEND/SSEND0/SSENDB) to methods of the SAME owner, and
  # refuses every method reached.
  # Same-owner self-sends only: every real call in a fiber body here has that
  # shape. An explicit-receiver call leaving the class is a known gap (none
  # exists); missing one reproduces the loud FiberError, never a silent wrong
  # answer.
  def compute_fiber_unsafe_methods
    by_owner_name = {} # [owner, name] -> irep label, registered methods only
    irep_owner = {} # irep label -> owner, registered methods AND every block nested inside them
    @registry.each_value do |defs|
      defs.each do |d|
        next unless d.irep

        by_owner_name[[d.owner, d.name]] = d.irep
        irep_owner[d.irep] = d.owner
      end
    end

    # A block shares its method's self/owner, so propagating owners down nested
    # block ireps is exact; a Fiber.new seed several blocks deep resolves
    # correctly.
    propagate = irep_owner.keys.dup
    until propagate.empty?
      label = propagate.shift
      irep = @ireps[label]
      next unless irep

      owner = irep_owner[label]
      (irep.reps || []).each do |child_label|
        next unless child_label
        next if irep_owner.key?(child_label)

        irep_owner[child_label] = owner
        propagate << child_label
      end
    end

    seeds = []
    @ireps.each_value do |irep|
      irep.instructions.each_with_index do |insn, idx|
        next unless insn.op == 'BLOCK'

        paired = irep.instructions[idx + 1]
        next unless paired && paired.op == 'SENDB'
        next unless paired.args[/:([\w+\-*\/<>=!?\[\]&|^~%@]+)/, 1] == 'new'

        dest_reg = paired.args[/^R(\d+)/, 1]
        next unless dest_reg && fiber_const_receiver?(irep, idx, dest_reg)

        block_irep_idx = insn.args[/I\[(\d+)\]/, 1]
        next unless block_irep_idx

        block_label = irep.reps[block_irep_idx.to_i]
        seeds << block_label if block_label
      end
    end

    unsafe = Set.new
    # SEEDS_MULTIPLE_OWNERS_SUPPORT: resolve each seed's owner separately.
    queue = seeds.flat_map do |label|
      seed_irep = @ireps[label]
      next [] unless seed_irep

      owner = irep_owner[label]
      next [] unless owner

      self_call_targets(seed_irep).filter_map { |name| by_owner_name[[owner, name]] }
    end
    until queue.empty?
      label = queue.shift
      next unless unsafe.add?(label)

      irep = @ireps[label]
      next unless irep

      owner = irep_owner[label]
      next unless owner

      self_call_targets(irep).each do |name|
        target = by_owner_name[[owner, name]]
        queue << target if target
      end
    end
    @fiber_unsafe_methods = unsafe
  end

  # Every self-send name reachable from `irep`, including inside nested block
  # ireps (a block body is part of the method that contains it).
  def self_call_targets(irep, seen = Set.new.compare_by_identity)
    return [] unless seen.add?(irep)

    names = []
    irep.instructions.each do |insn|
      next unless %w[SSEND SSEND0 SSENDB].include?(insn.op)

      name = insn.args[/:([\w+\-*\/<>=!?\[\]&|^~%@]+)/, 1]
      names << name if name
    end
    (irep.reps || []).each do |child_label|
      child = child_label && @ireps[child_label]
      names.concat(self_call_targets(child, seen)) if child
    end
    names
  end

  def recognize_block_fallback_regions(irep, available_upvars: [], blk_available: false)
    regions = []
    irep.instructions.each_with_index do |insn, idx|
      next unless insn.op == 'BLOCK'

      paired = irep.instructions[idx + 1]
      next unless paired && %w[SENDB SSENDB].include?(paired.op)

      # EXPLICIT_ARGS_BLOCK_FALLBACK_SUPPORT: any fixed positional count
      # (`ary.inject(0) { }`, `ary.each_slice(2) { }`), but never `n=*` (a splat has
      # no static layout) and never a keyword call (`n=3|nk=1`):
      # mrb_funcall_with_block cannot carry keywords (`ci->nk = 0` in
      # funcall_args_capture).
      n_match = paired.args.match(/n=(\d+)(?:\s|$)/)
      next unless n_match

      n = n_match[1].to_i
      dest, _rest = paired.args.split(/\s+/, 2)
      dest_reg = dest[/^R(\d+)/, 1]
      block_reg = insn.args[/^R(\d+)/, 1]
      # Layout: dest, n positional args, then the block (`BLOCK R4` + `SENDB R2
      # :reduce n=1`), so the block is at dest + n + 1.
      next unless dest_reg && block_reg && block_reg == (dest_reg.to_i + n + 1).to_s

      name = paired.args[/:([\w+\-*\/<>=!?\[\]&|^~%@]+)/, 1]
      next unless name

      # FIBER_NEW_BLOCK_UNSAFE_SUPPORT: never admit `Fiber.new { ... }`.
      next if paired.op == 'SENDB' && name == 'new' && fiber_const_receiver?(irep, idx, dest_reg)

      block_irep_idx = insn.args[/I\[(\d+)\]/, 1]
      next unless block_irep_idx

      block_label = irep.reps[block_irep_idx.to_i]
      block_irep = block_label && @ireps[block_label]
      next unless block_irep && block_fallback_safe?(block_irep)

      upvars = block_upvar_needs(block_irep)
      next if upvars.nil?

      # DEEP_UPVAR_CAPTURE_SUPPORT: a level-0 need is always suppliable (a local of
      # this function, `&r<idx>`). A level-L need (L >= 1) can only be forwarded if
      # this function already holds it, i.e. [L - 1, idx] is in `available_upvars`
      # (empty at method level, so L >= 1 is refused there). block_upvar_needs'
      # propagation should make this hold; it stays a real gate so any uncovered
      # shape keeps `#error` instead of a dangling name.
      next unless upvars.all? { |(l, x)| l.zero? || available_upvars.include?([l - 1, x]) }

      # UPVAR_CAPTURE_SUPPORT: a non-empty capture set requires the call's method to
      # be in BLOCK_FALLBACK_UPVAR_SAFE_METHODS (synchronous, never stores the
      # block); an empty one needs no gate.
      # DEEP_UPVAR_CAPTURE_SUPPORT: a forwarded deeper pointer stays valid because
      # every level in between passed this same gate (a forwarding outer site has a
      # non-empty capture set), so the whole frame chain is live while the inner
      # block runs.
      next if upvars.any? && !BLOCK_FALLBACK_UPVAR_SAFE_METHODS.include?(name)

      # BLOCK_FALLBACK_YIELD_SUPPORT: does this body's `yield` need the enclosing
      # method's block forwarded into the cfunc? Only `[1]` is modelled (every
      # BLKPUSH in the subtree resolves to the frame this call site is in, whose
      # block is a C++ local here). Deeper needs keep `#error` (none exist).
      # `blk_available` is true only from compile_method's top level, for methods
      # whose wrapper extracts a block (the same mandatory_ok condition as
      # needs_blk_param).
      # `needs_blk` never gates admission: an unanswerable BLKPUSH still fails on its
      # own `#error` in emit_proc_fallback_fn.
      # The synchronous allowlist is required here too: the captured block is an
      # mrb_value copy (GC-rooted by the env), but it is an irep-backed RProc whose
      # own env is on the caller's stack, so invoking it after that caller returned
      # would be an escaped block (vm.c raises "unexpected yield" for that).
      blk_needs = block_blk_needs(block_irep)
      needs_blk = blk_available && blk_needs == [1] &&
                  BLOCK_FALLBACK_UPVAR_SAFE_METHODS.include?(name)

      regions << { block_addr: insn.addr, sendb_addr: paired.addr, dest_reg: dest_reg,
                   block_irep: block_irep, name: name, n: n,
                   self_implicit: paired.op == 'SSENDB', upvars: upvars, needs_blk: needs_blk,
                   parent_irep: irep }
    end
    regions
  end

  # BLOCK_FALLBACK_ELEMENT_SUPPORT: pass an exact element class into the cfunc
  # only for a known Array or Hash iterator with a proven yield shape; otherwise
  # dynamic dispatch.
  def block_fallback_element_class(irep, region, owner_name)
    return nil unless irep && !region[:self_implicit]

    shape = case region[:name]
            when 'each' then [:array, 0, 1]
            when 'each_with_index' then [:array, 0, 2]
            when 'each_with_object' then [:array, 1, 2]
            when 'each_value' then [:hash, 0, 1]
            end
    return nil unless shape && region[:n] == shape[1]
    return nil unless mandatory_arity(region[:block_irep]) == shape[2]

    idx = irep.instructions.index { |insn| insn.addr == region[:sendb_addr] }
    return nil unless idx

    insn = irep.instructions[idx]
    return nil unless insn.op == 'SENDB'

    mand = mandatory_arity(irep)
    ivar_classes = @class_layout[owner_name] || {}
    arg_classes = @class_annotations[irep.label]&.args
    recv_class = trace_new_target(irep, idx, region[:dest_reg], ivar_classes, mand, arg_classes,
                                  owner: owner_name, class_layout: @class_layout, registry: @registry,
                                  container_constants: @container_constants,
                                  element_annotations: @element_annotations)
    if shape[0] == :array
      recv_class = proven_array_source(irep, idx, region[:dest_reg]) unless recv_class == 'Array'
      return nil unless recv_class == 'Array'

      proven_element_class(irep, idx, region[:dest_reg], ivar_classes, mand, arg_classes, owner_name)
    else
      return nil unless recv_class == 'Hash'

      proven_hash_element_class(irep, idx, region[:dest_reg], ivar_classes, mand, arg_classes, owner_name)
    end
  end

  # BLOCK_CFUNC_FALLBACK_SUPPORT / LAMBDA_FALLBACK_SUPPORT: the body's standalone
  # `_impl` plus an mrb_func_t entry (`mrb_value(mrb_state*, mrb_value)`, as
  # mrb_proc_new_cfunc_with_env requires) that reads the arguments with
  # mrb_get_args. A cfunc proc, yielded or `.call`ed, gets its arguments on the
  # VM stack like an ordinary call (vm.c exec_irep: `ci->stack[0] = self; return
  # MRB_PROC_CFUNC(p)(mrb, self);`). Shared by both recognizers; it only uses
  # region[:block_irep] and region[:block_addr].
  # SELF_CAPTURE_SUPPORT: the `self` mruby passes is ignored (nil for a cfunc
  # proc, see block_fallback_safe?); the real self is read from env slot 0,
  # filled by emit_rproc_construction.
  # A runtime-def/EXEC body's self is its receiver, not an instance of d.owner
  # (nested blocks inherit that), so self-ivar codegen must not assume d.owner.
  def emit_proc_fallback_fn(region, d, fn_prefix = nil)
    saved_self_class_unknown = @self_class_unknown
    @self_class_unknown = saved_self_class_unknown || runtime_def_fallback_kind?(region[:kind])
    emit_proc_fallback_fn_body(region, d, fn_prefix)
  ensure
    @self_class_unknown = saved_self_class_unknown
  end

  def emit_proc_fallback_fn_body(region, d, fn_prefix)
    block_irep = region[:block_irep]
    mand = mandatory_arity(block_irep)
    arg_names = (1..mand).map { |i| "bc2cpp_barg#{i}" }
    # UPVAR_CAPTURE_SUPPORT: region[:upvars] comes from
    # recognize_block_fallback_regions, or from recognize_lambda_fallback_regions
    # for a frame-confined lambda (lambda_proc_frame_confined?). `|| []` is the
    # plain no-upvars case.
    # DEEP_UPVAR_CAPTURE_SUPPORT: entries are [level, index] (see
    # upvar_var_name); level 0 keeps the old spelling.
    upvar_regs = region[:upvars] || []
    upvar_params = upvar_regs.map { |(l, b)| "mrb_value* #{upvar_var_name(l, b)}" }
    # BLOCK_FALLBACK_YIELD_SUPPORT: only recognize_block_fallback_regions sets
    # needs_blk; a lambda can escape the frame whose block it would capture.
    needs_blk = region[:needs_blk] ? true : false
    blk_param = needs_blk ? ['mrb_value bc2cpp_blk'] : []
    # Function names: block_addr is unique only within one irep, so prefix with
    # cpp_name(d.owner, d.name) (as emit_rescue_try_body does); `region[:kind]` is
    # only for readability.
    # NESTED_BLOCK_FALLBACK_SUPPORT: for a nested region `fn_prefix` is the outer
    # level's unique fn_name, since a nested block_addr lives in the block irep's
    # own address space.
    fn_name = "#{fn_prefix || cpp_name(d.owner, d.name)}_#{region[:kind] || 'block_fallback'}_#{region[:block_addr]}"
    impl_name = "#{fn_name}_impl"

    # NESTED_BLOCK_FALLBACK_SUPPORT: recursively run recognize ->
    # emit_proc_fallback_fn -> emit_block_fallback_glue on regions nested in this
    # body. Runs BEFORE this level sets @block_fallback_upvars/
    # @block_fallback_active: the recursive call sets, uses and clears its own
    # first. `nested_pre` is prepended so nested functions are defined first.
    nested_pre = String.new
    nested_suppressed = []
    nested_glue_at = {}
    # BLOCK_FALLBACK_RESCUE_SUPPORT: claim rescue ranges in `nested_suppressed`
    # before the nested BLOCK_FALLBACK pass, so block calls inside a rescue belong
    # to the rescue's own pass. The extraction itself must wait until the ivars are
    # set (its compile_insn calls need them), while the nested pass must run before;
    # splitting claim from emit satisfies both.
    rescue_regions = top_level_rescue_regions(recognize_rescue_regions(block_irep))
    rescue_regions.each do |rregion|
      nested_suppressed.concat((rregion[:begin_addr]..rregion[:end_addr]).to_a)
      nested_suppressed << rregion[:except_addr]
    end
    # DEEP_UPVAR_CAPTURE_SUPPORT: this body's own captured set, which nested
    # regions may forward.
    recognize_block_fallback_regions(block_irep, available_upvars: upvar_regs).each do |nregion|
      # BLOCK_FALLBACK_RESCUE_SUPPORT: regions inside a rescue range belong to that
      # range's own pass (emit_rescue_try_body); emitting them here too would
      # duplicate them.
      next if nested_suppressed.include?(nregion[:block_addr]) || nested_suppressed.include?(nregion[:sendb_addr])

      fn_result = emit_proc_fallback_fn(nregion, d, fn_name)
      next unless fn_result

      nfn_name, nfn_code = fn_result
      nested_pre << nfn_code
      nested_suppressed << nregion[:block_addr] << nregion[:sendb_addr]
      nested_glue_at[nregion[:block_addr]] = emit_block_fallback_glue(nregion, nfn_name)
    end
    # EXPLICIT_BLOCK_ARG_SUPPORT: `&expr` sites in this body: suppress/glue only,
    # no body to compile.
    recognize_explicit_block_arg_regions(block_irep).each do |nregion|
      next if nested_suppressed.include?(nregion[:sendb_addr])

      nested_suppressed << nregion[:sendb_addr]
      nested_glue_at[nregion[:sendb_addr]] = emit_explicit_block_arg_glue(nregion)
    end

    # RUNTIME_DEF_FALLBACK_SUPPORT: a `def` inside an EXEC-opened class body
    # (`class << Graphics; def update; ...; end; end`) is a TDEF whose I[c] body is
    # compiled by the same recursive emit_proc_fallback_fn (self_source:
    # :receiver, kind tdef_fallback) and installed by emit_tdef_fallback_glue.
    # Only inside exec_fallback: TDEF needs self to be the target class, which
    # OP_EXEC guarantees; inside a block or lambda, check_target_class follows the
    # lexical scope the proc was built in, which compiled code cannot see.
    # Runs before the ivars are set, like the nested pass above.
    if region[:kind] == 'exec_fallback'
      block_irep.instructions.each do |tinsn|
        next unless tinsn.op == 'TDEF'
        next if nested_suppressed.include?(tinsn.addr)

        tregion = tdef_fallback_region(tinsn, block_irep)
        next unless tregion

        tfn_result = emit_proc_fallback_fn(tregion, d, fn_name)
        next unless tfn_result

        tfn_name, tfn_code = tfn_result
        nested_pre << tfn_code
        nested_suppressed << tinsn.addr
        nested_glue_at[tinsn.addr] = emit_tdef_fallback_glue(tregion, tfn_name)
      end
    end

    # ALL_OR_NOTHING_SUPPORT: a body with any `#error` produces no region (as
    # every emitter here). compiles_clean? would reject the enclosing method
    # anyway, but the region would still be miscounted as a BLOCK_FALLBACK win in
    # the coverage diagnostic.
    # UPVAR_CAPTURE_SUPPORT: set for this one body loop only and cleared after, so
    # GETUPVAR/SETUPVAR only see names this function declares.
    @block_fallback_upvars = upvar_regs
    # EXCEPTION_BREAK_SUPPORT: selects BREAK's translation: LAMBDA_FALLBACK keeps a
    # plain return (strict proc), BLOCK_FALLBACK throws.
    # RUNTIME_DEF_FALLBACK_SUPPORT: method and class bodies must not get the
    # throwing BREAK (see RUNTIME_DEF_FALLBACK_KINDS). An explicit membership test
    # on the two kinds that set it (nil and 'block_fallback'), so new kinds are
    # opted out by default; the runtime_def_fallback_kind? assertion states the
    # same fact the other way round.
    raise "unexpected self_source for #{region[:kind]}" if
      runtime_def_fallback_kind?(region[:kind]) && region[:self_source] != :receiver
    @block_fallback_active = [nil, 'block_fallback'].include?(region[:kind])
    # BLOCK_FALLBACK_YIELD_SUPPORT: gates BLKPUSH. Saved and restored, not cleared:
    # compile_method sets @blk_param_name too and this function recurses. Level 1
    # only, matching the admitted `blk_needs == [1]` (`BLKPUSH Rx m1:r:m2:kd (1)`).
    saved_blk_param_name = @blk_param_name
    saved_blk_param_level = @blk_param_level
    @blk_param_name = needs_blk ? 'bc2cpp_blk' : nil
    @blk_param_level = 1
    # BLOCK_FALLBACK_RESCUE_SUPPORT: a `rescue` inside the block body
    # (`cached_bitmap(cache, key) { Bitmap.new(...) rescue StandardError => e;
    # ...; end }`) uses the top-level rescue machinery unchanged. Must run AFTER the
    # ivars are set (emit_rescue_try_body's compile_insn calls need them).
    # `extra_fields`/`extra_field_values` pass the captured upvar pointers into the
    # try body under the same names. arg_names and all-nil native types match the
    # block's `_impl`. `rescue_regions` is the list computed above.
    rescue_regions.each_with_index do |rregion, i|
      try_name = "#{impl_name}_rescue_try#{rescue_regions.size > 1 ? "_#{i}" : ''}"
      # BLOCK_FALLBACK_YIELD_SUPPORT: the forwarded block goes into the try body via
      # `extra_fields` too, as an mrb_value (OP_BLKPUSH only reads it), named
      # `bc2cpp_blk`, which @blk_param_name refers to.
      extra_fields = upvar_regs.map { |(l, b)| { name: upvar_var_name(l, b), c_type: 'mrb_value*' } }
      extra_fields += [{ name: 'bc2cpp_blk', c_type: 'mrb_value' }] if needs_blk
      saved = rescue_entry_saved_fields(block_irep, rregion)
      nested_pre << emit_rescue_try_body(try_name, rregion, block_irep, d, arg_names, Array.new(arg_names.size),
                                          extra_fields: extra_fields + saved, available_upvars: upvar_regs)
      nested_glue_at[rregion[:begin_addr]] =
        emit_rescue_glue(try_name, rregion, arg_names, Array.new(arg_names.size),
                         extra_field_values: extra_fields.map { |f| f[:name] } +
                                             saved.map { |f| f[:name].sub('bc2cpp_saved_', '') })
    end
    body = String.new
    # NESTED_BLOCK_FALLBACK_SUPPORT: the JUMP_TARGET_GLUE_FIX label rule.
    targets = jump_targets(block_irep) - (nested_suppressed - nested_glue_at.keys)
    elem_class = block_fallback_element_class(region[:parent_irep], region, d.owner)
    block_irep.instructions.each_with_index do |insn, idx|
      next if insn.op == 'ENTER'
      next if nested_suppressed.include?(insn.addr) && !nested_glue_at.key?(insn.addr)

      body << "  L#{insn.addr}:;\n" if targets.include?(insn.addr)
      if nested_glue_at.key?(insn.addr)
        body << nested_glue_at[insn.addr]
      else
        with_element_hint(block_irep, insn, idx, '1', elem_class) do
          body << compile_insn(insn, block_irep, d, idx)
        end
      end
    end
    @block_fallback_upvars = nil
    @block_fallback_active = false
    @blk_param_name = saved_blk_param_name
    @blk_param_level = saved_blk_param_level
    return nil if nested_pre.include?('#error') || body.include?('#error')

    out = nested_pre
    # BLOCK_FALLBACK_YIELD_SUPPORT: parameter order self, upvars, blk, then the
    # block's own parameters, matching the env slots. Bodies without it are
    # unchanged.
    out << "static mrb_value #{impl_name}(mrb_state* M, mrb_value self" \
           "#{upvar_params.map { |p| ", #{p}" }.join}#{blk_param.map { |p| ", #{p}" }.join}" \
           "#{arg_names.map { |a| ", mrb_value #{a}" }.join}) {\n"
    (0...block_irep.nregs).each { |i| out << "  mrb_value r#{i}" << (i.zero? ? ' = self;' : ' = mrb_nil_value();') << "\n" }
    arg_names.each_with_index { |a, i| out << "  r#{i + 1} = #{a};\n" }
    out << body
    out << "  return mrb_nil_value(); // unreachable if every path RETURNs\n"
    out << "}\n\n"

    # RUNTIME_DEF_FALLBACK_SUPPORT: method bodies and EXEC-opened class bodies take
    # self from the receiver mruby passes (the opposite of a block body). For an
    # installed method that is the object the call dispatched on. For an EXEC body
    # it is the target class: vm.c OP_EXEC does `struct RClass *c =
    # mrb_class_ptr(recv);` and `cipush(mrb, a, 0, c, p, NULL, 0, 0)`, so regs[0]
    # is recv and target_class is mrb_class_ptr(recv). emit_tdef_fallback_glue
    # relies on this to spell check_target_class(mrb) as mrb_class_ptr(self).
    if region[:self_source] == :receiver
      out << "static mrb_value #{fn_name}(mrb_state* M, mrb_value bc2cpp_recv_self) {\n"
      out << "  mrb_value bc2cpp_captured_self = bc2cpp_recv_self;\n"
    else
      out << "static mrb_value #{fn_name}(mrb_state* M, mrb_value bc2cpp_unused_self) {\n"
      out << "  (void)bc2cpp_unused_self;\n"
      out << "  mrb_value bc2cpp_captured_self = mrb_proc_cfunc_env_get(M, 0);\n"
    end
    # UPVAR_CAPTURE_SUPPORT: env slot 0 is self; upvar i is at slot i + 1, the same
    # order emit_rproc_construction builds (both read upvar_regs).
    upvar_args = upvar_regs.each_with_index.map do |(l, b), i|
      vname = upvar_var_name(l, b)
      out << "  mrb_value* #{vname} = static_cast<mrb_value*>(mrb_cptr(mrb_proc_cfunc_env_get(M, #{i + 1})));\n"
      vname
    end
    # BLOCK_FALLBACK_YIELD_SUPPORT: the forwarded block is the last env slot, read
    # back as a plain mrb_value (a copy, kept GC-reachable by the env).
    if needs_blk
      out << "  mrb_value bc2cpp_blk = mrb_proc_cfunc_env_get(M, #{upvar_regs.size + 1});\n"
    end
    call_args = (['bc2cpp_captured_self'] + upvar_args + (needs_blk ? ['bc2cpp_blk'] : [])).join(', ')
    if mand.zero?
      out << "  return #{impl_name}(M, #{call_args});\n"
    elsif (region[:kind] || 'block_fallback') == 'block_fallback' && mand > 1
      # Blocks are lenient about argument count, and Hash#each passes one [key,
      # value] Array; the interpreter expands it for a multi-parameter block, a
      # cfunc proc does not, so do it here.
      out << "  mrb_value* bc2cpp_argv;\n"
      out << "  mrb_int bc2cpp_argc;\n"
      out << "  mrb_get_args(M, \"*\", &bc2cpp_argv, &bc2cpp_argc);\n"
      arg_names.each { |a| out << "  mrb_value #{a};\n" }
      out << "  if (bc2cpp_argc == 1 && mrb_array_p(bc2cpp_argv[0])) {\n"
      arg_names.each_with_index do |a, i|
        out << "    #{a} = mrb_ary_ref(M, bc2cpp_argv[0], #{i});\n"
      end
      out << "  } else {\n"
      arg_names.each_with_index do |a, i|
        out << "    #{a} = bc2cpp_argc > #{i} ? bc2cpp_argv[#{i}] : mrb_nil_value();\n"
      end
      out << "  }\n"
      out << "  return #{impl_name}(M, #{call_args}, #{arg_names.join(', ')});\n"
    else
      arg_names.each { |a| out << "  mrb_value #{a};\n" }
      fmt = 'o' * mand
      ptrs = arg_names.map { |a| "&#{a}" }.join(', ')
      out << "  mrb_get_args(M, \"#{fmt}\", #{ptrs});\n"
      out << "  return #{impl_name}(M, #{call_args}, #{arg_names.join(', ')});\n"
    end
    out << "}\n\n"
    [fn_name, out]
  end

  # BLOCK_CFUNC_FALLBACK_SUPPORT / LAMBDA_FALLBACK_SUPPORT: build the RProc with
  # mrb_proc_new_cfunc_with_env and an env holding the enclosing method's `self`
  # (captured here, where it is a local; read back with
  # mrb_proc_cfunc_env_get(M, 0)). Returns [rproc_var, code]; the caller
  # dispatches or stores it.
  # INLINE_NESTED_BLOCK_SUPPORT: `inline_offset` (only for regions nested in an
  # inlined loop body) takes addresses of locals instead of forwarding pointer
  # parameters: level 0 is `r<b + inline_offset>`, level 1 the method's `r<b>`
  # (see inline_nested_block_pass). Level >= 2 never gets here. nil keeps the
  # previous output.
  def emit_rproc_construction(addr, fn_name, upvar_regs = [], needs_blk = false, inline_offset: nil)
    var = "bc2cpp_blk_proc_#{addr}"
    out = String.new
    # UPVAR_CAPTURE_SUPPORT: `&r#{b}` is the address of this function's register
    # local, boxed with mrb_cptr_value, in the same order the entry reads them.
    # DEEP_UPVAR_CAPTURE_SUPPORT: a level-L entry (L >= 1) is not a local here;
    # this function holds the pointer as its parameter upvar_var_name(l - 1, b), so
    # forward it as is (`&` would box a pointer-to-pointer).
    # BLOCK_FALLBACK_YIELD_SUPPORT: the enclosing frame's block (`bc2cpp_blk`, from
    # mrb_get_args "&" at method level or forwarded again) is appended by value:
    # nothing writes back through it, and the env keeps it GC-rooted.
    env_entries = ['self'] + upvar_regs.map do |(l, b)|
      if inline_offset
        "mrb_cptr_value(M, &r#{l.zero? ? b + inline_offset : b})"
      elsif l.zero?
        "mrb_cptr_value(M, &r#{b})"
      else
        "mrb_cptr_value(M, #{upvar_var_name(l - 1, b)})"
      end
    end
    env_entries << 'bc2cpp_blk' if needs_blk
    out << "    mrb_value bc2cpp_blk_env_#{addr}[] = { #{env_entries.join(', ')} };\n"
    out << "    struct RProc* #{var} = mrb_proc_new_cfunc_with_env(M, #{fn_name}, #{env_entries.size}, " \
           "bc2cpp_blk_env_#{addr});\n"
    [var, out]
  end

  # BLOCK_CFUNC_FALLBACK_SUPPORT: call-site glue: build the RProc
  # (emit_rproc_construction) and call with mrb_funcall_with_block (dynamic
  # dispatch, never devirtualized). emit_lambda_fallback_glue is the
  # no-dispatch sibling.
  # INLINE_NESTED_BLOCK_SUPPORT: `inline_offset` shifts this region's
  # destination/argument registers into the enclosing function's numbering (the
  # compile_block_body_insn shift) and is passed on for the capture levels.
  # `self` is not shifted: the block shares the method's self. nil keeps the
  # previous output.
  def emit_block_fallback_glue(region, fn_name, inline_offset: nil)
    dest_reg = region[:dest_reg].to_i + (inline_offset || 0)
    recv = region[:self_implicit] ? 'self' : "r#{dest_reg}"
    argv = (1..region[:n]).map { |k| "r#{dest_reg + k}" }
    rproc_var, ctor = emit_rproc_construction(region[:block_addr], fn_name, region[:upvars] || [],
                                              region[:needs_blk] ? true : false, inline_offset: inline_offset)
    out = String.new
    out << "  // BLOCK_FALLBACK :#{region[:name]} -- block body compiled as a standalone cfunc, wrapped as a real RProc " \
           "(self captured at construction time), dynamic dispatch\n"
    out << "  {\n"
    out << ctor
    # EXCEPTION_BREAK_SUPPORT: the dispatch is always wrapped (cheap under
    # zero-cost exceptions, and no need to know whether this body has a BREAK); a
    # body without one never throws.
    out << "    Bc2cppVmMark bc2cpp_brk_mark = bc2cpp_vm_mark(M);\n    try {\n"
    if argv.empty?
      out << "      r#{dest_reg} = mrb_funcall_with_block(M, #{recv}, mrb_intern_cstr(M, \"#{region[:name]}\"), 0, NULL, " \
             "mrb_obj_value(#{rproc_var}));\n"
    else
      out << "      mrb_value bc2cpp_blk_argv_#{region[:block_addr]}[] = { #{argv.join(', ')} };\n"
      out << "      r#{dest_reg} = mrb_funcall_with_block(M, #{recv}, mrb_intern_cstr(M, \"#{region[:name]}\"), " \
             "#{argv.size}, bc2cpp_blk_argv_#{region[:block_addr]}, mrb_obj_value(#{rproc_var}));\n"
    end
    out << "    } catch (bc2cpp_block_break& bc2cpp_brk) {\n"
    out << "      bc2cpp_vm_restore(M, bc2cpp_brk_mark);\n"
    out << "      r#{dest_reg} = bc2cpp_brk.value;\n"
    out << "    }\n"
    out << "  }\n"
    out
  end

  # EXPLICIT_BLOCK_ARG_SUPPORT: `ary.select(&:defending)`, `ary.each(&proc_var)`,
  # `ary.map(&method(:bar))`: no BLOCK instruction, just `expr` evaluated into
  # R(dest+n+1) before the SENDB/SSENDB. No body to compile:
  # mrb_funcall_with_block (vm.c) already runs ensure_block on the value
  # (`if (!mrb_nil_p(blk) && !mrb_proc_p(blk)) blk = mrb_type_convert(mrb, blk,
  # MRB_TT_PROC, MRB_SYM(to_proc));`), and `&nil` passes through. So the register
  # is handed straight to mrb_funcall_with_block, inside the same
  # `catch (bc2cpp_block_break&)` wrapper (the value may be one of our own
  # BLOCK_FALLBACK RProcs, whose break throws that type).
  def recognize_explicit_block_arg_regions(irep)
    regions = []
    irep.instructions.each_with_index do |insn, idx|
      next unless %w[SENDB SSENDB].include?(insn.op)

      prev = idx.positive? ? irep.instructions[idx - 1] : nil
      next if prev && prev.op == 'BLOCK'

      # EXPLICIT_BLOCK_ARG_DYNAMIC_SPLAT_SUPPORT: `n=*` (no `|nk=`) with `&expr`, e.g.
      # `__send__(name, *args, &block)` in RGSS::ErrorReport::Tee#method_missing.
      # The args Array is already built in R(dest+1) (see compile_dynamic_splat_send)
      # and the block is in R(dest+2).
      n_match = insn.args.match(/n=(\d+|\*)(?:\s|$)/)
      next unless n_match

      dest, = insn.args.split(/\s+/, 2)
      dest_reg = dest[/^R(\d+)/, 1]
      next unless dest_reg

      name = insn.args[/:([\w+\-*\/<>=!?\[\]&|^~%@]+)/, 1]
      next unless name

      if n_match[1] == '*'
        regions << { sendb_addr: insn.addr, dest_reg: dest_reg, n: '*',
                     argv_reg: (dest_reg.to_i + 1).to_s,
                     blk_reg: (dest_reg.to_i + 2).to_s, name: name,
                     self_implicit: insn.op == 'SSENDB' }
      else
        n = n_match[1].to_i
        regions << { sendb_addr: insn.addr, dest_reg: dest_reg, n: n,
                     blk_reg: (dest_reg.to_i + n + 1).to_s, name: name,
                     self_implicit: insn.op == 'SSENDB' }
      end
    end
    regions
  end

  def emit_explicit_block_arg_glue(region)
    dest_reg = region[:dest_reg].to_i
    recv = region[:self_implicit] ? 'self' : "r#{dest_reg}"
    out = String.new
    out << "  // EXPLICIT_BLOCK_ARG :#{region[:name]} -- &expr forwarded directly as the block " \
           "(mrb_funcall_with_block's own ensure_block coerces Symbol/Proc/anything with #to_proc), dynamic dispatch\n"
    out << "  {\n  Bc2cppVmMark bc2cpp_brk_mark = bc2cpp_vm_mark(M);\n  try {\n"
    if region[:n] == '*'
      # EXPLICIT_BLOCK_ARG_DYNAMIC_SPLAT_SUPPORT: R(dest+1) is a real Array, so
      # RARRAY_LEN/RARRAY_PTR go straight into mrb_funcall_with_block.
      out << "    r#{dest_reg} = mrb_funcall_with_block(M, #{recv}, mrb_intern_cstr(M, \"#{region[:name]}\"), " \
             "RARRAY_LEN(r#{region[:argv_reg]}), RARRAY_PTR(r#{region[:argv_reg]}), r#{region[:blk_reg]});\n"
    else
      argv = (1..region[:n]).map { |k| "r#{dest_reg + k}" }
      if argv.empty?
        out << "    r#{dest_reg} = mrb_funcall_with_block(M, #{recv}, mrb_intern_cstr(M, \"#{region[:name]}\"), 0, NULL, " \
               "r#{region[:blk_reg]});\n"
      else
        out << "    mrb_value bc2cpp_ebarg_argv_#{region[:sendb_addr]}[] = { #{argv.join(', ')} };\n"
        out << "    r#{dest_reg} = mrb_funcall_with_block(M, #{recv}, mrb_intern_cstr(M, \"#{region[:name]}\"), " \
               "#{argv.size}, bc2cpp_ebarg_argv_#{region[:sendb_addr]}, r#{region[:blk_reg]});\n"
      end
    end
    out << "  } catch (bc2cpp_block_break& bc2cpp_brk) {\n"
    out << "    bc2cpp_vm_restore(M, bc2cpp_brk_mark);\n"
    out << "    r#{dest_reg} = bc2cpp_brk.value;\n"
    out << "  }\n"
    out << "  }\n"
    out
  end

  # RESCUE_BODY_BLOCK_SUPPORT: the shared BLOCK_FALLBACK/EXPLICIT_BLOCK_ARG
  # suppress-and-glue pass, used by compile_method and emit_rescue_try_body.
  # Takes recognized region lists (the caller chooses the scope), mutates the
  # caller's suppressed/glue_at, and returns the nested-function pre-code.
  def emit_block_fallback_glue_pass(block_regions, explicit_arg_regions, d, suppressed, glue_at)
    pre = String.new
    block_regions.each do |region|
      next if suppressed.include?(region[:block_addr]) || suppressed.include?(region[:sendb_addr])

      fn_result = emit_proc_fallback_fn(region, d)
      next unless fn_result

      fn_name, fn_code = fn_result
      pre << fn_code
      suppressed << region[:block_addr] << region[:sendb_addr]
      glue_at[region[:block_addr]] = emit_block_fallback_glue(region, fn_name)
    end
    explicit_arg_regions.each do |region|
      next if suppressed.include?(region[:sendb_addr])

      suppressed << region[:sendb_addr]
      glue_at[region[:sendb_addr]] = emit_explicit_block_arg_glue(region)
    end
    pre
  end

  # LAMBDA_FALLBACK_SUPPORT: `LAMBDA Ra I[b]` (ops.h `R[a] =
  # lambda(Irep[b],L_LAMBDA)`) whose body is lambda_fallback_safe?: a
  # one-instruction region that only builds the proc.
  # CONFINED_LAMBDA_UPVAR_SUPPORT: `available_upvars` as in
  # recognize_block_fallback_regions (empty at method level).
  def recognize_lambda_fallback_regions(irep, available_upvars: [])
    regions = []
    irep.instructions.each do |insn|
      next unless insn.op == 'LAMBDA'

      dest_reg = insn.args[/^R(\d+)/, 1]
      next unless dest_reg

      lambda_irep_idx = insn.args[/I\[(\d+)\]/, 1]
      next unless lambda_irep_idx

      lambda_label = irep.reps[lambda_irep_idx.to_i]
      lambda_irep = lambda_label && @ireps[lambda_label]
      next unless lambda_irep && lambda_fallback_safe?(lambda_irep)

      # CONFINED_LAMBDA_UPVAR_SUPPORT: what does the body need captured
      # (block_upvar_needs), can this level supply it, and (lambda-specific) does
      # the proc provably never escape this frame?
      upvars = block_upvar_needs(lambda_irep)
      next if upvars.nil?
      next unless upvars.all? { |(l, x)| l.zero? || available_upvars.include?([l - 1, x]) }

      call_sites = lambda_confined_call_sites(irep, insn, dest_reg.to_i, lambda_irep)
      next if upvars.any? && call_sites.nil?

      regions << { block_addr: insn.addr, dest_reg: dest_reg, block_irep: lambda_irep,
                   kind: 'lambda_fallback', upvars: upvars, call_sites: call_sites || [] }
    end
    regions
  end

  # CONFINED_LAMBDA_UPVAR_SUPPORT: prove the proc built by `LAMBDA R<d> I[n]`
  # never leaves this frame (never returned, stored or passed on), so the
  # captured `&r<b>` pointers cannot dangle. Anything not accounted for declines
  # (`#error`). The recognized shape (RPG2k::Scene::Menu#draw_status_row, `line =
  # ->(n) { y + n * LINE_H }` then three `line.call(k)`):
  #
  #     531 013 LAMBDA  R6   I[0]
  #     532 022 MOVE    R12  R6      ; R6:line
  #     532 025 LOADI_0 R13  (0)
  #     532 027 SEND    R12  :call   n=1
  #     534 058 MOVE    R9   R6      ; R6:line
  #     534 061 LOADI_1 R10  (1)
  #     534 063 SEND    R9   :call   n=1
  #     541 204 MOVE    R9   R6      ; R6:line
  #     541 207 LOADI_2 R10  (2)
  #     541 209 SEND    R9   :call   n=1
  #
  # Three gates:
  # (1) `d` is a named local (1 <= d < nlocals). mrbc's allocator keeps
  #     temporaries above nlocals (codegen.c push_n_/pop_n_), so no opcode's
  #     implicit register window (`SEND Ra n=N` reading Ra+1..Ra+N, ARRAY, ...)
  #     reaches a named local; every use of R<d> is printed, and `\bR<d>\b`
  #     finds them all.
  # (2) No ARGARY or BLKPUSH in the enclosing irep: they read parameter slots
  #     (named locals) without printing them (vm.c `stack[m1+r+m2]`,
  #     `regs[a] = stack[offset]`), so gate (1) cannot cover them.
  # (3) Every other use of R<d> is `MOVE R<t> R<d>` consumed, on a straight-line
  #     stretch, as the receiver of `:call`. Proc#call is mruby's static
  #     call_proc (one OP_CALL, proc.c mrb_init_proc): synchronous, never
  #     retains the proc, and the SEND overwrites R<t>. R<t> is a temporary, so
  #     an intervening implicit window could cover it (`SSEND R9
  #     :draw_system_text n=7` reads R9..R16); hence only whitelisted opcodes
  #     that touch just the registers they print may sit between.
  LAMBDA_CONFINED_CALL_SETUP_OPS = %w[
    LOADI LOADI_0 LOADI_1 LOADI_2 LOADI_3 LOADI_4 LOADI_5 LOADI_6 LOADI_7
    LOADI__1 LOADI8 LOADI16 LOADI32 LOADINEG LOADL LOADL16
    LOADSYM LOADSYM16 LOADNIL LOADSELF LOADTRUE LOADFALSE
    STRING STRING16 MOVE GETIV GETGV GETCV GETCONST GETMCNST GETUPVAR
    ADDI SUBI
  ].freeze

  #
  # Returns the `.call` sites ({ send_addr:, dest_reg:, n: }) or nil; the
  # emitter needs them (see emit_lambda_confined_call_glue).
  def lambda_confined_call_sites(irep, lambda_insn, d, lambda_irep)
    nlocals = irep.nlocals.to_i
    # (1) a named local, so no implicit register window can alias it.
    return nil unless d >= 1 && d < nlocals
    # (2) the two opcodes that read a named local without printing it.
    return nil if irep.instructions.any? { |i| %w[ARGARY BLKPUSH].include?(i.op) }

    # A child irep capturing R<d> as an upvar would point at it from a scope this
    # proof does not cover; block_upvar_needs propagates deeper needs as
    # [level - 1, idx], so [0, d] covers any depth.
    return nil if (irep.reps || []).any? do |child_label|
      child = child_label && @ireps[child_label]
      needs = child && block_upvar_needs(child)
      needs.nil? || needs.include?([0, d])
    end

    mand = mandatory_arity(lambda_irep)
    sites = []
    insns = irep.instructions
    insns.each_with_index do |insn, i|
      next if insn.equal?(lambda_insn)
      next unless insn.args =~ /\bR#{d}\b/

      # (3) the only permitted consumer: `MOVE R<t> R<d>` into a temporary.
      m = insn.op == 'MOVE' && insn.args.match(/\AR(\d+)\s+R#{d}\b/)
      return nil unless m

      t = m[1].to_i
      return nil unless t >= nlocals

      site = lambda_confined_call_consumes?(irep, i, t)
      return nil unless site
      # A lambda is strict about arity; the direct call cannot raise ArgumentError,
      # so a count other than the lambda's mandatory arity declines.
      return nil unless site[:n] == mand

      sites << site
    end
    sites
  end

  # CONFINED_LAMBDA_UPVAR_SUPPORT: gate (3)'s straight-line half: walk from the
  # MOVE at `i` to the consuming `SEND`/`SEND0 R<t> :call`, allowing only
  # whitelisted setup opcodes, with no jump inside the stretch and no jump target
  # inside it. Then "after the MOVE, the next use of R<t> is the :call receiver,
  # which overwrites it" holds on every execution.
  # Returns { send_addr:, dest_reg:, n: } or nil.
  def lambda_confined_call_consumes?(irep, i, t)
    insns = irep.instructions
    targets = jump_targets(irep)
    ((i + 1)...insns.size).each do |j|
      nxt = insns[j]
      if %w[SEND SEND0].include?(nxt.op) &&
         (m = nxt.args.match(/\AR#{t}\s+:call(?:\s+n=(\d+))?(?:\s|\z)/))
        return { send_addr: nxt.addr, dest_reg: t, n: m[1].to_i }
      end

      return nil unless LAMBDA_CONFINED_CALL_SETUP_OPS.include?(nxt.op)
      return nil if nxt.args =~ /\bR#{t}\b/
      return nil if targets.include?(nxt.addr)
    end
    nil
  end

  # CONFINED_LAMBDA_UPVAR_SUPPORT: a confined `.call` becomes a DIRECT call to
  # the lambda body's `_impl`, never mrb_funcall(..., "call"). This is required:
  # Proc#call is call_proc (one OP_CALL), and vm.c OP_CALL's cfunc branch ends
  # with
  #
  #     ci = cipop(mrb);
  #     ci[1].stack[0] = recv;
  #     irep = ci->proc->body.irep;     /* <-- unconditional deref */
  #
  # When the caller is a C frame (a compiled method registered with
  # mrb_define_method), `ci->proc` is NULL (mrb_funcall_with_block sets
  # `ci->proc = MRB_METHOD_PROC_P(m) ? MRB_METHOD_PROC(m) : NULL`), so this
  # segfaults.
  # The confinement proof supplies everything the direct call needs: the
  # receiver is this lambda, self is the same local captured into env slot 0,
  # the upvar pointers are the same expressions in the same order, and the
  # arguments are R<t+1>..R<t+n> with n equal to the arity. The RProc is still
  # built and stored into R<d>, so the register holds a real Proc.
  def emit_lambda_confined_call_glue(region, fn_name, site)
    dest = site[:dest_reg]
    args = (1..site[:n]).map { |k| "r#{dest + k}" }
    upvar_args = (region[:upvars] || []).map do |(l, b)|
      l.zero? ? "&r#{b}" : upvar_var_name(l - 1, b)
    end
    out = String.new
    out << "  // CONFINED_LAMBDA_CALL -- provably this frame's own lambda (never escapes); " \
           "direct C++ call, not mrb_funcall(:call)\n"
    out << "  r#{dest} = #{fn_name}_impl(M, self#{(upvar_args + args).map { |x| ", #{x}" }.join});\n"
    out
  end

  # LAMBDA_FALLBACK_SUPPORT: build the RProc (emit_rproc_construction) and store
  # it (`mrb_obj_value`); a LAMBDA calls nothing.
  # CONFINED_LAMBDA_UPVAR_SUPPORT: region[:upvars] uses the same construction;
  # non-empty only for a frame-confined lambda.
  def emit_lambda_fallback_glue(region, fn_name)
    dest_reg = region[:dest_reg].to_i
    rproc_var, ctor = emit_rproc_construction(region[:block_addr], fn_name, region[:upvars] || [])
    out = String.new
    out << "  // LAMBDA_FALLBACK -- lambda body compiled as a standalone cfunc, wrapped as a real RProc " \
           "(self captured at construction time), stored -- not dispatched\n"
    out << "  {\n"
    out << ctor
    out << "    r#{dest_reg} = mrb_obj_value(#{rproc_var});\n"
    out << "  }\n"
    out
  end

  # RUNTIME_DEF_FALLBACK_SUPPORT: parse `SDEF R3 :read I[0]` / `TDEF R1 :update
  # I[0]` (both `"%cDEF\t\tR%d\t:%s\tI[%d]\n"`, src/codedump.c) into a region.
  # nil (keep `#error`) for an unmatched line, a child index not in reps[], or a
  # non-mandatory body (runtime_def_body_safe?).
  def runtime_def_region(insn, irep, kind)
    m = insn.args.match(/\AR(\d+)\s+:(\S+)\s+I\[(\d+)\]\z/)
    return nil unless m

    child_label = irep.reps[m[3].to_i]
    return nil unless child_label

    child = @ireps[child_label]
    return nil unless child && runtime_def_body_safe?(child)

    # RUNTIME_DEF_FALLBACK_SUPPORT: the enclosing irep's nregs, so
    # emit_runtime_def_install can tell whether the `a` register exists (it may
    # not; see there).
    { block_irep: child, block_addr: insn.addr, kind: kind, self_source: :receiver,
      dest_reg: m[1].to_i, name: m[2], mand: mandatory_arity(child),
      enclosing_nregs: irep.nregs.to_i }
  end

  def tdef_fallback_region(insn, irep)
    runtime_def_region(insn, irep, 'tdef_fallback')
  end

  # RUNTIME_DEF_DEVIRT_GUARD: class-body sends whose installed names can be read
  # from literal Symbol arguments. Anything else installs an unknown set (see
  # class_body_installed_names).
  CLASS_BODY_INSTALLER_SENDS = {
    'alias_method' => :alias,
    'attr_reader' => :reader,
    'attr_writer' => :writer,
    'attr_accessor' => :accessor
  }.freeze

  # RUNTIME_DEF_DEVIRT_GUARD: opcodes that touch no method table. An allowlist, so
  # an unconsidered opcode lands on "unknown", the safe side.
  CLASS_BODY_INERT_OPS = %w[LOADSYM MOVE LOADNIL LOADSELF ENTER JMP RETURN].freeze

  # RUNTIME_DEF_DEVIRT_GUARD: the `n` literal Symbol arguments of a class-body
  # send, from the `LOADSYM R(dest+k) :name` instructions right before it
  # (`alias_method :a, :b`, `attr_accessor :x`). nil unless the whole set is
  # literal.
  def literal_symbol_args(irep, idx, dest, n)
    return [] if n.zero?
    return nil if idx < n

    # Exactly the n instructions immediately before the send, in ascending
    # register order; a loose search would have to prove nothing in between (e.g.
    # a MOVE) clobbered the register. mrbc emits:
    #
    #   000 LOADSYM R2 :_probe_update
    #   003 LOADSYM R3 :update
    #   006 SSEND   R1 :alias_method  n=2
    #
    # Anything else is nil ("unknown").
    (1..n).map do |k|
      insn = irep.instructions[idx - n + k - 1]
      return nil unless insn && insn.op == 'LOADSYM'

      m = insn.args.to_s.match(/\AR(\d+)\s+:(\S+)\z/)
      return nil unless m && m[1].to_i == dest + k

      m[2]
    end
  end

  # RUNTIME_DEF_DEVIRT_GUARD: every name an EXEC-opened class body installs, or
  # nil ("cannot be bounded").
  # A method installed on an object's SINGLETON class at runtime is invisible to
  # mrb_obj_class (`mrb_class_real(mrb_class(mrb, obj))`, src/class.c, skips
  # SCLASS), so MONO calls, POLY_SMALL_N chains, TYPED and ivar-accessor inlines
  # would call the class's implementation for a patched receiver (`class << a;
  # alias_method :_orig, :shared_name; def shared_name; ...; end; end;
  # a.shared_name` returned the unpatched result when compiled). Compiling the
  # patching method is what exposes this, so it is guarded here, per name: only
  # names the method may install are blocked. nil blocks every name in the
  # method, which still compiles, fully dynamic.
  # Scope: a devirtualized call in some OTHER compiled method can still miss a
  # runtime singleton patch; that is a general limitation, not introduced here.
  def class_body_installed_names(body)
    names = Set.new
    body.instructions.each_with_index do |insn, idx|
      case insn.op
      when 'TDEF'
        m = insn.args.match(/\AR\d+\s+:(\S+)\s+I\[\d+\]\z/)
        return nil unless m

        names << m[1]
      when 'SSEND', 'SSEND0'
        m = insn.args.match(/\AR(\d+)\s+:(\S+?)(?:\s+n=(\d+))?\z/)
        return nil unless m

        kind = CLASS_BODY_INSTALLER_SENDS[m[2]]
        return nil unless kind

        syms = literal_symbol_args(body, idx, m[1].to_i, m[3].to_i)
        return nil unless syms && !syms.empty?

        case kind
        # alias_method(new_name, old_name) installs the FIRST argument
        # (mrb_alias_method).
        when :alias then names << syms.first
        when :reader then names.merge(syms)
        when :writer then names.merge(syms.map { |s| "#{s}=" })
        when :accessor then names.merge(syms).merge(syms.map { |s| "#{s}=" })
        end
      else
        return nil unless CLASS_BODY_INERT_OPS.include?(insn.op)
      end
    end
    names
  end

  # RUNTIME_DEF_DEVIRT_GUARD: every name this method may install at runtime
  # (SDEF names plus EXEC class bodies), or nil if any body is unbounded.
  def runtime_installed_names_for(irep, exec_regions)
    names = Set.new
    irep.instructions.each do |insn|
      next unless insn.op == 'SDEF'

      m = insn.args.match(/\AR\d+\s+:(\S+)\s+I\[\d+\]\z/)
      return nil unless m

      names << m[1]
    end
    exec_regions.each do |region|
      body_names = class_body_installed_names(region[:block_irep])
      return nil unless body_names

      names.merge(body_names)
    end
    names
  end

  # RUNTIME_DEF_DEVIRT_GUARD: may `name` be bound statically in the method being
  # compiled? Always true unless the method patches at runtime
  # (@runtime_installed_names non-nil).
  def devirt_blocked_name?(name)
    return false unless @runtime_installed_names
    return true if @runtime_installed_names == :unknown

    @runtime_installed_names.include?(name.to_s)
  end

  # RUNTIME_DEF_DEVIRT_GUARD: marker kinds that are real dynamic dispatch (runtime
  # lookup honours a singleton patch). Every other `// KIND :name` marker is
  # audited as a static bind, so a new marker kind defaults to the safe side.
  RUNTIME_DEF_DYNAMIC_MARKERS = %w[
    POLY SPLAT KEYWORD_HASH_POSITIONAL EXPLICIT_BLOCK_ARG
    BLOCK_FALLBACK LAMBDA_FALLBACK SDEF_FALLBACK TDEF_FALLBACK
    SCLASS_FALLBACK
  ].freeze

  # RUNTIME_DEF_DEVIRT_GUARD, second line of defense: re-read the FINISHED text of
  # the method and turn any static bind of a blocked name into `#error` (so
  # SKIP_UNSUPPORTED drops the method). Reading the emitted text cannot drift
  # from what codegen did, so a path that bypasses devirt_blocked_name? is still
  # caught. Returns "" for methods that install nothing.
  def runtime_def_devirt_audit(code)
    return '' unless @runtime_installed_names

    # `/` is part of the kind (`IVAR_ACCESSOR/ELEMENT`); stopping at it would skip
    # the line. Compound kinds are not in RUNTIME_DEF_DYNAMIC_MARKERS, so they are
    # audited.
    offenders = code.scan(%r{^\s*// ([A-Z][A-Z_0-9/]*) :(\S+?)(?:\s|,|$)}).reject do |kind, _name|
      RUNTIME_DEF_DYNAMIC_MARKERS.include?(kind)
    end.select { |_kind, name| devirt_blocked_name?(name) }
    return '' if offenders.empty?

    offenders.uniq.map do |kind, name|
      "  #error #{kind} devirtualization of :#{name}, which this method installs on a runtime " \
        "singleton class -- not in this prototype's supported subset\n"
    end.join
  end

  def sdef_fallback_region(insn, irep)
    runtime_def_region(insn, irep, 'sdef_fallback')
  end

  # RUNTIME_DEF_FALLBACK_SUPPORT: the install for SDEF and TDEF.
  # `mrb_define_method_id(M, tc, mid, fn, MRB_ARGS_REQ(n))` is equivalent to
  # OP_SDEF/OP_TDEF (checked against src/class.c mrb_define_method_raw):
  #   * Visibility: the VM passes MRB_METHOD_VDEFAULT_FL, this passes PUBLIC.
  #     mrb_define_method_raw's first branch is `if (c->tt == MRB_TT_SCLASS)
  #     MRB_SET_VISIBILITY_FLAGS(flags, MRB_METHOD_PUBLIC_FL);`, and every
  #     target here is a singleton class (SDEF by definition; TDEF only from an
  #     SCLASS body). A TDEF in a plain `class Foo` body would consult the
  #     `private`/`public` scope, one reason EXEC support is SCLASS-only.
  #   * initialize/initialize_copy/respond_to_missing? are forced private by
  #     mrb_define_method_raw on both paths.
  #   * Arity: MRB_ARGS_REQ(n) matches the entry's `mrb_get_args(M, "o"*n)`;
  #     runtime_def_body_safe? refused anything else.
  # The method_added hook: OP_SDEF/OP_TDEF call mrb_method_added, which is not
  # MRB_API (internal.h), so its SCLASS arm is reproduced with public API:
  #
  #   added = (c->tt == MRB_TT_SCLASS) ? singleton_method_added : method_added;
  #   recv  = (c->tt == MRB_TT_SCLASS) ? mrb_iv_get(.., c, __attached__) : c;
  #   if (!mrb_func_basic_p(mrb, recv, added, mrb_do_nothing))
  #     mrb_funcall_argv(mrb, recv, added, 1, &sym);
  #
  # The mrb_func_basic_p guard is dropped: it only skips a call to
  # mrb_do_nothing (`{ return mrb_nil_value(); }`, the default
  # BasicObject#singleton_method_added), so calling it anyway gives the same
  # state, and an overridden hook is invoked as the interpreter would.
  # mrb_funcall_argv does no visibility check, which matters because the hooks
  # are MRB_MT_PRIVATE.
  # Inherent difference: the installed body is a cfunc, not a bytecode RProc (as
  # for every compiled method).
  def emit_runtime_def_install(target_class_expr, region, fn_name, indent)
    tc_var = "bc2cpp_def_tc_#{region[:block_addr]}"
    mid_var = "bc2cpp_def_mid_#{region[:block_addr]}"
    sym_var = "bc2cpp_def_sym_#{region[:block_addr]}"
    out = String.new
    # Bound to a local: the expression may have a side effect
    # (mrb_singleton_class creates the singleton class), and the hook needs the
    # same class.
    out << "#{indent}struct RClass* #{tc_var} = #{target_class_expr};\n"
    out << "#{indent}mrb_sym #{mid_var} = mrb_intern_cstr(M, \"#{region[:name]}\");\n"
    out << "#{indent}mrb_define_method_id(M, #{tc_var}, #{mid_var}, #{fn_name}, " \
           "MRB_ARGS_REQ(#{region[:mand]}));\n"
    out << "#{indent}mrb_value #{sym_var} = mrb_symbol_value(#{mid_var});\n"
    out << "#{indent}mrb_funcall_argv(M, mrb_iv_get(M, mrb_obj_value(#{tc_var}), " \
           "mrb_intern_cstr(M, \"__attached__\")), mrb_intern_cstr(M, \"singleton_method_added\"), " \
           "1, &#{sym_var});\n"
    # Both opcodes leave the method name Symbol in `a` (vm.c `regs[a] =
    # mrb_symbol_value(mid);`), written after the hook as vm.c does. It is skipped
    # only when `a` is at or beyond the enclosing irep's nregs, which mrbc really
    # emits for a class body whose only statement is a def:
    #
    #   irep ... nregs=1 nlocals=1 pools=0 syms=1 reps=1 ilen=6
    #     000 TDEF  R1  :who  I[0]
    #     004 RETURN  R0
    #
    # The interpreter has slack from OP_EXEC's stack_extend, but compiled code
    # declares exactly nregs locals (writing R1 would not compile). Lossless:
    # nregs bounds every register the irep can read.
    if region[:dest_reg] < region[:enclosing_nregs].to_i
      out << "#{indent}r#{region[:dest_reg]} = #{sym_var};\n"
    else
      out << "#{indent}(void)#{sym_var}; // R#{region[:dest_reg]} is past the enclosing irep's " \
             "nregs=#{region[:enclosing_nregs]} -- dead by construction, see above\n"
    end
    out
  end

  # SDEF_FALLBACK: `def archive.read(name); ...; end` installs on one object's
  # singleton class. vm.c OP_SDEF: `struct RClass *tc =
  # mrb_class_ptr(mrb_singleton_class(mrb, regs[a]));` then install.
  # mrb_singleton_class (public) raises TypeError for objects that cannot have
  # one (Integer, Symbol, Float), so it is used rather than the non-raising
  # _ptr variant. No class body, RProc or VM frame is involved.
  def emit_sdef_fallback_glue(region, fn_name)
    out = String.new
    out << "  // SDEF_FALLBACK :#{region[:name]} -- singleton method body compiled as a standalone cfunc, " \
           "installed on the receiver's real runtime singleton class\n"
    out << "  {\n"
    out << emit_runtime_def_install("mrb_class_ptr(mrb_singleton_class(M, r#{region[:dest_reg]}))",
                                     region, fn_name, '    ')
    out << "  }\n"
    out
  end

  # TDEF_FALLBACK: a def in an EXEC-opened class body. OP_TDEF installs onto
  # check_target_class(mrb), which in an OP_EXEC body is the same object as self
  # (see emit_proc_fallback_fn's self_source), so mrb_class_ptr(self) is exact.
  # check_target_class's NULL case cannot occur: emit_exec_fallback_glue sets the
  # target class.
  def emit_tdef_fallback_glue(region, fn_name)
    out = String.new
    out << "  // TDEF_FALLBACK :#{region[:name]} -- `def` inside a class-reopen body, compiled as a standalone " \
           "cfunc, installed on this body's own target class (== self, per OP_EXEC)\n"
    out << "  {\n"
    out << emit_runtime_def_install('mrb_class_ptr(self)', region, fn_name, '    ')
    out << "  }\n"
    out
  end

  # SCLASS_FALLBACK + EXEC_FALLBACK: `class << Graphics; alias_method
  # :_probe_update, :update; def update; ...; end; end` inside a method body
  # (RGSS.singleton#effect_probe). Only `SCLASS Ra` immediately followed by `EXEC
  # Ra I[c]` on the same register (codegen.c's NODE_SCLASS arm).
  # Not CLASS/MODULE+EXEC: a TDEF there resolves visibility against the
  # enclosing scope (not reproduced by the public install), and CLASS/MODULE
  # create a constant the registry cannot learn about. Neither occurs here.
  # The body is compiled by emit_proc_fallback_fn, so sends (alias_method,
  # attr_*, include, private, ...), nested blocks and rescue regions work as in
  # a block body; `def` is added by its TDEF pass.
  def recognize_exec_fallback_regions(irep)
    regions = []
    irep.instructions.each_with_index do |insn, idx|
      next unless insn.op == 'SCLASS'

      nxt = irep.instructions[idx + 1]
      next unless nxt && nxt.op == 'EXEC'

      reg = insn.args[/\AR(\d+)\z/, 1]
      m = nxt.args.match(/\AR(\d+)\s+I\[(\d+)\]\z/)
      next unless reg && m && m[1] == reg

      child_label = irep.reps[m[2].to_i]
      next unless child_label

      child = @ireps[child_label]
      next unless child

      regions << { block_irep: child, block_addr: insn.addr, exec_addr: nxt.addr,
                   kind: 'exec_fallback', self_source: :receiver, dest_reg: reg.to_i }
    end
    regions
  end

  # SCLASS_FALLBACK + EXEC_FALLBACK glue, translated together:
  #   OP_SCLASS: `regs[a] = mrb_singleton_class(mrb, regs[a]);`, verbatim.
  #   OP_EXEC: run the body with target class and self set to that singleton
  #   class. mrb_yield_with_class (public) does exactly that: yield_with_attr
  #   sets `ci->u.target_class = c; ci->proc = p;` and, for a cfunc proc,
  #   `ci->stack[0] = self; val = MRB_PROC_CFUNC(p)(mrb, self);`. Pushing a real
  #   frame is what makes `private`/`public`/`module_function` in the body see
  #   the right scope (class.c find_visibility_scope reads
  #   mrb_vm_ci_target_class(ci)).
  # MRB_PROC_SCOPE needs no analogue: check_visibility_break treats a SCOPE proc
  # and a proc with no `upper` alike (cfunc procs have none), and OP_RETURN's
  # scope unwinding has no bytecode frame here. mrb_yield_with_class returns the
  # body's value, which is EXEC's result.
  def emit_exec_fallback_glue(region, fn_name)
    dest_reg = region[:dest_reg]
    sc_var = "bc2cpp_sclass_#{region[:block_addr]}"
    proc_var = "bc2cpp_exec_proc_#{region[:block_addr]}"
    out = String.new
    out << "  // SCLASS_FALLBACK + EXEC_FALLBACK -- `class << recv` body compiled as a standalone cfunc, " \
           "executed against the real runtime singleton class (self == target class, per OP_EXEC)\n"
    out << "  {\n"
    out << "    mrb_value #{sc_var} = mrb_singleton_class(M, r#{dest_reg});\n"
    out << "    struct RProc* #{proc_var} = mrb_proc_new_cfunc(M, #{fn_name});\n"
    out << "    r#{dest_reg} = mrb_yield_with_class(M, mrb_obj_value(#{proc_var}), 0, NULL, " \
           "#{sc_var}, mrb_class_ptr(#{sc_var}));\n"
    out << "  }\n"
    out
  end

  # `idx` is the instruction's position in irep.instructions (for the backward
  # proofs). `reg_offset` is non-zero only for compile_block_body_insn's shifted
  # registers and is undone with unshift_proof_reg wherever a register reaches a
  # proof rather than the output.
  def compile_insn(insn, irep, owner_def, idx = nil, reg_offset = 0)
    a = insn.args
    case insn.op
    when 'ENTER'
      "  // #{insn.raw.strip} (args already bound above)\n"
    when 'GETUPVAR', 'SETUPVAR'
      # UPVAR_CAPTURE_SUPPORT: only reached inside a BLOCK_FALLBACK body
      # (@block_fallback_upvars set for that loop); method ireps have no
      # GETUPVAR/SETUPVAR, and inlined block bodies use compile_block_body_insn.
      # `GETUPVAR R3 4 0`: `upvar_idx` is the defining frame's register (vm.c
      # `e->stack[b]`).
      # DEEP_UPVAR_CAPTURE_SUPPORT: matched on the [level, index] pair against the
      # captured set this function declares parameters for; anything else keeps
      # `#error`. The access is the same at every level: an mrb_value* to the
      # defining frame's register.
      reg, upvar_idx, level = a.split(/\s+/)
      key = [level.to_i, upvar_idx.to_i]
      if level =~ /\A\d+\z/ && @block_fallback_upvars&.include?(key)
        vname = upvar_var_name(*key)
        if insn.op == 'GETUPVAR'
          "  r#{reg[/\d+/]} = *#{vname};\n"
        else
          "  *#{vname} = r#{reg[/\d+/]};\n"
        end
      else
        "  #error unhandled opcode #{insn.op} -- not in this prototype's supported subset\n"
      end
    when 'KEY_P'
      # KEYWORD_ARG_SUPPORT: presence of an optional keyword: a bool parameter the
      # entry wrapper computed, named from `:sym` (kwarg_param_name).
      d = a[/^R(\d+)/, 1]
      sym = a[/:(\S+)/, 1]
      "  r#{d} = mrb_bool_value(#{kw_given_param_name(sym)});\n"
    when 'KARG'
      # KEYWORD_ARG_SUPPORT: the keyword's value, already an unpacked parameter. An
      # omitted optional one's default code overwrites the register after KEY_P's
      # JMPIF.
      d = a[/^R(\d+)/, 1]
      sym = a[/:(\S+)/, 1]
      "  r#{d} = #{kwarg_param_name(sym)};\n"
    when 'KEYEND'
      # KEYWORD_ARG_SUPPORT: unknown keywords already raised ArgumentError in the
      # entry wrapper's mrb_kwargs (`rest: NULL`).
      "  // KEYEND: already enforced by the entry wrapper's own mrb_kwargs (rest: NULL)\n"
    when 'MOVE'
      d, s = regs(a, 2)
      "  r#{d} = r#{s};\n"
    when 'LOADNIL'
      d, = regs(a, 1)
      "  r#{d} = mrb_nil_value();\n"
    when 'LOADFALSE'
      d, = regs(a, 1)
      "  r#{d} = mrb_false_value();\n"
    when 'LOADTRUE'
      d, = regs(a, 1)
      "  r#{d} = mrb_true_value();\n"
    when 'LOADSELF'
      # "LOADSELF R2 (R0)": R[a] = self (vm.c). Emitted for `self.foo = ...`; r0 is
      # already `self`.
      d, = regs(a, 1)
      "  r#{d} = self;\n"
    when 'LOADSYM'
      d = a[/^R(\d+)/, 1]
      name = a[/:(\S+)/, 1]
      "  r#{d} = mrb_symbol_value(mrb_intern_cstr(M, \"#{name}\"));\n"
    when /^LOADI/
      d = a[/^R(\d+)/, 1]
      # Small immediates print parenthesized ("R6\t(3)"); LOADI8/16/32 print bare
      # ("R1\t128").
      lit = a[/\(([^)]+)\)/, 1] || a[/^R\d+\s+(-?\d+)/, 1]
      "  r#{d} = mrb_fixnum_value(#{lit});\n"
    when 'LOADL'
      # "LOADL R5 L[0]": a pool literal (vm.c OP_LOADL). Only FLOAT is modelled:
      # mrbc's C dump prints it as a valid C double literal (".f=0.33000000000000002").
      # INT32/INT64/BIGINT are not decoded and keep `#error`.
      d = a[/^R(\d+)/, 1]
      pidx = a[/L\[(\d+)\]/, 1].to_i
      entry = irep.pool.fetch(pidx)
      if entry.is_a?(Hash) && entry[:type] == :float
        lit = entry[:raw][/\.f\s*=\s*(.+)/, 1]
        "  r#{d} = mrb_float_value(M, #{lit});\n"
      else
        kind = entry.is_a?(Hash) ? entry[:type] : :string
        "  #error LOADL references a non-float pool entry (#{kind}) -- not in this prototype's supported subset\n"
      end
    when 'STRING'
      d = a[/^R(\d+)/, 1]
      idx = a[/L\[(\d+)\]/, 1].to_i
      entry = irep.pool.fetch(idx)
      if entry.is_a?(String)
        "  r#{d} = mrb_str_new_cstr(M, #{c_string_literal(entry)});\n"
      else
        "  #error STRING references a non-string pool entry (#{entry[:type]}) -- not in this prototype's supported subset\n"
      end
    when 'SYMBOL'
      # "SYMBOL R2 L[0] ; atk_mod": ops.h `R[a] = intern(Pool[b])`, unlike LOADSYM,
      # which carries an interned symbol. Same `L[idx]` pool read as STRING
      # (codedump.c), interned with mrb_intern_cstr. mrbc emits it for `%i[...]`
      # literals (gen_literal_array: each word is an OP_STRING that gen_intern's
      # peephole turns into SYMBOL, followed by ARRAY(N)); `:foo` / `:"foo"` are
      # interned at parse time into LOADSYM.
      d = a[/^R(\d+)/, 1]
      sidx = a[/L\[(\d+)\]/, 1].to_i
      sentry = irep.pool.fetch(sidx)
      if sentry.is_a?(String)
        "  r#{d} = mrb_symbol_value(mrb_intern_cstr(M, #{c_string_literal(sentry)}));\n"
      else
        "  #error SYMBOL references a non-string pool entry (#{sentry[:type]}) -- not in this prototype's supported subset\n"
      end
    when 'INTERN'
      # "INTERN R<a>": vm.c `mrb_ensure_string_type(mrb, regs[a]); mrb_sym sym =
      # mrb_intern_str(mrb, regs[a]); regs[a] = mrb_symbol_value(sym);`, an in-place
      # String -> Symbol conversion (`:"#{expr}"`). Unconditional, like STRCAT.
      d = a[/^R(\d+)/, 1]
      "  r#{d} = mrb_ensure_string_type(M, r#{d});\n  r#{d} = mrb_symbol_value(mrb_intern_str(M, r#{d}));\n"
    when 'STRCAT'
      # Matches OP_STRCAT's own real semantics exactly (src/vm.c):
      # mrb_ensure_string_type then mrb_str_concat (mutates r<d> in place).
      d = a[/^R(\d+)/, 1]
      s = a[/\(R(\d+)\)/, 1]
      "  r#{d} = mrb_ensure_string_type(M, r#{d});\n  mrb_str_concat(M, r#{d}, r#{s});\n"
    when 'GETIV'
      d = a[/^R(\d+)/, 1]
      ivar = a[/@(\w+)/, 1]
      klass = self_class(owner_def)
      code = ivar_get_code(klass, 'self', ivar, "r#{d}", self_of_klass: true)
      type = embed_type(klass, ivar) if klass
      if code.nil?
        "  #error GETIV @#{ivar}: self's class is unknown here and some class embeds @#{ivar}\n"
      elsif type
        "  // @#{ivar} embedded (#{type}) -- direct struct field read, no mrb_iv_get\n  #{code}\n"
      else
        "  #{code}\n"
      end
    when 'SETIV'
      ivar = a[/@(\w+)/, 1]
      # Not `$`-anchored: a trailing "; R1:name" comment (see IvarLayout.analyze).
      s = a[/R(\d+)/, 1]
      klass = self_class(owner_def)
      code = ivar_set_code(klass, 'self', ivar, "r#{s}", self_of_klass: true)
      type = embed_type(klass, ivar) if klass
      if code.nil?
        "  #error SETIV @#{ivar}: self's class is unknown here and some class embeds @#{ivar}\n"
      elsif type
        "  // @#{ivar} embedded (#{type}) -- direct struct field write, no mrb_iv_set\n  #{code}\n"
      else
        "  #{code}\n"
      end
    when 'ADDI'
      d = a[/^R(\d+)/, 1]
      lit = a.split(/\s+/).last
      # FIXNUM_OPERAND_PROOF: the immediate is a Fixnum, so only the destination
      # needs proving.
      if proven_fixnum_operand?(irep, idx, unshift_proof_reg(d, reg_offset), owner_def)
        "#{FIXNUM_PROOF_NOTE}  r#{d} = mrb_fixnum_value(mrb_fixnum(r#{d}) + #{lit});\n"
      else
        <<~CPP
          if (mrb_integer_p(r#{d})) {
            r#{d} = mrb_fixnum_value(mrb_fixnum(r#{d}) + #{lit});
          } else {
            #{compile_operator_fallback('+', d, nil, "mrb_fixnum_value(#{lit})", irep, idx, owner_def, reg_offset)}
          }
        CPP
      end
    when 'ADD'
      d = a[/^R(\d+)/, 1]
      s = a[/\(R(\d+)\)/, 1]
      if proven_fixnum_pair?(irep, idx, unshift_proof_reg(d, reg_offset), unshift_proof_reg(s, reg_offset), owner_def)
        "#{FIXNUM_PROOF_NOTE}  r#{d} = mrb_fixnum_value(mrb_fixnum(r#{d}) + mrb_fixnum(r#{s}));\n"
      else
        <<~CPP
          if (mrb_fixnum_p(r#{d}) && mrb_fixnum_p(r#{s})) {
            r#{d} = mrb_fixnum_value(mrb_fixnum(r#{d}) + mrb_fixnum(r#{s}));
          #ifndef MRB_NO_FLOAT
          } else if (mrb_float_p(r#{d}) && mrb_integer_p(r#{s})) {
            r#{d} = mrb_float_value(M, mrb_float(r#{d}) + mrb_integer(r#{s}));
          } else if (mrb_integer_p(r#{d}) && mrb_float_p(r#{s})) {
            r#{d} = mrb_float_value(M, mrb_integer(r#{d}) + mrb_float(r#{s}));
          } else if (mrb_float_p(r#{d}) && mrb_float_p(r#{s})) {
            r#{d} = mrb_float_value(M, mrb_float(r#{d}) + mrb_float(r#{s}));
          #endif
          } else {
            #{compile_operator_fallback('+', d, s, nil, irep, idx, owner_def, reg_offset)}
          }
        CPP
      end
    when 'SUBI'
      d = a[/^R(\d+)/, 1]
      lit = a.split(/\s+/).last
      if proven_fixnum_operand?(irep, idx, unshift_proof_reg(d, reg_offset), owner_def)
        "#{FIXNUM_PROOF_NOTE}  r#{d} = mrb_fixnum_value(mrb_fixnum(r#{d}) - #{lit});\n"
      else
        <<~CPP
          if (mrb_integer_p(r#{d})) {
            r#{d} = mrb_fixnum_value(mrb_fixnum(r#{d}) - #{lit});
          } else {
            #{compile_operator_fallback('-', d, nil, "mrb_fixnum_value(#{lit})", irep, idx, owner_def, reg_offset)}
          }
        CPP
      end
    when 'SUB'
      d = a[/^R(\d+)/, 1]
      s = a[/\(R(\d+)\)/, 1]
      if proven_fixnum_pair?(irep, idx, unshift_proof_reg(d, reg_offset), unshift_proof_reg(s, reg_offset), owner_def)
        "#{FIXNUM_PROOF_NOTE}  r#{d} = mrb_fixnum_value(mrb_fixnum(r#{d}) - mrb_fixnum(r#{s}));\n"
      else
        <<~CPP
          if (mrb_fixnum_p(r#{d}) && mrb_fixnum_p(r#{s})) {
            r#{d} = mrb_fixnum_value(mrb_fixnum(r#{d}) - mrb_fixnum(r#{s}));
          #ifndef MRB_NO_FLOAT
          } else if (mrb_float_p(r#{d}) && mrb_integer_p(r#{s})) {
            r#{d} = mrb_float_value(M, mrb_float(r#{d}) - mrb_integer(r#{s}));
          } else if (mrb_integer_p(r#{d}) && mrb_float_p(r#{s})) {
            r#{d} = mrb_float_value(M, mrb_integer(r#{d}) - mrb_float(r#{s}));
          } else if (mrb_float_p(r#{d}) && mrb_float_p(r#{s})) {
            r#{d} = mrb_float_value(M, mrb_float(r#{d}) - mrb_float(r#{s}));
          #endif
          } else {
            #{compile_operator_fallback('-', d, s, nil, irep, idx, owner_def, reg_offset)}
          }
        CPP
      end
    when 'MUL'
      # Same shape as ADD/SUB: vm.c OP_ADD/OP_SUB/OP_MUL all expand OP_MATH, so MUL
      # differs only in operator and fallback name.
      d = a[/^R(\d+)/, 1]
      s = a[/\(R(\d+)\)/, 1]
      if proven_fixnum_pair?(irep, idx, unshift_proof_reg(d, reg_offset), unshift_proof_reg(s, reg_offset), owner_def)
        "#{FIXNUM_PROOF_NOTE}  r#{d} = mrb_fixnum_value(mrb_fixnum(r#{d}) * mrb_fixnum(r#{s}));\n"
      else
        <<~CPP
          if (mrb_fixnum_p(r#{d}) && mrb_fixnum_p(r#{s})) {
            r#{d} = mrb_fixnum_value(mrb_fixnum(r#{d}) * mrb_fixnum(r#{s}));
          #ifndef MRB_NO_FLOAT
          } else if (mrb_float_p(r#{d}) && mrb_integer_p(r#{s})) {
            r#{d} = mrb_float_value(M, mrb_float(r#{d}) * mrb_integer(r#{s}));
          } else if (mrb_integer_p(r#{d}) && mrb_float_p(r#{s})) {
            r#{d} = mrb_float_value(M, mrb_integer(r#{d}) * mrb_float(r#{s}));
          } else if (mrb_float_p(r#{d}) && mrb_float_p(r#{s})) {
            r#{d} = mrb_float_value(M, mrb_float(r#{d}) * mrb_float(r#{s}));
          #endif
          } else {
            #{compile_operator_fallback('*', d, s, nil, irep, idx, owner_def, reg_offset)}
          }
        CPP
      end
    when 'DIV'
      # DIV_FASTPATH_SUPPORT: Integer#/ floors (not C's truncation). int_div
      # (src/numeric.c) calls mrb_div_int_value(mrb, mrb_integer(x), mrb_integer(y))
      # for Integer/Integer, so calling it here reproduces the rounding and the
      # ZeroDivisionError/overflow raises exactly. Declared `extern "C"` like
      # mrb_str_aref (mruby/internal.h has no C-linkage guard). Same fixnum/fixnum
      # guard as ADD/SUB/MUL, mrb_funcall otherwise.
      d = a[/^R(\d+)/, 1]
      s = a[/\(R(\d+)\)/, 1]
      if proven_fixnum_pair?(irep, idx, unshift_proof_reg(d, reg_offset), unshift_proof_reg(s, reg_offset), owner_def)
        "#{FIXNUM_PROOF_NOTE}  r#{d} = mrb_div_int_value(M, mrb_fixnum(r#{d}), mrb_fixnum(r#{s}));\n"
      else
        <<~CPP
          if (mrb_fixnum_p(r#{d}) && mrb_fixnum_p(r#{s})) {
            r#{d} = mrb_div_int_value(M, mrb_fixnum(r#{d}), mrb_fixnum(r#{s}));
          } else {
            #{compile_operator_fallback('/', d, s, nil, irep, idx, owner_def, reg_offset)}
          }
        CPP
      end
    when 'EQ', 'LT', 'LE', 'GT', 'GE'
      compile_cmp(insn.op, a, irep, idx, owner_def, reg_offset)
    # BLOCK_BODY_INDEX_SUPPORT: compile_send keeps `idx` nil inside shifted block
    # bodies: its other scans derive r<d>..r<d+n> windows from `args`, and two of
    # them (compile_keyword_send, compile_splat_send) print register lists back
    # into the output, which would need re-shifting. trace_new_target needs only
    # the receiver register and index, both safely unshiftable, so it alone gets
    # the separate `trace_idx`/offset context.
    when 'SEND0', 'SEND'
      compile_send(a, self_implicit: false, irep: irep, idx: reg_offset.zero? ? idx : nil, owner_def: owner_def,
                   trace_idx: idx, trace_reg_offset: reg_offset)
    when 'SSEND0', 'SSEND'
      compile_send(a, self_implicit: true, irep: irep, idx: reg_offset.zero? ? idx : nil, owner_def: owner_def,
                   trace_idx: idx, trace_reg_offset: reg_offset)
    when 'BLKPUSH'
      # BLKPUSH_YIELD_SUPPORT: `BLKPUSH R4 2:0:0:0 (0)`: vm.c OP_BLKPUSH with lv == 0
      # reads regs[1 + offset], this frame's block (lv > 0 walks uvenv). Compiled
      # only with @blk_param_name set, i.e. when compile_method's prescan arranged
      # for the wrapper to extract the block. vm.c raises LocalJumpError
      # ("unexpected yield") for a nil slot, reproduced here (mrb_get_args "&"
      # returns nil instead of raising).
      # BLOCK_FALLBACK_YIELD_SUPPORT: inside a BLOCK_FALLBACK body whose enclosing
      # method's block was captured, @blk_param_level answers exactly that lv
      # (uvenv(mrb, lv-1) is a different frame for each lv).
      d = a[/^R(\d+)/, 1]
      lv = a[/\((\d+)\)/, 1]
      if lv == @blk_param_level.to_s && @blk_param_name
        <<~CPP
          if (mrb_nil_p(#{@blk_param_name})) {
            mrb_raise(M, mrb_exc_get_id(M, mrb_intern_lit(M, "LocalJumpError")), "bc2cpp: unexpected yield");
          }
          r#{d} = #{@blk_param_name};
        CPP
      else
        "#error unhandled opcode BLKPUSH #{a}\n"
      end
    when 'BLKCALL'
      # "BLKCALL R4 2": ops.h `R[a] = R[a].call(R[a+1],...,R[a+b])`. codegen_yield's
      # fast path for a plain `yield` (no keywords, < 15 args, no splat; otherwise
      # SEND :call), always right after a BLKPUSH into the same register. So this is
      # `yield`, not a general "call a Proc in a register".
      # vm.c OP_BLKCALL does no method dispatch: it raises TypeError unless R[a] is
      # a Proc (`mrb_raisef(mrb, E_TYPE_ERROR, "wrong type %T (expected Proc)",
      # recv)`) and runs the proc body, ignoring any #call method. mrb_funcall(...,
      # "call") would be wrong (an object with its own #call would be invoked), so
      # the type check is reproduced (fixed message, as elsewhere here) and the call
      # goes through mrb_yield_argv (public). For an irep-backed Proc (every real
      # site passes a literal block) both take self from the proc's env
      # (mrb_proc_get_self, src/proc.c), and `break` unwinds normally past this
      # frame's POD locals.
      # Not modelled: a cfunc-backed Proc here (`&:sym`, `&method(...)`), where vm.c
      # passes the proc as self but mrb_yield_argv passes nil. Calling the cfunc
      # pointer directly would skip the ci frame mrb_get_args reads, which is worse.
      # No site passes one, and no core cfunc proc depends on its self.
      d = a[/^R(\d+)/, 1].to_i
      blkn = a[/^R\d+\s+(\d+)/, 1].to_i
      out = String.new
      out << "  if (!mrb_proc_p(r#{d})) {\n"
      out << "    mrb_raise(M, mrb_exc_get_id(M, mrb_intern_lit(M, \"TypeError\")), \"bc2cpp: BLKCALL (yield) expected a Proc\");\n"
      out << "  }\n"
      if blkn.zero?
        out << "  r#{d} = mrb_yield_argv(M, r#{d}, 0, NULL);\n"
      else
        out << "  {\n"
        out << "    mrb_value blkcall_args[] = { #{(1..blkn).map { |i| "r#{d + i}" }.join(', ')} };\n"
        out << "    r#{d} = mrb_yield_argv(M, r#{d}, #{blkn}, blkcall_args);\n"
        out << "  }\n"
      end
      out
    when 'RETURN'
      r = a.empty? ? '0' : a[/^R(\d+)/, 1]
      "  return r#{r};\n"
    when 'RETNIL'
      "  return mrb_nil_value();\n"
    when 'RETFALSE'
      "  return mrb_false_value();\n"
    when 'RETTRUE'
      "  return mrb_true_value();\n"
    when 'RETSELF'
      # "RETSELF": vm.c `a = 0; goto NORMAL_RETURN;`. mrbc's gen_return only emits
      # it as a LOADSELF+RETURN peephole, and every leaf irep compiled here is a def
      # body, so it is `return self`.
      "  return self;\n"
    when 'JMP'
      # `.to_i`: the disassembly zero-pads ("018") while labels use the integer
      # ("L18:").
      target = ensure_remapped_jump_target(irep, a.strip[/\d+/].to_i)
      "  goto L#{target};\n"
    when 'JMPUW'
      # JMPUW_SUPPORT: break/next/redo/retry; a plain JMP when this irep has no
      # catch handlers (see jmpuw_is_plain_jump?). `.to_i` as for JMP.
      if jmpuw_is_plain_jump?(irep)
        "  goto L#{a.strip[/\d+/].to_i};\n"
      else
        "  #error unhandled opcode JMPUW -- not in this prototype's supported subset\n"
      end
    when 'JMPNOT'
      reg = a[/^R(\d+)/, 1]
      target = ensure_remapped_jump_target(irep, jmp_target_after_reg(a))
      "  if (!mrb_test(r#{reg})) goto L#{target};\n"
    when 'JMPIF'
      reg = a[/^R(\d+)/, 1]
      target = ensure_remapped_jump_target(irep, jmp_target_after_reg(a))
      "  if (mrb_test(r#{reg})) goto L#{target};\n"
    when 'JMPNIL'
      # "JMPNIL R3 024": jump if exactly nil (vm.c), for nil-specific tests like
      # `x.nil? ? a : b`.
      reg = a[/^R(\d+)/, 1]
      target = ensure_remapped_jump_target(irep, jmp_target_after_reg(a))
      "  if (mrb_nil_p(r#{reg})) goto L#{target};\n"
    when 'GETCONST'
      # "GETCONST R4 Integer": the VM resolves against the lexical scope chain
      # (mrb_vm_const_get), which compiled code does not have. A single lookup from
      # Object misses class-body and enclosing-module constants (`KIND_SKILL` in
      # Game::EnemyAction, `Tone` in RGSS::Sprite): const_get_nohook (src/variable.c)
      # stops before Object's table unless the search starts at Object. So try each
      # scope of the owner's nesting innermost first ("RGSS::Sprite" ->
      # [RGSS::Sprite, RGSS]), then Object (Module.nesting for defs nested where the
      # owner name says).
      # A failing mrb_const_get raises by longjmp, so it cannot be tried and then
      # polled; bc2cpp_const_try (emit_const_lookup_helper) wraps each attempt in
      # mrb_protect_error. The final lookup, from Object, is unprotected: a constant
      # still not found is a real error.
      # A top-level def (owner "Object") needs just the one lookup.
      # Name: `\S+`, so a trailing "; R3:name" comment ("GETCONST R3 MAX_DIGITS\t;
      # R3:d") is not interned into the name.
      d = a[/^R(\d+)/, 1]
      name = a[/^R\d+\s+(\S+)/, 1]
      # INTEGER_CONSTANT_VALUE_PROOF: a name analyze_values proved always binds this
      # number needs no lookup. Checked first; it can never also be a
      # StableClassConstants name (one poisons on CLASS/MODULE, the other requires
      # it).
      if (value = self.class.integer_constant_values&.[](name))
        return "  r#{d} = mrb_fixnum_value(#{value});\n"
      end

      owner_path = lexical_scope_path(owner_def.owner)
      if self.class.stable_class_constants&.include?(name)
        # CONST_SITE_CACHE: see tools/bc2cpp/const_site_cache.rb. One helper per
        # (lexical scope, name); it runs the ordinary lookup until it finds a
        # class/module, then returns the stored value.
        @const_site_cache ||= {}
        key = [owner_path, name]
        unless @const_site_cache.key?(key)
          @const_site_cache[key] = { index: @const_site_cache.size, body: const_lookup_block('0', name, owner_path) }
        end
        return "  r#{d} = bc2cpp_cconst_#{@const_site_cache[key][:index]}(M);\n"
      end

      const_lookup_block(d, name, owner_path)
    when 'OCLASS'
      # OCLASS_SUPPORT: "OCLASS R3" for `::Foo` (followed by GETMCNST); vm.c
      # `regs[a] = mrb_obj_value(mrb->object_class)`.
      d = a[/^R(\d+)/, 1]
      "  r#{d} = mrb_obj_value(M->object_class);\n"
    when 'GETMCNST'
      # "GETMCNST R6 (R6)::Sections": r<d> holds the owning module (from the chain,
      # e.g. GETCONST R2 LCF; GETMCNST R2 (R2)::Schema; GETMCNST R2 (R2)::DATABASE);
      # read the constant from it into the same register.
      d = a[/^R(\d+)/, 1]
      name = a[/::(\w+)\s*$/, 1]
      # INTEGER_CONSTANT_VALUE_PROOF, as in GETCONST. The preceding scope lookups
      # still run (and raise if missing); only this value lookup is skipped. This is
      # the hot `case cmd.code when Cmd::X` shape.
      if (value = self.class.integer_constant_values&.[](name))
        return "  r#{d} = mrb_fixnum_value(#{value});\n"
      end

      "  r#{d} = mrb_const_get(M, r#{d}, mrb_intern_cstr(M, \"#{name}\"));\n"
    when 'HASH'
      # "HASH R2 22": N key/value pairs from Rd, result into Rd (vm.c OP_HASH). All
      # pair registers are read before Rd is written.
      d = a[/^R(\d+)/, 1].to_i
      n = a[/^R\d+\s+(\d+)/, 1].to_i
      out = String.new
      out << "  {\n"
      out << "    mrb_value h = mrb_hash_new_capa(M, #{n});\n"
      n.times { |i| out << "    mrb_hash_set(M, h, r#{d + 2 * i}, r#{d + 2 * i + 1});\n" }
      out << "    r#{d} = h;\n"
      out << "  }\n"
      out
    when 'ARRAY'
      # "ARRAY R3 2": N registers from Rd into a new Array in Rd (vm.c
      # `mrb_ary_new_from_values(mrb, b, &regs[a])`). The registers are separate C++
      # locals, not contiguous, so they are copied into a C array first; all are
      # read before Rd is written. This is codegen_array's no-splat path; splats
      # use ARYCAT/ARYPUSH/ARYSPLAT.
      # ARRAY2_OPERAND_FORM: OP_ARRAY2 disassembles under the same mnemonic with a
      # source register, `ARRAY Rd Rs N` ("ARRAY\tR%d\tR%d\t%d", codedump.c): Rd =
      # [Rs .. Rs+N-1], emitted for `local = [literal]`. The 2-operand regex does
      # not match it, and treating N as 0 compiled it to an empty Array; it is
      # handled explicitly.
      d = a[/^R(\d+)/, 1].to_i
      three = a.match(/^R\d+\s+R(\d+)\s+(\d+)/)
      src = three ? three[1].to_i : d
      n = three ? three[2].to_i : a[/^R\d+\s+(\d+)/, 1].to_i
      if n.zero?
        "  r#{d} = mrb_ary_new(M);\n"
      else
        out = String.new
        out << "  {\n"
        out << "    mrb_value elems[] = { #{(0...n).map { |i| "r#{src + i}" }.join(', ')} };\n"
        out << "    r#{d} = mrb_ary_new_from_values(M, #{n}, elems);\n"
        out << "  }\n"
        out
      end
    when 'ARYPUSH'
      # "ARYPUSH R3 2": push Ra+1..Ra+N onto the Array in Ra (vm.c
      # `mrb_ensure_array_type(mrb, regs[a]); for (...) mrb_ary_push(...)`). Ra is
      # always an Array here: codegen.c emits OP_ARYPUSH only in gen_values and
      # codegen_array, each after an OP_ARRAY wrote that register, so the ensure is
      # a no-op and plain mrb_ary_push calls suffice.
      d = a[/^R(\d+)/, 1].to_i
      n = a[/^R\d+\s+(\d+)/, 1].to_i
      out = String.new
      n.times { |i| out << "  mrb_ary_push(M, r#{d}, r#{d + i + 1});\n" }
      out
    when 'ARYCAT'
      # "ARYCAT R3 (R4)" (codedump.c `"ARYCAT\tR%d\t(R%d)"`). vm.c OP_ARYCAT:
      #   mrb_value splat = mrb_ary_splat(mrb, regs[a+1]);
      #   if (mrb_nil_p(regs[a])) regs[a] = splat;
      #   else { mrb_ensure_array_type(mrb, regs[a]); mrb_ary_concat(mrb, regs[a], splat); }
      # ARYCAT_NIL_START_SUPPORT: R[a] can be nil: `bar(*list, *list2)` compiles to
      # `LOADNIL R5` then `ARYCAT R5 (R6)`, so the nil branch is reproduced. A
      # non-nil R[a] always came from ARRAY or ARYCAT, so ensure_array_type is a
      # no-op. R[a+1] can be anything, so mrb_ary_splat is really called.
      d = a[/^R(\d+)/, 1]
      s = a[/\(R(\d+)\)/, 1]
      <<~CPP
        {
          mrb_value bc2cpp_arycat_splat = mrb_ary_splat(M, r#{s});
          if (mrb_nil_p(r#{d})) {
            r#{d} = bc2cpp_arycat_splat;
          } else {
            mrb_ary_concat(M, r#{d}, bc2cpp_arycat_splat);
          }
        }
      CPP
    when 'AREF'
      # "AREF R2 R6 0 ; R2:x": R[a] = R[b][c] with an immediate c (vm.c): for a
      # non-Array, index 0 yields R[b] itself and others nil; for an Array,
      # mrb_ary_ref. This is `x, y, w, h = some_call(...)` destructuring.
      d, s = regs(a, 2)
      c = a[/^R\d+\s+R\d+\s+(\d+)/, 1]
      "  r#{d} = mrb_array_p(r#{s}) ? bc2cpp_ary_entry(M, r#{s}, #{c}) : (#{c} == 0 ? r#{s} : mrb_nil_value());\n"
    when 'GETIDX'
      # "GETIDX R2 (R3)": R[a] = R[a][R[a+1]] with a register index (vm.c).
      # Mirrors vm.c's fast paths: Array with an Integer index (mrb_ary_ref), Hash
      # (mrb_hash_get), String with an Integer/String/Range index; anything else
      # calls the real `[]`. The fast paths require the exact base class, as vm.c
      # does, so subclass/singleton `[]` overrides keep Ruby dispatch. r<d> is read
      # by every branch before any write.
      # GETIDX_STRING_AREF: the String arm calls `mrb_str_aref(mrb, str, idx,
      # mrb_undef_value())` (no length; codegen.c only emits GETIDX for one-argument
      # `[]`), with vm.c's index-type gate (INTEGER/STRING/RANGE). mrb_str_aref is
      # declared `extern "C"` in the prologue.
      # GETIDX_STATIC_RECEIVER_SUPPORT: when static_indexable_class proves Array or
      # Hash, emit one guarded fast path instead of the four-way gate; a wrong hint
      # still falls back to `[]`, and subclasses use Ruby dispatch. A Hash needs no
      # index-type check; an Array still needs mrb_integer_p (bc2cpp_ary_entry only
      # takes a fixnum).
      d, s = regs(a, 2)
      index_class = static_indexable_class(irep, idx, unshift_proof_reg(d, reg_offset), owner_def)
      case index_class
      when 'Array'
        <<~CPP
          if (mrb_array_p(r#{d}) && mrb_obj_ptr(r#{d})->c == M->array_class && mrb_integer_p(r#{s})) {
            r#{d} = bc2cpp_ary_entry(M, r#{d}, mrb_integer(r#{s}));
          } else {
            r#{d} = mrb_funcall(M, r#{d}, "[]", 1, r#{s});
          }
        CPP
      when 'Hash'
        <<~CPP
          if (mrb_hash_p(r#{d}) && mrb_obj_ptr(r#{d})->c == M->hash_class) {
            r#{d} = mrb_hash_get(M, r#{d}, r#{s});
          } else {
            r#{d} = mrb_funcall(M, r#{d}, "[]", 1, r#{s});
          }
        CPP
      else
        # STRUCT_INDEX_CACHE (see compile_struct_literal_index_read); a miss is "".
        struct_read = compile_struct_literal_index_read(irep, idx, s, d)
        fallback = outlined_getidx_code(d, s, struct_read)
        unless fallback
          # INDEX_CHAIN: send the untyped `x[i]` fallback through the exact-class chain
          # (compile_poly_small_n), so program-defined `#[]` (Game::Variables,
          # LCF::Array1D, ...) is called directly; nil keeps the funcall.
          tail = compile_poly_small_n('[]', d.to_i, "r#{d}", ["r#{s}"], 1)
          tail = tail ? tail.gsub(/^/, '  ').lstrip : "r#{d} = mrb_funcall(M, r#{d}, \"[]\", 1, r#{s});"
          fallback = <<~CPP
            if (mrb_array_p(r#{d}) && mrb_obj_ptr(r#{d})->c == M->array_class && mrb_integer_p(r#{s})) {
              r#{d} = bc2cpp_ary_entry(M, r#{d}, mrb_integer(r#{s}));
            } else if (mrb_hash_p(r#{d}) && mrb_obj_ptr(r#{d})->c == M->hash_class) {
              r#{d} = mrb_hash_get(M, r#{d}, r#{s});
            } else if (mrb_string_p(r#{d}) && mrb_obj_ptr(r#{d})->c == M->string_class &&
                       (mrb_integer_p(r#{s}) || mrb_string_p(r#{s}) || mrb_range_p(r#{s}))) {
              r#{d} = mrb_str_aref(M, r#{d}, r#{s}, mrb_undef_value());
            } #{struct_read}else {
              #{tail}
            }
          CPP
        end
        typed = compile_typed_index_send(irep, idx, owner_def, d, d, "r#{s}", reg_offset, index_class, fallback)
        typed || fallback
      end
    when 'GETIDX0'
      # "GETIDX0 R7 R4[0]": R[a] = R[b][0] (vm.c), separate dest/source registers
      # and no index register. Same exact-class Array/Hash fast paths as GETIDX,
      # else a real `[]` send with 0, as vm.c's getidx0_fallback.
      # GETIDX_STATIC_RECEIVER_SUPPORT applies to `s`, the receiver here.
      d, s = regs(a, 2)
      index_class = static_indexable_class(irep, idx, unshift_proof_reg(s, reg_offset), owner_def)
      case index_class
      when 'Array'
        <<~CPP
          if (mrb_array_p(r#{s}) && mrb_obj_ptr(r#{s})->c == M->array_class) {
            r#{d} = bc2cpp_ary_entry(M, r#{s}, 0);
          } else {
            r#{d} = mrb_funcall(M, r#{s}, "[]", 1, mrb_fixnum_value(0));
          }
        CPP
      when 'Hash'
        <<~CPP
          if (mrb_hash_p(r#{s}) && mrb_obj_ptr(r#{s})->c == M->hash_class) {
            r#{d} = mrb_hash_get(M, r#{s}, mrb_fixnum_value(0));
          } else {
            r#{d} = mrb_funcall(M, r#{s}, "[]", 1, mrb_fixnum_value(0));
          }
        CPP
      else
        # OUTLINED_INDEX_OPS: the Array/Hash/funcall chain is bc2cpp_getidx0.
        fallback = outlined_index_call('getidx0', "r#{d}", "r#{s}")
        typed = compile_typed_index_send(irep, idx, owner_def, d, s, 'mrb_fixnum_value(0)', reg_offset,
                                         index_class, fallback)
        typed || fallback
      end
    when 'SETIDX'
      # "SETIDX R4 (R5) (R6)": R[a][R[a+1]] = R[a+2], then R[a] = R[a+2] on the fast
      # Array/Hash paths (vm.c; `arr[i] = v` evaluates to v). Otherwise (including
      # container subclasses) a real `[]=` send, whose return value is kept, as in
      # vm.c's setidx_fallback.
      # GETIDX_STATIC_RECEIVER_SUPPORT as for GETIDX. The index register is named
      # `idx_reg`: `idx` would shadow compile_insn's instruction position, which
      # static_indexable_class needs.
      d, idx_reg, val = regs(a, 3)
      index_class = static_indexable_class(irep, idx, unshift_proof_reg(d, reg_offset), owner_def)
      case index_class
      when 'Array'
        <<~CPP
          if (mrb_array_p(r#{d}) && mrb_obj_ptr(r#{d})->c == M->array_class && mrb_integer_p(r#{idx_reg})) {
            mrb_ary_set(M, r#{d}, mrb_integer(r#{idx_reg}), r#{val});
            r#{d} = r#{val};
          } else {
            r#{d} = mrb_funcall(M, r#{d}, "[]=", 2, r#{idx_reg}, r#{val});
          }
        CPP
      when 'Hash'
        <<~CPP
          if (mrb_hash_p(r#{d}) && mrb_obj_ptr(r#{d})->c == M->hash_class) {
            mrb_hash_set(M, r#{d}, r#{idx_reg}, r#{val});
            r#{d} = r#{val};
          } else {
            r#{d} = mrb_funcall(M, r#{d}, "[]=", 2, r#{idx_reg}, r#{val});
          }
        CPP
      else
        # OUTLINED_INDEX_OPS: the Array/Hash/funcall chain is bc2cpp_setidx.
        fallback = outlined_index_call('setidx', "r#{d}", "r#{d}", "r#{idx_reg}", "r#{val}")
        typed = compile_typed_index_write(irep, idx, owner_def, d, idx_reg, val, reg_offset, index_class, fallback)
        typed || fallback
      end
    when 'GETGV'
      # "GETGV R4 $stderr": R[a] = mrb_gv_get (vm.c); the symbol already includes the
      # `$`.
      d = a[/^R(\d+)/, 1]
      name = a[/(\$\S+)/, 1]
      "  r#{d} = mrb_gv_get(M, mrb_intern_cstr(M, \"#{name}\"));\n"
    when 'SETGV'
      # "SETGV $stderr R4": operands are reversed relative to GETGV (codedump.c
      # `"SETGV\t\t%s\tR%d"`), so both are matched unanchored (one `$` token, one
      # register). vm.c: `mrb_gv_set(mrb, irep->syms[b], regs[a])`.
      s = a[/R(\d+)/, 1]
      name = a[/(\$\S+)/, 1]
      "  mrb_gv_set(M, mrb_intern_cstr(M, \"#{name}\"), r#{s});\n"
    when 'STOP'
      ''
    when 'NOP'
      # "NOP": vm.c does nothing. mrbc places it after a while loop's entry JMPNOT.
      ''
    when 'ADDILV'
      # "ADDILV Rd Rb N ; Rd:name": vm.c OP_MATHILV(add) updates regs[a] in place
      # (`b` is never touched), falling back to `+` for non-Integers, like ADDI.
      # Overflow wraps instead of promoting to Bignum, the same simplification ADDI
      # accepts. The immediate is the third operand (`^R\d+\s+R\d+\s+(-?\d+)`): `a`
      # is a named local, so a trailing "; Rd:name" comment is normal and
      # `.split.last` would pick it up.
      d = a[/^R(\d+)/, 1]
      lit = a[/^R\d+\s+R\d+\s+(-?\d+)/, 1]
      # FIXNUM_OPERAND_PROOF: as ADDI; rarely provable (a loop back-edge sits
      # between the write and this use).
      if proven_fixnum_operand?(irep, idx, unshift_proof_reg(d, reg_offset), owner_def)
        "#{FIXNUM_PROOF_NOTE}  r#{d} = mrb_fixnum_value(mrb_fixnum(r#{d}) + #{lit});\n"
      else
        <<~CPP
          if (mrb_integer_p(r#{d})) {
            r#{d} = mrb_fixnum_value(mrb_fixnum(r#{d}) + #{lit});
          } else {
            #{compile_operator_fallback('+', d, nil, "mrb_fixnum_value(#{lit})", irep, idx, owner_def, reg_offset)}
          }
        CPP
      end
    when 'SUBILV'
      # OP_SUBILV: ADDILV's sibling (same shape, same extraction), e.g. `new_level -=
      # 1 while ...`.
      d = a[/^R(\d+)/, 1]
      lit = a[/^R\d+\s+R\d+\s+(-?\d+)/, 1]
      if proven_fixnum_operand?(irep, idx, unshift_proof_reg(d, reg_offset), owner_def)
        "#{FIXNUM_PROOF_NOTE}  r#{d} = mrb_fixnum_value(mrb_fixnum(r#{d}) - #{lit});\n"
      else
        <<~CPP
          if (mrb_integer_p(r#{d})) {
            r#{d} = mrb_fixnum_value(mrb_fixnum(r#{d}) - #{lit});
          } else {
            #{compile_operator_fallback('-', d, nil, "mrb_fixnum_value(#{lit})", irep, idx, owner_def, reg_offset)}
          }
        CPP
      end
    when 'RANGE_INC'
      # "RANGE_INC Ra": R[a] = mrb_range_new(mrb, regs[a], regs[a+1], FALSE) (vm.c);
      # both operands are read before r<a> is written.
      d = a[/^R(\d+)/, 1].to_i
      "  r#{d} = mrb_range_new(M, r#{d}, r#{d + 1}, FALSE);\n"
    when 'RANGE_EXC'
      # OP_RANGE_EXC: RANGE_INC with exclude_end TRUE (`a...b`).
      d = a[/^R(\d+)/, 1].to_i
      "  r#{d} = mrb_range_new(M, r#{d}, r#{d + 1}, TRUE);\n"
    when 'RETURN_BLK'
      # "RETURN_BLK Ra": vm.c starts with `if (!MRB_PROC_ENV_P(ci->proc) ||
      # MRB_PROC_STRICT_P(ci->proc)) goto NORMAL_RETURN;`. Reached from:
      # (1) a def body (always strict, @block_fallback_active false): e.g. an early
      #     `return` inside a `while` loop; a plain `return`.
      # (2) a LAMBDA_FALLBACK body (a lambda proc is strict): a plain `return`.
      # (3) EXCEPTION_RETURN_SUPPORT: a BLOCK_FALLBACK body (@block_fallback_active
      #     true), where `return` exits the whole enclosing method:
      #     `throw bc2cpp_method_return{...}`, caught by compile_method's top-level
      #     try/catch (needs_return_catch). The per-call-site
      #     `catch (bc2cpp_block_break&)` cannot match it (exact C++ catch types).
      r = a.strip.empty? ? '0' : a[/^R(\d+)/, 1]
      if @block_fallback_active
        "  throw bc2cpp_method_return{r#{r}};\n"
      else
        "  return r#{r};\n"
      end
    when 'BREAK'
      # "BREAK Ra": vm.c starts with `if (MRB_PROC_STRICT_P(ci->proc)) goto
      # NORMAL_RETURN;`. Reached from:
      # (1) a LAMBDA_FALLBACK body (strict): a plain `return`.
      # (2) EXCEPTION_BREAK_SUPPORT: a BLOCK_FALLBACK body, where a non-strict break
      #     unwinds to the SENDB call site, past mrb_funcall_with_block: `throw`,
      #     caught by emit_block_fallback_glue's `catch (bc2cpp_block_break&)`.
      r = a.strip.empty? ? '0' : a[/^R(\d+)/, 1]
      if @block_fallback_active
        "  throw bc2cpp_block_break{r#{r}};\n"
      else
        "  return r#{r};\n"
      end
    when 'RESCUE'
      # "RESCUE Ra Rb": vm.c `R[b] = R[a].isa?(R[b])`. Ra holds the exception (only
      # RESCUE_SUPPORT's glue produces one) and Rb the class from the preceding
      # GETCONST/GETMCNST chain, so this is correct wherever it appears; not gated on
      # the recognizer (unlike EXCEPT).
      ra, rb = a.split(/\s+/)
      d = ra[/^R(\d+)/, 1]
      s = rb[/^R(\d+)/, 1]
      "  r#{s} = mrb_bool_value(mrb_obj_is_kind_of(M, r#{d}, mrb_class_ptr(r#{s})));\n"
    when 'RAISEIF'
      # "RAISEIF Ra": re-raise Ra unless nil. In a recognized rescue it is reached
      # only on the non-matching path with the exception in Ra. vm.c's mrb_break_p
      # branch (a break unwinding through a block) does not apply: the leaf ireps
      # compiled here are def bodies, so Ra is nil or an exception.
      ra = a[/^R(\d+)/, 1]
      "  if (!mrb_nil_p(r#{ra})) { mrb_exc_raise(M, r#{ra}); }\n"
    when 'SUPER'
      # "SUPER Ra n=N": vm.c looks up ci->mid one level above the current class, with
      # self as receiver and N args in R(a+1)..R(a+N), plus one register forwarding
      # the current block. That block is never read: a compiled `_impl` has none
      # (see SUPER_TARGETS). super_target applies the allowlist.
       target_def = super_target(owner_def)
       dest, nstr = a.split(/\s+/, 2)
       d_reg = dest[/^R(\d+)/, 1]
       n = nstr && nstr[/^n=(\d+)$/, 1]
       zsuper_kind = reg_offset.zero? ? zsuper_native_kind(owner_def, irep, idx) : nil
       zsuper_plan = reg_offset.zero? && zsuper_kind.nil? ? zsuper_forward_plan(owner_def, irep, idx) : nil
       if target_def && d_reg && n
         args = (1..n.to_i).map { |i| "r#{d_reg.to_i + i}" }
         "  r#{d_reg} = #{cpp_name(target_def.owner, target_def.name)}_impl(M, self#{args.map { |x| ", #{x}" }.join});\n"
       elsif zsuper_kind && d_reg
         compile_zsuper_native(zsuper_kind, d_reg)
       elsif zsuper_plan && d_reg
         compile_zsuper_forward(zsuper_plan[:target_def], d_reg, zsuper_plan[:m])
       else
         "  #error unhandled opcode SUPER -- not in this prototype's supported subset\n"
       end
     when 'ARGARY'
      # ZSUPER_NATIVE_SUPPORT: the array this ARGARY builds is only read by the next
      # `SUPER ... n=*` (zsuper_native_kind checks the adjacency and registers), and
      # both translations use the original registers instead, so it is not built.
      # OP_ARGARY has no other observable effect (see ZSUPER_NATIVE_TARGETS). Any
      # other ARGARY keeps `#error`.
      if reg_offset.zero? && zsuper_native_kind(owner_def, irep, idx)
        "  // #{insn.raw.strip} (zsuper argument array not built -- consumed by the SUPER below)\n"
      elsif reg_offset.zero? && zsuper_forward_plan(owner_def, irep, idx)
        # ZSUPER_GENERAL_SUPPORT: same dead-array suppression for the general zsuper
        # pair, whose SUPER arm calls the superclass `_impl` with the original
        # registers.
        "  // #{insn.raw.strip} (zsuper argument array not built -- forwarded to the superclass _impl below)\n"
      else
        "  #error unhandled opcode ARGARY -- not in this prototype's supported subset\n"
      end
    else
      "  #error unhandled opcode #{insn.op} -- not in this prototype's supported subset\n"
    end
  end

  # ZSUPER_NATIVE_SUPPORT: replacement body for a recognized ARGARY + `SUPER
  # n=*` pair (`d_reg` is SUPER's destination). See ZSUPER_NATIVE_TARGETS and
  # zsuper_native_kind.
  def compile_zsuper_native(kind, d_reg)
    case kind
    when :kernel_respond_to_missing
      # Kernel#respond_to_missing? is src/kernel.c's mrb_false:
      # `return mrb_false_value();`.
      "  // super -> Kernel#respond_to_missing? (3rd/mruby/src/kernel.c's own `mrb_false`: " \
        "unconditionally false, reads neither self nor arguments)\n" \
        "  r#{d_reg} = mrb_false_value();\n"
    when :basic_object_method_missing
      # BasicObject#method_missing is mrb_obj_missing (src/class.c), which reads its
      # arguments via mrb_get_args off mrb->c->ci and cannot be called directly;
      # its values are computed here and passed to mrb_method_missing.
      # The ARGARY spec is `1:1:0:0` with lv=0: vm.c builds `[r1, *r2]`, so "n*!"
      # gives name = r1 and args = r2, read from the live registers (a reassignment
      # before `super` is forwarded as the interpreter would).
      # The mrb_array_p guard is vm.c's OP_ARGARY `r != 0` branch (`if
      # (mrb_array_p(stack[m1])) { ... }`, else len 0: an empty forwarded list), and
      # keeps RARRAY_LEN/PTR off a non-Array.
      # `self` = r0 (OP_SUPER reads regs[0]).
      # mrb_method_missing is mrb_noreturn, so nothing follows and d_reg is left
      # unassigned; the next RETURN is unreachable (as after RAISEIF's raise).
      "  // super -> BasicObject#method_missing (3rd/mruby/src/class.c's own `mrb_obj_missing`, " \
        "reproduced via the `mrb_method_missing` it tail-calls -- always raises NoMethodError)\n" \
        "  mrb_method_missing(M, mrb_obj_to_sym(M, r1), self,\n" \
        "                     mrb_array_p(r2)\n" \
        "                       ? mrb_ary_new_from_values(M, RARRAY_LEN(r2), RARRAY_PTR(r2))\n" \
        "                       : mrb_ary_new(M));\n"
    end
  end

  # EQ/LT/LE/GT/GE share vm.c OP_CMP: Integer/Integer (and, with floats,
  # Integer/Float, Float/Integer, Float/Float) compare natively. For EQ's other
  # shapes the fallback keeps mrb_equal's mrb_obj_eq identity shortcut before
  # dispatching `==`, so `x == x` stays true even with an overridden `==`.
  # FIXNUM_OPERAND_PROOF: when both operands prove, only the native comparison
  # is emitted (the same value the fast path computes).
  def compile_cmp(op, args, irep = nil, idx = nil, owner_def = nil, reg_offset = 0)
    sym = { 'EQ' => '==', 'LT' => '<', 'LE' => '<=', 'GT' => '>', 'GE' => '>=' }.fetch(op)
    d = args[/^R(\d+)/, 1]
    s = args[/\(R(\d+)\)/, 1]
    if proven_fixnum_pair?(irep, idx, unshift_proof_reg(d, reg_offset), unshift_proof_reg(s, reg_offset), owner_def)
      return "#{FIXNUM_PROOF_NOTE}  r#{d} = mrb_bool_value(mrb_fixnum(r#{d}) #{sym} mrb_fixnum(r#{s}));\n"
    end

    # OP_CMP's MRB_TT_INTEGER is the full Integer tag, and with floats all three
    # Integer/Float pairs compare natively; the tag checks come before
    # mrb_integer/mrb_float, which are only valid for matching tags.
    # EQ: OP_EQ's identity shortcut runs before OP_CMP; keep that order (NaN,
    # symbols), with numeric comparison only after identity fails. MRB_NO_FLOAT
    # builds compile out the float arms.
    # Non-numeric operands use a real send; route it through compile_send's
    # MONO/TYPED resolver so compiled operator methods are called directly. For
    # EQ the generated chain below already handles String/Symbol, so its fallback
    # must not repeat the registered-expression switch.
    @suppress_native_expression_send = sym if op == 'EQ'
    begin
      fallback = compile_operator_fallback(sym, d, s, nil, irep, idx, owner_def, reg_offset)
    ensure
      @suppress_native_expression_send = nil
    end
    # String/Symbol `==` come from their C wrappers; the resolver fallback stays
    # the `else`.
    fallback = generated_eq_dispatch(d, s, fallback) || fallback if op == 'EQ'

    integer_accessor = "mrb_integer(r#{d}) #{sym} mrb_integer(r#{s})"
    no_float_accessor = "mrb_fixnum(r#{d}) #{sym} mrb_fixnum(r#{s})"
    numeric_dispatch = <<~CPP
      if (mrb_type(r#{d}) == MRB_TT_INTEGER && mrb_type(r#{s}) == MRB_TT_INTEGER) {
      #ifdef MRB_NO_FLOAT
        r#{d} = mrb_bool_value(#{no_float_accessor});
      #else
        r#{d} = mrb_bool_value(#{integer_accessor});
      #endif
      }
      #ifndef MRB_NO_FLOAT
      else if (mrb_type(r#{d}) == MRB_TT_INTEGER && mrb_type(r#{s}) == MRB_TT_FLOAT) {
        r#{d} = mrb_bool_value(mrb_integer(r#{d}) #{sym} mrb_float(r#{s}));
      } else if (mrb_type(r#{d}) == MRB_TT_FLOAT && mrb_type(r#{s}) == MRB_TT_INTEGER) {
        r#{d} = mrb_bool_value(mrb_float(r#{d}) #{sym} mrb_integer(r#{s}));
      } else if (mrb_type(r#{d}) == MRB_TT_FLOAT && mrb_type(r#{s}) == MRB_TT_FLOAT) {
        r#{d} = mrb_bool_value(mrb_float(r#{d}) #{sym} mrb_float(r#{s}));
      }
      #endif
      else {
        #{fallback}
      }
    CPP

    if op == 'EQ'
      <<~CPP
        if (mrb_obj_eq(M, r#{d}, r#{s})) {
          r#{d} = mrb_true_value();
        } else if (mrb_symbol_p(r#{d})) {
          // OP_EQ: a symbol receiver that is not identical is unequal, no send.
          r#{d} = mrb_false_value();
        } else {
          // Numeric tag pair handling mirrors the pinned mruby OP_CMP.
          #{numeric_dispatch}
        }
      CPP
    else
      "  // Numeric tag pair handling mirrors the pinned mruby OP_CMP.\n#{numeric_dispatch}"
    end
  end

  # EQ on non-numeric operands used to mrb_funcall whenever identity missed
  # (every false String/Symbol compare). String#== (mrb_str_equal) and Symbol#==
  # (mrb_obj_equal) are single public-API expressions, emitted behind the usual
  # per-class guards; everything else keeps the identity/dispatch fallback. nil
  # when nothing was generated or a Ruby definition/prepend could shadow the
  # built-in (builtin_class_send_safe?).
  def generated_eq_dispatch(d, s, identity_dispatch)
    entries = @native_registered_expressions['==']
    return unless entries && !entries.empty? && entries.all? { |entry| entry[:arity] == 1 }
    return unless builtin_class_send_safe?('==', entries.map { |entry| entry[:owner][:class_name] }.uniq)

    # An if/else-if chain rather than compile_native_registered_expression's
    # switch, which would repeat the fallback (an mrb_funcall site) per class.
    recv = "r#{d}"
    chain = entries.map do |entry|
      owner = entry[:owner]
      guard = "mrb_type(#{recv}) == #{owner[:tag]}"
      guard += " && mrb_obj_ptr(#{recv})->c == M->#{owner[:field]}" unless %w[Float Symbol].include?(owner[:class_name])
      expression = entry[:expression].gsub('recv', recv).gsub('BC2CPP_ARG0', "r#{s}")
      "  if (#{guard}) {\n    r#{d} = #{expression};\n  } else "
    end.join
    "  // == -- generated from native registrations and C method bodies\n#{chain}{\n#{identity_dispatch}  }\n"
  end

  # Operator opcodes fall back to a one-argument send; reuse compile_send's
  # MONO/TYPED resolution. ADDI/SUBI pass the immediate as an expression rather
  # than borrowing a possibly live register.
  def compile_operator_fallback(name, dest_reg, arg_reg, arg_expr, irep, idx, owner_def, reg_offset)
    argument = arg_reg ? "r#{arg_reg}" : arg_expr
    send_args = "R#{dest_reg} :#{name} n=1"
    send = compile_send(send_args, self_implicit: false, irep: irep,
                        idx: reg_offset.zero? ? idx : nil, owner_def: owner_def,
                        call_receiver: "r#{dest_reg}", call_arguments: [argument])
    send.lines.map { |line| "  #{line}" }.join
  end

  # compile_keyword_send (below), KEYWORD_CALLSITE_SUPPORT: compile a SEND/SSEND
  # with keyword arguments (`n=2|nk=1`) into a direct `_impl` call, or return nil
  # (the caller keeps `#error`). Direct call only: mrb_funcall* can never carry
  # keywords (`ci->nk = 0` in funcall_args_capture, vm.c); only OP_SEND packs
  # them, and the callee's `_impl` takes each keyword as parameters.
  # Layout (`SSEND R9 :deal_attack n=3|nk=1`): n positionals after the
  # destination, then nk (sym, value) pairs. Only literal keys (a LOADSYM,
  # verified by backward scan) are supported. The callee must be MONO, compile
  # clean, have a keyword_arg_table covering the keys, and match the positional
  # arity. A missing optional keyword passes mrb_nil_value() + given=0 (what
  # the entry wrapper does); a missing required one is refused (the interpreter
  # would raise ArgumentError).
  #
  # literal_symbol_write: was `reg`'s most recent write (scanning back from
  # `before_idx`, inclusive) a `LOADSYM :name`? Shared by compile_keyword_send
  # and splat_hash_literal_pairs.
  def literal_symbol_write(irep, before_idx, reg)
    before_idx.downto(0) do |i|
      insn = irep.instructions[i]
      next unless insn
      # A write to this register ends the scan -- it must be LOADSYM.
      next unless insn.args =~ /^R#{reg}\b/

      return nil unless insn.op == 'LOADSYM'

      return insn.args[/:(\S+)/, 1]&.sub(/\A:/, '')
    end
    nil
  end

  # KEYWORD_CALLSITE_SUPPORT: the shared tail of compile_keyword_send (MONO
  # resolution, keyword/arity checks, `_impl` call), reused by compile_splat_send
  # for unrolled splat register lists. argv/kw_val_exprs are C++ expressions.
  def compile_keyword_call(name:, d:, recv:, n:, argv:, kw_names:, kw_val_exprs:,
                           self_implicit: false, owner_def: nil)
    # MONO only, no TYPED: the guard's else branch would need a dynamic keyword
    # dispatch, which mrb_funcall cannot express. MONO needs no guard.
    target = monomorphic_target(name)
    # LEXICAL_SELF_KEYWORD_SUPPORT: a POLY name can still have one reachable
    # definition for an implicit-self send in a class with no subclasses (see
    # lexical_self_keyword_target). A certain, not traced, fact, so no guard or
    # fallback; the checks below apply unchanged. Only consulted after
    # monomorphic_target declined.
    lexical_self = false
    if target.nil?
      target = lexical_self_keyword_target(name, self_implicit: self_implicit, owner_def: owner_def)
      lexical_self = !target.nil?
    end
    return nil unless target&.irep

    # monomorphic_target already checked compiles_clean?; fetch the irep for the
    # checks below.
    callee_irep = @ireps.fetch(target.irep)
    kw_table = keyword_arg_table(callee_irep)
    return nil unless kw_table
    # KEYWORD_CALLSITE_OPTIONAL_POSITIONAL_SUPPORT: the callee's positional arity
    # is [mand, mand + opt]; with opt 0 this is the old exact match.
    # Sound per vm.c OP_ENTER with kd set: OP_SEND packs the nk pairs into one Hash
    # at regs[mrb_ci_kidx(ci)] and sets `ci->nk = CALL_MAXARGS`, so argc counts
    # positionals only (the `!kd` fold-back arm is unreachable since
    # keyword_arg_table requires kw > 0). Optional-slot resolution is then a
    # function of argc alone: the check admits m1 <= argc <= len (len = m1 + o
    # here) and the initializer skip picks jump-table entry argc - m1, which is
    # `bc2cpp_given_opt`; the call site's static `n - t_mand` reproduces it.
    # optional_arg_table's jump targets must have resolved (not just opt > 0),
    # since bc2cpp_given_opt only means this when the callee's dispatch switch was
    # emitted.
    t_mand = mandatory_arity(callee_irep)
    t_opt = optional_arity(callee_irep)
    return nil unless n.between?(t_mand, t_mand + t_opt)
    return nil if t_opt.positive? && !optional_arg_table(callee_irep)[1]
    return nil unless (kw_names - kw_table.map { |k| k[:name] }).empty?

    # Every required keyword must be present, or the interpreter raises
    # ArgumentError.
    required = kw_table.select { |k| k[:required] }.map { |k| k[:name] }
    return nil unless (required - kw_names).empty?

    # Same emission-eligibility guard as compile_send: no `_impl` for owners this
    # run does not emit.
    if @only_owners && !@only_owners.include?(target.owner)
      return nil unless @other_owners&.include?(target.owner)
    end
    impl = cpp_name(target.owner, target.name) + '_impl'
    # KEYWORD_CALLSITE_ARITY_FIX: the argument list must match the callee's
    # `_impl` exactly: compile_method adds `mrb_int bc2cpp_kw_given_<name>` only
    # for OPTIONAL keywords (`kw[:required] ? [value] : [value, given]`), since
    # mrb_get_args already guarantees required ones. Emitting a flag for every
    # keyword shifted later arguments (g++: "could not convert '1'" / "too many
    # arguments").
    # A required keyword is never absent here (refused above), so the
    # "not passed" arm applies only to optional keywords.
    kw_args = kw_table.flat_map do |kw|
      ci = kw_names.index(kw[:name])
      val = ci ? kw_val_exprs[ci] : 'mrb_nil_value()'
      kw[:required] ? [val] : [val, ci ? '1' : '0']
    end
    # KEYWORD_CALLSITE_OPTIONAL_POSITIONAL_SUPPORT: `_impl`'s parameters are all
    # `mand + opt` positionals, then `mrb_int bc2cpp_given_opt` when opt > 0, then
    # the keywords, e.g.
    #
    #   mrb_value Game__Battle_deal_attack_impl(mrb_state* M, mrb_value self,
    #       mrb_value b, mrb_value target, mrb_value swing_index,
    #       mrb_int bc2cpp_given_opt,
    #       mrb_value bc2cpp_kwarg_charged, mrb_int bc2cpp_kw_given_charged)
    #
    # so the padding goes BEFORE kw_args (appending would shift every keyword, the
    # KEYWORD_CALLSITE_ARITY_FIX error class). Omitted optionals get
    # mrb_nil_value(), never read because the callee's switch jumps to the default
    # code, which overwrites the register.
    opt_args = []
    if t_opt.positive?
      opt_args = Array.new(t_mand + t_opt - argv.size, 'mrb_nil_value()')
      opt_args << (argv.size - t_mand).to_s
    end
    call = "r#{d} = #{impl}(M, #{([recv] + argv + opt_args + kw_args).join(', ')});"
    # LEXICAL_SELF_KEYWORD_SUPPORT: a marker distinct from MONO (one definition
    # program-wide vs. a provably exact self class), spelled like compile_send's
    # LEXICAL_SELF, and absent from RUNTIME_DEF_DYNAMIC_MARKERS so
    # runtime_def_devirt_audit checks it.
    note =
      if lexical_self
        "  // LEXICAL_SELF :#{name} -> #{target.owner}##{target.name} (keyword call; self, statically " \
          "known -- #{target.owner} has no subclasses anywhere in this closed world, so this " \
          "implicit-self send can reach no other definition of this POLY name), direct C++ call " \
          "(no mrb_funcall)\n"
      else
        "  // MONO :#{name} -> #{target.owner}##{target.name} (keyword call), direct C++ call (no mrb_funcall)\n"
      end
    "#{note}  #{call}\n"
  end

  def compile_keyword_send(args, self_implicit:, irep:, idx:, owner_def:, name:, d:, n:, nk:)
    dest_reg = d.to_i
    # Keyword (sym, value) pairs sit right after the n positionals.
    kw_sym_regs = (0...nk).map { |k| dest_reg + 1 + n + k * 2 }
    kw_val_regs = (0...nk).map { |k| dest_reg + 2 + n + k * 2 }
    # Every key register must be written by a literal LOADSYM (backward scan in
    # this irep).
    kw_names = kw_sym_regs.map { |reg| literal_symbol_write(irep, idx, reg) }
    return nil if kw_names.any?(&:nil?)

    recv = self_implicit ? 'self' : "r#{d}"
    argv = (1..n).map { |k| "r#{dest_reg + k}" }
    direct = compile_keyword_call(name: name, d: d, recv: recv, n: n, argv: argv,
                                  kw_names: kw_names, kw_val_exprs: kw_val_regs.map { |r| "r#{r}" },
                                  self_implicit: self_implicit, owner_def: owner_def)
    return direct if direct

    # KEYWORD_DIRECT_CONSTRUCT_SUPPORT: for `:new`, compile_keyword_call always
    # declines (Class#new has no `_impl`); the keywords belong to the target
    # class's #initialize. Tried before the Hash-as-positional fallback, which
    # correctly refuses real keyword callees.
    construct = compile_keyword_direct_construct(
      irep: irep, idx: idx, owner_def: owner_def, self_implicit: self_implicit,
      name: name, d: d, n: n, recv: recv, argv: argv, kw_names: kw_names,
      kw_val_exprs: kw_val_regs.map { |r| "r#{r}" }
    )
    return construct if construct

    # KEYWORD_HASH_POSITIONAL_SUPPORT: many sites compile_keyword_call declines are
    # not real keyword calls (the callee declares no keywords). `self_implicit`/
    # `owner_def` let that path use the lexical-self narrowing
    # (KEYWORD_HASH_LEXICAL_SELF_SUPPORT) when the every-def gate declines.
    hashpos = compile_keyword_hash_positional_send(name: name, d: d, recv: recv, n: n, nk: nk,
                                                   argv: argv, kw_sym_regs: kw_sym_regs,
                                                   kw_val_regs: kw_val_regs, kw_names: kw_names,
                                                   self_implicit: self_implicit, owner_def: owner_def)
    return hashpos if hashpos

    # KEYWORD_NEVER_DEFINED_CONST_RECEIVER_SUPPORT: tried last: every other proof
    # declined, but the receiver provably never exists at runtime (see
    # compile_keyword_never_defined_const_send).
    compile_keyword_never_defined_const_send(name: name, d: d, n: n, nk: nk, irep: irep, idx: idx,
                                             argv: argv, kw_sym_regs: kw_sym_regs,
                                             kw_val_regs: kw_val_regs, kw_names: kw_names,
                                             self_implicit: self_implicit)
  end

  # KEYWORD_DIRECT_CONSTRUCT_SUPPORT: `Foo.new(a, b, k1: v1, k2: v2)` where Foo
  # is in DIRECT_CONSTRUCT_TARGETS and its #initialize declares these keywords,
  # matched by name.
  #   * compile_keyword_call cannot fire: it resolves `:new` (Class#new, no
  #     `_impl`, no keywords); the keywords belong to Foo#initialize, found via
  #     trace_new_target.
  #   * compile_keyword_hash_positional_send must not fire: it relies on the
  #     callee declaring NO keywords (OP_ENTER's kd == 0 turns the Hash into a
  #     trailing positional). Here kd == 1, so that would drop the keywords.
  # Emits the guarded bc2cpp_direct_alloc + `_impl` construct of compile_send's
  # DIRECT_CONSTRUCT_TARGETS branch, with compile_keyword_call's (value, given)
  # keyword arguments.
  # Gate: compile_send's DIRECT_CONSTRUCT_TARGETS gate with
  # mandatory_optional_and_keyword_arity? in place of pure_mandatory_arity?,
  # plus:
  #   a. keywords matched by exact name, and every required keyword present;
  #   b. no `self.new`/`self.allocate` defined ANYWHERE in the closed world
  #      (some entries are subclasses, and an inherited custom `self.new` would
  #      defeat the construct; @superclass_of may lack computed superclasses, so
  #      the whole-program question is the sound one). Adding one shuts this
  #      path off;
  #   c. #initialize's return value is discarded (`.new` returns the object).
  # nil (a safe miss) otherwise.
  def compile_keyword_direct_construct(irep:, idx:, owner_def:, self_implicit:,
                                       name:, d:, n:, recv:, argv:, kw_names:, kw_val_exprs:)
    return nil unless name == 'new' && !self_implicit && irep && idx

    known = trace_new_target(irep, idx, d, nil, 0, nil, resolving_new: true, owner: owner_def&.owner,
                             canonical: false)
    return nil unless known && DIRECT_CONSTRUCT_TARGETS.include?(known)

    # 1/2: no custom `self.new`/`self.allocate` on this class ("X.singleton"), and
    # by (b) above none anywhere, which covers inherited ones.
    no_custom_new = @registry['new'].none? { |md| md.owner == "#{known}.singleton" }
    no_custom_allocate = @registry['allocate'].none? { |md| md.owner == "#{known}.singleton" }
    return nil unless no_custom_new && no_custom_allocate

    none_anywhere = (@registry['new'] + @registry['allocate'])
                    .none? { |md| md.owner.to_s.end_with?('.singleton') }
    return nil unless none_anywhere

    # 3: #initialize is a compiling positionals-plus-keywords leaf whose
    # positional arity range covers this call's count.
    init_def = @registry['initialize'].find { |md| md.owner == known }
    return nil unless init_def&.irep

    init_irep = @ireps.fetch(init_def.irep)
    return nil unless mandatory_optional_and_keyword_arity?(init_irep)
    return nil unless compiles_clean?(init_def.irep)

    # KEYWORD_CONSTRUCT_OPTIONAL_POSITIONAL_SUPPORT: #initialize's positional
    # arity is [mand, mand + opt] (0 optional for older entries: an exact match).
    # Class#new forwards all arguments to #initialize, so the OP_ENTER argument of
    # KEYWORD_CALLSITE_OPTIONAL_POSITIONAL_SUPPORT (compile_keyword_call) applies:
    # with kd set, argc counts positionals only and the jump-table entry is
    # argc - m1 = `bc2cpp_given_opt`. The optional table's jump targets must have
    # resolved.
    t_mand = mandatory_arity(init_irep)
    t_opt = optional_arity(init_irep)
    return nil unless n.between?(t_mand, t_mand + t_opt)
    return nil if t_opt.positive? && !optional_arg_table(init_irep)[1]

    # (a): exact keyword-name match, and every required keyword supplied.
    kw_table = keyword_arg_table(init_irep)
    return nil unless kw_table
    return nil unless (kw_names - kw_table.map { |k| k[:name] }).empty?

    required = kw_table.select { |k| k[:required] }.map { |k| k[:name] }
    return nil unless (required - kw_names).empty?

    # 4: the ONLY_OWNERS/OTHER_OWNERS emission guard.
    owner_emitted = !@only_owners || @only_owners.include?(known) || @other_owners&.include?(known)
    return nil unless owner_emitted

    @direct_construct_used << known
    accessor = direct_construct_class_fn(known)
    init_impl = cpp_name(known, 'initialize') + '_impl'
    # (value, given) arguments as in compile_keyword_call (see
    # KEYWORD_CALLSITE_ARITY_FIX).
    kw_args = kw_table.flat_map do |kw|
      ci = kw_names.index(kw[:name])
      val = ci ? kw_val_exprs[ci] : 'mrb_nil_value()'
      kw[:required] ? [val] : [val, ci ? '1' : '0']
    end
    # KEYWORD_CONSTRUCT_OPTIONAL_POSITIONAL_SUPPORT: `_impl` takes `mand + opt`
    # positionals, then `bc2cpp_given_opt`, then the keywords:
    #
    #   mrb_value Game__Battle_initialize_impl(mrb_state* M, mrb_value self,
    #       mrb_value allies, mrb_value enemies, mrb_value rng,
    #       mrb_value states, mrb_value variance, mrb_value criticals,
    #       mrb_value accuracy, mrb_value first_strike, mrb_value attributes,
    #       mrb_value ai, mrb_int bc2cpp_given_opt,
    #       mrb_value bc2cpp_kwarg_rpg2003, mrb_int bc2cpp_kw_given_rpg2003,
    #       mrb_value bc2cpp_kwarg_party,   mrb_int bc2cpp_kw_given_party,
    #       mrb_value bc2cpp_kwarg_battle_type,
    #       mrb_int bc2cpp_kw_given_battle_type);
    #
    # so padding is spliced before kw_args (as in compile_keyword_call).
    # Placeholders are never read (the default code overwrites them). A short
    # argument list would be a g++ error, so omitted optionals are padded.
    opt_args = []
    if t_opt.positive?
      opt_args = Array.new(t_mand + t_opt - argv.size, 'mrb_nil_value()')
      opt_args << (argv.size - t_mand).to_s
    end
    note = "  // MONO :new -> #{known}, direct compiled construct with real KEYWORD arguments " \
           "(bc2cpp_direct_alloc + #{init_impl}) -- skips Class#new's own allocate+initialize " \
           "dispatch chain entirely; #{known}#initialize's own return value is discarded (real " \
           "Ruby .new always returns the new object, never whatever #initialize itself returns).\n" \
           "  // The keywords here are REAL keyword parameters of #{known}#initialize (matched by " \
           "NAME against its own KEY_P/KARG table, not by count), passed as the same explicit " \
           "(value, given) pairs its compiled _impl signature already declares -- NOT packed into " \
           "a trailing positional Hash, which is only correct for a callee declaring no keywords " \
           "at all (vm.c OP_ENTER's own kd == 0 arm; see compile_keyword_hash_positional_send).\n" \
           "  // Runtime-guarded exactly the way the non-keyword direct-construct path is: " \
           "#{known} could have been reassigned at the constant level since #{accessor}'s own " \
           "class was captured at gem-init, so #{recv} (this call site's own already-resolved " \
           "receiver) is compared against it rather than trusted outright, falling back to " \
           "ordinary mrb_funcall if they differ.\n"
    # The guard-miss arm: mrb_funcall cannot carry keywords (`ci->nk = 0`), and
    # OP_ENTER has no trailing-Hash-to-keywords conversion for kd == 1, so a plain
    # funcall would silently drop them (and, the keywords being optional, not
    # raise). Instead the pairs are packed into one Hash passed as a trailing
    # positional, exactly what OP_SEND does before OP_ENTER (hash_new_from_regs;
    # see compile_keyword_hash_positional_send). The arm is only reachable if the
    # constant was reassigned after gem init; the keys come from the literal
    # symbols literal_symbol_write proved.
    kw_hash = String.new
    kw_hash << "    mrb_value bc2cpp_kwh = mrb_hash_new_capa(M, #{kw_names.size});\n"
    kw_names.each_with_index do |kn, k|
      kw_hash << "    mrb_hash_set(M, bc2cpp_kwh, " \
                 "mrb_symbol_value(mrb_intern_cstr(M, \"#{kn}\")), #{kw_val_exprs[k]});\n"
    end
    "#{note}" \
      "  if (mrb_class_ptr(#{recv}) == #{accessor}()) {\n" \
      "    r#{d} = bc2cpp_direct_alloc(M, mrb_class_ptr(#{recv}));\n" \
      "    #{init_impl}(M, #{(["r#{d}"] + argv + opt_args + kw_args).join(', ')});\n" \
      "  } else {\n" \
      "#{kw_hash}" \
      "    #{dynamic_dispatch_line(d, recv, name, argv + ['bc2cpp_kwh'])}" \
      "  }\n"
  end

  # KEYWORD_HASH_POSITIONAL_SUPPORT: a SEND/SSEND with `n=N|nk=K` whose callee
  # declares NO keyword parameters: the VM hands it one ordinary trailing
  # positional Hash (`def foo(opts)`). Only the call site needs work.
  # Callee entry shapes:
  #     def bar(h)      ->  ENTER 1:0:0:0:0:0:0:0   (kw=0, kwrest=0)
  #     def baz(a, h)   ->  ENTER 2:0:0:0:0:0:0:0
  #     def kw(a, name: nil, x: 0)
  #                     ->  ENTER 1:0:0:0:2:0:0:0   (kw=2), then KEY_P ... KEYEND
  # and the call-site layout is compile_keyword_send's (n positionals, then K
  # (sym, value) pairs):
  #   f.bar(name: 1, x: 2)     ->  19 022 LOADSYM  R3  :name
  #                                19 025 LOADI_1  R4  (1)
  #                                19 027 LOADSYM  R5  :x
  #                                19 030 LOADI_2  R6  (2)
  #                                19 032 SEND     R2  :bar   n=0|nk=2
  #
  # vm.c semantics:
  #   1. OP_SEND packs unconditionally, knowing nothing about the callee:
  #        else if (nk > 0) {  /* pack keyword arguments */
  #          mrb_int kidx = a+(n==CALL_MAXARGS?1:n)+1;
  #          mrb_value kdict = hash_new_from_regs(mrb, nk, kidx);
  #          regs[kidx] = kdict;
  #          nk = CALL_MAXARGS;
  #   2. OP_ENTER decides what the Hash means:
  #        mrb_int kd = (MRB_ASPEC_KEY(a) > 0 || MRB_ASPEC_KDICT(a))? 1 : 0;
  #        ...
  #        if (!kd) {
  #          if (!mrb_nil_p(kdict) && mrb_hash_p(kdict) && mrb_hash_size(mrb, kdict) > 0) {
  #            if (argc < 14) {
  #              ci->n++;
  #              argc++;    /* include kdict in normal arguments */
  #            }
  #            ...
  #          }
  #          kdict = mrb_nil_value();
  #          ci->nk = 0;
  #      i.e. with kd == 0 the Hash is appended to the positionals and nk is 0.
  # So the translation is: build the Hash from the K pairs, then an ordinary
  # positional call with N+1 arguments. mrb_funcall's `ci->nk = 0` is exactly the
  # state OP_ENTER would produce anyway.
  #
  # Soundness gate: keyword_hash_positional_callee?(irep, n + 1) on EVERY
  # registry def of the name:
  #   - key/kdict zero (kd == 0) and rest/post/block/noblock zero; optional
  #     positionals are fine (the Hash lands in the next free slot)
  #     (KEYWORD_HASH_POSITIONAL_OPTIONAL_ARG_SUPPORT);
  #   - `total.between?(mand, mand + opt)`: only argc ranges OP_ENTER accepts;
  #   - every def, because mrb_funcall resolves at runtime, so all possible
  #     targets must agree (`:load_h`, five `(h)` defs, compiles;
  #     `:close_message`, whose defs disagree, does not);
  #   - a `<native>` def fails (its argument spec is invisible), which keeps
  #     `:new` sites out;
  #   - `n < 14`, vm.c's `if (argc < 14)` arm.
  # KEYWORD_HASH_LEXICAL_SELF_SUPPORT: when the every-def gate fails, an
  # implicit-self send in a class with no subclasses can only reach that class's
  # def (lexical_self_keyword_target), so the gate runs against that def alone.
  # The marker stays KEYWORD_HASH_POSITIONAL (a dynamic bind).
  # KEYWORD_HASH_DEVIRT_SUPPORT: once packed it is an ordinary positional send of
  # `total = n + 1` arguments, so MONO (monomorphic_target plus arity in [mand,
  # mand + opt], ONLY_OWNERS, no NATIVE_ARG_TARGETS positions; optional padding
  # as in compile_keyword_call) and then POLY_SMALL_N (compile_poly_small_n with
  # the Hash appended) apply. TYPED is not attempted (no trace context here).
  # Marked KEYWORD_HASH_DEVIRT.
  # Returns the C++ or nil.
  def compile_keyword_hash_positional_send(name:, d:, recv:, n:, nk:, argv:, kw_sym_regs:,
                                           kw_val_regs:, kw_names:, self_implicit:, owner_def:)
    # vm.c's `if (argc < 14)` arm.
    return nil unless nk.positive? && n < 14

    defs = @registry[name]
    return nil if defs.nil? || defs.empty?

    total = n + 1
    all_keyword_free = defs.all? do |t|
      # A native def's argument spec is invisible, so it cannot be proven
      # keyword-free.
      next false unless t.irep

      callee_irep = @ireps[t.irep]
      next false unless callee_irep

      keyword_hash_positional_callee?(callee_irep, total)
    end

    # KEYWORD_HASH_LEXICAL_SELF_SUPPORT: retry against the one def this
    # implicit-self site can reach; anything else is a safe miss.
    lexical_self = nil
    unless all_keyword_free
      lexical_self = lexical_self_keyword_target(name, self_implicit: self_implicit, owner_def: owner_def)
      return nil unless lexical_self

      callee_irep = @ireps[lexical_self.irep]
      return nil unless callee_irep && keyword_hash_positional_callee?(callee_irep, total)
    end

    out = String.new
    if lexical_self
      out << "  // KEYWORD_HASH_POSITIONAL :#{name} (n=#{n}|nk=#{nk}) -- POLY name program-wide, but this " \
             "is an implicit-self call inside a #{lexical_self.owner} method and #{lexical_self.owner} has " \
             "NO SUBCLASS anywhere in this closed world, so the only def this send can reach is " \
             "#{lexical_self.owner}##{name}, which declares NO keyword parameters and accepts #{total} " \
             "positional arguments; real src/vm.c OP_ENTER (`if (!kd) { ... ci->n++; argc++; }`) delivers " \
             "the #{nk} keyword pair(s) to exactly it as ONE ordinary trailing positional Hash, as built " \
             "here by OP_SEND's own hash_new_from_regs. Not a keyword call at runtime at all.\n"
    else
      owners = defs.map(&:owner).join(', ')
      out << "  // KEYWORD_HASH_POSITIONAL :#{name} (n=#{n}|nk=#{nk}) -- every real def of this name " \
             "(#{owners}) declares NO keyword parameters and accepts #{total} positional arguments, " \
             "so real src/vm.c OP_ENTER (`if (!kd) { ... ci->n++; argc++; }`) delivers the " \
             "#{nk} keyword pair(s) as ONE ordinary trailing positional Hash, exactly as built here by " \
             "OP_SEND's own hash_new_from_regs. Not a keyword call at runtime at all.\n"
    end
    out << "  {\n"
    out << "    mrb_value bc2cpp_kwh = mrb_hash_new_capa(M, #{nk});\n"
    nk.times do |k|
      out << "    mrb_hash_set(M, bc2cpp_kwh, r#{kw_sym_regs[k]}, r#{kw_val_regs[k]});" \
             "  // :#{kw_names[k]}\n"
    end
    out << "    #{keyword_hash_devirt_line(name: name, d: d, recv: recv, argv: argv, total: total)}"
    out << "  }\n"
    out
  end

  # KEYWORD_HASH_DEVIRT_SUPPORT dispatch tail for the packed-Hash call: MONO, then
  # POLY_SMALL_N, else dynamic dispatch.
  def keyword_hash_devirt_line(name:, d:, recv:, argv:, total:)
    ext_argv = argv + ['bc2cpp_kwh']
    target = monomorphic_target(name)
    if target
      t_irep = @ireps.fetch(target.irep)
      t_mand = mandatory_arity(t_irep)
      t_opt = optional_arity(t_irep)
      if pure_mandatory_or_optional_arity?(t_irep) &&
         total.between?(t_mand, t_mand + t_opt) &&
         native_arg_types(target, t_mand).compact.empty? &&
         (!@only_owners || @only_owners.include?(target.owner) || @other_owners&.include?(target.owner))
        impl = cpp_name(target.owner, target.name) + '_impl'
        call_argv = ext_argv.dup
        if t_opt.positive?
          call_argv += Array.new(t_mand + t_opt - ext_argv.size, 'mrb_nil_value()')
          call_argv << (ext_argv.size - t_mand).to_s
        end
        return "  // KEYWORD_HASH_DEVIRT :#{name} -> #{target.owner}##{target.name} (MONO, trailing-Hash " \
               "positional, direct C++ call, no mrb_funcall)\n" \
               "    r#{d} = #{impl}(M, #{([recv] + call_argv).join(', ')});\n"
      end
    end
    chained = compile_poly_small_n(name, d, recv, ext_argv, total)
    return chained.sub('POLY_SMALL_N', 'KEYWORD_HASH_DEVIRT/POLY_SMALL_N') if chained

    dynamic_dispatch_line(d, recv, name, ext_argv)
  end

  # KEYWORD_NEVER_DEFINED_CONST_RECEIVER_SUPPORT: memoized
  # IntegerConstants.defined_name_universe; without NATIVE_SRCS/FOREIGN_RUBY_SRCS
  # the picture is incomplete and no proof runs.
  def keyword_never_defined_universe
    return @keyword_never_defined_universe if defined?(@keyword_never_defined_universe)

    @keyword_never_defined_universe =
      if ENV['NATIVE_SRCS'] && ENV['FOREIGN_RUBY_SRCS']
        IntegerConstants.defined_name_universe(@ireps, Shellwords.split(ENV['NATIVE_SRCS']),
                                               Shellwords.split(ENV['FOREIGN_RUBY_SRCS']))
      end
  end

  # KEYWORD_NEVER_DEFINED_CONST_RECEIVER_SUPPORT: a keyword SEND whose receiver
  # is a bare constant defined NOWHERE in the closed world is unreachable:
  #   1. the name is absent from defined_name_universe (SETCONST/SETMCNST/
  #      CLASS/MODULE opcodes, native const/class/module definitions, foreign
  #      `NAME =`/class/module);
  #   2. such a GETCONST compiles to the bc2cpp_const_try chain ending in
  #      mrb_const_get from Object, which raises NameError (src/variable.c);
  #   3. the receiver register's first write before the call is that GETCONST,
  #      and no jump or catch target lands strictly between it and the send.
  # So the send never executes. It is still emitted in the faithful OP_SEND form
  # (pairs packed into one trailing Hash, dynamic dispatch) so a broken proof
  # yields a well-formed send.
  # Holes (as for every whole-program gate): runtime const_set, unscanned gems,
  # eval. None define constants here (optcarrot's evals are on the `--opt`
  # path). The shape: optcarrot NES#run's guarded `StackProf.start(...)`.
  def compile_keyword_never_defined_const_send(name:, d:, n:, nk:, irep:, idx:, argv:,
                                               kw_sym_regs:, kw_val_regs:, kw_names:,
                                               self_implicit:)
    return nil if self_implicit
    return nil unless nk.positive?

    universe = keyword_never_defined_universe
    return nil if universe.nil?

    send_insn = irep.instructions[idx]
    return nil unless send_insn && send_insn.op == 'SEND'

    recv_reg = d.to_i
    write = nil
    (idx - 1).downto(0) do |i|
      insn = irep.instructions[i]
      next unless insn
      # The first write to the receiver register must be the constant read itself.
      next unless insn.args =~ /^R#{recv_reg}\b/

      write = insn
      break
    end
    return nil unless write && write.op == 'GETCONST'

    const_name = write.args[/^R\d+\s+(\S+)/, 1]
    return nil unless const_name&.match?(/\A[A-Z][A-Za-z_0-9]*\z/)
    return nil if universe.include?(const_name)

    # No jump target or handler entry may land in (write, send]: that edge would
    # reach the send without the raising GETCONST.
    blocked = jump_targets(irep)
    irep.catch_handlers&.each { |ch| blocked << ch.target }
    return nil if blocked.any? { |t| t > write.addr && t <= send_insn.addr }

    out = String.new
    out << "  // KEYWORD_NEVER_DEFINED_CONST :#{name} (n=#{n}|nk=#{nk}) -- receiver is the value of " \
           "GETCONST `#{const_name}` (addr #{write.addr}), a constant with NO definition anywhere in this " \
           "closed world (no SETCONST/SETMCNST, no CLASS/MODULE, no native mrb_define_const/const_set/" \
           "define_class/define_module, no foreign-source assignment), so that GETCONST's own scope-chain " \
           "raises NameError and this send is dynamically unreachable -- no jump or handler entry lands " \
           "between the two. The keyword packing and real dynamic dispatch emitted below are the " \
           "faithful OP_SEND shape for a call that cannot execute.\n"
    out << "  {\n"
    out << "    mrb_value bc2cpp_kwh = mrb_hash_new_capa(M, #{nk});\n"
    nk.times do |k|
      out << "    mrb_hash_set(M, bc2cpp_kwh, r#{kw_sym_regs[k]}, r#{kw_val_regs[k]});" \
             "  // :#{kw_names[k]}\n"
    end
    out << "    #{dynamic_dispatch_line(d, "r#{d}", name, argv + ['bc2cpp_kwh'])}"
    out << "  }\n"
    out
  end

  # SPLAT_UNROLL_SUPPORT: the argument expressions of the literal Array built at
  # `reg` (traced back, MOVEs followed). vm.c OP_SEND with n == CALL_MAXARGS
  # spreads whatever Array is in R(d+1) at runtime, so a fixed list exists only
  # if that register was built by a literal `ARRAY Rd N`.
  # Elements are read with `mrb_ary_ref(M, r<base>, k)`, not the source
  # registers: OP_ARRAY overwrites r<base> (element 0's register) with the Array,
  # so a bare r<base> would pass the Array as the first argument.
  # Returns C++ expressions or nil.
  def splat_array_literal_regs(irep, idx, reg)
    hops = 0
    (idx - 1).downto(0) do |i|
      insn = irep.instructions[i]
      next unless insn
      # Skip the block proc register (see array_element_source_scan).
      next if insn.op == 'BLOCK'
      next unless insn.args[/^R(\d+)/, 1] == reg

      case insn.op
      when 'MOVE'
        hops += 1
        return nil if hops > 8

        src = insn.args.scan(/R(\d+)/).flatten[1]
        return nil unless src

        reg = src
        next
      when 'ARRAY', 'ARRAY2'
        n = insn.args[/^R\d+\s+(\d+)/, 1]&.to_i
        return nil if n.nil?

        base = reg.to_i
        return (0...n).map { |k| "mrb_ary_ref(M, r#{base}, #{k})" }
      else
        return nil
      end
    end
    nil
  end

  # SPLAT_UNROLL_SUPPORT: the double-splat analogue: a literal `HASH Rd N` (pairs
  # at Rd..Rd+2N-1, see hash_element_source_scan) whose keys are all literal
  # LOADSYMs (needed to match the callee's keyword table). Returns [{name:,
  # val_reg:}] in order, or nil.
  def splat_hash_literal_pairs(irep, idx, reg)
    hops = 0
    (idx - 1).downto(0) do |i|
      insn = irep.instructions[i]
      next unless insn
      next if insn.op == 'BLOCK'
      next unless insn.args[/^R(\d+)/, 1] == reg

      case insn.op
      when 'MOVE'
        hops += 1
        return nil if hops > 8

        src = insn.args.scan(/R(\d+)/).flatten[1]
        return nil unless src

        reg = src
        next
      when 'HASH'
        n = insn.args[/^R\d+\s+(\d+)/, 1]&.to_i
        return nil if n.nil?

        base = reg.to_i
        return (0...n).map do |k|
          key_reg = base + (2 * k)
          val_reg = base + (2 * k) + 1
          kname = literal_symbol_write(irep, i - 1, key_reg.to_s)
          return nil unless kname

          { name: kname, val_reg: "r#{val_reg}" }
        end
      else
        return nil
      end
    end
    nil
  end

  # SPLAT_UNROLL_SUPPORT: a `n=*` and/or `nk=*` call site compiles as an ordinary
  # call when the splatted Array/Hash traces to a fixed-size literal; otherwise
  # `#error`. Plain positional unrolls use dynamic dispatch; keyword-carrying
  # ones use compile_keyword_call's MONO `_impl` call (mrb_funcall cannot carry
  # keywords).
  # DYNAMIC_SPLAT_SUPPORT: a plain `n=*` (no `|nk=`) with a non-literal source
  # (`foo(*list)`): mrbc always builds the complete argument Array in R(dest+1)
  # before the SEND (ARRAY-then-ARYCAT, or LOADNIL-then-ARYCAT when the first
  # argument is a splat), so mrb_funcall_argv with its RARRAY_LEN/RARRAY_PTR is
  # exact. Keyword variants have no such translation and keep `#error`.
  def compile_dynamic_splat_send(name, recv, d, argv_reg)
    <<~CPP
      // SPLAT n=* :#{name} runtime-sized (not a literal), dynamic dispatch via mrb_funcall_argv
      r#{d} = mrb_funcall_argv(M, #{recv}, mrb_intern_cstr(M, "#{name}"), RARRAY_LEN(r#{argv_reg}), RARRAY_PTR(r#{argv_reg}));
    CPP
  end

  def compile_splat_send(args, self_implicit:, irep:, idx:, name:, d:, owner_def: nil)
    return nil unless irep && idx

    n_match = args.match(/n=(\d+|\*)(?:\|nk=(\d+|\*))?/)
    return nil unless n_match

    n_spec, nk_spec = n_match[1], n_match[2]
    return nil unless n_spec == '*' || nk_spec == '*'

    dest_reg = d.to_i
    recv = self_implicit ? 'self' : "r#{d}"

    next_reg = dest_reg + 1
    if n_spec == '*'
      positional = splat_array_literal_regs(irep, idx, next_reg.to_s)
      if positional.nil?
        return nil if nk_spec

        return compile_dynamic_splat_send(name, recv, d, next_reg)
      end

      next_reg += 1 # the single register the splatted array itself occupied.
    else
      n = n_spec.to_i
      positional = (1..n).map { |k| "r#{dest_reg + k}" }
      next_reg += n
    end

    kw_pairs =
      if nk_spec == '*'
        pairs = splat_hash_literal_pairs(irep, idx, next_reg.to_s)
        return nil unless pairs

        pairs
      elsif nk_spec
        nk = nk_spec.to_i
        (0...nk).map do |k|
          key_reg = next_reg + (k * 2)
          val_reg = next_reg + (k * 2) + 1
          kname = literal_symbol_write(irep, idx, key_reg.to_s)
          return nil unless kname

          { name: kname, val_reg: "r#{val_reg}" }
        end
      else
        []
      end

    if kw_pairs.empty?
      note = "  // SPLAT #{n_match[0]} :#{name} unrolled from a literal-sized splat, dynamic dispatch\n"
      "#{note}  #{dynamic_dispatch_line(d, recv, name, positional)}"
    else
      result = compile_keyword_call(name: name, d: d, recv: recv, n: positional.size, argv: positional,
                                     kw_names: kw_pairs.map { |p| p[:name] },
                                     kw_val_exprs: kw_pairs.map { |p| p[:val_reg] },
                                     self_implicit: self_implicit, owner_def: owner_def)
      return nil unless result

      note = "  // SPLAT #{n_match[0]} :#{name} unrolled from a literal-sized splat/double-splat\n"
      "#{note}#{result}"
    end
  end

  def compile_send(args, self_implicit:, irep: nil, idx: nil, owner_def: nil,
                   call_receiver: nil, call_arguments: nil, trace_idx: nil, trace_receiver_reg: nil,
                   trace_reg_offset: 0, typed_fallback: nil)
    # ELEMENT_CLASS_SUPPORT: consume the element hint before anything else
    # (including compiles_clean? probes that re-enter compile_method), so no other
    # call site can read it.
    elem_class_hint = @elem_class_hint
    @elem_class_hint = nil
    d = args[/^R(\d+)/, 1]
    # The method-name charset must include `?`, `!` and every operator character
    # (`&`, `|`, `^`, `~`, `%`, `@` for `-@`/`+@`). A missing character truncates
    # the name (`key?` -> "key") or yields "" (`flags & x` -> `mrb_funcall(M, r6,
    # "", ...)`): the C++ compiles and links, then raises NoMethodError at runtime,
    # which no `#error` check catches. Keep every copy of this charset in sync.
    name = args[/:([\w+\-*\/<>=!?\[\]&|^~%@]+)/, 1]
    # Parse `n=` including the other print_args shapes (src/codedump.c):
    #   - "n=3|nk=1": keyword pairs, which OP_SEND packs into a Hash at runtime;
    #   - "n=*": a splat (CALL_MAXARGS) with no fixed register list.
    # A bare `/n=(\d+)/` misparsed both (nil.to_i == 0), silently dropping splatted
    # arguments or keyword hashes (e.g. `charged:`, `keep:`, `preserve_mod: false`)
    # while compiling cleanly. Such sites now go to the keyword/splat paths or get
    # `#error` (SKIP_UNSUPPORTED keeps them interpreted). SEND0/SSEND0 print no
    # `n=` (vm.c OP_SEND0 has c=0), so nil still means n=0.
    n_match = args.match(/n=(\d+|\*)(?:\|nk=(\d+|\*))?/)
    if n_match && (n_match[1] == '*' || n_match[2])
      # Keyword call site (nk > 0, no splat): try compile_keyword_send before
      # `#error`.
      if n_match[1] != '*' && n_match[2] != '*' && irep && !idx.nil?
        kw_result = compile_keyword_send(args, self_implicit: self_implicit, irep: irep, idx: idx,
                                         owner_def: owner_def, name: name, d: d,
                                         n: n_match[1].to_i, nk: n_match[2].to_i)
        return kw_result if kw_result
      end
      # SPLAT_UNROLL_SUPPORT: try compile_splat_send (literal Array/Hash) before
      # `#error`; a splatted variable or expression still errors.
      if irep && !idx.nil?
        splat_result = compile_splat_send(args, self_implicit: self_implicit, irep: irep, idx: idx,
                                          name: name, d: d, owner_def: owner_def)
        return splat_result if splat_result
      end
      return "  #error SEND/SSEND :#{name} has a splat and/or keyword argument list (#{n_match[0]}) -- not in this prototype's supported subset\n"
    end

    n = n_match ? n_match[1].to_i : 0
    recv = call_receiver || (self_implicit ? 'self' : "r#{d}")
    argv = call_arguments || (1..n).map { |k| "r#{d.to_i + k}" }

    # LITERAL_EQQ_SUPPORT: `LITERAL === x` from `case x; when LITERAL` (receiver a
    # literal Fixnum or Symbol, see trace_eqq_literal_receiver) is compiled to
    # mruby's native semantics (mrb_eqq_m -> mrb_equal) directly. Soundness:
    # eqq_literal_devirt_safe? (both `:==` and `:===` MONO native, re-checked every
    # run). Runs before monomorphic_target, which refuses native-only names anyway,
    # so only `:===` sites that would otherwise mrb_funcall change. `n == 1`:
    # both natives are MRB_ARGS_REQ(1).
    if name == '===' && n == 1 && irep && idx && eqq_literal_devirt_safe?
      literal = trace_eqq_literal_receiver(irep, idx, d)
      if literal
        arg = argv.first
        case literal[:type]
        when :symbol
          # No fallback needed: Symbol#== is still mrb_obj_equal_m (the same `:==` check),
          # so mrb_equal's mrb_func_basic_p guard holds and it never dispatches; the
          # answer is `mrb_symbol(v1) == mrb_symbol(v2)` with an exact type match, and
          # Symbols have no cross-type equality.
          note = "  // LITERAL === :symbol -- `:#{literal[:name]} === arg` (case/when literal), " \
                 "Object#===/Symbol#== both confirmed native/unoverridden anywhere in this program's " \
                 "own whole-program registry -- sound unconditionally, no mrb_funcall fallback ever " \
                 "needed (see eqq_literal_devirt_safe?'s own comment).\n"
          return "#{note}  r#{d} = mrb_bool_value(mrb_symbol_p(#{arg}) && " \
                 "mrb_symbol(#{arg}) == mrb_intern_cstr(M, \"#{literal[:name]}\"));\n"
        when :fixnum
          # Only an exactly-Integer `arg`: mrb_equal (object.c) does Integer<->Float
          # comparison, and with mruby-bigint (always in build_config.rb's
          # rpg_maker_gems) Integer<->Bigint too (also in int_equal, src/numeric.c), so
          # `5 === 5.0` is true. Only MRB_TT_INTEGER vs MRB_TT_INTEGER is compared
          # directly (exact, given `:==` is MONO native); every other type uses
          # mrb_funcall, like compile_cmp's EQ.
          note = "  // LITERAL === :fixnum -- `#{literal[:value]} === arg` (case/when literal), " \
                 "Object#===/Integer#== both confirmed native/unoverridden anywhere in this program's " \
                 "own whole-program registry -- only the exact-Integer-type shape is handled directly; " \
                 "a Float/Bigint/other-typed arg falls back to real mrb_funcall (mrb_equal's own " \
                 "Integer<->Float/Bigint cross-type comparison, see this block's own top comment).\n"
          return "#{note}  if (mrb_fixnum_p(#{arg})) {\n" \
                 "    r#{d} = mrb_bool_value(mrb_fixnum(#{arg}) == #{literal[:value]});\n" \
                 "  } else {\n" \
                 "    #{dynamic_dispatch_line(d, recv, name, argv)}" \
                 "  }\n"
        end
      end
    end

    # Devirtualize `SEND :new` whose receiver traces (GETCONST, at this call site)
    # to a NATIVE_CONSTRUCT_TARGETS class. Never for self_implicit sends; irep/idx
    # are nil exactly then, but are checked because trace_new_target needs them.
    if name == 'new' && !self_implicit && irep && idx
      known = trace_new_target(irep, idx, d, nil, 0, nil, resolving_new: true, owner: owner_def&.owner,
                               canonical: false)
      native = known && NATIVE_CONSTRUCT_TARGETS[known]
      # Exact arity only (an Array lists several accepted counts); other counts fall
      # through to dynamic dispatch.
      if native && (native[:arity] == n || (native[:arity].is_a?(Array) && native[:arity].include?(n)))
        @native_construct_used << known
        # `fn` takes native mrb_int/mrb_float, so arguments are unboxed here with the
        # same mrb_as_int/mrb_as_float the function used internally (same TypeError).
        # `:object` (Sprite) passes through; a 0-argument Sprite.new passes an explicit
        # mrb_nil_value(), since the C++ signature always has the full parameter list
        # (include/rgss_construct.hxx) and "|o" leaves vp nil.
        # `type_guard` (Bitmap): check every argument's Integer tag and fall back to
        # mrb_funcall if any fails (a String first argument is the file-load form);
        # read with mrb_integer after the check.
        if native[:type_guard] == :int
          arg_checks = argv.map { |a| "mrb_integer_p(#{a})" }.join(' && ')
          unboxed_argv = argv.map { |a| "mrb_integer(#{a})" }
          guard = "mrb_class_ptr(#{recv}) == #{native[:class_fn]}() && #{arg_checks}"
          note_extra = " Argument tags checked first (#{arg_checks}), " \
                       "falling back to ordinary dispatch for any other shape -- " \
                       "see that entry's own `type_guard` comment."
        else
          unboxed_argv = case native[:arg_type]
                         when :int then argv.map { |a| "mrb_as_int(M, #{a})" }
                         when :float then argv.map { |a| "mrb_as_float(M, #{a})" }
                         else argv
                         end
          unboxed_argv = ['mrb_nil_value()'] if unboxed_argv.empty?
          guard = "mrb_class_ptr(#{recv}) == #{native[:class_fn]}()"
          note_extra = ''
        end
        # The note's "unboxes each argument" only applies to :int/:float.
        unbox_phrase = case native[:arg_type]
                       when :int then 'unboxes each argument register with the same mrb_as_int that function used to call internally'
                       when :float then 'unboxes each argument register with the same mrb_as_float that function used to call internally'
                       else 'passes each argument register straight through as mrb_value'
                       end
        note = "  // MONO :new -> #{known}, direct native construct (mruby-rgss/src/lib.cxx's own " \
               "#{native[:fn]}) -- skips Class#new's own allocate+initialize dispatch chain entirely.\n" \
               "  // Runtime-guarded: #{known} could have been reassigned at the constant level (e.g. " \
               "`RGSS::#{known} = SomeOtherClass`) since #{native[:class_fn]}'s own class was registered " \
               "-- #{recv} is whatever this method's own existing GETCONST resolution chain above just " \
               "produced, so a reassignment there is already reflected in it; falls back to ordinary " \
               "mrb_funcall (whatever #{recv} now actually is) rather than misconstruct if it doesn't " \
               "match the real native class.#{note_extra} #{native[:fn]}'s own parameters are native mrb_int/" \
               "mrb_float, not mrb_value (except :object, passed straight through), so this call site #{unbox_phrase}, " \
               "and passes mrb_class_ptr(#{recv}) " \
               "straight through (already computed for the guard just above -- no second, redundant " \
               "mrb_class_ptr call needed).\n"
        return "#{note}" \
               "  if (#{guard}) {\n" \
               "    r#{d} = #{native[:fn]}(M, mrb_class_ptr(#{recv}), #{unboxed_argv.join(', ')});\n" \
               "  } else {\n" \
               "    #{dynamic_dispatch_line(d, recv, name, argv)}" \
               "  }\n"
      end
    end

    # DIRECT_CONSTRUCT_TARGETS (see its comment): the compiled-class counterpart of
    # the block above. A separate `if`, so neither can shadow the other (the two
    # owner sets never overlap); re-running trace_new_target is cheap.
    if name == 'new' && !self_implicit && irep && idx
      known = trace_new_target(irep, idx, d, nil, 0, nil, resolving_new: true, owner: owner_def&.owner,
                               canonical: false)
      if known && DIRECT_CONSTRUCT_TARGETS.include?(known)
        init_def = @registry['initialize'].find { |md| md.owner == known }
        # DIRECT_CONSTRUCT_TARGETS' soundness bar, checked live against this run's
        # registry and ONLY_OWNERS.
        # 1/2: no custom `def self.new`/`def self.allocate` on this class ("X.singleton"
        # owner, see build_registry).
        no_custom_new = @registry['new'].none? { |md| md.owner == "#{known}.singleton" }
        no_custom_allocate = @registry['allocate'].none? { |md| md.owner == "#{known}.singleton" }
        # 3: #initialize is a compiling, pure-mandatory leaf whose arity matches this
        # call (the TYPED path's checks); an optional-argument #initialize must never
        # be skipped past this way.
        init_ok = init_def&.irep && pure_mandatory_arity?(@ireps.fetch(init_def.irep)) &&
                  compiles_clean?(init_def.irep) && n == mandatory_arity(@ireps.fetch(init_def.irep))
        if no_custom_new && no_custom_allocate && init_ok
          # 4: the ONLY_OWNERS/OTHER_OWNERS emission guard.
          owner_emitted = !@only_owners || @only_owners.include?(known) || @other_owners&.include?(known)
          if owner_emitted
            @direct_construct_used << known
            accessor = direct_construct_class_fn(known)
            init_impl = cpp_name(known, 'initialize') + '_impl'
            note = "  // MONO :new -> #{known}, direct compiled construct (bc2cpp_direct_alloc + " \
                   "#{init_impl}) -- skips Class#new's own allocate+initialize dispatch chain entirely; " \
                   "#{known}#initialize's own return value is discarded (real Ruby .new always returns " \
                   "the new object, never whatever #initialize itself returns).\n" \
                   "  // Runtime-guarded the same way NATIVE_CONSTRUCT_TARGETS' own native-construct path " \
                   "is (see that block's own comment): #{known} could have been reassigned at the constant " \
                   "level since #{accessor}'s own class was captured at gem-init, so #{recv} (this call " \
                   "site's own already-resolved GETCONST/GETMCNST receiver) is compared against it rather " \
                   "than trusted outright, falling back to ordinary mrb_funcall if they differ.\n"
            return "#{note}" \
                   "  if (mrb_class_ptr(#{recv}) == #{accessor}()) {\n" \
                   "    r#{d} = bc2cpp_direct_alloc(M, mrb_class_ptr(#{recv}));\n" \
                   "    #{init_impl}(M, #{([recv] + argv).join(', ')});\n" \
                   "  } else {\n" \
                   "    #{dynamic_dispatch_line(d, recv, name, argv)}" \
                   "  }\n"
          end
        end
      end
    end

    # NATIVE_PRIMITIVE_SENDS: inline native primitives at any call site, without
    # receiver-class knowledge. monomorphic_target refuses native-only names
    # (calling an arbitrary C method directly would leave mrb_get_args reading a
    # stale frame), but for these each native body is an expression that is safe
    # outside a dispatched frame, so native_only_mono? (no bytecode override
    # anywhere) is the whole soundness argument:
    #   - `!`: mrb_bob_not is `mrb_bool_value(!mrb_test(cv))` (class.c).
    #   - `nil?`: Object's is mrb_false, NilClass's mrb_true; together exactly
    #     mrb_nil_p(recv) for every receiver.
    #   - `is_a?`/`kind_of?`: mrb_obj_is_kind_of_m does `mrb_get_args(mrb, "c",
    #     &c)` (TypeError unless Class/Module) then mrb_obj_is_kind_of. Reproduced
    #     behind an `mrb_class_p(arg) || mrb_module_p(arg)` guard; otherwise
    #     mrb_funcall raises the real TypeError.
    #   - `equal?`: mrb_obj_equal_m is mrb_obj_equal(self, arg) (public).
    #   - `class`: mrb_obj_value(mrb_obj_class(mrb, self)).
    #   - `object_id`: mrb_fixnum_value(mrb_obj_id(self)) (boxing-generic).
    #   - `keys`: mrb_hash_keys casts unchecked, so it needs an mrb_hash_p guard
    #     (KEYS_TYPE_TAG_GUARD).
    #   - `to_s`, `length`, `first`: several native bodies behind one registry
    #     entry; per-type handling in *_TYPE_TAG_DISPATCH (Array/Hash to_s mutate
    #     ci->mid and are excluded; String length depends on MRB_UTF8_STRING;
    #     Array#first reads mrb_get_argc, so it is reproduced).
    #   - `dup`: exactly two native bodies, no fallback needed
    #     (DUP_TYPE_TAG_DISPATCH).
    # `respond_to?` has a positive-only fast path (a miss keeps dispatch so
    # respond_to_missing? runs; the two-argument form stays dynamic).
    if name == '[]' && n == 2 && builtin_class_send_safe?(name, %w[Array])
      start, length = argv
      fallback = dynamic_dispatch_line(d, recv, name, argv)
      return <<~CPP
          // ARRAY_SLICE_READ :[] -- exact Array and Fixnum slice only; preserve coercion and overrides
          if (mrb_array_p(#{recv}) && mrb_obj_ptr(#{recv})->c == M->array_class &&
              mrb_fixnum_p(#{start}) && mrb_fixnum_p(#{length}) &&
              !ARY_SHARED_P(mrb_ary_ptr(#{recv})) && mrb_fixnum(#{length}) >= 0 &&
              mrb_fixnum(#{length}) <= 10) {
            mrb_int bc2cpp_slice_start = mrb_fixnum(#{start});
            mrb_int bc2cpp_slice_length = mrb_fixnum(#{length});
            mrb_int bc2cpp_slice_array_length = RARRAY_LEN(#{recv});
            if (bc2cpp_slice_start < 0 && bc2cpp_slice_start >= -bc2cpp_slice_array_length) {
              bc2cpp_slice_start += bc2cpp_slice_array_length;
            }
            if (bc2cpp_slice_start < 0 || bc2cpp_slice_array_length < bc2cpp_slice_start ||
                bc2cpp_slice_length < 0) {
              r#{d} = mrb_nil_value();
            } else {
              if (bc2cpp_slice_length > bc2cpp_slice_array_length - bc2cpp_slice_start) {
                bc2cpp_slice_length = bc2cpp_slice_array_length - bc2cpp_slice_start;
              }
              if (bc2cpp_slice_length == 0) {
                r#{d} = mrb_ary_new(M);
              } else {
                r#{d} = mrb_ary_new_from_values(M, bc2cpp_slice_length,
                    RARRAY_PTR(#{recv}) + bc2cpp_slice_start);
              }
            }
          } else {
            #{fallback.chomp}
          }
      CPP
    end

    if name == '[]=' && n == 3 && builtin_class_send_safe?(name, %w[Array])
      # Array slice writes (optcarrot's mapper bank switches): mrb_ary_splice is the
      # public native body of this three-argument form. Only exact Arrays with
      # fixnum start/length; coercion, subclasses and non-Arrays keep dispatch.
      # Array#[]= returns the replacement, mrb_ary_splice the receiver.
      start, length, replacement = argv
      fallback = dynamic_dispatch_line(d, recv, name, argv)
      return <<~CPP
          // ARRAY_SLICE_WRITE :[]= -- exact Array and fixnum indices only; preserve coercion and overrides
          if (mrb_array_p(#{recv}) && mrb_obj_ptr(#{recv})->c == M->array_class &&
              mrb_fixnum_p(#{start}) && mrb_fixnum_p(#{length})) {
            mrb_ary_splice(M, #{recv}, mrb_fixnum(#{start}), mrb_fixnum(#{length}), #{replacement});
            r#{d} = #{replacement};
          } else {
            #{fallback.chomp}
          }
      CPP
    end

    if name == 'push' && n == 1 && builtin_class_send_safe?(name, %w[Array])
      value = argv.first
      fallback = dynamic_dispatch_line(d, recv, name, argv)
      return <<~CPP
          // ARRAY_PUSH :push -- exact base Array and one value; preserve overrides and other arities
          if (mrb_array_p(#{recv}) && mrb_obj_ptr(#{recv})->c == M->array_class) {
            mrb_ary_push(M, #{recv}, #{value});
            r#{d} = #{recv};
          } else {
            #{fallback.chomp}
          }
      CPP
    end

    if ['+', '-', '*'].include?(name) && n == 1 && builtin_class_send_safe?(name, %w[Integer Numeric])
      left, right = recv, argv.first
      fallback = dynamic_dispatch_line(d, recv, name, argv)
      helper = { '+' => 'mrb_num_add', '-' => 'mrb_num_sub', '*' => 'mrb_num_mul' }.fetch(name)
      return <<~CPP
          // FIXNUM_ARITHMETIC :#{name} -- exact Fixnums use mruby's overflow-aware numeric helper
          if (mrb_fixnum_p(#{left}) && mrb_fixnum_p(#{right})) {
            r#{d} = #{helper}(M, #{left}, #{right});
          } else {
            #{fallback.chomp}
          }
      CPP
    end

    # INTEGER_LSHIFT: `bits << n` on two Integers uses mrb_num_shift, the kernel
    # Integer#<< calls (src/numeric.c int_lshift), so zero shifts, negative counts
    # and the width limit match. MRB_INT_MIN counts and overflow (bigint or
    # RangeError) take ordinary dispatch, which also keeps bigints out of C on
    # 32-bit mrb_int builds. Placed next to the exact-Array push arm, so a site
    # that was ARRAY_PUSH-only stays so when Integer#<< is overridden in Ruby.
    if name == '<<' && n == 1 && builtin_class_send_safe?(name, %w[Integer])
      value = argv.first
      fallback = dynamic_dispatch_line(d, recv, name, argv).chomp
      array_arm = ''
      if builtin_class_send_safe?(name, %w[Array])
        array_arm = <<~CPP
            // ARRAY_PUSH :<< -- exact Array only; preserve subclass and override dispatch
            if (mrb_array_p(#{recv}) && mrb_obj_ptr(#{recv})->c == M->array_class) {
              mrb_ary_push(M, #{recv}, #{value});
              r#{d} = #{recv};
            } else\x20
        CPP
      end
      return <<~CPP
          #{array_arm.chomp}// INTEGER_LSHIFT :<< -- two immediate Integers; overflow keeps ordinary dispatch
          if (mrb_integer_p(#{recv}) && mrb_integer_p(#{value}) && mrb_integer(#{value}) != MRB_INT_MIN) {
            mrb_int bc2cpp_shl_v = mrb_integer(#{recv}), bc2cpp_shl_w = mrb_integer(#{value}), bc2cpp_shl_out;
            if (bc2cpp_shl_w == 0 || bc2cpp_shl_v == 0) {
              r#{d} = #{recv};
            } else if (mrb_num_shift(M, bc2cpp_shl_v, bc2cpp_shl_w, &bc2cpp_shl_out)) {
              r#{d} = mrb_int_value(M, bc2cpp_shl_out);
            } else {
              #{fallback}
            }
          } else {
            #{fallback}
          }
      CPP
    end

    integer_unary = compile_integer_unary(name, n, d, recv, argv)
    return integer_unary if integer_unary

    if name == '<<' && n == 1 && builtin_class_send_safe?(name, %w[Array])
      value = argv.first
      fallback = dynamic_dispatch_line(d, recv, name, argv)
      return <<~CPP
          // ARRAY_PUSH :<< -- exact Array only; preserve subclass and override dispatch
          if (mrb_array_p(#{recv}) && mrb_obj_ptr(#{recv})->c == M->array_class) {
            mrb_ary_push(M, #{recv}, #{value});
            r#{d} = #{recv};
          } else {
            #{fallback.chomp}
          }
      CPP
    end

    if name == 'concat' && n == 1 && owner_def&.owner == 'Optcarrot::APU' && owner_def.name == 'flush_sound' &&
       builtin_class_send_safe?(name, %w[Array])
      source = argv.first
      fallback = dynamic_dispatch_line(d, recv, name, argv)
      return <<~CPP
          // ARRAY_CONCAT_COPY :concat -- APU output buffer; preserve exact-Array capacity without sharing
          if (mrb_array_p(#{recv}) && mrb_obj_ptr(#{recv})->c == M->array_class &&
              mrb_array_p(#{source}) && mrb_obj_ptr(#{source})->c == M->array_class &&
              mrb_obj_ptr(#{recv}) != mrb_obj_ptr(#{source}) && ARY_LEN(mrb_ary_ptr(#{recv})) == 0) {
            r#{d} = mrb_ary_splice(M, #{recv}, 0, 0, #{source});
          } else {
            #{fallback.chomp}
          }
      CPP
    end

    if name == 'clear' && n.zero? && builtin_class_send_safe?(name, %w[Array])
      fallback = dynamic_dispatch_line(d, recv, name, argv)
      retain_frame_capacity = (owner_def&.owner == 'Optcarrot::PPU' && owner_def.name == 'setup_frame') ||
                              (owner_def&.owner == 'Optcarrot::APU' && owner_def.name == 'flush_sound')
      if retain_frame_capacity
        return <<~CPP
            // ARRAY_CLEAR_RETAIN :clear -- frame/audio buffer; clear length but reuse backing storage
            if (mrb_array_p(#{recv}) && mrb_obj_ptr(#{recv})->c == M->array_class) {
              struct RArray *bc2cpp_frame_pixels = mrb_ary_ptr(#{recv});
              mrb_ary_modify(M, bc2cpp_frame_pixels);
              ARY_SET_LEN(bc2cpp_frame_pixels, 0);
              r#{d} = #{recv};
            } else {
              #{fallback.chomp}
            }
        CPP
      end
    end

    if ['%', '&', '|', '^'].include?(name) && n == 1 && native_only_mono?(name)
      left, right = recv, argv.first
      fallback = dynamic_dispatch_line(d, recv, name, argv)
      operation = if name == '%'
                    <<~CPP.chomp
                      mrb_int bc2cpp_mod_left = mrb_fixnum(#{left});
                      mrb_int bc2cpp_mod_right = mrb_fixnum(#{right});
                      if (bc2cpp_mod_left == MRB_INT_MIN && bc2cpp_mod_right == -1) {
                        r#{d} = mrb_fixnum_value(0);
                      } else {
                        mrb_int bc2cpp_mod_value = bc2cpp_mod_left % bc2cpp_mod_right;
                        if ((bc2cpp_mod_left < 0) != (bc2cpp_mod_right < 0) && bc2cpp_mod_value != 0) {
                          bc2cpp_mod_value += bc2cpp_mod_right;
                        }
                        r#{d} = mrb_fixnum_value(bc2cpp_mod_value);
                      }
                    CPP
                  else
                    operator = { '&' => '&', '|' => '|', '^' => '^' }.fetch(name)
                    "r#{d} = mrb_fixnum_value(mrb_fixnum(#{left}) #{operator} mrb_fixnum(#{right}));"
                  end
      return <<~CPP
          // FIXNUM_BINARY :#{name} -- fixnum-only native semantics with Ruby fallback
          if (mrb_fixnum_p(#{left}) && mrb_fixnum_p(#{right})#{' && mrb_fixnum(' + right + ') != 0' if name == '%'}) {
            #{operation}
          } else {
            #{fallback.chomp}
          }
      CPP
    end

    if name == '>>' && n == 1 && builtin_class_send_safe?(name, %w[Integer Numeric])
      value, width = recv, argv.first
      fallback = dynamic_dispatch_line(d, recv, name, argv)
      return <<~CPP
          // FIXNUM_SHIFT :>> -- guarded shifts; overflow and non-Fixnum cases retain Ruby dispatch
          {
          mrb_bool bc2cpp_shift_fast = FALSE;
          mrb_int bc2cpp_shift_result = 0;
          if (mrb_fixnum_p(#{value}) && mrb_fixnum_p(#{width})) {
            mrb_int bc2cpp_shift_value = mrb_fixnum(#{value});
            mrb_int bc2cpp_shift_width = mrb_fixnum(#{width});
            if (bc2cpp_shift_width == 0) {
              bc2cpp_shift_result = bc2cpp_shift_value;
              bc2cpp_shift_fast = TRUE;
            } else if (bc2cpp_shift_width > 0) {
              if (bc2cpp_shift_width >= MRB_INT_BIT - 1) {
                bc2cpp_shift_result = bc2cpp_shift_value < 0 ? -1 : 0;
              } else {
                bc2cpp_shift_result = bc2cpp_shift_value >> bc2cpp_shift_width;
              }
              bc2cpp_shift_fast = TRUE;
            } else if (bc2cpp_shift_width != MRB_INT_MIN) {
              if (bc2cpp_shift_value == 0) {
                bc2cpp_shift_fast = TRUE;
              } else {
                mrb_int bc2cpp_left_width = -bc2cpp_shift_width;
                if (bc2cpp_left_width <= MRB_INT_BIT - 1 &&
                    !(bc2cpp_shift_value > 0 && bc2cpp_shift_value > (MRB_INT_MAX >> bc2cpp_left_width)) &&
                    !(bc2cpp_shift_value < 0 && bc2cpp_shift_value < (MRB_INT_MIN >> bc2cpp_left_width))) {
                  if (bc2cpp_left_width == MRB_INT_BIT - 1) {
                    bc2cpp_shift_result = MRB_INT_MIN;
                  } else if (bc2cpp_shift_value > 0) {
                    bc2cpp_shift_result = bc2cpp_shift_value << bc2cpp_left_width;
                  } else {
                    bc2cpp_shift_result = bc2cpp_shift_value * ((mrb_int)1 << bc2cpp_left_width);
                  }
                  bc2cpp_shift_fast = TRUE;
                }
              }
            }
          }
          if (bc2cpp_shift_fast) {
            r#{d} = mrb_fixnum_value(bc2cpp_shift_result);
          } else {
            #{fallback.chomp}
          }
          }
      CPP
    end

    if ['<', '<=', '>', '>='].include?(name) && n == 1 && native_only_mono?(name)
      left, right = recv, argv.first
      fallback = dynamic_dispatch_line(d, recv, name, argv)
      operator = { '<' => '<', '<=' => '<=', '>' => '>', '>=' => '>=' }.fetch(name)
      return <<~CPP
          // FIXNUM_COMPARE :#{name} -- fixnum-only native comparison with Ruby fallback
          if (mrb_fixnum_p(#{left}) && mrb_fixnum_p(#{right})) {
            r#{d} = mrb_bool_value(mrb_fixnum(#{left}) #{operator} mrb_fixnum(#{right}));
          } else {
            #{fallback.chomp}
          }
      CPP
    end

    if name == 'slice!' && n == 2 && builtin_class_send_safe?(name, %w[Array])
      start, length = argv
      fallback = dynamic_dispatch_line(d, recv, name, argv)
      return <<~CPP
          // ARRAY_PREFIX_SLICE_WRITE :slice! -- exact Array, zero start, nonnegative fixnum length
          if (mrb_array_p(#{recv}) && mrb_obj_ptr(#{recv})->c == M->array_class &&
              !mrb_frozen_p(mrb_obj_ptr(#{recv})) && mrb_fixnum_p(#{start}) &&
              mrb_fixnum(#{start}) == 0 && mrb_fixnum_p(#{length}) && mrb_fixnum(#{length}) >= 0) {
            mrb_value bc2cpp_slice_receiver = #{recv};
            mrb_int bc2cpp_slice_len = mrb_fixnum(#{length});
            mrb_int bc2cpp_array_len = RARRAY_LEN(bc2cpp_slice_receiver);
            if (bc2cpp_slice_len > bc2cpp_array_len) bc2cpp_slice_len = bc2cpp_array_len;
            r#{d} = mrb_ary_new_from_values(M, bc2cpp_slice_len, RARRAY_PTR(bc2cpp_slice_receiver));
            mrb_ary_splice(M, bc2cpp_slice_receiver, 0, bc2cpp_slice_len, mrb_undef_value());
          } else {
            #{fallback.chomp}
          }
      CPP
    end

    if name == 'key?' && n == 1 && !@native_registered_expressions.key?(name) &&
       builtin_class_send_safe?(name, %w[Hash])
      return compile_native_primitive_send(name, d, recv, argv)
    end

    # Resolve compiled MONO/TYPED targets first; only the final POLY fallback uses
    # the generated native C expressions.
    native_expression_entries = @native_registered_expressions[name]
    # EQ_CHAIN_FALLBACK: compile_cmp wraps this send in its own String/Symbol chain
    # (generated_eq_dispatch), so the send must not emit that switch a second time.
    native_expression_entries = nil if @suppress_native_expression_send == name
    native_expression_owners = native_expression_entries&.map { |entry| entry[:owner][:class_name] }&.uniq
    builtin_native_expression_send = native_expression_entries && native_expression_entries.all? { |entry| entry[:arity] == n } &&
                                     builtin_class_send_safe?(name, native_expression_owners)

    if (expected_n = NATIVE_PRIMITIVE_SEND_ARITY[name]) && n == expected_n && native_only_mono?(name) &&
       !@native_registered_expressions.key?(name)
      return compile_native_primitive_send(name, d, recv, argv)
    end

    target = monomorphic_target(name)
    # A MONO name is only safe to devirtualize if its definition fits the calling
    # convention (pure_mandatory_or_optional_arity?).
    target = nil if target && !pure_mandatory_or_optional_arity?(@ireps.fetch(target.irep))
    # ...and if this call's argument count fits the target's arity. Without
    # NATIVE_SRCS, `:repeat?` looks MONO (only Game::MoveRoute#repeat?, 0 args, is
    # bytecode) although `Input.repeat?(key)` (native, 1 arg) uses the name, and a
    # direct call would not compile. The argument count needs no NATIVE_SRCS and
    # never matches a genuinely different method's arity.
    # CALLSITE_OPTIONAL_ARG_SUPPORT: any count in [mand, mand + opt]; with no
    # optionals this is the exact match.
    target = nil if target && !n.between?(mandatory_arity(@ireps.fetch(target.irep)),
                                           mandatory_arity(@ireps.fetch(target.irep)) + optional_arity(@ireps.fetch(target.irep)))
    # LEXICAL_SELF_SUPPORT: POLY by name, but for an IMPLICIT-self send `self`'s
    # class is known outright when lexical_self_owner says so (no subclass of the
    # owner exists, and no instance_eval/instance_exec rebinding occurs here; see
    # self_receiver_class). A proven fact, so the direct call needs no runtime
    # guard or fallback, like MONO. Never for an explicit receiver.
    lexical_self = false
    lexical_self_ivar_accessor = nil
    if target.nil? && self_implicit
      lex_owner = lexical_self_owner(owner_def)
      # SINGLETON_LEXICAL_SELF: only the irep branch below; accessors stay dynamic.
      singleton_candidate = lex_owner.nil? && lexical_self_singleton_def(name, owner_def)
      if lex_owner || singleton_candidate
        lex_candidate = singleton_candidate || @registry[name]&.find { |md| md.owner == lex_owner }
        if lex_candidate&.irep && pure_mandatory_or_optional_arity?(@ireps.fetch(lex_candidate.irep)) &&
           compiles_clean?(lex_candidate.irep) &&
           n.between?(mandatory_arity(@ireps.fetch(lex_candidate.irep)),
                      mandatory_arity(@ireps.fetch(lex_candidate.irep)) + optional_arity(@ireps.fetch(lex_candidate.irep)))
          target = lex_candidate
          lexical_self = true
        elsif lex_candidate&.kind == :ivar_accessor && n == (name.end_with?('=') ? 1 : 0)
          # LEXICAL_SELF_IVAR_ACCESSOR: the :ivar_accessor analogue (an attr_* candidate
          # has no irep; see IVAR_ACCESSOR_DEVIRT). Same certainty, no guard; IVAR_ACCESS
          # chooses iv_tbl or the embedded struct.
          lexical_self_ivar_accessor = lex_candidate
        end
      end
    end
    # Still POLY: try the call-site fallback: the receiver traced (trace_new_target)
    # to one exact class. Exact owner match only (no MRO walk), so an inherited
    # method misses and keeps dispatch.
    # The trace sources are a fresh `.new` (a Ruby guarantee), a ClassLayout ivar
    # hint, or a ClassAnnotations argument (whole-program facts, not proofs), so
    # every hit gets a runtime mrb_obj_class check with an mrb_funcall fallback.
    typed = false
    via_element = false
    ivar_accessor_target = nil
    known_class = nil
    if target.nil? && !self_implicit && irep && (idx || trace_idx)
      proof_idx = idx || trace_idx
      proof_reg = unshift_proof_reg(trace_receiver_reg || d, trace_reg_offset)
      cur_enter = irep.instructions.find { |i| i.op == 'ENTER' }
      cur_mand = cur_enter ? cur_enter.args.split(':').first.to_i : 0
      cur_arg_classes = owner_def && @class_annotations[irep.label]&.args
      ivar_classes = owner_def && @class_layout[owner_def.owner]
      # CHAINED_ACCESSOR_SUPPORT: passing @class_layout/@registry lets TYPED resolve
      # multi-level accessor chains (`@state.screen.foo`); see trace_new_target.
      known_class = trace_new_target(irep, proof_idx, proof_reg, ivar_classes, cur_mand, cur_arg_classes, owner: owner_def&.owner,
                                      class_layout: @class_layout, registry: @registry,
                                      element_annotations: @element_annotations,
                                      known_owners: @known_owners,
                                      capture_hints: @block_hash_capture_hints)
    end
    # ELEMENT_CLASS_SUPPORT: the same TYPED/IVAR_ACCESSOR resolution fed by the
    # element hint (with_element_hint) for an inlined-loop parameter, which no
    # instruction writes. After the ordinary trace, so that path keeps priority by
    # construction. Everything downstream is shared with TYPED, including the
    # runtime `mrb_class_ptr(...) == mrb_obj_class(M, recv)` check and
    # mrb_funcall fallback, so a wrong element fact costs one failed compare.
    if target.nil? && !self_implicit && known_class.nil? && elem_class_hint
      known_class = elem_class_hint
      via_element = true
    end
    if target.nil? && !self_implicit && known_class
      candidate = @registry[name]&.find { |md| md.owner == known_class }
      # The same two guards as MONO: the class-exact candidate must compile clean
      # and fit the call's argument count.
      if candidate&.irep && pure_mandatory_or_optional_arity?(@ireps.fetch(candidate.irep)) &&
         compiles_clean?(candidate.irep) &&
         n.between?(mandatory_arity(@ireps.fetch(candidate.irep)),
                    mandatory_arity(@ireps.fetch(candidate.irep)) + optional_arity(@ireps.fetch(candidate.irep)))
        target = candidate
        typed = true
      elsif candidate&.kind == :ivar_accessor &&
            n == (name.end_with?('=') ? 1 : 0) &&
            ivar_accessor_call_code(candidate.owner, recv, name, d, argv)
        # IVAR_ACCESSOR_DEVIRT: an attr_* candidate has no irep, so it can never take
        # the TYPED branch. Its accessor is provably a bare mrb_iv_get/mrb_iv_set
        # (src/class.c; see MethodDef's `kind`), so it is inlined behind the same
        # runtime guard as TYPED. Arity is 0 for a reader and 1 for a writer (`=`
        # suffix), which is the complete check. For an embedded ivar IVAR_ACCESS
        # (ivar_accessor_call_code) picks the storage; nil leaves the call to dispatch.
        ivar_accessor_target = candidate
      end
    end
    # A target whose owner this run does not emit (ONLY_OWNERS) has no `_impl`
    # here (LCF::File#to_lcf calling LCF.write_ber would fail to link), so use
    # dynamic dispatch, unless another gem emits it (@other_owners; see
    # emit_decls_header).
    if target && @only_owners && !@only_owners.include?(target.owner)
      target = nil unless @other_owners&.include?(target.owner)
    end

    if target
      impl = cpp_name(target.owner, target.name) + '_impl'
      # NATIVE_ARG_TARGETS call-site half: the callee's `_impl` takes mrb_int/mrb_sym
      # for retyped positions (C++ has no implicit conversion from mrb_value), so
      # call_argv unboxes them here with mrb_as_int/mrb_obj_to_sym, the coercions
      # mrb_get_args "i"/"n" use in the entry wrapper (same TypeError). It wraps
      # whatever expression argv holds (e.g. `-weapon_sp_cost`).
      # native_arg_types is asked for t_mand positions only; NATIVE_ARG_TARGETS never
      # names optional-arg methods.
      t_irep = @ireps.fetch(target.irep)
      t_mand = mandatory_arity(t_irep)
      t_opt = optional_arity(t_irep)
      call_types = native_arg_types(target, t_mand)
      call_argv = argv.each_with_index.map do |a, i|
        case call_types[i]
        when :fixnum then "mrb_as_int(M, #{a})"
        when :symbol then "mrb_obj_to_sym(M, #{a})"
        else a
        end
      end
      # CALLSITE_OPTIONAL_ARG_SUPPORT: `_impl` always takes all optionals, so omitted
      # trailing ones get mrb_nil_value() placeholders (as the entry wrapper does;
      # never read), plus the `bc2cpp_given_opt` literal `argv.size - t_mand`.
      if t_opt.positive?
        call_argv += Array.new(t_mand + t_opt - argv.size, 'mrb_nil_value()')
        call_argv << (argv.size - t_mand).to_s
      end
      native_positions = call_types.each_index.select { |i| call_types[i] }.map { |i| i + 1 }
      native_note = native_positions.empty? ? '' : " (position#{'s' unless native_positions.one?} " \
                                                    "#{native_positions.join(', ')} unboxed here to match " \
                                                    "#{impl}'s own native argument type)"
      if typed
        check = "#{owner_class_ptr_expr(target.owner)} == mrb_obj_class(M, #{recv})"
        # ELEMENT_CLASS_SUPPORT: the tag records which fact proved the receiver.
        kind = via_element ? 'ELEMENT' : 'TYPED'
        traced_note = via_element ? "inlined block element of Array<#{target.owner}>" : "receiver traced to #{target.owner}"
        note = "  // #{kind} :#{name} -> #{target.owner}##{target.name} (#{traced_note}), " \
               "runtime-class-checked direct C++ call, mrb_funcall fallback#{native_note}\n"
        fallback = typed_fallback ||
                   guarded_fallback_line(d, recv, name, argv, [target.owner],
                                         closed_world_site(recv, irep, idx, owner_def))
        "#{note}  if (#{check}) {\n" \
          "    r#{d} = #{impl}(M, #{([recv] + call_argv).join(', ')});\n" \
          "  } else {\n" \
          "    #{fallback}" \
          "  }\n"
      elsif lexical_self
        note = "  // LEXICAL_SELF :#{name} -> #{target.owner}##{target.name} (self, statically " \
               "#{target.owner} -- no subclass exists program-wide), direct C++ call (no mrb_funcall, " \
               "no runtime check)#{native_note}\n"
        "#{note}  r#{d} = #{impl}(M, #{([recv] + call_argv).join(', ')});\n"
      elsif @ivar_layout.key?(target.owner)
        # MONO_EMBED_GUARD: MONO says nothing about method_missing: a class answering a
        # name via method_missing (LCF::Array1D/Array2D) adds no registry entry, so
        # MONO may call `impl` on a receiver that is not target.owner. Normally that
        # only touches the wrong iv_tbl (memory-safe), but if target.owner embeds any
        # ivar, GETIV/SETIV cast DATA_PTR(self) unconditionally and a plain RObject
        # receiver makes it a type-confused read (`@db_row.faceset_index` on an
        # Array1D crashed in Game::Actor's accessor). So every MONO call into an
        # embedding class gets the class guard, rather than proving per body that no
        # DATA_PTR is reached.
        cw_site = closed_world_site(recv, irep, idx, owner_def)
        # CLOSED_WORLD_SELF: LEXICAL_SELF's reasoning for a MONO target. Self is
        # kind_of the owner and the closed world proves it has no subclass, so
        # the guard can only be true.
        if cw_site && cw_site[:self_owner] == target.owner && @closed_world.exact_class?(target.owner)
          note = "  // CLOSED_WORLD_SELF :#{name} -> #{target.owner}##{target.name} (self, exactly " \
                 "#{target.owner}: no subclass in the closed world), direct C++ call#{native_note}\n"
          return "#{note}  r#{d} = #{impl}(M, #{([recv] + call_argv).join(', ')});\n"
        end

        check = "#{owner_class_ptr_expr(target.owner)} == mrb_obj_class(M, #{recv})"
        note = "  // MONO_EMBED_GUARD :#{name} -> #{target.owner}##{target.name} (embeds ivars; " \
               "method_missing elsewhere could otherwise mistarget this), runtime-class-checked " \
               "direct C++ call, mrb_funcall fallback#{native_note}\n"
        fallback = guarded_fallback_line(d, recv, name, argv, [target.owner], cw_site)
        "#{note}  if (#{check}) {\n" \
          "    r#{d} = #{impl}(M, #{([recv] + call_argv).join(', ')});\n" \
          "  } else {\n" \
          "    #{fallback}" \
          "  }\n"
      else
        # target.owner embeds no ivar, so its GETIV/SETIV never cast DATA_PTR(self); a
        # wrong receiver is only semantically wrong, as unguarded MONO always was. No
        # guard.
        note = "  // MONO :#{name} -> #{target.owner}##{target.name}, direct C++ call (no mrb_funcall)" \
               "#{native_note}\n"
        "#{note}  r#{d} = #{impl}(M, #{([recv] + call_argv).join(', ')});\n"
      end
    elsif lexical_self_ivar_accessor
      # LEXICAL_SELF_IVAR_ACCESSOR codegen: no guard, no fallback; IVAR_ACCESS picks
      # the storage.
      owner = lexical_self_ivar_accessor.owner
      ivar = name.chomp('=')
      storage = embed_type(owner, ivar) ? 'embedded struct field' : 'mrb_iv_get/mrb_iv_set'
      kind = name.end_with?('=') ? 'attr_writer' : 'attr_reader'
      note = "  // LEXICAL_SELF_IVAR_ACCESSOR :#{name} -> #{owner}#@#{ivar} (self, statically #{owner}), " \
             "#{kind} devirtualized to a direct #{storage} access (no _impl, no mrb_funcall, no runtime " \
             "check) -- see MethodDef's own kind: :ivar_accessor comment for the real " \
             "3rd/mruby/src/class.c citation this reproduces exactly.\n"
      "#{note}  #{ivar_accessor_call_code(owner, recv, name, d, argv, self_of_klass: true)}\n"
    elsif ivar_accessor_target
      # IVAR_ACCESSOR_DEVIRT codegen (see the branch above): guarded like TYPED, since
      # the real class may differ from the trace (subclass, reassigned constant), with
      # an mrb_funcall fallback.
      owner = ivar_accessor_target.owner
      check = "#{owner_class_ptr_expr(owner)} == mrb_obj_class(M, #{recv})"
      # ELEMENT_CLASS_SUPPORT: same tag as the TYPED branch.
      traced_note = via_element ? "inlined block element of Array<#{owner}>" : "receiver traced to #{owner}"
      ivar = name.chomp('=')
      # An embedded ivar goes through its synthesized accessor (IVAR_ACCESS).
      storage = if embed_type(owner, ivar) then 'synthesized struct accessor'
                elsif name.end_with?('=') then 'mrb_iv_set'
                else 'mrb_iv_get'
                end
      kind = name.end_with?('=') ? 'attr_writer' : 'attr_reader'
      note = "  // IVAR_ACCESSOR#{via_element ? '/ELEMENT' : ''} :#{name} -> #{owner}#@#{ivar} (#{traced_note}), " \
             "#{kind} devirtualized to a direct #{storage} (no mrb_funcall) -- see " \
             "MethodDef's own kind: :ivar_accessor comment for the real 3rd/mruby/src/class.c " \
             "citation this reproduces exactly (a writer yields the assigned value).\n"
      fallback = guarded_fallback_line(d, recv, name, argv, [owner], closed_world_site(recv, irep, idx, owner_def))
      "#{note}  if (#{check}) {\n" \
        "    #{ivar_accessor_call_code(owner, recv, name, d, argv, indent: '    ')}\n" \
        "  } else {\n" \
        "    #{fallback}" \
        "  }\n"
    else
      return compile_native_primitive_send(name, d, recv, argv) if builtin_native_expression_send

      poly_small_n = compile_poly_small_n(name, d, recv, argv, n,
                                          closed_world_site: closed_world_site(recv, irep, idx, owner_def))
      return poly_small_n if poly_small_n

      note = "  // POLY :#{name} -- real dynamic dispatch, receiver's runtime class decides\n"
      "#{note}  #{dynamic_dispatch_line(d, recv, name, argv)}"
    end
  end

  # `Owner::Path` -> a chained mrb_const_get expression for the class object (the
  # per-segment lookup GETCONST/GETMCNST do; mrb_class_get_under does not parse
  # "::"). Used only in guard conditions. Uses lexical_scope_path, stripping a
  # ".singleton" suffix (see there), although TYPED owners are never
  # `.singleton` today.
  def const_chain_value_expr(owner)
    lexical_scope_path(owner).reduce('mrb_obj_value(M->object_class)') do |expr, seg|
      "mrb_const_get(M, #{expr}, mrb_intern_cstr(M, \"#{seg}\"))"
    end
  end

  # OWNER_CLASS_CACHE: the RClass* for `owner` via a per-owner helper
  # (emit_owner_class_cache) instead of repeating mrb_const_get + mrb_intern_cstr
  # in every TYPED/POLY_SMALL_N guard on the hot path.
  def owner_class_ptr_expr(owner)
    @owner_class_cache ||= {}
    slot = (@owner_class_cache[owner] ||= { index: @owner_class_cache.size })
    "bc2cpp_owner_class_#{slot[:index]}(M)"
  end

  # File-scope cache emitted ahead of the compiled bodies. A static per owner,
  # also keyed on the mrb_state pointer and reset by the gem's gem_final
  # (bc2cpp_reset_owner_classes), so a later VM at a reused address never sees a
  # stale pointer. Every caller is a class-equality guard with a dynamic
  # fallback, so an undefined class yields nullptr (guard false) instead of
  # raising NameError (an RGSS-only run never defines Game). nullptr is not
  # cached, so a later definition is found. A later reassignment of the constant
  # is not noticed (as with g_direct_construct_*).
  def emit_owner_class_cache
    entries = (@owner_class_cache || {}).to_a
    out = +"// OWNER_CLASS_CACHE -- see bc2cpp.rb's own owner_class_ptr_expr comment.\n"
    out << "static mrb_state* bc2cpp_owner_class_state = nullptr;\n"
    out << "static struct RClass* bc2cpp_owner_class_slots[#{[entries.size, 1].max}] = {};\n"
    out << "static void bc2cpp_reset_owner_classes() {\n" \
           "  bc2cpp_owner_class_state = nullptr;\n" \
           "  for (struct RClass*& c : bc2cpp_owner_class_slots) c = nullptr;\n" \
           "}\n"
    unless entries.empty?
      # CLOSED_WORLD: a guard whose else arm raises must name exactly the class
      # the registry means, never a same-named constant found through ancestry.
      defined = @closed_world ? 'mrb_const_defined_at' : 'mrb_const_defined'
      out << <<~CPP
        static struct RClass* bc2cpp_owner_class_lookup(mrb_state* M, const char* const* path, int n) {
          mrb_value v = mrb_obj_value(M->object_class);
          for (int i = 0; i < n; ++i) {
            mrb_sym s = mrb_intern_cstr(M, path[i]);
            if (!#{defined}(M, v, s)) return nullptr;
            v = mrb_const_get(M, v, s);
          }
          return mrb_class_ptr(v);
        }
      CPP
    end
    entries.each do |owner, slot|
      i = slot[:index]
      path = lexical_scope_path(owner)
      out << <<~CPP
        static inline struct RClass* bc2cpp_owner_class_#{i}(mrb_state* M) {
          if (bc2cpp_owner_class_state != M) {
            bc2cpp_reset_owner_classes();
            bc2cpp_owner_class_state = M;
          }
          struct RClass* c = bc2cpp_owner_class_slots[#{i}];
          if (!c) {
            static const char* const path[] = {#{path.map { |seg| "\"#{seg}\"" }.join(', ')}};
            c = bc2cpp_owner_class_slots[#{i}] = bc2cpp_owner_class_lookup(M, path, #{path.size});
          }
          return c;
        }
      CPP
    end
    out
  end

  # The uncached GETCONST lookup: resolve the owner's lexical scope chain, probe
  # each scope innermost-first, fall back to Object. `d` is the destination
  # register number (a string). Used inline, and as the slow path of a
  # CONST_SITE_CACHE helper (which passes d = "0").
  def const_lookup_block(d, name, owner_path)
    if owner_path == ['Object']
      "  r#{d} = mrb_const_get(M, mrb_obj_value(M->object_class), mrb_intern_cstr(M, \"#{name}\"));\n"
    else
      @const_lookup_helper_used = true
      out = String.new
      out << "  {\n"
      scope_vars = []
      current = 'mrb_obj_value(M->object_class)'
      owner_path.each_with_index do |seg, i|
        out << "    mrb_value scope#{i} = mrb_const_get(M, #{current}, mrb_intern_cstr(M, \"#{seg}\"));\n"
        scope_vars << "scope#{i}"
        current = "scope#{i}"
      end
      out << "    mrb_bool ok = FALSE;\n"
      out << "    mrb_value r#{d}_tmp = mrb_nil_value();\n"
      scope_vars.reverse_each do |sv|
        out << "    if (!ok) r#{d}_tmp = bc2cpp_const_try(M, #{sv}, mrb_intern_cstr(M, \"#{name}\"), &ok);\n"
      end
      out << "    if (!ok) r#{d}_tmp = mrb_const_get(M, mrb_obj_value(M->object_class), mrb_intern_cstr(M, \"#{name}\"));\n"
      out << "    r#{d} = r#{d}_tmp;\n"
      out << "  }\n"
      out
    end
  end

  # File-scope state and helpers for CONST_SITE_CACHE. Each helper returns the
  # constant's class or module, running the full lookup only until that first
  # succeeds (a failed lookup still raises from the same code and stores
  # nothing). Only a class/module value is stored. Keyed on the mrb_state* with
  # its own reset, dropped by each compiled gem's gem_final via
  # bc2cpp_reset_const_site_cache(); always emitted so gem_final can call it.
  def emit_const_site_cache
    entries = (@const_site_cache || {}).values
    count = [entries.size, 1].max
    out = +"// CONST_SITE_CACHE -- see tools/bc2cpp/const_site_cache.rb.\n"
    out << "static mrb_state* bc2cpp_cconst_state = nullptr;\n"
    out << "static mrb_value bc2cpp_cconst_slots[#{count}];\n"
    out << "static bool bc2cpp_cconst_have[#{count}] = {};\n"
    out << "static void bc2cpp_reset_const_site_cache() {\n" \
           "  bc2cpp_cconst_state = nullptr;\n" \
           "  for (bool& h : bc2cpp_cconst_have) h = false;\n" \
           "}\n"
    entries.each do |slot|
      i = slot[:index]
      out << "static mrb_value bc2cpp_cconst_#{i}(mrb_state* M) {\n" \
             "  if (bc2cpp_cconst_state != M) {\n" \
             "    bc2cpp_reset_const_site_cache();\n" \
             "    bc2cpp_cconst_state = M;\n" \
             "  }\n" \
             "  if (bc2cpp_cconst_have[#{i}]) return bc2cpp_cconst_slots[#{i}];\n" \
             "  mrb_value r0 = mrb_nil_value();\n"
      out << slot[:body].lines.map { |l| "  #{l}" }.join
      out << "  if (mrb_type(r0) == MRB_TT_CLASS || mrb_type(r0) == MRB_TT_MODULE) {\n" \
             "    bc2cpp_cconst_slots[#{i}] = r0;\n" \
             "    bc2cpp_cconst_have[#{i}] = true;\n" \
             "  }\n" \
             "  return r0;\n" \
             "}\n"
    end
    out
  end

  # mruby's variadic mrb_funcall/mrb_funcall_id copy into a fixed
  # MRB_FUNCALL_ARGC_MAX array and raise "Too long arguments" past it.
  FUNCALL_ARGC_MAX = 16

  def dynamic_dispatch_line(d, recv, name, argv)
    if argv.empty?
      "r#{d} = mrb_funcall(M, #{recv}, \"#{name}\", 0);\n"
    elsif argv.size > FUNCALL_ARGC_MAX
      # A literal-sized splat unrolls one argument per element
      # (Game::Battle.from_actor's 22-field `Combatant.new(*[...])`).
      # mrb_funcall_argv has no such cap: it packs 15+ into a splat itself.
      "{ mrb_value bc2cpp_argv[] = { #{argv.join(', ')} }; " \
        "r#{d} = mrb_funcall_argv(M, #{recv}, mrb_intern_lit(M, \"#{name}\"), #{argv.size}, bc2cpp_argv); }\n"
    else
      "r#{d} = mrb_funcall(M, #{recv}, \"#{name}\", #{argv.size}, #{argv.join(', ')});\n"
    end
  end

  # CLOSED_WORLD: the else arm of a receiver-class guard chain listing
  # `listed`. `site` is closed_world_site's result, nil for a chain this does
  # not model. A proven fallback raises what dispatch would (bc2cpp_nomethod);
  # a refused one keeps dispatch and names the reason for the summary.
  def guarded_fallback_line(d, recv, name, argv, listed, site)
    dispatch = dynamic_dispatch_line(d, recv, name, argv)
    return dispatch unless @closed_world && site

    reason = argv.size > FUNCALL_ARGC_MAX ? :argc : @closed_world.refusal(name, listed, site[:self_owner],
                                                                          symbol_installed_names)
    return dispatch.sub(/\n\z/, " /* CLOSED_WORLD kept: #{reason} */\n") if reason

    args = argv.empty? ? '' : ", #{argv.size}, #{argv.join(', ')}"
    "r#{d} = bc2cpp_nomethod_named(M, #{recv}, \"#{name}\"#{args});\n"
  end

  # CLOSED_WORLD: the facts guarded_fallback_line needs about a call site --
  # the enclosing owner when the receiver is provably that method's own self.
  def closed_world_site(recv, irep, idx, owner_def)
    return nil unless @closed_world

    self_owner = owner_def && self_class(owner_def)
    unless recv == 'self'
      reg = recv[/\Ar(\d+)\z/, 1]
      prev = reg && irep && idx&.positive? && irep.instructions[idx - 1]
      self_loaded = prev && prev.op == 'LOADSELF' && prev.args[/\AR(\d+)/, 1] == reg &&
                    fixnum_proof_preds(irep)&.fetch(idx, nil).to_a == [idx - 1]
      self_owner = nil unless self_loaded
    end
    { self_owner: self_owner }
  end

  def regs(args_text, count)
    args_text.scan(/R(\d+)/).flatten.first(count)
  end

  def c_string_literal(s)
    '"' + s.bytes.map { |b| format('\\x%02x', b) }.join + '"'
  end
end

if $PROGRAM_NAME == __FILE__
  srcs = ARGV
  raise 'usage: bc2cpp.rb file1.rb [file2.rb ...]  (env: MRBC, OUT_SYMBOL, OUT_DIR, ONLY_OWNERS)' if srcs.empty?

  symbol = ENV['OUT_SYMBOL'] || File.basename(srcs.first, '.rb').gsub(/[^a-zA-Z0-9_]/, '_')
  out_dir = ENV['OUT_DIR'] || File.dirname(srcs.first)

  c_src, disasm_text = run_mrbc(srcs, symbol, out_dir)
  ireps, root_label = parse_c_dump(c_src, symbol)
  order = dfs_order(ireps, root_label)
  blocks, block_files, block_catches = parse_disasm_blocks(disasm_text)
  merge!(ireps, order, blocks, block_files, block_catches)
  registry, superclass_of, container_constants, included_modules, prepended_modules, unknown_mixins,
    struct_member_lists, class_decls, walked_ireps = build_registry(ireps, root_label)

  # NATIVE_SRCS: C/C++ sources to scan for mrb_define_method-family calls (see
  # extract_native_method_names). Without it the registry cannot see native
  # definitions.
  native_name_sources = nil
  native_expression_devirt = {}
  native_registered_expressions = {}
  if ENV['NATIVE_SRCS']
    native_paths = Shellwords.split(ENV['NATIVE_SRCS'])
    native_expression_devirt = NativeExpressionDevirt.analyze(native_paths)
    native_registered_expressions = NativeExpressionDevirt.analyze_exact_class_expressions(native_paths)
    warn "== generated native C-expression devirtualizations (#{native_expression_devirt.size}) =="
    native_expression_devirt.sort.each { |name, expression| warn "  C_EXPR :#{name}  (#{expression})" }
    native_registered_expressions.sort.each do |name, entries|
      entries.each do |entry|
        owner = entry[:owner]
        warn "  C_EXPR :#{name}  (#{owner[:class_name]}##{name}: #{entry[:expression]})"
      end
    end
    warn ''
    # ZSUPER_NATIVE_SUPPORT: the flat name set is derived from the per-name source
    # map, so NATIVE_SRCS is read once and the two agree.
    native_name_sources = extract_native_method_sources(native_paths)
    native_names = native_name_sources.keys.to_set
    flipped = native_names.select { |n| registry.key?(n) && registry[n].size == 1 }
    native_names.each do |name|
      registry[name] << MethodDef.new(name: name, owner: '<native>', irep: nil, visibility: :public)
    end
    warn "== native method names (#{native_names.size} from NATIVE_SRCS, #{flipped.size} flipped a MONO name to POLY) =="
    flipped.sort.each { |n| warn "  FLIP :#{n}" }
    warn ''
    # NATIVE_CONSTRUCT_SCHEMA_AUDIT: audit only; skipped without NATIVE_SRCS.
    warn '== native construct schema audit (row vs scraped mrb_get_args) =='
    NATIVE_CONSTRUCT_TARGETS.sort.each do |klass, row|
      verdict, detail = NativeConstructSchema.audit(native_paths, klass, row)
      warn "  #{verdict.to_s.upcase}  #{klass}  (#{detail})"
    end
    warn ''
  end

  warn '== whole-program method registry =='
  registry.sort.each do |name, defs|
    mono = defs.size == 1
    owners = defs.map(&:owner).join(', ')
    warn "  #{mono ? 'MONO' : 'POLY'}  :#{name}  (#{defs.size} def#{'s' unless defs.size == 1}: #{owners})"
  end

  arg_types = ArgTypes.analyze(ireps, registry)
  warn ''
  warn '== call-site argument-type inference (MONO names only) =='
  inferred_any = false
  arg_types.each do |name, types|
    types.each_with_index do |t, i|
      next unless t

      inferred_any = true
      warn "  ARG  :#{name}, position #{i + 1}  (#{t})"
    end
  end
  warn '  (none inferred)' unless inferred_any

  annotations = Annotations.extract(ireps, registry)
  warn ''
  warn '== magic-comment annotations (# bc2cpp: (T, ...) -> T) =='
  if annotations.empty?
    warn '  (none found)'
  else
    annotations.each do |label, ann|
      d = registry.values.flatten.find { |md| md.irep == label }
      name = d ? "#{d.owner}##{d.name}" : label
      warn "  ANNOTATED  #{name}  (#{ann.args.inspect} -> #{ann.ret.inspect})"
    end
  end

  # INTEGER_CONST_EMBED_SUPPORT / ARRAY_RETURN_IVAR_HINT: foreign sources,
  # foreign method names and integer constants are computed before
  # IvarLayout.analyze (which embeds `@x = SOME_INT_CONST`) and ClassLayout's
  # probing pass (ARRAY_RETURN_PROOF needs foreign_methods). Without
  # NATIVE_SRCS or FOREIGN_RUBY_SRCS both analyses skip and prove nothing extra,
  # rather than run on a knowingly incomplete picture. Diagnostic consumers find
  # sections by header text, not position.
  foreign_ruby_srcs = ENV['FOREIGN_RUBY_SRCS'] ? Shellwords.split(ENV['FOREIGN_RUBY_SRCS']) : nil
  foreign_methods = foreign_ruby_srcs ? foreign_method_names(foreign_ruby_srcs) : nil

  # UNIQUE_CLASS_NAME: set before the first ClassLayout pass, since every
  # trace_new_target caller reads it.
  UniqueClassNames.table = UniqueClassNames.analyze(ireps, root_label, native_paths, foreign_ruby_srcs)
  UniqueClassNames.object_mixins = Array(included_modules['Object'])
  warn '== bare class names with one definition (UNIQUE_CLASS_NAME) =='
  UniqueClassNames.table.sort.each { |name, full| warn "  UNIQUE_CLASS  #{name}  (#{full})" }

  integer_constants =
    if ENV['NATIVE_SRCS'] && foreign_ruby_srcs
      IntegerConstants.analyze(ireps, native_paths, foreign_ruby_srcs)
    else
      Set.new
    end
  warn "== integer-valued constants proven (INTEGER_CONSTANT_PROOF) =="
  if integer_constants.empty?
    warn '  (none)'
  else
    integer_constants.sort.each { |n| warn "  CONST #{n}" }
  end

  integer_constant_values = IntegerConstants.analyze_values(ireps, integer_constants)
  warn "== integer constant literal values proven (INTEGER_CONSTANT_VALUE_PROOF): #{integer_constant_values.size} of #{integer_constants.size} =="
  integer_constant_values.sort.each { |n, v| warn "  CONST #{n} = #{v}" }

  # FIXNUM_RETURN_IVAR_HINT: Level 0 IvarLayout (no FIXNUM_RETURN_PROOF evidence).
  # The `== ivar embedding ==` diagnostic is printed later from the final
  # (Level 2) table, so this call is silent.
  ivar_layout = IvarLayout.analyze(ireps, registry, arg_types, annotations, integer_constants)

  known_owners = registry.values.flatten.map(&:owner).uniq
  class_annotations = ClassAnnotations.extract(ireps, registry, known_owners)
  warn ''
  warn '== magic-comment class annotations (# bc2cpp: (ClassName, ...)) =='
  if class_annotations.empty?
    warn '  (none found)'
  else
    class_annotations.each do |label, ann|
      d = registry.values.flatten.find { |md| md.irep == label }
      name = d ? "#{d.owner}##{d.name}" : label
      warn "  CLASS_ANNOTATED  #{name}  (#{ann.args.inspect})"
    end
  end

  warn ''
  warn '== known container-class constants (Array/Hash/Range-valued, whole program) =='
  if container_constants.empty?
    warn '  (none)'
  else
    container_constants.sort.each { |name, cls| warn "  CONST_HINT  #{name}  (#{cls})" }
  end

  # ANNOTATED_ARRAY_RETURN_THREADING: CodeGen#annotated_array_return's MONO-keyed
  # lookup, as a lambda because CodeGen does not exist yet at this point.
  annotated_array_return = lambda do |name|
    defs = registry[name]
    next false unless defs && defs.size == 1 && defs.first.irep

    annotations[defs.first.irep]&.ret == :array
  end
  # ANY_OPAQUE_SUPPORT: owner -> {ivar => :any | :opaque}, filled by
  # ClassLayout.analyze (see `poison_reason`) and reported as extra breakdowns of
  # the same candidate list.
  # FIXNUM_RETURN_PROOF / ARRAY_RETURN_PROOF: the foreign poison set, computed
  # here because the probing pass below needs ARRAY_RETURN_PROOF, which proves
  # nothing without it (nil without FOREIGN_RUBY_SRCS).

  # ---------------------------------------------------------------------------
  # ARRAY_RETURN_IVAR_HINT: ClassLayout and ARRAY_RETURN_PROOF depend on each
  # other (compute_array_return_names reads ClassLayout through
  # trace_new_target's GETIV terminal, and ClassLayout's SETIV arm consumes the
  # proof). Naively that admits circular facts:
  #
  #     def initialize; @queue = turn_order; end
  #     def turn_order; @queue; end          # @queue is really nil
  #
  # Stratified: Level 0 = ClassLayout without the proof; Level 1 =
  # ARRAY_RETURN_PROOF against Level 0; Level 2 = ClassLayout with Level 1. Each
  # level uses only the level below, so derivations are well-founded (here
  # @queue stays UNKNOWN). Level 1 is sound given Level 0 (its argument only
  # assumes the ClassLayout facts are true), and Level 2 only adds evidence;
  # disagreeing sites still poison. Monotone: the new evidence only turns
  # UNKNOWN into 'Array', so Level 2 is a superset of Level 0, and everything
  # downstream uses Level 2.
  # Not iterated to a joint fixpoint: sound but a bigger change; stopping early
  # proves less. The real CodeGen still recomputes ARRAY_RETURN_PROOF against
  # Level 2.
  # ---------------------------------------------------------------------------
  class_layout_probe = ClassLayout.known(
    ClassLayout.analyze(ireps, registry, class_annotations, container_constants, annotated_array_return)
  )
  # Built just far enough to answer array_return_names (see CodeGen#initialize's
  # `analysis_only`); the inputs it is not given are never read by
  # compute_array_return_names.
  require_relative 'compiled_gems'
  # BC2CPP_SELF_REGISTERING: BC2CPP_WIRED_EMBEDDINGS exists because a
  # hand-written register.cxx may leave an embedding class's entry point
  # uninstalled (it then runs interpreted against iv_tbl). A caller whose
  # registration is generated from the same `embeds`/`compiled entry points`
  # diagnostic (tools/optcarrot_probe/compiled_run.rb) cannot have that gap and
  # sets this to skip the allowlist; drop_unsafe_embeddings' other checks still
  # run.
  CodeGen.wired_embeddings = BC2CPP_WIRED_EMBEDDINGS unless ENV['BC2CPP_SELF_REGISTERING'] == '1'
  CodeGen.embed_ivar_limits = BC2CPP_EMBED_IVAR_LIMITS unless ENV['BC2CPP_SELF_REGISTERING'] == '1'
  return_names_probe = CodeGen.new(ireps, registry, ivar_layout, class_layout_probe, class_annotations,
                                    annotations, superclass_of, {}, {}, container_constants, {},
                                    Set.new, foreign_methods, nil, nil,
                                    analysis_only: true,
                                    native_expression_devirt: native_expression_devirt,
                                    native_registered_expressions: native_registered_expressions)
  array_return_probe = return_names_probe.array_return_names
  # RETCLASS_SELF_CALL_SUPPORT: from the same Level-0 probe as
  # array_return_probe (see ClassLayout.analyze's `ret_class_proof`).
  class_poison_reason = {}
  class_layout_raw = ClassLayout.analyze(ireps, registry, class_annotations, container_constants,
                                         annotated_array_return, poison_reason: class_poison_reason,
                                         array_ret_proof: ->(n) { array_return_probe.include?(n) },
                                         ret_class_proof: ->(n, o) { return_names_probe.class_return_for_self_call(n, o) })
  class_layout = ClassLayout.known(class_layout_raw)
  warn ''
  warn '== known-ivar-class hints (devirtualization only, never embedded) =='
  if class_layout.empty?
    warn '  (none)'
  else
    class_layout.each do |klass, ivars|
      ivars.each { |name, cls| warn "  CLASS_HINT  #{klass}#@#{name}  (#{cls})" }
    end
  end

  class_layout_unknowns = ClassLayout.unknowns(class_layout_raw)
  warn ''
  warn '== ivar-class candidates (real SETIV evidence found, but poisoned to unknown) =='
  if class_layout_unknowns.empty?
    warn '  (none)'
  else
    class_layout_unknowns.sort.each { |n| warn "  CLASS_CANDIDATE  #{n}" }
  end

  # ANY_OPAQUE_SUPPORT: :any = two traced sites disagree (not worth annotating);
  # :opaque = some site could not be traced (an annotation candidate).
  warn ''
  warn '== ivar-class candidates split: ANY (proven heterogeneous, not fixable) =='
  any = ClassLayout.unknowns_by_reason(class_layout_raw, class_poison_reason, :any)
  if any.empty?
    warn '  (none)'
  else
    any.sort.each { |n| warn "  CLASS_CANDIDATE_ANY  #{n}" }
  end

  warn ''
  warn '== ivar-class candidates split: OPAQUE (unresolved, may be fixable) =='
  opaque = ClassLayout.unknowns_by_reason(class_layout_raw, class_poison_reason, :opaque)
  if opaque.empty?
    warn '  (none)'
  else
    opaque.sort.each { |n| warn "  CLASS_CANDIDATE_OPAQUE  #{n}" }
  end

  # ELEMENT_CLASS_SUPPORT: after ClassLayout (only proven-Array ivars are swept)
  # and ClassAnnotations (argument class hints are terminals).
  element_annotations = ElementAnnotations.extract(ireps, registry, known_owners)
  warn ''
  warn '== magic-comment element annotations (# bc2cpp: ... -> Array<Klass> / -> Klass) =='
  if element_annotations.empty?
    warn '  (none found)'
  else
    element_annotations.each do |label, ann|
      d = registry.values.flatten.find { |md| md.irep == label }
      name = d ? "#{d.owner}##{d.name}" : label
      claim = ann.element ? "Array<#{ann.element}>" : ann.ret_class
      warn "  ELEM_ANNOTATED  #{name}  (-> #{claim})"
    end
  end

  # ANY_OPAQUE_SUPPORT: as class_poison_reason.
  element_poison_reason = {}
  element_raw = ArrayElementLayout.analyze(ireps, registry, class_layout, class_annotations,
                                           element_annotations, superclass_of,
                                           poison_reason: element_poison_reason)
  element_layout = ArrayElementLayout.known(element_raw)
  warn ''
  warn '== known-array-element-class hints (guarded devirtualization only) =='
  if element_layout.empty?
    warn '  (none)'
  else
    element_layout.each do |klass, ivars|
      ivars.each { |name, cls| warn "  ELEM_HINT  #{klass}#@#{name}  (Array<#{cls}>)" }
    end
  end

  # PRIMITIVE_ELEMENT_SUPPORT: ivars whose elements are primitive tags;
  # informational, excluded from element_layout/ELEM_HINT (see
  # ArrayElementLayout.primitives).
  element_primitives = ArrayElementLayout.primitives(element_raw)
  warn ''
  warn '== known-array-element PRIMITIVE hints (informational only, never embedded) =='
  if element_primitives.empty?
    warn '  (none)'
  else
    element_primitives.each do |klass, ivars|
      ivars.each { |name, cls| warn "  ELEM_HINT_PRIMITIVE  #{klass}#@#{name}  (Array<#{cls}>)" }
    end
  end

  element_unknowns = ArrayElementLayout.unknowns(element_raw)
  warn ''
  warn '== array-element candidates (proven-Array ivar, element class poisoned to unknown) =='
  if element_unknowns.empty?
    warn '  (none)'
  else
    element_unknowns.each { |n| warn "  ELEM_CANDIDATE  #{n}" }
  end

  warn ''
  warn '== array-element candidates split: ANY (proven heterogeneous, not fixable) =='
  elem_any = ArrayElementLayout.unknowns_by_reason(element_raw, element_poison_reason, :any)
  if elem_any.empty?
    warn '  (none)'
  else
    elem_any.sort.each { |n| warn "  ELEM_CANDIDATE_ANY  #{n}" }
  end

  warn ''
  warn '== array-element candidates split: OPAQUE (unresolved, may be fixable) =='
  elem_opaque = ArrayElementLayout.unknowns_by_reason(element_raw, element_poison_reason, :opaque)
  if elem_opaque.empty?
    warn '  (none)'
  else
    elem_opaque.sort.each { |n| warn "  ELEM_CANDIDATE_OPAQUE  #{n}" }
  end

  # HASH_ELEMENT_SUPPORT: after ArrayElementLayout, so values chained through a
  # known-element array resolve (see HashElementLayout.analyze).
  # ANY_OPAQUE_SUPPORT: as class_poison_reason.
  hash_poison_reason = {}
  hash_element_raw = HashElementLayout.analyze(ireps, registry, class_layout, class_annotations,
                                               element_annotations, element_raw, superclass_of,
                                               poison_reason: hash_poison_reason)
  hash_element_layout = HashElementLayout.known(hash_element_raw)
  warn ''
  warn '== known-hash-element-class hints (guarded devirtualization only) =='
  if hash_element_layout.empty?
    warn '  (none)'
  else
    hash_element_layout.each do |klass, ivars|
      ivars.each { |name, cls| warn "  HASH_ELEM_HINT  #{klass}#@#{name}  (Hash<#{cls}>)" }
    end
  end

  # PRIMITIVE_ELEMENT_SUPPORT: as element_primitives.
  hash_element_primitives = HashElementLayout.primitives(hash_element_raw)
  warn ''
  warn '== known-hash-element PRIMITIVE hints (informational only, never embedded) =='
  if hash_element_primitives.empty?
    warn '  (none)'
  else
    hash_element_primitives.each do |klass, ivars|
      ivars.each { |name, cls| warn "  HASH_ELEM_HINT_PRIMITIVE  #{klass}#@#{name}  (Hash<#{cls}>)" }
    end
  end

  hash_element_unknowns = HashElementLayout.unknowns(hash_element_raw)
  warn ''
  warn '== hash-element candidates (proven-Hash ivar, value class poisoned to unknown) =='
  if hash_element_unknowns.empty?
    warn '  (none)'
  else
    hash_element_unknowns.each { |n| warn "  HASH_ELEM_CANDIDATE  #{n}" }
  end

  warn ''
  warn '== hash-element candidates split: ANY (proven heterogeneous, not fixable) =='
  hash_any = HashElementLayout.unknowns_by_reason(hash_element_raw, hash_poison_reason, :any)
  if hash_any.empty?
    warn '  (none)'
  else
    hash_any.sort.each { |n| warn "  HASH_ELEM_CANDIDATE_ANY  #{n}" }
  end

  warn ''
  warn '== hash-element candidates split: OPAQUE (unresolved, may be fixable) =='
  hash_opaque = HashElementLayout.unknowns_by_reason(hash_element_raw, hash_poison_reason, :opaque)
  if hash_opaque.empty?
    warn '  (none)'
  else
    hash_opaque.sort.each { |n| warn "  HASH_ELEM_CANDIDATE_OPAQUE  #{n}" }
  end

  candidates = report_annotation_candidates(ireps, registry, arg_types, annotations)
  warn ''
  warn '== annotation candidates (opaque incoming argument, unresolved) =='
  if candidates.empty?
    warn '  (none)'
  else
    candidates.each do |c|
      target = c[:ivar] ? "-> @#{c[:ivar]}" : "-> (used in #{c[:via]})"
      warn "  CANDIDATE  #{c[:owner]}##{c[:name]}, arg #{c[:pos]}/#{c[:mand]} #{target}"
    end
  end

  # `annotations` also drives NATIVE_ARG_TARGETS.
  # FIXNUM_RETURN_PROOF: without FOREIGN_RUBY_SRCS this is nil (never an empty
  # set), which compute_fixnum_return_names reads as "no scan" and proves
  # nothing.
  # ENTRY_ARG_CALLSITE_PROOF: every identifier token from the same two inputs
  # (see outside_world_tokens); nil when either is absent.
  outside_tokens =
    if native_paths && foreign_ruby_srcs
      outside_world_tokens(native_paths + foreign_ruby_srcs)
    end
  warn ''
  # BC2CPP_SELF_REGISTERING: same guard as for the probing CodeGen above.
  CodeGen.wired_embeddings = BC2CPP_WIRED_EMBEDDINGS unless ENV['BC2CPP_SELF_REGISTERING'] == '1'
  CodeGen.embed_ivar_limits = BC2CPP_EMBED_IVAR_LIMITS unless ENV['BC2CPP_SELF_REGISTERING'] == '1'
  CodeGen.stable_class_constants = StableClassConstants.analyze(ireps, native_paths, foreign_ruby_srcs) |
                                    StableClassConstants.analyze_native(ireps, native_paths, foreign_ruby_srcs)
  warn "== stable class constants (CONST_SITE_CACHE): #{CodeGen.stable_class_constants.size} =="
  CodeGen.struct_members = struct_member_lists
  warn "== Struct.new owners with a known member list (STRUCT_INDEX_CACHE): #{CodeGen.struct_members.size} =="
  CodeGen.integer_constant_values = integer_constant_values
  CodeGen.stable_class_constants.sort.each { |n| warn "  STABLE_CLASS #{n}" }

  # ---------------------------------------------------------------------------
  # FIXNUM_RETURN_IVAR_HINT: IvarLayout and FIXNUM_RETURN_PROOF depend on each
  # other (trace_type's SEND case trusts a proven Fixnum return, and that proof's
  # source 3 reads @ivar_layout), e.g. optcarrot's `@_pc =
  # peek16(RESET_VECTOR)` where peek16 is proven only through ivar reads.
  # Stratified like ARRAY_RETURN_IVAR_HINT: Level 0 = `ivar_layout` as computed
  # above; Level 1 = FIXNUM_RETURN_PROOF from a probing CodeGen on Level 0
  # (`analysis_only: :fixnum_return`), with every other table already final
  # (none of them take ivar_layout); Level 2 = IvarLayout.analyze with Level 1
  # available to trace_type's SEND arm, passed to the real CodeGen.
  # Sound: Level 1 is the unchanged proof run on a subset of the final ivar
  # facts (never more permissive). Level 2 only turns UNKNOWN SEND sites into
  # :fixnum (guarded by MONO uniqueness), so it is a superset of Level 0. Not
  # iterated further, for the reasons given for ARRAY_RETURN_IVAR_HINT; the real
  # CodeGen recomputes FIXNUM_RETURN_PROOF against Level 2.
  # ---------------------------------------------------------------------------
  fixnum_return_probe = CodeGen.new(ireps, registry, ivar_layout, class_layout, class_annotations, annotations,
                                    superclass_of, element_layout, element_annotations, container_constants,
                                    hash_element_layout, integer_constants, foreign_methods, outside_tokens,
                                    native_name_sources, included_modules, prepended_modules, unknown_mixins,
                                    analysis_only: :fixnum_return,
                                    native_expression_devirt: native_expression_devirt,
                                    native_registered_expressions: native_registered_expressions).fixnum_return_names
  ivar_layout = IvarLayout.analyze(ireps, registry, arg_types, annotations, integer_constants, fixnum_return_probe)
  warn ''
  warn '== ivar embedding =='
  if ivar_layout.empty?
    warn '  (none embeddable)'
  else
    ivar_layout.each do |klass, ivars|
      ivars.each { |name, type| warn "  EMBED  #{klass}#@#{name}  (#{type})" }
    end
  end

  # CLOSED_WORLD (docs/adr/0210): only for a build whose real gem list
  # (BC2CPP_BUILD_GEMS, from the compiled gem's own codegen task) passes
  # compiled_gems.rb's check; the scan reads that build's own sources.
  closed_world = nil
  if ENV['BC2CPP_CLOSED_WORLD'] == '1'
    repo_root = File.expand_path('../..', __dir__)
    build_name = ENV['BC2CPP_BUILD_NAME'].to_s
    build_gems = Shellwords.split(ENV['BC2CPP_BUILD_GEMS'].to_s).to_h { |kv| kv.split('=', 2) }
    errors = bc2cpp_closed_world_violations(build_name, build_gems, repo_root)
    abort "bc2cpp: BC2CPP_CLOSED_WORLD refused for build '#{build_name}':\n  #{errors.join("\n  ")}" unless errors.empty?

    outside_native, outside_ruby = bc2cpp_closed_world_outside_srcs(build_name, build_gems, repo_root)
    closed_world = ClosedWorld.new(ireps: ireps, registry: registry, class_decls: class_decls, walked: walked_ireps,
                                   native_paths: outside_native, ruby_paths: outside_ruby)
    warn "== closed world (#{build_name}: #{build_gems.size} gems, #{outside_native.size} native + " \
         "#{outside_ruby.size} Ruby outside sources) =="
    warn "  global refusal: #{closed_world.global_refusal || 'none'}"
    warn "  method_missing classes: #{closed_world.method_missing_classes.to_a.sort.join(', ')}"
    warn ''
  end

  gen = CodeGen.new(ireps, registry, ivar_layout, class_layout, class_annotations, annotations, superclass_of,
                    element_layout, element_annotations, container_constants, hash_element_layout,
                    integer_constants, foreign_methods, outside_tokens, native_name_sources,
                    included_modules, prepended_modules, unknown_mixins,
                    native_expression_devirt: native_expression_devirt,
                    native_registered_expressions: native_registered_expressions,
                    closed_world: closed_world)
  warn '== methods proven Fixnum-returning (FIXNUM_RETURN_PROOF) =='
  if gen.fixnum_return_names.empty?
    warn '  (none)'
  else
    gen.fixnum_return_names.sort.each { |n| warn "  RET #{n}" }
  end
  warn ''
  # ARRAY_RETURN_PROOF listing, one line per name like the one above, so the
  # coverage report can count it. See CodeGen#compute_array_return_names.
  warn '== methods proven Array-returning (ARRAY_RETURN_PROOF) =='
  if gen.array_return_names.empty?
    warn '  (none)'
  else
    gen.array_return_names.sort.each { |n| warn "  ARET #{n}" }
  end
  warn ''
  # ENTRY_ARG_CALLSITE_PROOF: one line per (method, position), by owner/name.
  warn '== entry arguments proven Fixnum by call-site enumeration (ENTRY_ARG_CALLSITE_PROOF) =='
  entry_arg_facts = gen.entry_arg_fixnum_facts
  if entry_arg_facts.empty?
    warn '  (none)'
  else
    owner_by_irep = {}
    registry.each_value { |defs| defs.each { |d| owner_by_irep[d.irep] = d if d.irep } }
    entry_arg_facts.map do |(label, k)|
      d = owner_by_irep[label]
      d ? "  ARG #{d.owner}##{d.name} arg#{k}" : "  ARG <irep #{label}> arg#{k}"
    end.sort.each { |l| warn l }
  end
  warn ''
  # ONLY_OWNERS narrows emitted code (e.g. "LCF::File,LCF::Database"), not the
  # registry: srcs must still be the whole program (see compile_all).
  only_owners = ENV['ONLY_OWNERS']&.split(',')
  # OTHER_OWNERS: classes another gem's run compiles and exposes (with
  # OTHER_DECLS_HEADER); see compile_send.
  other_owners = ENV['OTHER_OWNERS']&.split(',')
  compiled = gen.compile_all(only_owners: only_owners, other_owners: other_owners)
  compiled += gen.emit_synthesized_accessors(only_owners: only_owners)

  # SKIP_UNSUPPORTED=1 drops methods containing `#error` from the output; they
  # stay interpreted. CLI exploration keeps the markers visible; real builds
  # (mrbgem.rake) set this, since a `#error` stops the C++ build.
  if ENV['SKIP_UNSUPPORTED'] == '1'
    skipped, compiled = compiled.partition { |m| m[:code].include?('#error') }
    unless skipped.empty?
      warn ''
      warn '== skipped (unsupported, left on the interpreter) =='
      skipped.each { |m| warn "  #{m[:owner]}##{m[:name]}" }
    end
  end

  puts '#include <mruby.h>'
  # isnan/isinf/floor/ceil for to_i's Float case (TO_I_TYPE_TAG_DISPATCH).
  puts '#include <math.h>'
  puts '#include <mruby/numeric.h>'
  puts '#include <mruby/string.h>'
  puts '#include <mruby/variable.h>'
  puts '#include <mruby/data.h>'
  puts '#include <mruby/hash.h>'
  puts '#include <mruby/array.h>'
  puts '#include <mruby/class.h>'
  # mrb_range_new for RANGE_INC/RANGE_EXC.
  puts '#include <mruby/range.h>'
  # mrb_protect_error for GETCONST's owner-scope-first lookup (core API, not the
  # mruby-error gem).
  puts '#include <mruby/error.h>'
  # mrb_proc_new_cfunc for BLOCK_CFUNC_FALLBACK_SUPPORT; this header has a
  # C-linkage guard, so a plain #include is fine.
  puts '#include <mruby/proc.h>'
  # EXCEPTION_BREAK_SUPPORT: the exception a BLOCK_FALLBACK BREAK throws and the
  # call-site glue catches (mruby is built with MRB_USE_CXX_EXCEPTION). Always
  # emitted: a header-only struct with nothing to link.
  puts 'struct bc2cpp_block_break { mrb_value value; };'
  # EXCEPTION_RETURN_SUPPORT: a DIFFERENT type from bc2cpp_block_break, so the
  # method-level catch and the per-call-site catch never catch each other's
  # exception (exact C++ catch matching).
  puts 'struct bc2cpp_method_return { mrb_value value; };'
  # VM_UNWIND_RESTORE: bc2cpp_block_break / bc2cpp_method_return are foreign
  # C++ exceptions, which mruby's own MRB_TRY/MRB_CATCH (`catch (mrb_jmpbuf*)`)
  # does not intercept. When one unwinds through real VM frames (a compiled block
  # that returns or breaks out of a Ruby-defined iterator such as `each`),
  # mrb_vm_exec/mrb_funcall_with_block never run their cleanup: mrb->jmp points
  # at a dead frame and the callinfo stack keeps every frame pushed since, which
  # trips mrb_vm_run's `c->ci == c->cibase || ...` assertion. Every catch site
  # takes a mark before its `try` and restores it here, as mrb_protect_error does
  # for an mruby exception: reset mrb->jmp and pop the leftover callinfos,
  # unsharing each popped frame's env as the VM's cipop does.
  puts <<~'CPP'
    struct Bc2cppVmMark { struct mrb_jmpbuf* jmp; ptrdiff_t ci_index; };
    static inline Bc2cppVmMark bc2cpp_vm_mark(mrb_state* M) {
      return { M->jmp, M->c->ci - M->c->cibase };
    }
    static void bc2cpp_vm_restore(mrb_state* M, const Bc2cppVmMark& mark) {
      M->jmp = mark.jmp;
      struct mrb_context* c = M->c;
      while (c->ci - c->cibase > mark.ci_index) {
        mrb_callinfo* ci = c->ci;
        mrb_vm_ci_env_clear(M, ci);
        struct RProc* blk = ci->blk;
        if (blk && !MRB_PROC_STRICT_P(blk) && MRB_PROC_ENV(blk) == mrb_vm_ci_env(&ci[-1])) {
          blk->flags |= MRB_PROC_ORPHAN;
        }
        c->ci--;
      }
      if (M->errinfo && (c->ci - c->cibase) < M->errinfo_ci_depth) M->errinfo = NULL;
    }
  CPP
  # ENSURE_RAII_SUPPORT: the runtime guard for a recognized `ensure`
  # (recognize_ensure_region / emit_ensure_guard_open). A C++ destructor runs on
  # every exit:
  #   - fall-through and `return` (the operand is evaluated first, so a plain
  #     ensure cannot change the returned value, as in Ruby);
  #   - this file's bc2cpp_block_break / bc2cpp_method_return unwinding;
  #   - a Ruby `raise`: only because mruby is built with MRB_USE_CXX_EXCEPTION,
  #     so MRB_THROW is a real C++ `throw (mrb_jmpbuf*)` (mruby/throw.h). With
  #     setjmp/longjmp the destructor would not run. See docs/adr/0134 and
  #     build_config.rb's wio section for why that configuration is required.
  # Nothing may escape the destructor (std::terminate during unwinding), so the
  # ensure body runs under mrb_protect_error, which also pops the callinfo stack
  # back (vm.c MRB_CATCH arm) and restores the GC arena. Registers live before
  # the guard were allocated below that arena index, so they stay protected.
  # MRB_THROW needs mruby/throw.h, which <mruby.h> does not include.
  puts '#include <mruby/throw.h>'
  # std::uncaught_exceptions(): the guard's "is an unwind in flight" test (see
  # the guard).
  puts '#include <exception>'
  puts <<~'ENSURE_GUARD'
    template <class F>
    struct bc2cpp_ensure_guard {
      mrb_state* M;
      F fn;
      ~bc2cpp_ensure_guard() noexcept(false) {
        struct RObject* saved = M->exc;
        M->exc = NULL;
        /* M->exc is itself a GC root (src/gc.c's own mrb_gc_mark of it in
           both mark phases). Clearing it just above therefore removed the
           ONLY root keeping the in-flight exception alive -- the object
           may long since have been dropped from the GC arena by the
           ordinary mrb_gc_arena_restore every VM send already does. The
           ensure body allocates and so can trigger a real GC, which would
           then collect the very exception this guard is about to put
           back. Re-root it in the arena for the duration, BELOW the index
           mrb_protect_error saves and restores internally, so its own
           restore cannot drop this entry either.

           Found by the differential test, not by reading: it shows up
           only once enough allocation has happened to make a GC actually
           fire inside the ensure body, which is exactly the kind of
           silent, load-dependent corruption a wrong `ensure` translation
           produces. */
        int bc2cpp_ai = mrb_gc_arena_save(M);
        if (saved) mrb_gc_protect(M, mrb_obj_value(saved));
        mrb_bool err = FALSE;
        mrb_value raised = mrb_protect_error(M, [](mrb_state* m, void* ud) -> mrb_value {
          (*(F*)ud)();
          return mrb_nil_value();
        }, (void*)&fn, &err);
        if (!err) {
          /* Restore the real root FIRST, then drop our arena entry. */
          M->exc = saved;
          mrb_gc_arena_restore(M, bc2cpp_ai);
          return;
        }
        /* The ensure body itself raised. Real Ruby semantics: that
           exception SUPERSEDES whatever was already propagating. */
        M->exc = mrb_obj_ptr(raised);
        mrb_gc_arena_restore(M, bc2cpp_ai);
        if (std::uncaught_exceptions() == 0 && M->jmp != NULL) {
          /* Nothing was unwinding yet (normal or `return` exit), so
             nothing will carry this exception outward unless we start
             the unwind ourselves. Throwing here is safe for exactly
             that reason -- hence noexcept(false).

             The test is std::uncaught_exceptions(), NOT "was M->exc
             set": this file's OWN bc2cpp_block_break/
             bc2cpp_method_return unwind the C++ stack while M->exc
             stays NULL, so keying off M->exc would throw straight into
             an in-flight exception and std::terminate -- the classic
             throwing-destructor hazard, and a real one here rather than
             a hypothetical, since those two types cross exactly these
             frames. */
          MRB_THROW(M->jmp);
        }
        /* Otherwise an unwind is already in progress and simply
           continues, now carrying the superseding exception in M->exc. */
      }
    };
  ENSURE_GUARD
  # GETIDX's String arm calls mrb_str_aref (src/string.c, non-static), declared
  # only in mruby/internal.h, which has no C-linkage guard; including it would
  # give it C++ linkage and fail to link. So it is declared `extern "C"` here
  # with internal.h's signature.
  puts 'extern "C" mrb_value mrb_str_aref(mrb_state*, mrb_value, mrb_value, mrb_value);'
  # INTEGER_LSHIFT's kernel: exported by numeric.c but declared in no public header.
  puts 'extern "C" mrb_bool mrb_num_shift(mrb_state*, mrb_int, mrb_int, mrb_int*);'
  # DIV_FASTPATH_SUPPORT: same internal.h situation as mrb_str_aref.
  puts 'extern "C" mrb_value mrb_div_int_value(mrb_state*, mrb_int, mrb_int);'
  # ZSUPER_NATIVE_SUPPORT: same internal.h situation (see ZSUPER_NATIVE_TARGETS).
  # Declared as internal.h does, `mrb_noreturn` included, so g++ treats the
  # following RETURN as unreachable.
  puts 'extern "C" mrb_noreturn void mrb_method_missing(mrb_state*, mrb_sym, mrb_value, mrb_value);'
  # OTHER_DECLS_HEADER: other gems' *_decls.h paths to #include, so calls to
  # OTHER_OWNERS targets are declared.
  if ENV['OTHER_DECLS_HEADER']
    Shellwords.split(ENV['OTHER_DECLS_HEADER']).each { |path| puts "#include \"#{path}\"" }
  end
  puts ''
  print gen.emit_structs
  print gen.emit_ary_entry_helper(compiled)
  print gen.emit_bool_check_helper(compiled)
  print gen.emit_const_lookup_helper
  print gen.emit_native_construct_decls
  print gen.emit_direct_construct_decls
  print gen.emit_forward_decls(compiled)
  print gen.emit_instance_tt_setup
  print gen.emit_owner_class_cache
  print gen.emit_owner_registrations(compiled, BC2CPP_WIRED_EMBEDDINGS)
  # SYMBOL_CACHE: rewrite every function first, so the table is complete before
  # it is printed ahead of the code that uses it.
  symbol_table = SymbolCache::Table.new
  compiled.each { |m| m[:code] = SymbolCache.rewrite(m[:code], symbol_table) }
  if closed_world
    kept = Hash.new(0)
    compiled.each { |m| m[:code].scan(%r{/\* CLOSED_WORLD kept: (\w+) \*/}) { |(r)| kept[r] += 1 } }
    converted = compiled.sum { |m| m[:code].scan(/\bbc2cpp_nomethod\(M,/).size }
    dropped = compiled.sum { |m| m[:code].scan(%r{^\s*// CLOSED_WORLD_SELF :}).size }
    warn "== closed world fallbacks: #{dropped} guards dropped, #{converted} bc2cpp_nomethod, " \
         "#{kept.values.sum} kept dispatching =="
    kept.sort_by { |r, n| [-n, r] }.each { |r, n| warn "  KEPT #{r}: #{n}" }
    warn ''
  end
  const_site_cache_code = SymbolCache.rewrite(gen.emit_const_site_cache, symbol_table)
  # OUTLINED_INDEX_OPS: after the symbol cache (their fallbacks become
  # bc2cpp_send too), ahead of every function that calls them.
  index_helpers_code = SymbolCache.rewrite(gen.emit_index_helpers(compiled), symbol_table)
  warn "== outlined index ops: #{gen.index_helper_site_counts(compiled).map { |k, n| "#{k} #{n}" }.join(', ')} sites =="
  warn ''
  print SymbolCache.emit(symbol_table)
  print const_site_cache_code
  print index_helpers_code
  compiled.each { |m| print m[:code] }

  # This run's cross-TU declarations header, for other gems'
  # OTHER_DECLS_HEADER (see emit_decls_header). Always written.
  File.write(File.join(out_dir, "#{symbol}_decls.h"), gen.emit_decls_header(compiled))

  warn ''
  warn '== compiled entry points =='
  compiled.each do |m|
    # A hand-written registration via plain mrb_define_method would make a
    # private/protected method public, so the listing flags visibility.
    vis =
      case m[:visibility]
      when :public then ''
      when :private then '  [private -- use mrb_define_private_method, not mrb_define_method]'
      when :protected then '  [protected -- mruby has no mrb_define_protected_method; ' \
                            'registering this with mrb_define_method makes it public, a real behavior change]'
      end
    # A ".singleton" owner (`def self.x` / `class << self`) must be registered with
    # mrb_define_class_method (onto the singleton class), not mrb_define_method.
    # Such entries are always :public (singleton privacy is not modelled), so the
    # note is appended independently of `vis`.
    singleton_note = m[:owner].end_with?('.singleton') ? '  [class method -- use mrb_define_class_method, ' \
                                                          'not mrb_define_method]' : ''
    warn "  #{m[:entry]} / #{m[:impl]}  (#{m[:owner]}##{m[:name]}, arity #{m[:arity]})#{vis}#{singleton_note}"
  end

  warn ''
  warn '== classes needing MRB_SET_INSTANCE_TT(..., MRB_TT_DATA) =='
  gen.embedding_classes.each { |k| warn "  #{k}" }

  # Step 6h's diagnostic: compiled entry points whose name is never a bytecode
  # call target (collect_static_call_target_names) nor a literal mrb_funcall
  # name in NATIVE_SRCS (extract_native_call_names): deletion candidates, not
  # proof. RGSS classes are the public API of per-game scripts this tool cannot
  # see (docs/rpgxp-rgss-api-gap.md), so names there are expected;
  # mruby-rpg2k/mruby-lcf have no external script layer, so their names are
  # stronger evidence.
  static_call_names = collect_static_call_target_names(ireps)
  native_call_names = ENV['NATIVE_SRCS'] ? extract_native_call_names(native_paths) : Set.new
  # Methods mruby's C core calls through a `mrb_sym mid = MRB_SYM(...)` local
  # rather than a literal, invisible to extract_native_call_names' forward
  # lookahead, each with a verified call site in 3rd/mruby/src: initialize /
  # initialize_copy (class.c), method_missing / respond_to_missing? (vm.c,
  # kernel.c, class.c), to_s / inspect (kernel.c, array.c), == / eql? / <=> /
  # hash (object.c, array.c, kernel.c, numeric.c, hash.c), call (hash.c default
  # proc). coerce/each/to_ary/to_str/to_int/to_hash/[] were checked and are not
  # called this way in this core.
  always_reachable = %w[
    initialize initialize_copy
    method_missing respond_to_missing?
    to_s inspect
    == eql? <=> hash
    call
  ].to_set
  reachable_names = static_call_names | native_call_names | always_reachable
  never_called = compiled.reject { |m| reachable_names.include?(m[:name]) }
  warn ''
  warn "== never called (#{never_called.size} of #{compiled.size} compiled entry points -- " \
       "zero evidence in this program's own bytecode or NATIVE_SRCS; see Step 6h's own comment) =="
  if never_called.empty?
    warn '  (none)'
  else
    never_called.each { |m| warn "  #{m[:owner]}##{m[:name]}" }
  end
end
