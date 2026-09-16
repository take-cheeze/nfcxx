#!/usr/bin/env ruby
# frozen_string_literal: true

# A small mruby bytecode -> C++ AOT compiler (docs/adr/0139).
#
# Scope (deliberately narrow -- see README.md in this directory): compiles
# only "leaf" method-body IREPs (real executable Ruby method bodies), for a
# small, hand-picked subset of mruby's opcode set -- ENTER, MOVE, LOADNIL,
# LOADI/LOADI_n/LOADI8/16/32, STRING, STRCAT, GETIV, SETIV, ADD/ADDI,
# SEND0/SEND/SSEND0/SSEND, RETURN/RETFALSE/RETTRUE, JMP/JMPNOT/JMPIF,
# GETCONST/GETMCNST. It does NOT compile top-level script bodies or
# class-body (TDEF-only) IREPs -- those stay on the normal
# bytecode-interpreted path (mrb_load_irep), which still defines the classes
# and installs the compiled method bodies in their place via
# mrb_define_method. Any method using an opcode or argument shape outside
# this subset (optional/rest/keyword/block params, an unhandled opcode) is
# left uncompiled -- a loud `#error` marker in the generated source, never a
# silently wrong translation -- and keeps running on the interpreter.
#
# The real point of this prototype: a whole-program (closed-world) analysis
# that finds every method name defined by EXACTLY ONE class anywhere in the
# program. Every call site using such a name is provably monomorphic --
# Ruby's method resolution can only ever find that one implementation, no
# matter what the receiver's actual runtime class turns out to be -- so it
# compiles to a direct C++ function call, skipping mrb_funcall's real
# hash-based method-table lookup entirely. A call site whose method name has
# more than one definition (a genuinely overridden/polymorphic method, e.g.
# Dog#speak vs Cat#speak vs Animal#speak) keeps real dynamic dispatch
# (mrb_funcall), the same way a real Ruby program has to.
#
# Data source: this reads mrbc's own two debug output modes on the exact
# same input -- `-v` (a human-readable disassembly: real opcode mnemonics,
# resolved register/symbol operands, sequenced in DFS pre-order) and `-B -S`
# (a C dump of the literal mrb_irep structs: exact pool/symbol/local-name
# arrays and exact parent->child `reps` pointers, in C declaration order,
# which is bottom-up/post-order). Neither one alone is enough: the
# disassembly doesn't expose the reps[] parent/child structure explicitly
# (TDEF/EXEC's `I[k]` operand is only meaningful once you know what a given
# irep's own reps[] array contains), and the C dump doesn't spell out
# opcodes as mnemonics (re-decoding raw iseq bytes would mean re-implementing
# mruby's own opcode table). So: walk the C dump's reps[] pointers from the
# root irep to reconstruct the exact tree and its own DFS pre-order
# (verified to match the disassembly's own block order exactly), then zip
# that order against the disassembly's sequence of per-irep blocks. This is
# a legitimate, complete read of the real compiled bytecode -- not a
# lossy approximation -- just split across mrbc's own two debug dumps
# instead of a single hand-rolled binary .mrb parser (a real next step,
# not attempted here; see README.md).

require 'shellwords'
require 'set'

# Callers that need this closed-world analysis to see a whole game's worth
# of mrblib (not just the class being compiled -- see build_registry's own
# comment on why a call site's MONO/POLY resolution needs every gem that
# could define the same method name) always pass MRBC explicitly (e.g.
# mruby-lcf-compiled/mrbgem.rake passes `spec.build.mrbcfile`, the exact
# host mrbc the surrounding cross-build already produced). No bundled
# default path: which mrbc is correct depends entirely on which build
# (host/wio/desktop/...) is invoking this script.
MRBC = ENV['MRBC'] || 'mrbc'

Irep = Struct.new(:label, :nlocals, :nregs, :pool, :syms, :reps, :lv, :instructions, :file,
                   :catch_handlers, keyword_init: true)
Insn = Struct.new(:lineno, :addr, :op, :args, :raw, keyword_init: true)
# One entry of an irep's own real catch handler table (3rd/mruby/include/
# mruby/irep.h's own `struct mrb_irep_catch_handler`) -- mrbc's `-v`
# disassembly prints one "catch type: TYPE   begin: NNNN end: NNNN
# target: NNNN" header line per real `begin...rescue...end`/`ensure`
# construct, right before that irep's own instruction listing (see
# parse_disasm_blocks). `type` is "rescue" or "ensure" (mrb_catch_type,
# same header); begin/end/target are the exact same byte addresses this
# file's own Insn#addr already uses everywhere else.
CatchHandler = Struct.new(:type, :begin_addr, :end_addr, :target, keyword_init: true)
# `kind`: nil for an ordinary bytecode `def` (a real irep) and for every
# pre-existing synthetic (irep: nil) MethodDef this file already
# registered before this field existed -- monomorphic_target/the ordinary
# TYPED path already treat any irep-nil def as "native, no compiled body
# to call", regardless of `kind`, so leaving every one of those at the
# default `nil` changes nothing about their existing behavior. Only ever
# set to a real, specific value at the one call site that can actually
# prove what a synthetic entry's real native body does -- today just
# `:ivar_accessor` (build_registry's own attr_reader/attr_writer/
# attr_accessor case below), consumed by IVAR_ACCESSOR_DEVIRT's own
# compile_send branch to know it's safe to inline a bare mrb_iv_get/
# mrb_iv_set rather than only ever falling back to mrb_funcall. Every
# OTHER synthetic MethodDef in this file (Struct.new's own positional
# members -- storage completely unrelated to iv_tbl, see that call site's
# own comment; a `module_function`-installed singleton-class copy of an
# existing instance method's own body; a NATIVE_SRCS-derived name with no
# known real implementation at all) deliberately stays untagged: none of
# those are safe to assume "reads/writes @name via the ordinary iv_tbl"
# the way a real attr_reader/writer/accessor is, and getting this wrong
# would be a silent wrong-value bug, not just a missed optimization the
# way every other gap in this file safely degrades to.
MethodDef = Struct.new(:name, :owner, :irep, :visibility, :kind, keyword_init: true)

# ---------------------------------------------------------------------------
# Step 1: run mrbc's two debug dumps on the same input(s). mrbc accepts
# multiple source files on one command line and compiles them as one
# program (sequential top-level statements, real class reopening across
# files) -- exactly what's needed to analyze a whole gem's mrblib as one
# closed world instead of one file at a time.
# ---------------------------------------------------------------------------
def run_mrbc(src_paths, symbol, out_dir)
  src_paths = Array(src_paths)
  c_dump = File.join(out_dir, "#{symbol}_dump.c")
  disasm_txt = File.join(out_dir, "#{symbol}_disasm.txt")

  system(MRBC, '-B', symbol, '-S', '-o', c_dump, *src_paths, exception: true)
  # Real game source has non-ASCII (Japanese) comments/string literals --
  # force UTF-8 rather than trusting IO.popen's locale-dependent default,
  # which chokes on them.
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

  # Pool arrays: static const mrb_irep_pool SYM_pool_N[k] = { {tag, {...}}, ... }.
  # Entries aren't always strings -- {IREP_TT_SSTR|(len<<2), {"str"}} for a
  # string literal, but {IREP_TT_FLOAT, {.f=1.5}} / {IREP_TT_INT64,
  # {.i64=...}} / etc. for a numeric literal too big for LOADI's own
  # immediate operand. Codegen here never reads a non-string entry (no
  # opcode in this prototype's subset consumes one), but every entry still
  # has to be counted in order regardless of type, or a later STRING
  # instruction's own L[k] index silently points at the wrong pool slot --
  # a real bug an earlier, strings-only version of this scan had, caught by
  # running against real game source with mixed-type pools (this toy
  # example's own pools happen to be all-string, so it never surfaced).
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
  # Parallel to `blocks` -- each irep block's own `file: path/to/x.rb`
  # line (mrbc echoes back exactly the path it was given on the command
  # line), needed by Annotations.extract to find a magic comment's real
  # source line. Kept separate from Insn/Irep's existing per-instruction
  # `lineno` (already real, 1-indexed source line numbers within that
  # file) rather than repeating it on every instruction.
  block_files = []
  # Parallel to `blocks` too -- every "catch type: ..." header line seen
  # before that block's own instruction listing starts (zero or more; a
  # real irep can have several independent rescue/ensure constructs, or
  # none). See CatchHandler's own comment for what these three addresses
  # mean; RESCUE_SUPPORT (compile_method) is the only real consumer.
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

# ---------------------------------------------------------------------------
# Step 6: whole-program class/method registry, walking the tree from the
# root: CLASS/EXEC pairs define classes and recurse into their class-body
# irep; TDEF (anywhere) defines one method, owned by the innermost class
# being walked (or "Object" for a top-level TDEF).
# ---------------------------------------------------------------------------
def build_registry(ireps, root_label)
  registry = Hash.new { |h, k| h[k] = [] }
  # SUPER_SUPPORT: real class name -> its own real declared superclass
  # name (a String), :none (no explicit superclass written -- real Ruby
  # default is Object, and OP_SUPER's own real semantics, vm.c, start the
  # method search one level above the CURRENT class either way, so :none
  # is a real, useful fact, not just "unknown"), or simply absent from
  # this Hash (a computed/unrecognized superclass expression -- see
  # resolve_superclass_ref's own comment; never guessed). MODULE has no
  # superclass at all, so only ever populated from a real CLASS opcode.
  superclass_of = {}
  # CONST_CONTAINER_SUPPORT: real, fully-qualified constant name (e.g.
  # "Game::Vehicle::TYPES") -> 'Array'/'Hash'/'Range' when every real
  # SETCONST site for that exact name (there is almost always exactly
  # one -- reassigning a Ruby constant is rare, and this table poisons to
  # nil rather than guess if it ever happens) writes a proven
  # literal_container_class value. nil-poisoned entries are removed
  # before this method returns (see the .compact below), so a caller
  # only ever sees a real class name or a missing key -- never a raw nil
  # poison sentinel leaking out. No separate .known/.unknowns split
  # needed the way ClassLayout's own UNKNOWN-poisoning table needs:
  # there is no multi-pass fixed point here -- a constant's own literal
  # shape is a pure one-shot syntactic fact, never dependent on another
  # constant already being resolved, unlike an ivar's class hint.
  container_constants = {}

  walk = lambda do |label, namespace|
    irep = ireps.fetch(label)
    # Track which register currently holds "the class/module/singleton-class
    # most recently opened by CLASS/MODULE/SCLASS", so a same-register EXEC
    # right after it can be matched up -- exactly the shape mrbc's own
    # codegen emits for every `class X ... end` / `module X ... end` /
    # `class << X ... end`. pending_idx additionally pins the *exact*
    # instruction index the matching EXEC has to land on (idx immediately
    # after the CLASS/MODULE/SCLASS that set it) -- not just "whatever
    # comes along later on this register" -- to close a real, confirmed-live
    # bug: an empty `class`/`module` body (e.g. `class Timeout <
    # StandardError; end`, mruby-rgss/mrblib/lib.rb) emits no EXEC at all
    # for its own (empty) body, since mrbc doesn't bother emitting a
    # trivial always-empty child-irep call in that case. Before pending_idx
    # existed, that left pending_reg/pending_name sitting stale until
    # *whatever* later EXEC happened to reuse the same register -- possibly
    # many instructions and several unrelated constructs away -- which then
    # got wrongly treated as that empty class/module's own body. Confirmed
    # live against the real generated registry: RGSS::Timeout (empty) is
    # immediately followed by `class << self; attr_accessor
    # :asset_archive; end` reusing the very same register for its own
    # SCLASS+EXEC, so RGSS.asset_archive/asset_archive= were registered
    # under owner "RGSS::Timeout" instead of the real receiver. Real mrbc
    # codegen (verified directly against every CLASS/MODULE/SCLASS+EXEC
    # pair in this closed world's own disassembly) always emits the
    # matching EXEC as the *literal next instruction* -- nothing legitimate
    # is ever emitted in between -- so requiring exact index adjacency
    # matches every real, intended pairing while making a stale leak
    # structurally impossible, however far away the next same-register EXEC
    # actually is.
    pending_reg = nil
    pending_name = nil
    pending_idx = nil
    # Ruby's own `private`/`protected`/`public` visibility tracking, scoped
    # to this one class/module body (resets on every fresh `walk` call, the
    # same way a real visibility section never crosses a `class`/`module`
    # boundary). Two real, distinct forms, both plain self-implicit sends
    # to Kernel#private/#protected/#public (SSEND0/SSEND, register args
    # "R1\t:private"): a bare call (n=0) is a *mode switch* -- every `def`
    # from here to the end of this body defaults to that visibility; a call
    # with Symbol arguments (n>=1, e.g. `private :step, :finish_move`)
    # retroactively marks those *already-defined* methods, without
    # changing the mode for whatever comes after. Caught building the first
    # real second target (Game::Picture, docs/adr/0139's own follow-up):
    # #step/#finish_move are both private in the real interpreted source
    # (a bare `private` right before them) -- bc2cpp itself doesn't care
    # (a private method can only ever be legitimately reached via a
    # self-implicit call, which stays correct either way), but a hand-
    # written mrb_define_method registration that doesn't know this would
    # silently make a private method callable from outside, a real
    # observable behavior change never caught by any #error check.
    default_visibility = :public

    # Shared by the SCLASS-opened-body case below and the unfused
    # TCLASS/SCLASS+METHOD+DEF DEF case further down: resolve a
    # singleton receiver's own name by walking backward from
    # `before_idx` to `reg`'s own last write. Only two shapes are
    # trusted (mirrors trace_new_target's/the Struct.new fix's own
    # "only a real, statically-certain fact counts" discipline): a bare
    # LOADSELF (`self`, always the innermost enclosing namespace at this
    # point) or a GETCONST naming a specific constant (`SomeConst`).
    # Anything else (a computed or otherwise-aliased receiver) is simply
    # not recognized -- always safe, just a missed case, exactly like
    # every other backward-scan guard in this file.
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

    # Shared by the TDEF case below and the unfused TCLASS+METHOD+DEF
    # branch of the new DEF case further down -- both register an
    # ordinary instance method the same way, so both need the exact
    # same builtin-private-name special case (see the TDEF case's own
    # comment for why #initialize/#initialize_copy/#respond_to_missing?
    # can never simply follow default_visibility).
    resolve_def_visibility = lambda do |method_name|
      %w[initialize initialize_copy
         respond_to_missing?].include?(method_name) ? :private : default_visibility
    end

    # Real mrbc disassembly can interpose an OP_EXT1/EXT2/EXT3 pseudo-
    # instruction (src/codedump.c: each widens the *immediately
    # following* real instruction's own operand width, printed as its
    # own numbered disassembly line with no args of its own -- e.g.
    # "10884 5571 EXT2" then "10884 5572 METHOD R2 I[379]") between two
    # instructions codegen.c emits back-to-back with no logical gap.
    # Every other adjacency-based backward scan in this file has gotten
    # away with a plain idx-1/idx-2 check so far only because none of
    # their own real, closed-world instances happened to need one -- but
    # the unfused TCLASS/SCLASS+METHOD+DEF DEF case below can't: its own
    # METHOD operand is a child-irep index guaranteed > 0xff (that's
    # exactly why this path was taken instead of TDEF/SDEF), which
    # always needs one of these before it, confirmed directly in the
    # real RPG2k::Scene::Map disassembly this fix targets. skip_ext_back
    # walks back past any number of EXT1/EXT2/EXT3 entries and returns
    # the index of the first real opcode underneath (-1 if it runs off
    # the start of this block).
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
        # Real Ruby constant nesting (Game::CharSet, not just "CharSet") --
        # matters so two same-named classes nested under different
        # modules aren't conflated into one registry entry.
        pending_name = namespace ? "#{namespace}::#{name.sub(/^:/, '')}" : name.sub(/^:/, '')
        # SUPER_SUPPORT: OP_CLASS's own real shape (3rd/mruby/include/
        # mruby/ops.h: `R[a] = newclass(R[a], Syms[b], R[a+1])`, vm.c's
        # own CASE(OP_CLASS)) puts the real superclass value in the very
        # next register -- whatever wrote it is always the instruction
        # immediately preceding this one in program order (real Ruby
        # evaluates `class X < SUPER_EXPR`'s own SUPER_EXPR right before
        # opening the class), so resolve_superclass_ref's own backward
        # walk starts here, at this CLASS instruction's own index.
        if insn.op == 'CLASS'
          superclass_reg = (reg[/\d+/].to_i + 1).to_s
          resolved = resolve_superclass_ref(irep, idx, superclass_reg, namespace)
          superclass_of[pending_name] = resolved if resolved
        end
      when 'SCLASS'
        # "SCLASS R1" -- OP_SCLASS's own real shape (src/codedump.c:
        # `SCLASS\tR%d`), R[a] = R[a].singleton_class. A real `class <<
        # self ... end` (or `class << SomeConst ... end`) opens the
        # receiver's own singleton class as a body of its own, containing
        # ordinary TDEFs -- exactly like CLASS/MODULE's own child body,
        # just reached via this distinct opcode and with no symbol operand
        # naming it directly (the name comes from the receiver register's
        # own last write instead, walked backward the same cautious way
        # the Struct.new fix already does for its own receiver check).
        # Previously invisible to this walk entirely: nothing recursed into
        # an SCLASS-opened body the way EXEC already does for a
        # CLASS/MODULE-opened one, so every real `def` inside one (e.g.
        # RGSS::Bitmap's own `class << self; attr_writer :extensions; def
        # extensions; @extensions || EXTENSIONS; end; end`) was completely
        # unregistered -- confirmed directly against the real registry
        # dump (:extensions had zero entries, not even a synthetic one).
        # Unlike SDEF's own single fused def (irep: nil is enough there --
        # there is no separate body to recurse into), an SCLASS body can
        # hold arbitrarily many real defs (RGSS::Audio's own class << self
        # alone defines over twenty), so real soundness needs the same
        # genuine recursion CLASS/MODULE already gets, registering each
        # inner TDEF as an ordinary, walkable MethodDef with a real irep --
        # reusing the exact same EXEC-matching code below rather than a
        # bespoke synthetic-only path.
        #
        # Only two receiver shapes are trusted, both walked backward from
        # this SCLASS to the register's own last write (mirrors
        # trace_new_target's/the Struct.new fix's own "only a real,
        # statically-certain fact counts" discipline): a bare LOADSELF
        # (`class << self`, self at this point is always the innermost
        # enclosing namespace -- the same fact SDEF's own fix already
        # relies on) or a GETCONST naming a specific constant (`class <<
        # SomeConst`, e.g. `class << Graphics`, seen for real in this
        # closed world but only ever nested inside an ordinary runtime
        # method body that this walk never descends into anyway). Anything
        # else (a computed or otherwise-aliased receiver) is simply not
        # recognized -- always safe, just a missed case, exactly like every
        # other backward-scan guard in this file. resolve_singleton_receiver
        # (defined once, above) is reused as-is by the unfused
        # TCLASS/SCLASS+METHOD+DEF DEF case further down -- same receiver
        # shape, same guard, no separate copy.
        reg = insn.args[/^(R\d+)/, 1]
        recv = resolve_singleton_receiver.call(reg, idx)
        pending_reg = reg
        pending_idx = idx
        # A distinct pseudo-owner ("X.singleton", the same suffix SDEF's own
        # fix already uses) -- never a real Ruby constant path, so it can
        # never collide with (or be selected by) ONLY_OWNERS, which only
        # ever names real classes/modules. nil (unrecognized receiver)
        # leaves pending_name nil, so the EXEC case below's own `&&
        # pending_name` guard correctly never recurses into it.
        pending_name = recv ? "#{recv}.singleton" : nil
      when 'SETCONST'
        # CONST_CONTAINER_SUPPORT: "SETCONST NAME Rsrc" -- the real shape
        # a top-level `CONST = ...` assignment (module/class-body scope,
        # `namespace` is exactly this body's own real lexical nesting at
        # this point in the walk, confirmed by CLASS/MODULE's own case
        # above) compiles to. `literal_container_class` recognizes only
        # the specific literal-then-optional-freeze shape this codebase's
        # own constants overwhelmingly use; anything else (a computed
        # expression, a method call whose return isn't a bare literal)
        # is a safe miss (nil), same as everywhere else in this file.
        const_name = insn.args[/^(\S+)/, 1]
        src_reg = insn.args[/R(\d+)/, 1]
        qualified = namespace ? "#{namespace}::#{const_name}" : const_name
        klass = literal_container_class(irep, idx, src_reg)
        # Two real SETCONST sites for the exact same qualified name
        # disagreeing (or either being unresolvable) permanently poisons
        # it to nil -- never guess which one is right, the identical
        # "one bad site poisons the whole name" discipline ClassLayout/
        # IvarLayout already use, just without needing their own fixed-
        # point re-sweep (see this table's own top comment for why).
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
        # #initialize/#initialize_copy/#respond_to_missing? are always
        # private, unconditionally -- not a convention, an actual special
        # case the real interpreter enforces at `def`-definition time
        # itself (3rd/mruby/src/class.c's own define_method_vm-family
        # code: `if (mid == MRB_SYM(initialize) || ... ) MRB_SET_
        # VISIBILITY_FLAGS(flags, MRB_METHOD_PRIVATE_FL);`, unconditional,
        # regardless of whatever `private`/`public` mode is currently in
        # effect). default_visibility only tracks an explicit self-send
        # (see the SEND0/SEND/SSEND0/SSEND case below) -- it has no way to
        # see this builtin rule on its own, so a real `def initialize`
        # with no preceding `private` call would otherwise be reported
        # (and, worse, registered by a hand-written register.cxx via
        # plain mrb_define_method) as public -- a real, observable
        # behavior change, same shape as this file's own Game::Picture#
        # step/#finish_move finding, just never hit until a compiled
        # target's own method set happened to include one of these names.
        # resolve_def_visibility (defined once, above) is reused as-is by
        # the unfused TCLASS+METHOD+DEF branch of the DEF case further
        # down -- same builtin-private-name special case, no separate copy.
        visibility = resolve_def_visibility.call(method_name)
        registry[method_name] << MethodDef.new(name: method_name, owner: owner, irep: child_label,
                                                visibility: visibility)
      when 'SDEF'
        # "SDEF R1 :clamp I[5]" -- OP_SDEF's own real shape (src/codedump.c:
        # `SDEF\t\tR%d\t:%s\tI[%d]\n`, identical layout to TDEF's own, just a
        # different opcode). `def self.foo` (or `def SomeConst.foo`) never
        # compiles to TDEF at all -- codegen_sdef (mrbgems/mruby-compiler/
        # core/codegen.c) fuses SCLASS+METHOD+DEF into this one opcode
        # whenever the child irep's own index fits a byte (always true in
        # practice: the index is scoped to *this* class/module body's own
        # child-irep list, never the whole program's, so no real class body
        # here comes close to the 256 needed to miss the fusion), installing
        # Irep[c] onto R[a]'s *singleton* class -- a real, separate method
        # table from TDEF's own target_class, invisible to this registry
        # before this case existed. build_registry's TDEF-only walk had no
        # way to see any `def self.x` method at all -- a real, live gap,
        # same "invisible to the bytecode-only registry" shape as the
        # already-fixed attr_reader/Struct.new findings, just a third,
        # distinct mechanism (a real bytecode opcode this walk never
        # switched on, not a native method or a Struct.new-installed one).
        #
        # Confirmed LIVE, not hypothetical, in already-shipped, already-
        # compiled code: `RPG2k::Scene::MapViewer#clamp(v, lo, hi)` (a
        # private 3-arg helper) was the *only* bytecode-visible `:clamp`
        # definition anywhere in the whole program before this fix --
        # `Game.clamp(v, lo, hi)` (mruby-rpg2k/mrblib/game.rb, `def
        # self.clamp`) is real, used at dozens of already-compiled call
        # sites across Game::Actor/Screen/Party/Battle/Transition/etc. --
        # so every one of those compiled to a direct call straight into
        # `RPG2k__Scene__MapViewer_clamp_impl`, passing the `Game` module
        # object itself as `self`. Not a crash *today* only because both
        # real `#clamp` bodies happen to be pure functions of their three
        # arguments that never touch `self` (confirmed directly against the
        # generated `rpg2k_compiled_gen.cpp`: `RPG2k__Scene__MapViewer_
        # clamp_impl`'s own `self` parameter is copied into `r0` and never
        # read again) -- a real, live devirtualization-soundness violation
        # all the same, one call away from wrong behavior the moment either
        # side's body changes, or the next `def self.x`/instance-method
        # name collision isn't this lucky (e.g. `Game::Interpreter#
        # trans_to_opacity`, itself only `Game.trans_to_opacity(top_trans)`,
        # would have compiled to a literal unconditional self-call --
        # infinite recursion -- had `Game::Interpreter` ever joined
        # ONLY_OWNERS; caught here only because it hasn't yet).
        #
        # Fixed the same way the attr_reader/native-method gaps already
        # are: register a MethodDef under the same "Owner.singleton"
        # pseudo-owner suffix so a real bytecode instance-method definition
        # of the same bare name elsewhere correctly counts this as a second
        # definition and flips MONO to POLY, never silently staying MONO --
        # necessary for MONO/POLY soundness regardless of what happens
        # below. This can only ever turn an unsound MONO into a correctly
        # cautious POLY, never remove a genuinely sound one, the same
        # guarantee every other synthetic-MethodDef fix in this file
        # already carries.
        #
        # Follow-up (docs/adr/0139): `irep:` here used to be hardcoded
        # `nil` unconditionally, on the theory that "there is no separate
        # body to recurse into" for this fused opcode -- true for the
        # *registry walk* (unlike SCLASS, nothing here needs recursing
        # into), but wrong about the irep itself: I[c] (captured below as
        # `irep_ref`, previously read and immediately discarded as
        # `_irep_ref`) names a real child irep index, scoped to this class/
        # module body's own child-irep list exactly the way TDEF's own I[c]
        # is (see the TDEF case above) -- mrbc genuinely compiled a real
        # body into it, identical in kind to any TDEF/SCLASS-opened body's
        # own child irep, just reached through a fused instruction instead
        # of an unfused one. Discarding it meant a `def self.x` method was
        # not merely left uncompiled the way an arity/opcode gap leaves a
        # method uncompiled (those still produce a #error-marked stub
        # `compile_method` actually attempted) -- with irep: nil,
        # `@owner_of[d.irep] = d if d.irep` (this file's own leaf-worklist
        # builder) never inserted an entry for it at all, so it was
        # invisible to `compile_all` regardless of ONLY_OWNERS, structurally
        # incapable of ever becoming a compile target (confirmed live on
        # RGSS::Bitmap.failure_reason, docs/adr/0139's own follow-up).
        #
        # Resolving `irep_ref` into a real `child_label` here, the exact
        # same way TDEF resolves its own I[c] operand two cases up, closes
        # that gap: this MethodDef now behaves exactly like the unfused
        # `TCLASS/SCLASS+METHOD+DEF` DEF case's own singleton branch further
        # down (`recv`/`"#{recv}.singleton"`/`irep: child_label`) already
        # does for the same shape reached via a different, unfused
        # instruction sequence -- the two singleton-method registration
        # paths in this file are now consistent with each other. A real
        # irep here can only ever ADD emission eligibility (via
        # `compile_all`'s `only_owners` filter actually naming this
        # `"X.singleton"` pseudo-owner, see compiled_gems.rb) -- it changes
        # nothing about MONO/POLY resolution itself (still exactly one
        # MethodDef registered under this owner+name, same as before) and
        # nothing about ordinary dynamic dispatch for every call site that
        # doesn't devirtualize into it.
        #
        # Checked every other place in this file that reads `d.irep`/
        # `d.irep.nil?` for an implicit "synthetic/native, no real body"
        # assumption, in case any of them silently depended on every
        # `.singleton`-owned MethodDef being irep-less: `natively_exposed?`
        # (`d.owner == owner && d.irep.nil?`) is the one real such check,
        # used only by `drop_unsafe_embeddings` to keep an *instance* ivar
        # off the embedded struct when some native accessor already exposes
        # it under that ivar's own owning class -- `owner` there always
        # comes from `ivar_layout`'s own keys, themselves always a real
        # instance-class owner (`#initialize`'s own class), never a
        # `.singleton`-suffixed string, so a `.singleton`-owned MethodDef's
        # `d.owner` can never equal it regardless of its own `irep`
        # nil-ness -- unaffected. Every other `d.irep`/`.irep.nil?` site
        # (`monomorphic_target`, `compile_all`'s leaf worklist, embedding's
        # own `#initialize`-compiles-clean gate, `compiles_clean?`) already
        # treats "has a real irep" as "is a real, potentially-compilable
        # leaf" -- exactly the correct treatment for a real SDEF-captured
        # body too, not a special case needing its own guard.
        #
        # Round 41 follow-up: this case used to hardcode owner as
        # `"#{namespace || 'Object'}.singleton"` unconditionally, on the
        # unstated assumption that SDEF's own receiver is always `self`. It
        # isn't, structurally: codegen_sdef (mrbgems/mruby-compiler/core/
        # codegen.c) runs `codegen(s, recv, VAL)` for SDEF's own receiver
        # node -- an arbitrary expression, not just `self` -- onto the exact
        # register OP_SDEF's own `a` operand later names, and the real VM
        # (src/vm.c's OP_SDEF case) takes the singleton class of *whatever
        # value that register holds at runtime* (`mrb_singleton_class(mrb,
        # regs[a])`), just like OP_SCLASS does. This file's own top comment
        # for this very case already says so in words ("def self.foo (or def
        # SomeConst.foo)"), and the unfused sibling shape (TCLASS/SCLASS+
        # METHOD+DEF, the DEF case below) and the SCLASS-opened-body case
        # above both correctly resolve their own receiver via
        # resolve_singleton_receiver instead of assuming `self` -- this SDEF
        # case was the one place in the file that still assumed it. Blindly
        # trusting `namespace` for a real `def SomeConst.foo` that fuses to
        # SDEF (reachable exactly like today's own `def self.foo` SDEF
        # targets, whenever the child irep index still fits a byte) would
        # register the method under the WRONG owner -- the enclosing
        # namespace's own singleton, not SomeConst's -- a real
        # devirtualization-soundness violation of the same shape this SDEF
        # case's own comment already documents SDEF closing (the `Game.
        # clamp`-vs-`RPG2k::Scene::MapViewer#clamp` collision) if `SomeConst`
        # and the enclosing namespace ever collide by name elsewhere. Not
        # currently exploitable (confirmed: no `def SomeConst.foo` shape --
        # only `def self.foo` -- appears anywhere in this project's own real
        # `.rb` sources today, grepped directly), but the same "close it
        # regardless, it's real and general" discipline every other
        # SDEF/SCLASS/DEF fix in this file already follows. Reusing
        # resolve_singleton_receiver (defined once, above) here is exactly
        # behavior-preserving for every real target today: a `def self.foo`
        # always resolves via its own LOADSELF, to the identical
        # `namespace || 'Object'` this case already computed by hand: the
        # receiver's own codegen (`codegen(s, recv, VAL)` then `pop()`,
        # codegen_sdef above) writes LOADSELF/GETCONST into the exact same
        # register OP_SDEF's own `a` operand later names, with only
        # EXT1/EXT2/EXT3 pseudo-instructions possibly interposed --
        # resolve_singleton_receiver's own backward scan already tolerates
        # those (an EXT line's `args` carries no `R\d+` prefix of its own, so
        # the `next unless pd == reg` guard skips straight past it). An
        # unrecognized receiver (anything besides LOADSELF/GETCONST) now
        # simply isn't registered at all -- always safe, the same "missed
        # case, never a wrong one" guarantee every other backward-scan guard
        # in this file already carries -- rather than silently mis-attributed
        # to `namespace`.
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
        # "DEF R1 :toned? (R2)" -- OP_DEF's own real shape (src/codedump.c:
        # `DEF\t\tR%d\t:%s\t(R%d)\n`). codegen_def/codegen_sdef
        # (mrbgems/mruby-compiler/core/codegen.c) only fuse
        # TCLASS+METHOD+DEF / SCLASS+METHOD+DEF into the single TDEF/SDEF
        # opcode the two cases above already recognize when the def's own
        # child-irep index fits a byte (idx <= 0xff); once a class/module
        # body's own child-irep count exceeds 255, both fall back to this
        # literal, unfused three-opcode sequence instead -- invisible to a
        # walk that (before this case existed) only ever switched on
        # TDEF/SDEF. Confirmed real, not hypothetical, in already-shipped
        # source: RPG2k::Scene::Map (mruby-rpg2k/mrblib/scene/map.rb) is
        # large enough that both `def toned?` and `def self.tone_channel`
        # land past the fusion threshold -- real `mrbc -v` disassembly
        # confirmed directly:
        #   TCLASS  R1
        #   EXT2
        #   METHOD  R2      I[380]
        #   EXT2
        #   DEF     R1      :toned?   (R2)
        # and, for the SCLASS (`def self.x`) shape:
        #   LOADSELF R1     (R0)
        #   SCLASS   R1
        #   EXT2
        #   METHOD   R2     I[379]
        #   EXT2
        #   DEF      R1     :tone_channel  (R2)
        # (`RPG2k::Scene::Map` is not currently a compiled owner, so this
        # was NOT exploitable at the time it was found -- but the gap is
        # real and general, not specific to this one class, so it's
        # closed here rather than left for whenever that changes.)
        #
        # skip_ext_back (defined once, above) walks back past the real
        # EXT1/EXT2/EXT3 pseudo-instructions mrbc's own disassembler
        # interposes here (widening METHOD's own I[idx] operand, always
        # > 0xff by construction of reaching this unfused path at all,
        # and, in this real class's own large symbol pool, DEF's own
        # symbol-table operand too) before checking the real opcode
        # underneath -- a plain idx-1/idx-2 check would miss this real
        # shape entirely.
        reg, name, recv_arg = insn.args.split(/\s+/, 3)
        method_idx = skip_ext_back.call(idx - 1)
        method_insn = method_idx >= 0 ? irep.instructions[method_idx] : nil
        next unless method_insn && method_insn.op == 'METHOD'

        method_reg, irep_ref = method_insn.args.split(/\s+/, 2)
        # Registers must line up exactly the way codegen_def's/
        # codegen_sdef's own unfused branch always emits them (opener at
        # R<n>, METHOD at R<n+1>, DEF back at R<n> referencing (R<n+1>))
        # -- never trusted by adjacency alone, the same "only a real,
        # statically-certain fact counts" discipline every other
        # backward-scan guard in this file already follows.
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
          # Ordinary instance method (`def foo`'s own unfused shape) --
          # registered exactly the way the TDEF case above registers a
          # fused `def`, just reached via this three-opcode sequence
          # instead. A real, walkable MethodDef (a genuine irep, not a
          # synthetic placeholder): this owner's normal instance method
          # table, exactly as compilable as any TDEF-registered method
          # should this class ever join a future round's ONLY_OWNERS.
          owner = namespace || 'Object' # a top-level `def` lands on Object.
          visibility = resolve_def_visibility.call(def_name)
          registry[def_name] << MethodDef.new(name: def_name, owner: owner, irep: child_label,
                                               visibility: visibility)
        else
          # `def self.foo` (or `def SomeConst.foo`)'s own unfused shape --
          # the same "X.singleton" pseudo-owner the SDEF case above uses,
          # registered the same way: an ordinary walkable MethodDef with a
          # real child irep (this branch has always done this; the SDEF
          # case's own follow-up, docs/adr/0139, later brought its fused
          # sibling in line with this same "real irep" treatment, having
          # started out wrongly discarding its own I[c] operand as
          # irep: nil). Receiver resolved by the exact same cautious
          # backward scan the SCLASS-opened-body case above already uses
          # (resolve_singleton_receiver) -- an unrecognized receiver just
          # isn't registered at all, always safe, same as every other
          # backward-scan guard in this file. Visibility unconditionally
          # :public, matching the SDEF case's own entries -- this file
          # doesn't model `private_class_method`/singleton-method privacy
          # at all, consistently, for either the fused or unfused shape.
          recv = resolve_singleton_receiver.call(opener_reg, opener_idx)
          if recv
            owner = "#{recv}.singleton"
            registry[def_name] << MethodDef.new(name: def_name, owner: owner, irep: child_label,
                                                 visibility: :public)
          end
        end
      when 'SEND0', 'SEND', 'SSEND0', 'SSEND'
        # Same charset as compile_send's own name extraction below (see its
        # own comment for the real bug this fixes) -- kept in sync here too,
        # even though :private/:protected/:public never collide with an
        # operator name, so a future reader never has to wonder why the two
        # differ.
        name = insn.args[/:([\w+\-*\/<>=!?\[\]&|^~%@]+)/, 1]
        next unless %w[private protected public attr_reader attr_writer attr_accessor
                       module_function].include?(name)

        n = insn.args[/n=(\d+)/, 1].to_i
        # `private :a, :b, ...` / `attr_reader :a, :b, ...` -- the n Symbol
        # arguments are LOADSYM'd into consecutive registers immediately
        # before this send (real code always emits them right before, no
        # interleaving instructions of any other kind); walk backward
        # collecting them. Shared by both branches below.
        collect_loadsym_names = lambda do
          names = []
          (idx - 1).downto(0) do |i|
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
          # `module_function :a, :b, ...` -- a fourth, distinct "invisible to
          # a plain TDEF/DEF bytecode walk" installation mechanism, alongside
          # attr_reader/writer/accessor and Struct.new above and SDEF/SCLASS
          # elsewhere in this file: a bare SEND (like attr_reader), not a
          # dedicated opcode. Real, live use in this closed world: mruby-lcf/
          # mrblib/lcf.rb's own `module_function :read_ber, :write_ber,
          # :to_rb, ..., :elements_of` (16 names) and `module_function
          # :var_max, :var_min, ..., :exp_default` (6 names), both the
          # retroactive (n >= 1) form only -- the bare mode-switch form
          # (n.zero?, which would need to start tagging every subsequent
          # `def` in this body, not just retroactively mark ones already
          # seen) has zero real occurrences anywhere in the whole closed
          # world (confirmed by grep), so it's simply left unhandled here,
          # same as every other narrow, no-real-instance gap in this file --
          # always safe, just a missed case. The 16-name call site itself
          # hits a real, already-documented, pre-existing limit this same
          # collect_loadsym_names helper shares with attr_reader's own
          # 15-argument Game::Enemy call site (see that finding's own
          # comment, several rounds up): confirmed directly against the real
          # disassembly, 16 Symbol arguments is enough to tip mrbc's own
          # argument-count encoding from a literal `n=16` into the `n=*`
          # CALL_MAXARGS splat sentinel (`SSEND R1 :module_function n=*`,
          # vs. the 6-name call site's own plain `n=6`) -- outside
          # collect_loadsym_names' own `n=(\d+)`-only counting, so this fix
          # silently registers nothing for that one call site's own 16
          # names, the exact same safe-under-approximation shape (never
          # wrongly narrows, just misses a registration) the attr_reader
          # finding already established, not a new gap this fix introduces.
          # Not worth generalizing collect_loadsym_names to the `n=*` shape
          # here either, for the same reason already given there: real,
          # separate work, and neither call site is exploitable today
          # regardless (see the owner-not-emitted check below).
          #
          # Real mruby semantics confirmed by reading 3rd/mruby/src/class.c's
          # own mrb_mod_module_function directly, not assumed from CRuby's
          # (different) behavior: unlike CRuby, mruby's own implementation
          # does NOT make the original instance method private (the "set
          # PRIVATE method visibility if implemented" call right above the
          # real loop is commented-out dead code) -- it only looks up each
          # already-defined instance method and installs a copy of it,
          # marked public, onto the module's own singleton class. So the
          # already-registered instance-level MethodDef (owner `namespace`,
          # whatever visibility it already has) needs no correction here,
          # unlike `private`'s own retroactive-marking case just above --
          # what's missing is a registry entry for the NEW singleton-class
          # copy itself (e.g. `LCF.write_ber`, called from lazy schema
          # defaults and LCF::File#to_lcf), a real, distinct method
          # definition this registry never modeled at all. Registered the
          # same additive-only way as every other synthetic-MethodDef fix in
          # this file: under the distinct "Owner.singleton" pseudo-owner
          # (resolve_singleton_receiver's own suffix, shared with SDEF/
          # SCLASS) -- can never collide with or be selected by ONLY_OWNERS,
          # which only ever names real Ruby constant paths -- with irep: nil
          # (the singleton copy shares the exact same real body as the
          # instance one, but this registry has no representation for "two
          # owners, one shared irep", and irep: nil is always safe regardless
          # of that: it can only ever prevent an unsound direct call into the
          # wrong owner's own _impl, never enable one, the same guarantee
          # every other native/synthetic MethodDef here already carries).
          # Checked live: "LCF" (the bare module, as opposed to LCF::File/
          # Database/MapTree/MapUnit/SaveData/...) is never itself a
          # compiled owner in any of the three real gems (confirmed against
          # BC2CPP_COMPILED_GEMS directly), so compile_send's own
          # owner-not-emitted guard already falls back to ordinary
          # mrb_funcall for every real module_function call site in this
          # closed world today regardless of this fix -- not currently
          # exploitable, but the same class of gap the attr_reader/
          # Struct.new/SDEF/SCLASS fixes above already close for other
          # installation mechanisms, closed here too rather than left open
          # for whichever future round adds a bare module as a compiled
          # owner.
          collect_loadsym_names.call.each do |mname|
            registry[mname] << MethodDef.new(name: mname, owner: "#{namespace || 'Object'}.singleton",
                                              irep: nil, visibility: :public)
          end
        else
          # attr_reader/attr_writer/attr_accessor -- Module#attr_* itself is
          # a native (C-implemented) method, so the getter/setter it defines
          # never gets a TDEF of its own: build_registry's walk has no other
          # way to see these names at all, the exact same "invisible to the
          # bytecode-only registry" gap extract_native_method_names exists
          # to close for mrb_define_method-family call sites -- except here
          # the defined name isn't a fixed literal in any C source; it's
          # whatever Symbol argument *this* call site happens to pass, so no
          # amount of scanning NATIVE_SRCS could ever find it. Before this
          # fix, a name any class attr_reader/writer/accessor's (e.g.
          # `Game::Enemy#crit_chance`) that happens to *also* have exactly
          # one real bytecode `def` elsewhere in the whole program (e.g.
          # `Game::Actor#crit_chance`) looked MONO to monomorphic_target --
          # unsound, since a call site whose receiver is actually the
          # attr_reader-only class would still devirtualize straight into
          # the bytecode class's own _impl. Confirmed LIVE, not
          # hypothetical: `Game::Battle#critical?(b)`'s own real `b.
          # crit_chance` (`b` a battler that can be either a Game::Actor or
          # a Game::Enemy -- the source's own comment says so explicitly,
          # "most enemies... silently desynced") used to compile straight
          # into `Game__Actor_crit_chance_impl`, which calls Actor-only
          # `#weapon_crit_bonus` on `self` -- a real NoMethodError the
          # moment `b` is actually a Game::Enemy (which has no such method),
          # crashing every enemy attack's own crit roll in a build that
          # compiles and links clean with zero warnings. Fixed by
          # registering each attr_reader/writer/accessor name as a
          # synthetic MethodDef here too (irep: nil, same shape
          # extract_native_method_names's own merge already uses for a
          # native method with no bytecode body to devirtualize into) --
          # this can only ever turn an unsound MONO into a correctly
          # cautious POLY, never remove a genuinely sound one, since it
          # only adds an entry for a name that really does have another
          # real definition somewhere in the closed world.
          getter_flag = %w[attr_reader attr_accessor].include?(name)
          setter_flag = %w[attr_writer attr_accessor].include?(name)
          collect_loadsym_names.call.each do |mname|
            owner = namespace || 'Object'
            # kind: :ivar_accessor -- see MethodDef's own comment. Real
            # mruby semantics confirmed directly against 3rd/mruby/src/
            # class.c's own `attr_reader`/`attr_writer` (`mrb_iv_get(mrb,
            # obj, to_sym(mrb, name))` / `mrb_iv_set(mrb, obj, to_sym(mrb,
            # name), val); return val;` -- name here is always the bare
            # `mname` itself, `prepare_ivar_name`'s own real behavior for
            # the reader case and identically for the writer, never a
            # transformed name), consumed by IVAR_ACCESSOR_DEVIRT below.
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
        # `SomeConst = Struct.new(:a, :b, ...) do ... end` -- an explicit-
        # receiver send-with-block, invisible to this walk in TWO distinct
        # ways at once: no CLASS/MODULE opcode ever fires for a Struct.new
        # call (nothing above would recurse into the block's own body at
        # all), and the plain member names themselves are real reader+
        # writer methods Struct.new installs natively (mruby's own
        # struct.c), never a bytecode TDEF either -- the same native-
        # accessor blind spot attr_reader/writer/accessor above closes,
        # just for a different installation mechanism.
        #
        # Real, live instance, not hypothetical, found hunting for exactly
        # this shape of bug: Game::Battle::Combatant (mruby-rpg2k/mrblib/
        # game/battle.rb) is `Struct.new(:name, ..., :crit_chance, ...) do
        # ... def state?(id); (states || []).include?(id); end ... end` --
        # both Combatant#state? (defined inside this block) and the real,
        # ordinary bytecode Game::Actor#state? are real definitions of
        # :state?, but only the latter was ever visible to the registry
        # before this case existed, so it looked MONO. Game::Battle#
        # cure_state's own `target.state?(sid)` (target a real Combatant
        # on every real call site) devirtualized straight into
        # Game__Actor_state__impl(M, target, sid) regardless of target's
        # real class -- that function's own body reads
        # `mrb_iv_get(M, self, "@states")`, which returns nil on a real
        # Struct instance (Struct stores its members positionally, never
        # via iv_tbl), so `nil.include?(sid)` raises a real NoMethodError
        # the moment any state is cured in battle -- a build that compiled
        # and linked clean with zero warnings. Confirmed directly against
        # the real generated output (a real `rake`-driven bc2cpp run),
        # not just reasoned about. Game::Battle#combatant_permanent_states'
        # own `target.actor` (target the same real Combatant) has the
        # identical shape: Combatant's own plain `actor` member reader,
        # invisible the same way, collided with RPG2k::Scene::EquipMenu's
        # own real bytecode `def actor` -- 19 real call sites devirtualized
        # into the wrong class's own compiled body before this fix.
        name = insn.args[/:([\w+\-*\/<>=!?\[\]&|^~%@]+)/, 1]
        next unless name == 'new'

        d = insn.args[/^R(\d+)/, 1]
        # Only trust a bare `Struct.new` -- the receiver register's own
        # last write, walked backward, has to be a plain GETCONST naming
        # it exactly (mirrors trace_new_target's own "only a real,
        # statically-certain fact counts" discipline; a computed or
        # aliased Struct-like receiver just isn't recognized here rather
        # than guessed at -- always safe, just a missed case).
        struct_recv = false
        (idx - 1).downto(0) do |i|
          prev = irep.instructions[i]
          pd = prev.args[/^R(\d+)/, 1]
          next unless pd == d

          struct_recv = prev.op == 'GETCONST' && prev.args[/^R\d+\s+(\S+)/, 1] == 'Struct'
          break
        end
        next unless struct_recv

        # The block operand: the nearest preceding BLOCK instruction (real
        # code always emits it immediately before the SENDB that consumes
        # it, no interleaving instructions of any other kind -- the same
        # adjacency assumption the private/attr_reader LOADSYM scan above
        # already relies on).
        block_insn = irep.instructions[idx - 1]
        next unless block_insn && block_insn.op == 'BLOCK'

        block_idx = block_insn.args[/I\[(\d+)\]/, 1]
        next unless block_idx

        block_label = irep.reps[block_idx.to_i]
        next unless block_label

        # This Struct's own name: a SETCONST right after the SENDB, on the
        # same register, is how `Combatant = Struct.new(...) do ... end`
        # assigns the result -- the same real constant-naming shape
        # CLASS/MODULE already uses elsewhere in this file, just via a
        # plain assignment instead of opening a class body. A Struct.new
        # whose result isn't immediately named this way (passed straight
        # into something else, a genuinely anonymous Struct) has no real
        # owner name to register under -- registry soundness only needs
        # *a* distinct owner (not necessarily the *correct* one) to make
        # monomorphic_target's own `defs.size == 1` check see more than
        # one real definition, so a synthetic placeholder is still safe
        # here, just less informative in a diagnostic dump.
        next_insn = irep.instructions[idx + 1]
        struct_name = if next_insn && next_insn.op == 'SETCONST'
                         sc_name, sc_reg = next_insn.args.split(/\s+/, 2)
                         sc_name if sc_reg == "R#{d}"
                       end
        owner = struct_name ? (namespace ? "#{namespace}::#{struct_name}" : struct_name) : "<struct:#{label}:#{idx}>"

        # Every member name Struct.new was given -- LOADSYM'd into
        # consecutive registers immediately before the ARRAY that packs
        # them into the splat argument (same adjacency assumption as
        # every other LOADSYM backward-scan in this file). Struct
        # installs both a reader and a writer for each member (real
        # runtime behavior, mruby's own struct.c) -- same shape as
        # attr_accessor above, so registered the same way.
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

        # Every real `def` (and any nested private/attr_reader/etc.
        # sub-pattern) inside the block body -- reuse this exact same walk,
        # just rooted at the block's own child irep instead of a
        # CLASS/MODULE-opened one, so a real def like Combatant#state?
        # above is registered as an ordinary MethodDef with a real irep
        # (walkable/compilable like any other, even though no current
        # ONLY_OWNERS run ever targets a Struct-generated class).
        walk.call(block_label, owner)
      end
    end
  end

  walk.call(root_label, nil)
  [registry, superclass_of, container_constants.compact]
end

# SUPER_SUPPORT: resolve a real `class X < SUPER_EXPR`'s own SUPER_EXPR to
# a real class name, walking backward from `before_idx` (the CLASS
# instruction's own index) the same cautious, real-instruction-only way
# trace_new_target's own GETMCNST/GETCONST chain walk does for a `.new`
# call's receiver -- but general-purpose rather than gated on a pre-vetted
# table, since the caller here (build_registry) is always actively
# walking the exact real lexical namespace (`namespace`) a bare
# superclass reference would resolve against, the same "real by
# construction" guarantee resolve_singleton_receiver already relies on
# for an identical bare-GETCONST case (only one level of nesting is ever
# checked, matching that helper -- a real Module.nesting fallback search
# through OUTER namespaces has no real case here to justify the extra
# complexity, see this file's own top-level survey). A `MOVE` keeps
# tracing through the same real register-aliasing every other backward
# scan in this file already tolerates; anything else unrecognized
# (a computed superclass expression, never seen in this closed world)
# returns nil -- absent from superclass_of, never a wrong guess.
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
# Step 5b: native (C/C++-defined) method name extraction -- RGSS's own
# mrb_define_method/mrb_define_class_method/mrb_define_module_function call
# sites in mruby-rgss/src (and any other C-extension gem) are invisible to
# mrbc -- there's no .rb source for them, so build_registry above never sees
# them at all. A method name real bytecode defines exactly once still looks
# MONO to that registry even when a *different* class registers a same-named
# method natively -- dispatch is by name only, so the registry's MONO
# assumption is unsound wherever that collision happens (the exact shape of
# the earlier-caught Game::Shop#name bug: Class#name/Symbol#name are
# C-defined core methods this registry can't see either).
#
# This only extracts the flat set of names these call sites register -- not
# an owner class, not a callable C++ symbol. Neither is needed to make
# MONO/POLY accounting sound again (that only cares whether a name might
# resolve somewhere this registry can't see), and a real direct call into
# one of these methods needs the VM's own call-info frame
# (`mrb->c->ci`) populated first the way `mrb_funcall`'s own
# `cipush`/`funcall_args_capture` does -- calling the raw function pointer
# directly would leave any `mrb_get_args` inside it reading a stale frame,
# a real correctness bug, not just a missed optimization. So this
# deliberately stays a registry-soundness fix only; see monomorphic_target's
# own comment for where the MONO decision this feeds actually lives.
# ---------------------------------------------------------------------------
# mruby's own presym operator-name table (3rd/mruby/lib/mruby/presym.rb's
# own OPERATORS hash, inverted) -- MRB_OPSYM(cmp) is how mruby-core's own
# C source spells the method `<=>`, never the operator text itself. A
# small, closed, finite table (mruby's own presym generator has no other
# source of truth for this mapping either), so hardcoding the inverse here
# is exactly as authoritative as reading it out of that file at runtime,
# without a real dependency on `3rd/mruby/lib` being on the load path.
OPSYM_TO_RUBY = {
  'not' => '!', 'mod' => '%', 'and' => '&', 'mul' => '*', 'add' => '+',
  'sub' => '-', 'div' => '/', 'lt' => '<', 'gt' => '>', 'xor' => '^',
  'tick' => '`', 'or' => '|', 'neg' => '~', 'neq' => '!=', 'nmatch' => '!~',
  'andand' => '&&', 'pow' => '**', 'plus' => '+@', 'minus' => '-@',
  'lshift' => '<<', 'le' => '<=', 'eq' => '==', 'match' => '=~',
  'ge' => '>=', 'rshift' => '>>', 'aref' => '[]', 'oror' => '||',
  'cmp' => '<=>', 'eqq' => '===', 'aset' => '[]=',
}.freeze

# RGSS's own C++ sources (mruby-rgss/src/lib.cxx) register every method
# with a literal string name (`mrb_define_method(M, rect, "x", ...)`), but
# mruby's *own* core (3rd/mruby/src/*.c) and its bundled C mrbgems mostly
# don't -- mruby 4.0 registers most of its own core methods through a
# declarative ROM method-table macro instead (confirmed against real
# source, e.g. 3rd/mruby/src/symbol.c's own `symbol_rom_entries`):
#   static const mrb_mt_entry symbol_rom_entries[] = {
#     MRB_MT_ENTRY(sym_name, MRB_SYM(name), MRB_ARGS_NONE()),
#     MRB_MT_ENTRY(sym_cmp,  MRB_OPSYM(cmp), MRB_ARGS_REQ(1)),   // <=>
#     ...
#   };
#   MRB_MT_INIT_ROM(mrb, sym, symbol_rom_entries);
# -- a real, distinct native-registration idiom the RGSS-only literal-
# string regex below cannot see at all. This is exactly the shape of the
# earlier-caught Game::Shop#name bug (Symbol#name/Class#name are two of
# the names this exact table form registers) -- so scanning mruby's own
# core C sources via NATIVE_SRCS only closes that gap if this second
# pattern is recognized too. A few core mrbgems (e.g. mruby-task) still
# call `mrb_define_method_id(mrb, klass, MRB_SYM(name), func, aspec)`
# directly instead of a ROM table -- same MRB_SYM/MRB_OPSYM symbol
# spelling, different call shape, covered by the same second regex below.
# One MRB_SYM(name)/MRB_SYM_Q(name)/MRB_SYM_B(name)/MRB_SYM_E(name)/
# MRB_OPSYM(op) token -- shared between extract_native_method_names (method
# *definitions*, below) and extract_native_call_names (method *calls*,
# below that), so the SYM_Q/SYM_B/SYM_E/OPSYM resolution logic (and the
# "longer alternative before the bare one" ordering fix documented at this
# constant's original call site) exists in exactly one place rather than
# two copies that could quietly drift apart.
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

def extract_native_method_names(src_paths)
  names = Set.new
  # MRB_SYM(name) spells the bare method name; MRB_OPSYM(op) spells an
  # operator method by its presym-table key (OPSYM_TO_RUBY above).
  # 3rd/mruby/include/mruby/presym.h also defines three more real, distinct
  # sibling macros this used to miss entirely: MRB_SYM_Q(name) -> "name?",
  # MRB_SYM_B(name) -> "name!", MRB_SYM_E(name) -> "name=" (e.g.
  # `#define MRB_SYM_Q(name) MRB_SYM_Q__##name`, the presym-tagged token for
  # "name?"). mruby core reaches for these constantly -- Array#empty?,
  # Kernel#nil?/#frozen?/#respond_to?, Numeric#zero?/#even?/#odd?,
  # Hash#key?/#has_key?, Range#cover?, String#chomp!/#downcase!, IO#sync=,
  # ... -- so missing them left every one of those names invisible to this
  # registry, a real, live bug caught building Game::MoveRoute
  # (docs/adr/0139's own follow-up): array.c's own ROM table spells
  # Array#empty? as `MRB_MT_ENTRY(mrb_ary_empty_p, MRB_SYM_Q(empty), ...)`,
  # which the old `MRB_(?:SYM|OPSYM)\(...\)` regex simply never matched, so
  # bc2cpp's registry saw only Game::MoveRoute#empty?'s own bytecode
  # definition for the name `:empty?` and reported it MONO -- compile_send
  # then devirtualized `@commands.empty?` (a plain Array) straight into
  # Game__MoveRoute_empty__impl calling itself, real infinite recursion,
  # caught only because g++'s own -Winfinite-recursion happened to flag a
  # literal self-call; the exact same collision against any OTHER class's
  # own same-named method would have compiled clean and silently
  # misresolved instead, invisible to any compiler warning. The longer
  # SYM_Q/SYM_B/SYM_E alternatives must be tried before the bare SYM one
  # below (regex alternation order) or "MRB_SYM_Q(empty)" would match SYM
  # against "SYM" alone and then fail on the unconsumed "_Q(empty)".
  Array(src_paths).each do |path|
    src = File.read(path, encoding: 'UTF-8')
    # Handles both single-line and the far more common multi-line call shape
    # (`mrb_define_method(\n M, rect, "initialize",\n ...);`) -- the regex
    # just doesn't care where the newlines fall between arguments.
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

    # mrb_define_method_raw(mrb, klass, MRB_SYM(name)/MRB_OPSYM(op), m) -- a
    # third, real registration idiom (3rd/mruby/src/class.c's own bob_init:
    # `mrb_method_t m; MRB_METHOD_FROM_PROC(m, &neq_proc); mrb_define_method_
    # raw(mrb, bob, MRB_OPSYM(neq), m);`) that pre-builds an mrb_method_t --
    # sometimes wrapping a real C function, sometimes (like `!=` here) a
    # hand-written static RProc/irep baked directly into the C source rather
    # than compiled from any .rb file this run ever sees. Either way it is
    # still a real, whole-program-visible definition this registry must
    # know about, or a name like `!=` looks like it has NO definition at
    # all (worse than looking POLY-native: `native_only_mono?` requires an
    # actual `<native>` entry to gate on, so with no entry here it can never
    # fire, silently leaving a real, always-safe candidate undevirtualized
    # forever) -- confirmed via a full grep across 3rd/mruby/src that only
    # three literal-token call sites exist at all (`new` on Class, `!=` on
    # BasicObject, `call`/`[]` on Proc); the rest all pass a runtime
    # variable (alias/`define_method`-style dynamic definition), which no
    # static regex could or should try to match.
    src.scan(/mrb_define_method_raw\s*\(\s*\w+\s*,\s*\w+\s*,\s*#{MRB_SYM_TOKEN_RE}/) do |tok|
      names << resolve_mrb_sym_token(tok[0], tok[1])
    end
  end
  names
end

# A sibling to extract_native_method_names above, but for the opposite
# direction: which method names does this project's own native C/C++ (or
# mruby's own C core, when fed the same NATIVE_SRCS list) ever *call* by
# literal name -- mrb_funcall/mrb_funcall_id/mrb_funcall_argv/
# mrb_funcall_with_block's own "name" argument, spelled either as a
# literal C string or as one of the same MRB_SYM/MRB_OPSYM-family tokens
# extract_native_method_names already resolves via resolve_mrb_sym_token.
# Feeds the "never called" reachability diagnostic near the bottom of this
# file's own driver -- never consulted by codegen itself, the same
# diagnostic-only standing as Step 6e's report_annotation_candidates.
#
# Deliberately loose about which argument position the string/token
# actually sits in (a bounded lookahead after the call, not a strict
# comma-split): mrb_funcall's own receiver argument is frequently itself
# a call expression with commas of its own (e.g. `mrb_funcall_id(mrb,
# mrb_ary_entry(ary1, i), MRB_OPSYM(eq), ...)`), which a naive
# `[^,]+`-between-commas split (extract_native_method_names' own approach,
# safe there only because mrb_define_method's own receiver argument is
# always a bare identifier by this codebase's convention) would
# mis-parse. A 200-character bounded, non-greedy lookahead for "the
# nearest quoted string or MRB_SYM-family token after the opening paren"
# is a loose heuristic, not a real argument-position parse -- but the real
# calling convention (mrb_state*, receiver, name, ...) never puts another
# quoted string or symbol token before the name argument in practice, and
# a false match here only ever adds a name to the "reachable" set, never
# removes one -- so a wrong match is silently safe here, unlike the
# definition side above (where a missed name would wrongly leave a real
# collision looking MONO).
def extract_native_call_names(src_paths)
  names = Set.new
  Array(src_paths).each do |path|
    src = File.read(path, encoding: 'UTF-8')
    src.scan(/mrb_funcall(?:_id|_argv|_with_block)?\s*\(.{0,200}?(?:"((?:[^"\\]|\\.)*)"|#{MRB_SYM_TOKEN_RE})/m) do |str, macro, sym|
      names << (str ? unescape_c_string(str) : resolve_mrb_sym_token(macro, sym))
    end
  end
  names
end

# ---------------------------------------------------------------------------
# Step 6b: ivar-embedding analysis -- which instance variables can be lifted
# out of the dynamic ivar table (`iv_tbl`) and stored as real typed C struct
# fields on an RData payload instead.
#
# The rule: walk every SETIV site for a given ivar, across every method of
# every class that ever sets it (closed-world -- the whole program's own
# methods are the only possible writers, same assumption the monomorphic
# call-site analysis makes). If EVERY site's stored value can be traced back
# (through MOVE chains, within the same straight-line method body) to a
# source that is provably always the same primitive type -- a literal
# (LOADI/LOADI_n -> Fixnum), a fixnum-fastpath arithmetic op (ADD/ADDI,
# which this prototype's opcode subset only ever uses for Fixnum), or a read
# of another ivar already known to be that same type -- the ivar is
# embeddable as that type. A single unknown-typed source (an opaque method
# argument, e.g. Animal#@name) or a type MISMATCH across sites (nil in one
# place, String in another, e.g. Counter#@label) makes it permanently
# dynamic -- the same "one bad site poisons the whole name" join used for
# method-name monomorphism.
#
# This is a fixed-point analysis (not a single pass in a lucky order):
# Counter#increment's `@count = @count + 1` needs `initialize`'s
# `@count = 0` to already be known Fixnum before it can resolve its own
# GETIV @count read, so every class's every method is repeatedly swept
# until the per-ivar type map stops changing.
class IvarLayout
  UNKNOWN = :unknown

  # `arg_types`: method_name -> array of (:fixnum or nil) per mandatory-arg
  # position, from ArgTypes.analyze below -- optional (defaults to none),
  # since ArgTypes is itself built out of this same trace_type, and the two
  # combined only make ivar embedding *more* permissive, never less: an
  # ivar that was already embeddable without argument inference stays
  # embeddable either way. `annotations`: irep label -> Annotations::
  # Annotation, from Annotations.extract -- same "only ever adds" property,
  # and (unlike arg_types) reaches `#initialize` too, see Annotations'
  # own comment.
  def self.analyze(ireps, registry, arg_types = {}, annotations = {})
    # class_name -> irep labels of every leaf method owned by that class.
    # `d.irep` is nil for a synthetic native MethodDef (extract_native_
    # method_names's own merge into the registry) -- no bytecode body
    # exists to walk for one of those, so it's excluded here rather than
    # left to blow up the very next `ireps.fetch` below.
    methods_of = Hash.new { |h, k| h[k] = [] }
    registry.each_value { |defs| defs.each { |d| methods_of[d.owner] << d.irep if d.irep } }
    # irep label -> its own MethodDef, so a SETIV site's trace can look up
    # *its own* method's name/arity when it bottoms out at an incoming
    # argument register (see trace_type's own final fallback).
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
            # Not `$`-anchored: "SETIV @x R1 ; R1:v" carries a trailing
            # local-variable-name comment whenever the source register is a
            # named local (real code's `initialize(x); @x = x; end` shape,
            # everywhere) -- anchoring to end-of-string missed the register
            # entirely on exactly those lines and silently traced `nil`,
            # under-counting real embeddable ivars. Caught by running this
            # against actual game source; the toy example's own SETIV sites
            # never happened to have a trailing comment.
            src_reg = insn.args[/R(\d+)/, 1]
            inferred = trace_type(irep, idx, src_reg, types[klass], arg_types, mand, d&.name, annotations)
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

  # Two contributions for the same ivar must agree, or it's poisoned to
  # UNKNOWN permanently (a real type mismatch, e.g. nil vs. String) --
  # `b == UNKNOWN` is itself a disagreement (this new site's own type could
  # not be determined at all) and has to poison exactly the same way a
  # concrete-but-different type does, not be silently discarded in favor of
  # whatever type an earlier site already established. A real, demonstrated
  # bug caught building Game::Character: `#move_diagonal`'s own
  # `@last_move_direction = [horizontal, vertical]` (a real Array literal,
  # ARRAY opcode, correctly traced to UNKNOWN by trace_type's own generic
  # fallback) used to have its UNKNOWN contribution silently dropped by the
  # `return a if b == UNKNOWN` branch below whenever an earlier-processed
  # site (here, `#initialize`'s own `@last_move_direction = direction`) had
  # already joined in a concrete `:fixnum` for the same ivar name -- the
  # 10-pass fixed-point sweep above has no fixed processing order across
  # methods, so which site's contribution lands first in `types[klass]` is
  # incidental, not something call sites can rely on to "arrive UNKNOWN
  # first." The fix makes `UNKNOWN` join to `UNKNOWN` unconditionally,
  # regardless of which side of the pair already held a concrete type or
  # which order the two contributions were processed in -- the same
  # commutative, order-independent join a sound fixed-point analysis needs.
  # This closed a real, live unsoundness already affecting two shipped,
  # embedding classes (docs/adr/0139's own Game::Character follow-up has
  # the full before/after diagnostic diff and severity writeup):
  # Game::Screen and Game::State each had ivars wrongly embedded as
  # provably-Fixnum before this fix, when a later-processed real
  # non-Fixnum-typed assignment site for the same ivar name should have
  # poisoned them to UNKNOWN (dynamic iv_tbl) instead.
  def self.join(a, b)
    return b if a.nil?
    return UNKNOWN if b == UNKNOWN || b.nil?
    return UNKNOWN if a != b

    a
  end

  # Walk backward from `idx` in `irep.instructions` looking for whatever
  # last wrote `reg`, following MOVE chains, until a type-determining
  # opcode (or the top of this straight-line method body, in which case
  # `reg` is an opaque incoming argument -- unknown).
  def self.trace_type(irep, idx, reg, known_ivar_types, arg_types = nil, mand = 0, method_name = nil, annotations = nil)
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
        # A literal Symbol source (`@x = :foo`) -- see CodeGen::TYPE_OPS's
        # own comment for why this is just as safe to embed as Fixnum: a
        # real `mrb_sym` (a plain uint32_t interned id, never itself a
        # GC-tracked heap object -- 3rd/mruby/src/symbol.c's own symbol
        # table is only ever freed in bulk at mrb_close, never per-symbol
        # during an ordinary GC sweep), not an mrb_value needing to stay
        # reachable for the GC to keep it alive.
        return :symbol
      when 'LOADNIL'
        d = insn.args[/^R(\d+)/, 1]
        next unless d == reg

        return UNKNOWN
      when 'ADD', 'ADDI'
        d = insn.args[/^R(\d+)/, 1]
        next unless d == reg
        # Both ADD and ADDI are this opcode subset's only fixnum-fastpath
        # arithmetic ops (see CodeGen#compile_insn) -- their *destination*
        # register holds a Fixnum on the fast path taken in this prototype.
        return :fixnum
      when 'GETIV'
        d = insn.args[/^R(\d+)/, 1]
        next unless d == reg

        other_ivar = insn.args[/@(\w+)/, 1]
        return known_ivar_types[other_ivar] || UNKNOWN
      else
        # Any other opcode's destination register: nearly every mruby
        # opcode's first operand is its Rd (SEND, STRING, GETCONST,
        # LOADSYM, ARRAY, HASH, ...), so this generically recognizes "some
        # instruction we don't specifically model just wrote reg" and stops
        # the trace there -- UNKNOWN, not a silent skip past it. Skipping
        # past an unrecognized writer instead of stopping would let the
        # scan wander into an unrelated, coincidentally-earlier write to
        # the same register number from a completely different statement
        # (registers are reused within a method) and misattribute its
        # type -- a real unsoundness this prototype's own toy example
        # never had the length/register reuse to expose, but real code
        # does. See README.md.
        d = insn.args[/^R(\d+)/, 1]
        return UNKNOWN if d == reg
      end
    end
    # reg was never written in this block -- an incoming argument. Register
    # N (1-indexed) is argument N for N <= mand, the same convention
    # CodeGen#compile_method itself uses (`r#{i + 1} = #{a}`) -- if
    # whole-program call-site inference (ArgTypes, below) found every real
    # caller of *this* method passes the same primitive type there, use
    # it; otherwise this is a genuinely opaque incoming value (the
    # `Animal#@name` case: no caller-side inference possible without
    # knowing every caller passes a String, which ArgTypes only proves for
    # Fixnum-typed positions).
    pos = reg.to_i
    if pos.between?(1, mand)
      # A magic-comment annotation is per-*definition* (keyed by this exact
      # irep, not pooled by name the way ArgTypes below is), so it's
      # authoritative and safe to trust regardless of whether `method_name`
      # is MONO or POLY -- tried first for exactly that reason.
      t = annotations && annotations[irep.label]&.args&.[](pos - 1)
      return t if t

      t = arg_types && method_name && arg_types[method_name]&.[](pos - 1)
      return t if t
    end
    UNKNOWN
  end
end

# ---------------------------------------------------------------------------
# Step 6c: whole-program call-site argument-type inference -- "cheap type
# annotating" without any actual annotation: for a method name with
# exactly one real definition (MONO -- the same registry IvarLayout and
# devirtualization both already trust), every SEND/SSEND anywhere in the
# program that sends that name can only ever be calling this one
# definition (dispatch is by name, not signature, so a POLY name's call
# sites could each be targeting a *different* real method -- pooling their
# arguments together would silently conflate unrelated calling
# conventions, so this deliberately only ever looks at MONO names).
#
# For each of its mandatory argument positions, this walks every such call
# site's own argument register backward with IvarLayout's own trace_type
# (exactly the same machinery SETIV sites already use, just re-pointed at
# a SEND's argument registers instead) -- if every real caller's value for
# that position traces to Fixnum, the position is Fixnum everywhere calls
# reach it from. This directly feeds IvarLayout's own "opaque incoming
# argument" fallback above: `Animal#@name`-shaped ivars (a SETIV whose
# only source is a plain method parameter) can now embed whenever every
# real call site happens to pass a Fixnum there, without needing a real
# type annotation anywhere in the source.
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
          # Same charset as compile_send's own name extraction (see its own
          # comment) -- before this fix, a MONO name that happened to be an
          # operator (e.g. `&`) could never match here (the old class
          # matched nothing after the colon), so a real call site to it
          # silently never got its argument type inferred. A safe
          # under-approximation either way (never wrongly infers Fixnum),
          # not the correctness bug compile_send's own copy of this regex
          # had -- fixed anyway, for the same soundness this whole pass
          # already aims for.
          next unless insn.args[/:([\w+\-*\/<>=!?\[\]&|^~%@]+)/, 1] == name

          d = insn.args[/^R(\d+)/, 1].to_i
          n = insn.args[/n=(\d+)/, 1].to_i
          next unless n == mand # a real call site to a MONO name always matches its one definition's arity.

          (1..mand).each do |k|
            # No `known_ivar_types` context here (a caller's own ivars
            # aren't tracked at this point) -- a GETIV-sourced argument
            # value traces to UNKNOWN, a safe under-approximation (never
            # wrongly infers Fixnum), not a wrong one.
            t = IvarLayout.trace_type(caller_irep, idx, (d + k).to_s, {})
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
# Step 6d: magic-comment argument-type annotations -- a cheap, explicit
# escape hatch for exactly the gap ArgTypes documents as structurally
# unreachable: `#initialize`'s own arguments. `X.new(args)` always compiles
# to `SEND :new` (a C-defined core method), never a real bytecode `SEND
# :initialize`, so ArgTypes' call-site scan can never see what a real
# `Foo.new(1, 2)` call site actually passes -- and `#initialize` is where
# nearly every real ivar-from-argument pattern in this codebase lives.
#
# Unlike ArgTypes (which pools call *sites* under a name, so it only stays
# sound for MONO names -- a POLY name's call sites could each be targeting a
# genuinely different method), a magic comment sits directly on one real
# `def`, naming its own irep by construction -- safe for *any* method
# regardless of how many other classes define the same name, `#initialize`
# (about as POLY a name as they come) very much included.
#
# Syntax: a comment matching `# bc2cpp: (T1, T2, ...) -> T3` on the line
# immediately above (blank lines skipped) a `def` -- e.g.:
#   # bc2cpp: (fixnum, fixnum) -> fixnum
#   def initialize(x, y)
# `mrbc` never sees comments at all (stripped at parse time, long before
# any bytecode exists), so this has *zero* effect on the interpreted path
# -- the exact same "opt-in, invisible when unused" property every other
# bc2cpp feature in this file has. A wrong annotation can't silently
# corrupt anything either: IvarLayout's own SETIV-embedding codegen already
# guards every embedded write with a real `mrb_integer_p` check + `mrb_raise`
# regardless of how the type was established (a literal, ArgTypes
# inference, or this) -- lying in a comment just means a real TypeError at
# runtime instead of a wrong build, never silent corruption.
#
# Only a `fixnum`/`Fixnum`/`Integer` or `symbol`/`Symbol` type token means
# anything today -- matching the two primitive types IvarLayout/ArgTypes
# themselves model; anything else is simply not recognized (never an
# error -- an unsupported token just means this one annotation
# contributes nothing, same as omitting it).
class Annotations
  TYPES = { 'fixnum' => :fixnum, 'Fixnum' => :fixnum, 'Integer' => :fixnum,
            'symbol' => :symbol, 'Symbol' => :symbol, 'Array' => :array }.freeze
  COMMENT_RE = /^\s*#\s*bc2cpp:\s*\(([^)]*)\)(?:\s*->\s*(\S+))?\s*$/

  Annotation = Struct.new(:args, :ret, keyword_init: true)

  # `:array` (the `Array` token) feeds ONLY the block-receiver return-
  # type gate (annotated_array_return -- "this MONO method returns a
  # fresh Array", consumed by the block recognizers' chained rule). It
  # must never reach struct-field codegen: native_arg_types (the sole
  # consumer of `args`, and the only path from an annotation token to a
  # C type) maps unrecognized tokens through native_c_type, which has
  # no `:array` arm -- an `Array` token in ARGUMENT position would raise
  # KeyError at codegen time rather than silently embed. That fail-loud
  # shape is deliberate (same discipline as ClassAnnotations'
  # silently-no-op on non-class tokens, mirrored): argument Array types
  # are not modeled, return Array types are. See annotated_array_return's
  # own comment for why the gate itself stays sound despite resting on a
  # hand-placed comment (the emitter's own mrb_array_p tripwire verifies
  # every admitted site at runtime).

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
        # `enter.lineno` is 1-indexed and lands on the real `def` line
        # itself (confirmed against mrbc -v's own per-instruction line
        # numbers) -- the immediately preceding line, skipping blanks, is
        # where the annotation comment goes.
        idx = enter.lineno - 2
        idx -= 1 while idx >= 0 && lines[idx].strip.empty?
        next if idx < 0

        m = COMMENT_RE.match(lines[idx])
        next unless m

        arg_types = m[1].split(',').map { |t| TYPES[t.strip] }
        # ELEMENT_CLASS_SUPPORT: an `Array<Game::Actor>` return token is
        # still, first and foremost, an `Array` return token -- the
        # element name only NARROWS an already-true claim, it never
        # changes it. Stripping the `<...>` here (rather than adding
        # every `Array<...>` spelling to TYPES, which is unbounded) keeps
        # `-> Array<Klass>` a strict superset of `-> Array`: every site
        # the plain form already unlocked through annotated_array_return
        # keeps working byte-identically after a hand annotation is
        # narrowed, and ElementAnnotations below reads the SAME comment
        # independently for the element half -- exactly the way
        # ClassAnnotations already shares Annotations' own comment line
        # for class-shaped argument tokens without either reader
        # disturbing the other. A bare `Array<...>` whose inner token
        # isn't a real known class is still a plain `-> Array` here and
        # simply contributes no element fact at all (see
        # ElementAnnotations' own known_owners gate) -- a typo degrades
        # to today's behavior, never to a wrong gate.
        ret_token = m[2]&.sub(/<.*>\z/, '')
        ret_type = ret_token && TYPES[ret_token]
        result[irep.label] = Annotation.new(args: arg_types, ret: ret_type)
      end
    end

    result
  end
end

# ---------------------------------------------------------------------------
# Step 6f: class-name argument annotations -- the exact same magic-comment
# syntax Annotations reads (`# bc2cpp: (...)`), but a completely separate
# reader with a completely different claim: "this mandatory argument
# position is always exactly this one real class" rather than a
# primitive type. Deliberately never shares Annotations' own TYPES/
# Annotation -- a class name must never reach IvarLayout's embedding
# lattice (there's no struct field to unbox a general object reference
# into; C_TYPE.fetch would raise a real KeyError at codegen time the
# first time one did). Both readers can freely look at the very same
# comment line (`# bc2cpp: (Game::State, fixnum)` -- position 1 a class
# hint, position 2 a primitive hint) without stepping on each other:
# Annotations::TYPES already silently no-ops on a class-shaped token
# (an "unsupported token" per its own comment), and this silently no-ops
# on any token that isn't a real, already-known class name.
class ClassAnnotations
  Annotation = Struct.new(:args, keyword_init: true)

  # `known_owners`: every real class name this closed-world registry
  # actually has (`registry.values.flatten.map(&:owner).uniq`) -- gates a
  # token being treated as a class hint on it actually being a class
  # bc2cpp knows about, not just any capitalized word that happens to
  # appear in a comment.
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

        args = m[1].split(',').map { |t| t.strip if known_owners.include?(t.strip) }
        next if args.all?(&:nil?)

        result[irep.label] = Annotation.new(args: args)
      end
    end

    result
  end
end

# ---------------------------------------------------------------------------
# Step 6f-ter: ELEMENT_CLASS_SUPPORT -- the third independent reader of the
# very same `# bc2cpp: (...) -> T` magic comment, this one claiming
# something neither of the two above can express: "this method returns an
# Array every element of which is exactly this one real class".
#
#   # bc2cpp: () -> Array<Game::Actor>
#   def stat_targets(cmd)
#
# Why a separate reader rather than another Annotations::TYPES entry, the
# same reasoning ClassAnnotations' own comment already gives for argument
# class tokens: `Annotations`' `ret` feeds a primitive-type lattice
# (:fixnum/:symbol/:array) whose consumers map straight to C types, and a
# real class name has no C type to map to. Annotations still reads the
# same token as a plain `:array` (see its own `ret_token` comment), so the
# element half is purely additive -- narrowing `-> Array` to
# `-> Array<Klass>` can only ever unlock MORE, never disturb the
# fresh-Array gate that token already fed.
#
# `known_owners` gates the inner token exactly the way ClassAnnotations
# gates an argument token: a name this closed-world registry has never
# seen as a real class is silently ignored (contributes nothing), never an
# error and never a guess -- so a typo, a renamed class, or a class that
# simply isn't in this run's own closed world all degrade to today's
# behavior instead of producing a hint nothing can honor.
#
# Trust model, identical to annotated_array_return's own (see its
# comment): this is a HAND-PLACED claim, not an inference, and its
# soundness rests on two things rather than on the comment alone --
#   (1) every consumer runtime-guards it. The block emitters' own
#       ELEMENT_CLASS devirtualization reproduces compile_send's exact
#       `mrb_class_ptr(...) == mrb_obj_class(M, elem)` check before any
#       direct call, falling back to ordinary `mrb_funcall` otherwise, so
#       a WRONG annotation costs a failed guard and a slower call -- never
#       a wrong dispatch. This is strictly stronger than the plain
#       `-> Array` annotation's own backstop (an `mrb_array_p` tripwire
#       that RAISES), because a wrong element claim doesn't even raise:
#       it simply never fires.
#   (2) ArrayElementLayout below re-derives the same fact independently
#       wherever it can, and POISONS an ivar whose real populating sites
#       disagree -- the annotation is consulted as one terminal of that
#       sweep, not as an override of it.
# Two claims, read off the same `-> T` token and kept apart because they
# are genuinely different facts:
#   - `-> Array<Game::Actor>` (`element`): the RESULT is an Array and each
#     of its elements is exactly Game::Actor.
#   - `-> Game::Actor` (`ret_class`): the RESULT ITSELF is exactly
#     Game::Actor. This is the leaf fact ArrayElementLayout's own sweep
#     cannot reach any other way -- `trace_new_target` has no return-type
#     inference at all (its own comment says so), so an array built by
#     `ids.map { |i| @roster[i] }` is unresolvable until something names
#     what `Game::Actors#[]` hands back.
#
# NIL, stated precisely rather than glossed: both forms claim
# "every value that is not nil is exactly this class". A real method that
# returns nil on a miss (`Game::Actors#[]` returns nil for a non-positive
# or database-missing id -- read in full, not assumed) is therefore
# annotatable truthfully, and a nil that does reach an element position
# is a GUARANTEED miss at every consumer's own `mrb_obj_class` guard
# (`mrb_obj_class(M, nil)` is NilClass, never the annotated class), so it
# can only ever cost a fallback `mrb_funcall` -- it can never make a
# direct call fire on a nil receiver. Defining the claim this way keeps
# it exactly true instead of approximately true.
#
# `ret_class` is deliberately NOT wired into `trace_new_target` this
# round, only into ArrayElementLayout's own value tracer (see
# `element_value_class`). It would be sound there too (every consumer of
# that function already runtime-guards), but it would change the TYPED
# devirtualization decision at every call site in the program at once,
# which is a much larger blast radius than one round should mix into a
# new mechanism's own measurement. Named follow-up, recorded here rather
# than left implicit: "ELEMENT_CLASS_SUPPORT: promote `ret_class` to a
# trace_new_target terminal".
class ElementAnnotations
  Annotation = Struct.new(:element, :ret_class, keyword_init: true)

  # `-> Array<Game::Actor>` / `-> Array<RPG2k::Window>`: one `::`-joined
  # class path inside the angle brackets, matched against the exact same
  # `Owner` spelling build_registry gives every MethodDef (see
  # trace_new_target's own comment on why that spelling is directly
  # comparable). Anchored whole-token on purpose -- a partial match like
  # `Array<Foo, Bar>` (a heterogeneous claim this mechanism deliberately
  # cannot express) simply doesn't match and contributes nothing.
  ELEMENT_RE = /\AArray<([A-Za-z_][\w:]*)>\z/
  RET_CLASS_RE = /\A([A-Za-z_][\w:]*)\z/

  # Tokens that already mean something to `Annotations::TYPES` and must
  # never ALSO be read as "returns an instance of the class with this
  # name". `Array` is the one that actually bites: it is a real
  # `known_owners` entry in every gem's own closed world (mruby-rgss/
  # mrblib/array_sort.rb reopens it, so build_registry registers `Array`
  # as a real owner), so a plain, long-standing `-> Array` annotation
  # would otherwise silently acquire a second, new meaning here. Excluded
  # by name so today's `-> Array` comments keep meaning exactly and only
  # what they have always meant.
  NON_CLASS_RET_TOKENS = (Annotations::TYPES.keys + ['Array']).uniq.freeze

  # irep label -> Annotation, for every real `def` whose annotation
  # comment carries a recognized element or return-class token.
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
        next unless m && m[2]

        tok = m[2]
        element = nil
        ret_class = nil
        if (em = ELEMENT_RE.match(tok))
          element = em[1] if known_owners.include?(em[1])
        elsif !NON_CLASS_RET_TOKENS.include?(tok) && (rm = RET_CLASS_RE.match(tok))
          ret_class = rm[1] if known_owners.include?(rm[1])
        end
        next unless element || ret_class

        result[irep.label] = Annotation.new(element: element, ret_class: ret_class)
      end
    end

    result
  end
end

# ---------------------------------------------------------------------------
# Step 6f-bis: the shared "this expression is a proven fresh Array" rule.
# Used by BOTH the whole-program ivar-class analysis below (Step 6g, at its
# own SETIV sites) and, via CodeGen#proven_array_source, by every block
# recognizer further down -- one implementation, so the two can never drift
# apart on a soundness-critical question.
# ---------------------------------------------------------------------------
# INTERP_UNLOCK: the chained-receiver rule, shared by every block
# recognizer further down in this file (and by Step 6g below). When the
# static Array trace misses, scan backward
# for the nearest write to the destination register; the receiver is
# proven Array when that write is:
#   - a BLOCK-CARRYING call to `select`/`reject`/`map` (see the
#     block-gate note on CHAINED_ARRAY_METHODS below), or
#   - a call to a MONO method carrying a hand-placed `-> Array`
#     return annotation (annotated_array_return -- e.g.
#     `stat_targets`), or
#   - a call to a core method whose fresh-Array return is verified
#     against mruby's own implementation AND re-checked against this
#     program's real registry (core_array_return? below).
# Single-step, no fixpoint: the nearest write decides (MOVE chains are
# followed through to the register actually written -- see the scan's
# own comment). Sound by
# SKIP_UNSUPPORTED's own per-method partitioning: a producing call
# with any gap drops the whole method (including this site) to the
# interpreter -- so this rule only fires where the producer ALSO
# compiled (or is itself a chained link whose root traced clean).
#
# CORE_ARRAY_CHAIN block gate: these three are admitted ONLY from a
# block-carrying send (`SENDB`/`SSENDB`), never a bare `SEND`/`SEND0`.
# This is a TIGHTENING of the original rule (which matched the bare
# name in any dispatch shape), made after that looser form was caught
# producing a real, verifiably WRONG answer once ClassLayout started
# consulting this same scan: `RPG2k::Scene::MapViewer#@map = map ||
# state.map` (mruby-rpg2k/mrblib/scene/map_viewer.rb) got classified
# `Array`, because the `||`'s own right-hand side is a `SEND0 :map` --
# `Game::State#map` is an `attr_accessor` holding the current
# Game::Map, not an Array at all. Two independently checked facts make
# the block the right discriminator:
#   - A blockless `map`/`select`/`reject` never returns an Array in
#     mruby anyway: `Enumerable#collect` (aliased to `map`,
#     mrblib/enum.rb) and `Enumerable#reject` both open with
#     `return to_enum(...) unless block`, and `select` is
#     `alias select find_all`, the same shape -- i.e. an ENUMERATOR.
#     So requiring a block does not lose a single real Array producer;
#     it only drops shapes the old rule was answering wrongly.
#   - An `attr_reader`/`attr_accessor` read is always a bare,
#     argument-less, blockless send, so the block requirement excludes
#     that entire (large) class of same-named accessors by
#     construction, which is exactly what went wrong above.
# Known remaining narrowing, recorded rather than papered over: a
# block-carrying `select`/`reject` on a HASH receiver returns a Hash,
# not an Array (mrblib/hash.rb's own `Hash#select` builds `h = {}`),
# so this rule is still receiver-agnostic in a way that can overclaim
# there. Every block-recognizer consumer backstops that with its own
# `mrb_array_p` raise-tripwire (loud TypeError, never a silent
# miscompile), and the ClassLayout consumer's readers all re-check the
# class at runtime before trusting a hint -- but proving the receiver
# is not a Hash is genuinely out of reach here, so it stays a
# documented narrowing, not a claim.
CHAINED_ARRAY_METHODS = %w[select reject map].freeze

# CORE_ARRAY_CHAIN: a second, independent producer set for the same
# chained rule -- core methods that return a *fresh Array* on every
# path that returns at all. Unlike CHAINED_ARRAY_METHODS above (bare
# name, no whole-program check), every name here is admitted ONLY
# after `core_array_return?` below re-confirms, against the real
# whole-program registry, that nothing in THIS program defines the
# name except mruby's own core -- so a future `def keys` on a game
# class silently drops the name back to today's honest `#error`
# instead of quietly keeping a now-false claim. That check is the
# whole reason this is a separate set rather than three more entries
# in CHAINED_ARRAY_METHODS.
#
# Every entry verified by reading 3rd/mruby's own implementation at
# this repo's own pinned submodule commit (831da26b), never assumed:
#   - `keys`   -- `mrb_hash_keys`, src/hash.c's own Hash method table
#                 (MRB_SYM(keys), MRB_ARGS_NONE) -> a real Array.
#   - `values` -- `mrb_hash_values`, same table (MRB_SYM(values)).
#   - `compact`-- mrbgems/mruby-array-ext/src/array.c `ary_compact`:
#                 `mrb_ary_dup(mrb, self)` + compact_bang, returns
#                 that dup -- an Array by construction.
#   - `flatten`-- same file, `ary_flatten` -> `flatten_internal`,
#                 which builds and returns a new Array.
#   - `split`  -- String#split (src/string.c) -> a real Array.
#   - `uniq`   -- BOTH core definitions return an Array: Array#uniq
#                 (mruby-array-ext/mrblib/array.rb) yields `ary`
#                 (a `self.dup`) with a block and `__uniq` without,
#                 and Enumerable#uniq (mruby-enum-ext/mrblib/enum.rb)
#                 ends in `hash.values` -- Array either way, block or
#                 no block.
# A receiver that has no such method at all raises a real
# NoMethodError before ever returning, so "whenever this call returns,
# it returned an Array" holds for every possible receiver -- the same
# trust model recognize_times_regions' own `mrb_integer_p` guard
# already documents, and every admitted site still passes through the
# emitter's own `mrb_array_p` raise-tripwire regardless.
#
# Deliberately NOT here, each for a checked reason, not an oversight:
#   - `to_a`/`dup` -- receiver-dependent (`x.dup` is an Array only when
#     `x` already was). No static receiver proof available at exactly
#     the sites where this rule is needed.
#   - `to_h` -- returns a Hash, not an Array.
#   - `sort_by` (blockless) -- see CORE_ARRAY_CHAIN_NEEDS_BLOCK.
#   - `first`/`last` (no argument) -- see CORE_ARRAY_CHAIN_NEEDS_ARG:
#     an Array only with an explicit argument, an ELEMENT (or nil)
#     without one.
CORE_ARRAY_RETURN_METHODS = %w[keys values compact flatten split uniq].freeze

# CORE_ARRAY_CHAIN: names that return a fresh Array ONLY when called
# WITH an explicit argument (`n=1` or more at the call site -- a real
# `SEND`/`SENDB` argument count, checked the same way
# recognize_collect_regions' own `n=0` gate already is), so they are
# rejected on a bare no-arg call. Read directly against this repo's
# own pinned 3rd/mruby/src/array.c (both are core, MRB_MT_ENTRY table
# entries -- picked up by extract_native_method_names via NATIVE_SRCS
# exactly like keys/values above, never assumed):
#   - `first` -- `mrb_ary_first`: `mrb_get_argc(mrb) == 0` returns the
#     first ELEMENT (or nil, empty receiver) -- NOT an Array; the `|i`
#     branch (an explicit `n`) always returns
#     `mrb_ary_new_from_values`/`ary_subseq`, a real fresh Array,
#     whatever `n` and the receiver's length are (clamped to the
#     receiver's own length, never raises on an oversized `n`).
#   - `last` -- `mrb_ary_last`, the identical no-arg-vs-arg split
#     (`ARY_PTR(a)[alen - 1]` vs `ary_subseq`/`mrb_ary_new_from_values`
#     depending on `size`).
# Neither is redefined anywhere in this program's own source (checked:
# no `def first`/`def last` in any closed-world mrblib file), so like
# CORE_ARRAY_RETURN_METHODS this only ever needs the `'<native>'`
# branch of core_array_return?'s own registry check, never a vetted
# override.
CORE_ARRAY_CHAIN_NEEDS_ARG = %w[first last].freeze

# CORE_ARRAY_CHAIN: names that return a fresh Array ONLY when a real
# block is passed, so they are admitted exclusively from a block-
# carrying send (`SENDB`/`SSENDB`), never a bare `SEND`/`SEND0`:
#   - `sort_by` -- BOTH core definitions open with
#     `return to_enum(:sort_by) unless block` (Array#sort_by and
#     Enumerable#sort_by, mruby-enum-ext/mrblib/enum.rb), i.e. a
#     blockless `sort_by` hands back an ENUMERATOR, not an Array.
#     With a block, Array#sort_by ends in `ary.collect! {...}` (an
#     Array) and Enumerable#sort_by delegates to `self.to_a.sort_by`
#     (that same Array). So the block is exactly what makes the claim
#     true, and it is checked here rather than assumed.
CORE_ARRAY_CHAIN_NEEDS_BLOCK = %w[sort_by].freeze

# CORE_ARRAY_CHAIN: the one real bytecode definition this round vetted
# by hand, in the same single-entry, exact-`Owner#name` tradition as
# RANGE_RETURN_METHODS/SUPER_TARGETS -- naming a bare method name here
# would defeat the whole-program check `core_array_return?` performs.
#
# `sort` is the only chain producer in the measured set that this
# program really does redefine in bytecode: mruby-rgss/mrblib/
# array_sort.rb reopens `class Array` to normalize a comparator's
# answer around mruby's own `-2` "comparison failed" sentinel. Read in
# full: both of its paths (`return _rgss_native_sort if block.nil?`
# and `_rgss_native_sort { ... }`) return the value of
# `_rgss_native_sort`, an `alias_method` of mruby's own native
# `Array#sort`, which is `self.dup.sort!` (mrblib/array.rb) -- an
# Array on both paths. The only other `sort` any receiver in this
# program can reach is Enumerable#sort (mrblib/enum.rb),
# `self.map {...}.sort(&block)` -- an Array too. So `sort` returns a
# fresh Array for every possible receiver here, and unlike the names
# above that fact depends on a file in THIS repo, which is precisely
# why it is called out by exact owner instead of trusted by name.
VETTED_ARRAY_RETURN_OVERRIDES = Set['Array#sort'].freeze

# CORE_ARRAY_CHAIN: is `name` a core producer whose fresh-Array claim
# still holds against THIS program's real whole-program registry?
# Every MethodDef registered under the name must be either mruby's own
# native core (owner `'<native>'`, build_registry's own marker for a
# NATIVE_SRCS-derived entry -- confirmed for every name in the two
# sets above that mruby-rgss/src/*.cxx defines none of them, so a
# `<native>` entry here can only be mruby core itself) or an
# explicitly vetted bytecode override. A name with NO registry entry
# at all (`uniq`, `sort_by` -- implemented in mruby's own mrblib,
# which is neither a closed-world source nor a NATIVE_SRCS file) is
# likewise fine: nothing in this program redefines it.
#
# Crucially this rejects an `attr_reader`/`attr_accessor` definition
# too, which carries a real owner and NO irep -- the exact shape that
# makes a bare-name rule unsound: `Game::State#map`/
# `RPG2k::Scene::Battle#map` are both `attr_accessor :map` (the
# current Game::Map, not an Array at all), so "has no bytecode body"
# is NOT a safe stand-in for "cannot be redefined here".
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

def proven_array_source_scan(irep, idx, dest_reg, registry, annotated = nil)
  reg = dest_reg
  (idx - 1).downto(0) do |i|
    pin = irep.instructions[i]
    next unless pin
    # The block proc register (BLOCK writes dest+1 for n=0 calls)
    # sits between the call and its receiver write -- skip over it:
    # it is evidence FOR a region here, not a receiver writer.
    next if pin.op == 'BLOCK'
    next unless pin.args[/^R(\d+)/, 1] == reg

    # CORE_ARRAY_CHAIN: follow MOVE chains, exactly the way
    # trace_new_target's own backward walk already does, instead of
    # stepping over them. `OP_MOVE` is a verbatim register copy --
    # `regs[a] = regs[b]` (3rd/mruby/src/vm.c, CASE(OP_MOVE)), read
    # directly, not assumed -- so whatever wrote the SOURCE register
    # is exactly what this receiver holds, and the scan simply
    # continues on that register.
    #
    # This also closes a real hole in the previous `next unless
    # <send ops>` form: a MOVE writing the receiver register used to
    # be SKIPPED, leaving the scan free to walk further back and
    # latch onto an OLDER, already-overwritten `select`/`reject`/
    # `map` result on that same (reused) register and call the
    # receiver Array on that stale evidence. Registers are reused
    # aggressively (trace_type's own comment makes the same point),
    # so that was a wrong-answer path, not just an imprecise one.
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
    # SEND0/SSEND0 carry no `n=` field at all (confirmed against real
    # `mrbc -v`: a no-arg call is `SEND0 Ra :name`, never `SEND Ra
    # :name n=0`) -- absent means 0 args, not "unknown", so the `|| 0`
    # is the correct default, not a safe-miss fallback.
    argc = pin.args[/n=(\d+)/, 1]&.to_i || 0
    return 'Array' if block_carrying && CHAINED_ARRAY_METHODS.include?(called)
    return 'Array' if annotated&.call(called)
    return 'Array' if core_array_return?(called, block_carrying, registry, argc: argc)

    return nil
  end
  nil
end

# ---------------------------------------------------------------------------
# Step 6g: whole-program "this ivar always holds an instance of exactly
# this real class" analysis -- the object-reference analogue of
# IvarLayout, but deliberately never merged into it: a known object
# class is never a struct-field embedding candidate (still a real
# mrb_value pointing to a real heap object, nothing to unbox into a
# smaller C type) -- it only ever feeds compile_send's own
# devirtualization decision, which guards every use of a fact from here
# with a real runtime mrb_obj_class check (see compile_send's own
# comment) rather than trusting it unconditionally the way a purely
# static, Ruby-semantics-guaranteed fact (a fresh same-body `X.new`)
# safely can.
#
# Fixed-point for the same reason IvarLayout's own analysis is: one
# ivar's known class can depend on another already being known (an ivar
# set from `@other.some_getter`, where `some_getter` itself returns
# `@another_ivar`, would need a real return-type inference this
# prototype doesn't have -- out of scope here, see trace_new_target's own
# GETIV case, which only ever looks at *this* class's own ivars).
class ClassLayout
  UNKNOWN = :unknown

  def self.analyze(ireps, registry, class_annotations = {}, container_constants = {}, annotated_array_return = nil)
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
            # Never hand a poisoned (UNKNOWN) entry to trace_new_target's
            # own GETIV lookup -- it has no idea about this sentinel, and
            # would otherwise hand back the symbol :unknown as if it
            # were a real class name (harmless downstream -- no real
            # owner is ever literally that -- but sloppy to let through).
            known_so_far = classes[owner].reject { |_, c| c == UNKNOWN }
            # CHAINED_ACCESSOR_SUPPORT: `classes` (this whole method's own
            # owner -> {ivar => class_name} accumulator, still mid-sweep
            # and NOT yet UNKNOWN-filtered the way `known_so_far` just
            # above is) is threaded through as the FULL per-class table a
            # chained-accessor resolution needs to look up a DIFFERENT
            # class's own ivar hints -- trace_new_target's own new SEND
            # branch guards against reading a raw UNKNOWN entry back out of
            # it directly (see its own comment), so passing the
            # unfiltered, still-converging table here is sound and avoids
            # re-filtering it on every single SETIV site in this sweep.
            found = trace_new_target(irep, idx, src_reg, known_so_far, mand, arg_classes, owner: owner,
                                      class_layout: classes, registry: registry,
                                      container_constants: container_constants)
            # CORE_ARRAY_CHAIN: when the fresh-`.new`/literal trace misses,
            # ask the SAME chained fresh-Array question the block
            # recognizers already ask of a block receiver -- see
            # proven_array_source_scan's own comment for the full rule and
            # why each producer really does return a fresh Array.
            #
            # Why this is a sound *terminal* for a SETIV site specifically:
            # the scan only ever answers 'Array' when the value written
            # into the ivar came straight out of an expression that
            # allocates a NEW Array (`@actors = new_order.map { ... }`,
            # `@states = @states.select { ... }`), so the ivar genuinely
            # holds an Array after this assignment -- exactly the same
            # class of fact as the `ARRAY` literal terminal
            # (`@states = []`) trace_new_target already accepts one line
            # above, just reached through a call instead of an opcode.
            # Nothing is weakened: this runs ONLY where the existing trace
            # already gave up (nil), and the join below still poisons the
            # ivar to UNKNOWN the moment any OTHER site disagrees, so an
            # ivar that is an Array on one path and something else on
            # another is rejected exactly as before.
            #
            # `registry` is threaded through (it is already this method's
            # own parameter) because the core-producer half of the rule
            # re-checks every candidate name against the real whole-program
            # registry.
            #
            # ANNOTATED_ARRAY_RETURN_THREADING: `annotated_array_return` (a
            # 5th, optional parameter this method now accepts -- see its
            # own call site in the driver, which builds it from the exact
            # same MONO-keyed `# bc2cpp: (...) -> Array` lookup
            # CodeGen#annotated_array_return already performs for the block
            # recognizers' own identical chained-Array rule, see that
            # method's own comment for the full soundness argument) is
            # passed straight through to `proven_array_source_scan` as its
            # own `annotated` argument. Previously this call always passed
            # nil there, so a SETIV fed by a self-call to a hand-annotated,
            # bytecode-defined MONO method (`@equipment =
            # normalize_equipment(...)`, `@base = base_stats(1)`,
            # `@battle_commands = class_battle_commands` -- all three real,
            # measured `Game::Actor` sites that were poisoning their own
            # ivar to UNKNOWN before this change, per the whole-program
            # `CLASS_CANDIDATE` diagnostic) stayed UNKNOWN here even though
            # the exact same fact was already being trusted by the block
            # recognizers a few opcodes away in the very same method body.
            # Nothing about the annotation's own trust model changes: it is
            # still a hand-placed claim, still MONO-gated (a magic comment
            # sits on ONE irep, so it can only speak for a call site no
            # other same-named method in the whole program could also be
            # reaching), and still backstopped at every real consumer by a
            # runtime class check before any direct-call path is taken (see
            # this method's own header comment) -- this call site is simply
            # no longer arbitrarily withholding a fact the rest of the file
            # already relies on elsewhere.
            found ||= proven_array_source_scan(irep, idx, src_reg, registry, annotated_array_return)

            # NIL_TOLERANT_JOIN: a plain `@x = nil` SETIV site (real
            # bytecode shape confirmed directly against mrbc's own
            # disassembly: `LOADNIL Rn` immediately followed by `SETIV @x
            # Rn`) is evidence of NOTHING -- it neither proves nor
            # disproves any class this ivar might also hold on some other
            # path. Treating it as "disagreeing evidence" the same way an
            # opaque, unresolvable NON-nil write is treated (the `found ||=
            # UNKNOWN` fallback just below) permanently poisons the ivar
            # the moment `#initialize` merely nils out a field for a real
            # object assigned elsewhere -- confirmed to be the single
            # largest real source of poisoned CLASS_HINT entries. Skipping
            # the site outright (never recording it as either agreeing or
            # disagreeing evidence) is sound rather than merely convenient:
            # every consumer of this table already re-verifies the fact
            # with a real runtime `mrb_class_ptr(...) == mrb_obj_class(M,
            # elem)` guard before ever taking a direct-call path (see this
            # method's own comment a few lines up) and falls back to
            # ordinary `mrb_funcall` otherwise, so a genuinely-sometimes-
            # nil ivar with an otherwise-single-class hint is already
            # handled correctly at every real call site: the guard just
            # fails on the nil path, the same cost as any other guard miss,
            # never a wrong call. IvarLayout (struct EMBEDDING) is a
            # completely separate analysis and is deliberately NOT touched
            # by this: a raw C++ struct field has no room for "or nil" the
            # way a runtime-guarded devirtualization hint does, so an ivar
            # that's genuinely nilable stays correctly unembeddable there
            # regardless of this change.
            next if found.nil? && nil_literal_write?(irep, idx, src_reg)

            found ||= UNKNOWN

            before = classes[owner][ivar]
            # Two real sites disagreeing on the exact class permanently
            # poisons it to UNKNOWN -- never guess which one is right,
            # same "one bad site poisons the whole name" join IvarLayout
            # itself uses, and just as sticky across fixed-point passes
            # (UNKNOWN, once reached, is never overwritten by a later,
            # differently-ordered pass finding one real site again).
            merged = if before.nil?
                       found
                     elsif before == UNKNOWN || found == UNKNOWN || before != found
                       UNKNOWN
                     else
                       before
                     end
            if merged != before
              classes[owner][ivar] = merged
              changed = true
            end
          end
        end
      end
      break unless changed
    end

    classes
  end

  # The consumable half of `analyze`'s own raw result -- UNKNOWN entries
  # dropped, empty owners dropped. Split out this way (mirroring
  # ArrayElementLayout's own known/unknowns split below) precisely so the
  # poisoned entries survive long enough to be REPORTED: an ivar that came
  # out UNKNOWN is exactly the actionable candidate list a future round
  # (a widened trace_new_target rule, or a hand-placed annotation) needs --
  # see the `== ivar-class candidates (poisoned to unknown) ==` diagnostic.
  # Every existing caller of `ClassLayout.analyze` already expects exactly
  # this filtered shape (never a raw UNKNOWN value) -- the driver's own
  # call site is the only one updated to call `.known` immediately after
  # `.analyze`, so every downstream consumer (ArrayElementLayout.analyze,
  # CodeGen's own @class_layout, compile_send's TYPED/chained-accessor
  # paths) sees byte-identical content to before this split existed.
  def self.known(classes)
    classes.each_with_object({}) do |(owner, ivars), out|
      known = ivars.reject { |_, c| c == UNKNOWN }
      out[owner] = known unless known.empty?
    end
  end

  def self.unknowns(classes)
    classes.flat_map { |owner, ivars| ivars.select { |_, c| c == UNKNOWN }.keys.map { |i| "#{owner}#@#{i}" } }
  end
end

# ---------------------------------------------------------------------------
# Step 6g-bis: ELEMENT_CLASS_SUPPORT -- the second dimension of the same
# whole-program ivar fact Step 6g above establishes. ClassLayout answers
# "this ivar always holds exactly this one class" and, for a great many
# real game ivars, that answer is the singularly uninformative `Array`
# (`Game::Party#@actors`, `Game::Troop#@members`, `Game::State#@timers`,
# ... -- see the `== known-ivar-class hints ==` diagnostic, where Array is
# by far the most common hint). This analysis answers the question that
# actually pays off at a devirtualization site: "and every element of THAT
# array is exactly this one class".
#
# Why it matters, concretely: once a block recognizer proves a receiver is
# an Array and inlines the loop, the per-element loop register is just an
# opaque `mrb_value`, so `party.each { |a| a.dead? }` keeps a full POLY
# `mrb_funcall` per element per iteration even though `a` is provably
# always a `Game::Actor`. With this table the emitters devirtualize that
# call the exact same runtime-guarded way compile_send's own TYPED/
# IVAR_ACCESSOR paths do.
#
# SOUNDNESS, stated plainly and without overclaiming. This is NOT a proof,
# and it is not presented as one -- for exactly the reason ClassLayout's
# own header already gives for its scalar hints, plus one more that is
# specific to arrays:
#   - Like ClassLayout, the sweep only sees this program's own bytecode.
#     An ivar written from outside the compiled set is invisible to it.
#   - UNLIKE a scalar ivar, an Array is a mutable object other code can
#     hold a reference to: `Game::Party#actors` is an `attr_reader`, so
#     `party.actors.push(x)` anywhere in the program mutates the very
#     array this table describes, through a receiver this sweep has no way
#     to attribute back to `Game::Party#@actors`. The sweep attributes
#     every mutation site it CAN (see ARRAY_ELEMENT_WRITERS below -- a
#     mutator whose receiver backward-traces to a real `GETIV @x` in the
#     owner's own body) and poisons on any it can resolve but disagree
#     with; a mutation through an aliased reference it cannot attribute is
#     a real, named residual it does not pretend to cover.
# What makes that residual harmless rather than a correctness hole is the
# SAME thing that makes every ClassLayout hint safe: every single consumer
# re-checks the fact at runtime with a real `mrb_class_ptr(...) ==
# mrb_obj_class(M, elem)` guard before taking the direct-call path, and
# falls back to an ordinary `mrb_funcall` otherwise. A wrong entry in this
# table therefore costs one failed pointer comparison and a normal dynamic
# dispatch -- never a wrong call, never a miscompile. This table is
# consumed ONLY for that guarded devirtualization; it is never embedded,
# never used to pick a C type, and never used to skip a check.
#
# Fixed-point, ten passes, same shape and same sticky UNKNOWN join as
# ClassLayout: one array's element class routinely depends on another's
# (`@actors = new_order.map { |i| @actors[i] }` is literally
# self-referential), and UNKNOWN once reached is never un-poisoned by a
# later, differently-ordered pass.
# ---------------------------------------------------------------------------

# ELEMENT_CLASS_SUPPORT: core methods that return an Array whose elements
# are a SUBSET of the receiver's own elements -- so the result's element
# class is exactly the receiver's element class, whatever that is. Each
# one read directly against this repo's own pinned 3rd/mruby (831da26b),
# never assumed:
#   - `compact` (mruby-array-ext/src/array.c `ary_compact`): a `dup` with
#     the nils deleted -- strictly a subset.
#   - `uniq`: `self.dup` with duplicates dropped / `__uniq` -- subset.
#   - `sort`: `self.dup.sort!` (mrblib/array.rb) -- a PERMUTATION, so the
#     same multiset of elements.
#   - `reverse`: `mrb_ary_new_from_values` over the same values -- a
#     permutation too.
#   - `dup`: `mrb_obj_dup` -- a shallow copy, same element objects. Note
#     `dup` is receiver-dependent for the *Array-ness* question (which is
#     why CORE_ARRAY_RETURN_METHODS deliberately excludes it), but this
#     rule only ever runs on a receiver whose own element class already
#     resolved, i.e. one already known to be an Array, so the narrower
#     question asked here is well-founded where the broader one was not.
#   - `first`/`last` WITH an argument, `take`/`drop`: `ary_subseq`/
#     `mrb_ary_new_from_values` over a contiguous run of the receiver's
#     own values -- subset. (The no-argument `first`/`last` return an
#     ELEMENT, not an Array; they are handled by the separate
#     `ARRAY_ELEMENT_INDEXERS` rule below, not here.)
#   - `select`/`reject` WITH a block: mruby's own definitions push the
#     ELEMENT itself (`mrblib/array.rb`'s `select`/`find_all` and
#     `reject`), never a derived value -- subset. Block-gated for the
#     identical reason CHAINED_ARRAY_METHODS is (a blockless
#     `select`/`reject` returns an enumerator, not an Array).
# `map`/`collect`/`flat_map` are deliberately absent: those REPLACE each
# element with the block's own yielded value, so they are handled by
# their own block-return rule instead.
ARRAY_ELEMENT_PRESERVING = %w[compact uniq sort reverse dup].freeze
ARRAY_ELEMENT_PRESERVING_NEEDS_ARG = %w[first last take drop].freeze
ARRAY_ELEMENT_PRESERVING_NEEDS_BLOCK = %w[select reject].freeze

# ELEMENT_CLASS_SUPPORT: core methods that hand back one ELEMENT of the
# receiver, so a value produced by one of them has the receiver's own
# element class. `[]` with exactly one integer-ish argument
# (`a[i]` -- `a[i, n]` and `a[range]` return an Array instead and are
# excluded by the argument count), `first`/`last` with NO argument (the
# exact complement of the `NEEDS_ARG` rule above -- both read against
# `mrb_ary_first`/`mrb_ary_last` in src/array.c), `sample`, `min`, `max`.
# Only `[]`/`first`/`last` actually fire in this program today; the rest
# are listed because the rule is about the shape, not about which names
# happen to be reachable this week, and each was read the same way.
ARRAY_ELEMENT_INDEXERS_NEEDS_ARG = %w[[] at fetch].freeze
ARRAY_ELEMENT_INDEXERS_NO_ARG = %w[first last sample min max].freeze

# ELEMENT_CLASS_SUPPORT: every method that can INTRODUCE a new element
# into an array in place. The sweep must see agreement from all of them,
# not just from the SETIV sites, or `@actors = []` followed by
# `@actors.push(whatever)` would "prove" an element class off an empty
# literal that says nothing at all. Split by how the element values are
# reached at the call site:
#   - `push`/`<<`/`unshift`: every positional argument IS an element.
#   - `insert`: `insert(index, *values)` -- every argument after the
#     first is an element.
#   - `[]=`: `a[i] = v` (exactly two arguments) makes `v` an element;
#     `a[i, n] = v` / `a[range] = v` (three) splice an ARRAY in instead,
#     a shape this rule does not model, so it poisons.
#   - `concat`/`replace`: the single argument is itself an Array, so the
#     element fact comes from asking this same scan about THAT array.
# Anything else in this list with an unmodeled shape (a splat call, a
# wrong argument count, `fill`, `collect!`/`map!`/`flatten!`, ...)
# poisons the ivar to UNKNOWN rather than being quietly ignored -- an
# element writer this sweep cannot read is exactly the case where
# claiming a uniform element class would be a guess.
ARRAY_ELEMENT_WRITERS = %w[push << unshift insert []= concat replace fill collect! map! flatten! sort_by!].freeze

# ELEMENT_CLASS_SUPPORT: "what is the element class of the Array-valued
# expression in `reg` at `idx`?" -- the element-dimension analogue of
# proven_array_source_scan above, and deliberately built the same way:
# one backward scan to the nearest real write of the register, MOVE
# chains followed through (same stale-register reasoning that scan's own
# comment spells out), and a hard nil on anything not explicitly
# modelled. `ctx` carries the tables this needs (see
# ArrayElementLayout.analyze, its only caller, for how each is built).
#
# Returns a class-name String, or nil for "unknown" -- and nil is always
# a safe answer: the caller turns it into a poisoned (UNKNOWN) ivar.
def array_element_source_scan(irep, idx, dest_reg, ctx, depth = 0)
  # Depth cap: every recursive arm below either walks to a strictly
  # smaller instruction index or steps into a strictly smaller expression,
  # but two ivars can still reference each other across the fixed point
  # (`@a = @b.compact`, `@b = @a.compact`), so the cap makes termination a
  # property of this function alone rather than of the table it reads.
  return nil if depth > 8

  reg = dest_reg
  (idx - 1).downto(0) do |i|
    insn = irep.instructions[i]
    next unless insn

    # Same reasoning as proven_array_source_scan's own BLOCK skip: the
    # block proc register sits between a block-carrying call and its
    # receiver write, and is evidence FOR the shape rather than a writer.
    next if insn.op == 'BLOCK'
    next unless insn.args[/^R(\d+)/, 1] == reg

    case insn.op
    when 'MOVE'
      src = insn.args.scan(/R(\d+)/).flatten[1]
      return nil unless src

      reg = src
      next
    when 'ARRAY', 'ARRAY2'
      # "ARRAY R3 2" -- N consecutive registers starting at Rd (see
      # compile_insn's own ARRAY codegen comment for the real OP_ARRAY
      # semantics this reads).
      #
      # An EMPTY literal (`@members = []`, n == 0) is VACUOUS, not
      # unknown, and the distinction is load-bearing rather than
      # pedantic. The claim this whole analysis makes is "every element
      # of this array is exactly X"; an array with no elements satisfies
      # that for every X, so an empty literal cannot contradict any other
      # site and must not poison one. Treating it as unknown instead was
      # measured to poison essentially the entire table on the first
      # pass, because nearly every real array ivar in this program is
      # born as `@x = []` in `#initialize` and filled in later
      # (`Game::Troop#@members`, `Game::Battle#@log`,
      # `RPG2k::Scene::Map#@events`, ...). VACUOUS is skipped by the join
      # rather than merged into it, so an ivar whose ONLY site is an
      # empty literal still ends up with no entry at all -- silence, not
      # a claim.
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
  nil
end

# ELEMENT_CLASS_SUPPORT: the SEND arm of the scan above, split out purely
# for readability -- `insn` is the instruction that wrote `reg`, at index
# `i`.
def send_element_class(irep, i, reg, insn, ctx, depth)
  # Same charset as compile_send's own name extraction (see its comment).
  name = insn.args[/:([\w+\-*\/<>=!?\[\]&|^~%@]+)/, 1]
  return nil unless name

  block_carrying = %w[SENDB SSENDB].include?(insn.op)
  # SEND0/SSEND0 never print an "n=" field at all -- a real, always-zero
  # argument count, the same fact proven_array_source_scan's own comment
  # already establishes against real `mrbc -v` output.
  argc = insn.args[/n=(\d+)/, 1]&.to_i || 0
  self_recv = %w[SSEND SSEND0 SSENDB].include?(insn.op)

  # A hand-placed `-> Array<Klass>` claim, re-validated against the real
  # whole-program registry the same way core_array_return? re-validates a
  # core name: the annotation sits on ONE irep, so it can only be trusted
  # when that irep is the ONLY definition of the name in the whole program
  # (otherwise this call site might be reaching a different method that
  # merely shares the name).
  annotated = ctx[:annotated_element]&.call(name)
  return annotated if annotated

  # An element-preserving chain hands back the receiver's own elements, so
  # the answer is whatever THIS send's own receiver is an array of. A
  # self-receiver (`SSEND`) has no register to trace, so it stops here.
  preserving =
    ARRAY_ELEMENT_PRESERVING.include?(name) ||
    (ARRAY_ELEMENT_PRESERVING_NEEDS_ARG.include?(name) && argc >= 1) ||
    (ARRAY_ELEMENT_PRESERVING_NEEDS_BLOCK.include?(name) && block_carrying)
  if preserving
    return nil if self_recv

    return array_element_source_scan(irep, i, reg, ctx, depth + 1)
  end

  # `map`/`collect` with a real block REPLACES every element with the
  # block's own yielded value, so the result's element class is the class
  # of that value -- read out of the block's own irep (see
  # block_return_class). `flat_map` is excluded on purpose: its yielded
  # value is spliced rather than pushed, so the element class is the
  # element class of the yielded ARRAY, one level further in than this
  # rule models.
  if block_carrying && %w[map collect].include?(name) && argc.zero?
    block_irep = adjacent_block_irep(irep, i, reg, ctx)
    return nil unless block_irep

    return block_return_class(block_irep, ctx, depth + 1)
  end

  # CHAINED_ACCESSOR_SUPPORT, element dimension: `@state.party.actors` --
  # a plain `attr_reader` read whose receiver is itself traceable to an
  # exact class. Identical three-part check to trace_new_target's own
  # chained-accessor branch (see its comment): the receiver resolves to a
  # real class R, R really does define this name as an `:ivar_accessor`
  # (so the call is a bare ivar read and nothing else), and R's own entry
  # in THIS table names an element class for that same ivar.
  return nil if self_recv || argc.positive? || block_carrying

  recv_class = traced_owner(irep, i, reg, ctx)
  return nil unless recv_class

  accessor = ctx[:registry][name]&.find { |md| md.owner == recv_class && md.kind == :ivar_accessor }
  return nil unless accessor

  ivar_element_hint(recv_class, name, ctx)
end

# ELEMENT_CLASS_SUPPORT: read one entry out of the (still-converging)
# element table without ever handing back the UNKNOWN sentinel as if it
# were a real class name -- the same discipline trace_new_target's own
# chained-accessor branch applies to ClassLayout's in-progress table, and
# `key?` for the same reason (the table is a `Hash.new { {} }`, so a plain
# `[]` read on an untouched owner would silently insert an entry and
# perturb the diagnostic's own ordering).
def ivar_element_hint(owner, ivar, ctx)
  table = ctx[:elements]
  return nil unless owner && ivar && table&.key?(owner)

  hint = table[owner][ivar]
  return nil if hint.nil? || hint == ArrayElementLayout::UNKNOWN

  hint
end

# ELEMENT_CLASS_SUPPORT: the child irep a block-carrying send at index `i`
# takes its block from -- the same `BLOCK R(a+1) I[k]` adjacency every
# block recognizer in this file already checks (confirmed against real
# `mrbc -v` output there), re-checked here rather than assumed because
# this scan reaches a SENDB from a completely different direction.
def adjacent_block_irep(irep, i, recv_reg, ctx)
  block_insn = i.positive? ? irep.instructions[i - 1] : nil
  return nil unless block_insn && block_insn.op == 'BLOCK'
  return nil unless block_insn.args[/^R(\d+)/, 1] == (recv_reg.to_i + 1).to_s

  k = block_insn.args[/I\[(\d+)\]/, 1]
  return nil unless k

  label = irep.reps[k.to_i]
  label && ctx[:ireps][label]
end

# ELEMENT_CLASS_SUPPORT: the class of the value a `map` block yields --
# i.e. the class every element of the resulting Array has. A block's
# yielded value is whatever its own `RETURN` hands back (a bare `next`
# compiles to `RETNIL`, confirmed in compile_block_body_insn's own
# comment), so every RETURN in the block body must agree, and any other
# return form (`RETNIL`/`RETFALSE`/`RETTRUE`, a `break`) is a value whose
# class is not an object class at all -- unknown, so the whole answer is
# unknown. A block with no RETURN at all likewise answers nothing.
def block_return_class(block_irep, ctx, depth)
  # A block's own `self` is its enclosing method's self (real mruby
  # semantics, the same fact emit_each_inline relies on to alias R0
  # straight to `self`), so the owner and its ivar hints carry over
  # unchanged. Its PARAMETERS do not: they are block params, not method
  # arguments, so the argument-annotation terminal is switched off
  # (`mand: 0` makes trace_new_target's own `pos.between?(1, mand)`
  # fallback unreachable) rather than left to misread a block param as an
  # annotated method argument.
  irep_return_class(block_irep, ctx.merge(arg_classes: nil, mand: 0), depth)
end

# ELEMENT_CLASS_SUPPORT: trace a register to a real class name the
# whole-program REGISTRY actually knows, not merely to whatever token the
# source wrote.
#
# trace_new_target hands back a bare, unqualified name for a bare
# `GETCONST` receiver -- `Actors.new(db)` inside `Game::Party` traces to
# the literal string "Actors", while every MethodDef in the registry
# spells that class "Game::Actors" (build_registry's own `::`-joined
# owner). The two never compare equal, so an unresolved bare name is a
# dead hint: it can never match a candidate at a devirtualization site,
# and it would show up in the `== known-ivar-class hints ==`-style
# diagnostic looking like a fact when nothing can ever use it. (Real,
# measured: a first cut of this analysis emitted `Array<EnemyAction>` and
# `Array<Window>` hints, neither of which is a registry owner, alongside
# a silently-lost `Game::Party#@roster (Actors)`.)
#
# This resolves a bare name the same way real Ruby does and the same way
# compile_insn's own GETCONST codegen and trace_new_target's own
# DIRECT_CONSTRUCT_TARGETS branch already do: walk the enclosing owner's
# lexical nesting INNERMOST FIRST (so an inner `Game::Party::Actors`
# would win over an outer `Game::Actors`, exactly like Module.nesting),
# and accept only a candidate the registry really has. Anything that
# doesn't resolve returns nil -- an honest "unknown", never a guess and
# never a dead hint.
#
# Deliberately scoped to this analysis rather than pushed down into
# trace_new_target itself, even though that function has the same gap:
# changing what IT returns would change the TYPED devirtualization
# decision at every call site in the program at once. Named follow-up,
# same as ElementAnnotations' own: "ELEMENT_CLASS_SUPPORT: teach
# trace_new_target's bare-GETCONST case this same registry-validated
# lexical resolution".
def traced_owner(irep, idx, reg, ctx)
  cls = trace_new_target(irep, idx, reg, ctx[:ivar_classes], ctx[:mand], ctx[:arg_classes],
                         owner: ctx[:owner], class_layout: ctx[:class_layout], registry: ctx[:registry])
  resolve_owner_name(cls, ctx)
end

def resolve_owner_name(name, ctx)
  return nil unless name

  known = ctx[:known_owners]
  return name if known.include?(name)
  # Already namespace-qualified and still unknown: there is no lexical
  # search that could rescue it, so this is a real miss.
  return nil if name.include?('::')

  nesting = ctx[:owner].to_s.sub(/\.singleton\z/, '').split('::')
  nesting.length.downto(1) do |n|
    candidate = "#{nesting.first(n).join('::')}::#{name}"
    return candidate if known.include?(candidate)
  end
  nil
end

# ELEMENT_CLASS_SUPPORT: this irep's own mandatory arity, read the same
# way ClassLayout.analyze reads it (the ENTER instruction's first `:`
# field), with 0 for a body that has none.
def mand_of(ireps, label)
  enter = ireps.fetch(label).instructions.find { |i| i.op == 'ENTER' }
  enter ? enter.args.split(':').first.to_i : 0
end

# ELEMENT_CLASS_SUPPORT: every child irep reachable from `label` through
# `reps`, transitively (a block inside a block inside a method). `seen`
# makes this terminate on any self- or mutually-referential `reps` table
# rather than trusting one not to exist.
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

# ELEMENT_CLASS_SUPPORT: the one class every `RETURN` in this irep hands
# back, or nil when they disagree or any of them is unresolvable. Shared
# by block_return_class (a `map` block's yielded value) and
# mono_fresh_return_class (a whole method's result).
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
      # A nil/false/true result is not an object class this mechanism can
      # name, and a non-local return leaves through a path this scan is
      # not reading -- either way the answer is honestly unknown.
      return nil
    end
  end
  found
end

# ELEMENT_CLASS_SUPPORT: real, inferred return-class evidence -- no
# annotation involved -- for the one shape where it is a hard Ruby
# guarantee rather than a claim: a method with exactly ONE definition in
# the whole program (so dispatch cannot reach anything else -- the same
# argument monomorphic_target's own gate makes) whose every `RETURN`
# provably hands back a fresh `Klass.new`. `X.new` never allocates a
# subclass in disguise (trace_new_target's own comment establishes this),
# so where this fires it is as strong as the fresh-`.new` terminal that
# function already trusts, just observed one call frame further out.
#
# Real example this exists for: `Game::Troop#member(db, m)` is literally
# `Enemy.new(db, m.enemy_id, m.x, m.y, m.invisible)` and is the sole
# writer into `Game::Troop#@members` (`@members << member(db, m)`), so the
# whole troop-members element fact falls out of this with nothing
# hand-placed at all.
# ELEMENT_CLASS_SUPPORT: the return class of a call whose RECEIVER is
# traceable to one exact class -- class-exact resolution, not name-keyed,
# and that difference is what makes it usable at all for the names that
# matter here.
#
# `Game::Party#initialize` builds `@actors` as
# `ids.reject { ... }.map { |i| @roster[i] }.compact`, so the element
# class is whatever `@roster[i]` hands back. `@roster` is a
# `Game::Actors` and `Game::Actors#[]` really does return exactly a
# `Game::Actor` (or nil -- see ElementAnnotations' own NIL note) -- but
# `:[]` is one of the most POLY names in the whole program (Array, Hash,
# LCF::Array1D/Array2D, Game::Switches, ... plus mruby's own natives), so
# the name-MONO lookups above can never speak for it and never will. What
# IS available is exactly what compile_send's own TYPED path uses: trace
# this send's own receiver to an exact class, then look up the
# class-exact MethodDef for the name on THAT class.
#
# Two sources are accepted for the class-exact definition, in order: a
# hand-placed `-> Klass` return annotation on it, or -- with nothing
# hand-placed at all -- a body that provably returns a fresh `Klass.new`
# on every path. Both are guarded downstream exactly like every other
# fact in this file.
def receiver_scoped_return_class(irep, i, recv_reg, name, ctx, depth)
  return nil if depth > 8

  recv_class = traced_owner(irep, i, recv_reg, ctx)
  return nil unless recv_class

  class_scoped_return_class(recv_class, name, ctx, depth)
end

# ELEMENT_CLASS_SUPPORT: the shared tail of the rule above -- given an
# exact receiver class, what does `name` return on it?
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

# ELEMENT_CLASS_SUPPORT: the class of `self` inside a method of `owner`,
# when that can be answered exactly -- needed because a great deal of
# real populating code is an implicit-self call, not an explicit-receiver
# one: `Game::Troop#initialize`'s only writer into `@members` is
# `@members << member(db, m)`, and `:member` is POLY program-wide
# (`Game::Battle::Combatant` defines one too), so no name-keyed lookup can
# ever speak for it.
#
# "self is exactly `owner`" is NOT free: if any class in the program
# inherits from `owner`, then `self` inside one of `owner`'s own methods
# may be an instance of that subclass, and the call could dispatch to a
# subclass override instead. So this answers only when a real
# whole-program check says no such subclass exists -- `subclassed` is
# every name that appears as SOMEBODY's declared superclass
# (build_registry's own resolve_superclass_ref result, the same table
# compile_insn's own SUPER case reads). A class with any subclass at all
# is refused outright rather than reasoned about per-method: cheap,
# checked, and re-evaluated from the real registry on every run, so a
# future `class Foo < Game::Troop` silently withdraws the fact instead of
# leaving a stale claim behind.
#
# A `.singleton` pseudo-owner is refused too: its `self` is the class
# object, not an instance, so an instance-method lookup on it would be
# reasoning about the wrong object entirely.
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

# ELEMENT_CLASS_SUPPORT: "what class is the SCALAR value in `reg` at
# `idx`?" -- the value-level companion to array_element_source_scan.
# Three sources, in order:
#   1. trace_new_target, unchanged and untouched: a fresh `X.new`, a GETIV
#      of a ClassLayout-known ivar, a `# bc2cpp: (Klass)` argument
#      annotation, or a chained accessor. This is the workhorse.
#   2. a hand-placed `-> Klass` return-class annotation (see
#      ElementAnnotations) -- the leaf fact nothing else in this file can
#      supply, since there is no return-type inference here at all.
#   3. an ARRAY INDEXER on an array whose own element class is already
#      known (`@actors[i]`, `list.first`) -- the exact inverse of
#      array_element_source_scan, and the rule that makes a
#      self-referential reorder (`@actors = new_order.map { |i|
#      @actors[i] }`) resolve to agreement instead of poison.
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

    # ELEMENT_CLASS_SUPPORT: `a[i]` is NOT a `SEND :[]` in real bytecode
    # -- mrbc emits a dedicated index opcode and the VM only falls back to
    # a real `:[]` send for a receiver that is neither Array nor Hash
    # (confirmed against this file's own GETIDX/GETIDX0/AREF codegen,
    # which mirrors src/vm.c's fast paths). So an element read has to be
    # recognized by OPCODE here, not by method name; matching only the
    # name was measured to miss every real `@actors[i]`/`@roster[i]` site
    # in the program. The three shapes differ only in where the RECEIVER
    # register sits:
    #   GETIDX  R2 (R3)      -- R[a] = R[a][R[a+1]]: receiver is R2 itself.
    #   GETIDX0 R7 R4[0]     -- R[a] = R[b][0]:      receiver is R4.
    #   AREF    R2 R6 0      -- R[a] = R[b][c]:      receiver is R6.
    if %w[GETIDX GETIDX0 AREF].include?(insn.op)
      recv = insn.op == 'GETIDX' ? cur : insn.args.scan(/R(\d+)/).flatten[1]
      return nil unless recv

      hit = array_element_source_scan(irep, i, recv, ctx, depth + 1)
      return hit if hit && hit != ArrayElementLayout::VACUOUS
      # The receiver is not an array this analysis knows the elements of.
      # For GETIDX/GETIDX0 that is not the end of the road: vm.c's own
      # non-Array/non-Hash path is a REAL `:[]` send, so `@roster[i]`
      # (a `Game::Actors`, not an Array) resolves exactly the way the
      # equivalent explicit send would. AREF is excluded on purpose --
      # its non-Array behavior is "index 0 yields the receiver itself",
      # a destructuring shape, not a `:[]` dispatch.
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
    # An indexer read on an array whose element class is already known.
    # Skipped for an implicit-self receiver (no register to ask about),
    # and allowed to MISS rather than to fail: `@roster[i]` matches this
    # shape syntactically but `@roster` is a `Game::Actors`, not an
    # Array, so the element table has nothing for it -- that has to fall
    # through to the receiver-scoped rule below, not end the search.
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

    # Last resort: a name exactly one definition in the whole program
    # owns, whose body provably manufactures one exact class on every
    # path -- no receiver reasoning needed at all.
    mono_fresh_return_class(name, ctx, depth)
  end
  nil
end

class ArrayElementLayout
  UNKNOWN = :unknown
  # "this site provably introduces NO elements at all" -- see the ARRAY
  # arm of array_element_source_scan for why an empty literal has to be
  # kept apart from an unreadable one.
  VACUOUS = :vacuous

  # owner -> {ivar_name => element class name}, for every ivar ClassLayout
  # has ALREADY proved always holds an `Array`. Restricting the sweep to
  # those is not an optimization: an element claim about an ivar that
  # isn't reliably an Array in the first place could never be consumed
  # (every consumer sits behind a recognizer that has already proved its
  # receiver is an Array), and sweeping the rest would only manufacture
  # entries nothing can use.
  def self.analyze(ireps, registry, class_layout, class_annotations, element_annotations, superclass_of = {})
    methods_of = Hash.new { |h, k| h[k] = [] }
    registry.each_value { |defs| defs.each { |d| methods_of[d.owner] << d.irep if d.irep } }
    # Same `known_owners` set every other annotation reader gates on --
    # the real classes this closed world has, used here by
    # resolve_owner_name to turn a bare `GETCONST` token into a name the
    # registry can actually be asked about.
    known_owners = Set.new(registry.values.flatten.map(&:owner))
    # Every class name that some OTHER class declares as its superclass --
    # see self_receiver_class for why a class with any subclass at all is
    # refused as an exact `self` type. `:none` (no explicit superclass)
    # and an unrecognized/computed expression are not names, so they are
    # dropped rather than counted.
    subclassed = Set.new(superclass_of.values.select { |v| v.is_a?(String) })

    # name -> element class / return class, but ONLY for a name exactly one
    # definition in the whole program owns. Same whole-program
    # re-validation core_array_return? performs on a vetted core name, and
    # the same MONO-keying argument annotated_array_return's own comment
    # makes: a magic comment sits on one real irep, so it can only speak
    # for a call site when no other method could be the one being called.
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
          # ELEMENT_CLASS_SUPPORT: sweep the method's own body AND every
          # block body nested inside it. This is load-bearing, not
          # thoroughness for its own sake: real populating code very often
          # lives in a block rather than in the method itself --
          # `Game::Troop#initialize`'s only writer into `@members` is
          # `row.members.each { |_, m| @members << member(db, m) }`, i.e.
          # inside a child irep the registry never lists (only top-level
          # `def` bodies get MethodDefs). A sweep that stopped at the
          # method body would see `@members = []` and nothing else, and
          # would then have to poison on an empty literal while the real
          # writer sat one frame down, unexamined. Walking `reps`
          # transitively is what makes "EVERY site that populates this
          # array" an accurate description of what this sweep checks.
          #
          # A block's `self` is its enclosing method's self, so `owner`
          # and its ivar hints carry straight over; its parameters are not
          # method arguments, so `mand`/`arg_classes` are zeroed for the
          # nested ireps exactly the way block_return_class zeroes them.
          sweep = [[label, mand_of(ireps, label), class_annotations[label]&.args]]
          nested_block_labels(ireps, label).each { |bl| sweep << [bl, 0, nil] }

          sweep.each do |(cur_label, mand, arg_classes)|
            irep = ireps.fetch(cur_label)
            ctx = { owner: owner, registry: registry, class_layout: class_layout, ireps: ireps,
                    class_annotations: class_annotations, element_annotations: element_annotations,
                    known_owners: known_owners, subclassed: subclassed,
                    ivar_classes: (class_layout[owner] || {}), mand: mand,
                    arg_classes: arg_classes, elements: elements,
                    annotated_element: annotated_element, annotated_ret_class: annotated_ret_class }

            irep.instructions.each_with_index do |insn, idx|
              found = nil
              ivar = nil
              if insn.op == 'SETIV'
                ivar = insn.args[/@(\w+)/, 1]
                next unless array_ivars.include?(ivar)

                found = array_element_source_scan(irep, idx, insn.args[/R(\d+)/, 1], ctx)
              # SSEND/SSENDB deliberately excluded: their receiver is the
              # implicit self, so the `^R` register in the disassembly is the
              # DESTINATION, not a receiver to backward-trace -- feeding it to
              # mutated_ivar_target would be reading an unrelated register.
              elsif %w[SEND SEND0 SENDB].include?(insn.op)
                name = insn.args[/:([\w+\-*\/<>=!?\[\]&|^~%@]+)/, 1]
                next unless name && ARRAY_ELEMENT_WRITERS.include?(name)

                recv = insn.args[/^R(\d+)/, 1]
                ivar = mutated_ivar_target(irep, idx, recv)
                next unless ivar && array_ivars.include?(ivar)

                found = written_element_class(irep, idx, insn, recv, name, ctx)
              elsif insn.op == 'SETIDX'
                # ELEMENT_CLASS_SUPPORT: `@actors[0] = actor` is an
                # OP_SETIDX, not a `SEND :[]=` -- the same opcode-not-name
                # point element_value_class's own GETIDX arm makes, for
                # the writing direction. "SETIDX R4 (R5) (R6)" is
                # `R[a][R[a+1]] = R[a+2]`, so the receiver is R4 and the
                # element being written is R6. Missing this would have let
                # `Game::Party#promote_to_leader`'s own slot-0 assignment
                # introduce an unexamined element behind the sweep's back.
                recv, _i_reg, val = insn.args.scan(/R(\d+)/).flatten
                next unless recv && val

                ivar = mutated_ivar_target(irep, idx, recv)
                next unless ivar && array_ivars.include?(ivar)

                found = element_value_class(irep, idx, val, ctx, 1)
              else
                next
              end

              # A provably element-free site (`@x = []`) is skipped
              # entirely -- it neither confirms nor contradicts, so it
              # must not reach the join in either direction.
              next if found == VACUOUS

              found ||= UNKNOWN
              before = elements[owner][ivar]
              # Identical sticky join to ClassLayout's own: two sites that
              # disagree, or one site that cannot be read at all, poison the
              # ivar permanently. Never a majority vote, never "the one I
              # understood wins".
              merged = if before.nil?
                         found
                       elsif before == UNKNOWN || found == UNKNOWN || before != found
                         UNKNOWN
                       else
                         before
                       end
              if merged != before
                elements[owner][ivar] = merged
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

  # The consumable half of `analyze`'s own raw result -- UNKNOWN entries
  # dropped, empty owners dropped. Split out (rather than filtered inside
  # `analyze`, the way ClassLayout does it) precisely so the poisoned
  # entries survive long enough to be REPORTED: an Array ivar that came
  # out UNKNOWN is exactly the actionable candidate list a future round
  # (or a hand-placed `-> Array<Klass>` / `-> Klass` annotation) needs,
  # the same role `report_annotation_candidates` already plays for opaque
  # incoming arguments. See the `== array-element candidates ==`
  # diagnostic.
  def self.known(table)
    table.each_with_object({}) do |(owner, ivars), out|
      known = ivars.reject { |_, c| c == UNKNOWN }
      out[owner] = known unless known.empty?
    end
  end

  def self.unknowns(table)
    table.flat_map { |owner, ivars| ivars.select { |_, c| c == UNKNOWN }.keys.map { |i| "#{owner}#@#{i}" } }
  end
end

# ELEMENT_CLASS_SUPPORT: which ivar (if any) does the receiver of an
# in-place array mutation actually name? Backward-scans the receiver
# register to a real `GETIV @x` in this same body, following MOVE chains,
# and bails to nil on anything else. nil means "this mutator is on some
# other array" -- the sweep then simply doesn't attribute it, which is
# exactly the documented residual in this section's own header (a mutation
# reached through an aliased reference is invisible), NOT a claim that no
# mutation happened.
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

# ELEMENT_CLASS_SUPPORT: the element class one in-place mutation writes
# into the array, or nil (-> poison) for any shape this doesn't model.
# See ARRAY_ELEMENT_WRITERS' own comment for the per-name argument
# layout each branch here reads.
def written_element_class(irep, idx, insn, recv, name, ctx)
  # A splat call site prints "n=*" (mrbc's own CALL_MAXARGS sentinel, the
  # same shape compile_send's own n_match comment documents) -- no fixed
  # register list exists for it, so it can only poison.
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

      # The argument is itself an Array, so the element fact is that
      # array's own element class -- the same question, asked one level
      # in, through the same scan.
      return array_element_source_scan(irep, idx, arg_regs.first, ctx, 1)
    end
  return nil if value_regs.nil? || value_regs.empty?

  classes = value_regs.map { |r| element_value_class(irep, idx, r, ctx, 1) }
  return nil if classes.any?(&:nil?) || classes.uniq.size != 1

  classes.first
end

# ---------------------------------------------------------------------------
# Step 6e: annotation-candidate report -- diagnostic only, never consulted by
# codegen. Finds every SETIV site whose source register, tracing back
# through MOVE chains, was *never* written by anything in this method body
# (a true opaque incoming argument in a mandatory-arg position) and isn't
# already resolved by ArgTypes or an existing annotation -- exactly the set
# a magic comment could unlock, and nothing else can (this deliberately
# doesn't try to guess whether the argument really is always a Fixnum in
# practice; it only finds where annotating one, if true, would matter).
# ---------------------------------------------------------------------------

# Like IvarLayout.trace_type's own backward scan, but stops (returns nil) at
# *any* writer instead of type-classifying it -- a non-nil result means
# `reg` (after following MOVE chains) was never written before `idx`: a bare
# incoming argument, not a value already known some other way.
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

# This prototype's whole calling convention (a typed _impl taking each
# mandatory arg as its own mrb_value parameter) only models plain
# mandatory arguments. ENTER's full aspec is
# mandatory1:optional:rest:mandatory2:keyword:kwrest:block -- a method
# with anything nonzero past the first field (`def foo(n = 0)`, `*args`,
# keywords, an explicit `&block`) doesn't fit that shape. Found by
# running against real code: Game::State#timer(n = 0) compiled as
# 0-argument (only the mandatory-count field was ever read), so a real
# call site passing the optional explicitly (`timer(0)`) generated a
# direct call with one argument too many -- a real arity mismatch, not
# just an unsupported-opcode gap. Top-level (not just a CodeGen method) so
# report_annotation_candidates below can share the exact same rule
# drop_unsafe_embeddings itself uses, rather than silently overcounting
# candidates a real build would refuse to embed anyway.

# Native, closed-world RGSS classes backed by mruby-rgss/src/lib.cxx's own
# DataType<T> template that a `SEND :new` call site can be devirtualized
# straight into (compile_send's own "MONO :new -> direct native construct"
# path, below) when trace_new_target proves the receiver is exactly one of
# these -- bypassing Class#new's own allocate+initialize dispatch chain
# entirely in favor of a hand-written lib.cxx entry point (`fn`) that
# builds the T directly from already-known argument registers, guarded at
# runtime by a class-identity check against `class_fn` (see compile_send's
# own comment on why that guard exists and what it does/doesn't protect
# against).
#
# Checked before hand-listing these: neither bc2cpp.rb nor
# compiled_gems.rb has any existing registry of "classes needing
# MRB_SET_INSTANCE_TT(..., MRB_TT_DATA)" that covers Rect/Color/Tone --
# the one such listing that exists (report_native_tt_candidates' own
# `== classes needing ... ==` diagnostic) is about a completely different
# thing: bc2cpp's own ivar-embedding decision for classes IT compiles a
# body for from Ruby bytecode (Game::Actor, RPG2k::Scene::Map, ...).
# Rect/Color/Tone are hand-written native C++ classes bc2cpp never
# compiles a body for at all (their #initialize is native, invisible to
# this compiler the same way every other native method is), so there is
# no existing mechanism to reuse -- this table is the first one.
#
# `arity` is each class's own real positional-constructor shape as used by
# the one real, concrete call site this covers (`Tone.new(0, 0, 0, 0)`/
# `Color.new(0, 0, 0, 0)`/`Rect.new(0, 0, 0, 0)`, RGSS::Sprite#tone/#color/
# #src_rect's own `@ivar ||= Klass.new(...)` memoizing readers) --
# deliberately exact-match only (no optional-argument default-filling
# modeled here), so a call site passing a different argument count (e.g.
# a bare `Tone.new` relying on all-default 0s) just misses this path and
# falls back to ordinary dynamic dispatch, same as any other unmodeled
# shape in this file.
#
# `arg_type` (:int/:float, uniform across all of one class's own arguments
# -- Rect's own fields are all mrb_int, Color/Tone's own are all mrb_float,
# confirmed directly against each one's own lib.cxx struct definition)
# says how this codegen unboxes each argument register BEFORE calling
# `fn` -- `fn`'s own real C++ signature takes native mrb_int/mrb_float
# parameters now, not mrb_value (mruby-rgss/src/lib.cxx's own comment on
# these three functions has the full reasoning: a deliberately incremental
# first step away from mrb_value at bc2cpp's own generated call sites,
# starting here since these three already assumed one fixed native type
# per field long before this). `mrb_as_int`/`mrb_as_float` are the exact
# same unboxing calls that used to live inside `fn` itself -- relocating
# them to the call site changes nothing observable (same TypeError-raising
# for a bad argument, mrb_state* M has no notion of a calling-frame
# boundary to cross), only which side of the call spells them out.
NATIVE_CONSTRUCT_TARGETS = {
  'Tone' => { fn: 'rgss_tone_new_direct', class_fn: 'rgss_native_tone_class', arity: 4, arg_type: :float },
  'Color' => { fn: 'rgss_color_new_direct', class_fn: 'rgss_native_color_class', arity: 4, arg_type: :float },
  'Rect' => { fn: 'rgss_rect_new_direct', class_fn: 'rgss_native_rect_class', arity: 4, arg_type: :int },
}.freeze

# Generalizes NATIVE_CONSTRUCT_TARGETS' own "MONO :new -> direct native
# construct" mechanism (above) from hand-written native C++ classes to
# ordinary bc2cpp-COMPILED ones -- a parallel, additive mechanism, not a
# replacement (nothing about NATIVE_CONSTRUCT_TARGETS/compile_send's own
# native-construct branch changes here). Key difference: there is no
# hand-written native constructor to call for one of these -- Rect/Color/
# Tone each needed one (rgss_*_new_direct) because their own #initialize is
# native C++, invisible to this compiler entirely, so it had to be
# reimplemented by hand for the direct-construct path to have anything to
# call. A bc2cpp-COMPILED class's own #initialize, by contrast, is *already*
# a real, ordinary compiled `_impl` function once its owner joins some gem's
# ONLY_OWNERS (the same _impl compile_send's own MONO/TYPED paths already
# call for every other devirtualized send) -- so the only genuinely new
# piece of machinery needed is a generic replacement for Class#new's own
# `self.allocate` step (bc2cpp_direct_alloc, emitted by
# emit_direct_construct_decls below), not a second constructor per class.
#
# A plain owner-name array, not a Hash like NATIVE_CONSTRUCT_TARGETS -- there
# is no per-entry `fn`/`arity` to hand-carry: the constructor to call is
# always `#{cpp_name(owner, 'initialize')}_impl` (derived, like every other
# devirtualized call in this file) and the arity is whatever the real
# #initialize candidate's own mandatory_arity turns out to be, re-checked
# against the call site's own argument count at compile_send time exactly
# the way the existing TYPED path already does for a class-exact ivar/
# argument-annotation hit -- hardcoding it a second time here would risk it
# drifting out of sync with the real registry. Only the class-identity
# accessor function name is hand-carried, matching NATIVE_CONSTRUCT_TARGETS'
# own `class_fn` -- compile_send's own comment on that guard's reasoning
# applies identically here (a reassigned constant, e.g. `Game::Transition =
# SomeOtherClass`, has to be caught the same way).
#
# Deliberately NOT auto-derived from compiled_gems.rb's own owners: BOTH
# require a durable, gem-init-captured RClass* AND its own accessor function
# to actually exist in that owner's compiled gem's own register.cxx (see
# that file's own comment, mirroring mruby-rgss/src/lib.cxx's
# g_native_rect_class/rgss_native_rect_class() precedent for this same
# round) -- an owner simply being compiled at all (compiled_gems.rb's
# `owners:` list) says nothing about whether anyone has actually wired up
# that RClass*/accessor pair for it yet. Every entry here has one, confirmed
# directly against mruby-rpg2k-compiled/src/register.cxx.
#
# Picked from mruby-rpg2k-compiled's own real owners (compiled_gems.rb) by
# the same discipline as NATIVE_CONSTRUCT_TARGETS' own comment: a class
# whose #initialize is confirmed to compile clean AND has a real,
# fully-qualified (`Owner.new`, never a bare same-namespace reference --
# see Game::Screen's own paragraph below for why that distinction matters)
# construction site whose own argument count matches AND whose enclosing
# method compiles all the way through with zero OTHER unsupported opcodes
# anywhere in its own body (see the Game::EnemyAi/Game::ChipSet paragraph
# below for why that last condition, easy to miss, is just as real a gate
# as the first two -- this compiler emits or drops a whole method, never
# part of one, so a perfectly-eligible `.new` receiver sitting one
# instruction away from an unrelated `super`/`rescue`/block gets dropped
# right along with it). Confirmed by actually regenerating this gem's own
# real output (`ONLY_OWNERS`/`OTHER_OWNERS`/`NATIVE_SRCS`/
# `SKIP_UNSUPPORTED=1` computed exactly the way mruby-rpg2k-compiled's own
# mrbgem.rake does, through a real host `mrbc` built fresh in this checking
# worktree) and grepping it for the real `// MONO :new -> ...` comment this
# mechanism's own compile_send branch emits -- not merely reasoning about
# the Ruby source, which (as the two exclusion paragraphs below both show)
# is not sufficient on its own to know whether a given call site's own
# devirtualization actually survives into the emitted file.
#
# Two real owners actually clear every one of these bars, confirmed present
# in the real regenerated `rpg2k_compiled_gen.cpp` (which itself contains
# zero `#error` markers at all under `SKIP_UNSUPPORTED=1`, so every hit
# found this way is a real, live-in-production devirtualization, not a
# diagnostic-only artifact from a non-representative run):
#   Game::Transition.new(style, frames, Game::SCREEN_W, Game::SCREEN_H, erase)
#     -- mruby-rpg2k/mrblib/game.rb, Game::Screen#fade_to (5 args, matching
#     #initialize(style, frames, width, height, erase)'s own 5 mandatory
#     arguments; #fade_to itself compiles clean end to end).
#   Game::Map.new id, LCF::MapUnit.new(File.open(map_path(id)))
#     -- mruby-rpg2k/mrblib/main.rb, RPG2k#load_map (2 args, matching
#     #initialize(id, unit)'s own 2 mandatory arguments; #load_map itself
#     compiles clean end to end).
#
# Three more classes were seriously considered and ruled out, each for a
# genuinely different reason -- worth recording all three, since none of
# them would be obvious from reading compiled_gems.rb's own "#initialize
# compiles clean" writeup alone:
#
# Game::Screen's own #initialize takes zero arguments and compiles clean
# (the very first embedding target this ADR ever shipped), but its one real
# construction site (mruby-rpg2k/mrblib/game.rb: `@screen = Screen.new`,
# inside Game::State#initialize) is a *bare* constant reference, resolved
# only through `module Game`'s own real lexical scoping at runtime --
# trace_new_target's own GETCONST case has no lexical-scope-aware
# resolution the way build_registry's CLASS/MODULE walk or GETCONST's own
# ordinary codegen do (see that case's own comment): it captures the bare
# text "Screen" verbatim, which can never equal the real owner string
# "Game::Screen", so this call site provably MISSES the whole mechanism
# rather than being unsoundly matched -- confirmed directly: no
# `Game__Screen_compiled_class` reference appears anywhere in the real
# regenerated build, the same "safe miss, not a wrong answer" behavior this
# whole file already accepts for every other unrecognized receiver shape.
#
# Game::State's own #initialize(party, map_id, x, y) also compiles clean,
# and has exactly one real construction site anywhere in this closed world
# (mruby-rpg2k/mrblib/main.rb's own RPG2k#start_new_game: `Game::State.new
# Game::Party.new(@db), map_id, x, y`, 4 args, matching arity) -- but that
# one call site sits inside `RGSS::Profiler.section("map.transition.party")
# do ... end`, a genuine Ruby block. A block literal's own body compiles
# into a completely separate child irep that compile_method never
# independently visits at all (it has no MethodDef of its own in the
# registry -- only a real class-body def/CLASS-MODULE-opened body does, per
# build_registry's own walk) -- the SAME permanently-out-of-scope shape
# every other BLOCK/SENDB gap this whole codebase already documents (e.g.
# Game::Actor#party_level), just discovered here for a `.new` receiver
# rather than an ordinary method body.
#
# Game::EnemyAi(db, state) and Game::ChipSet(db, id) both compile clean
# too, and BOTH have a real, fully-qualified construction site whose own
# argument count matches (`Game::EnemyAi.new(db, @state)`, mruby-rpg2k/
# mrblib/scene/battle.rb; `Game::ChipSet.new(@db, @map.chipset_id)` /
# `Game::ChipSet.new(@db, @tileset_id || @map.chipset_id)`, scene/
# map_viewer.rb and scene/map.rb) -- genuinely different from Game::Screen's
# own bare-reference miss and Game::State's own block-body miss, and easy
# to mistake for a real win from the Ruby source alone. But EnemyAi's own
# one real call site sits inside `RPG2k::Scene::Battle#initialize`, which
# hits `#error unhandled opcode SUPER` (a `super parent` call, an entirely
# unrelated statement several lines above the EnemyAi.new site itself), and
# ChipSet's own two real call sites are each the sole statement of a
# `#build_chipset` method (map_viewer.rb's and map.rb's own, two distinct
# methods sharing one name) whose own very next line is `rescue
# StandardError => e` -- `#error unhandled opcode RESCUE`/`RAISEIF`/
# `EXCEPT`. compile_method emits or drops a method's ENTIRE body as one
# unit (SKIP_UNSUPPORTED's own real mechanism: a method whose generated
# code contains a `#error` marker anywhere is dropped whole, not trimmed
# down to its compiling instructions) -- so a perfectly-eligible `.new`
# receiver sitting right next to a totally unrelated unsupported opcode in
# the SAME enclosing method is dropped right along with it, exactly the
# same as any other devirtualization (MONO, TYPED, or this one) inside that
# same uncompiled method would be. Confirmed directly, not just reasoned
# about from the Ruby source: an earlier version of this same round's own
# diagnostic run (bc2cpp.rb invoked directly, without `SKIP_UNSUPPORTED=1`)
# DID show real `// MONO :new -> Game::EnemyAi`/`Game::ChipSet` comment
# lines in its own raw, error-marker-riddled output -- indistinguishable
# from a real win until cross-checked against the actual
# `SKIP_UNSUPPORTED=1` build mrbgem.rake always runs, which shows neither
# ever reaching the final file (their own accessor functions'
# forward declarations are the only trace either owner would leave were it
# still in this table -- confirmed absent once removed). A real, useful
# lesson for any future owner considered for this table: checking
# compiles_clean?(irep) for the *target* #initialize is not enough by
# itself -- the call site's own *enclosing* method has to independently
# clear the same bar, and the only way to know that for certain is to
# regenerate the real, `SKIP_UNSUPPORTED=1` output and grep it, not to
# reason about either method's source in isolation.
#
# All five names above (this table's own two members and the three
# ruled-out ones) are left undocumented as a live TODO nowhere else in this
# file -- a future round that removes Game::Screen's own bare-reference gap
# (a real, general fix: making trace_new_target's own GETCONST case
# lexical-scope-aware, mirroring GETCONST's own ordinary codegen), unwraps
# Game::State's one real call site from its own profiler block, or adds
# real SUPER/RESCUE support (both already flagged as future work by
# RPG2k::Scene::Base's/ItemMenu's own registration-block comments) would
# very likely unlock one or more of these for free, with the exact same
# soundness gate already proven correct for the two below.
#
# Every one of these two #initialize candidates is registered
# `mrb_define_private_method` (mruby's own src/class.c forces #initialize
# private unconditionally, regardless of source -- see build_registry's own
# TDEF-case comment) -- irrelevant to this mechanism's own soundness: a
# devirtualized direct call here never goes through mrb_funcall's own
# method-name/visibility lookup at all (the same reason Class#new's own real
# allocate+initialize dispatch chain is itself allowed to invoke a private
# #initialize), so bypassing that chain changes nothing about which
# visibility rule would have applied.
#
# Checked directly against the real whole-program registry (this round's own
# diagnostic run, ONLY_OWNERS set exactly the way mruby-rpg2k-compiled's own
# mrbgem.rake computes it): no method named `new` or `allocate` exists
# anywhere in the whole closed world under either
# "Game::Transition.singleton" or "Game::Map.singleton" (in fact no
# bytecode-visible `def self.new`/`def self.allocate` exists under ANY
# owner in this whole closed world at all -- confirmed by grepping the real
# registry dump for an exact `:new`/`:allocate` entry and finding none) --
# so neither of these two has a custom `self.new`/`self.allocate` this
# mechanism would have to respect and can't. compile_send's own gate
# re-checks this same fact live against `@registry` rather than trusting
# this comment, so a future edit to either class's own source that adds one
# is caught automatically, not silently missed.
# Round 41 follow-up (a dedicated adversarial correctness sweep of this
# mechanism, not a new motivating case): re-checked every real `owners:`
# entry across all three `*-compiled` gems against this table's own 4-part
# soundness bar, specifically looking for a class this table's own top
# comment's "three ruled-out ones" section doesn't already name. Found
# three MORE real classes hitting the exact same "bare-reference gap"
# already documented above for `Game::Screen` (trace_new_target's own
# GETCONST case -- `path.unshift(insn.args[/^R\d+\s+(\S+)/, 1]); return
# path.join('::')`, this file's own `trace_new_target` -- returns only the
# bare token a plain, lexically-scoped `GETCONST` opcode names, e.g.
# `"Switches"`, never resolving it through the enclosing namespace the way
# GETCONST's own real runtime lookup chain would, so it can never equal a
# fully-qualified `"Game::Switches"` string this table stores): `Game::
# Switches.new`/`Game::Timer.new` (x2)/`Game::MessageConfig.new`, every one
# of them a bare, unqualified `Switches.new`/`Timer.new`/`MessageConfig.new`
# reference inside `Game::State#initialize` (mruby-rpg2k/mrblib/game.rb) --
# the identical shape as `Game::Screen`'s own already-documented miss, one
# `Game::State#initialize` body over. All three otherwise clear the real
# 4-part bar cleanly (checked directly, not assumed): zero `def self.new`/
# `def self.allocate`/`class << self` anywhere in `mruby-rpg2k/mrblib/
# game.rb` at all (confirmed by grep), all three `#initialize`s are 0-arg
# (trivially `pure_mandatory_arity?`, matching each real call site's own
# `n=0`), and all three already compile clean today (their own `_impl`
# functions already exist in the real generated output, confirmed
# directly). Verified empirically, not just reasoned about: temporarily
# adding all four names (`Game::Switches`/`Game::Timer`/`Game::
# MessageConfig`/`Game::Screen`) to this table and regenerating the real
# `rpg2k_compiled_gen.cpp` produces a byte-for-byte IDENTICAL file to the
# unmodified table -- confirming the bare-reference gap, not some other
# unmet condition, is the actual and complete blocker for all four, exactly
# as this table's own top comment already predicts for `Game::Screen`
# alone. Left OFF this table at the time (adding any of the four then was a
# proven no-op, not a soundness risk) -- unlocking any of them needed the
# same real, general fix this table's own top comment already called out
# and deferred ("making trace_new_target's own GETCONST case lexical-scope-
# aware, mirroring GETCONST's own ordinary codegen").
#
# Round 43 follow-up implements that fix. trace_new_target's own GETCONST
# case (this file's own function, not this table) now resolves a bare,
# single-token receiver -- but ONLY as far as this table's own 4-part
# soundness bar can independently prove safe, never a general lexical
# lookup against the whole registry: it walks the enclosing method's own
# real nesting chain (an `owner:` string now threaded into
# trace_new_target from every one of its three call sites -- ClassLayout.
# analyze's own `owner`, compile_send's own `owner_def&.owner`) innermost
# first, exactly mirroring real Ruby's own Module.nesting search order (and
# compile_insn's own GETCONST codegen, which already does this correctly
# at runtime -- see lexical_scope_path's own comment), and returns the
# first namespace-qualified candidate that is already an exact,
# independently-vetted entry in THIS table. Deliberately narrower than a
# general "resolve any bare constant through its enclosing namespace" fix
# (real Ruby's own constant lookup can, in principle, still fall through a
# whole nesting chain to a same-named TOP-LEVEL constant if no nested one
# actually exists -- trace_new_target has no access to the whole-program
# registry needed to rule that out in general): gating the resolution on
# DIRECT_CONSTRUCT_TARGETS membership itself sidesteps that question
# entirely, since every candidate this loop can possibly produce is by
# construction a class this table's own 4-part bar has already separately
# vetted end to end (see below). A bare reference that doesn't resolve to a
# known entry this way (from any nesting level) falls straight through to
# this function's original "just the bare token" behavior, unchanged --
# still a provably safe miss, never a wrong guess, for every call site
# (including `Tone`/`Color`/`Rect`'s own real bare top-level references,
# NATIVE_CONSTRUCT_TARGETS' own table, which this change leaves completely
# untouched) this round doesn't specifically target. See
# trace_new_target's own GETCONST case for the full writeup, including the
# defense-in-depth this table's own two call sites (compile_send's MONO
# NATIVE_CONSTRUCT_TARGETS/DIRECT_CONSTRUCT_TARGETS branches and its TYPED
# branch) already independently provide regardless (a real runtime
# `mrb_class_ptr(recv) == ...` guard before ever taking the direct-call
# fast path, falling back to ordinary `mrb_funcall` otherwise) -- this fix
# could not misroute a real call even if its own nesting-chain reasoning
# were somehow wrong for some case it didn't anticipate.
#
# Verified this fix is a true no-op for whole-program registry building --
# a full `wio_registered_methods.rb` TSV dump (owner/name/arity/
# visibility/singleton for every real compiled entry point) for all three
# `*-compiled` gems is byte-for-byte IDENTICAL before and after this fix
# with this table left unchanged (2 entries) -- and separately confirmed
# real, not just theoretically unlocked, for the four names added below:
# regenerating the real `rpg2k_compiled_gen.cpp` shows `Game::State#
# initialize`'s own `Switches.new`/`Timer.new` (x2)/`MessageConfig.new`/
# `Screen.new` call sites now compile to the same `// MONO :new -> ...,
# direct compiled construct (bc2cpp_direct_alloc + ..._impl)`
# runtime-guarded shape `Game::Transition`/`Game::Map`'s own call sites
# already used, in place of the generic `mrb_funcall` fallback they
# compiled to before.
#
# `Game::Screen` itself re-verified independently against the real 4-part
# bar (not just carried over on the strength of the round-43 writeup
# above): zero `def self.new`/`def self.allocate`/`class << self` anywhere
# in `mruby-rpg2k/mrblib/game.rb` (confirmed by grep, and by the real
# whole-program registry dump below showing no `Game::Screen.singleton`
# entry at all); `#initialize` is 0-arg and already compiles clean (its
# `_impl` already exists in the real generated output), matching its one
# real construction site's own `n=0` (`@screen = Screen.new`, `Game::
# State#initialize`, mruby-rpg2k/mrblib/game.rb); and `Game::Screen` is a
# real, unambiguous single entry in mruby-rpg2k-compiled's own `owners:`
# list (compiled_gems.rb), not colliding with anything else -- also
# already a `NATIVE_ARG_TARGETS`/`wio_strip_bc2cpp_stubs` owner for
# several of its OTHER methods (`tint_to`/`restore_tint`/`shake`/`flash`/
# `approach`, none of them `#initialize`), which is orthogonal to this
# table and does not interact with it: this mechanism only ever touches
# the `Owner.new` call site itself and the target `#initialize`, and
# `#initialize` carries no `NATIVE_ARG_TARGETS` entry of its own. A full
# `wio_registered_methods.rb` TSV dump for all three `*-compiled` gems is
# byte-for-byte IDENTICAL before and after adding `Game::Screen` here,
# same as every other entry in this table -- this is purely an additive
# codegen unlock, never a registration change.
#
# Six more classes added this round, each independently checked against the
# real whole-program registry/`== compiled entry points ==` dump for
# `mruby-rpg2k-compiled` (never assumed from source reading alone) and
# against this table's own 4-part bar: `Game::ChipSet` (`#initialize(db,
# id)`, arity 2), `Game::Interpreter` (`#initialize(state)`, arity 1),
# `RPG2k::Scene::Menu` (`#initialize parent, state`, arity 2),
# `RPG2k::Scene::DebugMenu` (`#initialize(parent, state)`, arity 2),
# `RPG2k::Scene::ItemMenu` (`#initialize parent, state`, arity 2),
# `Game::NumberInput` (`#initialize(digits)`, arity 1). Every one: no `def
# self.new`/`def self.allocate` (confirmed by the real registry showing no
# matching `.singleton` entry for `:new`/`:allocate`), a real compiled
# `#initialize` whose real source (`mruby-rpg2k/mrblib/game.rb`,
# `interpreter.rb`, `scene/menu.rb`, `scene/debug_menu.rb`,
# `scene/item_menu.rb`) takes only plain mandatory positional arguments (no
# `= default`, no `*rest`, no keywords -- `pure_mandatory_arity?` would
# refuse any of those), and already a member of `mruby-rpg2k-compiled`'s
# own `owners:` list (`compiled_gems.rb`).
#
# Only THREE of these six are real, ACTIVE unlocks today, confirmed by a
# real before/after diff of the regenerated output (`mruby-rpg2k-compiled/
# src/register.cxx`'s own top-of-file comment has the matching C++-side
# wiring these three also needed to actually link, not just text-generate
# -- `emit_direct_construct_decls` only ever emits a forward declaration):
# `Game::ChipSet` (2 real sites, `mruby-rpg2k/mrblib/scene/
# map_viewer.rb:356` and `mruby-rpg2k/mrblib/scene/map.rb:1368` -- a THIRD
# real call site, `mruby-rpg2k/mrblib/game/lsd_io.rb:444`, does NOT convert
# and never will until its own containing method compiles: it sits inside a
# `begin...rescue` block bc2cpp still can't compile at all today, so that
# `SEND :new` is simply never reached by codegen, table membership or not),
# `Game::Interpreter` (1 real site, `mruby-rpg2k/mrblib/scene/map.rb:379`),
# `Game::NumberInput` (1 real site, `mruby-rpg2k/mrblib/scene/map.rb:9863`).
#
# The other three -- `RPG2k::Scene::Menu`/`DebugMenu`/`ItemMenu` -- pass
# this table's own 4-part bar exactly as cleanly, and stay listed as
# correct, harmless future-proofing (the identical "opt-in table checked
# live against the real registry every run" property every other entry
# here already has -- see this constant's own top comment), but confirmed
# to have ZERO real call sites today: every real `Scene::Menu.new`/
# `Scene::DebugMenu.new`/`Scene::ItemMenu.new` in `mruby-rpg2k/mrblib/
# scene/{map,menu}.rb` sits inside a caller method (`RPG2k::Scene::Map#
# perform_event_menu` and siblings) that is itself still on the
# `== skipped (unsupported, left on the interpreter) ==` list -- same
# "containing method doesn't compile yet" shape as ChipSet's own
# `lsd_io.rb` site above, just for all of a given class's real call sites
# rather than one of several. Confirmed these three add ZERO new forward
# declarations to the regenerated output (unlike the three real unlocks
# above) -- so, unlike those three, they need no matching register.cxx
# wiring yet either; whenever their own caller methods eventually gain
# opcode coverage, this table already covers them with no further Ruby-side
# change, though the matching accessor-function wiring register.cxx's own
# comment describes will still need adding at that point, the same real,
# separate step this round needed for the three that activated today.
#
# A handful of sibling classes from the same candidate sweep were checked
# and deliberately left OUT, not overlooked: `Game::Vehicle#initialize(type,
# map_id = 0, x = 0, y = 0, direction = 2)`, `Game::Character#initialize(x =
# 0, y = 0, direction = 2)`, `Game::Picture#initialize(id, opts = {})`,
# `Game::Weather#initialize(type = 0, strength = 0)`,
# `Game::Rng#initialize(seed = 1)`, and `Game::Variables#initialize(rpg2003
# = false)` (all in `mruby-rpg2k/mrblib/game.rb`) each carry a real `=
# default` optional argument, so `pure_mandatory_arity?` correctly refuses
# every one of them -- listing any of these here would be a silent no-op
# (the `init_ok` check below would just never pass), not a real unlock, so
# they stay off this table rather than padding it with dead entries.
DIRECT_CONSTRUCT_TARGETS = %w[Game::Transition Game::Map
                               Game::Switches Game::Timer Game::MessageConfig
                               Game::Screen Game::ChipSet Game::Interpreter
                               RPG2k::Scene::Menu RPG2k::Scene::DebugMenu
                               RPG2k::Scene::ItemMenu Game::NumberInput].freeze

# NATIVE_ARG_TARGETS: an explicit, human-vetted "Owner#name" allowlist that
# gates a THIRD, separate, additive calling-convention mechanism -- moving
# an ordinary compiled method's own mandatory argument off mrb_value and
# onto a real native C++ type (mrb_int/mrb_sym), the same way the
# just-merged Rect/Color/Tone round already did for three hand-written
# NATIVE_CONSTRUCT_TARGETS entry points, generalized here to ordinary
# bc2cpp-compiled `_impl` functions instead of a native constructor.
#
# The trigger is deliberately narrow and explicit, mirroring this file's
# own two other "opt-in table, never the analysis result trusted wholesale"
# precedents (NATIVE_CONSTRUCT_TARGETS/DIRECT_CONSTRUCT_TARGETS just
# above): a position only ever gets a native type when BOTH (a) this exact
# "Owner#name" string is listed here AND (b) Annotations.extract's own
# result -- a real, human-authored `# bc2cpp: (fixnum, ...)` magic comment
# sitting directly on that one `def`, never ArgTypes' own passive,
# call-site-inferred typing -- names a recognized type (`fixnum`/`symbol`)
# at that position. Annotations alone would already be sound in principle
# (see this file's own Annotations class comment: a wrong one only ever
# produces a real TypeError, never silent corruption, the same accepted
# precedent IvarLayout's ivar-embedding already relies on) -- but this
# round deliberately stays conservative about SCALE, not soundness: this
# whole codebase carries roughly a hundred real `# bc2cpp: (fixnum...)`
# annotations (mostly in mruby-rpg2k/mrblib), and trusting every one of
# them for a stricter calling convention in one pass, sight unseen, is a
# very different risk profile than the "handful, each individually traced
# through every real call site" this round actually did. This table is
# that trace's own record -- every entry below was individually checked
# against the real, regenerated `rpg2k_compiled_gen.cpp` (RPGMAKER_BC2CPP=1
# build in this same round) for: every MONO/TYPED devirtualized call site
# into it (grepped directly, not just reasoned about the Ruby source), AND
# -- the harder, easy-to-miss half, found by actually reading the fixnum
# annotation against the body -- whether the method's OWN compiled body
# already contains a defensive `<arg>.nil?` guard on that exact position
# (a real signal the original author expected a legitimate nil there too,
# which the annotation's own "fixnum" claim doesn't capture and a native
# mrb_int parameter cannot represent at all: mrb_get_args("i")/mrb_as_int
# both raise TypeError for nil, same as every other "i" callsite in this
# codebase, but here that would be a real, novel crash on an input the
# interpreted/mrb_value path handles gracefully today).
#
# Two real, concrete methods (Game::Actor#knows_skill?(skill_id),
# Game::Actor#learn_skill(skill_id)) were seriously considered from the
# same batch and DELIBERATELY EXCLUDED for exactly this reason: both
# compile clean, are genuinely devirtualized (MONO) at real call sites, and
# carry a real `# bc2cpp: (fixnum)` annotation on their one mandatory
# argument -- but both bodies open with `skill_id.nil?` (returning
# false/nil gracefully) before ever touching the value as a number, and one
# real call site of :knows_skill? (`Game::Party#can_cast?`'s own `sid`,
# guarded only by `!db_skill(sid).nil?` -- a check on a DIFFERENT value,
# not on `sid` itself) could not be proven, without a much deeper trace
# into LCF::Array1D#[]'s own behavior on a nil index, to always exclude a
# genuinely nil `sid` reaching the call. (Read closely, that one path likely
# already raises a TypeError today from inside Array1D#[] for a nil id --
# array indexing with `nil` needs an implicit Integer conversion mruby
# itself doesn't grant nil -- meaning this specific miss may not even be a
# real regression; but "likely already raises, following the schema
# metadata's own storage shape two calls deep" is exactly the kind of
# not-fully-provable chain this round declined to force through, per its
# own "skip and document, don't guess" mandate. Any real call site actually
# reaching these two methods with a nil argument today is handled
# gracefully by the interpreted path regardless of this reasoning, so both
# stay off this list.) Every one of the 9 entries actually below was
# confirmed to have NO such nil-guard in its own compiled body -- every
# real use of the annotated register is a direct arithmetic/comparison
# opcode (ADD/ADDI's own fixnum-fastpath, `<`/`<=`/`>=`/`==`'s own
# fixnum-fastpath, or a GETCONST-chain comparison), never preceded by a
# `nil?`/`respond_to?`-style guard -- and every real caller in the whole
# closed world (mruby-rpg2k/mrblib, scripts/rpg2k_logic_check.rb) was
# individually traced back to a source that is always a real Integer
# (an event command's own `cmd.param(i) || 0`, a `Game::Variables#[]`
# read -- `@data[id] || 0`, never nil -- or another already-verified
# Integer-typed expression), not merely assumed from the annotation alone.
#
# `Game::Actor#gain_exp`/`#change_level_by`/`#free_two_handed_slot` have
# ZERO devirtualized (MONO/TYPED) call sites in the real regenerated
# output at all -- reachable only through ordinary dynamic dispatch, so
# only this table's own entry-wrapper/impl-signature change (compile_method)
# applies to them; compile_send's own call-site-unboxing code path is
# exercised by nothing for these three, confirmed by grepping the whole
# regenerated file for their own `_impl` name and finding just the decl,
# definition, and entry wrapper -- the simplest, lowest-risk shape in this
# batch. `#change_mp`/`#exp_for_level`/`#slot_cursed?`/`#base_param_limit`/
# `Game::Interpreter#character_ref`/`#trunc_div` each have one or more real
# MONO devirtualized call sites (`#exp_for_level` five, all self-implicit
# recursive-ish calls from other Game::Actor methods; `#character_ref`
# three, self-implicit; `#change_mp`'s own single call site's argument is
# itself the *result* of a dynamic-dispatch expression (`-weapon_sp_cost`),
# not a bare register -- confirmed the generic call-site fix in
# compile_send wraps whatever expression is already there, not just a
# literal `r<n>` token) -- these exercise the real call-site-unboxing path.
# `Game::Interpreter#trunc_div(n, d)` is the one 2-mandatory-argument entry
# in this batch, with BOTH positions annotated and native-typed -- checked
# that its own two real call sites (self-implicit, from `#apply`) pass two
# independently-verified-Integer registers, not a mix of one safe and one
# unsafe position.
#
# A later round re-checked every remaining `# bc2cpp: (fixnum/symbol...)`
# annotation in mruby-rpg2k/mrblib (game.rb, interpreter.rb) and
# mruby-lcf/mrblib/lcf.rb against the exact same two-part bar (no nil-guard
# on the annotated position, every real caller's argument provably
# Integer/Symbol) and against `compiled_gems.rb`'s own owners lists (an
# annotation on a method whose class is not actually compiled, or whose own
# body does not itself compile clean, is moot regardless of the annotation).
# mruby-rgss/mrblib carries zero `fixnum`/`symbol` annotations at all --
# confirmed by grep, not assumed -- so it contributes nothing this round.
#
# Excluded for a `nil`-guard on the exact annotated position, the same
# knows_skill?/learn_skill shape the prior round already found and documented
# above: `Game::ChipSet#upper_flags` (`upper_tile_id.nil?`), `Game::Actor#
# state?`/`#equipped?`/`#two_handed?`/`#cursed_armor_state_ids` (each opens
# with `<id>.nil? || <id> == 0`), `Game::Actor#change_battle_commands`
# (`id.nil?`), `Game::Actors#[]`/`#known_invalid?` (`id.nil? || id <= 0`),
# `Game::State#show_picture` (`id && id > 0 && ...`), `Game::Interpreter#
# start_at` (`index && index > 0 && ...`), `#simulated_attack_variance`
# (`var && var > 0 && ...`) and `#teleport_facing` (`param && param >= 1 &&
# ...`) -- every one of these already tolerates a genuine `nil` at the
# annotated position today, by returning/no-opping gracefully, so a native
# `mrb_get_args("i"/"n", ...)` raising TypeError there instead would be a
# real, novel crash on an input the interpreted path currently handles fine.
#
# Excluded because the method itself does not compile clean at all (a real
# `#error` in the regenerated output regardless of this table), so there is
# no `_impl` signature to retype in the first place: `Game::Actor#initialize`
# (BLOCK/SENDB/GETIDX, per `compiled_gems.rb`'s own Game::Actor writeup),
# `#set_level`/`#add_state` (a trailing keyword argument with a default --
# `preserve_mod:`/`allow_battle_states:` -- makes both non-mandatory arity
# even though the *positional* argument the annotation names is itself
# mandatory), and `#equip_item`/`#change_hp` (`slot = nil`/`allow_death =
# true`, an optional positional argument, same non-mandatory-arity gap).
#
# Excluded for a structural reason specific to this mechanism, not a
# soundness finding about the method's own body: `Game::Transition#
# initialize` and `Game::Map#initialize` both carry a real, clean-compiling,
# purely-mandatory-arity `# bc2cpp: (fixnum, ...)` annotation and would
# otherwise be textbook candidates -- but both classes are also listed in
# `DIRECT_CONSTRUCT_TARGETS` (just above), whose own `SEND :new` codegen
# (this round left untouched, per its own brief) calls `#{init_impl}(M,
# recv, argv...)` passing every argument straight through as a plain
# `mrb_value`, with no `native_arg_types`-aware unboxing of its own. Adding
# either class's `#initialize` here would silently desync that call from a
# retyped `_impl` signature expecting `mrb_int` -- a real compile error (or
# worse, a signature mismatch masked by implicit conversion) in a codegen
# path this round was explicitly told not to touch, so both stay off this
# list for exactly that reason, independent of anything about their own
# annotated arguments.
#
# `Game::State#initialize` is the one case this round traced all the way
# through a real save-data schema and still excluded, the same honest
# "can't fully verify, so don't guess" call the prior round's own
# Game::Party#can_cast? writeup models: its real, only real construction
# site is `Game::State.from_lsd`'s own `new(party, hero[:map_id], hero[:x],
# hero[:y])` (mruby-rpg2k/mrblib/game/lsd_io.rb), and unlike the SAVE_SCREEN
# tint fields `Game::Screen#restore_tint` relies on below, `LCF::Schema::
# SAVE_MOVABLE`'s own `:map_id`/`:x`/`:y` entries (fields 11-13) carry no
# `default:` key at all -- `LCF.to_rb`'s own `unless d; dv = s[:default];
# ...; end` branch returns a bare `nil` for an absent field with no declared
# default, not a real Integer. `#initialize`'s own body only ever plain-
# assigns these three (`@map_id = map_id`, etc.), never touching them
# arithmetically, so a save chunk 104 genuinely missing one of these fields
# is tolerated silently today (a `nil` ivar) and would become a new,
# hard TypeError crash on `Continue` for exactly that malformed-but-loadable
# save shape -- excluded rather than assumed safe.
#
# `Game::Interpreter#apply(op, cur, val)` is the other explicitly-considered-
# and-declined case, for the same "can't fully verify" reason, even though
# its own two annotated positions (`cur`, `val`) are BOTH used arithmetically
# in four of `apply`'s five real branches (`cur + val`, `cur - val`, ...),
# which would ordinarily be the strong, crashes-already-today signal this
# round otherwise relies on. The gap is `when 0 then val` (Control Variables'
# "Set" operation): `cur` is never even read there, and `val` is returned
# completely unguarded -- so whatever `operand_value(cmd)` produces reaches
# `apply`'s own caller as-is, with no arithmetic op along the way to already
# raise on a bad value the way every other branch's `+`/`-`/`*` would. Tracing
# `operand_value` far enough to rule out a `nil` result would mean separately
# proving `actor_operand`/`enemy_operand`/`event_operand`/`item_operand`/
# `random_operand` each never return one (e.g. `enemy_operand`'s own `foe.hp`/
# `foe.max_hp`, read with no `|| 0` fallback unlike its sibling `foe.mp || 0`/
# `foe.max_mp || 0` two lines below) -- exactly the "much deeper trace into
# [an unrelated class']'s own behavior" shape the prior round's own
# Game::Party#can_cast? writeup already declined to force through, so this
# round declines it too rather than guess. (`Game::Interpreter#trunc_mod`,
# below, sidesteps this entirely: only its own `n` position is annotated,
# and `n` is always a `Game::Variables#[]` read -- `@data[id] || 0` --
# regardless of what `apply`'s own `val`/`d` might be.)
#
# Every survivor below was checked against BOTH halves this table's own top
# comment requires -- no nil-guard on the annotated position (or, in the four
# cases marked "assign-only", a real trace of every actual caller, since a
# plain `@ivar = arg` body never itself raises on `nil` regardless): `Game::
# Actor#unequip` (`slot == .../ slot >= 0 && slot < ...`, both real callers --
# `#change_class`'s own `EQUIP_ORDER.size` literal and `Party#unequip_to_bag`'s
# own already-range-checked `slot` -- traced); `#base_stats` (`level >
# levels`, every real caller passes `@level`/`actor.level`, always seeded by
# `#set_level`'s own `level && level >= 1 ? level : 1`, or the literal `1`
# Change Class's `CLASS_PARAM_RESET_LV1` branch passes); `#change_param`
# (`type >= 0 && ...`/arithmetic on `delta`, its one real caller `Interpreter#
# do_change_params` builds both from `cmd.param(i)`/`Game::Variables#[]`, both
# already-established-safe shapes, and `Party#use_seed`'s own `seed_boosts`
# array is built entirely from `it.*_points* || 0`); `#change_class`'s own
# `class_id` position only (`class_id > 0`, its one real caller `Interpreter#
# do_change_class` passes `cmd.param(2)` directly -- the other three
# positions stay untyped, not annotated). `#battle_row=` is "assign-only"
# (`@row = row == ROW_BACK ? ROW_BACK : ROW_FRONT` never raises on a bad
# `row` on its own) -- every real caller was traced instead: two pass a
# literal `Actor::ROW_*` constant, one passes `Combatant#row`'s own `self[:row]
# || ROW_FRONT`, one is guarded by its own caller's `if m[:row]`, and
# `Game::State.from_lsd`'s own restore passes `sa[:row]`, whose schema entry
# (`SAVE_PARTY_ACTOR` field 0x5B) carries a real `default: 0` -- unlike
# `SAVE_MOVABLE`'s `:map_id`/`:x`/`:y` above, `LCF.to_rb` never returns a bare
# `nil` for this one.
#
# `Game::Map#in_bounds?(x, y)` (`x >= 0 && y >= 0 && x < @width && y <
# @height`) has by far the widest real fan-in of any entry in this table --
# a dozen-plus call sites across `RPG2k::Scene::Map`/`RPG2k::Scene::
# MapViewer`/`game/lsd_io.rb` -- but every one already crashes on a non-
# Integer `x`/`y` today via that same unconditional `>=`/`<` (a plain
# NoMethodError, not a graceful nil-tolerant path), so retyping only changes
# which exception class an already-broken call raises, the same accepted
# reasoning `#half`/`#block_count_through`/`#approach`/`#tint_to`/`#shake`
# below all share -- individual per-call-site tracing was not needed for any
# of them, only confirming the annotated position is used this way with no
# guard in front of it (spot-checked test.rb's own `m.in_bounds?(0, 0)`/
# `m.in_bounds?(4, 0)` against the real compiled entry point regardless).
# `Game::Map#substitute_tile`'s own `layer` position (`layer == 0 ? 0 : 1`,
# a bare `==`, not itself a crash on `nil`) was traced instead: its one real
# caller (`Interpreter#do_tile_substitution`, i.e. `map.substitute_tile
# (cmd.param(0), ...)`) always passes a `cmd.param` result. `#set_tile`/
# `#tile` (both private) only type their own `x`
# position, which each forwards straight into that same already-crashes-
# on-nil `#in_bounds?(x, y)` before doing anything else with it -- their
# public callers (`#set_lower`/`#set_upper`/`#lower`/`#upper`) were not
# separately traced, since any bad `x` reaching them already raises via
# `#in_bounds?` regardless of which side of the call boxes it.
#
# `Game::Transition#half(total)` (`total / 2`) and `#block_count_through
# (frame)` (`frame < 0`) both already crash on a non-Integer argument via
# their own unconditional arithmetic/comparison; their few self-implicit
# callers (`half(@height)`/`half(@width)`, `block_count_through(@frame -
# 1)`/`(@frame)`) all read ivars `#initialize`/`#advance` only ever set to
# real Integers regardless. `Game::Screen#approach(cur, target, step)`'s own
# `target` position (`(target - cur).abs <= step`) is the same shape, called
# only as `approach(@pan_x, @pan_tx, ...)`/`approach(@pan_y, @pan_ty, ...)`,
# both ivars seeded from a literal `0` or an `h[:pan_tx] || 0`-style
# fallback everywhere they're set.
#
# `Game::Screen#tint_to`'s own `frames` position (`frames <= 0`) and
# `#shake`'s own (same shape) are both the crashes-already case too, each
# with exactly one real caller (`Interpreter#do_tint_screen`/
# `#do_shake_screen`), both building `frames` from `cmd.param(i) *
# FRAMES_PER_TENTH`. `#restore_tint`'s own `frames` position, by contrast,
# is "assign-only" (`@frames = frames`, no arithmetic) -- traced instead:
# its one real caller is `Game::State.from_lsd`'s own restore, passing
# `scr[:tint_time_left]`, whose `SAVE_SCREEN` schema entry (field 15)
# carries a real `default: 0`, so `LCF.to_rb` never returns `nil` for it
# even when the chunk's own byte for this field is absent. `#flash`'s own
# five positions (`r, g, b, power` all "assign-only"; `frames` crashes-
# already via its own `frames <= 0`) were all traced: every real call site
# (`Interpreter#do_flash_screen`'s `cmd.param(i) * FLASH_SCALE`,
# `Scene::Map#fire_animation_flashes`'s `(t.flash_red || 0) * 8`-style
# reads, `Scene::Map`'s own literal `STEP_DAMAGE_FLASH`/`(0, 0, 0, 0, 0)`
# calls, scripts/rpg2k_logic_check.rb's literals) already guards or
# defaults every one of the four "assign-only" positions -- the `spr.flash
# (Color.new(...), ...)` calls elsewhere in `scene/map.rb`/`scene/battle.rb`
# are a same-named but unrelated 2-argument method on the vehicle/target
# sprite class, never this `Game::Screen#flash`, so they do not bear on this
# entry at all.
#
# `Game::State#set_screen_transition`'s own `which` position (`which >= 0 &&
# which < SCREEN_TRANSITION_SLOTS`) crashes already on a bad value; its one
# real caller (`Interpreter#execute`'s own `Cmd::CHANGE_TRANSITION` branch)
# passes `cmd.param(0)`.
#
# `Game::Interpreter#skip_to`'s own `indent` position (`c.indent == indent`,
# a bare `==`) was traced: every real caller passes `cmd.indent`, an
# `LCF::EventCommand` reader whose value is always `read_ber`'s own result
# (`parse_event_commands`) -- `read_ber` either returns a real Integer or
# raises `'truncated BER integer'` outright, never `nil`. `#find_choice_
# option`'s own `index` (`c.param(0) == index`, same bare-`==` shape) has
# one real caller, `#choose(index)`, itself called only with a literal (`it.
# choose(0)`) or `@choice_index` (an Integer ivar only ever `+=`/`-=`/`%=`d).
# `#do_control_vars_range_variable`'s own `a`/`b` positions (`src >= a && src
# <= b`, `(a..b)`, ...) crash already on a bad Range endpoint; its one real
# caller (`#do_control_vars`) builds both from `#range(cmd)`'s own `r.begin`/
# `r.end`, which that method's own body only ever assigns from `cmd.param`/
# `Game::Variables#[]` reads or the literal `1..0`/`a..b`, all real Integers.
# `#vehicle_operand`'s own `ref` position (`ref - CHAR_BOAT`) crashes already;
# its one real caller (`#event_operand`) only reaches it after its own `ref.
# nil?`/`ref >= CHAR_BOAT && ref <= CHAR_AIRSHIP` guard already passed, which
# a non-Integer `ref` could never do. `#screen_operand`'s own `attr` position
# (`attr == 4 ? ... : ...`, bare `==`) was traced instead of `ref` (which
# *is* nil-guarded here, but is not the annotated position): its one real
# caller passes `cmd.param(6)` directly. `#queue_level_up_messages`'s own
# `old_level`/`new_level` positions (`new_level > old_level`) crash already;
# both real callers (`#do_change_exp`/`#do_change_level`) pass `a.level`
# (before and after the change) for both. `#trunc_mod`'s own `n` position
# (`n - d * trunc_div(n, d)`) crashes already; its one real caller (`#apply`'s
# own `when 5` branch) passes `cur`, always a `Game::Variables#[]` read --
# `d`/`val` stays untyped here regardless of `#apply` itself being excluded
# above, since only position 1 is annotated on `#trunc_mod`.
#
# `LCF::EventCommand#initialize`'s own `code`/`indent` positions and `LCF::
# MoveCommand#initialize`'s own `command_id`/`a`/`b`/`c` positions are both
# "assign-only" bodies (`@code = code`, etc., no arithmetic at all) -- traced
# instead of assumed: both classes' sole real construction sites
# (`LCF.parse_event_commands`/`.parse_move_commands`) build every one of
# these from `read_ber`, which -- as above -- never returns `nil`, only a
# real Integer or a raised error; `Interpreter#start_death_handler`'s own
# extra `LCF::EventCommand.new(Cmd::TELEPORT, 0, '', tp)` call passes a
# constant and a literal. (Every other `EventCommand.new`/`MoveCommand.new`
# call site in this codebase -- scripts/*.rb, mruby-*/test/*.rb -- either
# runs under plain CRuby, never touching the compiled entry point at all, or
# passes literal integers when it does run under the real mruby VM via
# `mrbtest`, so neither needed separate tracing.)
#
# Round 41 follow-up (a dedicated adversarial correctness sweep of this
# mechanism, not a new motivating case): every prior round's own "later
# round re-checked every remaining annotation" sentence above only ever
# named `mruby-rpg2k/mrblib` (`game.rb`/`interpreter.rb`) and
# `mruby-lcf/mrblib/lcf.rb` -- `mruby-rpg2k/mrblib/scene/*.rb` and
# `mruby-rpg2k/mrblib/game/battle_support.rb`, despite carrying real
# `# bc2cpp: (fixnum...)`/`(symbol...)` annotations of their own on classes
# already in `compiled_gems.rb`'s own `owners:` list (`RPG2k::Scene::
# SaveLoad`/`Title`/`ItemMenu`/`Order`/`Base`/`Map`/`Battle`/`Menu`/
# `DebugMenu`, `RPG2k::Scene::Map::LRUBitmapCache`), were never actually
# swept against this table's own two-part bar at all -- confirmed directly
# by grepping every `# bc2cpp:` annotation in the whole closed world and
# checking which files the prior rounds' own comments ever named. This
# round closes that specific audit gap for the small, easily-traced subset
# below (single- or few-mandatory-argument methods with a short, fully
# enumerable real call-site list); the remainder of `scene/battle.rb`'s own
# ~25 annotations and `scene/battle_support.rb`'s own 1 are NOT covered by
# this round (deliberately left for a future round, not silently skipped:
# `battle.rb` is this codebase's largest, most call-site-dense file, and a
# real per-entry trace to this table's own bar for every one of those would
# be its own dedicated round, not a follow-up item of this one).
#
# `RPG2k::Scene::SaveLoad#move_selection(delta)`/`RPG2k::Scene::Title#
# move_selection(delta)`/`RPG2k::Scene::ItemMenu#move_item_cursor(delta)`/
# `RPG2k::Scene::ItemMenu#move_teleport_cursor(delta)`/`RPG2k::Scene::
# Order#move_cursor(delta)`: five distinct methods (two different classes
# share the `move_selection` name, three different classes share
# `move_cursor`/`move_teleport_cursor` -- each entry below is independently
# gated by its own exact "Owner#name" string, so this has no bearing on
# soundness) all sharing one shape -- a single mandatory `delta`, used only
# in a plain `@index + delta`/`(a + delta) % b`-style arithmetic expression
# with NO nil-guard of any kind anywhere in the body -- and, checked
# directly against the real regenerated `rpg2k_compiled_gen.cpp` (this
# round's own diagnostic build), all five already have a real MONO/TYPED
# devirtualized call site today (a direct `..._impl(...)` call, not a
# `mrb_funcall`), so retyping actually removes a real `mrb_value` unboxing
# step at each, not merely a no-op signature change. Every real caller of
# all five, in the whole closed world, was individually grepped (not
# assumed): each one passes a literal Integer (`1`, `-1`,
# `ItemMenu::COLUMN_MAX` -- itself a literal `= 2`, or `-COLUMN_MAX`) --
# there is no other call site of any of these five methods anywhere in this
# project's own real source.
#
# `RPG2k::Scene::Map::LRUBitmapCache#initialize(capacity_bytes)` is
# "assign-only" (`@capacity_bytes = capacity_bytes`, no arithmetic) --
# traced instead: its only real construction sites are seven `LRUBitmapCache
# .new(constrained_scale(SOME_LITERAL_BYTES))` calls in `scene/map.rb`
# itself, and `#constrained_scale` (a private helper on the very same
# enclosing `RPG2k::Scene::Map`, not `LRUBitmapCache`) always returns a real
# Integer -- either its own literal `base` argument unchanged (the `fps >=
# 60` early return, or its own `rescue StandardError` fallback), or a plain
# arithmetic expression built from that same `base` (`base * fps / 60`, `base
# / CONSTRAINED_SCALE_FLOOR_DIVISOR`) -- never `nil` on any path. Unlike
# `Game::Transition#initialize`/`Game::Map#initialize` above,
# `LRUBitmapCache` is not itself in `DIRECT_CONSTRUCT_TARGETS` (ordinary
# `Class#new` dispatch, never `SEND :new`-devirtualized), so that exclusion
# reason doesn't apply here; it has zero real devirtualized call sites of
# its own today for the ordinary reason every un-direct-constructed
# `#initialize` does (`compile_send`'s call-site-unboxing path is never
# exercised by a plain `.new`), the same lowest-risk "entry-wrapper/impl-
# signature only" shape `Game::Actor#gain_exp`/`#change_level_by`/
# `#free_two_handed_slot` above already established as still worth adding.
#
# `RPG2k::Scene::SaveLoad#draw_slot_label(c, slot_index, color)`'s own
# `slot_index` position (`(slot_index + 1).to_s`, direct arithmetic, no
# guard) has one real caller, `#draw_slot_box(win, inner_w, slot_index)`,
# which itself indexes `@slots[slot_index]` on the very same value BEFORE
# ever calling `draw_slot_label` -- a non-Integer `slot_index` already
# raises there first (`Array#[]` needs an implicit Integer conversion mruby
# never grants a non-Integer), the same "crashes already" shape `Game::Map#
# in_bounds?` above relies on, so no deeper trace into `#draw_slot_box`'s
# own callers was needed. Checked directly against the real regenerated
# output: already has a real MONO/TYPED devirtualized call site today.
#
# Round 46: re-checked every remaining `# bc2cpp: (fixnum/symbol...)`
# annotation this file's own registry can see -- the whole-program
# `Annotations.extract` result, not a fresh grep -- against this table's own
# two-part bar, restricted to the non-`scene/battle.rb` remainder round 41's
# own follow-up above explicitly left open (`scene/battle.rb`'s own dense
# ~25-annotation cluster stays deliberately out of scope again this round,
# for the exact same "its own dedicated round, not a follow-up item" reason;
# `scene/battle_support.rb`'s own one annotation, `Scene::Base#
# sticky_list_top`, is NOT part of that cluster -- it lives in a small,
# separate reopen-`Base` file most of whose own real caller is a single
# `scene/battle.rb` call site, cleanly traced below -- so it IS covered this
# round, closing that specific one-line gap round 41 also named). Six real
# entries below, every one independently traced AND confirmed against a
# real, un-`SKIP_UNSUPPORTED`-hidden regenerated build to actually produce a
# real `_impl` at all (a lesson this round only learned the hard way -- see
# `RPG2k::Scene::SaveLoad#initialize`/`#draw_slot_faces` below: a `#error
# unhandled opcode BLOCK/SENDB/SUPER` line, unlike the "has non-mandatory
# arguments" one, carries no owner/method name of its own, so grepping for
# the candidate's own name past it, as this round's own first pass did,
# silently walks right by it). Seven real, seriously-considered candidates
# from the same sweep were found unsound (three) or structurally moot
# (four: two non-mandatory-arity misses caught before adding, two genuine
# BLOCK/SENDB/SUPER misses caught only by this real compile, all four
# detailed below) and DELIBERATELY EXCLUDED:
#
# `Game::EnemyAi#enemy(id)` and `Game::EnemyAi#set_switch(id, on)` (both
# `game/battle_support.rb`) each open with the exact `id.nil?`-style guard
# this table's own top comment already excludes `Game::Actor#knows_skill?`/
# `#learn_skill` for (`return nil unless ... id && id > 0` /
# `sw[id] = on if sw && id && id > 0`) -- both already tolerate a genuine nil
# `id` today by no-oping gracefully, so a native `mrb_get_args("i", ...)`
# raising TypeError there instead would be a real, novel crash. `Game::
# Interpreter#resume_battle(result)` looked promising (a bare `result ==
# :escape`/`BATTLE_HANDLERS[result]` lookup, no explicit guard at all) but
# traced into a real, structurally deeper problem than a simple guard: its
# one real non-literal caller is `Scene::Battle#finish_battle`'s own
# `owner.resume_battle(result)`, whose own `result` is `battle.result`
# (Game::Battle's own `attr_reader`, `@result` -- nil until a round actually
# settles it). Two of `finish_battle`'s three real call sites call `battle.
# end_round` immediately beforehand, which this round proved always leaves
# `@result` non-nil once `finished?` is true (`@escaped` implies `@result =
# :escaped` was already set at the very same `attempt_escape` call that set
# `@escaped`, per that method's own body; otherwise `end_round`'s own
# `@result = ... if finished? && !@escaped` sets it fresh) -- but the third,
# `Scene::Battle#leave_battle_event_phase`, reads `battle.finished?`/
# `battle.result` directly, with NO intervening `end_round` call of its own
# for that round, after a chain of battle-event-page processing
# (`run_battle_events`/`leave_battle_event_phase` calling each other) that
# could in principle flip `finished?` true mid-round (an event's own effect
# wiping a side) without `end_round` ever having run for THIS round yet --
# meaning `@result` could still be nil at that exact read, on a real path
# this round could not fully rule out without separately proving every
# battle-event command that can affect `alive?(@allies)`/`enemy_active?
# (@enemies)` mid-round never does so before `end_round` next runs. The same
# "can't fully verify, so don't guess" call this table's own `Game::
# Interpreter#apply`/`Game::State#initialize` write-ups already model --
# left off this round's own additions rather than assumed safe.
#
# `RPG2k::Scene::Base#build_list_arrow_sprite(skin, src_y, x, y, z = 450)`
# and `RPG2k::Scene::Base#draw_system_text(bmp, x, y, w, h, text, skin,
# idx = 0, align = 0)` both looked like strong candidates on the annotated
# position's own soundness (`build_list_arrow_sprite`'s `src_y` is traceable
# through its only 4 real call sites -- `Scene::SkillMenu#build_arrow_
# sprite`/`Scene::ItemMenu#build_arrow_sprite`'s own forwarding wrappers,
# fed from `UP_ARROW_SRC_Y = 8`/`DOWN_ARROW_SRC_Y = Window::ARROW_SRC_Y`
# (`= 16`) literals, and `Scene::Battle`'s own two direct calls passing the
# identical `Scene::Base`-local `LIST_UP_ARROW_SRC_Y`/`LIST_DOWN_ARROW_
# SRC_Y` literals -- to a literal-derived Integer every time; `draw_system_
# text`'s own `x`/`y` are the ordinary "crashes already" shape, handed
# straight to a native `RGSS::Bitmap` call or a `+` op with no guard) --
# but BOTH turn out structurally moot regardless: each carries its own
# trailing optional argument (`z = 450`, `idx = 0`/`align = 0`), and a real,
# no-`SKIP_UNSUPPORTED`-hiding regenerated build shows both landing in this
# file's own "does not compile clean at all" exclusion category already
# established for `Game::Actor#set_level`/`#add_state`/`#equip_item`/
# `#change_hp` above (`#error ... has non-mandatory arguments (optional/
# rest/keyword/block) -- not in this prototype's supported subset`) --
# there is no real `_impl` for either one to retype in the first place, so
# adding either "Owner#name" here would be a pure no-op, never a soundness
# problem but never a real win either. Left off this round's own additions
# for that reason, not a nil-safety finding about either method's own body.
#
# `RPG2k::Scene::Base#draw_stat_segment(c, x, y, w, h, label, cur, max,
# can_knockout, skin)` (mand=10) DOES compile clean (confirmed against the
# same real regenerated output): its own `x`/`w` positions are the
# identical "crashes already" shape (`w - x` at the very top of the body,
# unguarded); its own `cur`/`max` positions are NOT annotated (only 2 and 4
# -- `x`/`w` -- carry a `fixnum` token in the real annotation, matching
# `value_font_color`'s own already-excluded `max` staying untouched here
# too). `RPG2k::Scene::Base#sticky_list_top(top, sel_row, row_count,
# visible_rows)` (`scene/battle_support.rb`, see above) has its own
# `sel_row`/`row_count`/
# `visible_rows` positions (2/3/4; `top` stays untyped) each used in a bare
# arithmetic/comparison expression (`[row_count - visible_rows, 0].max`,
# `sel_row < top`, `sel_row - visible_rows + 1`) with no guard anywhere --
# crashes already on any of the three -- and its one real caller (`Scene::
# Battle#battle_list_window`'s own `sticky_list_top(..., sel_row, row_count,
# rows)`) passes `row_count` built purely from `labels.length`/an integer
# `.ceil`/`.max` expression, `rows` the literal `BATTLE_VISIBLE_ROWS = 4`,
# and `sel_row = sel / column_max` -- itself already crashing on a
# non-Integer `sel` before ever reaching this call, so no deeper trace into
# `battle_list_window`'s own callers was needed for that third position
# either.
#
# `RPG2k::Scene::SaveLoad#build_arrow_sprite(src_y)` is the exact same
# shape and same trace as `Scene::Base#build_list_arrow_sprite` above (its
# own near-duplicate, pre-dating the shared helper), but WITHOUT that one's
# own disqualifying optional trailing argument -- `build_arrow_sprite` takes
# just the one mandatory `src_y`, confirmed compiling clean for real. Its
# two real callers (`#build_arrow_sprites`) pass `UP_ARROW_SRC_Y = 8`/
# `DOWN_ARROW_SRC_Y = Window::ARROW_SRC_Y`, both literal-derived Integers.
#
# `RPG2k::Scene::SaveLoad#draw_slot_faces(c, inner_w, state)`'s own
# `inner_w` position looked sound on the same "crashes already" bar
# `#draw_slot_label` (`slot_index`, via the same `#draw_slot_box` caller)
# already established (`start_x = inner_w - (...)`, unguarded, and
# `#draw_slot_box` itself already uses the same `inner_w` unguarded one line
# earlier via `Bitmap.new(inner_w, ...)`) -- but the method's own body
# separately contains `pairs.first(MAX_SLOT_FACES).each_with_index do
# |(name, index), i| ... end`, a real block/`SENDB` this prototype's own
# opcode subset does not support, confirmed by a real, un-`SKIP_UNSUPPORTED`
# regenerated build showing `#error unhandled opcode BLOCK`/`SENDB` inside
# its own `_impl` body and, independently, by the real "skipped
# (unsupported, left on the interpreter)" list itself naming this method --
# no `_impl` exists at all regardless of `inner_w`'s own soundness, the same
# "does not compile clean" exclusion category `Game::Actor#initialize`
# already established. `RPG2k::Scene::SaveLoad#initialize(parent, state,
# mode)`'s own `mode` position (`@mode = mode # :save or :load`, assign-
# only, every real in-game construction site passing a literal `:save`/
# `:load`) looked equally sound in isolation, but the same real regenerated
# build shows the same class of failure one line earlier in this
# constructor's own body -- `super parent` (`#error unhandled opcode
# SUPER`) and `@slots = (1..SLOT_COUNT).map { |slot| ... }` (`#error
# unhandled opcode BLOCK`/`SENDB` again) -- so this one has no real `_impl`
# either, for reasons entirely unconnected to `mode`'s own soundness. Both
# left off this round's own additions for that "no `_impl` to retype"
# reason, not a nil-safety finding about either method's own annotated
# position.
#
# `RPG2k::Scene::Menu#wait_term_for(key, term_name)`'s own `key` position
# (only `key`, not `term_name`, carries the annotation) is nil-tolerant on
# its own (`key == :wait`, a bare `==`) -- traced instead: its one real
# caller, `#build_commands`'s own `keys.map { |key, term_name| [key,
# wait_term_for(key, term_name)] }`, destructures `keys`, which is always
# either the literal `RPG2K_COMMAND_KEYS` array (five literal `[:symbol,
# :symbol]` pairs) or `RPG2K3_COMMAND_IDS` (an eight-entry literal Hash of
# the same shape) filtered through `filter_map` (which only keeps a real
# hit) plus one more literal pair appended -- every element either branch
# can ever produce is a real, literal `Symbol`, never nil. `RPG2k::Scene::
# Menu#enter_actor_selection(key)` is even more directly provable: its own
# body is assign-only (`@pending_key = key`), and its one real caller,
# `#select_command`'s own `case key when :skill, :equip, :status, :row ...
# enter_actor_selection(key)`, only ever reaches that call from inside a
# `when` branch Ruby's own `===` dispatch has already matched against those
# four literal symbols -- `key` is PROVABLY one of them by the time
# `enter_actor_selection` is called at all, structurally, regardless of
# anything upstream of `@commands`/`@index`.
#
# `RPG2k::Scene::VehicleWorld#initialize(scene, rng, type)` (`scene/
# base.rb`; positions 1/2 carry a *class*-name annotation, `ClassAnnotations`
# territory, not this table's own concern) has its own `type` position
# (position 3, `Symbol`) assign-only (`@type = type`) -- traced instead: its
# one real construction site, `Scene::Map`'s own `Game::Vehicle::TYPES.
# each_with_object({}) { |type, h| h[type] = VehicleWorld.new(self, @rng,
# type) }`, iterates the literal `Game::Vehicle::TYPES = [:boat, :ship,
# :airship].freeze` -- every `type` this ever constructs with is a real,
# literal Symbol.
#
# Explicitly considered and left OFF this round's own additions, for the
# same "found and correctly excluded" reasons this table's own precedents
# already establish: `RPG2k::Scene::Base#value_font_color(have, max,
# can_knockout)` carries a real `(fixnum, fixnum, )` annotation on BOTH
# `have` and `max`, but `max`'s own use (`max && max > 0 && have <= max /
# 4`) is itself a defensive truthiness guard on the exact annotated
# position -- the identical `knows_skill?`/`learn_skill` shape this table's
# own top comment already declines to retype, so the whole entry stays off
# rather than only partially applying an annotation this mechanism has no
# way to split mid-tuple. `RPG2k::Scene::ItemMenu#prompt_item_target(id)`
# (`@pending_item = id`, assign-only, no guard) was NOT added despite
# looking identical in shape to the five `move_*` entries above: unlike
# those, its own `id` traces back through `#choose_item`'s own internal
# `id`/`it`/`sk` locals (never a bare parameter), which would need the same
# "much deeper trace into an unrelated method's own control flow" this
# table's own `Game::Party#can_cast?`/`Game::Interpreter#apply` write-ups
# already decline to force through -- left for whichever future round
# actually completes `scene/item_menu.rb`'s own sweep.
# `RPG2k::Scene::Base#clip_text_to_width(c, text, w)`'s own `w` position
# (`return '' if w <= 0`, crashes-already, no guard) is real and sound by
# the same bar as every other entry here, but has ZERO real call sites of
# any kind that devirtualize to it today -- checked directly against the
# real regenerated output: its own one real call site (`RPG2k::Scene::
# Map#draw_message_run`'s `clip_text_to_width(c, seg[:text], w)`) is a
# genuine self-implicit call whose receiver's *static* owner (`RPG2k::
# Scene::Map`) differs from the method's own defining owner (`RPG2k::
# Scene::Base`, `Map`'s real superclass) -- this file's own MONO/TYPED
# devirtualization never does inheritance-aware/superclass resolution (see
# `monomorphic_target`'s own comment elsewhere in this file), so this call
# site compiles to plain `mrb_funcall`, tagged `// POLY` in the real output,
# regardless of `:clip_text_to_width` being MONO by name (exactly one real
# bytecode def anywhere). Left off this round's own additions: unlike
# `LRUBitmapCache#initialize` above (still worth adding despite zero call
# sites, since a constructor's own entry wrapper still unboxes real incoming
# arguments), a same-shaped but non-constructor method with zero call sites
# and no real prospect of ever gaining one (the cross-owner shape above is
# structural, not incidental) was judged not worth the added surface for
# strictly zero measured benefit -- a judgment call, not a soundness finding,
# so a future round is free to disagree and add it.
#
# Round 47: the dedicated `scene/battle.rb` sweep round 41's own follow-up
# explicitly deferred ("its own dedicated round, not a follow-up item"),
# closed now. Swept all 15 real `# bc2cpp:` annotation comments in
# `mruby-rpg2k/mrblib/scene/battle.rb` (14 of them naming a `fixnum`/
# `Symbol` position; the 15th, on `#initialize`, is a class-name annotation
# -- `(RPG2k::Scene::Map, Hash, Game::Interpreter)`, `ClassAnnotations`
# territory, not this table's own concern), plus `mruby-rpg2k/mrblib/game/
# battle_support.rb`'s own 3 and `mruby-rpg2k/mrblib/scene/
# battle_support.rb`'s own 1 -- confirmed by a fresh whole-closed-world grep
# for `# bc2cpp: (`, not just trusted from the dispatching round's own
# count. The latter two files needed no new work: `game/battle_support.rb`'s
# `Game::EnemyAi#enemy`/`#set_switch` are the exact two methods round 46's
# own writeup above already traced and excluded (both open with an
# `id && id > 0`-style guard tolerating a genuine nil `id` today); its
# third annotation, `EnemyAi#initialize(db, state)`, carries no fixnum/
# symbol position at all (`Game::State`, a class-name annotation). `scene/
# battle_support.rb`'s own one annotation, `Scene::Base#sticky_list_top`,
# is already on this list (round 46 above).
#
# Every one of `scene/battle.rb`'s own 9 real additions below was checked
# against a real, `SKIP_UNSUPPORTED=0` regenerated `rpg2k_compiled_gen.cpp`
# (built from scratch this round: `git submodule update --init 3rd/mruby
# 3rd/mruby-marshal 3rd/mruby-onig-regexp 3rd/mruby-stringio
# 3rd/mgem-list`, all nine `patches/*.patch` files applied via `scripts/
# apply_mruby_patch.bash`, then a real host `mrbc` built by running `rake`
# from *inside* `3rd/mruby` itself with `HOST_CXX=c++`, the same recipe
# this file's own prior follow-ups already document) -- not merely
# `grep`ped for its own name in a `SKIP_UNSUPPORTED=1` run, which this
# round's own immediate predecessor (round 46) learned the hard way
# produces a real, misleadingly-clean-looking false positive: a method's
# own `_impl(mrb_state* M, ...)` signature line is ALWAYS emitted, even
# when its body is nothing but `#error unhandled opcode ...` lines, because
# bc2cpp.rb prints the signature before ever walking the body's own
# instructions. Reading each candidate's own real generated BODY (not just
# grepping for its declaration) caught two genuine misses this round's own
# first pass, going in, would otherwise have missed entirely:
#
# `#enter_battle_result(result)` (`@ui[:result] = result; ...; [@ui[:status_win],
# @ui[:cmd_win]].each { |w| w.dispose if w }; ...`) and `#battle_result_lines
# (result, troop)` (`troop.drops(...).each do |iid| ... end`, `@state.party.
# actors.each do |a| ... end`) both looked promising on paper -- `#error
# unhandled opcode BLOCK`/`SENDB` in each one's own real generated body says
# otherwise: both end in a real Ruby block this compiler does not support,
# so neither has a real `_impl` to retype regardless of anything else. (Both
# also fail this table's own OTHER bar independently, a second, unrelated
# reason each stays off this list: `result`'s own real value at the one
# non-literal, non-`end_round`-preceded call site --
# `Scene::Battle#leave_battle_event_phase`'s own `if battle.finished? ...
# enter_battle_result(battle.result)`, with no intervening `end_round` call
# for that round -- is the exact same "can't fully verify @result is
# non-nil there" gap round 46's own `Game::Interpreter#resume_battle`
# write-up above already found and declined to force through; every OTHER
# real call site of `#enter_battle_result` -- `#settle_already_finished_battle`/
# `#finish_round_animation`/`RPG2k3::Scene::Battle#drive_battle_atb`/
# `#finish_round_animation`'s own four `battle.result` reads, plus the
# literal `enter_battle_result(:escape)` in `#try_battle_escape` -- calls
# `battle.end_round` immediately beforehand or passes a literal, so only
# this one path is unresolved; `#battle_result_lines`'s own `result`
# position is nil-TOLERANT regardless, not crashes-already: `return
# [term(:escape_success)] if result == :escape; return [term(:defeat)]
# unless result == :victory` both bare `==`, so a genuine nil `result`
# reaching here today silently reads as "defeat" rather than raising,
# exactly the `knows_skill?`/`learn_skill` shape this table's own top
# comment already declines to retype.) `#battle_level_up_lines(actor,
# before_level, before_skills)`'s own `before_level` position looked sound
# on its own value-safety merits too (its one real caller,
# `#battle_result_lines`'s own `lines.concat(battle_level_up_lines(a,
# before_level, before_skills)) if before_level`, guards it directly at the
# call site) -- moot regardless: its own body's `((before_level +
# 1)..actor.level).each do |lv| ... actor.learn_table.each do |sid, at|
# ... end end` hits the identical BLOCK/SENDB gap, confirmed directly
# against its own real generated body, independent of `#battle_result_lines`
# already being excluded above for an unrelated reason.
#
# `#draw_battle_stat_segment(c, x, y, w, label, cur, max, can_knockout)`'s
# own `x`/`w` positions (`limit = x + w`, `cx = x`, both unguarded
# arithmetic, the identical "crashes already" shape round 46's own `Scene::
# Base#draw_stat_segment` entry above already establishes for the same
# `x`/`w` pair on that method's own near-duplicate namesake) looked sound
# too -- also moot regardless: its own body's `pieces.each do |text, pw,
# align, color| ... end` hits the same BLOCK/SENDB gap, confirmed directly
# against its own real generated body. `#battle_list_window(x, w, labels,
# sel, z, column_max: 1, idxs: nil, desc: nil, scroll_key: nil)`'s own `w`
# position was never a real prospect at all -- four trailing keyword
# arguments with defaults make this non-mandatory arity, the same
# `#error ... has non-mandatory arguments` gap `Game::Actor#set_level`/
# `#equip_item` above already establish, confirmed directly against its own
# real generated `#error` line rather than assumed from the signature.
#
# The real, sound 9 below (every one confirmed CLEAN against the real
# generated body -- no `#error` anywhere in it -- and every annotated
# position either crashes already today with no nil-guard in front of it,
# or every real caller was individually traced to a provably-safe value):
# `#battler_z(i)` (`100 + (@ui[:troop].members.size - 1 - i)`, unguarded;
# its 3 real callers -- `#build_battle_sprites`'s own `Array.new(...) { |i|
# ... }` block index, `#refresh_battle_sprites`'s own `#rebuild_battler_
# sprite(i, foe)` forwarding an `each_with_index` `i`, and `#reveal_battle_
# monster(index)` forwarding `Interpreter#take_revealed_monsters`'s own
# drained `@revealed_monsters` queue, pushed only via `Interpreter#execute`'s
# own `cmd.param(0)` -- all provably Integer). `#actor_sprite_z(i)` (`200 +
# i`, unguarded; its 2 real callers -- `#build_actor_sprite`'s own `i`
# forwarding param, itself always an `Array.new(...) { |i| ... }` block
# index or `@ui[:allies].length - 1` / an already-`return unless i`-guarded
# `Array#index` result at every one of ITS OWN 3 real call sites -- and
# `#reset_actor_battler_z`'s own `each_with_index` `i` -- all provably
# Integer). `#battle_grid_position(i, party_size)`'s own `party_size`
# position only (`GRID_TABLE_0[party_size - 1]`, unguarded; `i` stays
# untyped, not annotated); its one real caller passes `@ui[:allies].
# length`. `#move_battle_target_cursor(delta, foes_count)`'s own
# `foes_count` position only (`foes_count > BATTLE_VISIBLE_ROWS`,
# unguarded; `delta` stays untyped); both real callers pass `foes.length`.
# `#move_battle_list_index(index, delta, size)`, all three positions
# (`index + delta`, `target >= size`, `index / BATTLE_LIST_COLUMN_MAX`,
# `size - 1`, every one unguarded arithmetic/comparison -- crashes already
# regardless of either real caller's own `@ui[:skill_i]`/`@ui[:item_i]`/
# `delta`/`.length` values, so neither needed separate tracing, the same
# `Game::Map#in_bounds?` reasoning above). `#battle_skill_unavailable?
# (cost, sk)`'s own `cost` position only (`current_actor.mp < cost`,
# unguarded; `sk` stays untyped); both real callers destructure `sid, cost
# = @ui[:skills][@ui[:skill_i]]` the same way. `#draw_gauge_system2(c,
# system2, x, y, cur, max, which)`'s own `cur`/`max` positions (`width = 25
# * cur / max`, unguarded arithmetic reached regardless of the earlier
# `max == 0`/`cur == max` bare-`==` branches, which only select a draw
# variant, never filter out a bad value -- crashes already); `which` stays
# untyped. `#draw_number_system2(c, system2, x, y, value)`'s own `value`
# position (`value >= 1000`, `value %= 1000`, ..., all unguarded). `#refresh_
# battle_list_arrows(scroll, row_count, rows)`, all three positions
# (`scroll > 0`, `scroll + rows < row_count`, unguarded) -- its one real
# caller is inside `#battle_list_window` itself, which never compiles (see
# above), so this has zero real devirtualized call sites today, the same
# "entry-wrapper/impl-signature only, still worth it" shape `Game::Actor#
# gain_exp`/`RPG2k::Scene::Map::LRUBitmapCache#initialize` above already
# establish -- not a soundness concern, just the honest measured-benefit
# note.
# A real Ruby local-variable name is a perfectly ordinary identifier in
# Ruby's own grammar but can still collide with a C++ reserved word --
# found for real (not hypothetical) while verifying OPTIONAL_ARG_SUPPORT:
# `RPG2k::Scene::Map#page_field(name, default)` has a real, literal
# `default` parameter (mruby-rpg2k/mrblib/scene/map.rb), which
# compile_method's own arg_names codegen previously emitted completely
# unescaped -- `mrb_value default` as a real C++ parameter/local
# declaration, a guaranteed g++ syntax error the moment this exact method
# ever became compile-clean (not yet today -- it separately still hits a
# real, unrelated `rescue`+`yield` gap -- but a real, live landmine
# regardless, exactly the kind of bug this file's own verification passes
# exist to catch before it ships). Deliberately NOT a full C++ keyword
# table -- just real, plausible Ruby parameter names this codebase's own
# survey has actually found colliding with a reserved word; `sanitize_c_ident`
# is the single place every arg_names entry passes through, so a future
# collision is a one-line fix here, not a repeat of this same bug.
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
  # Round 41 additions -- see this constant's own top comment for the full
  # per-entry trace.
  'RPG2k::Scene::SaveLoad#move_selection',
  'RPG2k::Scene::Title#move_selection',
  'RPG2k::Scene::ItemMenu#move_item_cursor',
  'RPG2k::Scene::ItemMenu#move_teleport_cursor',
  'RPG2k::Scene::Order#move_cursor',
  'RPG2k::Scene::Map::LRUBitmapCache#initialize',
  'RPG2k::Scene::SaveLoad#draw_slot_label',
  # Round 46 additions -- see this constant's own top comment for the full
  # per-entry trace.
  'RPG2k::Scene::Base#draw_stat_segment',
  'RPG2k::Scene::Base#sticky_list_top',
  'RPG2k::Scene::SaveLoad#build_arrow_sprite',
  'RPG2k::Scene::Menu#wait_term_for',
  'RPG2k::Scene::Menu#enter_actor_selection',
  'RPG2k::Scene::VehicleWorld#initialize',
  # Round 47 additions -- see this constant's own top comment for the full
  # per-entry trace.
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

# SUPER_SUPPORT: an explicit, human-vetted "Owner#name" allowlist gating
# real `super`/`super(...)` compilation -- the same NATIVE_ARG_TARGETS/
# DIRECT_CONSTRUCT_TARGETS-style table this file already uses whenever a
# mechanism's own soundness depends on a whole-program fact compile_insn
# itself has no way to re-verify locally at codegen time (here: that no
# real call site anywhere in the program ever passes an actual block
# literal into the ENCLOSING method -- see below).
#
# A real closed-world survey (every real #error unhandled opcode SUPER
# across the whole program, mirroring docs/adr/0145's own RESCUE survey)
# found 11 methods blocked ONLY by SUPER, 10 of them inside owners this
# project's own three *-compiled gems already cover -- those 10 fall into
# exactly two real shapes (see compile_insn's own SUPER case for the
# shapes themselves): `RPG2k::Scene::Battle#initialize`/`DebugMenu#
# initialize`/`ItemMenu#initialize`/`Menu#initialize` (`super parent`,
# explicit single arg, into `RPG2k::Scene::Base#initialize`), and
# `RPG2k3::Scene::Battle#update`/`#drive_battle_command`/
# `#enter_command_phase`/`#open_battle_options`/`#advance_actor`/
# `#prev_commandable_actor_index` (bare `super`, zero mandatory args, into
# `RPG2k::Scene::Battle`'s own same-named methods). The 11th
# (`RGSS::Bitmap::LoadError#initialize`, into native `RuntimeError#
# initialize`) isn't a covered owner at all and reaches a native
# superclass regardless -- explicitly never a target here, same as any
# other native-reaching call site this file's own devirtualization always
# stays out of.
#
# A follow-up survey against a fresh whole-program regen (same recipe)
# found 8 MORE methods blocked ONLY by SUPER, every one an `#initialize`
# calling `super parent` (the exact first shape above) into the same,
# already-clean `RPG2k::Scene::Base#initialize`: `RPG2k::Scene::
# ChipsetEditor#initialize`, `EquipMenu#initialize`, `GameOver#
# initialize`, `MapViewer#initialize`, `Order#initialize`, `SkillMenu#
# initialize`, `StatusMenu#initialize`, `Title#initialize` -- exactly the
# "later round" tools/bc2cpp/compiled_gems.rb's own `RPG2k::Scene::Base`
# comment already flagged when the first 4 landed. Re-checked both real
# soundness facts fresh for these 8, not assumed from the first 4: grepped
# every real `.new` call site for all 8 classes across the whole closed
# world (mruby-rpg2k/mruby-lcf/mruby-rgss mrblib plus scripts/
# rpg2k_scene_check.rb) -- none pass a block literal; and the whole closed
# world still has exactly the same 3 real `include`s total (two unrelated
# `Enumerable`s, one top-level `include RGSS`), none between any of these
# 8 classes and `RPG2k::Scene::Base`.
#
# Every real `super`/`super(...)` (mrbc's own codegen, `codegen_super`/
# `codegen_zsuper`) unconditionally forwards whatever block was passed
# into the CURRENT method, whether or not that method ever otherwise
# touches its own block -- but a bc2cpp-compiled `_impl` function has no
# block parameter in its own C++ signature at all (every register besides
# self/mandatory-args is unconditionally nil-initialized, see
# compile_method's own preamble), so this forwarded value is always nil
# here, correct only if no real caller of the CURRENT (super-calling)
# method ever actually supplies a block. Checked directly, not assumed,
# for every one of these 10 entries: grepped every real call site of
# `Battle.new`/`DebugMenu.new`/`ItemMenu.new`/`Menu.new` and of
# `.update`/`.drive_battle_command`/`.enter_command_phase`/
# `.open_battle_options`/`.advance_actor`/`.prev_commandable_actor_index`
# across the whole closed world -- none pass a block literal. This is a
# real, narrow soundness fact about THIS PROGRAM's own call sites, not a
# permanent language guarantee, so it belongs in this same human-vetted
# table rather than assumed automatically the way RESCUE/RAISEIF's own
# always-safe translation could be (see compile_insn's own RESCUE
# comment) -- adding a future entry here means re-checking this exact
# fact for it, not just checking arity/cleanliness.
#
# Also checked, not assumed: neither `RPG2k::Scene::Base` (the first
# group's own target) nor `RPG2k::Scene::Battle` (the second's) has any
# `include`/`prepend` between it and its own caller class -- a real
# `super` walks the actual C ancestor chain, which a naive "jump straight
# to the registered superclass" skips a same-named module override on;
# the whole closed world has exactly one real `include` anywhere
# (`Enumerable`, an unrelated `mruby-lcf/mrblib/lcf.rb` class), so this
# holds for every entry below, but -- same as the block-forwarding check
# above -- is a fact about this program today, re-checked per future
# entry, never a standing assumption.
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
].freeze

# Call-site-specific devirtualization: unlike monomorphic_target (a name
# with exactly one definition anywhere in the whole program), this asks a
# narrower question about ONE specific SEND -- "is THIS receiver provably a
# freshly constructed instance of one exact, statically known class" --
# which can still resolve a POLY-named call site to a direct C++ call.
#
# Walk backward from `idx` (a SEND's own position) looking for whatever
# last wrote `reg` (following MOVE chains, exactly like IvarLayout.
# trace_type), until hitting a `SomeClass.new(...)` SEND on that same
# register, then keep tracing the *same* register one step further back
# through a GETMCNST*/GETCONST constant-path chain (mirrors GETMCNST's own
# codegen comment: it reads a constant off of r<d> and overwrites r<d> in
# place, so each segment's base is still findable on the same register)
# to recover the class's own fully-qualified name (e.g. "Game::Picture"),
# built the same left-to-right, `::`-joined, no-leading-colon way
# build_registry's own CLASS/MODULE walk builds every MethodDef#owner --
# so it can be matched directly against one.
#
# Deliberately never asks "which class might this receiver be" the way a
# real type system (or a superclass/MRO walk) would -- only "is this
# receiver POSITIVELY, EXACTLY this one class". A bare `ClassName.new`
# always allocates the literal receiver class it's sent to, never a
# subclass in disguise, so this needs no inheritance model at all to stay
# sound: an inherited method this can't see (no matching owner in the
# registry) just stays a safe miss, never a wrong answer. Bails to nil
# (ordinary dynamic dispatch, always safe) on anything else -- a computed
# or aliased class reference (`x.class.new`, `superclass.new`), a receiver
# reused from an opaque argument, or any other write to `reg` this
# doesn't recognize.
# `ivar_classes` (owner -> {ivar_name => class_name}, from ClassLayout)
# and `arg_classes` (per-mandatory-position class name, from
# ClassAnnotations) are both optional, additional terminal sources this
# same backward scan can bottom out at, alongside the original fresh-
# `.new` chain: a GETIV of an ivar ClassLayout already proved always
# holds one exact class (`@state.foo`), or an opaque incoming argument a
# real magic-comment class annotation names (`def foo(state); state.foo;
# end`). Every caller of this function still gets the exact same
# fresh-`.new` behavior it always had when these are omitted (both
# default to nil, and `next unless ...` bails cleanly on a nil lookup).
#
# `resolving_new:` (default false, every existing caller's own behavior
# unchanged) lets a caller start the walk already "inside" the SEND :new
# case below -- i.e. resolve *this exact* `.new` call's own receiver
# instead of chasing an object's origin through a later call on it. Used
# by compile_send's own native-construction devirtualization (the
# NATIVE_CONSTRUCT_TARGETS path): called with `idx`/`reg` pointing at the
# `SEND :new` instruction itself being compiled right now, so the very
# first thing this walk looks for is the GETCONST/GETMCNST chain that fed
# *that* call its own receiver, with the same conservative bail-to-nil on
# anything else (a GETIV, another SEND, ...) the ordinary chase already
# has -- deliberately narrower than the ivar-hint/argument-annotation
# terminal sources above, which don't apply to a `.new` call's own
# receiver at all.
#
# CHAINED_ACCESSOR_SUPPORT: `class_layout` (owner -> {ivar_name =>
# class_name}, the FULL, every-owner table ClassLayout.analyze itself
# builds -- unlike `ivar_classes` above, which every real call site
# already pre-slices down to just the CURRENT method's own owner) and
# `registry` (name -> [MethodDef], for the same `:ivar_accessor` lookup
# IVAR_ACCESSOR_DEVIRT's own compile_send branch uses) are a second,
# independent pair of optional additional terminal sources, both default
# nil so every pre-existing caller that doesn't pass them keeps its exact
# prior behavior (see the guard at the top of the SEND0/SEND case below).
# When present, they let a plain (non-`new`) SEND mid-chain -- e.g.
# `@state.screen.foo`, where `.screen` is the SEND landing here -- also
# resolve to a known class, by chaining two already-proven whole-program
# facts that nothing before this connected: (1) this SEND's OWN receiver
# is itself traceable (recursing into this exact same function, scanning
# strictly before this SEND's own instruction index -- terminates for the
# identical reason the outer `(idx-1).downto(0)` loop already does, since
# `i` only ever shrinks) to some exact class `R`; (2) `R` has a real,
# whole-program `:ivar_accessor` MethodDef for this SEND's own method
# name (`registry[name]`, filtered to `owner == R` -- see MethodDef's own
# `kind` comment and build_registry's own attr_reader/writer/accessor
# case for why a getter's MethodDef is always registered under the bare
# ivar name, a setter's always under "#{name}="); (3) `R`'s OWN
# class_layout entry (a DIFFERENT class than the CURRENT method's own
# owner, which is exactly why the full table is needed here and not just
# `ivar_classes`) already names a known class for that same ivar (getter
# name == ivar name, confirmed by the same build_registry case just
# cited). Every hit through this path is still just as "unsound without a
# runtime check" as a GETIV/argument-annotation hit above -- every real
# consumer (compile_send's own TYPED/IVAR_ACCESSOR_DEVIRT branches)
# already guards it with a real `mrb_obj_class` check before trusting it,
# so this only ever risks a missed optimization, never a wrong answer.
def trace_new_target(irep, idx, reg, ivar_classes = nil, mand = 0, arg_classes = nil, resolving_new: false, owner: nil,
                      class_layout: nil, registry: nil, container_constants: nil)
  path = []
  # GETCONST/GETMCNST are only ever valid class-name evidence *while
  # resolving a `.new` call's own receiver* -- never on their own. A bare
  # `@position = POS_BOTTOM` (a plain Integer constant, no `.new` in
  # sight anywhere) must never be mistaken for "@position always holds
  # an instance of a class named POS_BOTTOM": real bug, caught running
  # this against real game source (`Game::MessageConfig#@position`,
  # `Game::NumberInput#@digits`, ... all Integer-valued constants, none
  # of them classes). `resolving_new` only ever becomes true right after
  # a `SEND :new` is found (with nothing already peeled off `path`) --
  # or starts true already, for the `resolving_new:` keyword-arg caller
  # described above -- gating GETMCNST/GETCONST on one of those two.
  (idx - 1).downto(0) do |i|
    insn = irep.instructions[i]
    d = insn.args[/^R(\d+)/, 1]
    next unless d == reg

    case insn.op
    when 'MOVE'
      reg = insn.args.scan(/R(\d+)/).flatten[1]
    when 'SEND0', 'SEND'
      return nil if resolving_new || !path.empty?

      # Same charset as compile_send's own name extraction (see its own
      # comment) -- kept in sync for consistency, though `name == 'new'`
      # below can never be affected by the operator characters that fix
      # covers.
      name = insn.args[/:([\w+\-*\/<>=!?\[\]&|^~%@]+)/, 1]
      if name == 'new'
        resolving_new = true
      elsif name == 'dup' && registry && (registry['dup'] || []).all? { |md| md.owner == '<native>' }
        # DUP_PRESERVES_CLASS: a bare, blockless, argument-less `.dup`
        # (`SEND0`/`SEND` only -- this `elsif` is unreachable from the
        # `SENDB` arm below, which returns immediately for any name other
        # than `new`, so a stray block on a `.dup` call never reaches
        # here) always constructs an object of the EXACT SAME class as
        # its own receiver, for ANY receiver whatsoever -- read directly
        # against this repo's own pinned 3rd/mruby (831da26b)
        # `mrb_obj_dup` (src/class.c): `mrb_obj_alloc(mrb,
        # mrb_type(obj), mrb_obj_class(mrb, obj))`, i.e. the new object's
        # class is read straight off the receiver, unconditionally, no
        # class-specific special-casing anywhere in that function. Bound
        # as plain `Kernel#dup` (src/kernel.c's own MRB_MT_ENTRY table,
        # `MRB_SYM(dup), MRB_ARGS_NONE()`) -- MRB_ARGS_NONE is exactly
        # why only the 0-arg SEND0/SEND shape is ever real `.dup`; this
        # program's own bytecode never overrides it either (grepped: no
        # `def dup` in any closed-world mrblib file), which is exactly
        # what the `registry['dup']` re-check just above rules out for
        # good, the identical "own-registry re-validation" discipline
        # core_array_return? already applies to CORE_ARRAY_RETURN_METHODS
        # (a future `def dup` in this program's own source would fail
        # that check and this branch would simply stop firing, never keep
        # trusting a now-false claim). So this receiver's own class,
        # however THIS function itself already knows how to prove it
        # (another `.new`, a chained accessor, a GETIV of an
        # already-known ivar, ...), is exactly this `.dup` call's own
        # result class too -- recursing into this exact same function for
        # the receiver (identical "SEND overwrites its receiver register
        # with the result, in place" invariant the chained-accessor
        # branch below already relies on, so `i`/`reg` here name the
        # receiver's own producer instruction) reuses every one of those
        # proofs for free, with the exact same termination argument
        # (strictly decreasing `i`) as that branch's own recursive call.
        #
        # `SEND0` never prints an `n=` field at all (always 0 args, same
        # fact this function's own chained-accessor branch already cites
        # against real `mrbc -v` output), so the guard below only ever
        # has real work to do for a plain `SEND` -- a real `.dup(x)` call
        # site (MRB_ARGS_NONE, so genuinely an ArgumentError at runtime)
        # is not evidence of anything and must not be trusted here.
        n_match = insn.args.match(/n=(\d+|\*)/)
        return nil if n_match && n_match[1] != '0'

        return trace_new_target(irep, i, reg, ivar_classes, mand, arg_classes, owner: owner,
                                 class_layout: class_layout, registry: registry,
                                 container_constants: container_constants)
      else
        # CHAINED_ACCESSOR_SUPPORT (see this function's own top comment):
        # `name` isn't `new`, so this can never join the fresh-`.new`
        # chain above, but it might still be a chained `:ivar_accessor`
        # read (`@state.screen.foo` -- `.screen` is the SEND landing
        # here) whose own return class is provable a different way.
        # `class_layout`/`registry` are both nil for every caller that
        # doesn't opt in (in particular every `resolving_new: true`
        # caller -- e.g. DIRECT_CONSTRUCT_TARGETS' own two call sites --
        # never even reaches this `else` branch at all: the
        # `resolving_new || !path.empty?` guard at the very top of this
        # `when` already returned nil for them), so this is a strict,
        # additive no-op unless a caller actually threads both through.
        return nil unless class_layout && registry

        # Real attr_reader semantics take exactly zero arguments (3rd/
        # mruby/src/class.c's own `attr_reader` -- confirmed already, see
        # MethodDef's own `kind` comment) -- gating on that here (not just
        # on the registry/class_layout match below) rules out a same-
        # named-but-different-arity POLY method this SEND could otherwise
        # be calling instead, the identical real-bug shape the MONO/TYPED
        # paths' own arity guards already exist to catch (see compile_send's
        # own comment on Input.repeat?/Game::MoveRoute#repeat?).
        # SEND0's own real disassembly never prints "n=" at all (always
        # zero args, src/vm.c's OP_SEND0 hardcodes c=0 -- same fact
        # compile_send's own `n_match` comment already established) so a
        # nil match here still correctly means n=0.
        n_match = insn.args.match(/n=(\d+|\*)/)
        return nil if n_match && n_match[1] != '0'

        # This SEND's own receiver was whatever last wrote `reg` strictly
        # BEFORE this instruction's own index `i` -- the exact same "SEND
        # overwrites its receiver register with the result, in place"
        # invariant the `.new` case below already relies on, just for
        # THIS SEND instead of a later one. Recursing into this exact same
        # function reuses the identical "find what wrote reg before
        # position idx" contract every other caller already gets from
        # `trace_new_target(irep, idx, reg, ...)` -- no new mechanism
        # needed. Bounded by the same `(i-1).downto(0)` scan this
        # recursion's own call performs, so it always terminates: `i` is
        # strictly less than the outer call's own `idx` (it came from that
        # same `(idx-1).downto(0)` loop), and every further nested
        # recursion's own `i` is again strictly less than the `i` that
        # spawned it -- a single, monotonically shrinking index, the same
        # way the un-recursive scan above already terminates on its own.
        recv_class = trace_new_target(irep, i, reg, ivar_classes, mand, arg_classes, owner: owner,
                                       class_layout: class_layout, registry: registry,
                                       container_constants: container_constants)
        return nil unless recv_class

        # `registry[name]` is already sliced to real MethodDefs literally
        # named `name` -- a real attr_writer's own MethodDef is always
        # registered under "#{mname}=" instead (build_registry's own
        # attr_reader/writer/accessor case, not the bare `mname` a getter
        # gets), so this can only ever match a GETTER's own entry, never a
        # setter's -- no separate `name.end_with?('=')` check needed here.
        accessor = registry[name]&.find { |md| md.owner == recv_class && md.kind == :ivar_accessor }
        return nil unless accessor

        # `R`'s (== `recv_class`) OWN ivar-class hint for this same name
        # (getter name == ivar name, same build_registry case just cited).
        # `class_layout[recv_class]` can still be raw, UNKNOWN-poisoned
        # ClassLayout.analyze fixed-point-sweep state -- the one real
        # caller mid-sweep (ClassLayout.analyze's own SETIV loop) passes
        # its own in-progress `classes` table directly here rather than
        # paying to re-filter it on every single SETIV site -- so this
        # never hands back ClassLayout::UNKNOWN as if it were a real class
        # name, the same "no wrong guess, ever" bar every other terminal
        # case in this function already holds itself to.
        #
        # `class_layout.key?(recv_class)` (never a bare `class_layout[recv_class]`
        # here) -- real, checked bug caught comparing this function's own
        # diagnostic stderr output before/after this change: ClassLayout.
        # analyze's own `classes` table (the one real caller mid-sweep passes
        # as `class_layout`, per the comment above) is a `Hash.new { |h, k|
        # h[k] = {} }`, so an ordinary `[]` read on a class this scan has
        # never SETIV'd anything for yet silently *inserts* an empty entry --
        # changing that hash's own insertion order (and so its diagnostic
        # `each`-order in the `== known-ivar-class hints ==` listing) despite
        # this being nothing but a probing read. `Hash#key?` never touches
        # the default proc, so this reads without ever mutating. Confirmed
        # this was real, not hypothetical: the exact same 12-line CLASS_HINT
        # reordering (zero content change, zero `.cpp` byte change) appeared
        # in EVERY gem's own diagnostic before this fix, including
        # mruby-lcf-compiled/mruby-rgss-compiled, whose own generated output
        # never differs at all -- purely a side effect of this scan probing
        # classes it never otherwise touches.
        recv_ivars = class_layout[recv_class] if class_layout.key?(recv_class)
        hint = recv_ivars && recv_ivars[name]
        return nil unless hint && hint != ClassLayout::UNKNOWN

        return hint
      end
    when 'SENDB'
      # BLOCK_CARRYING_NEW: `Klass.new(...) { block }` -- e.g.
      # `Array.new(@base_raw.size) { |i| ... }`, mruby-array-ext's own
      # documented block form of `Array#initialize`, confirmed as a real,
      # measured shape in this program's own bytecode (`Game::Actor#@base`)
      # -- compiles to `SENDB`/`SSENDB` exactly the way any other
      # block-carrying call does, never plain `SEND0`/`SEND`, so it was
      # previously invisible to this function entirely (this `when` only
      # ever matched `SEND0`/`SEND` before, and the bare `case`'s own
      # `else` arm below returns nil for anything unmatched). A block
      # argument to `#initialize` never changes WHICH class gets
      # constructed -- `.new` always allocates an instance of the exact
      # receiver class first (real Ruby object-model semantics, the same
      # trust this function's own `resolving_new` flow already rests on
      # for the blockless form), then merely runs `#initialize` -- with or
      # without a block -- against that already-allocated instance. So
      # this only ever needs to set the exact same `resolving_new = true`
      # flag the `SEND0`/`SEND` arm's own `name == 'new'` case already
      # sets, and let the SAME downstream GETCONST/GETMCNST chain-walking
      # logic below (shared, not duplicated) resolve the receiver's class
      # name exactly as it already does for a blockless `.new`.
      #
      # `SSENDB` (a block-carrying `self.new`) is deliberately NOT
      # included here -- unlike the chained-accessor branch above (which
      # explicitly re-validates a `self`-prefixed accessor call through
      # `registry`), there is no real measured `self.new { ... }` call
      # site in this program to vet, and a wrong guess here (self's OWN
      # class differs by receiver, not a fixed name) is a real path this
      # function has no chain-walking logic for regardless -- narrower
      # than strictly necessary, exactly per this function's own "no
      # wrong guess, ever" bar, rather than reaching for a shape nothing
      # here actually exercises.
      return nil if resolving_new || !path.empty?

      name = insn.args[/:([\w+\-*\/<>=!?\[\]&|^~%@]+)/, 1]
      return nil unless name == 'new'

      resolving_new = true
    # Same register, still tracing further back for the class object that
    # was `.new`'s own receiver -- SEND overwrites its receiver register
    # with the result, in place.
    when 'GETIV'
      return nil if resolving_new || !path.empty?

      ivar = insn.args[/@(\w+)/, 1]
      return ivar_classes && ivar_classes[ivar]
    when 'ARRAY', 'ARRAY2'
      # EACH_BLOCK_SUPPORT: an array literal (`items = [1, 2, 3]`) always
      # creates a real Array -- confirmed directly against
      # 3rd/mruby/src/vm.c's own OP_ARRAY (`regs[a] =
      # ary_new_from_regs(mrb, b, a)`), never assumed. Like GETIV above,
      # only valid as the END of the trace (a `.new` chain or a
      # constant path already in progress means this ARRAY belongs to a
      # different expression reusing the register -- registers are
      # reused, see trace_type's own comment).
      return nil if resolving_new || !path.empty?

      return 'Array'
    when 'HASH'
      # HASH_EACH_SUPPORT: a hash literal (`h = { a: 1, b: 2 }`) always
      # creates a real Hash -- confirmed directly against 3rd/mruby/src/
      # vm.c's own OP_HASH (`mrb_hash_new_capa` then a `mrb_hash_set` loop,
      # result written to `regs[a]`), never assumed. Same end-of-trace
      # gating as ARRAY/ARRAY2 above.
      return nil if resolving_new || !path.empty?

      return 'Hash'
    when 'RANGE_INC', 'RANGE_EXC'
      # INTERP_UNLOCK: a range literal (`(a..b).each`, `(a...b).each`)
      # always creates a real Range -- confirmed directly against
      # 3rd/mruby/src/vm.c's own OP_RANGE_INC (`regs[a] =
      # mrb_range_new(mrb, regs[a], regs[a + 1], 0)`) and OP_RANGE_EXC
      # (same with excl=1), never assumed. Same end-of-trace gating as
      # ARRAY above.
      return nil if resolving_new || !path.empty?

      return 'Range'
    when 'GETMCNST'
      # CONST_CONTAINER_SUPPORT: accumulating a qualified-name segment is
      # harmless whether or not `resolving_new` -- it only ever matters
      # once GETCONST (the chain's own root, always reached last in this
      # backward walk) decides what to DO with the assembled `path`, and
      # that decision is still fully gated below (resolving_new keeps its
      # own pre-existing DIRECT_CONSTRUCT_TARGETS-only behavior; the new
      # non-resolving_new branch is additive, see GETCONST's own comment).
      #
      # Not `$`-anchored on purpose -- a trailing "; R6:name" local-
      # variable comment (real code, same shape as SETIV's own) would
      # otherwise land inside the captured segment.
      path.unshift(insn.args[/::(\w+)/, 1])
    when 'GETCONST'
      # "GETCONST R4 Integer" or, with a named-local destination
      # register, "GETCONST R3 MAX_DIGITS\t; R3:d" -- \S+ (not the rest
      # of the line) stops at the first whitespace/tab, same fix as
      # compile_insn's own GETCONST codegen needed for the identical bug.
      const_name = insn.args[/^R\d+\s+(\S+)/, 1]

      # CONST_CONTAINER_SUPPORT: a completely separate question from
      # everything below this point (which only ever resolves a bare/
      # qualified name to a CLASS NAME string, for a `.new` receiver) --
      # here, `resolving_new` is false, so this GETCONST/GETMCNST chain is
      # not building a `.new` target at all; it's the receiver of an
      # ordinary call (e.g. `Game::Vehicle::TYPES.each { ... }`), and the
      # only useful fact this function can hand back is "this constant's
      # own VALUE is a proven Array/Hash" -- fed by build_registry's own
      # SETCONST scan (`container_constants`, see that scan's own
      # comment), keyed by the exact same fully-qualified dotted name
      # this walk already assembles (`path` holds every already-visited
      # GETMCNST segment, most-recently-visited first per `unshift`, so
      # `[const_name] + path` is this chain's own full qualified name,
      # root first -- identical convention to the `path.unshift(const_name)
      # ; path.join('::')` the resolving_new branch below uses for the
      # exact same chain shape).
      unless resolving_new
        return nil unless container_constants

        unless path.empty?
          full = ([const_name] + path).join('::')
          return container_constants[full]
        end

        # A bare, single-token reference (`STAT_NAMES.each`) -- real
        # Ruby's own lexical constant lookup, walked the SAME innermost-
        # first nesting order as the resolving_new branch below (and
        # compile_insn's own GETCONST codegen), but checked against
        # `container_constants` instead of DIRECT_CONSTRUCT_TARGETS.
        # Never a blind guess: a name absent from every nesting level
        # (including bare, i.e. real top-level/Object scope) is simply
        # not in the table, so this returns nil -- a safe miss, exactly
        # like every other terminal case in this function.
        if owner
          nesting = owner.to_s.sub(/\.singleton\z/, '').split('::')
          nesting.length.downto(1) do |n|
            candidate = "#{nesting.first(n).join('::')}::#{const_name}"
            return container_constants[candidate] if container_constants.key?(candidate)
          end
        end
        return container_constants[const_name]
      end

      # Round 41's own documented gap (DIRECT_CONSTRUCT_TARGETS' own top
      # comment, "bare-reference gap"): when `path` is still empty right
      # here, this GETCONST is the WHOLE receiver expression -- a bare,
      # single-token reference like `Switches` -- not the qualifying
      # root of an already-multi-segment chain a prior (later-executed,
      # so already-visited in this backward walk) GETMCNST built onto
      # `path` (that shape, e.g. "Game::Transition", is already handled
      # correctly below by the plain `path.join('::')` fallback and is
      # never touched by this block: `path` is non-empty by the time
      # GETCONST is reached for it). A bare single-token reference is
      # resolved through real Ruby's own lexical constant lookup, but
      # ONLY as far as this function can actually PROVE sound: never a
      # blind `"#{owner}::#{const_name}"` guess the way
      # resolve_singleton_receiver gets away with elsewhere in this file
      # (that helper only ever fires at a point build_registry is
      # actively walking a namespace it is itself opening, where the
      # prepended segment is real by construction; a `.new` call site's
      # own bare receiver carries no such guarantee -- real Ruby's own
      # Module.nesting-based lookup could just as easily resolve a bare
      # name to a same-named TOP-LEVEL constant instead, if a namespace-
      # qualified one doesn't actually exist, and this function has no
      # general access to the whole-program registry needed to tell
      # which). So: only ever resolve a bare reference to a namespace-
      # qualified form when that EXACT string is already a known,
      # independently-vetted DIRECT_CONSTRUCT_TARGETS entry -- never a
      # general namespace lookup against the wider registry -- walking
      # `owner`'s own real lexical nesting chain innermost first
      # (mirroring real Ruby's own Module.nesting search order, and
      # compile_insn's own GETCONST codegen's `owner_path`/
      # lexical_scope_path, which resolves a bare reference's real
      # runtime value the exact same innermost-first way; see that
      # codegen's own comment) so a same-named INNER scope entry would
      # be preferred over an outer one, exactly like real Ruby. Any bare
      # name that doesn't resolve this way (not in that table, from any
      # nesting level) falls straight through to the exact same "just
      # the bare token" behavior this function has always had -- a
      # provably safe miss, never a wrong guess, for every call site
      # this change doesn't specifically target. (Even were this
      # resolution somehow wrong for some byzantine real-Ruby shadowing
      # case this reasoning missed, every consumer of this function's
      # return value that matters for codegen correctness -- the MONO
      # NATIVE_CONSTRUCT_TARGETS/DIRECT_CONSTRUCT_TARGETS paths and the
      # TYPED path, compile_send's own -- independently re-verifies a
      # `known`/`known_class` match with a real runtime
      # `mrb_class_ptr(recv) == ...` guard before ever taking the direct-
      # call fast path, falling back to ordinary mrb_funcall otherwise;
      # `recv` itself there is always whatever compile_insn's own
      # GETCONST codegen actually resolves at runtime, independent of
      # this guess. This block is still written to never rely on that
      # net, per this table's own "no wrong guess, ever" bar.)
      if path.empty? && owner
        nesting = owner.to_s.sub(/\.singleton\z/, '').split('::')
        nesting.length.downto(1) do |n|
          candidate = "#{nesting.first(n).join('::')}::#{const_name}"
          return candidate if DIRECT_CONSTRUCT_TARGETS.include?(candidate)
        end
      end

      path.unshift(const_name)
      return path.join('::')
    else
      return nil
    end
  end
  # `reg` was never written in this straight-line body -- an opaque
  # incoming argument (same convention as IvarLayout.trace_type's own
  # final fallback: register N, 1-indexed, is argument N for N <= mand).
  # A magic-comment class annotation is the only source for this (there's
  # no whole-program call-site pooling for object-class arguments the way
  # ArgTypes does for Fixnum -- a POLY name's call sites could each be a
  # genuinely different real method, so pooling them would be unsound;
  # ClassAnnotations sits on one real irep by construction instead, same
  # reasoning as Annotations' own comment).
  pos = reg.to_i
  return arg_classes[pos - 1] if arg_classes && pos.between?(1, mand)

  nil
end

# NIL_TOLERANT_JOIN's own predicate (see ClassLayout.analyze's own call
# site for the full rule this serves): true only when `reg`'s value at
# `idx` was unambiguously just loaded from a literal `nil` (`LOADNIL`),
# following the same defensive MOVE-chain-following idiom
# trace_eqq_literal_receiver below already established (mrbc could in
# principle interpose a MOVE before the literal load; every real
# disassembly checked here never does, but following the chain costs
# nothing and keeps this sound either way). Anything else writing `reg`
# first -- a real object, a computed value, an opaque incoming argument --
# returns false: a missed nil-tolerant opportunity is always safe (falls
# straight through to the ordinary "disagreeing evidence" join, exactly
# today's pre-existing behavior), while a wrong "yes, this is nil" would
# silently drop real evidence -- this stays exactly as conservative as
# every other backward-scan guard in this file.
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

# CONST_CONTAINER_SUPPORT's own predicate (see build_registry's SETCONST
# handling and trace_new_target's GETCONST/GETMCNST terminal for the two
# ends of the same feature): true only when `reg`'s value at `idx` is
# unambiguously a fresh Array/Hash/Range literal, optionally wrapped in
# exactly one trailing `.freeze` -- confirmed against real `mrbc -v`
# disassembly for the universal `CONST = [...].freeze` / `CONST =
# {...}.freeze` idiom this codebase's own module-level constants
# overwhelmingly use (`ARRAY R1 2` / `SEND0 R1 :freeze` / `SETCONST NAME
# R1`, freeze reusing its own receiver register in place, the same "SEND
# overwrites its receiver register with the result" invariant every other
# backward scan in this file already relies on).
#
# `.freeze` is recognized ONLY in this one narrow adjacency -- never as a
# general "any `.freeze` call anywhere is a safe passthrough" rule. Real
# `Kernel#freeze` (3rd/mruby/src/kernel.c's own mrb_obj_freeze,
# unconditionally `return self`) is the correct read for THIS specific
# shape, but this file never assumes a POLY name means the same thing
# everywhere it appears -- confirmed a real, unrelated bytecode override
# exists (`RGSS::Transition#freeze`, mruby-rgss/mrblib/lib.rb, an
# unrelated screen-transition snapshot method with a totally different
# return value). This helper structurally can never reach that method's
# own body: it only ever recognizes `:freeze` as a hop-through when the
# instruction directly beneath it, on the exact same register, is already
# a proven ARRAY/ARRAY2/HASH/RANGE_INC/RANGE_EXC literal -- a real
# `RGSS::Transition` instance is never constructed that way at a real
# SETCONST site.
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

# LITERAL_EQQ_SUPPORT: backward-scan a `:===` SEND's own receiver register
# for a literal Fixnum/Symbol write a few instructions earlier in the same
# straight-line irep -- real Ruby's own `case x; when 5 ... when :bar ...
# end` desugaring (`when` compiles to `LITERAL === x`), confirmed against
# mrbc's own real disassembly for both shapes (a toy `case x; when 5;
# when :bar; end` method body):
#   LOADI_5  R4  (5)
#   MOVE     R5  R3   ; R3 holds the case value
#   SEND     R4  :===  n=1
#   ...
#   LOADSYM  R4  :bar
#   MOVE     R5  R3
#   SEND     R4  :===  n=1
# -- i.e. SEND's own receiver register (R4 above, `d` in compile_send) is
# freshly written by the literal load, immediately before the argument-
# register MOVE. Deliberately a separate, self-contained walk from
# trace_new_target above, not a reuse of it: this asks a completely
# different question ("did a LOADI*/LOADSYM literal just write this
# register", never "is this register traceable to a known object's
# class"), and none of trace_new_target's own GETCONST/GETMCNST/GETIV/
# ARRAY terminal cases apply to a literal receiver at all -- sharing that
# function here would mean bending its own already-intricate case
# analysis around an unrelated question, a real readability/soundness risk
# for no real code reuse (this walk is a handful of lines). Still follows
# the same defensive MOVE-chain-following idiom that function established
# (same reasoning: mrbc could in principle interpose a MOVE before the
# literal load; every real disassembly checked here never does, but
# following the chain costs nothing and keeps this sound either way).
# Returns {type: :fixnum, value: "5"} / {type: :symbol, name: "bar"}, or
# nil the moment anything else writes `reg` first (an opaque incoming
# argument, a computed value, ...) -- a safe miss, same as every other
# backward-scan guard in this file: compile_send's own caller falls
# straight through to ordinary POLY dynamic dispatch on nil, never guesses.
def trace_eqq_literal_receiver(irep, idx, reg)
  (idx - 1).downto(0) do |i|
    insn = irep.instructions[i]
    d = insn.args[/^R(\d+)/, 1]
    next unless d == reg

    case insn.op
    when 'MOVE'
      reg = insn.args.scan(/R(\d+)/).flatten[1]
    when 'LOADSYM'
      # Same shape as LOADSYM's own codegen above (":(\S+)" -- stops at
      # the first whitespace, real code has a trailing local-variable
      # comment on a named-destination register the same way GETCONST's
      # own args do).
      name = insn.args[/:(\S+)/, 1]
      return name ? { type: :symbol, name: name } : nil
    when /^LOADI/
      # Same two-shape literal extraction LOADI's own codegen above uses
      # (parenthesized for the small-immediate variants, bare for LOADI8/
      # 16/32) -- see that codegen's own comment for why both forms exist.
      lit = insn.args[/\(([^)]+)\)/, 1] || insn.args[/^R\d+\s+(-?\d+)/, 1]
      return lit ? { type: :fixnum, value: lit } : nil
    else
      # Anything else writing `reg` first (GETIV, another SEND, a computed
      # expression, ...) means the receiver isn't a bare literal -- a safe
      # miss, never a wrong guess.
      return nil
    end
  end
  # `reg` was never written in this straight-line body -- an opaque
  # incoming argument or block-entry register, not a literal. No
  # arg_classes-style terminal fallback here on purpose: unlike
  # trace_new_target's class-annotation fallback (a real magic-comment
  # fact about an argument's *class*), there is no equivalent "this
  # argument is always literal value N" whole-program fact this compiler
  # tracks anywhere -- a safe miss.
  nil
end

def pure_mandatory_arity?(irep)
  enter = irep.instructions.find { |i| i.op == 'ENTER' }
  return true unless enter # no ENTER at all: a 0-arg method, trivially fine.

  fields = enter.args.split(':').map { |f| f[/\d+/].to_i }
  fields[1..].all?(&:zero?)
end

# The real mandatory-argument count an ENTER instruction declares (the same
# `fields[0]` pure_mandatory_arity? already parses out, just returned
# instead of only checked) -- used by compile_send's own MONO devirtualization
# guard to refuse a direct call whose call-site argument count doesn't match
# the target's real arity (see that guard's own comment for the real
# Input.repeat?/Game::MoveRoute#repeat? name-collision bug this catches).
def mandatory_arity(irep)
  enter = irep.instructions.find { |i| i.op == 'ENTER' }
  return 0 unless enter

  enter.args.split(':').first.to_i
end

# CALLSITE_OPTIONAL_ARG_SUPPORT: the real optional-argument count `mandatory_
# arity`'s own sibling leaves out -- ENTER's aspec field 2 (0-indexed 1),
# same parse, just the next field instead of the first. 0 for a no-ENTER/
# pure-mandatory method, same as mandatory_arity's own 0 case. Used by
# compile_send's own call-site devirtualization guard (see
# pure_mandatory_or_optional_arity?'s own comment) to know how many trailing
# `mrb_nil_value()` placeholders/what `bc2cpp_given_opt` value a direct call
# needs when the call site itself supplied fewer than the target's full
# mandatory+optional count -- mirrors compile_method's own entry-wrapper
# `bc2cpp_given_opt = mrb_get_argc(M) - mand` computation exactly, just
# computed from the call site's own already-known argument count instead of
# a runtime mrb_get_argc call.
def optional_arity(irep)
  enter = irep.instructions.find { |i| i.op == 'ENTER' }
  return 0 unless enter

  fields = enter.args.split(':').map { |f| f[/\d+/].to_i }
  fields[1] || 0
end

# CALLSITE_OPTIONAL_ARG_SUPPORT: `pure_mandatory_arity?`'s own sibling,
# widened to also accept a real OPTIONAL_ARG_SUPPORT shape (plain positional
# optional arguments, `def foo(a, b = 1)`) as call-site-devirtualizable --
# every other non-mandatory field (rest/mandatory2/keyword/kwrest/block)
# still has to be zero, exactly as before. This alone doesn't prove the
# target's own body actually compiles with that shape (optional_arg_table's
# own JMP-shape recognition can still fail, e.g. a default-value expression
# this file can't translate) -- callers of this predicate still gate on
# `compiles_clean?` separately, same as the pure-mandatory path always has,
# so a method whose ENTER *looks* optional-shaped but whose body doesn't
# actually compile still correctly falls back to ordinary dynamic dispatch.
def pure_mandatory_or_optional_arity?(irep)
  enter = irep.instructions.find { |i| i.op == 'ENTER' }
  return true unless enter # no ENTER at all: a 0-arg method, trivially fine.

  fields = enter.args.split(':').map { |f| f[/\d+/].to_i }
  fields[2..].all?(&:zero?)
end

# OPTIONAL_ARG_SUPPORT: ENTER's own real aspec is mandatory1:optional:
# rest:mandatory2:keyword:kwrest:block -- this only ever models the second
# field, plain positional optional arguments (`def foo(a, b = 1)`); every
# other nonzero field (rest/mandatory2/keyword/kwrest/block) is still
# completely unmodeled, exactly as before this existed. Returns
# [optional_count, jump_source_addrs, jump_target_addrs] for a real,
# exactly-recognized optional-only shape, or [0, nil, nil] for anything
# else (a 0-arg/no-ENTER/pure-mandatory method, an ENTER whose optional
# field is nonzero but some OTHER field is too, or one whose optional
# field is nonzero alone but the real bytecode right after ENTER doesn't
# match the one shape this recognizes) -- compile_method's own #error stub
# is the fallback for all of those, identical to any other unrecognized
# shape in this file; never guessed at.
#
# Real ENTER-then-jump-table shape, confirmed directly against real
# disassembly rather than assumed from vm.c's own OP_ENTER comment alone
# (`def foo(a, b = 1, c = 2)` compiles to `ENTER 1:2:0:0:0:0:0:0` followed
# by exactly 3 (`optional + 1`) consecutive real, addressable JMP
# instructions): entry k (0-indexed, k = how many of the real optional
# arguments THIS call actually supplied) jumps straight to wherever this
# method's own bytecode starts computing the (k+1)th optional argument's
# own default-value expression, or straight to the method's own real first
# statement when k == optional (every default already supplied by the
# caller). This *is* the real mruby VM's own OP_ENTER PC-skip mechanism
# (3rd/mruby/src/vm.c) -- compile_method reproduces it as an ordinary
# native `switch`/`goto` instead of relying on any VM PC arithmetic (see
# emit_optional_dispatch), so every default-value expression this file can
# already translate (a literal, an ivar read, a reference to an earlier
# argument -- confirmed directly against real disassembly for all three,
# not just the literal case) just works, completely unmodified, wherever
# it's reached from.
# JMPNOT/JMPIF/JMPNIL's own real disassembly shape is always
# "R<reg>\t<target>", optionally followed by a "; R<reg>:<name>" comment
# when the register operand happens to be a real, named local variable --
# confirmed as a genuinely new shape while building KEYWORD_ARG_SUPPORT's
# own KEY_P (the first opcode in this file to ever write its own result
# directly into a keyword's own named register; every prior real JMPIF/
# JMPNOT/JMPNIL call site in this codebase always tested an unnamed temp
# register instead, so no comment ever appeared before). Every call site
# in this file used to extract the target with a bare `/(\d+)\s*$/`
# (anchored to the true end of the string) -- silently wrong the moment a
# real comment like "; R5:b" doesn't itself end in a digit: the regex
# simply fails to match anywhere, returning nil, and `nil.to_i` is 0 --
# not a raised error, a silent `goto L0` instead of the real target,
# caught for real (not hypothetical) building this against
# `def foo(a, b: 1, c:)`. Anchoring right after the register operand
# instead is correct whether or not a trailing comment follows.
def jmp_target_after_reg(args)
  args[/^R\d+\s+(\d+)/, 1].to_i
end

def optional_arg_table(irep)
  enter = irep.instructions.find { |i| i.op == 'ENTER' }
  return [0, nil, nil] unless enter

  fields = enter.args.split(':').map { |f| f[/\d+/].to_i }
  _mand, opt, rest, mand2, kw, kwrest, block = fields
  return [0, nil, nil] unless opt.positive? && rest.zero? && mand2.zero? && kw.zero? && kwrest.zero? && block.zero?

  enter_idx = irep.instructions.index { |i| i.op == 'ENTER' }
  jmps = irep.instructions[enter_idx + 1, opt + 1]
  return [opt, nil, nil] unless jmps && jmps.size == opt + 1 && jmps.all? { |i| i.op == 'JMP' }

  [opt, jmps.map(&:addr), jmps.map { |i| i.args.strip[/\d+/].to_i }]
end

# KEYWORD_ARG_SUPPORT: real per-keyword parameter naming, shared between
# compile_method (building _impl's own signature and the entry wrapper's
# real mrb_kwargs extraction) and compile_insn's own KEY_P/KARG cases
# (which only ever see one instruction, and derive everything they need --
# including this exact name -- straight from that instruction's own `:sym`
# operand, never from an externally threaded table). Both sides only ever
# agree because both run the identical symbol text through the identical
# sanitize_c_ident + prefix scheme.
def kwarg_param_name(sym)
  "bc2cpp_kwarg_#{sanitize_c_ident(sym)}"
end

def kw_given_param_name(sym)
  "bc2cpp_kw_given_#{sanitize_c_ident(sym)}"
end

# KEYWORD_ARG_SUPPORT: ENTER's own `keyword`/`kwrest` fields -- this only
# ever models plain keyword arguments with `kwrest` == 0 (no real `**rest`
# receiver); a real closed-world survey of every currently-blocked
# keyword-only method found `kwrest` == 0 on every single one, so this is
# not a narrowing against real code today, just an honest boundary for
# what's actually verified (a real `**rest` needs this method's own
# generated register to be populated directly by the VM's own ENTER
# semantics rather than by any KARG/KEY_P instruction at all -- confirmed
# directly against real disassembly -- a materially different shape this
# round doesn't attempt).
#
# Unlike OPTIONAL_ARG_SUPPORT's own ENTER-jump-table replacement, no
# suppressed-address/glue-at region is needed here at all: KEY_P/KARG/
# KEYEND (compile_insn's own new cases) are ordinary, always-correct,
# already-in-place-in-the-real-bytecode instructions once those three
# opcodes have a real translation -- every already-supported opcode around
# them (JMPIF for the presence check, JMP to skip a redundant KARG, LOADI/
# GETIV/... for a default-value expression, exactly the same generality
# OPTIONAL_ARG_SUPPORT's own default-value computation already relies on)
# just works unmodified. This function's only real job is enumerating
# every distinct keyword this irep's own KEY_P/KARG instructions name, in
# real bytecode-declaration order, and whether each is required (a bare,
# unguarded KARG with no KEY_P anywhere for that same symbol -- confirmed
# directly against real disassembly: `c:` with no default compiles to a
# lone `KARG R4 :c`, nothing else) or optional (a real `KEY_P`/`JMPIF`
# guard precedes its own KARG) -- compile_method needs this list to build
# _impl's own real parameter list and the entry wrapper's own real
# mrb_kwargs extraction; compile_insn's own KEY_P/KARG cases need none of
# it, deriving everything from their own instruction alone (see
# kwarg_param_name's own comment).
#
# Returns an array of {name:, required:} descriptors, or nil for anything
# this doesn't model (rest/mandatory2/optional/kwrest/block nonzero, or a
# real mismatch between ENTER's own declared keyword count and the number
# of distinct symbols actually found -- a defensive sanity check, never
# silently guessed past).
def keyword_arg_table(irep)
  enter = irep.instructions.find { |i| i.op == 'ENTER' }
  return nil unless enter

  fields = enter.args.split(':').map { |f| f[/\d+/].to_i }
  _mand, opt, rest, mand2, kw, kwrest, block = fields
  return nil unless kw.positive? && opt.zero? && rest.zero? && mand2.zero? && kwrest.zero? && block.zero?

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

# REST_ARG_SUPPORT: ENTER's own `rest` field (`def foo(a, *rest)`) --
# scoped to a real, exactly-recognized "rest alone, nothing else non-
# mandatory" shape (`opt`/`mand2`/`kw`/`kwrest`/`block` all zero), matching
# a real closed-world survey that found every currently-blocked `*rest`
# method already shaped this way. Unlike OPTIONAL_ARG_SUPPORT's own real
# ENTER jump table or KEYWORD_ARG_SUPPORT's own real KEY_P/KARG
# instructions, a plain `*rest` needs no opcode-level recognition at all:
# confirmed directly against real disassembly (`def foo(a, *rest)`
# compiles to `ENTER 1:0:1:0:0:0:0:0` followed immediately by the method's
# own real first body instruction -- nothing in between) that mruby's own
# real `OP_ENTER` VM semantics (3rd/mruby/src/vm.c) populate the rest
# register directly with a real, already-boxed Array value before the
# method body ever starts running, the exact same "no opcode needed, the
# entry wrapper's own real mrb_get_args call does all the real work"
# shape KEYWORD_ARG_SUPPORT's own `**kwrest` case would need too (not
# attempted here -- see keyword_arg_table's own comment). The rest
# register itself sits immediately after the last mandatory argument's own
# register, real disassembly confirms directly -- the exact same
# contiguous layout OPTIONAL_ARG_SUPPORT's own `total_args = mand + opt`
# already established, so compile_method folds `*rest` into that same
# `total_args`-driven mechanism (one more contiguous slot, a plain
# `mrb_value` parameter needing no register-initialization or signature
# change of its own at all) rather than building a separate one.
#
# Returns true for a real, recognized rest-only shape, false otherwise.
def rest_only_arity?(irep)
  enter = irep.instructions.find { |i| i.op == 'ENTER' }
  return false unless enter

  fields = enter.args.split(':').map { |f| f[/\d+/].to_i }
  _mand, opt, rest, mand2, kw, kwrest, block = fields
  rest.positive? && opt.zero? && mand2.zero? && kw.zero? && kwrest.zero? && block.zero?
end

def report_annotation_candidates(ireps, registry, arg_types, annotations)
  candidates = []
  registry.each_value do |defs|
    defs.each do |d|
      next unless d.irep

      # Mirrors drop_unsafe_embeddings' own gate: no ivar on this class can
      # ever embed unless its #initialize is compilable at all (found in
      # the registry) *and* purely mandatory-arity -- annotating an opaque
      # argument elsewhere in the class is pointless if that gate already
      # vetoes the whole class regardless.
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

      # A second, purely diagnostic pass: an opaque mandatory argument
      # consumed directly by a fixnum-fastpath arithmetic/comparison op
      # (ADD/SUB/MUL/EQ/LT/LE/GT/GE and their *I immediate forms) is real
      # evidence worth surfacing too, even though -- unlike a SETIV site --
      # annotating one of these can never change compiled output:
      # IvarLayout.trace_type (the only consumer of arg_types/annotations)
      # only ever reaches its "incoming argument" fallback from a SETIV
      # trace, never from here. Purely a documentation aid: a magic-comment
      # annotation doubles as "this argument is always an Integer in
      # practice" for a human reading the `def` line, not just a codegen
      # unlock -- see the "go on annotating rpg2k for readability" follow-up.
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
# Step 6h: whole-program static call-target reachability -- diagnostic
# only, never consulted by codegen (the same standing as Step 6e's
# annotation-candidate report above). Answers a different question than
# MONO/POLY registry resolution: not "if this name is called, which def
# wins" but "is this name ever a call target anywhere in the whole
# program's own bytecode at all". A compiled entry point whose name never
# appears here, and whose name extract_native_call_names above also never
# finds, has no known caller anywhere this tool can see -- a real,
# load-bearing signal for "is this compiled entry point safe to delete",
# surfaced by the "== never called ==" diagnostic near the bottom of this
# file's own driver.
#
# Three ways a whole-program bytecode instruction can name a method
# without ever emitting a literal SEND/SSEND targeting it:
#   - SEND0/SEND/SSEND0/SSEND's own `:name` operand -- the ordinary case.
#   - A fixed-name opcode -- ADD/SUB/MUL/DIV/EQ/LT/LE/GT/GE/GETIDX/
#     GETIDX0/SETIDX and their *I/*ILV immediate variants always dispatch
#     a hardcoded method name (`+`, `==`, `[]`, ...) on their own
#     fixnum/array/hash-fastpath-failure path -- see compile_insn's/
#     compile_cmp's own comments for the exact mrb_funcall shape each one
#     emits. IMPLICIT_DISPATCH_NAMES below mirrors that same fixed-name
#     table; keep the two in sync if a future round gives a new opcode a
#     fixed-name mrb_funcall fallback.
#   - LOADSYM's own `:name` operand -- a bare symbol *literal* anywhere in
#     the program (`send(:name)`, `method(:name)`, `&:name` block
#     conversion, `respond_to?(:name)`, or just a Hash key that happens to
#     share a compiled method's own name). Deliberately as conservative as
#     extract_native_call_names above: counting a symbol literal as
#     "reachable" even when it turns out to be plain data, not a real
#     dispatch, only ever shrinks the "never called" list, never wrongly
#     grows it.
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
      when 'SEND0', 'SEND', 'SSEND0', 'SSEND', 'LOADSYM'
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
  C_TYPE = { fixnum: 'mrb_int', symbol: 'mrb_sym' }.freeze

  # box/check/unbox/err for each embeddable primitive type's GETIV/SETIV
  # codegen (see IvarLayout.trace_type's own LOADSYM comment for why a raw
  # `mrb_sym` -- not an `mrb_value`-boxed one -- is just as safe to embed
  # as `mrb_int` already is: mruby's own symbol table
  # (3rd/mruby/src/symbol.c) is never swept per-symbol, only freed in bulk
  # at mrb_close, so a `mrb_sym` field needs no GC-reachability keep-alive
  # any more than a plain integer does).
  TYPE_OPS = {
    fixnum: { box: 'mrb_fixnum_value', check: 'mrb_integer_p', unbox: 'mrb_integer', err: 'Integer' },
    symbol: { box: 'mrb_symbol_value', check: 'mrb_symbol_p', unbox: 'mrb_symbol', err: 'Symbol' },
  }.freeze

  def initialize(ireps, registry, ivar_layout, class_layout = {}, class_annotations = {}, annotations = {},
                 superclass_of = {}, element_layout = {}, element_annotations = {}, container_constants = {})
    @ireps = ireps
    # CONST_CONTAINER_SUPPORT: real, fully-qualified constant name ->
    # 'Array'/'Hash'/'Range' -- build_registry's own SETCONST scan (see
    # that table's own comment). Read only by the block recognizers'
    # static receiver-class gate, threaded through trace_new_target the
    # same additive way @class_layout/@registry already are.
    @container_constants = container_constants
    # ELEMENT_CLASS_SUPPORT: owner -> {ivar => element class name}
    # (ArrayElementLayout.analyze's own filtered result) and irep label ->
    # ElementAnnotations::Annotation. Both are read ONLY by the block
    # emitters' own per-element devirtualization, which guards every use
    # with a real runtime `mrb_obj_class` check -- see ArrayElementLayout's
    # own header for the full soundness argument.
    @element_layout = element_layout
    @element_annotations = element_annotations
    # The per-element class currently in scope, set by the block emitters
    # around one inlined loop body and consulted by compile_send for a
    # receiver that provably still holds the loop element. nil everywhere
    # else, so every call site outside an inlined block behaves exactly as
    # it did before this existed.
    @elem_class_hint = nil
    @registry = registry
    # SUPER_SUPPORT: real class name -> its own declared superclass name
    # (String), :none (no explicit superclass -- real Object), or absent
    # (unrecognized/computed expression) -- build_registry's own
    # resolve_superclass_ref result, see that function's comment. The
    # only real consumer is compile_insn's own SUPER case.
    @superclass_of = superclass_of
    # irep label -> Annotations::Annotation (Annotations.extract's own
    # result) -- previously computed at the top level only to feed
    # IvarLayout.analyze's own opaque-argument fallback, never threaded
    # into CodeGen at all. Now also the sole trigger for NATIVE_ARG_TARGETS'
    # own native-argument calling convention (see that constant's own
    # comment for why an annotation, and never ArgTypes' own passive
    # inference, is the only safe trigger for changing a method's own C++
    # signature) -- consulted by native_arg_types below, shared by
    # compile_method (a target method's own entry/impl signature) and
    # compile_send (a devirtualized call site's own argument unboxing).
    @annotations = annotations
    # irep label -> {owner:, name:} for every leaf method body. A native
    # MethodDef (irep nil) has no body to compile, so it's excluded here --
    # it only ever exists to make monomorphic_target's own size check see
    # more than one definition.
    @owner_of = {}
    registry.each_value do |defs|
      defs.each { |d| @owner_of[d.irep] = d if d.irep }
    end
    @class_layout = class_layout # class_name -> {ivar_name => class_name} -- see ClassLayout's own comment.
    @class_annotations = class_annotations # irep label -> ClassAnnotations::Annotation
    @only_owners = nil # set by compile_all -- see its own comment.
    # Set by GETCONST's own owner-scope-first codegen (see its comment)
    # whenever at least one compiled method actually needs the shared
    # bc2cpp_const_get_or_object helper -- emit_const_lookup_helper reads
    # this after compile_all runs, so the helper (and its mruby/error.h
    # dependency) never appears in a generated file that has no real use
    # for it.
    @const_lookup_helper_used = false
    # Set of NATIVE_CONSTRUCT_TARGETS keys (e.g. "Tone") at least one
    # compiled `.new` call site actually devirtualized into -- same
    # "only emit what's used" shape as @const_lookup_helper_used, read by
    # emit_native_construct_decls after compile_all runs.
    @native_construct_used = Set.new
    # Same "only emit what's used" shape, for DIRECT_CONSTRUCT_TARGETS' own
    # generalized construction path -- read by emit_direct_construct_decls
    # after compile_all runs.
    @direct_construct_used = Set.new
    @clean_cache = {} # irep label -> does compile_method(label) end up #error-free? (memoized -- see compiles_clean?'s own comment)
    @probing = Set.new # recursion guard for compiles_clean? (mutually-MONO-recursive methods)
    # ATTR_STRUCT_DEVIRT: [owner, ivar] pairs drop_unsafe_embeddings below
    # allowed to embed ONLY because a synthesized struct-aware accessor
    # (emit_ivar_accessor_pair) will override the plain native
    # attr_reader/writer/accessor that would otherwise still read/write
    # the ordinary iv_tbl -- see that method's own comment for the full
    # soundness argument. Populated by drop_unsafe_embeddings, read by
    # emit_synthesized_accessors after compile_all runs.
    @synthesize_accessor_for = Set.new
    # @clean_cache/@probing (above) and @ivar_layout (below, temporarily the
    # RAW layout) both have to exist before drop_unsafe_embeddings runs --
    # it calls compiles_clean?, which calls compile_method, which reads
    # @ivar_layout[d.owner] for its OWN embedding decision (irrelevant to
    # whether #error appears -- the embedded-struct init block never itself
    # contains #error text -- but a nil @ivar_layout would still raise
    # NoMethodError on `[]` before ever reaching that check). Reassigned to
    # the real, filtered result immediately after.
    @ivar_layout = ivar_layout
    @ivar_layout = drop_unsafe_embeddings(ivar_layout) # class_name -> {ivar_name => :fixnum}
  end

  def const_lookup_helper_used?
    @const_lookup_helper_used
  end

  # Embedding an ivar as a real struct field only works if the struct is
  # actually *allocated* first -- compile_method's own mrb_data_init call,
  # emitted only for a compiled `#initialize`. A class whose own
  # `#initialize` this compiler can't compile (optional/rest/keyword args,
  # same constraint as pure_mandatory_arity? everywhere else, or no
  # `#initialize` of its own at all -- relying on an ancestor's) never gets
  # that allocation, so any *other* compiled method's GETIV/SETIV for that
  # class would read/write DATA_PTR(self) on an object that's still a plain
  # MRB_TT_OBJECT -- garbage or a crash, not just a missed optimization.
  # Caught wiring up a second real target (Game::Picture, docs/adr/0139's
  # own follow-up): its 11 real embeddable ivars are all correctly inferred
  # by IvarLayout, but #initialize takes optional arguments and was never
  # going to compile -- embedding them anyway would have been a real,
  # silent memory-safety bug the very first time a compiled #step or
  # #update ran against a real (interpreter-allocated, MRB_TT_OBJECT)
  # Game::Picture instance.
  #
  # pure_mandatory_arity? alone is NOT enough, a real gap this guard's
  # own arity-only check missed -- caught building Game::Party (this
  # round): `Game::Actor#initialize` genuinely has pure mandatory arity
  # (2 required args, no opts -- confirmed against real disassembly, `ENTER
  # 2:0:0:0:0:0:0:0`), so the old check let 7 real provably-Fixnum
  # Game::Actor ivars (@id, @exp, @level, @class_id, @faceset_index,
  # @face_index, @battler_animation_override) straight through -- but the
  # method's own body still ends in a real `@equipment.each { |eq| ... }`
  # (BLOCK/SENDB), an opcode this compiler has never modeled, so it can
  # never actually compile and never runs its own mrb_data_init call
  # either way. The already-shipped mruby-rpg2k-compiled/src/register.cxx
  # (docs/adr/0139's own Game::Actor follow-up) confirms this was REAL,
  # not hypothetical: replaying its own exact bc2cpp invocation (whole
  # closed world, ONLY_OWNERS including Game::Actor, no other change) shows
  # 16 real, already-registered methods (`faceset_index`, `set_faceset`,
  # `restore_class`, `set_class_id`, `curve_row`, `gain_exp`,
  # `exp_to_next`, `next_level_exp`, `change_level_by`, `change_param`,
  # `battler_animation_id`, `class_battle_commands`, `double_hand?`,
  # `equipment_fixed?`, `force_ai?`, `strong_defence?`) whose own GETIV/
  # SETIV codegen -- built from the very same (unfiltered) ivar_layout this
  # method is supposed to be the *only* gate on -- dereferences
  # `DATA_PTR(self)` for one of the 7 ivars above, yet
  # `mruby-rpg2k-compiled/src/register.cxx` never calls
  # `MRB_SET_INSTANCE_TT(actor, MRB_TT_DATA)` (confirmed: no such call
  # exists anywhere in that file's own Game::Actor registration block,
  # since nothing there ever suspected embedding was live for this class).
  # So every real `Game::Actor.new(...)` stays a plain `MRB_TT_OBJECT`, and
  # any of those 16 real, already-registered methods reading
  # `faceset_index`/`class_id`/`exp`/`level`/etc. off `self` would
  # dereference an `RData` payload that was never allocated: real
  # undefined behavior (garbage or a segfault, not a diagnostic), live in
  # the actual merged build today, every time one of them runs.
  # compiles_clean? -- a real compile_method(label) call, checked for a
  # #error marker, the exact same test SKIP_UNSUPPORTED itself uses (see
  # its own comment) -- is the only way to answer "does #initialize's own
  # body actually finish compiling", the same real gap
  # compiles_clean?/compile_send's own MONO-devirtualization fix already
  # closed for call sites two follow-ups up in docs/adr/0139; this is the
  # identical fix applied to the embedding gate instead.
  def drop_unsafe_embeddings(ivar_layout)
    ivar_layout.each_with_object({}) do |(owner, ivars), out|
      init = @registry['initialize']&.find { |d| d.owner == owner }
      next unless init && pure_mandatory_arity?(@ireps.fetch(init.irep)) && compiles_clean?(init.irep)

      # A per-owner #initialize gate alone isn't enough: an ivar only
      # embeds safely if *every* read/write of it goes through this
      # compiler's own GETIV/SETIV codegen -- or through a replacement
      # this file itself controls just as completely. A plain
      # `attr_reader`/`attr_writer`/`attr_accessor` for that exact same
      # name is a real, live counterexample -- its native C implementation
      # (3rd/mruby/src/class.c's own `attr_reader`/`attr_writer`) is a
      # bare `mrb_iv_get`/`mrb_iv_set` against the ordinary dynamic
      # `iv_tbl`, with no way to know this class's own SETIV codegen wrote
      # the value into an `RData` struct field instead -- so the native
      # getter always returns nil (or the setter's write is simply
      # invisible to every compiled GETIV reader) regardless of what
      # #initialize did. Caught for real on LCF::EventCommand's own
      # `attr_reader :code, :indent, :string, :parameters` -- @code/
      # @indent are exactly the two ivars #initialize's own annotation
      # marks embeddable, and a minimal toy repro (a class embedding one
      # ivar via #initialize, with a plain `attr_reader` for it installed
      # the ordinary way) confirms `Foo.new(42).x` returns `nil`, not
      # `42`, once embedded: build_registry's own attr_reader/writer/
      # accessor case already registers a synthetic (irep: nil) MethodDef
      # under this exact owner for the bare name (a reader) and/or
      # "<name>="  (a writer) -- checked directly here, the same way
      # monomorphic_target already treats an irep-nil MethodDef as "native,
      # no compiled body", rather than assumed safe by construction.
      #
      # ATTR_STRUCT_DEVIRT: a `kind: :ivar_accessor` exposure specifically
      # (as opposed to any OTHER irep-nil MethodDef under this owner --
      # e.g. a `Struct.new(:name, ...)` member accessor, a completely
      # different, non-iv_tbl storage mechanism this file has no business
      # touching) is the ONE native-exposure shape this file can safely
      # neutralize itself: emit_ivar_accessor_pair below hand-builds a
      # real compiled getter/setter using the exact same struct-field
      # codegen GETIV/SETIV already use, and the caller registers it in
      # register.cxx the ordinary way -- overriding attr_reader's own
      # installation PROGRAM-WIDE (mrb_define_method replaces the whole
      # class's own method-table entry for that name, so a genuinely
      # dynamic call path -- an unprovable receiver class, `send`,
      # reflection -- reaches this synthesized accessor exactly the same
      # as a statically-devirtualized one; IVAR_ACCESSOR_DEVIRT's own
      # call-site shortcut in compile_send is a distinct, purely-additive
      # speed optimization on top of this, never a substitute for it --
      # it still falls through to `mrb_funcall` whenever a call site can't
      # prove its receiver's class, and that `mrb_funcall` needs THIS
      # override already in place to land somewhere struct-aware). Only
      # ivars whose native reader AND writer exposure (when both exist)
      # are exclusively :ivar_accessor qualify; anything else keeps the
      # ivar off the struct exactly as before.
      safe = ivars.reject do |name, _|
        reader_native = natively_exposed?(owner, name)
        writer_native = natively_exposed?(owner, "#{name}=")
        reader_blocked = reader_native && !synthesizable_accessor_only?(owner, name)
        writer_blocked = writer_native && !synthesizable_accessor_only?(owner, "#{name}=")
        next true if reader_blocked || writer_blocked || !every_accessor_compiles?(owner, name)

        # Record exactly which of reader/writer actually needs a
        # synthesized override -- never both just because one did: a
        # class with only `attr_reader :x` (no `attr_writer`) must not
        # gain a brand-new public `x=` nobody wrote, a real behavior
        # change (NoMethodError today, silently accepted after).
        @synthesize_accessor_for << [owner, name, :reader] if reader_native
        @synthesize_accessor_for << [owner, name, :writer] if writer_native
        false
      end
      out[owner] = safe unless safe.empty?
    end
  end

  # Does some OTHER, native (non-bytecode) definition already expose this
  # exact method name under this exact owner -- an attr_reader/writer/
  # accessor-installed accessor (build_registry's own synthetic
  # MethodDef, irep: nil) that reads/writes the ordinary dynamic iv_tbl
  # directly, bypassing any embedded RData struct entirely. Used by
  # drop_unsafe_embeddings above to keep an ivar off the embedded struct
  # whenever some other real accessor would silently miss it.
  def natively_exposed?(owner, name)
    (@registry[name] || []).any? { |d| d.owner == owner && d.irep.nil? }
  end

  # ATTR_STRUCT_DEVIRT: are ALL of this exact owner's own native
  # definitions of `name` specifically a plain attr_reader/writer/
  # accessor (kind: :ivar_accessor)? True vacuously when there are none
  # (natively_exposed? already false in that case, so the caller never
  # actually relies on this branch) or when the only one there is really
  # is an :ivar_accessor. False whenever some OTHER native, non-bytecode
  # definition shares this exact owner+name -- the concrete, checked
  # counterexample is a `Struct.new(:name, ...)` member accessor
  # (build_registry's own SENDB case, `kind: nil` -- see its own
  # comment): Struct stores members positionally, never through iv_tbl
  # at all, so there is no GETIV/SETIV-shaped struct field this file
  # could ever synthesize a replacement for, and the ivar (which would
  # only even appear in ivar_layout in the first place if some OTHER,
  # unrelated method on the same class also does real `@name = ...`
  # bytecode -- a real possibility, not paranoia) has to stay off the
  # struct exactly as natively_exposed? alone already decided.
  def synthesizable_accessor_only?(owner, name)
    (@registry[name] || []).select { |d| d.owner == owner }.all? { |d| d.kind == :ivar_accessor }
  end

  # A real, previously-undiscovered gap in this same "safe to embed" gate,
  # found and fixed building Game::Interpreter (docs/adr/0139's own
  # follow-up): #initialize compiling clean (the check immediately above)
  # is necessary but not sufficient. `struct RData` (3rd/mruby/include/
  # mruby/data.h) carries its own, separate `struct iv_tbl *iv` field,
  # completely independent of the `void *data` pointer bc2cpp's own
  # embedded struct lives behind (`DATA_PTR`) -- confirmed directly against
  # the real struct definition, not assumed. So ANY method that stays on
  # the interpreter for any of this file's own already-established reasons
  # (an unsupported opcode, non-mandatory arity, a genuine Ruby block/
  # rescue) still runs its own ordinary SETIV/GETIV bytecode against that
  # same `iv_tbl` the moment it touches this exact ivar -- a completely
  # different storage location from the one every *compiled* sibling
  # method's own GETIV/SETIV codegen reads and writes via DATA_PTR(self)
  # once the ivar is embedded. Two real, independent storage locations
  # silently diverging for the same ivar name on the same object: real,
  # live data corruption (an interpreted accessor reading nil/stale from an
  # `iv_tbl` entry a compiled sibling never writes to, while every compiled
  # accessor's own writes vanish into a struct field the interpreter never
  # reads) every time the still-interpreted method runs, not merely a
  # missed optimization -- the identical severity class as the
  # #initialize-never-compiles half of this same bug, just triggered by a
  # DIFFERENT method than #initialize touching the same ivar. Confirmed
  # real, not hypothetical, on Game::Interpreter's own @frame_steps: both
  # #initialize and #reset_frame_steps compile clean and would embed it as
  # a real Fixnum struct field, but #update -- which also reads and
  # increments this exact ivar (`break if @frame_steps >= MAX_STEPS`,
  # `@frame_steps += step_cost(cmd.code)`) -- hits a real, unmodeled JMPUW
  # opcode (an `until`/modifier-`while` loop's own jump-out-of-loop shape)
  # and stays on the interpreter; without this guard, every real #update
  # call after the first #initialize would read a permanently-nil
  # `iv_tbl["@frame_steps"]` (never written, since the compiled
  # #initialize wrote the real value into the embedded struct field
  # instead) rather than the value #initialize actually set, immediately
  # raising inside `nil >= MAX_STEPS` the first time any interpreter ran.
  def every_accessor_compiles?(owner, ivar_name)
    # `@registry` is a `Hash.new { |h, k| h[k] = [] }` -- even a plain read
    # of a not-yet-present key (e.g. `natively_exposed?`'s own `@registry
    # [name]`, reached transitively the moment `compiles_clean?` below
    # actually compiles a method body that sends a name never seen before)
    # auto-vivifies a new empty-array entry as a side effect, mutating the
    # very hash this method is enumerating. `.values` snapshots the current
    # arrays into a plain, disconnected Array *before* any such nested
    # mutation can happen, so the actual enumeration below never touches
    # `@registry` itself -- `each_value` here raised a real, reproduced
    # "can't add a new key into hash during iteration" RuntimeError the
    # first time this method ran against the whole closed world (every
    # other `@registry.each_value` walk in this file only ever reads
    # `d.owner`/`d.irep` off already-built MethodDefs, never triggers a
    # nested compile, so this collision was never reachable there).
    @registry.values.each do |defs|
      defs.each do |d|
        next unless d.owner == owner && d.irep

        touches = irep_subtree_touches_ivar?(d.irep, ivar_name)
        return false if touches && !compiles_clean?(d.irep)
      end
    end
    true
  end

  # Recursively checks a method's own top-level irep *and every irep nested
  # inside it* (a block literal's own separate body -- `irep.reps[idx]`,
  # the same child-irep array BLOCK/OCLASS/SCLASS/SDEF instructions already
  # index into elsewhere in this file) for a SETIV/GETIV of this exact
  # ivar. Needed because mrbc compiles a block literal's own body into a
  # completely separate child irep, invisible to a plain scan of the
  # enclosing method's own top-level `irep.instructions` alone -- confirmed
  # real reading Game::Transition#clip's own generated output while fixing
  # this same method's own #initialize-only blind spot (docs/adr/0139's own
  # Game::Interpreter follow-up): #clip's own top-level irep is only 6
  # instructions (build the Array, MOVE the argument, `#error unhandled
  # opcode BLOCK`) and never itself mentions `@width`/`@height` at all --
  # both live only inside its own `rects.each do |x, y, w, h| ... end`
  # block's separate child irep, entirely missed by the first version of
  # this fix (which only scanned `d.irep.instructions` directly and so
  # still let `@width` embed even though `#clip` -- permanently
  # uncompiled, BLOCK is not in this prototype's supported subset --
  # reads it). Whether #clip's own top-level irep *itself* mentions the
  # ivar is irrelevant to whether the method as a whole touches it: mruby's
  # own VM runs a still-interpreted method's nested block bodies exactly
  # like any other bytecode once that method is reached at all, no
  # special-casing for "this part would have compiled in isolation" -- so
  # every reachable descendant irep has to be checked, not just the
  # method's own. `seen` guards against revisiting a shared child irep more
  # than once (mrbc can and does share an irep across more than one call
  # site); it is not a cycle guard `reps` could ever need one for (a block
  # literal's own child irep is a strict subtree, never back-references an
  # ancestor), but costs nothing to keep.
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

  # NATIVE_ARG_TARGETS' own per-position type lookup -- shared verbatim by
  # compile_method (a target method's own entry-wrapper/`_impl` signature)
  # and compile_send (a devirtualized call site's own argument unboxing),
  # so the two can never disagree about which mandatory positions of a
  # given MethodDef are native-typed: returns an array of size `mand`,
  # each slot either `:fixnum`/`:symbol` (Annotations::TYPES' own two
  # recognized tokens) or `nil` (stays plain `mrb_value`, exactly like
  # today, for a MethodDef this round's own NATIVE_ARG_TARGETS table
  # doesn't name, OR one it names but whose real annotation doesn't cover
  # that exact position -- see Annotations' own comment on `# bc2cpp:
  # (fixnum, )`'s own per-position meaning).
  #
  # Gated on BOTH `d.irep` (a native/synthetic MethodDef has no `_impl` of
  # its own to retype at all) and NATIVE_ARG_TARGETS' own explicit
  # "Owner#name" membership -- an annotation alone is never enough, by
  # design (see that constant's own comment for why trusting every real
  # annotation in this codebase wholesale is a scale decision this round
  # deliberately declined, not a soundness one).
  def native_arg_types(d, mand)
    return Array.new(mand) unless d.irep && NATIVE_ARG_TARGETS.include?("#{d.owner}##{d.name}")

    ann = @annotations[d.irep]
    return Array.new(mand) unless ann

    Array.new(mand) { |i| ann.args[i] }
  end

  # The native C++ parameter type for one `native_arg_types` slot --
  # `C_TYPE.fetch(t)` (`mrb_int`/`mrb_sym`) when native-typed, plain
  # `mrb_value` (today's own uniform type, unchanged) otherwise. NOTE:
  # `:array` (the `-> Array` return token) has deliberately NO arm here
  # -- `fetch` raises KeyError, fail-loud, if an Array token ever
  # reaches argument position. Return-type gates read `.ret` directly
  # and never pass through this function.
  def native_c_type(t)
    t ? C_TYPE.fetch(t) : 'mrb_value'
  end

  # Owner class names are real Ruby constant paths ("Game::Actor",
  # "RPG2k::Scene::Order") once nested module/class tracking is in play --
  # ":: " isn't valid inside an ordinary C++ identifier, so every generated
  # name (function, struct, static var) needs this, not just cpp_name.
  def sanitize(s)
    s.gsub(/[^a-zA-Z0-9_]/, '_')
  end

  # Follow-up (docs/adr/0139: ".singleton owner support"): the real
  # `Module.nesting`-style lexical scope a `def`'s own body sees for a bare
  # constant reference, split into "::"-separated segments innermost-last
  # -- what GETCONST's owner-scope-first codegen (below) and
  # const_chain_value_expr (this file's own TYPED-path helper) both need,
  # factored out here once both call it instead of each doing its own
  # `owner.split('::')`.
  #
  # A REAL, LIVE BUG this factoring fixes, caught empirically the first
  # time this project ever actually compiled a `.singleton`-owned method
  # (RGSS::Bitmap.singleton#extensions/#failure_reason, this same
  # follow-up): `owner_def.owner` for one of these is the synthetic
  # "Owner.singleton" pseudo-owner string (SDEF/SCLASS/the unfused-DEF
  # singleton branch, see build_registry above) -- a bookkeeping label for
  # MONO/POLY registry purposes ONLY, never a real, nested Ruby constant
  # path. Before this fix, GETCONST's own `owner_path = owner_def.owner.
  # split('::')` split "RGSS::Bitmap.singleton" into ["RGSS",
  # "Bitmap.singleton"] and then literally tried
  # `mrb_const_get(M, scope_RGSS, mrb_intern_cstr(M, "Bitmap.singleton"))`
  # -- looking up a constant *named* "Bitmap.singleton" (a symbol with a
  # literal dot in it, never a real constant anywhere) as this loop's own
  # FIRST, UNPROTECTED scope-chain segment (only the final, innermost
  # lookup of the *target* constant name is wrapped in
  # bc2cpp_const_try/mrb_protect_error -- see GETCONST's own comment;
  # building the scope chain itself was never guarded, on the reasonable-
  # until-now assumption that every segment of a real owner path is by
  # construction a real, already-existing constant). Confirmed live: every
  # bare constant reference inside either method's own body (EXTENSIONS/
  # GAME_DIR/RTP_DIR/RGSS) compiled to exactly this broken shape in the
  # real generated output before this fix -- a guaranteed real NameError
  # ("uninitialized constant RGSS::Bitmap.singleton") the very first time
  # either compiled function actually ran, never caught by g++ (a valid,
  # if wrong, runtime call) and never caught by this file's own
  # SKIP_UNSUPPORTED/`#error` mechanism (compile_insn's own GETCONST case
  # has no way to know a segment it's about to look up isn't real).
  #
  # The real fix: a `def self.x`/`class << self ... end` method's own
  # lexical nesting is exactly its ENCLOSING class/module's nesting --
  # real Ruby's `Module.nesting` for code textually written inside `class
  # Bitmap; def self.foo; end; end` is `[RGSS::Bitmap, RGSS]`, the pseudo-
  # owner suffix carries no lexical-scope meaning of its own (it exists
  # purely so build_registry's own MONO/POLY table can tell a class
  # method apart from a same-named instance method) -- so stripping a
  # trailing ".singleton" before splitting on "::" recovers exactly the
  # real scope chain a bare constant reference in this body should search,
  # innermost first: RGSS::Bitmap, then RGSS, then (GETCONST's own
  # existing unconditional final fallback) Object. This can only ever
  # affect a `.singleton`-suffixed owner -- every real Ruby constant path
  # already has no such suffix to strip (`sub` is then a no-op), so no
  # already-shipped owner's own GETCONST codegen changes at all (confirmed
  # in this same follow-up's own full-sweep byte-identical regression
  # diff).
  def lexical_scope_path(owner)
    owner.sub(/\.singleton\z/, '').split('::')
  end

  # Every method name with exactly one definition anywhere in the whole
  # program -- the actual "static method resolution" this prototype does.
  #
  # A name whose one and only definition is a synthetic native MethodDef
  # (extract_native_method_names's own merge -- irep nil, no bytecode body
  # anywhere) never becomes a target here either: there's no compiled C++
  # function to call into, and calling the real RGSS C++ method's raw
  # function pointer directly (bypassing mrb_funcall) would leave any
  # mrb_get_args inside it reading a stale mrb->c->ci call-info frame -- a
  # real correctness bug, not just a missed optimization (verified against
  # 3rd/mruby/src/vm.c's own mrb_funcall_with_block). So a name that's
  # *only* natively defined just falls back to ordinary dynamic dispatch,
  # same as any other unresolvable call site.
  def monomorphic_target(name)
    defs = @registry[name]
    return nil unless defs && defs.size == 1
    return nil unless defs.first.irep
    return nil unless compiles_clean?(defs.first.irep)

    defs.first
  end

  # LITERAL_EQQ_SUPPORT's own soundness gate -- a LIVE re-check against
  # THIS run's own @registry, not a comment trusting a fact that was true
  # the day it was written. Both `#==` and `#===` have to still be
  # exactly, unambiguously native (`MONO`, one def, owner `'<native>'`)
  # anywhere in the whole program for compile_send's own LITERAL === block
  # below to be sound at all:
  #   - `:===` itself: a reopened `#===` anywhere (Integer, Symbol,
  #     Object, Comparable, a mixin, ...) means `LITERAL === arg` might
  #     not even call mruby's own native `mrb_eqq_m` (3rd/mruby/src/
  #     kernel.c) in the first place.
  #   - `:==`: `mrb_eqq_m` calls `mrb_equal` (3rd/mruby/src/object.c),
  #     which -- whenever its own fast identity/type-mixing checks don't
  #     already settle the answer -- dispatches to `self`'s own real
  #     `#==` method (`mrb_func_basic_p`'s own guard, same file). Both the
  #     Symbol branch (sound only because Symbol's own `#==` is still
  #     literally `mrb_obj_equal_m`, the exact default `mrb_func_basic_p`
  #     compares against) and the Fixnum branch (sound only because
  #     Integer's own `#==` is still literally `int_equal`, 3rd/mruby/src/
  #     numeric.c) below depend on this -- a reopened `#==` on ANY class
  #     (not just Integer/Symbol) could change what `self` even IS by the
  #     time `mrb_equal` dispatches, so the check is deliberately whole-
  #     name, not scoped to Integer/Symbol's own owner. Confirmed for real
  #     against mruby-rpg2k-compiled's own whole-program registry dump
  #     (both `MONO :== (1 def: <native>)` and `MONO :=== (1 def:
  #     <native>)`, zero `FLIP` lines for either -- i.e. neither name was
  #     EVER a bytecode MONO name to begin with, the strongest form of
  #     "never reopened anywhere"), not merely assumed from reading
  #     mruby's own source in isolation.
  # A future Ruby source change anywhere in the whole program that reopens
  # either name flips this false automatically (POLY, or a second real
  # native flip target) -- every LITERAL === call site falls back to
  # ordinary POLY dynamic dispatch from then on, never silently keeps a
  # now-unsound fast path. Memoized: `@registry` never changes after
  # CodeGen.new (compile_all's own single pass over already-finalized
  # ireps), so this is a pure function of it.
  def eqq_literal_devirt_safe?
    return @eqq_literal_devirt_safe if defined?(@eqq_literal_devirt_safe)

    @eqq_literal_devirt_safe = %w[== ===].all? do |n|
      defs = @registry[n]
      defs && defs.size == 1 && defs.first.owner == '<native>'
    end
  end

  # NATIVE_PRIMITIVE_SEND_ARITY: the native Kernel/NilClass/Hash methods
  # compile_send's own NATIVE_PRIMITIVE_SENDS path (see that comment,
  # right above compile_send's own `target = monomorphic_target(name)`
  # line, for the full soundness writeup) knows how to inline directly,
  # mapped to the exact real mandatory arity a call site must match --
  # `!`/`nil?`/`class`/`object_id`/`keys`/`to_s`/`length`/`first`/`dup`
  # take no arguments, `is_a?`/`kind_of?`/`equal?`/`===`/`!=` take exactly
  # one (confirmed against each one's own real MRB_ARGS_NONE()/
  # MRB_ARGS_REQ(1) registration in 3rd/mruby/src/kernel.c /
  # 3rd/mruby/src/class.c / 3rd/mruby/src/hash.c / 3rd/mruby/src/string.c
  # / 3rd/mruby/src/numeric.c / 3rd/mruby/src/array.c /
  # 3rd/mruby/src/range.c). `to_s`/`length`/`first`/`dup`/`===` are the
  # entries that AREN'T "one real native implementation" -- see each
  # one's own `*_TYPE_TAG_DISPATCH` comment in
  # compile_native_primitive_send.
  #
  # `push`/`size`/`empty?`/`<<` were investigated this round too (each has
  # a real, safely-reproducible native body -- see this round's own
  # changelog) but deliberately NOT added here: this exact program's own
  # whole-program registry shows each one genuinely collided with a real
  # bytecode override somewhere in the closed world (`RPG2k#push`,
  # `Game::Party#size`, `Game::MoveRoute#empty?`,
  # `RGSS::ErrorReport::Tee#<<`), confirmed directly against the live
  # registry (not assumed) -- `native_only_mono?` correctly refuses all
  # four every time, so an entry for any of them would be real, dead,
  # never-reached code today. Left out rather than shipped inert; revisit
  # if a future edit to any of those four classes removes the collision.
  #
  # `clear` was investigated too but excluded: `RGSS::ErrorReport`'s own
  # `class << self; def clear; ...; end; end` (mruby-rgss/mrblib/
  # error_report.rb) is a real bytecode override this table's own gate
  # correctly refuses on every time -- confirmed against the live
  # registry (`RGSS::ErrorReport.singleton#clear` shows up as a second
  # def alongside the native placeholder), not assumed. Would be dead
  # code today, same reasoning as `push`/`size`/`empty?`/`<<` above.
  #
  # `include?`/`member?` were investigated too and also excluded, for the
  # same "individually sound, but real bytecode override collides"
  # reason: Hash/Range/String/Class-Module-SClass's own four real native
  # registrations of `include?` are each safely reproducible (Range's own
  # case is literally the same real function, `range_include`, already
  # reimplemented for `===`'s own MRB_TT_RANGE arm above -- see
  # EQQ_TYPE_TAG_DISPATCH), but `mruby-rgss/mrblib/array_include.rb`
  # deliberately defines a real bytecode `Array#include?` (that file's own
  # comment: mruby's Array class has no native `#include?` of its own),
  # so `native_only_mono?('include?')` is false today. `member?` shares
  # `range_include`/`mrb_hash_has_key`'s own native registrations too, but
  # would need its own separate table entry (compile_send's own dispatch
  # is keyed by the literal call-site name, not an alias set) and is
  # independently blocked by a real, unrelated `Game::Battle::Combatant#
  # member?` (0-arg, mruby-rpg2k/mrblib/game/battle.rb) -- the one real
  # `member?` call site in the whole program is that custom method, not
  # Hash/Range's 1-arg native one, so even the arity gate alone would
  # already exclude it. Neither added; revisit if either override is ever
  # removed.
  #
  # `to_i` (arity 0 only -- see TO_I_TYPE_TAG_DISPATCH below for why the
  # explicit-base `str.to_i(base)` shape is deliberately left as ordinary
  # POLY dispatch) has no bytecode override anywhere in this project's own
  # closed world and fires for real.
  NATIVE_PRIMITIVE_SEND_ARITY = { '!' => 0, 'nil?' => 0, 'is_a?' => 1, 'kind_of?' => 1,
                                   'equal?' => 1, 'class' => 0, 'object_id' => 0, 'keys' => 0,
                                   'to_s' => 0, 'length' => 0, 'first' => 0, 'dup' => 0,
                                   '===' => 1, '!=' => 1, 'to_i' => 0 }.freeze

  # Whole-program soundness gate shared by every NATIVE_PRIMITIVE_SEND_
  # ARITY name: `name` must resolve in the registry to EXACTLY ONE def,
  # and that one def must be the synthetic native placeholder build_
  # registry's own NATIVE_SRCS merge creates (irep nil) -- i.e.
  # name-monomorphic (the identical whole-program guarantee
  # monomorphic_target's own registry check makes) AND that one def is
  # native rather than bytecode. monomorphic_target itself requires the
  # opposite (a real compiled `_impl` to call), so a name landing here is,
  # by construction, exactly the shape monomorphic_target already falls
  # through on -- this is genuinely a separate check, not a duplicate of
  # it. If some future game-source class ever defines its own `nil?`/
  # `!`/`is_a?`/`kind_of?` (however unlikely), `@registry[name]` grows a
  # second, real bytecode def, `defs.size == 1` goes false here exactly
  # the same way it already would for monomorphic_target, and this falls
  # back to ordinary POLY dynamic dispatch, never a wrong direct call.
  # When NATIVE_SRCS isn't passed at all (this project's own established
  # no-NATIVE_SRCS diagnostic mode), the native placeholder is never
  # added and `defs` is nil here too -- the same "can't prove it, don't"
  # fallback as everywhere else in this file, not a special case needing
  # its own handling.
  def native_only_mono?(name)
    defs = @registry[name]
    defs && defs.size == 1 && defs.first.irep.nil?
  end

  # Emits the guarded direct C++ implementation for one
  # NATIVE_PRIMITIVE_SEND_ARITY name -- see compile_send's own call site
  # (right above `target = monomorphic_target(name)`) for the full
  # per-method soundness citations against the real 3rd/mruby source;
  # kept here, rather than inlined at that call site, purely to keep
  # compile_send's own already-long body from growing a fifth deeply-
  # nested branch for what is otherwise a small, self-contained C++
  # snippet per name.
  def compile_native_primitive_send(name, d, recv, argv)
    case name
    when '!'
      "  // ! -- native primitive, no lookup needed\n" \
      "  r#{d} = mrb_bool_value(!mrb_test(#{recv}));\n"
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
      # KEYS_TYPE_TAG_GUARD: unlike equal?/class/object_id above,
      # mrb_hash_keys is Hash-specific -- its own body casts the receiver
      # straight to `struct RHash*` via mrb_hash_ptr's own unchecked
      # `(struct RHash*)(mrb_ptr(v))` macro (3rd/mruby/include/mruby/
      # hash.h), no type check inside it at all. Calling it on a non-Hash
      # receiver would reinterpret that receiver's real struct (RArray,
      # RString, ...) as an RHash -- undefined behavior, not a clean
      # NoMethodError the way real Ruby would raise for `[].keys`.
      # `mrb_hash_p` (mrb_type(o) == MRB_TT_HASH, always-defined regardless
      # of boxing mode) is the same RBasic-derived-struct type-tag check
      # `mrb_class_p`/`mrb_module_p` above already use for is_a?/kind_of?'s
      # own argument -- guarding on it here, falling back to ordinary
      # `mrb_funcall` otherwise, reproduces the real NoMethodError a
      # genuinely non-Hash receiver would raise (no OTHER native or
      # bytecode `:keys` exists anywhere in the closed world --
      # native_only_mono? already proved that -- so mrb_funcall's own
      # dispatch correctly fails to find one).
      "  // keys -- native primitive, runtime-guarded (mrb_hash_keys casts straight\n" \
      "  // to struct RHash*, unsafe on a non-Hash receiver -- see compile_native_\n" \
      "  // primitive_send's own KEYS_TYPE_TAG_GUARD comment)\n" \
      "  if (mrb_hash_p(#{recv})) {\n" \
      "    r#{d} = mrb_hash_keys(M, #{recv});\n" \
      "  } else {\n" \
      "    #{dynamic_dispatch_line(d, recv, name, argv)}" \
      "  }\n"
    when 'to_s'
      # TO_S_TYPE_TAG_DISPATCH: unlike every other name above (one native
      # implementation total, whole-program-uncontested), `to_s` is the
      # canonical case native_only_mono? can't safely answer alone -- a
      # real grep across 3rd/mruby/src finds it registered separately on
      # Array/String/Hash/Integer/Float/Range/Module *and* inherited from
      # Kernel's own default for everything else, seven-plus distinct
      # native bodies collapsed into the registry's one synthetic
      # `<native>` entry (see this round's own changelog for the full
      # accounting). Safe here only because this is a real `mrb_type(recv)`
      # switch -- an RBasic-derived-struct type-tag check, the same kind
      # `mrb_hash_p` above already is -- covering ONLY the tags whose real
      # native body was individually verified side-effect-free enough to
      # call outside an actual dispatched call frame, with every other
      # tag (including two, Array and Hash, deliberately left out below)
      # falling through to ordinary `mrb_funcall`.
      #
      # MRB_TT_STRING: 3rd/mruby/src/string.c's own `mrb_str_to_s` is
      # exactly `mrb_obj_class(mrb, self) != mrb->string_class ?
      # mrb_str_dup(mrb, self) : self` (a String subclass instance gets a
      # real plain-String dup, matching #to_s's own real contract of
      # "always returns an actual String, never a subclass instance";
      # `self` unchanged when it's already a plain String) -- static (not
      # exported), but this three-line body is simple and side-effect-free
      # enough to reproduce directly rather than needing the function
      # itself linkable.
      #
      # MRB_TT_INTEGER: 3rd/mruby/src/numeric.c's own `int_to_s` (also
      # static) is `mrb_integer_to_str(mrb, self, base)`, `base` defaulting
      # to 10 when the call took no argument -- always true here, this
      # devirtualization only ever fires for a real `n == 0` call site
      # (NATIVE_PRIMITIVE_SEND_ARITY's own arity gate). `mrb_integer_to_str`
      # itself (3rd/mruby/include/mruby/numeric.h) IS a real, public
      # `MRB_API`, callable directly with the same `base=10` default.
      #
      # Deliberately excludes MRB_TT_ARRAY/MRB_TT_HASH despite having a
      # single, named native implementation each (`mrb_ary_to_s`/
      # `mrb_hash_to_s`) -- a real, easy-to-miss trap caught only by
      # reading each body, not by checking static/exported status alone:
      # both of them unconditionally run `mrb->c->ci->mid = MRB_SYM
      # (inspect);` as their own first line, reaching into and MUTATING
      # the VM's own current call-info frame (the same `mrb->c->ci`
      # monomorphic_target's own comment already flags as unsafe to trust
      # outside a real dispatched call for a DIFFERENT reason, stale
      # `mrb_get_args` reads) -- calling either directly from here would
      # silently corrupt whatever real call frame this generated code
      # happens to be running inside, not just risk a stale read. Also
      # excludes MRB_TT_FLOAT (`flo_to_s`)/MRB_TT_RANGE (`range_to_s`),
      # both static with no safe public equivalent found; MRB_TT_CLASS/
      # MRB_TT_MODULE/MRB_TT_SCLASS (`mrb_mod_to_s`, declared non-static in
      # mruby/internal.h -- real and side-effect-free on inspection, but
      # left for a future round rather than pulling in an internal header
      # for one more tag in the same change that just found the Array/Hash
      # trap). Every one of these, like every tag not listed here at all,
      # correctly falls through to the `default:` case's ordinary
      # `mrb_funcall`.
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
      # LENGTH_TYPE_TAG_DISPATCH: same shape as to_s -- real registrations
      # found on Array (`mrb_ary_size`), String (`mrb_str_size`), and Hash
      # (`mrb_hash_size_m`), three distinct native bodies collapsed into
      # one registry entry. Array and Hash are both safe and simple:
      # `mrb_ary_size` is `mrb_int_value(mrb, ARY_LEN(a))` (ARY_LEN and
      # mrb_ary_ptr both real public macros, already used by this file's
      # own GETIDX/AREF codegen); `mrb_hash_size_m` is a thin wrapper
      # around `mrb_hash_size`, itself a real public `MRB_API`. String is
      # deliberately excluded despite `mrb_str_size` itself being harmless
      # (no ci mutation, no argc read): its own body reads
      # `RSTRING_CHAR_LEN(self)`, a macro defined twice, *inside
      # string.c itself* (never in any public header) -- `utf8_strlen(s)`
      # under `MRB_UTF8_STRING`, plain `RSTRING_LEN(s)` otherwise. This
      # project's own mrbconf.h leaves `MRB_UTF8_STRING` at its default
      # (commented out, confirmed by reading the file, not assumed), so
      # `RSTRING_LEN` would be the real answer today -- but hardcoding
      # that here would silently go wrong the moment this project's own
      # build config changes, an unstated coupling this file's own
      # established style doesn't take on elsewhere. Left to ordinary
      # `mrb_funcall`, like every tag not listed below.
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
      # FIRST_TYPE_TAG_DISPATCH: this entry's own arity (0, see
      # NATIVE_PRIMITIVE_SEND_ARITY) only ever matches a real `x.first`
      # call site with no argument -- `x.first(n)` (the "first n elements"
      # form real call sites also use, per the whole-program survey that
      # found this candidate) simply never reaches this table at all
      # (compile_send's own `n == expected_n` gate), so it stays ordinary
      # `mrb_funcall`, untouched, same as any other arity mismatch
      # elsewhere in this file.
      #
      # Only MRB_TT_RANGE is handled directly: `range_beg` (registered
      # under `first`, ARGS_NONE -- a real, separate 0-arg-only
      # registration, not the same function as Array's optional-arg one)
      # is exactly `mrb_range_beg(mrb, range)`, a real public macro
      # (`RANGE_BEG(mrb_range_ptr(mrb, r))`) with no VM state touched at
      # all. MRB_TT_ARRAY is deliberately excluded even though `first` has
      # a single, real, named implementation there too (`mrb_ary_first`):
      # its own body calls `mrb_get_argc(mrb)` to decide which of its two
      # real behaviors to run (bare `x.first` vs `x.first(n)`) -- calling
      # it directly from here would read the WRONG call frame's argument
      # count (this call site's own caller, not "0"), the exact same
      # stale-call-info-frame trap monomorphic_target's own comment
      # already warns about for an arbitrary native function, just for
      # `mrb_get_argc` instead of `mrb_get_args`. Everything else,
      # Array included, falls through to ordinary `mrb_funcall`.
      "  // first -- native primitive, runtime-guarded (only Range is handled\n" \
      "  // directly -- see compile_native_primitive_send's own\n" \
      "  // FIRST_TYPE_TAG_DISPATCH comment for why Array is deliberately left\n" \
      "  // to ordinary dispatch despite having a single real implementation)\n" \
      "  if (mrb_range_p(#{recv})) {\n" \
      "    r#{d} = mrb_range_beg(M, #{recv});\n" \
      "  } else {\n" \
      "    #{dynamic_dispatch_line(d, recv, name, argv)}" \
      "  }\n"
    when '==='
      # EQQ_TYPE_TAG_DISPATCH: same shape as to_s/length -- a real grep
      # across 3rd/mruby/src finds `===` registered separately on
      # Object/Kernel (`mrb_eqq_m`), Class/Module (`mrb_mod_eqq`) and
      # Range (`range_include`), three distinct native bodies the
      # registry's own `<native>` placeholder collapses into one entry.
      # All three are `static` and read their argument via
      # `mrb_get_arg1(mrb)` (a call-frame read, unsafe to call directly --
      # the same trap as every other name in this table with more than
      # one real implementation), but each one's own logic is trivially
      # and safely reproducible from genuinely public, direct-parameter
      # MRB_APIs:
      #   - MRB_TT_CLASS/MRB_TT_MODULE/MRB_TT_SCLASS: `mrb_mod_eqq` is
      #     exactly `mrb_obj_is_kind_of(mrb, arg, mrb_class_ptr(mod))` --
      #     `mrb_class_ptr` is the same real public macro this file's own
      #     shipped is_a?/kind_of? case above already uses on its
      #     argument; here it's the *receiver* being cast, always safe
      #     since the switch already proved the receiver's own type tag.
      #   - MRB_TT_RANGE: `range_include`'s real body (3rd/mruby/src/
      #     range.c) is reproduced inline using `mrb_range_beg`/
      #     `mrb_range_end`/`mrb_range_excl_p` (the same real public
      #     macros this file's own #each-inlining codegen already uses,
      #     see compile_insn's OP_SEND each-on-Range case) plus `mrb_cmp`
      #     (a real public MRB_API, already used by this file's own #sort
      #     codegen) standing in for range.c's own static `r_le`/`r_gt`/
      #     `r_ge` one-line wrappers around that exact same `mrb_cmp`.
      #     Safe to call unconditionally once the switch itself has
      #     already matched `MRB_TT_RANGE` -- the same "the switch IS the
      #     guard" reasoning `to_s`'s own switch above already relies on,
      #     no separate `mrb_range_p` check needed inside the case body.
      #   - MRB_TT_INTEGER/FLOAT/STRING/SYMBOL/TRUE/FALSE (also covers
      #     MRB_TT_NIL: this mruby build has no separate nil type tag --
      #     nil and false both report `MRB_TT_FALSE` from `mrb_type`,
      #     distinguished only by a hidden flag bit, confirmed against
      #     3rd/mruby/include/mruby/value.h's own `mrb_nil_p`/`mrb_false_p`
      #     macros -- so a bare `case MRB_TT_FALSE:` already covers both,
      #     and a separate `case MRB_TT_NIL:` would be a compile error, not
      #     just redundant)/ARRAY/HASH:
      #     `mrb_eqq_m` (Kernel/Object's own default) is exactly
      #     `mrb_bool_value(mrb_equal(mrb, self, arg))` -- `mrb_equal` is
      #     a real public MRB_API, side-effect-free, safe for literally
      #     any receiver/argument pair (it internally re-dispatches to a
      #     real `==` method call only when its own fast paths don't
      #     resolve, exactly like `equal?`'s own case above already
      #     relies on `mrb_obj_equal` for). Array/Hash included here even
      #     though `to_s` excluded them for a DIFFERENT native function
      #     with a real ci->mid-mutation bug -- `mrb_equal` itself has no
      #     such trap for any receiver, so there's nothing to exclude.
      #
      # Deliberately excludes MRB_TT_DATA (mruby-onig-regexp's `Regexp`
      # registers a real, active, BYTECODE `#===` override --
      # `closed_world_mrblib_srcs` never scans mruby-onig-regexp's own
      # mrblib, so `native_only_mono?` can't see it; MRB_TT_DATA is also
      # shared by mruby-marshal/mruby-stringio/mruby-rgss's own wrapper
      # objects, worse ambiguity than any tag `to_s` ever had to exclude)
      # and MRB_TT_PROC (mruby-proc-ext's bytecode `Proc#===`, confirmed
      # not part of this project's real dependency graph today, excluded
      # anyway as cheap insurance against that changing). Both, like every
      # tag not listed here, correctly fall through to `default:`'s
      # ordinary `mrb_funcall`.
      arg = argv.first
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
      "  case MRB_TT_INTEGER:\n" \
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
      # DUP_TYPE_TAG_DISPATCH: unlike every other entry here, this one is
      # actually EXHAUSTIVE -- no `mrb_funcall` fallback arm at all.
      # `dup` has exactly two real native registrations, confirmed via a
      # full grep across every native source this project's own closed
      # world can see (3rd/mruby/src, every active mrbgem, mruby-rgss):
      # `mrb_obj_dup` (Kernel's own default, MRB_API, real body:
      # immediate values return `self` unchanged via `mrb_immediate_p`,
      # everything else does a real `mrb_obj_alloc` + `init_copy` --
      # which itself dispatches the copied object's own real
      # `#initialize_copy` through the ordinary method-call mechanism, so
      # a class overriding it is still honored correctly even from
      # here) and `mrb_mod_dup` (Class/Module's own override -- static,
      # but its whole body, `mrb_value mod = mrb_obj_clone(mrb, self);
      # mrb_obj_ptr(mod)->frozen = 0; return mod;`, is three lines,
      # reproduced directly; `mrb_obj_clone` is a real public MRB_API,
      # `mrb_obj_ptr` a real public macro). Since Kernel#dup's own real
      # body is already correct and safe for literally every receiver
      # type OTHER than a Class/Module/singleton-class instance (which
      # Module's own registration overrides), the `default:` arm calls it
      # directly instead of falling back to `mrb_funcall` -- there is no
      # third real implementation anywhere left for that arm to miss.
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
      # NEQ_UNCONDITIONAL: `!=` is not backed by any C function at all --
      # 3rd/mruby/src/class.c's own `bob_init` registers it via a hand-
      # written static bytecode `RProc` (`neq_proc`/`neq_irep`: `OP_ENTER,
      # OP_EQ, OP_JMPNOT, OP_LOADFALSE/OP_LOADTRUE, OP_RETURN` -- literally
      # "return !(self == other)") through `mrb_define_method_raw`, a
      # registration idiom extract_native_method_names didn't recognize at
      # all before this round (see that function's own new scan, added
      # alongside this entry) -- without it, `!=` would have no registry
      # entry whatsoever and this case would be silent dead code, gated
      # out by native_only_mono? forever despite being genuinely safe.
      # Real `OP_EQ` itself (3rd/mruby/src/vm.c) is: an identity check
      # first (`mrb_obj_eq`), then -- ONLY for a Symbol receiver -- a
      # hardcoded `false` (no dispatch), then `OP_CMP(==,eq)` (an Integer/
      # Integer, Integer/Float, Float/Integer, Float/Float fast path, else
      # a real `SEND :==` dispatch). The real public `mrb_equal` MRB_API
      # (3rd/mruby/src/object.c, already trusted for `===`'s own
      # MRB_TT_INTEGER/FLOAT/STRING/SYMBOL/... bucket above) reproduces
      # this exactly for EVERY type, including the Symbol case: its own
      # identity check comes first, then (for a Symbol whose `==` is still
      # the real, unmodified `mrb_obj_equal_m` default) `mrb_func_basic_p`
      # is true, so its own `else if` dispatch branch is skipped and it
      # falls through to `return FALSE` -- the same answer OP_EQ's
      # hardcoded Symbol special case gives, just reached generically
      # rather than as a hardcoded type check. So `!mrb_equal(...)` is a
      # full, unconditional, no-fallback-needed reproduction of `!=` for
      # any receiver -- the same "no third real implementation to miss"
      # shape `dup` already has above, just via negation instead of a
      # type switch.
      arg = argv.first
      "  // != -- native primitive, no lookup needed for any receiver (real\n" \
      "  // bytecode is exactly `!(self == other)`, mrb_equal reproduces ==\n" \
      "  // exactly for every type -- see compile_native_primitive_send's own\n" \
      "  // NEQ_UNCONDITIONAL comment)\n" \
      "  r#{d} = mrb_bool_value(!mrb_equal(M, #{recv}, #{arg}));\n"
    when 'to_i'
      # TO_I_TYPE_TAG_DISPATCH: real grep across 3rd/mruby/src finds
      # `to_i` registered on Integer/Float/String plus (via mruby-time,
      # the one loaded non-core gem that registers it -- mruby-complex/
      # mruby-rational/mruby-object-ext all real registrations too, but
      # none of those three gems are ever `conf.gem`'d anywhere in this
      # project's own build_config.rb, confirmed by reading the whole
      # file, so none of their own `to_i` bodies can ever actually run
      # here) Time.
      #
      # MRB_TT_INTEGER: `mrb_obj_itself` (3rd/mruby/src/object.c) is
      # exactly `return self;` -- a real public MRB_API, trivially safe
      # for any receiver.
      #
      # MRB_TT_FLOAT: `flo_to_i` (3rd/mruby/src/numeric.c) is `mrb_check_
      # num_exact(mrb, f)` (raises FloatDomainError for NaN/Infinity --
      # itself just `isinf`/`isnan` plus `mrb_raise`, both reproduced
      # inline rather than linked: `mrb_check_num_exact` is declared only
      # in mruby/internal.h, no C-linkage guard), then -- only when
      # `!FIXABLE_FLOAT(f)` (real public macro, mruby/numeric.h) -- a
      # Bignum-promotion/overflow path through `mrb_bint_new_float`/
      # `mrb_int_overflow`, BOTH internal.h-only with no public MRB_API
      # substitute (the same "won't reach into mruby/internal.h for a
      # function with no public equivalent" posture `to_s`'s own case
      # already took deferring `mrb_mod_to_s`). So only the common finite-
      # and-in-range case is handled directly (real bodies for `f > 0.0`/
      # `f < 0.0` matched exactly via `floor`/`ceil`, `mrb_int_value` a
      # real public MRB_API); NaN, Infinity, and anything too large for a
      # native mrb_int fall through to ordinary `mrb_funcall`, which
      # raises/promotes exactly as real `flo_to_i` would.
      #
      # MRB_TT_STRING: `mrb_str_to_i` (3rd/mruby/src/string.c) reads
      # `mrb_get_args(mrb, "|i", &base)` -- a real call-frame read, but
      # this table's own `to_i` arity is pinned to 0 (see this table's own
      # comment above), and for that exact shape `mrb_str_to_i`'s own real
      # body always resolves `base` to its 10 default before calling the
      # real public MRB_API `mrb_str_to_integer(mrb, self, base, FALSE)`
      # -- confirmed by reading the whole function, not assumed. A real
      # `str.to_i(base)` call site (n=1) never reaches this table's own
      # arity gate at all and stays ordinary `mrb_funcall`, unaffected
      # (confirmed zero such call sites exist in this program today
      # anyway).
      #
      # MRB_TT_DATA (Time, mruby-time) deliberately excluded: `time_to_i`
      # reads straight from `struct mrb_time`, a type defined only inside
      # mruby-time's own time.c (never in the public mruby/time.h) --
      # fully opaque outside that one file, no public accessor for the raw
      # epoch-seconds field exists (`mrb_time_get_tm` returns a calendar
      # `struct tm*` via a real timezone-dependent recomputation, not a
      # safe drop-in substitute). Falls through to `default:`'s ordinary
      # `mrb_funcall`, like every other unhandled tag.
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

  # INTERP_UNLOCK: does MONO method `name` carry a hand-placed
  # `-> Array` return annotation? Consumed by the block recognizers'
  # chained rule (proven_array_source): a call result from such a
  # method is a fresh Array by the annotation's own claim. MONO-only
  # (one def program-wide -- POLY-safe by the same keying argument as
  # arg annotations: per-irep labels, never pooled by name). No
  # `compiles_clean?` requirement: the fact consumed is only about the
  # RETURN value's class, and the annotated methods (`stat_targets`
  # and friends) return Array literals on every path by construction.
  # Soundness rests on the comment being true -- hand-placed per
  # method, never inferred -- AND every admitted site still passes
  # through the emitter's own `mrb_array_p` raise-tripwire, which
  # verifies the claim at runtime: a wrong annotation raises loudly at
  # the first call, never silently miscompiles. Unknown/missing tokens
  # resolve to nil (TYPES simply has no entry), so a typo degrades to
  # today's honest `#error`, never a wrong gate.
  def annotated_array_return(name)
    defs = @registry[name]
    return false unless defs && defs.size == 1 && defs.first.irep

    @annotations[defs.first.irep]&.ret == :array
  end

  # ELEMENT_CLASS_SUPPORT: the same MONO-keyed annotation lookup
  # annotated_array_return performs, for the element dimension -- see
  # ElementAnnotations' own header for what each field claims and why a
  # hand-placed claim is safe here (every consumer runtime-guards it).
  # MONO-only for the identical reason: a magic comment sits on ONE irep,
  # so it can only speak for a call site when no other method in the whole
  # program shares the name.
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

  # ELEMENT_CLASS_SUPPORT: "the receiver of this block-carrying call is a
  # proven Array -- an Array of WHAT?" Asked by every block recognizer
  # right after its own static Array gate passes, and answered by exactly
  # the same top-level scan ArrayElementLayout's own sweep uses, so the
  # two can never drift apart on a soundness-critical question (the same
  # sharing argument proven_array_source's own comment makes for the
  # Array-ness question). This wrapper only supplies what is specific to a
  # CodeGen instance: the whole-program registry, the finished element
  # table, and the two annotation lookups.
  #
  # nil (the overwhelmingly common answer) means the loop body compiles
  # exactly as it did before this mechanism existed -- every per-element
  # call stays an ordinary POLY `mrb_funcall`.
  def proven_element_class(irep, idx, dest_reg, ivar_classes, mand, arg_classes, owner_name)
    array_element_source_scan(irep, idx, dest_reg, element_ctx(ivar_classes, mand, arg_classes, owner_name))
  end

  # Memoized for the same reason eqq_literal_devirt_safe? memoizes: the
  # registry never changes after CodeGen.new, so this is a pure function
  # of it, rebuilt once instead of per call site.
  def known_owner_set
    @known_owner_set ||= Set.new(@registry.values.flatten.map(&:owner))
  end

  # See self_receiver_class: every class some other class inherits from.
  # Memoized for the same reason as above -- @superclass_of is fixed at
  # construction.
  def subclassed_set
    @subclassed_set ||= Set.new(@superclass_of.values.select { |v| v.is_a?(String) })
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

  # SYM_DEVIRT: resolve a `&:sym` block-pass target for direct per-element
  # dispatch inside emit_sym_inline's own inlined loop. Returns
  # `[:mono, def]`, `[:poly, defs]`, or nil -- applying compile_send's own
  # full MONO guard sequence (pure-mandatory arity, call-site arity match,
  # ONLY_OWNERS/OTHER_OWNERS emission gate), NOT the bare
  # monomorphic_target lookup alone, which checks none of those. The one
  # deliberate simplification versus compile_send: the call-site arity is
  # always 0 (a `&:sym` call passes no positional arguments by
  # construction -- recognize_sym_regions already gates `n=0`), so the
  # arity check is `mandatory_arity == 0` rather than `== n`.
  #
  # MONO needs no element-type knowledge at all (exactly one definition
  # exists program-wide -- dispatch can only ever reach it). POLY needs a
  # per-element runtime class guard per candidate (emit_sym_inline's own
  # job, cloning compile_send's TYPED shape) -- so a POLY result is only
  # useful when every candidate passes the same four checks AND the chain
  # stays short (SYM_DEVIRT_CHAIN_CAP, user-confirmed at 4): a 16-way
  # `dispose` chain would be pure code bloat for a megamorphic site.
  # Anything else (native-only target like `Integer#even?`, an unclean
  # callee like `Game::Actor#full_heal`, over-cap POLY) returns nil and
  # the site keeps today's unconditional `mrb_funcall` -- already the
  # fastest sound option there, byte-identical to before this existed.
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
    # A usable subset smaller than the full def list is still unsound for
    # MONO (a skipped def is a real method some element could dispatch
    # to), and a partial POLY chain would silently misroute the skipped
    # classes' elements if the fallback were ever dropped -- require ALL
    # or nothing so the fallback (`mrb_funcall`, exact `Symbol#to_proc`
    # semantics) is merely an optimization miss, never a wrong dispatch.
    return nil unless usable.size == defs.size && !usable.empty?

    return [:mono, usable.first] if usable.size == 1
    return [:poly, usable] if usable.size <= SYM_DEVIRT_CHAIN_CAP

    nil
  end

  # SUPER_SUPPORT: the real target a `super`/`super(...)` inside
  # `owner_def`'s own method reaches -- the same-named MethodDef on
  # `owner_def.owner`'s own registered superclass -- but ONLY when
  # `owner_def`'s own "Owner#name" is in the SUPER_TARGETS allowlist
  # (see that constant's own top comment for the whole-program facts
  # this gates on that this function alone can't re-verify: no real
  # caller of THIS method ever passes a block, and no `include`/
  # `prepend` sits between `owner_def.owner` and its own superclass).
  # Unlike monomorphic_target (name-based, any owner), this is always
  # relative to one exact owner's own declared superclass -- never a
  # whole-program name search -- so a target here can be POLY by name
  # (several unrelated classes defining the same method) and still
  # resolve correctly, exactly the way real `super` dispatch always
  # ignores every OTHER same-named definition in the program.
  def super_target(owner_def)
    return nil unless SUPER_TARGETS.include?("#{owner_def.owner}##{owner_def.name}")

    superclass = @superclass_of[owner_def.owner]
    return nil unless superclass.is_a?(String)

    target_def = @registry[owner_def.name].find { |d| d.owner == superclass }
    return nil unless target_def && target_def.irep
    return nil unless compiles_clean?(target_def.irep)

    target_def
  end

  # Does compile_method(label) actually come out #error-free? A MONO name
  # whose one real definition has pure-mandatory arity still isn't safe to
  # devirtualize into if that definition's own body hits some OTHER
  # unsupported opcode -- real bug, caught building Game::Screen's own
  # compiled target (docs/adr/0139): #update calls #update_shake/
  # #update_flash by (MONO) name, but both bodies use a plain `MUL`, an
  # opcode this compiler has no compile_insn case for at all, so
  # SKIP_UNSUPPORTED correctly drops them from what's actually emitted --
  # except #update's own devirtualized call still referenced their _impl
  # functions directly, an undefined-reference link failure the two
  # previously-shipped targets never happened to hit (this is exactly the
  # pre-existing, "flagged for whoever next touches compile_send's own MONO
  # path" gap this same ADR already named, from the ONLY_OWNERS-only guard
  # a few lines below this method's own caller).
  #
  # Actually compiling the candidate (not just re-deriving compile_insn's
  # own opcode-support list by hand a second time, which would drift) is
  # the only way to answer this without duplicating that logic -- so this
  # memoizes a real compile_method(label) call and checks its own result
  # for a `#error` marker, the exact same test SKIP_UNSUPPORTED itself uses.
  #
  # Guarded against recursion (two MONO methods calling each other by
  # name): a label already being probed reports itself as "not (yet) known
  # clean" instead of recursing forever -- always the SAFE direction. A
  # real mutually-recursive MONO pair simply loses this one optimization
  # for each other (falls back to ordinary mrb_funcall dispatch), never an
  # unsound direct call to a function this run might not actually emit.
  def compiles_clean?(label)
    return @clean_cache[label] if @clean_cache.key?(label)
    return false if @probing.include?(label)

    @probing << label
    begin
      result = compile_method(label)
      @clean_cache[label] = !result[:code].include?('#error')
    ensure
      @probing.delete(label)
    end
  end

  def embed_type(owner, ivar)
    (@ivar_layout[owner] || {})[ivar]
  end

  def embedding_classes
    @ivar_layout.keys
  end

  def struct_name(owner)
    sanitize("#{owner}_ivars")
  end

  def type_var(owner)
    sanitize("#{owner}_ivars_type")
  end

  # ATTR_STRUCT_DEVIRT: the real compiled getter/setter pair for one
  # [owner, ivar, :reader | :writer] entry drop_unsafe_embeddings' own
  # @synthesize_accessor_for recorded -- see that method's own comment
  # for the full soundness argument (this is what makes it safe: once
  # register.cxx registers these, EVERY access path reaches struct-aware
  # code, not just a statically-devirtualized call site). No bytecode
  # body exists to translate (attr_reader/writer never had one), so this
  # hand-builds the exact same box/check/unbox codegen GETIV/SETIV
  # already use for an embedded ivar (compile_insn's own GETIV/SETIV
  # cases) instead. Returns one `compiled`-shaped Hash -- same keys
  # compile_method's own return value has (label/owner/name/entry/impl/
  # arity/arg_c_types/code/visibility) -- so it slots into the exact same
  # `compiled` array as every ordinary compiled method, needing no
  # special-casing from emit_forward_decls/emit_decls_header/the
  # `== compiled entry points ==` diagnostic below.
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
        arity: 0, arg_c_types: [], code: code, visibility: :public }
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
        arity: 1, arg_c_types: ['mrb_value'], code: code, visibility: :public }
    end
  end

  # Every synthesized accessor drop_unsafe_embeddings' own
  # @synthesize_accessor_for recorded, built AFTER compile_all runs (it
  # reads @ivar_layout, already finalized in initialize -- ordering here
  # doesn't matter the way it does for GETIV/SETIV codegen, but running
  # after keeps this call visually next to the rest of the post-compile
  # assembly in the driver below). `emit_ivar_accessor_pair` returning
  # nil (embed_type suddenly absent) can't actually happen -- an ivar
  # only ever enters @synthesize_accessor_for inside the same
  # drop_unsafe_embeddings pass that puts it in the real, final
  # @ivar_layout -- but checked rather than assumed, same discipline as
  # every other "this can't happen, but see for yourself" guard in this
  # file.
  #
  # `only_owners` mirrors compile_all's own filter (its own comment has
  # the real cross-gem-link-failure bug that guard exists for) -- an
  # owner this run isn't actually emitting gets no synthesized accessor
  # either, same reasoning: this run's own generated file would declare
  # a struct/DATA_PTR access for a class it never defines here.
  def emit_synthesized_accessors(only_owners: nil)
    pairs = @synthesize_accessor_for.to_a
    pairs = pairs.select { |owner, _, _| only_owners.include?(owner) } if only_owners
    pairs.sort.filter_map { |owner, ivar, which| emit_ivar_accessor_pair(owner, ivar, which) }
  end

  # One real C struct + mrb_data_type per class that has any embeddable
  # ivars -- the actual "embed known primitive ivars into RData" mechanism.
  # Non-embeddable ivars on the same class (Counter#@label, mixed
  # nil/String across sites) stay on the ordinary dynamic iv_tbl, which
  # coexists fine: RData carries both a `data` payload *and* a normal `iv`
  # table (mruby/data.h) -- this is exactly the same hybrid every RGSS
  # class in this project's own mruby-rgss/src/lib.cxx already uses.
  def emit_structs
    out = String.new
    @ivar_layout.each do |owner, ivars|
      # Same reasoning as compile_all's only_owners filter: a class outside
      # this run's emitted set gets no compiled methods either, so its
      # embedding struct/free-function/mrb_data_type would be pure dead
      # weight in the output (harmless to compile, but confusing, and an
      # unused static function warning) -- skip it, not just its methods.
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

  # ARY_ENTRY_INLINE: a same-translation-unit reproduction of
  # `mrb_ary_entry` (3rd/mruby/src/array.c, read directly) --
  #
  #   struct RArray *a = mrb_ary_ptr(ary);
  #   mrb_int len = ARY_LEN(a);
  #   if (n < 0) n += len;
  #   if (n < 0 || len <= n) return mrb_nil_value();
  #   return ARY_PTR(a)[n];
  #
  # -- byte-for-byte, using only the public `mrb_ary_ptr`/`ARY_LEN`/
  # `ARY_PTR` macros (mruby/array.h), never assumed equivalent. Every
  # text this file emits of the shape "mrb_ary_ref" + "(M, " + args +
  # ")" is replaced with "bc2cpp_ary_entry" + that identical "(M, " +
  # args + ")" (the unused `M` parameter kept only so every call site
  # stays a pure, mechanical, argument-for-argument rename -- the real
  # `mrb_ary_ref` macro is itself `#define mrb_ary_ref(mrb, ary, n)
  # mrb_ary_entry(ary, n)`, mruby/array.h read directly, so this changes
  # NOTHING about bounds-checking, negative-index normalizing, or the
  # nil-on-out-of-bounds result -- same behavior, different call target).
  #
  # The reason this exists at all: `mrb_ary_ref` is a macro alias for
  # `mrb_ary_entry`, a real out-of-line `MRB_API` function
  # (3rd/mruby/src/array.c) living in libmruby.a, a SEPARATE translation
  # unit from every file this tool generates -- and this project does not
  # build with LTO (docs/adr/0133/0135 record it being tried and reverted
  # for wio, never adopted generally), so that call cannot be inlined by
  # the real build, ever. Measured directly against this repo's own
  # `libmruby.a` at real `-O3` (no LTO): replacing the out-of-line call
  # with this in-TU `static inline` reproduction measured a real 2.3-2.4x
  # speedup on a 245M-element-visit micro-benchmark, reproduced twice --
  # by far the largest of the three array-access costs measured that
  # round (dwarfing both a known-element-type `mrb_fixnum()` shortcut and
  # a full unboxed-element representation change, the latter of which was
  # rejected outright: 3rd/mruby's own GC walks a real `RArray` to mark
  # array elements (src/gc.c, gc_mark_children), so anything other than a
  # real `RArray` backing every array this file emits is a live
  # use-after-free hazard, not a soundness tradeoff this file's usual
  # "wrong hint just falls back to mrb_funcall" guard shape can cover).
  # Purely mechanical and behavior-preserving, so no `#error`/fallback
  # path is needed here the way a real class hint would need one -- this
  # is not a new fact being trusted, just where the exact same, always-
  # true fact (`mrb_ary_ref`'s real definition) gets evaluated.
  #
  # Emitted once per generated file, and only when at least one compiled
  # method's own text actually calls it (scanning `compiled`'s own
  # already-assembled `:code` text -- same "only emit what's needed"
  # shape as emit_const_lookup_helper below, just checked post hoc
  # against the real output instead of a flag threaded through every one
  # of this file's own ~20 emission call sites individually).
  def emit_ary_entry_helper(compiled)
    return '' unless compiled.any? { |m| m[:code].include?('bc2cpp_ary_entry(') }

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

  # The shared helper GETCONST's own owner-scope-first codegen calls
  # (compile_insn's own comment has the full story on why a bare
  # `mrb_const_get` can't just be tried-then-polled with mrb_check_error --
  # it raises via a real longjmp, never returning to let the caller check
  # anything). `mrb_protect_error` (mruby/error.h) is the real, always-
  # available core primitive for "run this and tell me if it raised,
  # without letting the raise itself unwind past me": it takes a plain C
  # function pointer plus a void* payload, so the actual lookup has to be
  # a real top-level static function (LookupCtx/lookup_body below) rather
  # than a lambda or inline call -- C, not C++ closures, is what this API
  # takes. Emitted once per generated file (not once per call site), and
  # only when at least one compiled method actually needs it
  # (const_lookup_helper_used?, set by compile_insn while compiling).
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
        Bc2cppConstLookupCtx ctx{scope, name};
        mrb_bool err = FALSE;
        mrb_value result = mrb_protect_error(M, bc2cpp_const_lookup_body, &ctx, &err);
        *ok = !err;
        return result;
      }

    CPP
  end

  # Forward declarations for the lib.cxx entry points NATIVE_CONSTRUCT_
  # TARGETS names -- emitted once per generated file, and only for the
  # entries at least one compiled `.new` call site actually used (same
  # "declare only what's needed" shape as emit_const_lookup_helper).
  # These are real, hand-written C++ functions defined in mruby-rgss/
  # src/lib.cxx (not generated), so -- unlike emit_forward_decls' own
  # `_impl` declarations -- this only ever declares them, never defines
  # them; the definitions reach this translation unit at link time the
  # same way any other cross-file C++ call in this project's native gems
  # already does. `extern "C"`, matching lib.cxx's own definitions exactly
  # (see that file's own comment on why: each one sits inside lib.cxx's
  # top-level anonymous namespace, and only an `extern "C"` declaration
  # escapes that namespace's own internal linkage) -- a plain C++-linkage
  # declaration here would silently mangle a different symbol name than
  # the real (extern "C") one lib.cxx defines and fail to link; caught
  # exactly this way building the very first real caller (RGSS::Sprite's
  # own #tone/#color/#src_rect).
  #
  # Parameter types have to match lib.cxx's own real (native, not
  # mrb_value) signature exactly, one real C++ overload-resolution/linkage
  # concern, not just documentation -- see that file's own comment on
  # these three functions for why `klass` is `RClass*` and every other
  # parameter is `arg_type`'s own native C++ type (`mrb_int`/`mrb_float`).
  def emit_native_construct_decls
    return '' unless @native_construct_used.any?

    out = String.new
    out << "// mruby-rgss/src/lib.cxx's own devirtualized-construction entry\n"
    out << "// points (see that file's own DataType<T> comment) -- called\n"
    out << "// directly in place of Class#new's own allocate+initialize\n"
    out << "// dispatch when a `.new` call site's receiver is provably one of\n"
    out << "// these native DataType<T>-backed classes (compile_send's own\n"
    out << "// \"MONO :new -> direct native construct\" path).\n"
    out << "extern \"C\" {\n"
    @native_construct_used.sort.each do |known|
      native = NATIVE_CONSTRUCT_TARGETS.fetch(known)
      out << "RClass* #{native[:class_fn]}(void);\n"
      native_type = native[:arg_type] == :int ? 'mrb_int' : 'mrb_float'
      params = (['mrb_state*', 'RClass*'] + [native_type] * native[:arity]).join(', ')
      out << "mrb_value #{native[:fn]}(#{params});\n"
    end
    out << "}\n"
    out << "\n"
    out
  end

  # The class-identity accessor function name DIRECT_CONSTRUCT_TARGETS'
  # generalized path calls for `owner` (e.g. "Game::Transition" ->
  # "Game__Transition_compiled_class") -- derived via the same `sanitize`
  # every other generated identifier in this file already goes through,
  # rather than hand-carried per entry the way NATIVE_CONSTRUCT_TARGETS'
  # own `class_fn` is: unlike Rect/Color/Tone's own lib.cxx entry points
  # (arbitrary hand-written names, no derivable convention), this name is
  # purely mechanical, and a compiled gem's own register.cxx (the one place
  # that actually DEFINES it -- see that file's own comment) can and does
  # spell it exactly this way, so there is nothing here worth a second
  # hand-maintained string to drift out of sync with.
  def direct_construct_class_fn(owner)
    "#{sanitize(owner)}_compiled_class"
  end

  # Forward declarations for DIRECT_CONSTRUCT_TARGETS' generalized
  # construction path -- emitted once per generated file, and only for what
  # at least one compiled `.new` call site actually used (same "declare
  # only what's needed" shape as emit_native_construct_decls/
  # emit_const_lookup_helper).
  #
  # Two distinct things, both only declared here, never defined:
  #
  # 1. `bc2cpp_direct_alloc` -- a GENERIC replacement for Class#new's own
  #    `self.allocate` step, correct for ANY class regardless of its own
  #    instance type (see its own body's comment for the real proof this
  #    isn't RGSS::Sprite/#tone-specific reasoning). Defined here too (not
  #    just declared) since, unlike a per-class native constructor, this one
  #    helper is genuinely part of bc2cpp's own generated output -- there is
  #    no natural per-gem "one real place" to hand-write it the way
  #    register.cxx is for the accessor functions below, and every consumer
  #    of it needs the identical body regardless of which gem's own
  #    register.cxx eventually calls it.
  # 2. One class-identity accessor per DIRECT_CONSTRUCT_TARGETS owner
  #    actually used (direct_construct_class_fn) -- a REAL function this
  #    owner's own compiled gem's register.cxx defines (mirroring
  #    NATIVE_CONSTRUCT_TARGETS' own class_fn precedent, mruby-rgss/src/
  #    lib.cxx's g_native_rect_class/rgss_native_rect_class()), declared
  #    here only. Unlike emit_native_construct_decls' own `extern "C"`
  #    declarations (needed there because lib.cxx's real definitions sit
  #    inside an anonymous namespace, and are reached from a genuinely
  #    different translation unit), this is a plain ordinary C++ declaration
  #    -- exactly like every `_impl` forward declaration emit_forward_decls
  #    already emits -- because both sides of this one are real C++ code:
  #    the accessor's own real definition lives in the SAME compiled gem's
  #    register.cxx, which #includes this generated file directly (see that
  #    file's own comment) and so shares one translation unit with this
  #    declaration; C++'s own language-linkage rule ([dcl.link]) means a
  #    later definition in that same TU need not (and here, does not) repeat
  #    any linkage specifier this declaration didn't use, so plain C++
  #    linkage on both sides matches automatically. Every candidate this
  #    round targets lives in the one gem that also consumes it
  #    (mruby-rpg2k-compiled); a future cross-gem consumer of one of these
  #    accessors would need the same OTHER_DECLS_HEADER treatment
  #    emit_decls_header's own comment describes for `_impl` -- not wired up
  #    here since no real call site needs it yet (same "safe miss, not
  #    attempted" discipline as every other unhandled shape in this file).
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

  # `only_owners`, when given, restricts which classes' methods actually get
  # emitted -- but the registry/ivar_layout this CodeGen was built with must
  # still come from the WHOLE closed world (every gem that could define a
  # colliding method name), never from just the source files of the classes
  # being emitted. Confirmed a real, non-hypothetical concern while wiring
  # up the first real caller (mruby-lcf-compiled, docs/adr/0139): analyzed
  # alone, LCF::Database#rpg2003? is the only :rpg2003? definition in
  # mruby-lcf's own mrblib -- but the real game also defines Game::Actor
  # /Party/Battle#rpg2003?, 4 definitions total, genuinely polymorphic. A
  # narrower closed world would have silently mis-resolved that name as
  # monomorphic for every *other* future caller of `.rpg2003?` in the whole
  # program (this particular call site -- Database#maker's `self.rpg2003?`
  # -- happens to be safe either way, since `self` here is always a
  # Database, but the registry itself would have been wrong).
  # `other_owners`: classes this run doesn't compile itself but trusts
  # *some other* translation unit in the same final link to define --
  # see monomorphic_target's own comment and this file's cross-TU decls
  # header (emit_decls_header) for why a devirtualized call to one of
  # these is safe to emit here at all (an external, non-static _impl
  # declared via #include, resolved by the linker at final link time).
  #
  # Follow-up (docs/adr/0139): `only_owners.include?(...)` below is (and
  # has always been) a plain string-membership check against whatever
  # `@owner_of.fetch(l).owner` happens to be -- it was never the thing
  # standing between a `"ClassName.singleton"` pseudo-owner (SDEF/SCLASS/
  # the unfused-DEF singleton branch's own owner string, see build_registry
  # above) and being selected here. Two OTHER facts were: every real
  # `owners:` entry ever written in compiled_gems.rb has, by convention,
  # named only a real Ruby constant path (never a `.singleton`-suffixed
  # string, so `only_owners` itself never contained one to match against);
  # and, until this same follow-up, SDEF's own fused `def self.x` shape
  # registered its MethodDef with `irep: nil`, so `@owner_of[d.irep] = d if
  # d.irep` (this file's own leaf-worklist builder, see its own comment)
  # never even inserted an entry for it into `@owner_of` in the first
  # place -- invisible to `leaves = @owner_of.keys` before this line ever
  # ran, regardless of what `only_owners` contained. A `.singleton`-owned
  # MethodDef reached via SCLASS or the unfused-DEF singleton branch
  # already had a real irep and was therefore already a real key in
  # `@owner_of` -- already selectable here, in principle, the moment some
  # `owners:` list ever named its pseudo-owner string (confirmed directly:
  # docs/adr/0139's own RGSS::Font/RGSS::Bitmap follow-ups added
  # `RGSS::Bitmap.singleton`/`RGSS::Font.singleton` to `ONLY_OWNERS` in
  # isolated diagnostic-only runs and got real registry hits for
  # `self.extensions`/`self.exist?` back). So no change to this method's
  # own filtering logic was needed to "accept" a `.singleton` owner -- the
  # real, load-bearing fix is the SDEF-irep one above (closing the last gap
  # that kept a `def self.x`-shaped MethodDef out of `@owner_of` at all)
  # plus `compiled_gems.rb` actually choosing to write one into a real
  # `owners:` list for the first time (see that file's own RGSS::Bitmap
  # follow-up). Kept this comment here, not just there, so a future reader
  # checking "does compile_all's own filter need to change for this"
  # finds the answer at the filter itself, not just at the one call site
  # that happens to exercise it. The identical plain-string-membership
  # `@only_owners.include?(target.owner)` guard in compile_send (this
  # file's own call-site devirtualization, searched separately) needs the
  # same answer for the same reason -- also unmodified.
  def compile_all(only_owners: nil, other_owners: nil)
    @only_owners = only_owners
    @other_owners = other_owners
    # SYM_DEVIRT route pre-pass: sym_call_target (MONO/POLY per-element
    # resolution inside emit_sym_inline) calls compiles_clean? on CALLEE
    # labels, whose own compile_method runs each recognizer against
    # @only_owners/@other_owners -- both must be assigned BEFORE any
    # compile_method runs, or a callee probed from inside another
    # method's own compilation sees a nil-owner gate and wrongly misses.
    # compile_method itself never assigns these (single-assignment here),
    # so the ordering is simply this-then-map below, never racy.
    leaves = @owner_of.keys
    leaves = leaves.select { |l| only_owners.include?(@owner_of.fetch(l).owner) } if only_owners
    leaves.map { |label| compile_method(label) }
  end

  # Forward declarations for every compiled function, emitted before any
  # bodies. A monomorphic direct call can legitimately target a method
  # defined *later* in file order (real Ruby has no such ordering
  # constraint -- this toy's own original example only ever avoided the
  # problem by luck, calling things in the order they happened to be
  # `def`'d; real, larger source doesn't). Without this, `compile_method`'s
  # own single-pass emission order would make some direct calls reference
  # an as-yet-undeclared function.
  def emit_forward_decls(compiled)
    out = String.new
    compiled.each do |m|
      out << "#{decl_line(m)};\n"
      # The entry wrapper (mrb_get_args marshaling) stays static/file-local
      # -- unlike _impl, nothing outside this one gem's own registration
      # code ever calls it, so it never needs cross-TU visibility.
      out << "static mrb_value #{m[:entry]}(mrb_state*, mrb_value);\n"
    end
    out << "\n"
    out
  end

  # A standalone, `#pragma once`-guarded header of the same declarations
  # emit_forward_decls puts inline in the generated .cpp -- the actual
  # cross-TU artifact. `_impl`/entry functions are no longer `static` (see
  # compile_method) specifically so a *different* gem's own generated .cpp
  # can declare them via this header (OTHER_DECLS_HEADER, wired in
  # mrbgem.rake) and the linker can resolve a devirtualized call across
  # gem boundaries at final link time -- previously impossible: every
  # `_impl` was file-local (`static`), so `monomorphic_target`'s own
  # @only_owners guard had to refuse any cross-gem target outright (see
  # compile_send's own comment on the real LCF.write_ber/LCF.binstr bug
  # this guard was originally added for).
  def emit_decls_header(compiled)
    out = String.new
    out << "#pragma once\n"
    out << "#include <mruby.h>\n\n"
    compiled.each { |m| out << "#{decl_line(m)};\n" }
    out << "\n"
    out
  end

  # `m[:arg_c_types]` (set by compile_method below) is each mandatory
  # position's own real C++ parameter type -- `mrb_value` uniformly for
  # every method NATIVE_ARG_TARGETS doesn't name (today's own established
  # shape, unchanged), or a mix of `mrb_value`/`mrb_int`/`mrb_sym` for one
  # it does. `self` is never native-typed (NATIVE_ARG_TARGETS only ever
  # retypes a method's own mandatory *arguments*, never its receiver), so
  # it stays the one hardcoded `mrb_value` here regardless. Falls back to
  # an all-`mrb_value` array when absent (the `#error`-stub early-return
  # branch of compile_method never sets this key) -- identical to this
  # method's own pre-existing behavior in that case.
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

    # OPTIONAL_ARG_SUPPORT: `opt` is >0 only for a real, exactly-recognized
    # "plain optional positional arguments, nothing else non-mandatory"
    # shape -- see optional_arg_table's own comment. Every other
    # non-mandatory shape (rest, keyword, block, ...) still falls through
    # to the ordinary #error stub below, completely unchanged from before
    # this existed. `mandatory_ok` short-circuits the (irep-instructions-
    # scanning) optional_arg_table call entirely for the overwhelmingly
    # common pure-mandatory case, same as before.
    mandatory_ok = pure_mandatory_arity?(irep)
    opt, opt_jmp_addrs, opt_jmp_targets = mandatory_ok ? [0, nil, nil] : optional_arg_table(irep)
    # KEYWORD_ARG_SUPPORT: only attempted once both of the above have
    # already failed (mandatory_ok and opt_jmp_targets are mutually
    # exclusive with a real keyword-only ENTER shape by construction --
    # keyword_arg_table's own gate refuses unless `opt` is zero too), same
    # short-circuiting shape as opt_jmp_targets' own guard above.
    kw_table = (mandatory_ok || opt_jmp_targets) ? nil : keyword_arg_table(irep)
    # REST_ARG_SUPPORT: same short-circuiting shape as kw_table's own guard
    # above -- see rest_only_arity?'s own comment for why a real `*rest`
    # needs no opcode-level region of its own at all, just one more
    # contiguous `total_args` slot (below), the exact same mechanism
    # OPTIONAL_ARG_SUPPORT's own `opt` extension already established.
    has_rest = (mandatory_ok || opt_jmp_targets || kw_table) ? false : rest_only_arity?(irep)
    supported = mandatory_ok || opt_jmp_targets || kw_table || has_rest

    total_args = supported ? mand + opt + (has_rest ? 1 : 0) : mand
    arg_names = irep.lv.first(total_args).each_with_index.map { |n, i| n ? sanitize_c_ident(n) : "arg#{i + 1}" }
    # NATIVE_ARG_TARGETS' own per-position native type, size == mand -- see
    # native_arg_types' own comment. All-nil (every position stays plain
    # `mrb_value`, today's own uniform shape) unless this exact
    # "Owner#name" is explicitly listed there AND a real annotation names a
    # recognized type at that position. A real optional argument (`opt` >
    # 0) is never NATIVE_ARG_TARGETS-eligible -- that set only ever names
    # already-pure-mandatory methods, so this padding is always all-nil in
    # practice, just kept explicit rather than relying on that coincidence.
    arg_native_types = native_arg_types(d, mand) + Array.new(total_args - mand)

    impl_name = "#{cpp_name(d.owner, d.name)}_impl"
    entry_name = cpp_name(d.owner, d.name)
    embedded_ivars = @ivar_layout[d.owner]

    unless supported
      # Not modeled -- see pure_mandatory_arity?/optional_arg_table's own
      # comments. Emit a loud, honest #error instead of a function whose
      # signature silently disagrees with what real call sites (interpreted
      # or a devirtualized direct call) actually pass it.
      code = "// #{d.owner}##{d.name} (compiled from irep #{label}, #{irep.instructions.size} insns)\n" \
             "#error #{d.owner}##{d.name} has non-mandatory arguments (optional/rest/keyword/block) -- not in this prototype's supported subset\n\n"
      return { label: label, owner: d.owner, name: d.name, entry: entry_name, impl: impl_name,
               arity: arg_names.size, code: code, unsupported: true, visibility: d.visibility }
    end

    out = String.new
    out << "// #{d.owner}##{d.name} (compiled from irep #{label}, #{irep.instructions.size} insns)\n"
    # Not `static`: a devirtualized call from a *different* gem's own
    # generated .cpp (OTHER_OWNERS/OTHER_DECLS_HEADER, see mrbgem.rake) can
    # only resolve this at final link time if it's an ordinary externally-
    # linked symbol -- see emit_decls_header's own comment.
    #
    # Each mandatory parameter's own C++ type comes from arg_native_types
    # (native_c_type(nil) is plain `mrb_value`, unchanged from before this
    # mechanism existed) -- `self` is never affected, only ever
    # NATIVE_ARG_TARGETS' own explicitly-listed arguments.
    arg_params = arg_names.each_with_index.map { |a, i| "#{native_c_type(arg_native_types[i])} #{a}" }
    # OPTIONAL_ARG_SUPPORT: one extra real parameter, `bc2cpp_given_opt` --
    # how many of this method's own real optional arguments THIS call
    # actually supplied (0..opt) -- the switch emit_optional_dispatch
    # builds below reads it directly; a slot for an optional argument NOT
    # supplied still gets a real (unused until the default-value code
    # itself overwrites its register) placeholder argument from every
    # caller, same as every other parameter here.
    arg_params << 'mrb_int bc2cpp_given_opt' if opt.positive?
    # KEYWORD_ARG_SUPPORT: one real `mrb_value` parameter per keyword
    # (required or optional alike -- see keyword_arg_table's own comment),
    # plus one extra `mrb_int` "was it given" parameter for each optional
    # one only (a required keyword is always given -- mrb_get_args itself
    # already raises ArgumentError otherwise, before _impl is ever
    # reached). Natural bytecode-declaration order, matching the entry
    # wrapper's own call below exactly.
    kw_table&.each do |kw|
      arg_params << "mrb_value #{kwarg_param_name(kw[:name])}"
      arg_params << "mrb_int #{kw_given_param_name(kw[:name])}" unless kw[:required]
    end
    out << "mrb_value #{impl_name}(mrb_state* M, #{(['mrb_value self'] + arg_params).join(', ')}) {\n"
    (0...irep.nregs).each { |i| out << "  mrb_value r#{i}" << (i.zero? ? ' = self;' : ' = mrb_nil_value();') << "\n" }
    # A native-typed argument's own register still holds a plain mrb_value
    # like every other VM register in this whole function (see this file's
    # own top comment: NATIVE_ARG_TARGETS only moves the FFI boundary's own
    # coercion earlier -- it is NOT full register-level type specialization)
    # -- so its very first assignment has to *box* the native value back
    # into one, via the same TYPE_OPS[:box] call IvarLayout's own embedded-
    # ivar SETIV codegen already uses for the identical purpose. A plain
    # `mrb_value` argument keeps today's own bare identity assignment.
    arg_names.each_with_index do |a, i|
      t = arg_native_types[i]
      out << if t
                "  r#{i + 1} = #{TYPE_OPS.fetch(t)[:box]}(#{a});\n"
              else
                "  r#{i + 1} = #{a};\n"
              end
    end
    if embedded_ivars && d.name == 'initialize'
      # self is a bare, freshly allocated MRB_TT_DATA shell (data == NULL)
      # at the start of #initialize -- allocate the real struct once, here,
      # before any SETIV on an embedded ivar can write into it.
      sname = struct_name(d.owner)
      out << "  {\n"
      out << "    #{sname}* embedded = (#{sname}*)mrb_calloc(M, 1, sizeof(#{sname}));\n"
      out << "    mrb_data_init(self, embedded, &#{type_var(d.owner)});\n"
      out << "  }\n"
    end
    # Goto-threaded control flow: every address any JMP/JMPNOT/JMPIF in this
    # irep can target gets a real C label (`L<addr>:`), and those three
    # opcodes translate straight to `goto`/conditional `goto` -- this is a
    # general, mechanical way to reproduce arbitrary bytecode control flow
    # (branches AND loops) without reconstructing a structured CFG (if/else,
    # while, ...) from the jump graph. All registers are already declared as
    # plain mrb_value locals above, before any label, so C++'s "goto must not
    # jump over a variable's initialization" rule can never be violated here.
    # RESCUE_SUPPORT: every recognized region (recognize_rescue_regions --
    # see its own top comment for the exact shape required) gets a
    # separate, real, extracted "try body" function -- emitted below,
    # ahead of this function, since this function calls it -- and its own
    # [begin_addr, end_addr] address range (the protected computation
    # itself, plus its own trailing exit JMP) is skipped entirely by this
    # loop below: emit_rescue_glue emits the actual `mrb_protect_error`
    # call plus the `if (!err) return ...;` early-out in its place, right
    # where the loop reaches that region's own begin_addr, and everything
    # from `except_addr` onward (EXCEPT itself, and only that one address)
    # is *also* skipped -- its own effect (capturing the exception into
    # r<exc_reg>) is folded into emit_rescue_glue's own last line instead,
    # since nothing else in this file can ever give EXCEPT a real,
    # non-`#error` translation of its own (see RESCUE_SUPPORT's own
    # compile_insn case comment). GETCONST/RESCUE/JMPIF/JMP/RAISEIF and
    # the rescue clause's own handler body all continue right on through
    # this same loop, completely unmodified -- no other opcode here needs
    # any special-casing at all.
    rescue_regions = recognize_rescue_regions(irep)
    rescue_pre = String.new
    suppressed = Set.new
    glue_at = {}

    # OPTIONAL_ARG_SUPPORT: same suppressed-address/glue-at mechanism as
    # RESCUE_SUPPORT/BLOCK_SUPPORT below, replacing the real ENTER jump
    # table (optional_arg_table's own comment) with an equivalent native
    # `switch` on the real given-optional-count parameter -- every other
    # address in the region (each optional's own default-value computation,
    # already ordinary already-supported bytecode) is untouched, reached
    # only via `goto` from this switch exactly the way the real VM's own
    # PC-skip reaches it.
    if opt.positive? && opt_jmp_targets
      opt_jmp_addrs.each { |a| suppressed << a }
      glue_at[opt_jmp_addrs.first] = emit_optional_dispatch(opt_jmp_targets)
    end

    rescue_regions.each_with_index do |region, i|
      suppressed.merge((region[:begin_addr]..region[:end_addr]).to_a)
      suppressed << region[:except_addr]
      try_name = "#{impl_name}_rescue_try#{rescue_regions.size > 1 ? "_#{i}" : ''}"
      rescue_pre << emit_rescue_try_body(try_name, region, irep, d, arg_names, arg_native_types)
      glue_at[region[:begin_addr]] = emit_rescue_glue(try_name, region, arg_names, arg_native_types)
    end

    # BLOCK_SUPPORT: same suppressed-address/glue-at mechanism as RESCUE_
    # SUPPORT just above, for a recognized `.times` region (see
    # recognize_times_regions/emit_times_inline's own comments) -- both
    # the BLOCK and SENDB addresses are replaced by one inlined-loop
    # chunk emitted at the BLOCK's own address. A region whose own block
    # body doesn't come out clean (emit_times_inline returns nil) is
    # simply skipped here -- BLOCK/SENDB then fall through to the
    # ordinary per-instruction loop below completely unmodified, hitting
    # compile_insn's own default `#error unhandled opcode` case exactly
    # like any other unrecognized shape in this file.
    recognize_times_regions(irep).each do |region|
      inlined = emit_times_inline(region, irep, d)
      next unless inlined

      suppressed << region[:block_addr] << region[:sendb_addr]
      glue_at[region[:block_addr]] = inlined
    end

    # EACH_BLOCK_SUPPORT: same suppressed-address/glue-at mechanism as the
    # times loop just above, for recognized `ary.each` and `&:sym`
    # regions. The static Array gate lives in the recognizers themselves
    # (trace_new_target/ClassLayout, mirroring compile_send's own TYPED
    # path context); a region that fails any check simply never appears
    # here, and its BLOCK/SENDB/LOADSYM fall through to the ordinary
    # honest `#error` stubs below. A region whose own body doesn't come
    # out clean (emit_* returns nil) is skipped the same way.
    each_ctx_ivar = @class_layout[d.owner]
    each_ctx_args = @class_annotations[irep.label]&.args
    recognize_each_regions(irep, d.owner, mand, each_ctx_ivar, each_ctx_args).each do |region|
      inlined = emit_each_inline(region, irep, d)
      next unless inlined

      suppressed << region[:block_addr] << region[:sendb_addr]
      glue_at[region[:block_addr]] = inlined
    end
    # EACH_INDEX_SUPPORT: same mechanism for recognized
    # `ary.each_index { |i| ... }` regions (recognize_each_index_regions
    # above). Same all-or-nothing contract; distinct method name
    # (`:each_index`, never `:each`) so no collision with the Array
    # #each recognizer just above.
    recognize_each_index_regions(irep, d.owner, mand, each_ctx_ivar, each_ctx_args).each do |region|
      inlined = emit_each_index_inline(region, irep, d)
      next unless inlined

      suppressed << region[:block_addr] << region[:sendb_addr]
      glue_at[region[:block_addr]] = inlined
    end
    # HASH_EACH_SUPPORT: same mechanism for recognized `hash.each { |k, v|
    # ... }` regions (recognize_hash_each_regions above). Same all-or-
    # nothing contract; shares the ':each' method name with the Array
    # recognizer just above but never collides with it (mutually
    # exclusive receiver-class gates -- see that recognizer's own
    # comment).
    recognize_hash_each_regions(irep, d.owner, mand, each_ctx_ivar, each_ctx_args).each do |region|
      inlined = emit_hash_each_inline(region, irep, d)
      next unless inlined

      suppressed << region[:block_addr] << region[:sendb_addr]
      glue_at[region[:block_addr]] = inlined
    end
    # EACH_KEY_SUPPORT: same mechanism for recognized `hash.each_key { |k|
    # ... }` regions (recognize_each_key_regions above). Same all-or-
    # nothing contract; distinct method name (`:each_key`, never
    # `:each`) so no collision with the Hash #each recognizer just
    # above.
    recognize_each_key_regions(irep, d.owner, mand, each_ctx_ivar, each_ctx_args).each do |region|
      inlined = emit_each_key_inline(region, irep, d)
      next unless inlined

      suppressed << region[:block_addr] << region[:sendb_addr]
      glue_at[region[:block_addr]] = inlined
    end
    # INTERP_UNLOCK: same mechanism for recognized `Range#each`
    # regions. Same gate shape (Range, not Array), same all-or-nothing
    # contract.
    recognize_range_each_regions(irep, d.owner, mand, each_ctx_ivar, each_ctx_args).each do |region|
      inlined = emit_range_each_inline(region, irep, d)
      next unless inlined

      suppressed << region[:block_addr] << region[:sendb_addr]
      glue_at[region[:block_addr]] = inlined
    end
    recognize_sym_regions(irep, d.owner, mand, each_ctx_ivar, each_ctx_args).each do |region|
      inlined = emit_sym_inline(region, irep, d)
      next unless inlined

      suppressed << region[:sym_addr] << region[:sendb_addr]
      glue_at[region[:sym_addr]] = inlined
    end
    # MAP_BLOCK_SUPPORT: same mechanism for recognized collection-block
    # regions (`map`/`select`/`reject`/`find`/`each_with_index` literal
    # blocks). Same Array gate, same all-or-nothing contract -- a dirty
    # body or a missed gate falls through to honest `#error` stubs.
    recognize_collect_regions(irep, d.owner, mand, each_ctx_ivar, each_ctx_args).each do |region|
      inlined = emit_collect_inline(region, irep, d)
      next unless inlined

      suppressed << region[:block_addr] << region[:sendb_addr]
      glue_at[region[:block_addr]] = inlined
    end
    # ACCUM_BLOCK_SUPPORT: same mechanism for accumulator/predicate
    # regions (`any?`/`all?`/`none?`/`count` literal blocks,
    # `reduce`/`inject(init)` folds). Same gate, same contract.
    recognize_accum_regions(irep, d.owner, mand, each_ctx_ivar, each_ctx_args).each do |region|
      inlined = emit_accum_inline(region, irep, d)
      next unless inlined

      suppressed << region[:block_addr] << region[:sendb_addr]
      glue_at[region[:block_addr]] = inlined
    end
    # SORT_BLOCK_SUPPORT: same mechanism for sort-family regions
    # (`sort_by`/`uniq` key blocks; `sort`-comparator shapes are
    # recognized-and-rejected inside the emitter). Same gate, same
    # contract.
    recognize_sort_regions(irep, d.owner, mand, each_ctx_ivar, each_ctx_args).each do |region|
      inlined = emit_sort_inline(region, irep, d)
      next unless inlined

      suppressed << region[:block_addr] << region[:sendb_addr]
      glue_at[region[:block_addr]] = inlined
    end

    # JUMP_TARGET_GLUE_FIX: a real, caught bug -- `- suppressed` alone
    # would ALSO drop the label for any address that is suppressed but
    # still has real replacement code sitting at it (`glue_at.key?`), and
    # a suppressed BLOCK/SENDB region's own `block_addr` is exactly such
    # an address whenever it's also a genuine jump target from elsewhere
    # in the SAME method -- e.g. `(h[:x] || {}).each { ... }`: `||`'s own
    # short-circuit JMPIF lands directly on the `.each` call's BLOCK
    # instruction the moment the left side is truthy, which is *exactly*
    # `region[:block_addr]`. Confirmed live, not hypothetical: caught by
    # a real `g++ -fsyntax-only` check on the actual generated output
    # (bc2cpp.rb's own `#error`-marker diagnostics can never catch this --
    # the emitted C++ is syntactically well-formed everywhere except the
    # missing label itself) after HASH_EACH_SUPPORT's own recognizer
    # inlined `Game::Battle#roll_weapon_states`' `(states[:inflict] ||
    # {}).each { ... }` for the first time -- `goto L68;` with no `L68:;`
    # anywhere, a hard compile error. Every OTHER block recognizer
    # (times/each/collect/accum/sym/range_each/sort) shares this exact
    # same suppressed/glue_at/targets machinery and was equally exposed
    # to this bug in principle; it simply happened that no real call site
    # any of them recognized, anywhere in this closed world, combined
    # "receiver expression with a preceding short-circuit landing exactly
    # on the block address" until this one. `suppressed - glue_at.keys`
    # is the precise fix: only an address that's suppressed WITHOUT real
    # replacement code (the interior of a RESCUE region's own suppressed
    # range, `(begin_addr..end_addr).to_a` minus `begin_addr` itself,
    # which alone carries a `glue_at` entry) should still lose its label
    # -- anything with a `glue_at` entry has real code starting exactly
    # there, so a jump landing on it is always well-defined.
    targets = jump_targets(irep) - (suppressed - glue_at.keys)
    irep.instructions.each_with_index do |insn, idx|
      next if suppressed.include?(insn.addr) && !glue_at.key?(insn.addr)

      out << "  L#{insn.addr}:;\n" if targets.include?(insn.addr)
      out << (glue_at[insn.addr] || compile_insn(insn, irep, d, idx))
    end
    out << "  return mrb_nil_value(); // unreachable if every path RETURNs\n"
    out << "}\n\n"
    out = rescue_pre + out

    out << "static mrb_value #{entry_name}(mrb_state* M, mrb_value self) {\n"
    if arg_names.empty? && !kw_table
      out << "  return #{impl_name}(M, self);\n"
    elsif kw_table
      # KEYWORD_ARG_SUPPORT: the real mrb_kwargs mechanism mruby.h's own
      # `mrb_get_args` `:` format specifier documents -- `required` names
      # how many of `table`'s own entries (which MUST list every required
      # keyword first) are mandatory; `values[i]` comes back `mrb_undef_p`
      # for an omitted optional keyword, real Ruby's own "undef" sentinel,
      # never safe to hand to ordinary code (see the mrb_nil_value()
      # fallback below -- the same "never a raw uninitialized/sentinel
      # value" trust model OPTIONAL_ARG_SUPPORT's own `mrb_nil_value()`
      # placeholder already establishes). `rest: NULL` means an
      # unrecognized keyword raises ArgumentError automatically -- the
      # real semantics KEYEND's own compile_insn case relies on already
      # being enforced here, before _impl is ever reached (this round
      # never declares a real `**kwrest` receiver -- see keyword_arg_
      # table's own comment on why that's a real, confirmed non-issue for
      # every currently-blocked keyword-only method, not just an
      # unhandled gap). Mandatory positional arguments (if any) are
      # unpacked exactly like the plain, non-keyword case above, just with
      # `:` plus one extra `&bc2cpp_kwargs` pointer appended.
      arg_names.each_with_index { |a, i| out << "  #{native_c_type(arg_native_types[i])} #{a};\n" }
      required_kws = kw_table.select { |kw| kw[:required] }
      optional_kws = kw_table.reject { |kw| kw[:required] }
      ordered_kws = required_kws + optional_kws
      table_entries = ordered_kws.map { |kw| "mrb_intern_cstr(M, \"#{kw[:name]}\")" }.join(', ')
      out << "  mrb_sym bc2cpp_kw_table[#{ordered_kws.size}] = { #{table_entries} };\n"
      out << "  mrb_value bc2cpp_kw_values[#{ordered_kws.size}];\n"
      out << "  mrb_kwargs bc2cpp_kwargs = { #{ordered_kws.size}, #{required_kws.size}, " \
             "bc2cpp_kw_table, bc2cpp_kw_values, NULL };\n"
      fmt = arg_native_types.map { |t| t == :fixnum ? 'i' : (t == :symbol ? 'n' : 'o') }.join + ':'
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
      call_args = arg_names + kw_table.flat_map do |kw|
        kw[:required] ? [kwarg_param_name(kw[:name])] : [kwarg_param_name(kw[:name]), kw_given_param_name(kw[:name])]
      end
      out << "  return #{impl_name}(M, self, #{call_args.join(', ')});\n"
    elsif has_rest
      # REST_ARG_SUPPORT: mrb_get_args' own `*` format specifier
      # (mruby.h's own format table) hands back a raw `const mrb_value*` +
      # `mrb_int` pair pointing straight into the VM's own live call-frame
      # stack -- never safe to keep past this function's own return, so it
      # gets copied into a real, independently-GC-owned Array right away
      # via mrb_ary_new_from_values (the same real API mruby's own core
      # uses for exactly this purpose), matching what the rest register
      # already holds in the ordinary interpreted path (confirmed directly
      # against real disassembly -- a real boxed Array value, populated by
      # the VM's own real ENTER semantics, never a raw pointer pair).
      # `_impl`'s own signature and this call's own trailing argument both
      # fall out of `total_args`/`arg_names` unchanged (see
      # rest_only_arity?'s own comment) -- only extracting the real value
      # here is genuinely `*rest`-specific.
      mand_names = arg_names.first(mand)
      rest_name = arg_names.last
      mand_names.each_with_index { |a, i| out << "  #{native_c_type(arg_native_types[i])} #{a};\n" }
      out << "  const mrb_value* bc2cpp_rest_ptr;\n"
      out << "  mrb_int bc2cpp_rest_len;\n"
      fmt = arg_native_types.first(mand).map { |t| t == :fixnum ? 'i' : (t == :symbol ? 'n' : 'o') }.join + '*'
      ptrs = (mand_names.map { |a| "&#{a}" } + ['&bc2cpp_rest_ptr', '&bc2cpp_rest_len']).join(', ')
      out << "  mrb_get_args(M, \"#{fmt}\", #{ptrs});\n"
      out << "  mrb_value #{rest_name} = mrb_ary_new_from_values(M, bc2cpp_rest_len, bc2cpp_rest_ptr);\n"
      out << "  return #{impl_name}(M, self, #{(mand_names + [rest_name]).join(', ')});\n"
    else
      # Each local's own declared type has to match what mrb_get_args'
      # own format character below writes into it -- 'o' (no coercion at
      # all, today's own established default) wants a plain mrb_value
      # out-param; 'i'/'n' (NATIVE_ARG_TARGETS' own fixnum/symbol
      # positions) want a real mrb_int*/mrb_sym* instead, mirroring
      # 3rd/mruby/src/class.c's own mrb_get_args format table exactly (its
      # own `case 'i':`/`case 'n':` read a `mrb_int*`/`mrb_sym*` via
      # GET_ARG, never an mrb_value* -- confirmed by reading that switch
      # directly, not assumed from the format letter alone). One
      # declaration per argument (rather than the previous single combined
      # `mrb_value a, b, c;` line) since a mixed-type argument list can no
      # longer share one declaration statement.
      # OPTIONAL_ARG_SUPPORT: an optional position (i >= mand) gets a real
      # `= mrb_nil_value()` initializer -- mrb_get_args' own `|` marker
      # (below) simply leaves an omitted optional's own out-param
      # untouched, so without this it would read as uninitialized C++
      # garbage rather than the harmless placeholder _impl expects (see
      # its own comment: never read before the jump table's own default-
      # value code overwrites it, but still real, defined behavior either
      # way -- no UB from an unconditional read of an mrb_value that was
      # never written).
      arg_names.each_with_index do |a, i|
        default = i >= mand ? ' = mrb_nil_value()' : ''
        out << "  #{native_c_type(arg_native_types[i])} #{a}#{default};\n"
      end
      # 'i' is mrb_as_int under the hood (mrb_ensure_int_type + a bigint
      # unwrap), 'n' is mrb_obj_to_sym -- the exact same two coercions
      # compile_send's own call-site unboxing (below) uses when it moves
      # this identical coercion to a devirtualized direct-call site
      # instead of through this entry wrapper; see that call site's own
      # comment for why the two have to stay in lockstep. OPTIONAL_ARG_
      # SUPPORT's own `|` marker (mrb_get_args' own real optional-argument
      # syntax, mruby.h's own format-specifier table) lands exactly at the
      # mandatory/optional boundary -- everything from there on is simply
      # left untouched in the real call if this exact call didn't supply
      # it, matching the pre-initialized nil above.
      fmt = arg_native_types.each_with_index.map do |t, i|
        ch = t == :fixnum ? 'i' : (t == :symbol ? 'n' : 'o')
        i == mand && opt.positive? ? "|#{ch}" : ch
      end.join
      ptrs = arg_names.map { |a| "&#{a}" }.join(', ')
      out << "  mrb_get_args(M, \"#{fmt}\", #{ptrs});\n"
      if opt.positive?
        # OPTIONAL_ARG_SUPPORT: mrb_get_argc is the real, public mruby API
        # for "how many positional arguments did THIS call actually pass"
        # (3rd/mruby/include/mruby.h) -- independent of mrb_get_args, and
        # the exact same quantity the real VM's own OP_ENTER computes to
        # decide which jump-table entry to land on, clamped to this
        # method's own real [0, opt] range the same way (a call passing
        # MORE than mandatory+optional positional args is already a real
        # ArgumentError mrb_get_args itself would have raised above, so
        # this clamp is a formality for the upper bound, never reachable
        # with fewer given than mandatory for the same reason on the low
        # end -- kept anyway since a clamp is free and this is exactly the
        # value that walks straight into emit_optional_dispatch's switch).
        out << "  mrb_int bc2cpp_given_opt = mrb_get_argc(M) - #{mand};\n"
        out << "  if (bc2cpp_given_opt < 0) bc2cpp_given_opt = 0;\n"
        out << "  if (bc2cpp_given_opt > #{opt}) bc2cpp_given_opt = #{opt};\n"
        out << "  return #{impl_name}(M, self, #{arg_names.join(', ')}, bc2cpp_given_opt);\n"
      else
        out << "  return #{impl_name}(M, self, #{arg_names.join(', ')});\n"
      end
    end
    out << "}\n\n"
    # arg_c_types: this method's own real per-position C++ parameter type
    # list (decl_line's own forward-declaration/cross-TU-header codegen
    # reads it, so a devirtualized caller -- same gem or, via
    # OTHER_DECLS_HEADER, a different one -- declares this `_impl` with
    # exactly the signature it was actually emitted with).
    arg_c_types = arg_names.each_index.map { |i| native_c_type(arg_native_types[i]) }
    # OPTIONAL_ARG_SUPPORT: the extra `bc2cpp_given_opt` parameter (see
    # above) is real, load-bearing part of this _impl's own signature --
    # decl_line's own forward declaration has to include it too, or a
    # devirtualized cross-TU caller (OTHER_DECLS_HEADER) would declare an
    # arity-mismatched prototype for a real, externally-linked symbol.
    arg_c_types << 'mrb_int' if opt.positive?
    # KEYWORD_ARG_SUPPORT: same reasoning as OPTIONAL_ARG_SUPPORT's own
    # `bc2cpp_given_opt` line just above -- every real parameter arg_params
    # added for a keyword (one `mrb_value` each, plus one `mrb_int` for an
    # optional one) has to appear here too, in the exact same order, or a
    # cross-TU devirtualized caller's own forward declaration would
    # mismatch this real, externally-linked symbol's actual signature.
    kw_table&.each do |kw|
      arg_c_types << 'mrb_value'
      arg_c_types << 'mrb_int' unless kw[:required]
    end
    { label: label, owner: d.owner, name: d.name, entry: entry_name, impl: impl_name,
      arity: arg_names.size, arg_c_types: arg_c_types,
      code: out, visibility: d.visibility }
  end

  # OPTIONAL_ARG_SUPPORT: the native `switch` that replaces the real ENTER
  # jump table (optional_arg_table's own comment has the full design) --
  # `targets` is that function's own third return value, the jump table's
  # own real target addresses in order. `bc2cpp_given_opt` is the extra
  # _impl parameter compile_method adds whenever this is reached.
  def emit_optional_dispatch(targets)
    out = String.new
    out << "  switch (bc2cpp_given_opt) {\n"
    targets.each_with_index do |addr, i|
      out << (i == targets.size - 1 ? "    default: goto L#{addr};\n" : "    case #{i}: goto L#{addr};\n")
    end
    out << "  }\n"
    out
  end

  # Every bytecode address any JMP/JMPNOT/JMPIF in this irep can land on --
  # each one needs a real C label emitted in compile_method, or `goto` has
  # nowhere valid to target.
  def jump_targets(irep)
    targets = Set.new
    irep.instructions.each do |insn|
      case insn.op
      when 'JMP'
        targets << insn.args.strip[/\d+/].to_i
      when 'JMPNOT', 'JMPIF', 'JMPNIL'
        targets << jmp_target_after_reg(insn.args)
      end
    end
    targets
  end

  # RESCUE_SUPPORT: a `begin BODY rescue SomeClass => e; HANDLER; end`
  # construct (or, identically, a whole method body with a trailing
  # `rescue` clause, or an inline `EXPR rescue FALLBACK` modifier -- real
  # Ruby desugars all three to the exact same EXCEPT/RESCUE/RAISEIF shape,
  # see this method's own top comment) is the ONLY real shape this file
  # ever attempts to translate -- no `retry`, no `ensure`, no multi-class
  # `rescue A, B`, no rescue clause that doesn't bind or use its own
  # exception object the way this method assumes, no *nested* rescue (one
  # rescue's own protected body containing -- or contained by -- another,
  # e.g. an explicit `begin...rescue...end` sitting inside a method that
  # also has its own trailing, whole-method `rescue` -- confirmed still
  # unsupported, not just assumed, against RPG2k::Scene::Map
  # #build_resolver/#perform_teleport, both of which stay `#error
  # unhandled opcode EXCEPT` for exactly this reason as of this writing;
  # see the real nesting-rejection check inside recognize_rescue_regions
  # below), and no rescue naming a *namespaced* class (`rescue
  # RGSS::Timeout`, RPG2k#start -- compiles to `GETCONST base; GETMCNST
  # (base)::Name`, two instructions, not the one bare `GETCONST Rcls
  # <Name>` this recognizer's own 4-instruction scan requires; a real,
  # separate, smaller gap from the nesting one above, also still open).
  # Real Ruby's exception machinery has none of those restrictions; this
  # prototype's own closed-world survey of every real rescue clause
  # actually shipped (mruby-rpg2k/mrblib) found the overwhelming majority
  # already fit this exact narrow shape (a single, bare-named class, no
  # retry, no nesting, at most one real `ensure` anywhere in the whole
  # tree -- itself excluded here, never silently mistranslated) -- the
  # small remainder that doesn't (the nested and namespaced-class cases
  # named above) stays a loud, honest miss, exactly like any other
  # unmodeled shape in this file (falls through to compile_insn's own
  # default `#error unhandled opcode EXCEPT` -- RESCUE/RAISEIF below are
  # unconditionally safe wherever they appear, but EXCEPT genuinely needs
  # this recognizer's own C++-level `mrb_protect_error` wrapping to mean
  # anything at all, see this file's own top comment).
  #
  # The real, always-generated shape a real `rescue` clause's own catch
  # handler entry (CatchHandler -- begin/end/target, mrbc's own "catch
  # type: rescue" disassembly header) sits in front of, confirmed directly
  # against real disassembly (mruby-rpg2k/mrblib/game.rb's own
  # `Game::Actors#[]`) rather than assumed from mruby's own vm.c source
  # alone:
  #
  #   [begin, end)   -- the protected computation itself (BODY above).
  #   end            -- exactly one instruction, `JMP S` -- BODY's own
  #                     normal (non-raising) exit, landing on address S,
  #                     which every rescue-match path also independently
  #                     converges on (whole-method-tail rescue: S is a
  #                     final `RETURN`/`RETURN_BLK`; a rescue embedded
  #                     mid-method, or an inline `rescue` modifier with
  #                     more code after it, or several independent rescue
  #                     clauses in one method -- e.g. Scene::Map
  #                     #parallax_config's own eight -- S is just the
  #                     next ordinary instruction, exactly like any other
  #                     JMP target this file already goto-threads).
  #   target         -- exactly `EXCEPT Rexc` (captures the raised
  #                     exception -- mrb->exc -- into Rexc, clearing it).
  #   target+1..+4   -- exactly `GETCONST Rcls <Name>`; `RESCUE Rexc
  #                     Rcls` (Rcls := Rexc.isa?(Rcls)); `JMPIF Rcls
  #                     match`; `JMP raise` -- mirrors this method's own
  #                     RESCUE/RAISEIF compile_insn cases below, which are
  #                     just that same real vm.c logic (OP_RESCUE/
  #                     OP_RAISEIF) mechanically transcribed, unconditional
  #                     on this recognizer ever running at all.
  #   raise          -- exactly `RAISEIF Rexc` (re-raises unless nil).
  #
  # `Rexc` (the register EXCEPT above writes the exception object into) is
  # also, always, the register the *whole rescue construct's own result
  # value* ends up in on every path -- not by convention, by construction:
  # 3rd/mruby/mrbgems/mruby-compiler/core/codegen.c's own codegen_rescue
  # compiles the protected BODY at `cursp()` then takes `exc = cursp()`
  # (the exact same register) for OP_EXCEPT, and every matched rescue
  # clause's own handler body is compiled at that same still-unmoved
  # `cursp()` too (its own trailing `push()`/no-op after the shared
  # `pop()`s) -- so whatever address S turns out to be, the value flowing
  # into it (in a plain `MOVE`, a `SETIV`, a Hash/Array literal slot,
  # whatever real instruction sits at S) is always `r<exc_reg>`, read
  # directly rather than re-derived from S's own operands. This is what
  # lets this recognizer handle a `RETURN`/`RETURN_BLK` S (the original,
  # narrower shape this recognizer used to require) and any other S
  # identically -- `emit_rescue_glue` below still special-cases the
  # `RETURN`/`RETURN_BLK` case as an early-return shortcut (a whole-
  # method-tail rescue really can just return immediately, faster than a
  # goto-then-return round trip through a label this file would otherwise
  # have to declare and jump to), but that is an optimization, not a
  # soundness requirement -- the general goto-to-S path below is
  # unconditionally correct for both shapes.
  #
  # Every address in this chain is cross-checked, never assumed -- a real
  # shape this narrow either matches completely (safe to translate) or
  # doesn't match at all (falls through to the ordinary, honest #error
  # path, same as any other unmodeled construct in this whole file).
  #
  # Returns one Hash per independently-recognized, non-nested handler:
  # {begin_addr:, end_addr:, except_addr:, exc_reg:, cls_name:, match_addr:,
  #  raise_addr:, shared_target:, connector_reg:, tail_return:}.
  # compile_method is the only real caller.
  def recognize_rescue_regions(irep)
    return [] if irep.catch_handlers.nil? || irep.catch_handlers.empty?
    return [] unless irep.catch_handlers.all? { |ch| ch.type == :rescue }

    by_addr = irep.instructions.each_with_object({}) { |insn, h| h[insn.addr] = insn }
    by_index = irep.instructions.each_with_index.to_h

    regions = []
    irep.catch_handlers.each do |ch|
      b, e, t = ch.begin_addr, ch.end_addr, ch.target
      # No nesting, checked symmetrically: reject ch if it contains
      # another handler's range OR sits inside another's -- this file
      # only ever models flat, sequential rescue clauses, never one
      # rescue's own BODY containing (or being contained by) another. A
      # one-directional version of this check here previously only ever
      # rejected the *outer* handler of a real nested pair, never the
      # *inner* one on its own turn through this each -- caught rewriting
      # this comment, not by any real failure yet (0 nested rescue
      # clauses exist in this program today, and even a nested case that
      # slipped past this check couldn't have compiled to anything
      # *wrong*: the inner construct's own EXCEPT would still hit this
      # file's own ordinary `#error unhandled opcode EXCEPT` fallback
      # inside the outer's own extracted try body, which
      # compiles_clean?/SKIP_UNSUPPORTED already correctly treats as "this
      # whole method stays interpreted" -- but fixed properly regardless,
      # the same standard this whole recognizer holds every other check
      # to).
      next if irep.catch_handlers.any? do |o|
        o != ch && ((o.begin_addr >= b && o.end_addr <= e) || (b >= o.begin_addr && e <= o.end_addr))
      end

      except_i = by_addr[t]
      next unless except_i && except_i.op == 'EXCEPT'
      exc_reg = except_i.args[/^R(\d+)/, 1]
      next unless exc_reg

      idx = by_index[except_i]
      seq = irep.instructions[idx + 1, 4]
      next unless seq && seq.size == 4
      getconst_i, rescue_i, jmpif_i, jmp_i = seq
      next unless getconst_i.op == 'GETCONST'
      cls_reg = getconst_i.args[/^R(\d+)/, 1]
      cls_name = getconst_i.args[/^R\d+\s+(\S+)/, 1]
      next unless cls_reg && cls_name
      next unless rescue_i.op == 'RESCUE' && rescue_i.args.strip =~ /^R#{exc_reg}\s+R#{cls_reg}$/
      next unless jmpif_i.op == 'JMPIF' && jmpif_i.args[/^R(\d+)/, 1] == cls_reg
      match_addr = jmp_target_after_reg(jmpif_i.args)
      next unless jmp_i.op == 'JMP'
      raise_addr = jmp_i.args.strip[/\d+/].to_i

      raise_i = by_addr[raise_addr]
      next unless raise_i && raise_i.op == 'RAISEIF' && raise_i.args[/^R(\d+)/, 1] == exc_reg

      exit_i = by_addr[e]
      next unless exit_i && exit_i.op == 'JMP'
      shared_target = exit_i.args.strip[/\d+/].to_i
      # shared_target can never legitimately be this same region's own
      # except_addr in real mrbc-generated code (codegen_rescue emits
      # OP_EXCEPT immediately, long before `dispatch(s, noexc)` -- the
      # success JMP's own patch-up -- ever runs, so the two addresses
      # are never unified) -- rejected explicitly anyway rather than
      # trusted, since a coincidence here would target compile_method's
      # own suppressed, label-less except_addr with the goto below.
      next if shared_target == t
      shared_i = by_addr[shared_target]
      next unless shared_i
      # connector_reg is always exc_reg -- see this method's own top
      # comment on codegen_rescue's shared `cursp()` -- not re-derived
      # from shared_i's own operands. tail_return (RETURN/RETURN_BLK)
      # stays a real, checked distinction: emit_rescue_glue takes the
      # early-`return` shortcut only then, cross-verifying connector_reg
      # against that instruction's own operand register as it always has,
      # rather than trusting the codegen_rescue fact blind on the one
      # shape real disassembly originally confirmed it against.
      tail_return = %w[RETURN RETURN_BLK].include?(shared_i.op)
      connector_reg = exc_reg
      if tail_return
        tail_reg = shared_i.args.strip.empty? ? '0' : shared_i.args[/^R(\d+)/, 1]
        next unless tail_reg == connector_reg
      end

      # Full containment, checked by real jump SOURCE address, not just
      # by which addresses appear as *some* target somewhere (a blunter
      # address-list check here previously passed a real jump landing
      # exactly on `b` itself -- e.g. a `retry`'s own JMP back to the
      # region's start, emitted from inside the rescue handler body,
      # which sits *after* `e` -- straight through, since `b` itself was
      # being subtracted out of the candidate list before ever comparing
      # it against anything; caught rewriting this comment, not by any
      # real failure yet, since retry is confirmed absent from every real
      # rescue clause this prototype has ever seen, see this method's own
      # top comment -- checked properly here regardless, never assumed).
      # Two separate directions, both required:
      #   1. No jump whose own SOURCE lies outside [b, e] may ever target
      #      an address inside [b, e] -- the region's only two legitimate
      #      entry points (falling into `b` from the preceding ENTER or
      #      an ordinary preceding branch, and this handler's own `t`/
      #      `match_addr`, both outside [b, e] by construction) are real
      #      control transfers this recognizer already models
      #      explicitly, never a bare goto into the middle -- EXCEPT
      #      (see the real, checked carve-out right below) a jump
      #      targeting exactly `b` itself from strictly BEFORE it, which
      #      is that same first legitimate entry point reached via an
      #      explicit branch instead of plain fallthrough.
      #   2. No jump whose own SOURCE lies inside [b, e) (e itself is the
      #      region's own designated exit instruction, allowed to target
      #      shared_target, already checked above) may ever target an
      #      address outside [b, e] -- the only sanctioned way out of the
      #      protected computation is that one designated exit, or a real
      #      raise (mrb_protect_error's own job, not a jump at all).
      #
      # The carve-out in (1): an ordinary branch immediately before a
      # `begin`/trailing-rescue -- an `if`/`unless` guard (confirmed
      # directly, RPG2k::Scene::DebugMenu#open_map_viewer's own `if
      # @state.map && ...; return; end` right before its `map = begin
      # ... rescue ... end`), or OPTIONAL_ARG_SUPPORT's own default-
      # value dispatch (RPG2k#save_exists?'s own `slot = 1`) -- compiles
      # to a real JMP/JMPNOT/JMPIF/JMPNIL landing exactly on `b`, not a
      # plain fallthrough, so the blunter "no external jump into [b, e]
      # at all" rule above rejected every one of these as if they were
      # unsafe, even though landing exactly on `b` from outside is
      # exactly the same legitimate entry the ENTER-fallthrough case
      # already is. Never true for `retry`: a real retry's own JMP would
      # have to originate from *inside the handler body*, strictly after
      # `e` (the handler runs after the whole [b, e] region, by
      # construction), so gating this carve-out on `src.addr < b` -- is
      # never true for a source inside the handler -- keeps retry exactly
      # as unsupported (a genuine escape, caught by the plain `else`
      # branch below) as this method's own top comment already documents.
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
                   connector_reg: connector_reg, tail_return: tail_return }
    end
    regions
  end

  # RESCUE_SUPPORT: the extracted "try body" for one recognized region --
  # a real, standalone, top-level static function (mrb_protect_error's own
  # function-pointer body parameter can't be a closure, see
  # emit_const_lookup_helper's own comment on the identical constraint for
  # GETCONST's owner-scope lookup) containing exactly the protected
  # computation ([begin_addr, end_addr], the region's own trailing exit
  # JMP included -- see recognize_rescue_regions' own top comment for why
  # that boundary is inclusive here). Its only live-in state at
  # begin_addr is `self` plus this method's own mandatory arguments --
  # true because begin_addr is always the very first real instruction
  # after ENTER (recognize_rescue_regions never matches anything else,
  # per this method's own real 4-part shape check) -- so a small by-value
  # Ctx struct carrying exactly those, the same real parameter list
  # compile_method's own `_impl` function already takes, is enough;
  # mrb_protect_error's `void*` userdata is this struct's address.
  #
  # Every *other* register this body uses is a plain temporary, live only
  # within [begin_addr, end_addr] -- declared and nil-initialized here
  # exactly like compile_method's own `_impl` preamble does, never
  # threaded through the Ctx. The one instruction at end_addr (the
  # region's own real exit JMP, jumping to shared_target -- always a bare
  # `RETURN`/`RETURN_BLK`, per recognize_rescue_regions' own check) is the
  # one deliberate rewrite: translated to a real C++ `return`, carrying
  # the exact value that JMP would have handed to that outer RETURN, since
  # this function's own return value *is* mrb_protect_error's return
  # value on the non-raising path (emit_rescue_glue's own early-return
  # line is what actually turns that into the real method's own return).
  # Every other instruction compiles completely normally (compile_insn,
  # unmodified) -- including any internal jump within the region, which
  # keeps working exactly like compile_method's own goto-threaded loop
  # since every registered label this function needs is declared right
  # here, the same L<addr> convention used everywhere else in this file.
  def emit_rescue_try_body(try_name, region, irep, d, arg_names, arg_native_types)
    ctx_struct = "#{try_name}_Ctx"
    ctx_fields = ['mrb_value self'] + arg_names.each_with_index.map { |a, i| "#{native_c_type(arg_native_types[i])} #{a}" }
    out = String.new
    out << "struct #{ctx_struct} { #{ctx_fields.join('; ')}; };\n"
    out << "static mrb_value #{try_name}(mrb_state* M, void* ud) {\n"
    out << "  #{ctx_struct}* ctx = (#{ctx_struct}*)ud;\n"
    (0...irep.nregs).each do |i|
      if i.zero?
        # GETIV/SETIV's own codegen (compile_insn) hardcodes the bare C++
        # identifier `self`, not `r0` -- it relies on `_impl`'s own real
        # `self` parameter name, which this standalone try-body function
        # doesn't have (its live-in state arrives packed in `ctx` instead,
        # mrb_protect_error's body signature has no room for a second
        # named parameter). A real, caught-immediately g++ error
        # ("'self' was not declared in this scope") the very first time
        # this ever ran on a real ivar-reading rescue clause -- fixed by
        # giving this function its own `self` alias too, exactly the
        # value `_impl`'s own real `self` had at begin_addr.
        out << "  mrb_value self = ctx->self;\n"
        out << "  mrb_value r0 = self;\n"
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
    body_targets = jump_targets(irep).select { |t| t >= region[:begin_addr] && t <= region[:end_addr] }
    irep.instructions.each_with_index do |insn, idx|
      next unless insn.addr >= region[:begin_addr] && insn.addr <= region[:end_addr]

      out << "  L#{insn.addr}:;\n" if body_targets.include?(insn.addr)
      out << if insn.addr == region[:end_addr]
                "  return r#{region[:connector_reg]};\n"
              else
                compile_insn(insn, irep, d, idx)
              end
    end
    out << "  return mrb_nil_value(); // unreachable\n"
    out << "}\n\n"
    out
  end

  # RESCUE_SUPPORT: the glue emitted at a recognized region's own
  # begin_addr, replacing that whole [begin_addr, end_addr] range (see
  # compile_method's own suppressed-address loop) -- runs the extracted
  # try body under mrb_protect_error (see this file's own top comment for
  # why that's the right, already-proven primitive: it either returns the
  # try body's own real result with err==FALSE, or the raised exception
  # object itself with err==TRUE, exception state already cleared and the
  # call-info stack already unwound back to here -- 3rd/mruby/src/vm.c's
  # own mrb_protect_error, read directly, not assumed). On failure,
  # assigns the exception into r<exc_reg> and falls straight through --
  # the very next instruction compile_method's own loop emits is
  # GETCONST/RESCUE/JMPIF (EXCEPT's own address is separately suppressed,
  # its only real effect folded into this assignment), unmodified.
  #
  # On success: `region[:tail_return]` (a real, checked distinction --
  # see recognize_rescue_regions' own top comment) picks between two
  # provably-equivalent translations of the exact same fact, "the try
  # body didn't raise" --
  #   true  -- a whole-method-tail rescue, where that fact already IS
  #            "this is the method's own final return value" (both the
  #            success path and every rescue-match path converge on the
  #            same final RETURN/RETURN_BLK); `return` immediately,
  #            skipping a label hop this shape never needs.
  #   false -- any other rescue (mid-method, an inline `EXPR rescue
  #            FALLBACK` modifier with more code after it, one of
  #            several independent rescue clauses in the same method,
  #            ...): assign the try body's own result into
  #            r<connector_reg> (== r<exc_reg>, the same register the
  #            exception path already assigns on the very next line --
  #            connector_reg's own comment is the citation) and fall
  #            through to shared_target the same way every ordinary JMP
  #            elsewhere in this file already does, via the label
  #            compile_method's own pre-scan already declares for it
  #            (shared_target is a real jump target -- exit_i's own --
  #            so it's never a label this recognizer has to invent).
  def emit_rescue_glue(try_name, region, arg_names, arg_native_types)
    ctx_struct = "#{try_name}_Ctx"
    ctx_args = (['self'] + arg_names).join(', ')
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

  # BLOCK_SUPPORT: `receiver.times { |i| BODY }` (or `do...end`), the
  # first (and, for this round, only) real Ruby-block shape this file
  # compiles -- by *inlining* the block's own body directly into the
  # enclosing compiled function, as one native C++ `for` loop, rather
  # than building any real Proc/closure object at all. `#each`/`#map`/
  # every other real Enumerable-family method stays unconditionally
  # `#error unhandled opcode BLOCK` (see this method's own top comment
  # for why `#times` specifically is safe to start with and those
  # aren't, yet).
  #
  # Why inlining, not a general block-calling mechanism: mruby exposes
  # real public APIs that look tempting for the general case
  # (`mrb_proc_new`+`mrb_funcall_with_block`, wrapping the block's own
  # already-compiled child irep in a real Proc and letting the ordinary
  # interpreter run it) -- but a plain `mrb_proc_new` builds an *unbound*
  # Proc with no captured environment, and real blocks routinely close
  # over an outer local variable (confirmed directly against real source,
  # not assumed -- e.g. `@instants.each { |a, b| return b if pos >= a &&
  # pos < b }`, mruby-rpg2k/mrblib/game.rb, captures the enclosing
  # method's own `pos`), which a bc2cpp-compiled function's plain C++
  # stack locals can't feed into a real REnv without reimplementing a
  # real chunk of mruby's own closure machinery. Inlining sidesteps this
  # entirely: the block's own body becomes literal C++ sharing the exact
  # same `r0..rN` register variables the enclosing method's own body
  # already uses, so an outer local reference (`GETUPVAR`/`SETUPVAR`,
  # level 0 only -- see compile_block_body_insn's own comment) is just
  # that same shared variable, and a `return` inside the block (`OP_
  # RETURN_BLK`'s own real non-local-return path, vm.c) collapses to a
  # perfectly ordinary C++ `return` from the very same function it would
  # otherwise have unwound out of -- both completely free, no closure
  # object ever needed.
  #
  # Why `#times` specifically: `#times` has ZERO real bytecode-defined
  # overrides anywhere in this whole program's real closed-world registry
  # (confirmed directly -- it doesn't even appear as a registry entry at
  # all, MONO or POLY, unlike e.g. `#each`, which real `Game::Actors`/
  # `Game::Party`/`LCF::Array2D` all define their own competing versions
  # of). Since no bytecode `#times` exists anywhere to override the real
  # native `Integer#times`, calling `.times` on anything that ISN'T
  # really an Integer is *already* a guaranteed real `NoMethodError` in
  # the interpreted program today -- so the runtime `mrb_integer_p` guard
  # this emits, raising a real error on mismatch instead of silently
  # miscompiling, is provably equivalent to real dispatch for every
  # possible receiver, not just "should never happen." This is the same
  # trust model this file's own embedded-ivar SETIV codegen already uses
  # (a real runtime `mrb_integer_p` guard even for a statically-proven
  # type, TypeError on failure, never silent corruption) -- not a new
  # pattern invented for this.
  #
  # Recognized shape (cross-checked against real disassembly, not
  # assumed): `SENDB Ra :times n=0`, whose own destination register `Ra`
  # already holds the receiver, immediately preceded by `BLOCK R(a+1)
  # I[k]` (mrbc's own codegen always places a call's block argument at
  # the very next register after the destination, for n=0 explicit
  # args), where child irep `I[k]` takes exactly one mandatory argument
  # (the yielded index) and nothing else. `mandatory_arity`/
  # `pure_mandatory_arity?` are the same checks compile_method's own top-
  # level gate already uses, reused here for the child irep instead.
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

  # EACH_BLOCK_SUPPORT: recognize one inlinable `ary.each { |x| ... }`
  # region. Shape (confirmed against real `mrbc -v` disassembly, never
  # assumed): `SENDB`/`SSENDB Ra :each n=0` immediately preceded by
  # `BLOCK R(a+1) I[k]`, where child irep `I[k]` takes exactly one
  # mandatory argument and nothing else -- the identical adjacency the
  # times recognizer above already requires, pointed at a new method
  # name. Unlike `#times` (zero bytecode overrides program-wide, so a
  # bare `mrb_integer_p` guard is unconditionally sound), `#each` has
  # real competing definitions (`Game::Actors#each`, `Game::Party#each`,
  # `LCF::Array2D#each`), so every region ALSO carries the static
  # receiver gate: the SENDB destination register must trace (via
  # trace_new_target, the same backward proof compile_send's own TYPED
  # path trusts -- GETIV through ClassLayout-known ivars, `X.new`
  # chains, ARRAY literals) to exactly `"Array"`. An SSENDB site has an
  # implicit-self receiver, untraceable by register -- admitted only
  # when the enclosing method's own owner IS `Array` itself (nearly
  # vacuous in game code, but the only sound static claim available;
  # a self-Enumerable game class calling bare `each` stays interpreted).
  # Anything unproven yields no region at all -- honest `#error` via
  # the ordinary per-instruction loop, exactly like any other
  # unrecognized shape in this file.
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
        # CHAINED_ACCESSOR_SUPPORT: threading the full @class_layout/
        # @registry through here too (both already sitting on `self`, no
        # new state) is a strictly additive extension of the same static
        # Array gate this call site already relies on -- it only ever
        # turns a prior nil into 'Array' when the receiver chain itself
        # proves Array-typed a new way, never changes an existing 'Array'
        # result.
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

  # HASH_EACH_SUPPORT: recognize one inlinable `hash.each { |k, v| ... }`
  # region. Same `BLOCK`+`SENDB`/`SSENDB` adjacency as
  # recognize_each_regions above (this literally reuses the SAME method
  # name, `:each` -- the two recognizers never collide in practice
  # because their own receiver-class gates are mutually exclusive, never
  # both 'Array' and 'Hash' for the same traced expression), but gated on
  # a receiver proven 'Hash' and a 2-mandatory-arg block. Real `Hash#each`
  # (3rd/mruby/mrblib/hash.rb) always calls its block with exactly 2
  # values -- key then value -- via `block.call([keys[i], vals[i]])`'s own
  # real Proc auto-splat; this emitter (below) never reproduces that
  # Proc#call/splat machinery literally, it just assigns the two
  # synthesized register values directly into the block's own R1/R2, the
  # identical mechanism recognize_accum_regions' own reduce/inject fold
  # and recognize_collect_regions' own each_with_index already use for a
  # real 2-value yield.
  #
  # Unlike `#each` on Array (whose own receiver gate exists specifically
  # because real competing bytecode definitions do exist --
  # `Game::Actors#each`/`Game::Party#each`/`LCF::Array2D#each`), NO real
  # bytecode override of `Hash#each` exists anywhere in this closed world
  # (confirmed directly: no `class Hash` reopen, no `class X < Hash`, in
  # any of mruby-rpg2k/mruby-lcf/mruby-rgss's own mrblib) -- once a
  # receiver is provably `Hash`, `#each` is completely unambiguous. The
  # `SSENDB`/owner-is-`Hash` admission is kept anyway, for the same
  # "nearly vacuous but the only sound static claim available" reason
  # recognize_each_regions' own comment gives, though no real call site
  # in this program currently takes that shape.
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
                   ssendb: insn.op == 'SSENDB' }
    end
    regions
  end

  # EACH_INDEX_SUPPORT: recognize one inlinable `ary.each_index { |i|
  # ... }` region. Real `Array#each_index` (3rd/mruby/mrblib/array.rb):
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
  # -- LIVE `length` re-check every pass (`length` is a real method call,
  # re-evaluated each iteration, exactly like emit_each_inline's own
  # live `RARRAY_LEN` re-check -- see that method's own comment), the
  # block is yielded the INDEX only (a fixnum, never an element), and
  # the return value is the receiver. Same `BLOCK R(a+1)` +
  # `SENDB`/`SSENDB Ra :each_index n=0` adjacency as recognize_each_
  # regions above (confirmed against real `mrbc -v -S` on a synthetic
  # `a.each_index { |i| p i }`: `BLOCK R4 I[0]` immediately followed by
  # `SENDB R3 :each_index n=0`, identical shape). Real call sites: 13
  # across mruby-rpg2k/mrblib (Game::Actor#defensive_attribute_ids/
  # #weapon_attributes/game.rb's own several `set.each_index`/
  # `sset.each_index` id-bitset scans, Scene::Battle's shake-timer scan,
  # Game::LsdIO's several save/load id scans, Game::Battle's flee scan)
  # plus 2 in mruby-rgss/mrblib/lib.rb (RGSS::Input's own
  # @triggered/@pressed key scans). Same static Array receiver gate
  # (including the SSENDB/owner rule): no real bytecode override of
  # `#each_index` exists anywhere in this closed world (confirmed: the
  # only real `class Array` reopens in mruby-rpg2k/mruby-lcf/
  # mruby-rgss's own mrblib are mruby-rgss/mrblib/array_include.rb's
  # `#include?` and array_sort.rb's `#sort`/`#sort!` -- neither touches
  # `each_index` -- and no `class X < Array` subclass exists at all;
  # `mruby-lcf/mrblib/lcf.rb`'s `Array1D`/`Array2D` are standalone
  # classes, not Array subclasses, confirmed by their own class headers
  # having no `< Array`).
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

  # EACH_KEY_SUPPORT: recognize one inlinable `hash.each_key { |k| ...
  # }` region. Real `Hash#each_key` (3rd/mruby/mrblib/hash.rb):
  #
  #   def each_key(&block)
  #     return to_enum(:each_key) unless block
  #     self.keys.each {|k| block.call(k)}
  #     self
  #   end
  #
  # -- SNAPSHOT (`self.keys` returns a FRESH Array -- mrblib/hash.rb's
  # own `#keys` -> real `mrb_hash_keys`, MRB_API,
  # 3rd/mruby/include/mruby/hash.h -- so mutating the receiver mid-
  # iteration cannot affect an already-taken snapshot, the identical
  # soundness argument emit_hash_each_inline's own comment gives for its
  # keys/values snapshot), ONE value (the key) yielded per iteration,
  # receiver returned. Same `BLOCK R(a+1)` + `SENDB`/`SSENDB Ra
  # :each_key n=0` adjacency as recognize_hash_each_regions above
  # (confirmed against real `mrbc -v -S` on a synthetic
  # `h.each_key { |k| p k }`: `BLOCK R4 I[0]` immediately followed by
  # `SENDB R3 :each_key n=0`, identical shape). Real call site:
  # `Scene_Map`'s own LRU-eviction scan (mruby-rpg2k/mrblib/scene/
  # map.rb, `@entries.each_key { |k| oldest_key = k; break }`). Same
  # static Hash receiver gate (including the SSENDB/owner rule) -- no
  # real bytecode override of `Hash#each_key` exists anywhere in this
  # closed world (confirmed: no `class Hash` reopen, no `class X <
  # Hash`, in any of mruby-rpg2k/mruby-lcf/mruby-rgss's own mrblib).
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

  # ELEMENT_CLASS_SUPPORT: the element class of one recognized region's
  # receiver, or nil. Shared by every recognizer below so the gate is
  # written once. An `SSENDB` site always answers nil: its receiver is the
  # implicit self, which has no register to backward-scan, and the only
  # self-receiver these recognizers admit at all is an enclosing owner
  # that literally IS `Array` (see recognize_each_regions' own comment) --
  # a case with no element fact available and none worth inventing.
  def region_element_class(insn, irep, idx, dest_reg, ivar_classes, mand, arg_classes, owner_name)
    return nil if insn.op == 'SSENDB'

    proven_element_class(irep, idx, dest_reg, ivar_classes, mand, arg_classes, owner_name)
  end

  # INTERP_UNLOCK / CORE_ARRAY_CHAIN: the chained-receiver rule, shared by
  # every block recognizer above. The rule itself (and its full soundness
  # argument) lives at top level as `proven_array_source_scan`, because
  # ClassLayout.analyze needs the exact same "is this expression a proven
  # fresh Array" question answered at its own SETIV sites, and two copies
  # of a soundness-critical rule is exactly the silent-drift shape
  # compiled_gems.rb's own closed_world_mrblib_srcs comment warns about.
  # This wrapper only supplies what is specific to a CodeGen instance: the
  # whole-program registry and the `-> Array` return annotations (which
  # ClassLayout has no access to and does not need).
  def proven_array_source(irep, idx, dest_reg)
    proven_array_source_scan(irep, idx, dest_reg, @registry, ->(n) { annotated_array_return(n) })
  end

  # MAP_BLOCK_SUPPORT: recognize one inlinable collection-block region --
  # `ary.map/select/reject/find/filter_map { |x| ... }` (1-mandatory-arg
  # blocks) and `ary.each_with_index { |x, i| ... }` (2-mandatory-arg
  # blocks). Same `BLOCK R(a+1)` + `SENDB/SSENDB Ra :name n=0` adjacency
  # as recognize_each_regions above (confirmed against real `mrbc -v`
  # for every name here -- `map`, `select`, `reject`, `find`,
  # `each_with_index`, `filter_map` all emit the identical shape), same
  # static Array receiver gate (including the SSENDB/owner rule). The
  # per-method result semantics live in emit_collect_inline, not here:
  # this recognizer only admits shapes whose block arity matches the
  # method (1 for map/select/reject/find/filter_map, 2 for
  # each_with_index -- a 2-arg `map` block or 1-arg `each_with_index`
  # block is a real arity-mismatch the interpreter would raise on, so it
  # keeps the honest `#error` here rather than compiling a
  # silently-wrong loop).
  #
  # `filter_map` itself: NOT a native Array method (no MRB_SYM(filter_map)
  # in 3rd/mruby/src/array.c) -- it comes from `Enumerable#filter_map`
  # (3rd/mruby/mrbgems/mruby-enum-ext/mrblib/enum.rb, mixed into Array),
  # confirmed present in this closed world (mruby-enum-ext is a real
  # dependency of both mruby-rpg2k and mruby-wolf's own mrbgem.rake and
  # build_config.rb). Its real body:
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
  # -- for an Array receiver `self.each` yields one element at a time
  # (never an array to splat), so the block always gets exactly the
  # element; the RESULT of the block (not the element itself, unlike
  # select/reject) is pushed only when truthy. Confirmed against real
  # `mrbc -v -S` on a synthetic `a.filter_map { |x| x if x > 0 }`: same
  # `BLOCK R4 I[0]` + `SENDB R3 :filter_map n=0` shape, block arity 1.
  # Real call site: `Scene_Menu`'s own command-id remap (mruby-rpg2k/
  # mrblib/scene/menu.rb, `ids.filter_map { |id| RPG2K3_COMMAND_IDS[id]
  # } << RPG2K_COMMAND_KEYS.last` -- the returned Array is then chained
  # with `<<`, an ordinary CALL on the inlined result, nothing special
  # needed here). No real receiver-class ambiguity: `filter_map` is not
  # redefined by any `class Array`/`class X < Array` reopen in
  # mruby-rpg2k/mruby-lcf/mruby-rgss's own mrblib (same audit as
  # recognize_each_index_regions' own comment).
  #
  # `any?`/`all?`/`none?`/`count`/`reduce` literal blocks stay out --
  # each needs its own accumulator/early-exit codegen, a separate
  # follow-up on this same machinery, not this round.
  COLLECT_BLOCK_METHODS = %w[map select reject find each_with_index flat_map filter_map].freeze

  # ACCUM_BLOCK_SUPPORT: recognize one inlinable accumulator/predicate
  # region -- `ary.any?/all?/none?/count { |x| ... }` (1-mandatory-arg
  # blocks) and `ary.reduce/inject(init) { |acc, x| ... }` (2-
  # mandatory-arg blocks, exactly one positional init argument:
  # `n=1`). Same `BLOCK R(a+1)` + `SENDB/SSENDB` adjacency and same
  # static Array gate as every recognizer above. Per-method semantics
  # (defaults, early-exit, accumulation) live in emit_accum_inline:
  #   - `any?`: false default, first truthy result exits with true.
  #   - `all?`: true default, first falsy result exits with false.
  #   - `none?`: true default, first truthy result exits with false.
  #   - `count`: fixnum tally of truthy results, no early exit.
  #   - `reduce`/`inject` with init (`n=1`): the SENDB's own R(dest+1)
  #     register holds the init value (verified below by register
  #     match, not assumed); each iteration feeds the accumulator
  #     through the block's two params and takes the block's yielded
  #     value back as the next accumulator.
  # A no-init `reduce` (`n=0` -- first element seeds the accumulator)
  # stays out: its empty-array/no-block nuances (nil on empty, each-
  # element-visited-once shape) need their own emitter, a follow-up.
  # Arity mismatches (2-arg `any?` block, 1-arg `reduce` block) keep
  # the honest `#error`, same as the collect recognizer.
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
        # `reduce(init)`: registers are dest, init, block -- the BLOCK
        # must sit at dest+2 with the init value at dest+1 (confirmed
        # against real `mrbc -v`: `BLOCK R4` + `SENDB R2 :reduce n=1`).
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
        # CHAINED_ACCESSOR_SUPPORT: threading the full @class_layout/
        # @registry through here too (both already sitting on `self`, no
        # new state) is a strictly additive extension of the same static
        # Array gate this call site already relies on -- it only ever
        # turns a prior nil into 'Array' when the receiver chain itself
        # proves Array-typed a new way, never changes an existing 'Array'
        # result.
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
        # CHAINED_ACCESSOR_SUPPORT: threading the full @class_layout/
        # @registry through here too (both already sitting on `self`, no
        # new state) is a strictly additive extension of the same static
        # Array gate this call site already relies on -- it only ever
        # turns a prior nil into 'Array' when the receiver chain itself
        # proves Array-typed a new way, never changes an existing 'Array'
        # result.
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

  # EACH_BLOCK_SUPPORT: recognize one `&:sym` block-pass site --
  # `ary.reject(&:dead?)` and friends. Shape (confirmed against real
  # `mrbc -v`): `LOADSYM R(a+1) :sym` immediately followed by
  # `SENDB`/`SSENDB Ra :name n=0`, with NO `BLOCK` instruction involved
  # at all -- the VM's own OP_SENDB packs `regs[bidx]` (here, the
  # LOADSYM-written symbol) via `ensure_block` into a symbol-proc, so
  # there is no closure to inline and no environment to capture. The
  # recognized method set is the Enumerable core whose per-element
  # semantics this file can express as a plain loop around one
  # `mrb_funcall` per element (see emit_sym_inline): iteration
  # (`each`), collection (`map`), filtering (`select`/`reject`),
  # search (`find`), predicates (`any?`/`all?`/`none?`), counting
  # (`count`). Same static Array receiver gate as
  # recognize_each_regions above (including the SSENDB/owner rule).
  SYM_BLOCK_METHODS = %w[each map select reject find any? all? none? count].freeze

  def recognize_sym_regions(irep, owner_name, mand, ivar_classes, arg_classes)
    regions = []
    irep.instructions.each_with_index do |insn, idx|
      next unless %w[SENDB SSENDB].include?(insn.op) && idx.positive?

      dest, name, nstr = insn.args.split(/\s+/, 3)
      next unless nstr == 'n=0' && SYM_BLOCK_METHODS.include?(name&.sub(/\A:/, ''))

      loadsym_insn = irep.instructions[idx - 1]
      next unless loadsym_insn && loadsym_insn.op == 'LOADSYM'
      # No BLOCK check needed here: the VM's own OP_SENDB takes its block
      # from exactly one slot (`regs[bidx]`, bidx = dest+1 for n=0 --
      # vm.c), and the LOADSYM immediately above provably overwrote that
      # slot last (register match below), whatever wrote it before. A
      # SENDB cannot take two blocks at once, so this site unambiguously
      # passes the symbol -- unlike a literal-block SENDB, which the each
      # recognizer above owns instead.
      #
      # Adjacent-shape note (keyword calls also LOADSYM into neighbor
      # registers): a keyword-argument call (`SEND ... n=k|nk=j`) parks
      # its key symbols at dest+1+n onward (positionals first -- see
      # compile_keyword_send's own kw_sym_regs), and is ALWAYS a plain
      # SEND/SSEND, never SENDB/SSENDB (the VM packs keywords from the
      # registers itself; only `ensure_block(regs[bidx])` in OP_SENDB's
      # own path makes a register a block). This recognizer only fires
      # on SENDB/SSENDB (the `next unless` at the top of the loop), so a
      # keyword call's key LOADSYM can never form a region here -- the
      # opcode disambiguates, not the slot. Documented because the slot
      # reuse is genuinely surprising and the next reader will wonder.

      dest_reg = dest[/^R(\d+)/, 1]
      sym_reg = loadsym_insn.args[/^R(\d+)/, 1]
      next unless dest_reg && sym_reg && sym_reg == (dest_reg.to_i + 1).to_s

      sym_name = loadsym_insn.args[/:(\S+)/, 1]&.sub(/\A:/, '')
      next unless sym_name && !sym_name.empty?

      if insn.op == 'SSENDB'
        next unless owner_name == 'Array'
      else
        # CHAINED_ACCESSOR_SUPPORT: threading the full @class_layout/
        # @registry through here too (both already sitting on `self`, no
        # new state) is a strictly additive extension of the same static
        # Array gate this call site already relies on -- it only ever
        # turns a prior nil into 'Array' when the receiver chain itself
        # proves Array-typed a new way, never changes an existing 'Array'
        # result.
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

  # INTERP_UNLOCK: recognize one inlinable `Range#each` region --
  # `r.each { |id| ... }` where the receiver traces to `Range` (a
  # `RANGE_INC`/`RANGE_EXC` literal, or the `range(cmd)` helper below).
  # Same `BLOCK R(a+1)` + `SENDB Ra :each n=0` adjacency and 1-arg gate
  # as recognize_each_regions (confirmed against real `mrbc -v`).
  # SSENDB excluded: the owner-gate is Array-specific and no game class
  # IS a Range.
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

  # INTERP_UNLOCK: `Game::Interpreter#range` always returns a Range --
  # every path builds `a..b` (inclusive) or the empty `1..0`
  # (indirect-mode miss), verified by reading the method, never
  # inferred. Human-vetted single-entry allowlist in the SUPER_TARGETS
  # tradition: when the backward scan from a range-each site lands on a
  # `SEND :range` writer, the receiver is proven Range. Any other
  # writer (or a future edit adding a non-Range path to #range)
  # misses here and keeps the honest `#error` -- the allowlist names
  # one exact Owner#name, not a bare method name, so an unrelated
  # `range` method elsewhere can never sneak through.
  RANGE_RETURN_METHODS = Set['Game::Interpreter#range'].freeze

  def range_return_call(irep, idx, dest_reg)
    (idx - 1).downto(0) do |i|
      pin = irep.instructions[i]
      next unless pin
      next unless pin.args[/^R(\d+)/, 1] == dest_reg
      # The receiver's own provenance: only a direct `range` call made
      # FROM a Game::Interpreter method body counts. A subclass
      # inheriting #range but overriding it would still dispatch to the
      # override -- so verify the CALLER is itself the Interpreter (via
      # the irep's own MethodDef owner), not just the method name.
      next unless %w[SEND SSEND SEND0 SSEND0].include?(pin.op)

      called = pin.args[/:([\w+\-*\/<>=!?\[\]&|^~%@]+)/, 1]
      return nil unless called == 'range'

      return 'Range' if RANGE_RETURN_METHODS.include?("#{@owner_of.fetch(irep.label).owner}#range")

      return nil
    end
    nil
  end

  # SORT_BLOCK_SUPPORT: recognize one inlinable sort-family region --
  # `ary.sort_by { |x| key }` (1-mandatory-arg key block),
  # `ary.sort { |a, b| ... }` (2-mandatory-arg comparator block),
  # `ary.uniq { |x| ... }` (1-arg key block). Same `BLOCK R(a+1)` +
  # `SENDB/SSENDB` adjacency and same static Array gate as every
  # recognizer above (upgraded here to the shared proven_array_source
  # gate: static trace + chained rule + `-> Array` annotations).
  # Per-method semantics live in emit_sort_inline.
  # `sort_by!`/`uniq!` (bang, in-place) stay out -- mutating the
  # receiver in place needs aliasing analysis this round doesn't do; a
  # follow-up. `max`/`min`/`max_by`/`min_by` (2 sites, `uniq`-adjacent)
  # stay out too -- same loop-with-key shape as `find`, trivially a
  # follow-up on this machinery, but not this round. Arity mismatches
  # keep the honest `#error`, same as every recognizer above.
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
        # CHAINED_ACCESSOR_SUPPORT: threading the full @class_layout/
        # @registry through here too (both already sitting on `self`, no
        # new state) is a strictly additive extension of the same static
        # Array gate this call site already relies on -- it only ever
        # turns a prior nil into 'Array' when the receiver chain itself
        # proves Array-typed a new way, never changes an existing 'Array'
        # result.
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
  # BLOCK_SUPPORT: translate one instruction from an INLINED block body
  # (never a top-level method body -- compile_method's own main loop
  # never calls this). `offset` disambiguates the block's own local
  # register numbering from the enclosing method's -- added to every
  # bare `R<N>` register reference in `insn.args` before delegating to
  # the ordinary `compile_insn` (a real irep, real instructions, just
  # relabeled first) for every opcode this function doesn't special-case
  # itself, so ordinary translation (ADD/MOVE/GETIV/SEND/...) needs no
  # changes of its own at all -- `idx: nil` in that delegated call also
  # cleanly disables compile_send's own MONO `.new`-devirtualization
  # (gated on a truthy `idx`, see its own comment), the one piece of
  # per-instruction codegen that would otherwise need real, aligned
  # backward-scan access to this SAME (offset) instruction's true index
  # in the ORIGINAL, un-offset `block_irep.instructions` array -- a real
  # missed optimization inside an inlined block body, never a wrong one.
  #
  # Four opcodes need real, block-body-specific handling, none of them
  # meaningful (or even reachable) in a top-level method body:
  #   - `RETURN`/`RETNIL`/`RETFALSE`/`RETTRUE` -- a block's own ordinary
  #     "yielded value" (confirmed directly: real `next` compiles to a
  #     plain `RETNIL`, not `RETURN_BLK` -- see this method's own caller
  #     comment). `#times` never uses this value at all, so it becomes a
  #     bare `goto` to this iteration's own end label -- ending just the
  #     current loop iteration, never the whole function.
  #   - `RETURN_BLK` -- a REAL `return` inside the block, OP_RETURN_BLK's
  #     own real non-local-return path (vm.c) for a genuine block. Since
  #     inlining collapses the block's own call frame into the exact same
  #     C++ function as its enclosing method, "unwind past the block back
  #     to the method that created it" and "the method this C++ code
  #     already belongs to" are the same frame -- so this is a perfectly
  #     ordinary C++ `return`, no unwinding machinery needed.
  #   - `GETUPVAR`/`SETUPVAR` -- real outer-local access (`uvget`/`uvset`,
  #     vm.c), gated here on level `0` only (a single level of block
  #     nesting -- this file has no nested-block support at all, so a
  #     level other than 0 can never arise from anything this recognizer
  #     itself accepts, but checked rather than assumed). Since the
  #     "outer scope" at level 0 for an inlined block IS this exact
  #     enclosing function, register index `b` already names one of its
  #     own real `r<b>` variables directly -- no offset applied, unlike
  #     every other register reference in this same instruction stream.
  # ELEMENT_CLASS_SUPPORT: publish "the receiver of THIS instruction is the
  # loop element, whose class is `elem_class`" for exactly the one
  # instruction about to be translated, then take it straight back down.
  # compile_send consumes the hint on read (see its own first lines), so
  # even a recursive compile triggered from inside that same call --
  # compiles_clean? probing a devirtualization candidate re-enters
  # compile_method for a COMPLETELY different body -- can never see a
  # stale hint belonging to this loop. The `ensure` is the second half of
  # the same belt-and-braces: a hint that some path never reads still
  # cannot outlive this one instruction.
  #
  # Only a real explicit-receiver send is eligible. `SSEND`/`SSEND0` are
  # implicit-self calls (the receiver is the enclosing method's own self,
  # never the element) and everything else has no receiver register at
  # all.
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

  # ELEMENT_CLASS_SUPPORT: does register `reg` still hold the loop element
  # at instruction `idx` of this block body? mrbc never sends directly on
  # a block parameter register -- it always MOVEs the parameter into a
  # scratch register first (`MOVE R10 R8` then `SEND R10 :dead?`,
  # confirmed against this project's own real generated output, not
  # assumed) -- so this follows MOVE chains back exactly the way
  # trace_new_target and proven_array_source_scan already do, and answers
  # true only when the chain bottoms out on the element register with
  # nothing having overwritten it in between.
  #
  # A block body that REASSIGNS its own parameter (`each { |a| a = x;
  # a.foo }`) writes the element register directly, and that write is a
  # non-MOVE writer this scan stops at -- correctly answering false.
  #
  # Straight-line, control-flow-insensitive, exactly like every other
  # backward scan in this file: a jump into the middle of the scanned
  # range could make this answer true where a real execution path had
  # overwritten the register. That is a PRECISION limit, not a soundness
  # one -- the emitted code still checks `mrb_obj_class` at runtime before
  # taking the direct call, so the worst case is one failed pointer
  # comparison and an ordinary `mrb_funcall`, never a wrong dispatch.
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

  def compile_block_body_insn(insn, block_irep, owner_def, offset, iter_end_label, label_prefix,
                                break_dest: nil, break_label: nil)
    case insn.op
    when 'RETURN', 'RETNIL', 'RETFALSE', 'RETTRUE'
      "  goto #{iter_end_label};\n"
    when 'RETURN_BLK'
      r = insn.args.strip.empty? ? '0' : insn.args[/^R(\d+)/, 1]
      "  return r#{r.to_i + offset};\n"
    when 'BREAK'
      # EACH_BLOCK_SUPPORT: a real `break` (with or without a value -- the
      # disassembly always carries the value register, LOADNIL-supplied when
      # bare, confirmed against real `mrbc -v` output) unwinds to the call
      # site with the break value as the whole SEND expression's own value
      # (vm.c's own OP_BREAK `L_UNWINDING` path). Inlined, that is an
      # assignment into the SENDB's own destination register plus a jump
      # past the loop -- same shape as RETURN_BLK above, landing after the
      # loop instead of leaving the function. Only wired by the each/sym
      # emitters (which pass both); the times emitter passes neither, so a
      # `break` inside a `#times` block keeps its honest `#error` exactly
      # as before this existed.
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
    # JMP/JMPNOT/JMPIF/JMPNIL need their OWN handling here, never a
    # delegation to the shared compile_insn below: that codegen hardcodes
    # a bare `goto L<target>;` (compile_method's own top-level "L<addr>"
    # convention), which for an inlined block body would collide with --
    # or simply fail to match -- this SAME function's own `label_prefix`-
    # qualified labels (C++ goto labels have whole-FUNCTION scope, not
    # block scope, so a bare, unprefixed "L16" here could even silently
    # collide with a real, same-numbered label the enclosing method's own
    # unrelated control flow already defined -- caught building this
    # exact case, `with_next`'s own `next if i == 1`, before it ever
    # shipped: g++ rejected the mismatched, undefined "L16" the shared
    # codegen's own output referenced). `.to_i` on every extracted target
    # is required, not cosmetic, for the exact same reason the shared
    # compile_insn's own JMP case already documents: the disassembly
    # zero-pads addresses ("016"), but labels are emitted by their real
    # *integer* value ("LBLK9_16:") -- also caught live, building this.
    when 'JMP'
      "  goto #{label_prefix}#{insn.args.strip[/\d+/].to_i};\n"
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
      shifted_args = insn.args.gsub(/R(\d+)/) { "R#{Regexp.last_match(1).to_i + offset}" }
      shifted = Insn.new(lineno: insn.lineno, addr: insn.addr, op: insn.op, args: shifted_args, raw: insn.raw)
      compile_insn(shifted, block_irep, owner_def, nil)
    end
  end

  # BLOCK_SUPPORT: the full inlined-loop replacement for one recognized
  # `.times` region (recognize_times_regions), or nil if the block's own
  # body doesn't come out clean (any `#error` anywhere -- an unsupported
  # opcode inside the block itself, including a nested BLOCK/SENDB this
  # file has no nested-block support for at all) -- never emitted
  # partially; compile_method's own caller falls all the way back to
  # leaving both BLOCK and SENDB as ordinary, honest `#error` stubs in
  # that case, exactly like any other unrecognized shape in this file.
  #
  # `offset` (the enclosing irep's own `nregs`) gives the block's own
  # local registers a disjoint numbering from the enclosing method's --
  # R0 (a block's own "self", inherited unchanged from its enclosing
  # method, real mruby semantics) is aliased straight to `self` rather
  # than renumbered, matching GETIV/SETIV's own hardcoded `self`
  # identifier (see emit_rescue_try_body's own identical fix for the
  # exact same constraint). Every other block-local register is
  # re-initialized to nil at the TOP OF EVERY ITERATION, not just once
  # before the loop -- a fresh block activation each time it's yielded
  # to, exactly like a real Proc#call would give it, never state leftover
  # from a previous iteration.
  def emit_times_inline(region, irep, d)
    block_irep = region[:block_irep]
    offset = irep.nregs
    dest_reg = region[:dest_reg]
    param_reg = 1 + offset # the block's own single mandatory arg, R1 in its own numbering.

    label_prefix = "LBLK#{region[:block_addr]}_"
    body = String.new
    iter_label = "Lbc2cpp_times_iter_#{region[:block_addr]}"
    body_targets = jump_targets(block_irep)
    block_irep.instructions.each do |insn|
      next if insn.op == 'ENTER'

      body << "    #{label_prefix}#{insn.addr}:;\n" if body_targets.include?(insn.addr)
      body << '  ' << compile_block_body_insn(insn, block_irep, d, offset, iter_label, label_prefix)
    end
    return nil if body.include?('#error')

    out = String.new
    out << "  {\n"
    # Not E_TYPE_ERROR: that macro hardcodes the identifier `mrb` (see
    # embedded-ivar SETIV's own identical comment/fix, compile_insn's own
    # SETIV case) -- every register/state variable in this whole file is
    # named `M`, never `mrb`, so the macro's own expansion would reference
    # an undeclared identifier. A real g++ error caught building this
    # exact case, not assumed from reading the macro alone.
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
    # Integer#times returns self (the original receiver), not the loop's
    # own last value -- r<dest_reg> already still holds it, untouched by
    # the loop above, so no further assignment is needed here at all.
    out
  end

  # EACH_BLOCK_SUPPORT: the full inlined-loop replacement for one
  # recognized `ary.each` region (recognize_each_regions), or nil when
  # the block body doesn't come out clean -- same all-or-nothing
  # contract as emit_times_inline above. Three deliberate differences
  # from the times loop, each grounded in real semantics rather than
  # cloned by analogy:
  #   - LIVE length (`i < RARRAY_LEN(recv)` re-checked every iteration,
  #     the exact condition native iteration in 3rd/mruby/src/array.c
  #     uses): real `Array#each` visits elements pushed mid-iteration
  #     (confirmed against CRuby: `[1,2,3].each { a << 99 if first }`
  #     visits 99) -- a snapshot `n` like times uses would silently
  #     drop them. `mrb_ary_ref` (bounds-checked, negative-normalizing
  #     -- the same public API GETIDX codegen already trusts) supplies
  #     each element.
  #   - `mrb_array_p` raise-guard (mirrors times' `mrb_integer_p`
  #     guard): unreachable when the recognizer's own static gate is
  #     sound, a loud TypeError tripwire if the trace is ever buggy --
  #     never silent wrong dispatch into a `Game::Actors#each`-style
  #     override. NOT a live `mrb_funcall` fallback: `mrb_funcall`
  #     cannot carry a block, so falling back through it would silently
  #     drop the block -- the exact bug class ADR 0147 rejected
  #     proc-wrap for. The interpreter (honest `#error` on unproven
  #     sites) is the real fallback, always correct.
  #   - `BREAK` wired (break_dest/break_label): times leaves it `#error`;
  #     here `BREAK Rv` assigns the SENDB destination and jumps past the
  #     loop, matching OP_BREAK's own `L_UNWINDING` value semantics. A
  #     completed loop leaves the destination holding the receiver
  #     (real `Array#each` returns its receiver -- confirmed against
  #     CRuby), so no assignment is needed on the fall-through path.
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
    body_targets = jump_targets(block_irep)
    block_irep.instructions.each_with_index do |insn, i|
      next if insn.op == 'ENTER'

      body << "    #{label_prefix}#{insn.addr}:;\n" if body_targets.include?(insn.addr)
      # ELEMENT_CLASS_SUPPORT: the block's own single mandatory parameter
      # is R1 in its own register numbering (mandatory_arity == 1, checked
      # by this region's own recognizer), and this emitter binds exactly
      # that register to `mrb_ary_ref(...)` below -- so R1 IS the loop
      # element for the whole body.
      with_element_hint(block_irep, insn, i, '1', region[:elem_class]) do
        body << '  ' << compile_block_body_insn(insn, block_irep, d, offset, iter_label, label_prefix,
                                                break_dest: dest_reg, break_label: break_label)
      end
    end
    return nil if body.include?('#error')

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

  # EACH_INDEX_SUPPORT: the inlined-loop replacement for one recognized
  # `ary.each_index` region (recognize_each_index_regions above), or nil
  # when the block body doesn't come out clean -- same all-or-nothing
  # contract as emit_each_inline, whose live-`RARRAY_LEN` loop this
  # clones with one deliberate difference: the block's own single
  # mandatory parameter is bound to the loop COUNTER itself
  # (`mrb_fixnum_value(i)`), never an `mrb_ary_ref`/`bc2cpp_ary_entry`
  # fetch -- real `Array#each_index` (mrblib/array.rb, cited in
  # recognize_each_index_regions' own comment) yields `idx`, not
  # `self[idx]`. No `with_element_hint` here, for the identical reason
  # emit_collect_inline's own `each_with_index` index parameter skips it
  # (that method's own comment): the bound value is always Integer,
  # already known to codegen without a hint. Fall-through leaves dest
  # holding the receiver (real `#each_index` returns `self`, its own
  # mrblib body's trailing `self`) -- no assignment needed, same as
  # emit_each_inline.
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
    body_targets = jump_targets(block_irep)
    block_irep.instructions.each do |insn|
      next if insn.op == 'ENTER'

      body << "    #{label_prefix}#{insn.addr}:;\n" if body_targets.include?(insn.addr)
      body << '  ' << compile_block_body_insn(insn, block_irep, d, offset, iter_label, label_prefix,
                                              break_dest: dest_reg, break_label: break_label)
    end
    return nil if body.include?('#error')

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

  # HASH_EACH_SUPPORT: the full inlined-loop replacement for one
  # recognized `hash.each` region (recognize_hash_each_regions above), or
  # nil when the block body doesn't come out clean -- same all-or-nothing
  # contract as emit_each_inline. Two deliberate differences from that
  # Array loop, both grounded in real Hash#each semantics
  # (3rd/mruby/mrblib/hash.rb), not cloned by analogy:
  #   - SNAPSHOT, not live: real Hash#each computes `keys = self.keys`/
  #     `vals = self.values`/`len = self.size` ONCE before iterating, not
  #     a live hash-table walk -- `mrb_hash_keys`/`mrb_hash_values` (both
  #     real public MRB_API, 3rd/mruby/include/mruby/hash.h) each return
  #     a FRESH Array, so this loop's own bound and per-index reads are
  #     naturally immune to the receiver being mutated mid-iteration,
  #     unlike emit_each_inline's own live `RARRAY_LEN` re-check (see
  #     that method's own comment for why Array#each needs one and this
  #     one structurally can't need one: there is no "live hash" here to
  #     re-check against, only two already-snapshotted Arrays).
  #   - TWO synthesized values per iteration (key then value), assigned
  #     directly into the block's own R1/R2 -- the identical "skip the
  #     real Proc#call/auto-splat machinery, just assign the registers"
  #     mechanism recognize_accum_regions' own reduce/inject fold already
  #     uses for its own 2-value (acc, x) yield.
  # `mrb_hash_p` raise-guard (mirrors `mrb_array_p` above): unreachable
  # when the recognizer's own static gate is sound, a loud TypeError
  # tripwire if the trace is ever buggy -- never silent wrong dispatch.
  # `BREAK` wired the same way; a completed loop leaves the destination
  # holding the receiver (real `Hash#each` returns `self`, its own
  # mrblib body's trailing `self`), so no assignment is needed on the
  # fall-through path either.
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
    body_targets = jump_targets(block_irep)
    block_irep.instructions.each_with_index do |insn, i|
      next if insn.op == 'ENTER'

      body << "    #{label_prefix}#{insn.addr}:;\n" if body_targets.include?(insn.addr)
      body << '  ' << compile_block_body_insn(insn, block_irep, d, offset, iter_label, label_prefix,
                                               break_dest: dest_reg, break_label: break_label)
    end
    return nil if body.include?('#error')

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

  # EACH_KEY_SUPPORT: the full inlined-loop replacement for one
  # recognized `hash.each_key` region (recognize_each_key_regions
  # above), or nil when the block body doesn't come out clean -- same
  # all-or-nothing contract as emit_hash_each_inline, whose SNAPSHOT
  # loop this clones with one deliberate difference: only the KEY
  # snapshot is taken (`mrb_hash_keys`) and only ONE value is bound per
  # iteration -- real `Hash#each_key` (mrblib/hash.rb, cited in
  # recognize_each_key_regions' own comment) never touches `#values` at
  # all, so no `mrb_hash_values` snapshot is taken here (unlike
  # emit_hash_each_inline's own two-snapshot loop). `mrb_hash_p`
  # raise-guard and fall-through-leaves-receiver behavior mirror
  # emit_hash_each_inline exactly (real `Hash#each_key` also returns
  # `self`).
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
    body_targets = jump_targets(block_irep)
    block_irep.instructions.each do |insn|
      next if insn.op == 'ENTER'

      body << "    #{label_prefix}#{insn.addr}:;\n" if body_targets.include?(insn.addr)
      body << '  ' << compile_block_body_insn(insn, block_irep, d, offset, iter_label, label_prefix,
                                               break_dest: dest_reg, break_label: break_label)
    end
    return nil if body.include?('#error')

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

  # INTERP_UNLOCK: the inlined-loop replacement for one recognized
  # `Range#each` region (recognize_range_each_regions), or nil when the
  # block body doesn't come out clean -- same all-or-nothing contract
  # as emit_each_inline above, whose loop this clones with four
  # deliberate differences (each grounded in mrblib/range.rb's own
  # integer fast path, never assumed):
  #   - COUNTER, not fetch: the element is the loop index itself as a
  #     fixnum (`r<param> = mrb_fixnum_value(i)`), no `mrb_ary_ref`.
  #   - SNAPSHOT bounds: beg/end/excl read ONCE before looping (Ranges
  #     are frozen -- `range_initialize` freezes -- so no
  #     push-during-iteration analogue exists; unlike Array's live
  #     `RARRAY_LEN` re-check, a snapshot is exactly sound here).
  #   - OVERFLOW-SAFE comparison: `excl ? i < e : i <= e` instead of
  #     mrblib's own `lim = end + 1; i < lim` (which overflows at
  #     MRB_INT_MAX -- this formulation cannot).
  #   - GUARD is two-part: `mrb_range_p` (right class) AND Integer
  #     beg/end (the `succ`-path, Float edges, and nil-ended/endless
  #     ranges -- an endless range would be an infinite loop -- all
  #     raise rather than miscompile; unproven sites keep the honest
  #     `#error`). Uses the REAL excl flag from `mrb_range_excl_p`,
  #     never `begin == end` (a `1...1` exclusive range is empty while
  #     `begin == end` -- the source-level shortcut in
  #     do_control_switches is only valid because `range()` never
  #     builds `...`, and the emitter must not replicate that
  #     assumption).
  # Fall-through leaves dest holding the receiver (Range#each returns
  # self, mrblib/range.rb) -- no assignment, same as each. BREAK,
  # RETURN_BLK, upvars, jumps: identical handling via
  # compile_block_body_insn (same break_dest/break_label wiring).
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
    body_targets = jump_targets(block_irep)
    block_irep.instructions.each do |insn|
      next if insn.op == 'ENTER'

      body << "    #{label_prefix}#{insn.addr}:;\n" if body_targets.include?(insn.addr)
      body << '  ' << compile_block_body_insn(insn, block_irep, d, offset, iter_label, label_prefix,
                                              break_dest: dest_reg, break_label: break_label)
    end
    return nil if body.include?('#error')

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

  # MAP_BLOCK_SUPPORT: the inlined-loop replacement for one recognized
  # collection-block region (recognize_collect_regions), or nil when the
  # block body doesn't come out clean -- same all-or-nothing contract as
  # emit_each_inline above, whose loop this clones with four deliberate
  # differences (each grounded in measured semantics, not analogy):
  #   - RESULT slot: `map` collects each iteration's yielded value
  #     (block-body RETURN/RETNIL -- a real `next value` -- pushes
  #     `r<off>` into a fresh `mrb_ary_new` accumulator, the SENDB
  #     destination takes the accumulator, never the receiver);
  #     `select`/`reject` push the ELEMENT on truthy/falsy result;
  #     `find` assigns the first truthy-result element and exits early
  #     (nil default when nothing matches); `each_with_index` discards
  #     like `each` but binds a second param to the loop index as a
  #     fixnum each iteration.
  #   - YIELDED VALUE capture: the block body's own `RETURN Rv` (and the
  #     RETNIL/RETFALSE/RETTRUE family -- a real `next`, possibly with a
  #     value) is the per-element result, NOT a bare end-of-iteration the
  #     way `each` treats it. So the body is translated by
  #     compile_collect_body_insn below (not compile_block_body_insn):
  #     each return-form stores its own value into the per-iteration
  #     result local, then jumps to iter-end. A value-less `next`
  #     (RETNIL) stores nil -- correct: real `map { next if c }`
  #     collects nil for that element (confirmed against CRuby).
  #   - `BREAK Rv` (value) assigns the SENDB destination and jumps past
  #     the loop (same L_UNWINDING semantics as each -- `map { break 99
  #     }` is 99, confirmed against CRuby); bare `break` behaves the
  #     same with the BREAK register's own (nil) value.
  #   - Live `RARRAY_LEN` loop + `mrb_array_p` raise-guard, identical to
  #     each (map-push-during-iteration visits new elements -- confirmed
  #     against CRuby above -- so no snapshot).
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
    body_targets = jump_targets(block_irep)
    block_irep.instructions.each_with_index do |insn, i|
      next if insn.op == 'ENTER'

      body << "    #{label_prefix}#{insn.addr}:;\n" if body_targets.include?(insn.addr)
      # ELEMENT_CLASS_SUPPORT: R1 in the block's own numbering is the
      # ELEMENT for every method this recognizer admits -- including
      # `each_with_index`, whose second parameter (R2) is the fixnum index
      # and is deliberately NOT hinted (it is not an element, and its
      # class is already known to codegen anyway).
      with_element_hint(block_irep, insn, i, '1', region[:elem_class]) do
        body << '  ' << compile_collect_body_insn(insn, block_irep, d, offset, iter_label, label_prefix,
                                                  result_var: result_var, break_dest: dest_reg,
                                                  break_label: break_label,
                                                  broke_flag: "bc2cpp_collect_broke_#{region[:block_addr]}")
      end
    end
    return nil if body.include?('#error')

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
      # INTERP_UNLOCK: mruby's own flat_map (enum-ext/mrblib/enum.rb):
      # each yielded value is pushed whole when it does NOT respond to
      # `each`, else each of ITS elements is pushed (one level only --
      # `e2.each { |e3| ary.push(e3) }`, never recursive). Mirror with
      # the same respond_to? gate. The inner expansion loops over
      # RARRAY_LEN -- but ONLY after an `mrb_array_p` tripwire on the
      # yielded value (same trust class as every receiver guard: a
      # Hash/Range yielder responds to `each` but is not an Array, and
      # RARRAY_LEN on it would misread memory -- the tripwire raises
      # loudly instead, never silently wrong). Divergence from the VM
      # ONLY when a program yields a non-Array each-responder from
      # flat_map AND expects expansion. Real game code never does
      # (verified: the flat_map sites yield id-arrays); the tripwire
      # message says exactly this. Documented as a known, deliberate
      # narrowing (same class as the Integer-edges guard on Range#each,
      # which also raises where the VM would iterate).
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
      # COLLECT_BLOCK_SUPPORT / filter_map: pushes the block's own RESULT
      # (not the element, unlike select/reject) when truthy -- real
      # Enumerable#filter_map (cited in COLLECT_BLOCK_METHODS' own
      # comment) reassigns `x = blk.call(*x)` before the `ary.push x if
      # x` truthiness test, so the pushed value and the tested value are
      # the same block-result register.
      out << "      if (mrb_test(#{result_var})) mrb_ary_push(M, bc2cpp_collect_acc_#{region[:block_addr]}, #{result_var});\n"
    end
    out << "    }\n"
    out << "    #{break_label}:;\n"
    # BREAK inside the loop jumps here with the destination ALREADY
    # holding the break value (BREAK's own `r<dest> = r<v>` assignment,
    # wired with this emitter's own broke-flag below) -- so the final
    # accumulator assignment must NOT run on the break path (it would
    # overwrite the break value with a partial accumulator, the exact
    # `[1, 2]`-instead-of-`99` bug caught by the runtime harness).
    # A loop-index comparison (fall-through exits with i == len, break
    # with i < len) was considered and rejected: pop-during-iteration
    # can shrink len below a later break index, misreading break as
    # fall-through. A dedicated boolean, set only on the break path,
    # has zero per-iteration cost and no such edge. each_with_index
    # needs no guard at all (fall-through leaves the receiver, break
    # already set dest -- no assignment either way), so it skips both
    # the flag declaration and the guarded assignment.
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

  # ACCUM_BLOCK_SUPPORT: the inlined-loop replacement for one recognized
  # accumulator/predicate region (recognize_accum_regions), or nil when
  # the block body doesn't come out clean -- same all-or-nothing
  # contract as every emitter above. Clones emit_collect_inline's loop
  # with three deliberate differences (each grounded in measured CRuby
  # semantics, listed in recognize_accum_regions' own comment):
  #   - PREDICATE result: `any?`/`all?`/`none?` produce a boolean
  #     destination with early exit (any?: false default, first truthy
  #     result sets true + goto end; all?: true default, first falsy
  #     sets false + goto end; none?: true default, first truthy sets
  #     false + goto end). A `break v` inside overrides with v (same
  #     broke-flag pattern as collect -- BREAK assigns dest + sets the
  #     flag + jumps past; the final boolean assignment is flag-
  #     guarded). Empty-array defaults fall out with zero iterations.
  #   - COUNT tally: `count` keeps a fixnum tally local (no early exit),
  #     destination takes the tally past the broke-guard (a `break v`
  #     overrides with v -- confirmed against CRuby: `count { break 7 }`
  #     is 7).
  #   - FOLD threading: `reduce`/`inject(init)` seeds a block-local
  #     accumulator from the SENDB's own R(dest+1) init register ONCE
  #     before the loop (never re-initialized per iteration -- the whole
  #     point of a fold); each iteration binds block param 1 to the
  #     accumulator and param 2 to the element, and takes the block's
  #     yielded value back as the next accumulator. Destination takes
  #     the accumulator past the broke-guard. The init register is read
  #     before the loop starts, so a body that later writes the same
  #     enclosing register (possible only through a level-0 SETUPVAR
  #     aliasing that local) cannot affect iteration -- sound by copy
  #     timing, documented because subtle.
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
    body_targets = jump_targets(block_irep)
    block_irep.instructions.each_with_index do |insn, i|
      next if insn.op == 'ENTER'

      body << "    #{label_prefix}#{insn.addr}:;\n" if body_targets.include?(insn.addr)
      # ELEMENT_CLASS_SUPPORT: which parameter register holds the ELEMENT
      # depends on the shape this region actually is -- a predicate block
      # (`any?`/`all?`/`none?`/`count`) takes the element as its single
      # parameter R1, while a fold (`reduce`/`inject`) takes the
      # ACCUMULATOR as R1 and the element as R2. Read straight off the
      # same `is_fold` flag that decides the register binding a few lines
      # below, so the two can never disagree.
      with_element_hint(block_irep, insn, i, is_fold ? '2' : '1', region[:elem_class]) do
        body << '  ' << compile_collect_body_insn(insn, block_irep, d, offset, iter_label, label_prefix,
                                                  result_var: result_var, break_dest: dest_reg,
                                                  break_label: break_label,
                                                  broke_flag: "bc2cpp_accum_broke_#{region[:block_addr]}")
      end
    end
    return nil if body.include?('#error')

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

  # MAP_BLOCK_SUPPORT: translate one instruction from an INLINED
  # collection-block body -- identical to compile_block_body_insn
  # (RETURN_BLK, BREAK, GETUPVAR/SETUPVAR@0, JMP-family, delegated
  # everything-else) EXCEPT the block's own ordinary return forms
  # (`RETURN`/`RETNIL`/`RETFALSE`/`RETTRUE` -- a real `next`, possibly
  # with a value): where each-inline treats them as bare end-of-
  # iteration, collection methods USE the yielded value, so each such
  # form first stores its own value register into `result_var`, then
  # jumps to iter-end. `RETURN_BLK` (real `return`) is unchanged --
  # still a plain C++ return. BREAK/BREAK-value, upvars, jumps, and the
  # delegated remainder are line-for-line the each behavior.
  def compile_collect_body_insn(insn, block_irep, owner_def, offset, iter_end_label, label_prefix,
                                result_var:, break_dest:, break_label:, broke_flag:)
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
      # Same L_UNWINDING value semantics as compile_block_body_insn's
      # own BREAK case, PLUS setting this emitter's own broke-flag so
      # the post-loop accumulator assignment knows not to run (see
      # emit_collect_inline's own comment -- without the flag the break
      # value would be overwritten by a partial accumulator).
      r = insn.args.strip.empty? ? '0' : insn.args[/^R(\d+)/, 1]
      "  r#{break_dest} = r#{r.to_i + offset};\n  #{broke_flag} = TRUE;\n  goto #{break_label};\n"
    else
      compile_block_body_insn(insn, block_irep, owner_def, offset, iter_end_label, label_prefix,
                              break_dest: break_dest, break_label: break_label)
    end
  end

  # EACH_BLOCK_SUPPORT: the inlined-loop replacement for one recognized
  # `&:sym` site (recognize_sym_regions) -- `ary.reject(&:dead?)` and
  # friends. No closure exists (the VM packs the LOADSYM symbol via
  # `ensure_block`), so instead of a translated block body each
  # iteration performs one real `mrb_funcall(M, elem, "<sym>", 0)` --
  # ordinary dynamic dispatch of the NAMED method, exactly what
  # `Symbol#to_proc` does at runtime -- and accumulates per the call
  # method's own real Enumerable semantics:
  #   each: discard the result (destination keeps the receiver);
  #   map: push each result into a fresh Array;
  #   select/reject: push the ELEMENT when the result is truthy/falsy;
  #   find: destination is the first element with a truthy result
  #     (else nil), loop exits early;
  #   any?/all?/none?: boolean destination with early exit
  #     (all?/none? default true, any? defaults false);
  #   count: destination is the fixnum tally of truthy results.
  # Same live-length loop and `mrb_array_p` raise-guard as
  # emit_each_inline above (same mutation-during-iteration and
  # wrong-receiver reasoning -- confirmed the same way). Returns nil
  # (caller falls back to `#error` stubs) only when the method name is
  # outside the recognizer's own set, which cannot happen -- the
  # recognizer is the sole caller and already gates on it.
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

  # SYM_DEVIRT: the per-element call for a `&:sym` site, devirtualized
  # where sym_call_target allows. Both helpers emit full STATEMENTS
  # (never bare expressions): `sym_call_value` declares
  # `mrb_value <result_var> = ...` for valued methods, `sym_call_line`
  # emits the discard-result call for `each`. Both take the element
  # expression (always the loop's own `bc2cpp_sym_e_N` local -- a plain
  # `mrb_value`, so the TYPED guard shape needs no register-specific
  # adaptation).
  #
  # A POLY chain is a statement-level if/else-if/else (NOT a C
  # conditional expression -- `if` is not an expression in C, caught by
  # g++ building the first real chain), which is why valued and void
  # cases need separate helpers rather than one shared expression core.
  #
  # Soundness: the `mrb_funcall` fallback is exact `Symbol#to_proc`
  # semantics (unlike a literal block, a symbol-call carries no closure
  # `mrb_funcall` would drop), so every fallback path is merely slower,
  # never wrong. The MONO direct call needs no guard at all (one def
  # program-wide); each POLY branch guards exact-class `==` (subclass
  # elements take the fallback -- same as compile_send's TYPED path).
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
      check = "mrb_class_ptr(#{const_chain_value_expr(d.owner)}) == mrb_obj_class(M, #{elem_expr})"
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
      check = "mrb_class_ptr(#{const_chain_value_expr(d.owner)}) == mrb_obj_class(M, #{elem_expr})"
      out << (i.zero? ? '      ' : '      else ')
      out << "if (#{check}) { #{impl}(M, #{elem_expr}); }\n"
    end
    out << "      else { #{fallback} }\n"
    out
  end

  # SORT_BLOCK_SUPPORT: the inlined replacement for one recognized
  # sort-family region (recognize_sort_regions), or nil when the block
  # body doesn't come out clean -- same all-or-nothing contract as
  # every emitter above. Two strategies, split by what the block MEANS:
  #
  # - `sort { |a, b| ... }` (comparator): delegate the WHOLE call to
  #   the interpreter. A comparator block cannot inline as a loop at
  #   all -- it runs O(n log n) times inside the VM's own sort, driven
  #   by native code this file cannot reproduce. So `sort`-with-block
  #   is NOT compiled here (returns nil -- honest `#error`, stays
  #   interpreted). Recognized-and-rejected deliberately: the shape is
  #   claimed so a future round (comparator-as-callback via retained
  #   Proc, or key-extraction) has a named place to extend. Bare
  #   `sort` with NO block (`n=0`, no BLOCK -- plain SEND, never
  #   reaches this recognizer) already compiles as an ordinary call.
  #
  # - `sort_by { |x| key }` / `uniq { |x| key }` (key extraction): the
  #   Schwartzian transform, expressed with/or ordinary compiled
  #   operations only --
  #     1. keys[i] = <block>(elem[i]) for each element (the inlined
  #        block body, yielded-value capture shared with collect via
  #        compile_collect_body_insn -- same `next`-collects-nil,
  #        same `break`-overrides, same broke-flag);
  #     2. decorate: pairs[i] = [keys[i], i, elem[i]] (index decoration
  #        keeps the sort STABLE -- mruby's own sort is not stable, but
  #        CRuby's sort_by IS stable, confirmed by oracle above:
  #        `[[0,"b"],[0,"a"]].sort_by` keeps order -- and game code
  #        like turn-order ties depends on it);
  #     3. sort pairs by (key, index) with `mrb_cmp` (mruby.h's own
  #        public three-way comparison: fixnum/float/string fast paths,
  #        `<=>` dispatch otherwise, -2 on incomparable -- exactly the
  #        comparison native sort itself uses);
  #     4. undecorate: dest[i] = pairs[i][2].
  #   `uniq` differs only in step 3-4: keep the FIRST element per key
  #   (consecutive-key dedup after sorting by key -- sort stably by
  #   key, then drop adjacent equal keys via `mrb_cmp == 0`).
  #   All temporaries are fresh `mrb_ary_new` locals (never the
  #   receiver -- `sort_by`/`uniq` return new arrays, confirmed by
  #   oracle; the receiver is only ever READ via `mrb_ary_ref`).
  #   A `break v` inside the key block overrides the whole expression
  #   with v (same broke-flag pattern as collect/accum).
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
    body_targets = jump_targets(block_irep)
    block_irep.instructions.each_with_index do |insn, i|
      next if insn.op == 'ENTER'

      body << "    #{label_prefix}#{insn.addr}:;\n" if body_targets.include?(insn.addr)
      # ELEMENT_CLASS_SUPPORT: a `sort_by`/`uniq` key block takes the
      # element as its single parameter R1, same as the collect family.
      with_element_hint(block_irep, insn, i, '1', region[:elem_class]) do
        body << '  ' << compile_collect_body_insn(insn, block_irep, d, offset, iter_label, label_prefix,
                                                  result_var: result_var, break_dest: dest_reg,
                                                  break_label: break_label,
                                                  broke_flag: "bc2cpp_sort_broke_#{region[:block_addr]}")
      end
    end
    return nil if body.include?('#error')

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
    # Key loop uses a snapshot length (n) for allocation but re-checks
    # live RARRAY_LEN per element -- push-during-key-block visits new
    # elements (same live-length rule as every emitter above); keys and
    # elements can only diverge if the body mutates the receiver, in
    # which case the SORT phase below re-reads live length and the key
    # array is shorter -- guarded: iterate min(keys, len) by indexing
    # keys with the same live loop and pushing only while i < keys len.
    # Simpler exact rule: sort phase loops over the KEY array's own
    # length (keys are 1:1 with visited elements by construction), and
    # element fetch uses mrb_ary_ref on the receiver at the same index
    # (nil-padded by mrb_ary_ref semantics if the receiver shrank --
    # matches interpreted sort_by-on-mutated-array within reason; a
    # body that mutates mid-sort is already VM-undefined -- native sort
    # RAISES "array modified during sort" -- so any sane behavior here
    # is acceptable, and non-mutating bodies are exact).
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
    # Insertion sort on (key, index) -- O(n^2) worst case, but game
    # arrays here are tiny (turn order, event lists, transition bands:
    # single-to-double digits), and insertion sort is STABLE, which the
    # index decoration would otherwise have to supply alone. The index
    # tiebreak below makes stability explicit regardless of algorithm,
    # so this is correct for any size, just tuned for small n.
    # mrb_cmp: 1/0/-1, -2 on incomparable (same contract native
    # sort_cmp relies on -- incomparable keys raise, matching the VM).
    # mrb_integer on the decorated index: always a real fixnum (emitted
    # above as mrb_fixnum_value(j)), never user data -- no TypeError
    # path possible, matching native sort's own unchecked index ints.
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

  def compile_insn(insn, irep, owner_def, idx = nil)
    a = insn.args
    case insn.op
    when 'ENTER'
      "  // #{insn.raw.strip} (args already bound above)\n"
    when 'KEY_P'
      # KEYWORD_ARG_SUPPORT: real presence check for one optional keyword
      # -- the entry wrapper's own real mrb_kwargs extraction (compile_
      # method) already computed this as a plain bool parameter, named
      # purely from this same instruction's own `:sym` operand (see
      # kwarg_param_name's own comment -- no external table needed here).
      d = a[/^R(\d+)/, 1]
      sym = a[/:(\S+)/, 1]
      "  r#{d} = mrb_bool_value(#{kw_given_param_name(sym)});\n"
    when 'KARG'
      # KEYWORD_ARG_SUPPORT: fetch one keyword's own real value -- required
      # or optional, both are already-unpacked plain mrb_value parameters
      # by the time _impl runs (an optional one's own default-value
      # computation, reached only when KEY_P's own JMPIF found it absent,
      # simply overwrites this same register right afterward, exactly like
      # OPTIONAL_ARG_SUPPORT's own default-value codegen).
      d = a[/^R(\d+)/, 1]
      sym = a[/:(\S+)/, 1]
      "  r#{d} = #{kwarg_param_name(sym)};\n"
    when 'KEYEND'
      # KEYWORD_ARG_SUPPORT: real unrecognized-keyword-argument checking
      # (raising ArgumentError on a key this method never declared) is
      # already done by the entry wrapper's own real mrb_kwargs (`rest:
      # NULL`, mruby.h's own documented behavior) before _impl is ever
      # reached -- nothing left for this opcode to do here.
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
      # "LOADSELF R2 (R0)" -- R[a] = self (src/vm.c's OP_LOADSELF). Real
      # code hits this from an explicit-receiver self-send that mrbc
      # doesn't fold into SSEND (`self.foo = ...`, a plain local-variable-
      # looking assignment on an attr writer, compiles to LOADSELF + SEND
      # rather than SSEND -- confirmed against a toy `self.baz = 1` case).
      # r0 is already wired to `self` at the top of every generated
      # function body (CodeGen#compile_method's own `mrb_value r0 = self;`
      # declaration), so this is exactly as trivial as LOADNIL/LOADFALSE/
      # LOADTRUE's own bare-assignment shape above.
      d, = regs(a, 1)
      "  r#{d} = self;\n"
    when 'LOADSYM'
      d = a[/^R(\d+)/, 1]
      name = a[/:(\S+)/, 1]
      "  r#{d} = mrb_symbol_value(mrb_intern_cstr(M, \"#{name}\"));\n"
    when /^LOADI/
      d = a[/^R(\d+)/, 1]
      # The small-immediate variants (LOADI_0..7, LOADI__1, plain LOADI)
      # show the literal parenthesized, e.g. "R6\t(3)" -- but the
      # wider-range ones (LOADI8/LOADI16/LOADI32/...) don't: "R1\t128" with
      # no parens at all. Real game code hits both; this toy's own literals
      # were all small enough to only ever exercise the parenthesized form.
      lit = a[/\(([^)]+)\)/, 1] || a[/^R\d+\s+(-?\d+)/, 1]
      "  r#{d} = mrb_fixnum_value(#{lit});\n"
    when 'LOADL'
      # "LOADL R5 L[0]" -- a numeric literal too wide for LOADI's own
      # immediate operand (src/vm.c's OP_LOADL: pool[k].tt is INT32/INT64/
      # BIGINT/FLOAT). Only FLOAT is modeled here -- parse_c_dump's own
      # pool scan already tags a non-string entry as {type:, raw:} (the
      # same mixed-type-pool handling STRING's own #error fallback above
      # relies on), and every real FLOAT entry seen in this codebase's own
      # pools (mrbc's C dump, a %.17g-shaped literal, e.g. ".f=0.330000000
      # 00000002") is already a valid, directly-reusable C double literal
      # -- no reformatting needed. INT32/INT64/BIGINT pool entries never
      # showed up under LOADL in real code (mrb_int literals wide enough
      # to need LOADL instead of LOADI/LOADI8/16/32 are bignums here,
      # IREP_TT_BIGINT -- a real big-endian sign+exponent encoded string
      # this prototype doesn't decode); left as an honest #error, the same
      # "loud gap, not a silent wrong translation" every other unmodeled
      # shape here gets, rather than guessed at.
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
    when 'STRCAT'
      # Matches OP_STRCAT's own real semantics exactly (src/vm.c):
      # mrb_ensure_string_type then mrb_str_concat (mutates r<d> in place).
      d = a[/^R(\d+)/, 1]
      s = a[/\(R(\d+)\)/, 1]
      "  r#{d} = mrb_ensure_string_type(M, r#{d});\n  mrb_str_concat(M, r#{d}, r#{s});\n"
    when 'GETIV'
      d = a[/^R(\d+)/, 1]
      ivar = a[/@(\w+)/, 1]
      if (type = embed_type(owner_def.owner, ivar))
        sname = struct_name(owner_def.owner)
        box = TYPE_OPS.fetch(type)[:box]
        note = "  // @#{ivar} embedded (#{type}) -- direct struct field read, no mrb_iv_get\n"
        "#{note}  r#{d} = #{box}(((#{sname}*)DATA_PTR(self))->#{ivar});\n"
      else
        "  r#{d} = mrb_iv_get(M, self, mrb_intern_cstr(M, \"@#{ivar}\"));\n"
      end
    when 'SETIV'
      ivar = a[/@(\w+)/, 1]
      # See the matching comment in IvarLayout.analyze -- not `$`-anchored,
      # a trailing "; R1:name" local-variable comment breaks that.
      s = a[/R(\d+)/, 1]
      if (type = embed_type(owner_def.owner, ivar))
        sname = struct_name(owner_def.owner)
        ops = TYPE_OPS.fetch(type)
        note = "  // @#{ivar} embedded (#{type}) -- direct struct field write, no mrb_iv_set\n"
        # Optimistic but guarded: the whole-program analysis proved every
        # *compiled* write site is this type, but it can't see writes from
        # outside this program (reflection, a future uncompiled caller) --
        # so this checks rather than blindly trusting its own analysis.
        # Not E_TYPE_ERROR: that macro hardcodes the identifier `mrb`, and
        # every generated function here names its mrb_state* parameter `M`.
        "#{note}  if (!#{ops[:check]}(r#{s})) mrb_raise(M, mrb_exc_get_id(M, mrb_intern_lit(M, \"TypeError\")), \"@#{ivar}: expected #{ops[:err]}\");\n" \
          "  ((#{sname}*)DATA_PTR(self))->#{ivar} = #{ops[:unbox]}(r#{s});\n"
      else
        "  mrb_iv_set(M, self, mrb_intern_cstr(M, \"@#{ivar}\"), r#{s});\n"
      end
    when 'ADDI'
      d = a[/^R(\d+)/, 1]
      lit = a.split(/\s+/).last
      <<~CPP
        if (mrb_integer_p(r#{d})) {
          r#{d} = mrb_fixnum_value(mrb_fixnum(r#{d}) + #{lit});
        } else {
          r#{d} = mrb_funcall(M, r#{d}, "+", 1, mrb_fixnum_value(#{lit}));
        }
      CPP
    when 'ADD'
      d = a[/^R(\d+)/, 1]
      s = a[/\(R(\d+)\)/, 1]
      <<~CPP
        if (mrb_fixnum_p(r#{d}) && mrb_fixnum_p(r#{s})) {
          r#{d} = mrb_fixnum_value(mrb_fixnum(r#{d}) + mrb_fixnum(r#{s}));
        } else {
          r#{d} = mrb_funcall(M, r#{d}, "+", 1, r#{s});
        }
      CPP
    when 'SUBI'
      d = a[/^R(\d+)/, 1]
      lit = a.split(/\s+/).last
      <<~CPP
        if (mrb_integer_p(r#{d})) {
          r#{d} = mrb_fixnum_value(mrb_fixnum(r#{d}) - #{lit});
        } else {
          r#{d} = mrb_funcall(M, r#{d}, "-", 1, mrb_fixnum_value(#{lit}));
        }
      CPP
    when 'SUB'
      d = a[/^R(\d+)/, 1]
      s = a[/\(R(\d+)\)/, 1]
      <<~CPP
        if (mrb_fixnum_p(r#{d}) && mrb_fixnum_p(r#{s})) {
          r#{d} = mrb_fixnum_value(mrb_fixnum(r#{d}) - mrb_fixnum(r#{s}));
        } else {
          r#{d} = mrb_funcall(M, r#{d}, "-", 1, r#{s});
        }
      CPP
    when 'MUL'
      # ADD/SUB's own fixnum-fastpath-else-mrb_funcall shape exactly:
      # src/vm.c's OP_ADD/OP_SUB/OP_MUL all expand from the identical
      # OP_MATH(op_name) macro (confirmed reading vm.c directly), so MUL's
      # real VM semantics differ from ADD/SUB only in which C operator and
      # which method name the slow path calls -- no separate design
      # question to answer here (unlike DIV, which deliberately skips the
      # fastpath for its own real rounding-direction reason, see below).
      d = a[/^R(\d+)/, 1]
      s = a[/\(R(\d+)\)/, 1]
      <<~CPP
        if (mrb_fixnum_p(r#{d}) && mrb_fixnum_p(r#{s})) {
          r#{d} = mrb_fixnum_value(mrb_fixnum(r#{d}) * mrb_fixnum(r#{s}));
        } else {
          r#{d} = mrb_funcall(M, r#{d}, "*", 1, r#{s});
        }
      CPP
    when 'DIV'
      # No fixnum/fixnum fastpath here (unlike ADD/SUB): real Ruby integer
      # division (`Fixnum#/`) floors toward negative infinity, not C's own
      # truncating `/` -- getting that right means duplicating mruby's own
      # `mrb_div_int` rounding, not worth it for this prototype's scope, so
      # this always goes through the real method (`mrb_funcall`), which
      # calls the same C-implemented `Integer#/` the interpreter itself
      # would -- always correct, just without OP_DIV's own in-VM fast path.
      d = a[/^R(\d+)/, 1]
      s = a[/\(R(\d+)\)/, 1]
      "  r#{d} = mrb_funcall(M, r#{d}, \"/\", 1, r#{s});\n"
    when 'EQ', 'LT', 'LE', 'GT', 'GE'
      compile_cmp(insn.op, a)
    when 'SEND0', 'SEND'
      compile_send(a, self_implicit: false, irep: irep, idx: idx, owner_def: owner_def)
    when 'SSEND0', 'SSEND'
      compile_send(a, self_implicit: true, irep: irep, idx: idx, owner_def: owner_def)
    when 'RETURN'
      r = a.empty? ? '0' : a[/^R(\d+)/, 1]
      "  return r#{r};\n"
    when 'RETNIL'
      "  return mrb_nil_value();\n"
    when 'RETFALSE'
      "  return mrb_false_value();\n"
    when 'RETTRUE'
      "  return mrb_true_value();\n"
    when 'JMP'
      # .to_i (not the raw text) on purpose: the disassembly zero-pads
      # addresses ("018"), but jump_targets/compile_method label instructions
      # by their *integer* insn.addr ("L18:") -- interpolating the raw
      # zero-padded string here produced a `goto L018;` with no matching
      # label (`L18:` was what actually got emitted), a real
      # compile-time "label not found" bug caught by building this.
      target = a.strip[/\d+/].to_i
      "  goto L#{target};\n"
    when 'JMPNOT'
      reg = a[/^R(\d+)/, 1]
      target = jmp_target_after_reg(a)
      "  if (!mrb_test(r#{reg})) goto L#{target};\n"
    when 'JMPIF'
      reg = a[/^R(\d+)/, 1]
      target = jmp_target_after_reg(a)
      "  if (mrb_test(r#{reg})) goto L#{target};\n"
    when 'JMPNIL'
      # "JMPNIL R3 024" -- OP_JMPNIL's own real shape (src/vm.c): jump if
      # r<d> is exactly nil (not merely falsy -- mrb_test/JMPNOT/JMPIF
      # already cover the falsy case; this is the dedicated opcode mrbc
      # emits for `x.nil? ? a : b` / `x || y`-shaped nil-specific tests,
      # e.g. `@opacity.nil? ? 255 : @opacity`).
      reg = a[/^R(\d+)/, 1]
      target = jmp_target_after_reg(a)
      "  if (mrb_nil_p(r#{reg})) goto L#{target};\n"
    when 'GETCONST'
      # "GETCONST R4 Integer" -- a bare top-level/lexical constant lookup.
      # The real VM (OP_GETCONST, vm.c) resolves this against the *current
      # lexical scope chain* (mrb_vm_const_get, which walks the call info
      # stack's target classes) -- info this AOT-compiled function doesn't
      # have at codegen time.
      #
      # Real bug, caught running against real code (Game::EnemyAction/
      # RGSS::Sprite): the original single-scope-from-Object codegen
      # compiled clean but raised a real runtime NameError for a same-
      # class constant (`KIND_SKILL` inside `Game::EnemyAction#skill?`,
      # really `Game::EnemyAction::KIND_SKILL`) and an enclosing-module
      # one (`Tone`/`Color`/`Rect` inside `RGSS::Sprite#tone`/`#color`/
      # `#src_rect`, really `RGSS::Tone`/`RGSS::Color`/`RGSS::Rect`) --
      # confirmed empirically against a real built mruby: mrb_const_get's
      # own const_get_nohook (src/variable.c) stops walking the ancestor
      # chain *before* ever checking Object's own table unless the search
      # started AT Object, so a class-body or enclosing-module constant is
      # invisible to a bare from-Object lookup no matter how "top-level-
      # looking" the #error-free compile made it look. Fix: try every
      # scope in the owner's own real lexical nesting chain, innermost
      # first (owner "RGSS::Sprite" -> [RGSS::Sprite, RGSS]), before
      # falling back to Object -- mirroring real Ruby's own Module.nesting
      # -based resolution for the plain "def is textually nested exactly
      # where its owner name says" shape every real case here has (no
      # `class Foo << self` reopening tricks). A bare `mrb_const_get`
      # can't just be tried-then-polled with mrb_check_error to walk this
      # chain -- a failing lookup raises via a real setjmp/longjmp,
      # jumping straight past any code that would poll mrb->exc
      # afterward (confirmed by instrumenting a debug build: a printf
      # placed right after the failing call never ran).
      # `mrb_protect_error` (mruby/error.h, a real always-available core
      # API, not gated behind the mruby-error gem) is what actually lets
      # this poll: emit_const_lookup_helper's own bc2cpp_const_try wraps
      # one scope attempt and reports success via an out-param instead of
      # choosing the fallback itself, so this call site can walk the
      # whole chain. The very last attempt, against Object, stays
      # unprotected -- a constant this chain still can't find is a real
      # bug in the SOURCE, not something to paper over (this compiler's
      # own "never silently wrong, loud is fine" philosophy).
      #
      # A top-level `def` (owner "Object") needs none of this -- the
      # original single lookup already searches exactly the right scope.
      #
      # Name extraction: `\S+` (stops at the first whitespace/tab), not a
      # `split(/\s+/, 2)` that swallows the rest of the line -- a real
      # bug, caught running against real code: a trailing "; R3:name"
      # local-variable-name comment (real shape whenever the destination
      # register is a named local, e.g. "GETCONST R3 MAX_DIGITS\t;
      # R3:d") would otherwise get interned as part of the constant name,
      # a garbage symbol lookup raising a real NameError at runtime,
      # never caught by any #error check (this compiles and links fine).
      d = a[/^R(\d+)/, 1]
      name = a[/^R\d+\s+(\S+)/, 1]
      owner_path = lexical_scope_path(owner_def.owner)
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
    when 'GETMCNST'
      # "GETMCNST R6 (R6)::Sections" -- module-qualified lookup: r<d> already
      # holds the owning module/class (from a prior GETCONST/GETMCNST in the
      # same chain, e.g. LCF::Schema::DATABASE compiles to
      # GETCONST R2 LCF; GETMCNST R2 (R2)::Schema; GETMCNST R2 (R2)::DATABASE),
      # read the named constant off of it, and overwrite the same register.
      d = a[/^R(\d+)/, 1]
      name = a[/::(\w+)\s*$/, 1]
      "  r#{d} = mrb_const_get(M, r#{d}, mrb_intern_cstr(M, \"#{name}\"));\n"
    when 'HASH'
      # "HASH R2 22" -- build a Hash from N key/value pairs held in 2N
      # consecutive registers starting at Rd (Rd,Rd+1)=(k0,v0),
      # (Rd+2,Rd+3)=(k1,v1), ...; the result overwrites Rd itself (real
      # OP_HASH semantics, src/vm.c). Every pair register still holds its
      # original value at this point (nothing here writes r<d> until the
      # very end), so reading them all before the final assignment is safe.
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
      # "ARRAY R3 2" -- build an Array from N consecutive registers starting
      # at Rd (Rd, Rd+1, ..., Rd+N-1), the result overwriting Rd itself
      # (real OP_ARRAY semantics, src/vm.c: `ary_new_from_regs(mrb, b, a)`
      # is `mrb_ary_new_from_values(mrb, b, &regs[a])`). Every source
      # register still holds its original value at this point (nothing
      # here writes r<d> until the final assignment), so copying them all
      # into a temporary contiguous C array before it is safe -- the same
      # "read everything before the final overwrite" reasoning HASH's own
      # codegen above already relies on. `r<d>..r<d+N-1>` are separate C++
      # locals here (this codegen's registers are never actually
      # contiguous in memory the way the real VM's register file is), so
      # they have to be copied into a real array rather than pointed at
      # directly the way the interpreter's own `&regs[idx]` does.
      #
      # Only the plain literal-array shape mrbc's own codegen.c emits for
      # `[e0, e1, ..., eN-1]` with no splat is modeled (confirmed against
      # codegen_array's own `else` branch, the no-splat path: `pop_n(n);
      # genop_2(s, OP_ARRAY, cursp(), n)`); mrbc emits an *unrelated*
      # 3-operand ARRAY2 (`R[a] = ary_new(R[b]..R[b+c])`, a peephole variant
      # for `local = [literal]`, MOVE-then-ARRAY collapsed into one op) and
      # separate ARYCAT/ARYPUSH/ARYSPLAT ops for a splat (`[*a, b]`) --
      # none of those are in this prototype's real scope, so this opcode's
      # own 2-operand disassembly shape (`ARRAY Rd N`) is the only one
      # handled; anything else (a 3-operand ARRAY2, or ARYCAT/ARYPUSH/
      # ARYSPLAT themselves) falls through to the generic #error below,
      # exactly LOADL's own established narrow-scope precedent for an
      # out-of-model opcode variant.
      d = a[/^R(\d+)/, 1].to_i
      n = a[/^R\d+\s+(\d+)/, 1].to_i
      if n.zero?
        "  r#{d} = mrb_ary_new(M);\n"
      else
        out = String.new
        out << "  {\n"
        out << "    mrb_value elems[] = { #{(0...n).map { |i| "r#{d + i}" }.join(', ')} };\n"
        out << "    r#{d} = mrb_ary_new_from_values(M, #{n}, elems);\n"
        out << "  }\n"
        out
      end
    when 'AREF'
      # "AREF R2 R6 0 ; R2:x" -- R[a] = R[b][c], c a plain immediate index,
      # never a register (real OP_AREF semantics, src/vm.c): when R[b]
      # isn't an Array, index 0 yields R[b] itself (a bare non-Array value
      # is treated as a one-element pseudo-array) and any other index
      # yields nil; when it is an Array, mrb_ary_ref does the real bounds-
      # checked lookup. This is exactly the destructuring assignment shape
      # `x, y, w, h = some_call(...)` compiles to -- one AREF per
      # destructured local, all reading the same call-result register.
      d, s = regs(a, 2)
      c = a[/^R\d+\s+R\d+\s+(\d+)/, 1]
      "  r#{d} = mrb_array_p(r#{s}) ? bc2cpp_ary_entry(M, r#{s}, #{c}) : (#{c} == 0 ? r#{s} : mrb_nil_value());\n"
    when 'GETIDX'
      # "GETIDX R2 (R3)" -- R[a] = R[a][R[a+1]] (real OP_GETIDX semantics,
      # src/vm.c): unlike AREF above, the index here is itself a *register*
      # (a computed/variable value), not a compile-time immediate -- the
      # real shape `recv[idx]` compiles to whenever `idx` isn't a literal
      # mrbc's own peephole can fold into AREF (e.g. `@equipment[WEAPON_SLOT]`,
      # a class constant resolved at runtime via GETCONST first, so its
      # value only exists in a register by the time this opcode runs).
      # Mirrors vm.c's own fast paths: Array with an Integer index
      # (mrb_ary_ref -- bounds-checked, negative-index-normalizing, same
      # public API AREF's own codegen above already uses), Hash
      # (mrb_hash_get, the same public API HASH's own codegen above already
      # uses), and String with an Integer/String/Range index (mrb_str_aref
      # -- see below); anything else (Range#[], or a class overriding #[])
      # falls back to the real method the interpreter itself would call --
      # never unsound, just without the in-VM fast path. `r<d>` (the
      # receiver) is read by every branch before any of them writes it, the
      # same "read before overwrite" safety AREF/HASH/ARRAY's own codegen
      # already relies on.
      #
      # GETIDX_STRING_AREF: the real vm.c's own OP_GETIDX handler
      # (3rd/mruby/src/vm.c) has a third arm this codegen used to skip
      # entirely -- String with an Integer/String/Range index (character
      # index, substring search, or a Range slice respectively) calls
      # `mrb_str_aref(mrb, str, idx, mrb_undef_value())` (the real "no
      # length argument" sentinel -- the exact form `str[idx]` compiles to,
      # as opposed to `str[idx, len]`'s own explicit third argument, a
      # different real call shape codegen.c's own OP_GETIDX emission never
      # produces at all -- confirmed directly against mrbgems/mruby-
      # compiler/core/codegen.c, GETIDX is only ever emitted for the
      # exactly-one-argument `[]` shape). `mrb_str_aref` is a real,
      # externally-linked function (see this file's own top-of-output
      # `extern "C"` forward declaration and its own comment for why a
      # plain #include of the header that declares it doesn't work).
      # Reproduces the real VM's own index-type gate exactly (`case
      # MRB_TT_INTEGER: case MRB_TT_STRING: case MRB_TT_RANGE:` -- anything
      # else, e.g. a Regexp, falls through to `default: break` there too,
      # same as this codegen's own `mrb_funcall` fallback). Does NOT
      # reproduce the real VM's own additional `ary->c != mrb->array_class`
      # (Array)/`obj_ptr(va)->c != mrb->string_class` (String) exact-class
      # guard (rejects an Array/String/Hash subclass or singleton
      # overriding `[]`) -- a real, pre-existing gap this codegen's own
      # Array/Hash arms already shared before this round touched String at
      # all, left alone here rather than fixed as a drive-by (this
      # project's own established mrblib never subclasses Array/String/
      # Hash to override `[]`, so it costs nothing in practice today, but
      # it is a real gap, not a proven-safe simplification).
      d, s = regs(a, 2)
      <<~CPP
        if (mrb_array_p(r#{d}) && mrb_integer_p(r#{s})) {
          r#{d} = bc2cpp_ary_entry(M, r#{d}, mrb_integer(r#{s}));
        } else if (mrb_hash_p(r#{d})) {
          r#{d} = mrb_hash_get(M, r#{d}, r#{s});
        } else if (mrb_string_p(r#{d}) && (mrb_integer_p(r#{s}) || mrb_string_p(r#{s}) || mrb_range_p(r#{s}))) {
          r#{d} = mrb_str_aref(M, r#{d}, r#{s}, mrb_undef_value());
        } else {
          r#{d} = mrb_funcall(M, r#{d}, "[]", 1, r#{s});
        }
      CPP
    when 'GETIDX0'
      # "GETIDX0 R7 R4[0]" -- R[a] = R[b][0] (real OP_GETIDX0 semantics,
      # src/vm.c): mrbc's own peephole for the common literal `x[0]` index
      # shape (e.g. `ev[0]` off a computed local) -- distinct instruction
      # from GETIDX above, with its own separate dest/src register pair
      # (`BB` operand shape) rather than GETIDX's in-place a/a+1 pair, and
      # no index register at all since the index is always the literal 0.
      # Same Array/Hash fast paths as GETIDX (mrb_ary_ref -- same public,
      # bounds-checked API, an empty array correctly yielding nil; a Hash
      # via mrb_hash_get with a literal Fixnum(0) key), falling back to a
      # real `[]` send with a literal 0 argument for anything else --
      # mirrors vm.c's own `getidx0_fallback` label exactly (regs[a]=recv,
      # regs[a+1]=Fixnum(0), then real :[] dispatch through the ordinary
      # SEND path).
      d, s = regs(a, 2)
      <<~CPP
        if (mrb_array_p(r#{s})) {
          r#{d} = bc2cpp_ary_entry(M, r#{s}, 0);
        } else if (mrb_hash_p(r#{s})) {
          r#{d} = mrb_hash_get(M, r#{s}, mrb_fixnum_value(0));
        } else {
          r#{d} = mrb_funcall(M, r#{s}, "[]", 1, mrb_fixnum_value(0));
        }
      CPP
    when 'SETIDX'
      # "SETIDX R4 (R5) (R6)" -- R[a][R[a+1]] = R[a+2], then R[a] = R[a+2]
      # too (real OP_SETIDX semantics, src/vm.c: the fast Array/Hash paths
      # explicitly overwrite regs[a] with the assigned value afterward --
      # `arr[i] = v` is always `v` as a Ruby expression, regardless of what
      # the underlying method itself returns). Same Array/Hash fast paths as
      # GETIDX above (mrb_ary_set/mrb_hash_set, the same public APIs ARRAY/
      # HASH's own codegen already uses), falling back to a real `[]=` send
      # for anything else -- there the assigned-back value is whatever that
      # real method returns, matching the interpreter's own SENDB-based
      # fallback exactly (no explicit regs[a]=vc override on that path
      # either, confirmed reading vm.c's own setidx_fallback).
      d, idx, val = regs(a, 3)
      <<~CPP
        if (mrb_array_p(r#{d}) && mrb_integer_p(r#{idx})) {
          mrb_ary_set(M, r#{d}, mrb_integer(r#{idx}), r#{val});
          r#{d} = r#{val};
        } else if (mrb_hash_p(r#{d})) {
          mrb_hash_set(M, r#{d}, r#{idx}, r#{val});
          r#{d} = r#{val};
        } else {
          r#{d} = mrb_funcall(M, r#{d}, "[]=", 2, r#{idx}, r#{val});
        }
      CPP
    when 'GETGV'
      # "GETGV R4 $stderr" -- R[a] = mrb_gv_get(M, sym) (real OP_GETGV
      # semantics, src/vm.c). A global variable's own symbol name already
      # spells the leading `$` (mrbc's own disassembly prints it that way,
      # matching how the real compiler interns it -- confirmed reading
      # vm.c's own mrb_gv_get(mrb, irep->syms[b]) call, no separate sigil
      # stripping/reattaching anywhere in that path), so this is exactly as
      # mechanical as GETCONST's own bare mrb_const_get call, just against
      # the flat global table instead of a lexical scope chain.
      d = a[/^R(\d+)/, 1]
      name = a[/(\$\S+)/, 1]
      "  r#{d} = mrb_gv_get(M, mrb_intern_cstr(M, \"#{name}\"));\n"
    when 'STOP'
      ''
    when 'NOP'
      # "NOP" -- OP_NOP's own real semantics (src/vm.c): `/* do nothing */
      # NEXT;`, no operands, no register read or write at all. Real code
      # hits this from a `while` loop's own condition-check jump target
      # (confirmed against real disassembly, Game::Party#include_actor?/
      # #any_alive?/#actor_by_id: mrbc's own codegen places a bare NOP
      # right after the loop-entry JMPNOT, before the loop body proper --
      # a label placeholder with nothing to actually execute). Translating
      # to a real, empty C++ statement is exactly as safe as the real
      # opcode's own do-nothing behavior -- nothing to get wrong here.
      ''
    when 'ADDILV'
      # "ADDILV Rd Rb N ; Rd:name" -- OP_ADDILV's own real shape (src/vm.c,
      # OP_MATHILV(add) macro): `a=local, b=working space, c=immediate` per
      # that macro's own comment, but the macro body itself never reads or
      # writes regs[b] at all -- only regs[a] (in place: regs[a] += c on the
      # Integer fast path, falling to a real `mrb_funcall(mid=:+, ...)` for
      # anything else, mirroring ADDI's own established fixnum-fastpath-
      # else-mrb_funcall shape exactly). `b` is confirmed dead for codegen
      # purposes by reading that macro directly -- real code hits this from
      # a `while` loop's own `i += 1`-shaped increment (confirmed against
      # real disassembly: Game::Party#include_actor?/#any_alive?/
      # #actor_by_id/#insert_item_in_bag all have one, always immediately
      # before the loop's own back-edge JMP). The one real difference from
      # ADDI's own codegen -- a real Integer-overflow bignum promotion
      # (OP_MATH_OVERFLOW_INT) instead of falling through to mrb_funcall --
      # is the same simplification ADDI's own codegen already accepts (see
      # its own comment): not worth duplicating mruby's own bignum-overflow
      # path for this prototype's scope, and C's own wraparound on overflow
      # is no worse a divergence here than ADDI's plain C `+` already is.
      # Immediate extraction is its own real, third-operand regex (`^R\d+
      # \s+R\d+\s+(-?\d+)`), NOT ADDI's own established `a.split(/\s+/).last`
      # -- a real bug, caught building this: unlike ADDI's own destination
      # register (never observed carrying a trailing named-local comment in
      # this codebase's real disassembly), ADDILV's own `a` register is BY
      # DEFINITION a real named local (the whole point of the *LV opcode
      # variant), so its trailing "; Rd:name" comment (the same shape SETIV/
      # GETCONST's own already-documented not-`$`-anchored bugs guard
      # against) is the common case, not a rare one -- `.split.last` would
      # grab "Rd:name" itself as the literal here, a C++ syntax error caught
      # immediately trying to compile this round's own toy harness (`R4:i`
      # is not valid C++), never a silently-wrong translation.
      d = a[/^R(\d+)/, 1]
      lit = a[/^R\d+\s+R\d+\s+(-?\d+)/, 1]
      <<~CPP
        if (mrb_integer_p(r#{d})) {
          r#{d} = mrb_fixnum_value(mrb_fixnum(r#{d}) + #{lit});
        } else {
          r#{d} = mrb_funcall(M, r#{d}, "+", 1, mrb_fixnum_value(#{lit}));
        }
      CPP
    when 'SUBILV'
      # OP_SUBILV -- ADDILV's own OP_MATHILV(sub) sibling, identical shape
      # (see ADDILV's own comment above for the real b-register-is-dead
      # confirmation and the accepted overflow simplification). Real code
      # hits this from a `while` loop's own countdown decrement (confirmed
      # against real disassembly, Game::Actor#set_exp's own `new_level -= 1
      # while ...` post-condition-loop shape). Same real trailing-comment
      # extraction fix as ADDILV above, same reason.
      d = a[/^R(\d+)/, 1]
      lit = a[/^R\d+\s+R\d+\s+(-?\d+)/, 1]
      <<~CPP
        if (mrb_integer_p(r#{d})) {
          r#{d} = mrb_fixnum_value(mrb_fixnum(r#{d}) - #{lit});
        } else {
          r#{d} = mrb_funcall(M, r#{d}, "-", 1, mrb_fixnum_value(#{lit}));
        }
      CPP
    when 'RANGE_INC'
      # "RANGE_INC Ra" -- R[a] = Range.new(R[a], R[a+1], exclude_end=false)
      # (real OP_RANGE_INC semantics, src/vm.c: `mrb_range_new(mrb, regs[a],
      # regs[a+1], FALSE)`, the result overwriting r<a> itself). A plain,
      # narrow, mechanical two-register-read-then-overwrite translation via
      # the real public mrb_range_new API (mruby/range.h) -- the same "read
      # both operands before the final overwrite" safety ARRAY/HASH/AREF/
      # GETIDX's own codegen above already relies on (nothing here writes
      # r<a> until the very last step). Real code hits this from an
      # inclusive Range literal (`a..b`), e.g. Game::Party#skill_invoking_item?
      # /#use_special_switch_item's own identical `(1..5).cover?(it.type)`
      # check (both real, independent call sites of the same shape --
      # `mruby-rpg2k/mrblib/game/battle_support.rb`/`game.rb`).
      d = a[/^R(\d+)/, 1].to_i
      "  r#{d} = mrb_range_new(M, r#{d}, r#{d + 1}, FALSE);\n"
    when 'RANGE_EXC'
      # OP_RANGE_EXC -- RANGE_INC's own exclude_end=TRUE sibling (real
      # OP_RANGE_EXC semantics, src/vm.c), the exact real shape a `a...b`
      # (exclusive) Range literal compiles to. Added alongside RANGE_INC
      # even though no Game::Party method itself needs it (both share the
      # identical real VM shape, differing only in the one literal exclude
      # flag -- the natural mirrored pair, matching this file's own
      # established RETFALSE/RETTRUE and LOADFALSE/LOADTRUE precedent for
      # never shipping just one half of a real opcode pair without reason).
      d = a[/^R(\d+)/, 1].to_i
      "  r#{d} = mrb_range_new(M, r#{d}, r#{d + 1}, TRUE);\n"
    when 'RETURN_BLK'
      # "RETURN_BLK Ra" -- looks block-specific by name, but its own real
      # VM semantics (src/vm.c, OP_RETURN_BLK) start with:
      # `if (!MRB_PROC_ENV_P(ci->proc) || MRB_PROC_STRICT_P(ci->proc)) goto
      # NORMAL_RETURN;` -- i.e. falls through to the exact same bare-value
      # return OP_RETURN itself uses, whenever the executing proc is an
      # ordinary (non-block) method. Every leaf irep this compiler ever
      # translates *is* exactly that: a real `def`-compiled method body
      # (mrb_proc_new_irep tags it MRB_PROC_SCOPE|MRB_PROC_STRICT --
      # confirmed reading 3rd/mruby/src/vm.c's own OP_METHOD/OP_L_METHOD
      # lambda-creation path), never a block/proc irep (those are separate
      # child ireps this whole-program TDEF-only registry never registers
      # as a leaf method body in the first place -- see build_registry's
      # own comment). So for every real call site this opcode's own
      # MRB_PROC_STRICT_P branch is unconditionally taken here -- safe to
      # translate identically to a plain RETURN. Real code hits this from a
      # `return` that isn't the method's own last statement (confirmed
      # against real disassembly: Game::Party#include_actor?/#any_alive?/
      # #actor_by_id's own early `return true`/`return a` inside a `while`
      # loop body, mrbc's own codegen choice for a non-tail-position
      # `return`, not a real block boundary).
      r = a.strip.empty? ? '0' : a[/^R(\d+)/, 1]
      "  return r#{r};\n"
    when 'RESCUE'
      # "RESCUE Ra Rb" -- OP_RESCUE's own real body (3rd/mruby/src/vm.c)
      # is exactly `R[b] = R[a].isa?(R[b])`, unconditionally: Ra already
      # holds the raised exception object (RESCUE_SUPPORT's own glue code
      # -- see recognize_rescue_regions -- is the only thing that can ever
      # put a real exception there; nothing else in this whole file emits
      # an EXCEPT this opcode could otherwise be reacting to), Rb already
      # holds a Class/Module object (always a GETCONST immediately before
      # this, per RESCUE_SUPPORT's own recognized shape) -- so this
      # translation is safe and correct wherever this opcode appears, not
      # gated on the recognizer at all (unlike EXCEPT, which the
      # recognizer's own glue is the only source of a real Ra value).
      ra, rb = a.split(/\s+/)
      d = ra[/^R(\d+)/, 1]
      s = rb[/^R(\d+)/, 1]
      "  r#{s} = mrb_bool_value(mrb_obj_is_kind_of(M, r#{d}, mrb_class_ptr(r#{s})));\n"
    when 'RAISEIF'
      # "RAISEIF Ra" -- OP_RAISEIF's own real body re-raises Ra unless
      # it's nil (a rescue clause that matched already cleared this via
      # this same opcode's own real semantics one level up -- RESCUE_
      # SUPPORT's own recognized shape only ever reaches this opcode on
      # the *non-matching* path, with Ra still holding the original
      # exception). The real opcode's own `mrb_break_p` branch (a
      # `break`/`next`/`redo` unwinding through a Ruby block) can never
      # apply to anything this whole file ever compiles -- every leaf
      # irep here is a real `def`-compiled method body, and this file has
      # no BLOCK/SENDB support at all (see this file's own top comment),
      # so Ra can never hold anything but nil or a real MRB_TT_EXCEPTION
      # object here.
      ra = a[/^R(\d+)/, 1]
      "  if (!mrb_nil_p(r#{ra})) { mrb_exc_raise(M, r#{ra}); }\n"
    when 'SUPER'
      # "SUPER Ra n=N" -- OP_SUPER's own real body (vm.c) looks up this
      # method's own name (`ci->mid`) starting one level above the
      # CURRENT class, using `self` as receiver and N explicit args
      # already sitting in R(a+1)..R(a+N) (mrbc's own codegen_super/
      # codegen_zsuper -- confirmed directly against real disassembly,
      # mruby-rpg2k/mrblib/scene/battle.rb's own `super parent` and
      # RPG2k3::Scene::Battle's own bare `super`), always followed by one
      # further register forwarding the CURRENT method's own block
      # parameter -- never read here: a compiled `_impl` function has no
      # block parameter of its own to forward in the first place (see
      # SUPER_TARGETS' own comment), and every real target this ever
      # fires for was independently checked to need none. `super_target`
      # itself is gated on the SUPER_TARGETS allowlist -- see its own
      # comment for the whole-program facts this depends on that this
      # opcode alone has no way to re-verify at codegen time.
      target_def = super_target(owner_def)
      dest, nstr = a.split(/\s+/, 2)
      d_reg = dest[/^R(\d+)/, 1]
      n = nstr && nstr[/^n=(\d+)$/, 1]
      if target_def && d_reg && n
        args = (1..n.to_i).map { |i| "r#{d_reg.to_i + i}" }
        "  r#{d_reg} = #{cpp_name(target_def.owner, target_def.name)}_impl(M, self#{args.map { |x| ", #{x}" }.join});\n"
      else
        "  #error unhandled opcode SUPER -- not in this prototype's supported subset\n"
      end
    else
      "  #error unhandled opcode #{insn.op} -- not in this prototype's supported subset\n"
    end
  end

  # EQ/LT/LE/GT/GE all share OP_CMP's own real shape (src/vm.c): a fixnum-
  # fixnum fast path compares directly and produces a real C++ bool
  # converted to mrb_value; anything else falls back to the actual method
  # (`mrb_funcall` with the operator's own name), which reaches the exact
  # same method resolution the interpreter's own fallback SEND would -- a
  # deliberate simplification for EQ specifically (the real VM short-
  # circuits object identity and a Symbol-vs-anything-else compare before
  # ever reaching this fallback), but never *unsound*: mrb_funcall("==")
  # against an unoverridden class already falls back to identity equality
  # on its own, so the observable result is identical either way.
  def compile_cmp(op, args)
    sym = { 'EQ' => '==', 'LT' => '<', 'LE' => '<=', 'GT' => '>', 'GE' => '>=' }.fetch(op)
    d = args[/^R(\d+)/, 1]
    s = args[/\(R(\d+)\)/, 1]
    <<~CPP
      if (mrb_fixnum_p(r#{d}) && mrb_fixnum_p(r#{s})) {
        r#{d} = mrb_bool_value(mrb_fixnum(r#{d}) #{sym} mrb_fixnum(r#{s}));
      } else {
        r#{d} = mrb_funcall(M, r#{d}, "#{sym}", 1, r#{s});
      }
    CPP
  end

  # KEYWORD_CALLSITE_SUPPORT: compile a `SEND`/`SSEND` call site that
  # passes keyword arguments (`n=2|nk=1` shape) into a direct `_impl`
  # call against an already-compiled callee. Returns the emitted C++ on
  # success, nil when this call site is not a supported shape (the
  # caller falls back to its honest #error).
  #
  # Why direct-call-only, never dynamic dispatch: mruby's own
  # `mrb_funcall*` family can never carry keywords (`ci->nk = 0` in
  # funcall_args_capture, 3rd/mruby/src/vm.c) -- only the VM's own
  # OP_SEND packs nk pairs into a Hash at runtime. So unlike a
  # positional call, there is no `mrb_funcall` spelling that preserves
  # keywords at all; the only sound translation is calling the
  # callee's own compiled `_impl` directly, whose signature already
  # takes each keyword as an explicit `(value, given)` parameter pair
  # (see compile_method's own entry-wrapper comment).
  #
  # Call-site layout (confirmed against real disassembly, e.g.
  # `SSEND R9 :deal_attack n=3|nk=1` with `R10/R11/R12` positionals,
  # `R13 = LOADSYM :charged`, `R14` = value): n positional registers
  # immediately after the destination, then nk (sym, value) pairs.
  # Only literal-symbol keys (a `LOADSYM :name` writing the sym
  # register, verified by backward scan in this same irep) are
  # supported -- a computed key has no static name to match against
  # the callee's keyword table, so it keeps the #error.
  #
  # Callee resolution is MONO-only with the keyword-aware gate
  # (callee compiles clean AND has a computable `keyword_arg_table`
  # covering the call site's keys, AND positional count matches the
  # callee's mandatory arity) instead of `pure_mandatory_arity?.
  # Missing keywords pass `mrb_nil_value()` + `given=0`, exactly what
  # the entry wrapper's own `mrb_undef_p` check produces for an omitted
  # keyword; required keywords missing at the call site are rejected
  # (nil return -- the interpreter would raise ArgumentError, so
  # compiling a call that drops one would be silently wrong).
  def compile_keyword_send(args, self_implicit:, irep:, idx:, owner_def:, name:, d:, n:, nk:)
    dest_reg = d.to_i
    # Keyword (sym, value) pairs sit right after the n positionals.
    kw_sym_regs = (0...nk).map { |k| dest_reg + 1 + n + k * 2 }
    kw_val_regs = (0...nk).map { |k| dest_reg + 2 + n + k * 2 }
    # Verify every key register is written by a LOADSYM with a literal
    # symbol, scanning backward from the call site in this same irep.
    kw_names = kw_sym_regs.map do |reg|
      sym = nil
      idx.downto(0) do |i|
        insn = irep.instructions[i]
        next unless insn
        # A write to this register ends the scan -- it must be LOADSYM.
        if insn.args =~ /^R#{reg}\b/
          sym = insn.op == 'LOADSYM' ? insn.args[/:(\S+)/, 1] : nil
          break
        end
      end
      break nil if sym.nil?
      sym.sub(/\A:/, '')
    end
    return nil if kw_names.nil? || kw_names.size != nk

    recv = self_implicit ? 'self' : "r#{d}"
    # MONO resolution only -- deliberately no TYPED path: a traced-
    # receiver guard's `else` branch would need a dynamic keyword
    # dispatch, which mruby's own `mrb_funcall*` family cannot express
    # (`ci->nk = 0`, see above), so any guard failure would silently
    # drop keywords. MONO needs no guard at all (exactly one def
    # exists program-wide), so it is unconditionally sound. A POLY
    # keyword call keeps the honest #error.
    target = monomorphic_target(name)
    return nil unless target&.irep
    # monomorphic_target already verified compiles_clean? -- fetch the
    # irep struct for the keyword-table/arity checks below (fetch, not
    # compiles_clean?, which takes a label).
    callee_irep = @ireps.fetch(target.irep)
    kw_table = keyword_arg_table(callee_irep)
    return nil unless kw_table
    return nil unless n == mandatory_arity(callee_irep)
    return nil unless (kw_names - kw_table.map { |k| k[:name] }).empty?
    # Every required keyword must be present at the call site --
    # otherwise the interpreter raises ArgumentError and compiling
    # the call would be silently wrong.
    required = kw_table.select { |k| k[:required] }.map { |k| k[:name] }
    return nil unless (required - kw_names).empty?
    # Same emission-eligibility guard as compile_send's own: no _impl
    # exists for an owner this run is not emitting.
    if @only_owners && !@only_owners.include?(target.owner)
      return nil unless @other_owners&.include?(target.owner)
    end
    impl = cpp_name(target.owner, target.name) + '_impl'
    argv = (1..n).map { |k| "r#{dest_reg + k}" }
    kw_args = kw_table.flat_map do |kw|
      ci = kw_names.index(kw[:name])
      if ci
        ["r#{kw_val_regs[ci]}", '1']
      else
        ['mrb_nil_value()', '0']
      end
    end
    call = "r#{d} = #{impl}(M, #{([recv] + argv + kw_args).join(', ')});"
    note = "  // MONO :#{name} -> #{target.owner}##{target.name} (keyword call), direct C++ call (no mrb_funcall)\n"
    "#{note}  #{call}\n"
  end

  def compile_send(args, self_implicit:, irep: nil, idx: nil, owner_def: nil)
    # ELEMENT_CLASS_SUPPORT: consume-and-clear. The hint is published by
    # with_element_hint for exactly the one instruction being translated
    # right now, and taking it down here (before ANY other work, including
    # the compiles_clean? probes further down that re-enter compile_method
    # for unrelated bodies) is what makes it impossible for a second,
    # unrelated call site to read a hint that was never about it.
    elem_class_hint = @elem_class_hint
    @elem_class_hint = nil
    d = args[/^R(\d+)/, 1]
    # Real bug, caught by running against real code: this charset omitted
    # `?` -- every predicate-style method name (`rpg2003?`, `key?`, `eof?`,
    # `is_a?`, `respond_to?`, ...) got silently truncated to its non-`?`
    # prefix here, so a compiled call site would `mrb_funcall` a *different,
    # usually-undefined* method name (e.g. "key" instead of "key?"), a real
    # NoMethodError at runtime that a #error-based check can never catch
    # (the generated C++ itself compiles and links fine -- it just calls the
    # wrong Ruby method). `!`-suffixed names (`empty!`, ...) were already
    # covered; `?` needed the same treatment.
    #
    # A second, materially worse real bug in this same charset, caught
    # building Game::ChipSet and confirmed independently against the real
    # generated output for every already-shipped class, not just the
    # triggering one: this charset also omitted every bitwise/unary
    # operator character (`&`, `|`, `^`, `~`, `%`, and the unary-method
    # suffix `@` for `-@`/`+@`). A call site sending one of those names
    # (`flags & DIR_BIT[dir]`, a real Integer#& send; mrbc's own
    # disassembly prints "R6\t:&\tn=1", exactly the same shape as any
    # other operator SEND) matched *nothing* after the colon, so `name`
    # came back `nil` -- silently interpolated as `""` a few lines below
    # into `mrb_funcall(M, r6, "", 1, r7)`, an empty-string method name no
    # real Ruby method ever has. That compiles and links clean (the same
    # class of bug as the `?`-omission above -- a `#error`-marker check
    # can never catch it) but raises a real NoMethodError the first time
    # it actually runs.
    #
    # Confirmed LIVE in already-shipped, already-building code, and far
    # more widespread than the one triggering case: a direct grep of the
    # real generated `rpg2k_compiled_gen.cpp` for this exact broken
    # `mrb_funcall(M, <reg>, "", ...)` shape found 41 call sites across 33
    # distinct already-registered compiled methods spanning a dozen
    # classes, not just RPG2k::Scene::ChipsetEditor's own #toggled_byte/
    # #cell_color_for -- the single most common shape by far is `%` used
    # for cursor-wraparound arithmetic (`(index + delta) % list.size`),
    # hit by RPG2k::Scene::Order#move_cursor, RPG2k::Scene::EquipMenu#
    # move_slot_cursor/#update_slots/#refresh_cand_cursor/#tick_arrows,
    # RPG2k::Scene::ItemMenu#refresh_item_cursor/#refresh_teleport_cursor/
    # #tick_arrows/#update_target/#draw_target_face, RPG2k::Scene::
    # SkillMenu's own equivalent five, RPG2k::Scene::Menu#update_command/
    # #update_actor_selection/#draw_actor_face, RPG2k::Scene::StatusMenu#
    # draw_actor_face, RPG2k::Scene::DebugMenu#cycle_mode/#move_block/
    # #move_row/#update_editor, RPG2k::Scene::SaveLoad#tick_arrows/
    # #build_face_cell, RPG2k::Scene::Base#advance_list_arrow_anim,
    # RPG2k::Window#update, Game::Screen#update_shake (a `% 256` phase
    # wrap), Game::Transition#block_shuffle_rank (`% total`), and
    # RPG2k::Scene::ChipsetEditor#draw_cursor/#move_cursor (`@idx % COLS`)
    # -- i.e. every already-shipped menu's own scrolling-cursor/blink-arrow
    # logic, plus this same `%`-for-wraparound idiom wherever else it
    # appears. The remaining two sites are `&`/`|`/`~` bitwise flag work
    # (ChipsetEditor's own #toggled_byte/#cell_color_for). Every one of
    # these methods
    # was silently generating a guaranteed-NoMethodError call the moment a
    # player actually scrolled a list, moved an equip-menu cursor, or used
    # the F9 chipset editor -- this compiler's single highest-impact bug
    # so far, precisely because the affected pattern (modulo-based cursor
    # wraparound) is the single most common idiom across every menu class
    # already shipped, not an edge case. Fixed at the root (this one
    # character class, reused by every SEND-name extraction site in this
    # file, kept in sync at each of its own three other copies above); the
    # very next regen of every already-shipped class's own generated
    # output picks up the fix automatically, the same "no hand-edit
    # needed" shape this file's own IvarLayout.join fix already
    # established. See docs/adr/0139's own follow-up for the full
    # before/after verification.
    name = args[/:([\w+\-*\/<>=!?\[\]&|^~%@]+)/, 1]
    # Real, live bug, caught running against real code (Game::Battle#
    # enemy_basic_action's own `deal_attack(b, target, 0, charged: charged)`):
    # a bare `/n=(\d+)/` only recognizes a call site's real disassembly
    # shape when it passes a small fixed count of plain positional arguments
    # ("n=3"). Two other real shapes exist in mrbc's own print_args (src/
    # codedump.c) and were silently misparsed by that narrow regex instead of
    # being rejected outright:
    #   - A keyword-argument call site ("n=3|nk=1", one Symbol/value register
    #     pair per keyword) -- src/vm.c's own OP_SEND packs those nk pairs
    #     into a real Hash (hash_new_from_regs) *at runtime*, a step this
    #     codegen never replicated at all.
    #   - A splat call site ("n=*", mrbc's own CALL_MAXARGS sentinel) -- a
    #     genuinely variable argument count this codegen has no fixed
    #     register list for.
    # Neither shape matches `/n=(\d+)/` (no digits right after "n=" for a
    # splat; the keyword pair registers are simply never looked at for a
    # keyword call), and `nil.to_i` silently evaluates to 0 -- so a splat
    # call site (`move_to(*args)`, `Class.new(*args)`, ...) used to compile
    # to a real ZERO-argument mrb_funcall, silently dropping every splatted
    # argument, and a keyword call site compiled with only its real
    # positional args, silently dropping the keyword hash entirely. Confirmed
    # live, not hypothetical, in already-shipped compiled classes: `Game::
    # Battle#enemy_basic_action`/`#enemy_fallback_attack`'s own `deal_attack(
    # ..., charged: charged)` compiled to `mrb_funcall(M, self, "deal_attack",
    # 3, r10, r11, r12)` with the `:charged`/`charged` register pair computed
    # and then silently discarded -- every charged enemy attack routed
    # through either method called the real #deal_attack with its own
    # `charged: nil` default instead of the caller's real charged state.
    # `Game::Actor#knock_out!`/`Game::Battle#inflict_state`'s own `Game::
    # States.prune(ids, table, keep: permanent_states)` silently dropped
    # `keep:`, so a real permanently-protected state (`keep.include?(id)`,
    # e.g. an innate racial trait modeled as a state) could be pruned away
    # as if no exemption list existed at all. `Game::Actor#restore_class`'s
    # own `set_level(@level, preserve_mod: false)` (a real, load-bearing
    # `false` -- the very next source line's own comment explains it's
    # deliberately different from #set_level's own default of `true`)
    # silently called with `preserve_mod: true` instead, incorrectly
    # carrying stat modifiers across a class restore. `RPG2k::Scene::
    # DebugMenu#play_animation`'s own `scene.anim_target(x, y, height: nil,
    # index: nil, flash_target: nil)` is a real MANDATORY-keyword call
    # (`RPG2k::Scene::Map#anim_target(tx, ty, height:, index:,
    # flash_target:)`, no defaults at all) -- silently dropping those three
    # used to compile a call that would raise a real ArgumentError (missing
    # keyword) at runtime, not just pass a wrong value. All six of these
    # (`Game::Actor#change_class` shares #restore_class's own `set_level`
    # bug shape too, but was already excluded from compilation for an
    # unrelated reason -- a real `.each` block later in the same method
    # body, so it never actually shipped with this bug either way) were
    # removed from `mruby-rpg2k-compiled/src/register.cxx`'s own
    # registration list as part of this fix; see that file's own comments at
    # each removed line. None of this shape is in this
    # prototype's modeled subset (the top-of-file comment already excludes
    # "keyword ... params" -- this is that same exclusion, just for a CALL
    # SITE rather than a method definition), so it gets the same treatment
    # every other unmodeled shape here does: a loud #error instead of a
    # silently wrong translation, leaving the method on the interpreter
    # (SKIP_UNSUPPORTED's own established fallback) rather than shipping a
    # call that quietly drops real arguments. SEND0/SSEND0's own
    # disassembly never prints "n=" at all (mrbc's own codedump.c, and
    # src/vm.c's OP_SEND0 hardcodes c=0) -- a real, always-0-argument call,
    # not a shape to reject, so a nil match here still means n=0, exactly
    # the same fallback value `nil.to_i` used to compute (now explicit
    # instead of incidental).
    n_match = args.match(/n=(\d+|\*)(?:\|nk=(\d+|\*))?/)
    if n_match && (n_match[1] == '*' || n_match[2])
      # Keyword-argument call site (nk>0, no splat): try devirtualizing
      # into the compiled callee's own _impl (compile_keyword_send
      # below) before falling back to the honest #error. Splat (`*`
      # anywhere) still always #errors -- no fixed register list exists
      # for it by construction.
      if n_match[1] != '*' && n_match[2] != '*' && irep && !idx.nil?
        kw_result = compile_keyword_send(args, self_implicit: self_implicit, irep: irep, idx: idx,
                                         owner_def: owner_def, name: name, d: d,
                                         n: n_match[1].to_i, nk: n_match[2].to_i)
        return kw_result if kw_result
      end
      return "  #error SEND/SSEND :#{name} has a splat and/or keyword argument list (#{n_match[0]}) -- not in this prototype's supported subset\n"
    end

    n = n_match ? n_match[1].to_i : 0
    recv = self_implicit ? 'self' : "r#{d}"
    argv = (1..n).map { |k| "r#{d.to_i + k}" }

    # LITERAL_EQQ_SUPPORT: `case x; when LITERAL ... end`'s own desugared
    # `LITERAL === x` (a `:===` SEND whose own receiver is a bare literal
    # Fixnum or Symbol, trace_eqq_literal_receiver's own comment has the
    # exact real disassembly shape this matches) devirtualizes straight
    # past ordinary MONO/POLY registry resolution and real dynamic
    # dispatch, replicating mruby's own native `Object#===`/`#==`
    # semantics directly (3rd/mruby/src/kernel.c's own `mrb_eqq_m` ->
    # 3rd/mruby/src/object.c's own `mrb_equal`) -- see
    # eqq_literal_devirt_safe?'s own comment for the full whole-program
    # soundness argument (both `:==` and `:===` have to be registry-
    # confirmed MONO-native, re-checked live every run, not just once) and
    # trace_eqq_literal_receiver's own comment for the backward-scan
    # mechanism. Deliberately runs BEFORE monomorphic_target/the ordinary
    # POLY fallback below (`:===` itself can never devirtualize through
    # either of those anyway -- monomorphic_target always refuses a
    # native-only def, its own comment explains why -- so this changes
    # nothing about their own behavior for every other name; it only ever
    # intercepts a `:===` name that would otherwise fall straight to
    # `dynamic_dispatch_line`'s own plain `mrb_funcall` at the bottom of
    # this method). `n == 1`: real `#===`/`#==` always take exactly one
    # argument (`MRB_ARGS_REQ(1)` on both native entries, 3rd/mruby/src/
    # kernel.c) -- a `:===` SEND with any other arg count than 1 isn't
    # this shape at all (never produced by real `when` desugaring, and
    # this compiler's own SEND-arg-count parsing above already guarantees
    # `n_match` matched a plain `n=1` shape to even reach here with
    # `argv.size == 1`). `irep && idx`: same "only meaningful for an
    # explicit-receiver send with real bytecode position to scan
    # backward from" gate every other backward-scan devirtualization in
    # this method already uses (never true when self_implicit is, per
    # this method's own top comment).
    if name == '===' && n == 1 && irep && idx && eqq_literal_devirt_safe?
      literal = trace_eqq_literal_receiver(irep, idx, d)
      if literal
        arg = argv.first
        case literal[:type]
        when :symbol
          # Sound with NO runtime fallback ever needed: Symbol's own real
          # `#==` is confirmed (by the very same whole-program `:==` MONO
          # check eqq_literal_devirt_safe? just ran) to still be mruby's
          # own plain, unoverridden default (`mrb_obj_equal_m`,
          # 3rd/mruby/src/symbol.c's own ROM table) -- so `mrb_equal`'s
          # own `mrb_func_basic_p(mrb, obj1, MRB_OPSYM(eq),
          # mrb_obj_equal_m)` guard (object.c) is unconditionally TRUE for
          # a Symbol receiver, meaning `mrb_equal` NEVER dispatches at
          # all: the whole call resolves entirely off its own initial
          # `mrb_obj_eq` identity/type check (`MRB_TT_SYMBOL` case:
          # `mrb_symbol(v1) == mrb_symbol(v2)`, requiring an EXACT type
          # match first) -- true iff `arg` is this exact Symbol, false for
          # literally every other value including every other type. No
          # cross-type coercion exists for Symbol the way it does for
          # Integer below, so there is nothing a runtime fallback could
          # ever catch that this doesn't already get right.
          note = "  // LITERAL === :symbol -- `:#{literal[:name]} === arg` (case/when literal), " \
                 "Object#===/Symbol#== both confirmed native/unoverridden anywhere in this program's " \
                 "own whole-program registry -- sound unconditionally, no mrb_funcall fallback ever " \
                 "needed (see eqq_literal_devirt_safe?'s own comment).\n"
          return "#{note}  r#{d} = mrb_bool_value(mrb_symbol_p(#{arg}) && " \
                 "mrb_symbol(#{arg}) == mrb_intern_cstr(M, \"#{literal[:name]}\"));\n"
        when :fixnum
          # Sound ONLY for an exactly-Integer `arg` -- `mrb_equal`'s own
          # real logic (object.c) applies a genuine Integer<->Float
          # numeric cross-comparison BEFORE ever reaching Integer's own
          # `#==` dispatch, and -- since this project's own
          # build_config.rb unconditionally includes `mruby-bigint` for
          # every build target (`conf.gem core: 'mruby-bigint'`, inside
          # the shared `rpg_maker_gems` every target calls) -- a further
          # Integer<->Bigint cross-comparison exists too (both in
          # `mrb_equal` itself under `MRB_USE_BIGINT` and, redundantly,
          # inside Integer's own real `#==`, `int_equal`, 3rd/mruby/src/
          # numeric.c's own `MRB_TT_BIGINT` case). So `5 === 5.0` (a
          # Float, real value 5.0) is real-Ruby-TRUE, not something this
          # codegen can assume FALSE from a bare type mismatch --
          # replicating that cross-type math inline would need pulling in
          # float/bigint comparison helpers this call site has no other
          # reason to reference, so instead: only the exact same-type
          # shape (`arg` is itself `MRB_TT_INTEGER`) is handled directly
          # here (matching `mrb_obj_eq`'s own fast path for an equal
          # value, and `int_equal`'s own plain `MRB_TT_INTEGER` case for a
          # differing one -- both are exact integer comparisons, no
          # coercion, so no possible override changes the answer given
          # `:==`'s own confirmed-MONO-native status); every other runtime
          # type (Float, Bigint, String, nil, ...) falls back to ordinary
          # `mrb_funcall`, deferring to the real interpreter for exactly
          # the cases this reasoning can't safely resolve alone -- the
          # identical "fixnum-fixnum fast path, mrb_funcall otherwise"
          # shape `compile_cmp`'s own EQ codegen already established
          # above, not a new pattern.
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

    # Devirtualize a `SEND :new` whose receiver is provably (GETCONST-
    # traced, right here at this exact call site -- not the ivar/argument
    # terminal sources trace_new_target also supports) one of
    # NATIVE_CONSTRUCT_TARGETS' own native DataType<T>-backed classes.
    # `self.new`/implicit-receiver `new` (self_implicit) is never this
    # shape (these three classes' own `.new` is always sent to an explicit
    # constant receiver in every real call site this covers) so it's
    # excluded outright, same as monomorphic_target's own MONO path
    # implicitly is by never matching a bare `new` name against anything
    # meaningful for self_implicit sends. `irep`/`idx` are nil exactly
    # when self_implicit is true (see this method's own two call sites),
    # so checking them here is redundant with checking self_implicit, but
    # kept explicit since trace_new_target needs both regardless.
    if name == 'new' && !self_implicit && irep && idx
      known = trace_new_target(irep, idx, d, nil, 0, nil, resolving_new: true, owner: owner_def&.owner)
      native = known && NATIVE_CONSTRUCT_TARGETS[known]
      # Exact-arity-only (see NATIVE_CONSTRUCT_TARGETS' own comment) -- a
      # call site passing a different argument count just isn't this
      # shape, falls through to ordinary POLY dynamic dispatch below like
      # any other unmodeled variant.
      if native && n == native[:arity]
        @native_construct_used << known
        # `fn`'s own real C++ signature takes native mrb_int/mrb_float
        # parameters, not mrb_value (mruby-rgss/src/lib.cxx's own comment
        # on these three functions has the full reasoning) -- unboxed
        # right here, at the call site, with the exact same mrb_as_int/
        # mrb_as_float calls that function used to make internally before
        # this change; moving them here changes nothing observable (same
        # TypeError-raising for a bad argument), it only changes which
        # side of the call spells them out.
        unbox = native[:arg_type] == :int ? 'mrb_as_int' : 'mrb_as_float'
        unboxed_argv = argv.map { |a| "#{unbox}(M, #{a})" }
        note = "  // MONO :new -> #{known}, direct native construct (mruby-rgss/src/lib.cxx's own " \
               "#{native[:fn]}) -- skips Class#new's own allocate+initialize dispatch chain entirely.\n" \
               "  // Runtime-guarded: #{known} could have been reassigned at the constant level (e.g. " \
               "`RGSS::#{known} = SomeOtherClass`) since #{native[:class_fn]}'s own class was registered " \
               "-- #{recv} is whatever this method's own existing GETCONST resolution chain above just " \
               "produced, so a reassignment there is already reflected in it; falls back to ordinary " \
               "mrb_funcall (whatever #{recv} now actually is) rather than misconstruct if it doesn't " \
               "match the real native class. #{native[:fn]}'s own parameters are native mrb_int/" \
               "mrb_float, not mrb_value, so this call site unboxes each argument register with the " \
               "same #{unbox} that function used to call internally, and passes mrb_class_ptr(#{recv}) " \
               "straight through (already computed for the guard just above -- no second, redundant " \
               "mrb_class_ptr call needed).\n"
        return "#{note}" \
               "  if (mrb_class_ptr(#{recv}) == #{native[:class_fn]}()) {\n" \
               "    r#{d} = #{native[:fn]}(M, mrb_class_ptr(#{recv}), #{unboxed_argv.join(', ')});\n" \
               "  } else {\n" \
               "    #{dynamic_dispatch_line(d, recv, name, argv)}" \
               "  }\n"
      end
    end

    # Same shape as the NATIVE_CONSTRUCT_TARGETS block just above, generalized
    # to ordinary bc2cpp-COMPILED classes (DIRECT_CONSTRUCT_TARGETS' own
    # comment has the full design writeup and the real call sites this
    # covers) -- a separate `if`, not an `elsif`/shared branch, deliberately:
    # NATIVE_CONSTRUCT_TARGETS and DIRECT_CONSTRUCT_TARGETS' own owner-name
    # sets can never overlap in practice (one is hand-written native C++
    # classes, the other real Ruby classes this compiler itself compiles a
    # body for), but keeping them as two independent, self-contained checks
    # means neither can ever accidentally shadow the other's own matching
    # logic, and the already-shipped native-construct branch above stays
    # completely untouched by this addition (a second trace_new_target call
    # here re-walks the same backward scan the block above already did when
    # `known` fell through to nil there -- a harmless, cheap re-walk of a
    # single straight-line instruction range, not a correctness concern).
    if name == 'new' && !self_implicit && irep && idx
      known = trace_new_target(irep, idx, d, nil, 0, nil, resolving_new: true, owner: owner_def&.owner)
      if known && DIRECT_CONSTRUCT_TARGETS.include?(known)
        init_def = @registry['initialize'].find { |md| md.owner == known }
        # The full four-part soundness gate DIRECT_CONSTRUCT_TARGETS' own
        # comment lays out, checked live against the real registry/ONLY_
        # OWNERS this run was actually given rather than trusted from that
        # comment alone -- a future edit to either of these two classes' own
        # source (a new `self.new`/`self.allocate`, a changed #initialize
        # shape) is caught here automatically, never silently missed.
        #
        # 1/2: no custom `def self.new`/`def self.allocate` on this exact
        # class -- the same "X.singleton" pseudo-owner every def-self.x/
        # class<<self method in this file already registers under (see
        # build_registry's own SDEF/SCLASS/unfused-DEF cases).
        no_custom_new = @registry['new'].none? { |md| md.owner == "#{known}.singleton" }
        no_custom_allocate = @registry['allocate'].none? { |md| md.owner == "#{known}.singleton" }
        # 3: #initialize's own real candidate has to be a genuine, compiling,
        # pure-mandatory-arity leaf whose arity matches THIS call site's own
        # argument count -- the identical three checks the TYPED path below
        # already applies to a class-exact candidate, reused as-is (a real,
        # differently-shaped #initialize -- e.g. Game::Picture's own
        # optional-argument shape -- must never be skipped past this way).
        init_ok = init_def&.irep && pure_mandatory_arity?(@ireps.fetch(init_def.irep)) &&
                  compiles_clean?(init_def.irep) && n == mandatory_arity(@ireps.fetch(init_def.irep))
        if no_custom_new && no_custom_allocate && init_ok
          # 4: same ONLY_OWNERS/OTHER_OWNERS emission-eligibility guard the
          # MONO/TYPED paths below already apply -- an owner this run
          # doesn't itself emit (and no other gem exposes) has no real
          # `_impl`/class-accessor symbol to link against.
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

    # NATIVE_PRIMITIVE_SENDS: devirtualize `!`/`nil?`/`is_a?`/`kind_of?`
    # straight to their real native primitive at ANY call site, entirely
    # independent of trace_new_target/TYPED's own receiver-class-guard
    # machinery -- unlike TYPED (which needs to prove the receiver's
    # *class* before it can trust a class-exact candidate), none of these
    # four need any receiver-class knowledge at all: each one's real
    # native body is exactly the same single primitive expression for
    # EVERY possible receiver, so "the name is uncontested whole-program"
    # (monomorphic_target's own registry check, reused as-is via
    # native_only_mono? below) is already the whole soundness argument,
    # with no runtime class check needed the way TYPED's own
    # `mrb_class_ptr(recv) == ...` guard is.
    #
    # monomorphic_target itself always refuses these (its own comment: a
    # native-only MONO name has no compiled `_impl` to call, and calling
    # the real native C function's raw pointer directly would leave any
    # `mrb_get_args` inside it reading a stale `mrb->c->ci` call-info
    # frame -- a real correctness bug for an ARBITRARY native method).
    # That conservatism is correct in general but overly conservative for
    # exactly these four, checked directly against the real mruby source
    # rather than assumed:
    #   - `!` (Kernel#!): 3rd/mruby/src/class.c's own `mrb_bob_not` is
    #     exactly `mrb_bool_value(!mrb_test(cv))` -- `mrb_test`
    #     (3rd/mruby/include/mruby/value.h's own `mrb_bool`,
    #     `mrb_type(o) != MRB_TT_FALSE`) is a real, always-defined macro,
    #     no `mrb_get_args` call anywhere in this body at all.
    #   - `nil?` (Kernel#nil?/NilClass#nil?): 3rd/mruby/src/kernel.c
    #     registers `mrb_false` (always `mrb_false_value()`) for Object's
    #     own `nil?`, and 3rd/mruby/src/object.c separately registers
    #     `mrb_true` (always `mrb_true_value()`) for NilClass's own
    #     `nil?` -- two distinct native C functions in real mruby, but
    #     extract_native_method_names only ever records the flat NAME
    #     "nil?" once (no owner, by design -- see that function's own
    #     comment), so the registry can't and doesn't distinguish them.
    #     Collapsing both into one expression here is still sound, not
    #     because the registry happens not to see the difference, but
    #     because both real bodies TOGETHER are exactly the single
    #     predicate `mrb_nil_p(recv)` (3rd/mruby/include/mruby/value.h:
    #     `mrb_type(o) == MRB_TT_FALSE && !mrb_fixnum(o)`, true only for
    #     the real nil value, false for every other receiver including
    #     `false` itself) -- inlining it reproduces both real native
    #     bodies' observable behavior at once, for every receiver, not
    #     just the common case.
    #   - `is_a?`/`kind_of?`: 3rd/mruby/src/kernel.c's own
    #     `mrb_obj_is_kind_of_m` (registered under both `MRB_SYM_Q(is_a)`
    #     and `MRB_SYM_Q(kind_of)`) is exactly `mrb_get_args(mrb, "c",
    #     &c); return mrb_bool_value(mrb_obj_is_kind_of(mrb, self, c));`
    #     -- `"c"` is mrb_get_args' own class/module-only format
    #     character, which raises a real TypeError for anything else
    #     BEFORE mrb_obj_is_kind_of ever runs, so the argument really is
    #     always a Class/Module by the time that call happens. Reproduced
    #     below as an explicit `mrb_class_p(arg) || mrb_module_p(arg)`
    #     runtime guard (3rd/mruby/include/mruby/value.h, both real,
    #     always-defined macros/fallback macros -- confirmed not
    #     boxing-mode-specific: value.h's own `#ifndef` guards mean the
    #     word-boxing build's own faster boxing_word.h definitions are
    #     used instead where available, value.h's plain `mrb_type(o) ==
    #     MRB_TT_CLASS`/`MRB_TT_MODULE` otherwise -- both always present
    #     either way) around the direct `mrb_obj_is_kind_of(M, recv,
    #     mrb_class_ptr(arg))` call; a non-Class/Module argument falls
    #     back to ordinary `mrb_funcall` here instead of faking the
    #     TypeError -- the exact same "loud gap over silently wrong"
    #     posture as every other unmodeled shape in this file, and the
    #     fallback raises the identical real TypeError mrb_get_args
    #     itself would have (same code path, just reached through
    #     mrb_funcall's own dispatch instead of straight-line here).
    #     `mrb_class_ptr`/`mrb_obj_is_kind_of`/`mrb_bool_value` are not
    #     new to this generated output either -- OP_RESCUE's own
    #     translation above (`when 'RESCUE'`) already emits the identical
    #     `mrb_bool_value(mrb_obj_is_kind_of(M, r#{d}, mrb_class_ptr(r#{s})))`
    #     unconditionally (safe there with no guard at all only because
    #     RESCUE_SUPPORT's own recognized shape already guarantees Rb is
    #     a Class/Module via a GETCONST immediately before it -- a
    #     narrower, call-site-specific guarantee than the general
    #     `is_a?`/`kind_of?` case here can rely on, hence the explicit
    #     runtime guard added instead).
    #   - `equal?` (Kernel#equal?/BasicObject#equal?): 3rd/mruby/src/
    #     class.c's own `mrb_obj_equal_m` is exactly `mrb_get_arg1` (this
    #     call site's own `argv.first`, already extracted) then
    #     `mrb_bool_value(mrb_obj_equal(mrb, self, arg))` --
    #     `mrb_obj_equal` is a real, public `MRB_API` (mruby.h), no struct
    #     cast, safe for any receiver/argument pair (identity comparison,
    #     `mrb_obj_eq` underneath). Also confirmed genuinely name-
    #     uncontested for real via a direct grep of every mrb_define_*/
    #     MRB_MT_ENTRY registration across this project's own NATIVE_SRCS
    #     and mrblib -- `equal?` has exactly one native registration
    #     (class.c's own Kernel-level one) and no bytecode override
    #     anywhere.
    #   - `class` (Kernel#class): 3rd/mruby/src/kernel.c's own
    #     `mrb_obj_class_m` is exactly `mrb_obj_value(mrb_obj_class(mrb,
    #     self))` -- `mrb_obj_class` is a real, public `MRB_API`, safe for
    #     any receiver (immediate or heap-allocated alike, no struct
    #     cast).
    #   - `object_id` (Kernel#object_id): 3rd/mruby/src/kernel.c's own
    #     `mrb_obj_id_m` is exactly `mrb_fixnum_value(mrb_obj_id(self))`
    #     -- `mrb_obj_id` is a real, public `MRB_API`, boxing-mode-generic
    #     (its own body branches on MRB_NAN_BOXING/MRB_WORD_BOXING/
    #     MRB_NO_BOXING internally, never a struct cast).
    #   - `keys` (Hash#keys): 3rd/mruby/src/hash.c's own `mrb_hash_keys`
    #     IS the whole native body (registered directly, no `_m` wrapper)
    #     -- also a real, public `MRB_API` (mruby/hash.h), but UNLIKE the
    #     three above it is Hash-specific: its own first line,
    #     `mrb_hash_ptr(hash)`, is an unchecked `(struct RHash*)(mrb_ptr(v))`
    #     cast with no type check inside it at all -- see
    #     compile_native_primitive_send's own KEYS_TYPE_TAG_GUARD comment
    #     for why this one, alone among the names here, needs a real
    #     runtime `mrb_hash_p` guard (an RBasic-derived-struct type-tag
    #     check, the same *kind* of check `mrb_class_p`/`mrb_module_p`
    #     above already are) before the direct call, falling back to
    #     ordinary `mrb_funcall` otherwise.
    #   - `to_s`: the one entry here that ISN'T "one native implementation,
    #     whole-program uncontested" -- native_only_mono? only ever proves
    #     the second half (no bytecode override anywhere), never the
    #     first, and `to_s` is real, live proof they're different claims:
    #     a direct grep across 3rd/mruby/src finds `mrb_ary_to_s` (Array),
    #     `mrb_str_to_s` (String), `mrb_hash_to_s` (Hash), `int_to_s`
    #     (Integer), `flo_to_s` (Float), `range_to_s` (Range), `mrb_mod_
    #     to_s` (Module/Class), and `mrb_any_to_s` (Kernel's own default,
    #     inherited by everything else) -- eight distinct native bodies
    #     the registry's `'<native>'` marker still collapses into one
    #     entry. See compile_native_primitive_send's own TO_S_TYPE_TAG_
    #     DISPATCH comment for the full per-type accounting -- only
    #     String/Integer are handled directly there (both individually
    #     verified side-effect-free by reading their real bodies, not
    #     assumed from being native-registered), with Array/Hash
    #     deliberately excluded despite having a single named
    #     implementation each: both mutate `mrb->c->ci->mid` as their own
    #     first line, real VM call-frame state a direct call from here
    #     would silently corrupt rather than merely risk a stale read.
    #     Every other tag -- Float/Range/Class-ish included -- falls
    #     through to the same `default: mrb_funcall` case, exactly like a
    #     tag this switch never heard of.
    #   - `length`: same shape as `to_s` -- `mrb_ary_size`/`mrb_str_size`/
    #     `mrb_hash_size_m` (Array/String/Hash) collapsed into one entry.
    #     Array and Hash handled directly (see compile_native_primitive_
    #     send's own LENGTH_TYPE_TAG_DISPATCH comment); String excluded
    #     because its own real body reads a macro (`RSTRING_CHAR_LEN`)
    #     defined only inside string.c itself, never in a public header,
    #     with two different real bodies gated on this project's own
    #     `MRB_UTF8_STRING` build flag -- reproducing it here would be a
    #     silent, unstated coupling to that flag's current (disabled)
    #     value rather than a proven-safe simplification.
    #   - `first`: `mrb_ary_first` (Array, optional-arg form) vs
    #     `range_beg` (Range, real separate ARGS_NONE-only registration).
    #     Only Range is handled directly -- see compile_native_primitive_
    #     send's own FIRST_TYPE_TAG_DISPATCH comment for why Array is
    #     excluded despite having a single real implementation: its own
    #     body reads `mrb_get_argc(mrb)` to pick between its two real
    #     behaviors, which would read the WRONG call frame's argument
    #     count if called directly from here.
    #   - `dup`: exactly two real native registrations found (confirmed
    #     via a full grep across every native source this project's own
    #     closed world can see, not just 3rd/mruby/src) -- `mrb_obj_dup`
    #     (Kernel's own default, a real public `MRB_API`, safe and
    #     correct for literally any receiver except a Class/Module/
    #     singleton-class instance) and `mrb_mod_dup` (Module's own
    #     override for that one case -- static, but its three-line body
    #     is reproduced directly). See compile_native_primitive_send's own
    #     DUP_TYPE_TAG_DISPATCH comment -- the only entry in this whole
    #     table with no `mrb_funcall` fallback arm at all, because there
    #     is no third real implementation left to miss.
    #
    # Deliberately excludes `respond_to?` (also POLY-native, also a
    # high-count name): real `Kernel#respond_to?`
    # (3rd/mruby/src/kernel.c's own `obj_respond_to`) takes an optional
    # `include_private` argument and falls back to a real
    # `respond_to_missing?` method call when the name isn't found --
    # `mrb_respond_to()`, the obvious native helper, does neither, so
    # substituting it would be a silent behavior change. Left as
    # ordinary POLY `mrb_funcall`, exactly like today; no entry for it
    # below.
    if (expected_n = NATIVE_PRIMITIVE_SEND_ARITY[name]) && n == expected_n && native_only_mono?(name)
      return compile_native_primitive_send(name, d, recv, argv)
    end

    target = monomorphic_target(name)
    # A monomorphic *name* is still only safe to devirtualize if its one
    # real definition fits this prototype's pure-mandatory-or-optional-args
    # calling convention -- see pure_mandatory_or_optional_arity?'s own
    # comment (widened from a pure-mandatory-only check to also cover
    # CALLSITE_OPTIONAL_ARG_SUPPORT; the original pure-mandatory bug this
    # replaced is unchanged, caught by running against real code, not a
    # hypothetical).
    target = nil if target && !pure_mandatory_or_optional_arity?(@ireps.fetch(target.irep))
    # ...and if the call site's own argument count actually matches that
    # target's real mandatory arity. Real, pre-existing bug (present before
    # this round's own changes too, confirmed against a true before/after):
    # a bytecode-only registry has no visibility into a same-named NATIVE
    # method (see extract_native_method_names's own comment) -- run this
    # diagnostic without NATIVE_SRCS (as this project's own established
    # 421-error baseline measurement always has) and `:repeat?` looks MONO
    # (only Game::MoveRoute#repeat?, a real 0-arg getter, is bytecode-
    # visible), even though `Input.repeat?(key)` -- a real native 1-arg
    # method on a different class entirely -- sends the very same bare name
    # with 1 argument all over mruby-rpg2k/mrblib's own scene code. Every
    # one of those call sites used to devirtualize straight into
    # `Game__MoveRoute_repeat__impl(M, recv, key)`, a real arity mismatch
    # against that function's own 0-argument signature -- a g++ compile
    # error, not a hypothetical (120 real occurrences in this project's own
    # unrestricted, no-NATIVE_SRCS diagnostic output). Real gem builds
    # always pass NATIVE_SRCS (mrbgem.rake), which already flips a true
    # collision like this to POLY and avoids the bug that way -- but the
    # arg-count check here is a strictly cheaper, always-correct second
    # line of defense that needs no NATIVE_SRCS input at all: a call site's
    # own argument count is real, load-bearing data already sitting right
    # here, and simply never matches a genuinely different method's real
    # arity by construction, whatever its name happens to collide with.
    # CALLSITE_OPTIONAL_ARG_SUPPORT: a real optional-argument target accepts
    # any call-site argument count in [mandatory_arity, mandatory_arity +
    # optional_arity], not just an exact match -- the pure-mandatory case
    # (optional_arity == 0) collapses back to the original exact-match check
    # unchanged, so this is a strict widening, never a behavior change for
    # any target this file already devirtualized before.
    target = nil if target && !n.between?(mandatory_arity(@ireps.fetch(target.irep)),
                                           mandatory_arity(@ireps.fetch(target.irep)) + optional_arity(@ireps.fetch(target.irep)))
    # Name-based devirtualization failed (still POLY by name) -- try a
    # call-site-specific fallback: THIS receiver, traced backward through
    # the same straight-line method body, might still be provably a fresh
    # instance of one exact class (trace_new_target's own comment). Never a
    # superclass/MRO walk -- an exact owner match only, so a method this
    # class inherits rather than defines itself still safely misses here
    # and falls through to ordinary dynamic dispatch, same as today.
    #
    # Three real sources feed the same trace now, not just a fresh
    # same-body `.new`: a GETIV of an ivar ClassLayout already proved
    # always holds one exact class (`@state.foo`), or an opaque incoming
    # argument a real ClassAnnotations comment names. The first is a hard
    # Ruby-semantics guarantee (`.new` never allocates a subclass in
    # disguise); the other two are real whole-program facts but not a
    # *proof* the same way -- an ivar this run never sees written from
    # outside the compiled set, or an annotation that's simply wrong. So
    # every hit through this path (not just the two newer ones) gets a
    # real runtime `mrb_obj_class` check before the direct call, falling
    # back to ordinary `mrb_funcall` if it doesn't match -- strictly
    # *safer* than the name-only MONO path above, which trusts the
    # registry with no runtime check at all. A guard on the fresh-`.new`
    # case too costs nothing (it's simply always true there) and means
    # every future extension to trace_new_target's own reach inherits the
    # same safety net for free.
    typed = false
    via_element = false
    ivar_accessor_target = nil
    known_class = nil
    if target.nil? && !self_implicit && irep && idx
      cur_enter = irep.instructions.find { |i| i.op == 'ENTER' }
      cur_mand = cur_enter ? cur_enter.args.split(':').first.to_i : 0
      cur_arg_classes = owner_def && @class_annotations[irep.label]&.args
      ivar_classes = owner_def && @class_layout[owner_def.owner]
      # CHAINED_ACCESSOR_SUPPORT: `@class_layout` (the full owner -> ivar-
      # hint table, not just this call site's own already-sliced
      # `ivar_classes`) and `@registry` let this same TYPED path also
      # devirtualize a multi-level accessor chain (`@state.screen.foo`),
      # not just a single-level GETIV/`.new`/ARRAY hit -- see
      # trace_new_target's own top comment for the full mechanism. Both
      # are already real CodeGen instance state (`initialize`, above), no
      # new plumbing needed to reach them from here.
      known_class = trace_new_target(irep, idx, d, ivar_classes, cur_mand, cur_arg_classes, owner: owner_def&.owner,
                                      class_layout: @class_layout, registry: @registry)
    end
    # ELEMENT_CLASS_SUPPORT: the same TYPED/IVAR_ACCESSOR resolution, fed
    # by a fact the backward scan above structurally cannot reach. Inside
    # an inlined block body the receiver is the loop-element register,
    # which no instruction in that body ever writes (the EMITTER binds it,
    # right outside the translated instruction stream), so trace_new_target
    # has nothing to find -- and in fact never even runs there, because a
    # block body is compiled with `idx` nil (see compile_block_body_insn's
    # own delegation). The hint published by with_element_hint carries
    # exactly the missing piece: "this receiver is element N of an array
    # whose element class is X".
    #
    # Placed AFTER the ordinary trace on purpose, as a strict fallback:
    # `known_class` is only ever nil here (the two sources are mutually
    # exclusive in practice -- one only fires outside a block body, the
    # other only inside), but ordering it this way means the pre-existing
    # path keeps priority by construction rather than by coincidence, so
    # nothing about a non-block call site can change.
    #
    # Everything downstream is shared verbatim with the TYPED path: the
    # exact-owner registry match, the pure-mandatory/compiles_clean?/
    # arity guards, the ONLY_OWNERS emission gate, and -- the part that
    # matters for soundness -- the real runtime `mrb_class_ptr(...) ==
    # mrb_obj_class(M, recv)` check with an `mrb_funcall` fallback. A
    # wrong element fact can therefore only ever cost one failed pointer
    # comparison, exactly like a wrong ivar-class hint.
    if target.nil? && !self_implicit && known_class.nil? && elem_class_hint
      known_class = elem_class_hint
      via_element = true
    end
    if target.nil? && !self_implicit && known_class
      candidate = @registry[name]&.find { |md| md.owner == known_class }
      # Same two guards as the MONO path above (its own comments have the
      # real bugs both catch, e.g. Game::State#set_parallax/
      # #set_screen_transition/#show_picture/#erase_picture -- all four
      # real TYPED-path arity mismatches this exact check fixed, caught
      # building Game::Screen's own compiled target): a class-exact
      # candidate still isn't safe to call directly unless its own body
      # actually compiles AND the call site's argument count matches its
      # real mandatory arity.
      if candidate&.irep && pure_mandatory_or_optional_arity?(@ireps.fetch(candidate.irep)) &&
         compiles_clean?(candidate.irep) &&
         n.between?(mandatory_arity(@ireps.fetch(candidate.irep)),
                    mandatory_arity(@ireps.fetch(candidate.irep)) + optional_arity(@ireps.fetch(candidate.irep)))
        target = candidate
        typed = true
      elsif candidate&.kind == :ivar_accessor &&
            n == (name.end_with?('=') ? 1 : 0)
        # IVAR_ACCESSOR_DEVIRT: `candidate` has no `.irep` at all (never
        # will -- build_registry's own attr_reader/writer/accessor case
        # registers it that way on purpose, see MethodDef's own `kind`
        # comment), so it can never satisfy the ordinary TYPED branch
        # just above -- an attr_reader/writer/accessor name is *always*
        # POLY-native by the existing MONO/TYPED paths' own standards,
        # regardless of how many real classes happen to define it. This
        # is a real, separate devirtualization: not "call this class's
        # own compiled body" (there is none), but "this class's own
        # accessor is *provably* a bare mrb_iv_get/mrb_iv_set against
        # the ordinary dynamic iv_tbl" (MethodDef's own `kind` comment
        # has the real 3rd/mruby/src/class.c citation) -- safe to inline
        # directly, runtime-guarded exactly like TYPED above, with no
        # `_impl` function involved at all. Arity here is exactly 0 for
        # a getter, exactly 1 for a setter (`name.end_with?('=')`) --
        # `mandatory_arity`/`pure_mandatory_arity?` don't apply (there is
        # no irep to ask), but a real attr_reader/writer call site can
        # never have any other shape, so this is the complete, correct
        # check on its own, not an approximation.
        ivar_accessor_target = candidate
      end
    end
    # A monomorphic target whose *owner* is being filtered out of this run's
    # emitted output (ONLY_OWNERS) has no _impl function in the generated
    # file at all -- a real bug, caught wiring up the first real caller
    # (docs/adr/0139): LCF::File#to_lcf's own devirtualized calls to
    # LCF.write_ber/LCF.binstr (owner "LCF", not one of the LCF::File-family
    # classes actually being emitted) compiled clean but referenced two
    # functions this run would never define, an undefined-reference link
    # failure waiting to happen. Falling back to ordinary dynamic dispatch
    # here is always safe (just slower) -- the same fallback an unmodeled
    # opcode or a bad arity already gets. `@other_owners` is the one
    # exception: an owner this run explicitly trusts *another* gem's own
    # run to compile and expose non-static (see emit_decls_header) -- a
    # real, externally-linked function the final link will resolve, not a
    # guess.
    if target && @only_owners && !@only_owners.include?(target.owner)
      target = nil unless @other_owners&.include?(target.owner)
    end

    if target
      impl = cpp_name(target.owner, target.name) + '_impl'
      # NATIVE_ARG_TARGETS' own call-site half: `impl`'s own real signature
      # (compile_method, above) already boxes any native-typed parameter
      # right back into an mrb_value as its first statement, so passing an
      # already-boxed mrb_value straight through here as before would be a
      # real type mismatch (a g++ compile error, since C++ has no implicit
      # mrb_value -> mrb_int/mrb_sym conversion) the moment `target` is one
      # of these methods. `call_argv` unboxes each position that needs it
      # right here at the call site instead -- the exact same relocation
      # (callee's own internal coercion moved to the caller) the just-
      # merged Rect/Color/Tone round already established for
      # NATIVE_CONSTRUCT_TARGETS' own direct-construct path, just generalized
      # from a hardcoded native constructor to an ordinary devirtualized
      # `_impl` call. `mrb_as_int`/`mrb_obj_to_sym` are the exact same
      # coercions `mrb_get_args`'s own "i"/"n" format characters use
      # internally (see compile_method's own entry-wrapper comment) --
      # identical TypeError-raising for a genuinely wrong-typed argument,
      # `mrb_state* M` has no notion of a calling-frame boundary to cross,
      # so this changes nothing observable versus reaching the same
      # coercion through an ordinary mrb_funcall-dispatched call into
      # `target`'s own entry wrapper. Wraps whatever expression `argv`
      # already holds at this position (a bare register, or itself the
      # result of another expression -- e.g. Game::Actor#change_mp's own
      # real `-weapon_sp_cost` call site), never assumes a bare register
      # name. `target.irep`'s own mandatory arity is now only ever a LOWER
      # bound on `argv.size` (checked above, both for the MONO and TYPED
      # paths -- CALLSITE_OPTIONAL_ARG_SUPPORT widened the exact-match guard
      # to a range), so `native_arg_types` is asked for exactly the target's
      # own mandatory-position count -- NATIVE_ARG_TARGETS never names an
      # optional-arg method (see that table's own comment), so every
      # position at or past `t_mand` always stays plain `mrb_value` here
      # regardless; passing `t_mand` rather than `argv.size` just makes that
      # explicit instead of relying on `call_types[i]` reading past its own
      # array bounds (nil either way, but not by coincidence).
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
      # CALLSITE_OPTIONAL_ARG_SUPPORT: `impl`'s own real signature (see
      # compile_method's own `arg_params << 'mrb_int bc2cpp_given_opt' if
      # opt.positive?`) always has room for the target's FULL optional
      # count, whether or not this exact call site supplied all of them --
      # so a call site that only gave some of them still needs one real
      # placeholder mrb_value per omitted trailing optional, plus the
      # target's own `bc2cpp_given_opt` figure as a trailing integer
      # literal. `mrb_nil_value()` is the identical placeholder
      # compile_method's own entry wrapper already initializes an omitted
      # optional's out-param to (see its own comment: never read before the
      # jump table's own default-value code overwrites it) -- reusing it
      # here keeps the devirtualized direct-call path and the ordinary
      # mrb_funcall-through-entry-wrapper path observably identical. The
      # given-count is `argv.size - t_mand` rather than a runtime
      # `mrb_get_argc` call because the call site's own real argument count
      # is already known statically here, unlike inside the entry wrapper.
      if t_opt.positive?
        call_argv += Array.new(t_mand + t_opt - argv.size, 'mrb_nil_value()')
        call_argv << (argv.size - t_mand).to_s
      end
      native_positions = call_types.each_index.select { |i| call_types[i] }.map { |i| i + 1 }
      native_note = native_positions.empty? ? '' : " (position#{'s' unless native_positions.one?} " \
                                                    "#{native_positions.join(', ')} unboxed here to match " \
                                                    "#{impl}'s own native argument type)"
      if typed
        check = "mrb_class_ptr(#{const_chain_value_expr(target.owner)}) == mrb_obj_class(M, #{recv})"
        # ELEMENT_CLASS_SUPPORT: same codegen, different provenance -- the
        # tag says which fact proved the receiver so a reader of the
        # generated file can tell an ordinary traced receiver from an
        # inlined-loop element without re-deriving it.
        kind = via_element ? 'ELEMENT' : 'TYPED'
        traced_note = via_element ? "inlined block element of Array<#{target.owner}>" : "receiver traced to #{target.owner}"
        note = "  // #{kind} :#{name} -> #{target.owner}##{target.name} (#{traced_note}), " \
               "runtime-class-checked direct C++ call, mrb_funcall fallback#{native_note}\n"
        "#{note}  if (#{check}) {\n" \
          "    r#{d} = #{impl}(M, #{([recv] + call_argv).join(', ')});\n" \
          "  } else {\n" \
          "    #{dynamic_dispatch_line(d, recv, name, argv)}" \
          "  }\n"
      else
        note = "  // MONO :#{name} -> #{target.owner}##{target.name}, direct C++ call (no mrb_funcall)" \
               "#{native_note}\n"
        "#{note}  r#{d} = #{impl}(M, #{([recv] + call_argv).join(', ')});\n"
      end
    elsif ivar_accessor_target
      # IVAR_ACCESSOR_DEVIRT's own codegen -- see the `elsif candidate&.kind
      # == :ivar_accessor` branch above for the full soundness writeup.
      # Runtime-guarded the same way TYPED is (a wrong static trace only
      # ever costs a missed optimization, never a wrong answer): `recv`'s
      # real runtime class might still differ from `known_class` (a
      # subclass, a reassigned constant since gem-init, ...), so this
      # checks before ever touching iv_tbl directly, falling back to
      # ordinary `mrb_funcall` (which correctly dispatches to whatever
      # `name` actually resolves to on the real receiver) otherwise.
      owner = ivar_accessor_target.owner
      check = "mrb_class_ptr(#{const_chain_value_expr(owner)}) == mrb_obj_class(M, #{recv})"
      # ELEMENT_CLASS_SUPPORT: see the TYPED branch above -- same tag, same
      # reason, so both provenances stay greppable in generated output.
      traced_note = via_element ? "inlined block element of Array<#{owner}>" : "receiver traced to #{owner}"
      if name.end_with?('=')
        ivar = name[0..-2]
        val = argv.first
        note = "  // IVAR_ACCESSOR#{via_element ? '/ELEMENT' : ''} :#{name} -> #{owner}#@#{ivar} (#{traced_note}), " \
               "attr_writer devirtualized to a direct mrb_iv_set (no _impl, no mrb_funcall) -- see " \
               "MethodDef's own kind: :ivar_accessor comment for the real 3rd/mruby/src/class.c " \
               "citation this reproduces exactly (attr_writer's own mrb_iv_set then returning the " \
               "assigned value, never the ivar read back).\n"
        "#{note}  if (#{check}) {\n" \
          "    mrb_iv_set(M, #{recv}, mrb_intern_cstr(M, \"@#{ivar}\"), #{val});\n" \
          "    r#{d} = #{val};\n" \
          "  } else {\n" \
          "    #{dynamic_dispatch_line(d, recv, name, argv)}" \
          "  }\n"
      else
        note = "  // IVAR_ACCESSOR#{via_element ? '/ELEMENT' : ''} :#{name} -> #{owner}#@#{name} (#{traced_note}), " \
               "attr_reader devirtualized to a direct mrb_iv_get (no _impl, no mrb_funcall) -- see " \
               "MethodDef's own kind: :ivar_accessor comment for the real 3rd/mruby/src/class.c " \
               "citation this reproduces exactly.\n"
        "#{note}  if (#{check}) {\n" \
          "    r#{d} = mrb_iv_get(M, #{recv}, mrb_intern_cstr(M, \"@#{name}\"));\n" \
          "  } else {\n" \
          "    #{dynamic_dispatch_line(d, recv, name, argv)}" \
          "  }\n"
      end
    else
      note = "  // POLY :#{name} -- real dynamic dispatch, receiver's runtime class decides\n"
      "#{note}  #{dynamic_dispatch_line(d, recv, name, argv)}"
    end
  end

  # `Owner::Path` -> a real, chained `mrb_const_get` mrb_value expression
  # for that class object -- the exact same per-segment lookup GETCONST/
  # GETMCNST codegen already does (mrb_class_get_under has no built-in
  # "::"-path parsing of its own to delegate to instead), just built as
  # one C++ expression rather than emitted as its own sequence of
  # instructions. Only ever used inside a runtime guard condition, so
  # re-resolving the constant on every call (no caching) is the same
  # already-accepted tradeoff GETCONST's own codegen makes.
  #
  # Follow-up (docs/adr/0139: ".singleton owner support"): uses
  # lexical_scope_path (not a bare `owner.split('::')`) for the same reason
  # GETCONST's own owner-scope-first codegen does -- see that helper's own
  # comment for the real bug this avoids. Not currently reachable with a
  # `.singleton`-suffixed `owner` in practice (this is only ever called
  # with a TYPED-path `target.owner`, and `target.owner` here can only come
  # from `trace_new_target`'s own `known_class` -- a fresh `.new`, an ivar
  # ClassLayout hint, or a ClassAnnotations comment, none of which ever
  # name a `.singleton` pseudo-owner, confirmed by this same follow-up's
  # own registry audit), but hardened here anyway rather than left relying
  # on that invariant holding forever elsewhere.
  def const_chain_value_expr(owner)
    lexical_scope_path(owner).reduce('mrb_obj_value(M->object_class)') do |expr, seg|
      "mrb_const_get(M, #{expr}, mrb_intern_cstr(M, \"#{seg}\"))"
    end
  end

  def dynamic_dispatch_line(d, recv, name, argv)
    if argv.empty?
      "r#{d} = mrb_funcall(M, #{recv}, \"#{name}\", 0);\n"
    else
      "r#{d} = mrb_funcall(M, #{recv}, \"#{name}\", #{argv.size}, #{argv.join(', ')});\n"
    end
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
  registry, superclass_of, container_constants = build_registry(ireps, root_label)

  # NATIVE_SRCS: shell-word-separated list of C/C++ source files (e.g.
  # mruby-rgss/src/*.cxx) to scan for mrb_define_method-family call sites --
  # see extract_native_method_names's own comment. Optional: omitting it
  # just means the registry stays exactly as unsound as it always was with
  # respect to that native gem, same as before this existed.
  if ENV['NATIVE_SRCS']
    native_paths = Shellwords.split(ENV['NATIVE_SRCS'])
    native_names = extract_native_method_names(native_paths)
    flipped = native_names.select { |n| registry.key?(n) && registry[n].size == 1 }
    native_names.each do |name|
      registry[name] << MethodDef.new(name: name, owner: '<native>', irep: nil, visibility: :public)
    end
    warn "== native method names (#{native_names.size} from NATIVE_SRCS, #{flipped.size} flipped a MONO name to POLY) =="
    flipped.sort.each { |n| warn "  FLIP :#{n}" }
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

  ivar_layout = IvarLayout.analyze(ireps, registry, arg_types, annotations)
  warn ''
  warn '== ivar embedding =='
  if ivar_layout.empty?
    warn '  (none embeddable)'
  else
    ivar_layout.each do |klass, ivars|
      ivars.each { |name, type| warn "  EMBED  #{klass}#@#{name}  (#{type})" }
    end
  end

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

  # ANNOTATED_ARRAY_RETURN_THREADING: the exact same MONO-keyed `-> Array`
  # lookup CodeGen#annotated_array_return performs (see its own comment for
  # the full soundness argument -- one real irep per name, so a magic
  # comment on it can only ever speak for a call site nothing else in the
  # whole program could also be reaching), rebuilt here as a bare lambda
  # because CodeGen itself is not constructed yet at this point in the
  # driver (ClassLayout.analyze, like every other whole-program analysis
  # above it, runs before codegen starts) -- `annotations` (Annotations.
  # extract's own result, already computed above) and `registry` are both
  # already in scope, so this is nothing but the identical lookup CodeGen's
  # own instance method performs against its own `@annotations`/`@registry`
  # ivars, duplicated here rather than shared only because no shared
  # instance exists yet to call it on.
  annotated_array_return = lambda do |name|
    defs = registry[name]
    next false unless defs && defs.size == 1 && defs.first.irep

    annotations[defs.first.irep]&.ret == :array
  end
  class_layout_raw = ClassLayout.analyze(ireps, registry, class_annotations, container_constants, annotated_array_return)
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

  # ELEMENT_CLASS_SUPPORT: the element dimension of the same ivar facts
  # (see ArrayElementLayout's own header). Runs after ClassLayout because
  # it only ever sweeps ivars ClassLayout has already proved hold an
  # `Array`, and after ClassAnnotations because an incoming-argument class
  # hint is one of the real terminals its value tracer bottoms out at.
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

  element_raw = ArrayElementLayout.analyze(ireps, registry, class_layout, class_annotations,
                                           element_annotations, superclass_of)
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

  element_unknowns = ArrayElementLayout.unknowns(element_raw)
  warn ''
  warn '== array-element candidates (proven-Array ivar, element class poisoned to unknown) =='
  if element_unknowns.empty?
    warn '  (none)'
  else
    element_unknowns.each { |n| warn "  ELEM_CANDIDATE  #{n}" }
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

  # `annotations` (computed above, previously fed only to IvarLayout.analyze)
  # also now drives NATIVE_ARG_TARGETS' own native-argument calling
  # convention -- see that constant's own comment.
  gen = CodeGen.new(ireps, registry, ivar_layout, class_layout, class_annotations, annotations, superclass_of,
                    element_layout, element_annotations, container_constants)
  # ONLY_OWNERS narrows *emitted* code to specific classes (comma-separated,
  # e.g. "LCF::File,LCF::Database") without narrowing the closed-world
  # registry itself -- srcs above should still be the whole program (or at
  # least everything that could define a colliding method name); see
  # compile_all's own comment for why that distinction is load-bearing.
  only_owners = ENV['ONLY_OWNERS']&.split(',')
  # OTHER_OWNERS: classes this run trusts *another* gem's own bc2cpp run to
  # compile and expose (paired with OTHER_DECLS_HEADER below) -- see
  # compile_send's own comment on why a devirtualized call to one of these
  # is safe to emit despite not being compiled in this run at all.
  other_owners = ENV['OTHER_OWNERS']&.split(',')
  compiled = gen.compile_all(only_owners: only_owners, other_owners: other_owners)
  compiled += gen.emit_synthesized_accessors(only_owners: only_owners)

  # SKIP_UNSUPPORTED=1 drops any method whose body contains a `#error`
  # marker (an unmodeled opcode, or an arity this calling convention can't
  # express -- see pure_mandatory_arity?) from what actually gets emitted,
  # instead of emitting the #error into the output file. Default CLI usage
  # (exploring/measuring coverage) wants those markers visible; a real build
  # integration (mruby-lcf-compiled/mrbgem.rake) sets this, since a `#error`
  # in a file the C++ toolchain actually compiles halts the whole build --
  # the correct behavior for a method bc2cpp can't safely compile is exactly
  # what happens when it's just never emitted here: it keeps running on the
  # ordinary interpreted bytecode path, the documented fallback.
  if ENV['SKIP_UNSUPPORTED'] == '1'
    skipped, compiled = compiled.partition { |m| m[:code].include?('#error') }
    unless skipped.empty?
      warn ''
      warn '== skipped (unsupported, left on the interpreter) =='
      skipped.each { |m| warn "  #{m[:owner]}##{m[:name]}" }
    end
  end

  puts '#include <mruby.h>'
  # isnan/isinf/floor/ceil -- to_i's own Float case (see compile_native_
  # primitive_send's own TO_I_TYPE_TAG_DISPATCH comment) needs these to
  # reproduce flo_to_i's own real NaN/Infinity guard and truncation-
  # toward-zero, nothing else here already pulls this in.
  puts '#include <math.h>'
  puts '#include <mruby/string.h>'
  puts '#include <mruby/variable.h>'
  puts '#include <mruby/data.h>'
  puts '#include <mruby/hash.h>'
  puts '#include <mruby/array.h>'
  puts '#include <mruby/class.h>'
  # mrb_range_new -- RANGE_INC/RANGE_EXC's own codegen (see compile_insn's
  # own comment on both), same "declared by a header nothing else here
  # already pulls in" gap HASH's own mruby/hash.h addition closed for
  # mrb_hash_new_capa/mrb_hash_set.
  puts '#include <mruby/range.h>'
  # mrb_protect_error -- GETCONST's own owner-scope-first lookup (see its
  # own comment above) needs this to safely try a scope and fall back to
  # Object without letting a genuinely-missing-there NameError propagate
  # out of the wrong branch. A real core API (always available, not gated
  # behind the mruby-error gem the way mrb_protect/mrb_rescue are).
  puts '#include <mruby/error.h>'
  # GETIDX's own String arm (see compile_insn's own comment on that opcode)
  # calls `mrb_str_aref` directly -- a real, non-static, externally-linked
  # function (3rd/mruby/src/string.c), but declared only in mruby/
  # internal.h, which -- unlike every other mruby header this file already
  # includes -- has no MRB_BEGIN_DECL/MRB_END_DECL C-linkage guard at all
  # (confirmed by reading the whole file, not assumed from its name):
  # #include-ing it here would declare `mrb_str_aref` with C++ linkage,
  # then fail to link against the plain-C symbol libmruby.a actually has.
  # A direct `extern "C"` forward declaration sidesteps needing that header
  # at all, matching the real signature exactly (3rd/mruby/include/mruby/
  # internal.h's own declaration).
  puts 'extern "C" mrb_value mrb_str_aref(mrb_state*, mrb_value, mrb_value, mrb_value);'
  # OTHER_DECLS_HEADER: shell-word-separated list of real file paths (each
  # another gem's own *_decls.h, written by this same OUT_DIR mechanism
  # below) to #include so a devirtualized call to an OTHER_OWNERS target
  # has a real declaration in scope -- paired with OTHER_OWNERS above.
  if ENV['OTHER_DECLS_HEADER']
    Shellwords.split(ENV['OTHER_DECLS_HEADER']).each { |path| puts "#include \"#{path}\"" }
  end
  puts ''
  print gen.emit_structs
  print gen.emit_ary_entry_helper(compiled)
  print gen.emit_const_lookup_helper
  print gen.emit_native_construct_decls
  print gen.emit_direct_construct_decls
  print gen.emit_forward_decls(compiled)
  compiled.each { |m| print m[:code] }

  # Write this run's own cross-TU declarations header, so a *different*
  # gem's own bc2cpp run can point its own OTHER_DECLS_HEADER at this file
  # and devirtualize into these entries -- see emit_decls_header's own
  # comment. Written unconditionally (cheap, and this run doesn't know in
  # advance whether anything will ever want it); only meaningful once some
  # other run actually references it via OTHER_DECLS_HEADER/OTHER_OWNERS.
  File.write(File.join(out_dir, "#{symbol}_decls.h"), gen.emit_decls_header(compiled))

  warn ''
  warn '== compiled entry points =='
  compiled.each do |m|
    # A hand-written register.cxx that just mrb_define_method's every entry
    # here would silently make a private/protected method public -- flagged
    # loudly (not just left to a code comment) since the whole point of
    # this listing is what a real registration needs to get right.
    vis =
      case m[:visibility]
      when :public then ''
      when :private then '  [private -- use mrb_define_private_method, not mrb_define_method]'
      when :protected then '  [protected -- mruby has no mrb_define_protected_method; ' \
                            'registering this with mrb_define_method makes it public, a real behavior change]'
      end
    # Follow-up (docs/adr/0139): an owner ending in ".singleton" is the
    # SDEF/SCLASS/unfused-DEF-singleton pseudo-owner build_registry writes
    # for a real `def self.x`/`class << self; def x; end; end` method (see
    # build_registry's own SDEF/SCLASS cases above) -- `self` at the real
    # call site is the CLASS object, not an instance, so registering one of
    # these with plain mrb_define_method (which installs onto the
    # receiver's own *instance* method table) would define it in the wrong
    # place entirely, reachable only as `SomeInstance.name` rather than
    # `ClassName.name`. mrb_define_class_method (3rd/mruby/include/
    # mruby.h -- installs onto the receiver's own singleton class instead,
    # exactly where SDEF/SCLASS put the real method) is the correct call;
    # unconditional, independent of the `visibility` switch above, since
    # this file never models `private_class_method`/singleton-method
    # privacy at all (every ".singleton"-owned MethodDef's own `visibility`
    # is always :public, see build_registry's own comment) -- a
    # `.singleton` owner and a private/protected instance method are
    # mutually exclusive on any one entry, so appending rather than
    # branching on `vis` is safe.
    singleton_note = m[:owner].end_with?('.singleton') ? '  [class method -- use mrb_define_class_method, ' \
                                                          'not mrb_define_method]' : ''
    warn "  #{m[:entry]} / #{m[:impl]}  (#{m[:owner]}##{m[:name]}, arity #{m[:arity]})#{vis}#{singleton_note}"
  end

  warn ''
  warn '== classes needing MRB_SET_INSTANCE_TT(..., MRB_TT_DATA) =='
  gen.embedding_classes.each { |k| warn "  #{k}" }

  # Step 6h's own diagnostic: every compiled entry point whose name is
  # never a call target anywhere in the whole program's own bytecode
  # (collect_static_call_target_names) and never a literal mrb_funcall
  # name anywhere in NATIVE_SRCS (extract_native_call_names) is a real
  # candidate for deletion -- not proof of it. This tool has no visibility
  # into a downstream game's own bundled Ruby scripts: RGSS's own
  # `Sprite`/`Window`/`Plane`/`Bitmap`/`Audio`/`Graphics`/`Input` classes
  # ARE the public scripting API those external, per-game "stock scripts"
  # call (see docs/rpgxp-rgss-api-gap.md's own measured usage counts for
  # `zoom_x`/`zoom_y`/`ox`/`oy`/`angle`/... ), so a name landing here from
  # one of those classes is the expected, correct shape for a public API
  # surface, not a bug -- only RPG2000/2003 (mruby-rpg2k/mruby-lcf) has no
  # equivalent external-script layer, so a name from those two gems is
  # much stronger evidence of real dead code. Either way: a real signal
  # worth surfacing every run, rather than re-deriving this by hand (a
  # rebuilt host mrbc, a bespoke script reusing this file's own parsing
  # pipeline, a manual cross-check against docs/rpgxp-rgss-api-gap.md) the
  # next time this question comes up.
  static_call_names = collect_static_call_target_names(ireps)
  native_call_names = ENV['NATIVE_SRCS'] ? extract_native_call_names(native_paths) : Set.new
  # A short, closed list of Ruby-language "magic" methods mruby's own C
  # core can call on any object independent of any literal call site
  # anywhere in this program or in NATIVE_SRCS -- #initialize is the
  # everyday case: mrb_obj_new/mrb_instance_new (3rd/mruby/src/class.c)
  # call it through a `mrb_sym mid = MRB_SYM(initialize)` local variable a
  # few lines above their own mrb_funcall_argv call, invisible to
  # extract_native_call_names' own bounded lookahead (which only looks
  # forward from the mrb_funcall* call site itself, not backward through
  # arbitrary local-variable assignments). Every entry below has a real,
  # confirmed call site in this project's own 3rd/mruby/src via this same
  # indirect pattern -- checked directly, not guessed: `initialize`/
  # `initialize_copy` in class.c (mrb_obj_new, mrb_instance_new,
  # mrb_obj_init_copy, mrb_class_new_class); `method_missing`/
  # `respond_to_missing?` in vm.c/kernel.c/class.c; `to_s`/`inspect` in
  # kernel.c/array.c; `==`/`eql?`/`<=>`/`hash` in object.c/array.c/
  # kernel.c/numeric.c/hash.c; `call` in hash.c (a Hash's own default
  # Proc). Deliberately short -- e.g. `coerce`/`each`/`to_ary`/`to_str`/
  # `to_int`/`to_hash`/`[]` were checked too and dropped: this mruby 4.0
  # build's own core never reaches for them via mrb_funcall at all (no
  # generic implicit-conversion-protocol dispatch in this leaner core),
  # so claiming them "always reachable" here would be exactly the kind of
  # unverified guess this file's own design avoids everywhere else.
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
