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

Irep = Struct.new(:label, :nlocals, :nregs, :pool, :syms, :reps, :lv, :instructions, :file, keyword_init: true)
Insn = Struct.new(:lineno, :addr, :op, :args, :raw, keyword_init: true)
MethodDef = Struct.new(:name, :owner, :irep, :visibility, keyword_init: true)

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
  current = nil
  text.each_line do |line|
    if line =~ /^irep 0x[0-9a-f]+ /
      blocks << current if current
      current = []
      block_files << nil # overwritten by this block's own `file:` line below, if any.
      next
    end
    next unless current
    if line =~ /^file: (.+)$/
      block_files[-1] = Regexp.last_match(1)
      next
    end
    if line =~ /^\s*(\d+)\s+(\d+)\s+([A-Z][A-Z0-9_]*)\s*(.*)$/
      lineno, addr, op, rest = Regexp.last_match.captures
      current << Insn.new(lineno: lineno.to_i, addr: addr.to_i, op: op, args: rest.strip, raw: line.rstrip)
    end
  end
  blocks << current if current
  [blocks, block_files]
end

# ---------------------------------------------------------------------------
# Step 5: merge -- zip DFS label order against disassembly block order, and
# attach each block's instructions onto its Irep.
# ---------------------------------------------------------------------------
def merge!(ireps, order, blocks, block_files = [])
  raise "irep count mismatch: #{order.size} (C dump) vs #{blocks.size} (disasm)" unless order.size == blocks.size

  order.each_with_index do |label, i|
    irep = ireps.fetch(label)
    irep.instructions = blocks[i]
    irep.file = block_files[i]
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
            if getter_flag
              registry[mname] << MethodDef.new(name: mname, owner: owner, irep: nil, visibility: :public)
            end
            if setter_flag
              registry["#{mname}="] << MethodDef.new(name: "#{mname}=", owner: owner, irep: nil,
                                                       visibility: :public)
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
  registry
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
  sym_or_opsym = /MRB_(SYM_Q|SYM_B|SYM_E|SYM|OPSYM)\((\w+)\)/
  resolve_sym = lambda do |macro, name|
    case macro
    when 'SYM_Q' then "#{name}?"
    when 'SYM_B' then "#{name}!"
    when 'SYM_E' then "#{name}="
    when 'OPSYM' then OPSYM_TO_RUBY[name] || name
    else name # bare MRB_SYM(name)
    end
  end

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
    src.scan(/MRB_MT_ENTRY\s*\(\s*\w+\s*,\s*#{sym_or_opsym}/) { |tok| names << resolve_sym.call(tok[0], tok[1]) }

    # mrb_define_method_id(mrb, klass, MRB_SYM(name)/MRB_OPSYM(op), func, aspec)
    # (and the _class_method_id/_module_function_id siblings) -- the direct-call
    # form some core mrbgems (mruby-task, ...) use instead of a ROM table.
    src.scan(/mrb_define_(?:method|class_method|module_function)_id\s*\(\s*\w+\s*,\s*\w+\s*,\s*#{sym_or_opsym}/) do |tok|
      names << resolve_sym.call(tok[0], tok[1])
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
            'symbol' => :symbol, 'Symbol' => :symbol }.freeze
  COMMENT_RE = /^\s*#\s*bc2cpp:\s*\(([^)]*)\)(?:\s*->\s*(\S+))?\s*$/

  Annotation = Struct.new(:args, :ret, keyword_init: true)

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
        ret_type = m[2] && TYPES[m[2]]
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

  def self.analyze(ireps, registry, class_annotations = {})
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
            found = trace_new_target(irep, idx, src_reg, known_so_far, mand, arg_classes, owner: owner) || UNKNOWN

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

    classes.each_with_object({}) do |(owner, ivars), out|
      known = ivars.reject { |_, c| c == UNKNOWN }
      out[owner] = known unless known.empty?
    end
  end
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
# real, not just theoretically unlocked, for the three names added below:
# regenerating the real `rpg2k_compiled_gen.cpp` shows `Game::State#
# initialize`'s own `Switches.new`/`Timer.new` (x2)/`MessageConfig.new`
# call sites now compile to the same `// MONO :new -> ..., direct compiled
# construct (bc2cpp_direct_alloc + ..._impl)` runtime-guarded shape
# `Game::Transition`/`Game::Map`'s own call sites already used, in place of
# the generic `mrb_funcall` fallback they compiled to before. `Game::
# Screen`'s own bare `Screen.new` call site (mruby-rpg2k/mrblib/game.rb,
# also inside `Game::State#initialize`) is, by this exact same reasoning,
# now provably unlockable too -- confirmed directly (temporarily adding it
# here and regenerating shows the identical direct-construct shape) -- but
# left off this table for now since unlocking it was not part of this
# round's own brief; a trivial follow-up for whoever next touches this
# table.
DIRECT_CONSTRUCT_TARGETS = %w[Game::Transition Game::Map
                               Game::Switches Game::Timer Game::MessageConfig].freeze

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
def trace_new_target(irep, idx, reg, ivar_classes = nil, mand = 0, arg_classes = nil, resolving_new: false, owner: nil)
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
      return nil unless name == 'new'

      resolving_new = true
    # Same register, still tracing further back for the class object that
    # was `.new`'s own receiver -- SEND overwrites its receiver register
    # with the result, in place.
    when 'GETIV'
      return nil if resolving_new || !path.empty?

      ivar = insn.args[/@(\w+)/, 1]
      return ivar_classes && ivar_classes[ivar]
    when 'GETMCNST'
      return nil unless resolving_new

      # Not `$`-anchored on purpose -- a trailing "; R6:name" local-
      # variable comment (real code, same shape as SETIV's own) would
      # otherwise land inside the captured segment.
      path.unshift(insn.args[/::(\w+)/, 1])
    when 'GETCONST'
      return nil unless resolving_new

      # "GETCONST R4 Integer" or, with a named-local destination
      # register, "GETCONST R3 MAX_DIGITS\t; R3:d" -- \S+ (not the rest
      # of the line) stops at the first whitespace/tab, same fix as
      # compile_insn's own GETCONST codegen needed for the identical bug.
      const_name = insn.args[/^R\d+\s+(\S+)/, 1]

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

  def initialize(ireps, registry, ivar_layout, class_layout = {}, class_annotations = {}, annotations = {})
    @ireps = ireps
    @registry = registry
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
      # compiler's own GETIV/SETIV codegen. A plain `attr_reader`/
      # `attr_writer`/`attr_accessor` for that exact same name is a real,
      # live counterexample -- its native C implementation
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
      safe = ivars.reject do |name, _|
        natively_exposed?(owner, name) || natively_exposed?(owner, "#{name}=") ||
          !every_accessor_compiles?(owner, name)
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
  # `mrb_value` (today's own uniform type, unchanged) otherwise.
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
    arg_names = irep.lv.first(mand).each_with_index.map { |n, i| n || "arg#{i + 1}" }
    # NATIVE_ARG_TARGETS' own per-position native type, size == mand -- see
    # native_arg_types' own comment. All-nil (every position stays plain
    # `mrb_value`, today's own uniform shape) unless this exact
    # "Owner#name" is explicitly listed there AND a real annotation names a
    # recognized type at that position.
    arg_native_types = native_arg_types(d, mand)

    impl_name = "#{cpp_name(d.owner, d.name)}_impl"
    entry_name = cpp_name(d.owner, d.name)
    embedded_ivars = @ivar_layout[d.owner]

    unless pure_mandatory_arity?(irep)
      # Not modeled -- see pure_mandatory_arity?'s own comment. Emit a
      # loud, honest #error instead of a function whose signature silently
      # disagrees with what real call sites (interpreted or a devirtualized
      # direct call) actually pass it.
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
    targets = jump_targets(irep)
    irep.instructions.each_with_index do |insn, idx|
      out << "  L#{insn.addr}:;\n" if targets.include?(insn.addr)
      out << compile_insn(insn, irep, d, idx)
    end
    out << "  return mrb_nil_value(); // unreachable if every path RETURNs\n"
    out << "}\n\n"

    out << "static mrb_value #{entry_name}(mrb_state* M, mrb_value self) {\n"
    if arg_names.empty?
      out << "  return #{impl_name}(M, self);\n"
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
      arg_names.each_with_index { |a, i| out << "  #{native_c_type(arg_native_types[i])} #{a};\n" }
      # 'i' is mrb_as_int under the hood (mrb_ensure_int_type + a bigint
      # unwrap), 'n' is mrb_obj_to_sym -- the exact same two coercions
      # compile_send's own call-site unboxing (below) uses when it moves
      # this identical coercion to a devirtualized direct-call site
      # instead of through this entry wrapper; see that call site's own
      # comment for why the two have to stay in lockstep.
      fmt = arg_native_types.map { |t| t == :fixnum ? 'i' : (t == :symbol ? 'n' : 'o') }.join
      ptrs = arg_names.map { |a| "&#{a}" }.join(', ')
      out << "  mrb_get_args(M, \"#{fmt}\", #{ptrs});\n"
      out << "  return #{impl_name}(M, self, #{arg_names.join(', ')});\n"
    end
    out << "}\n\n"
    # arg_c_types: this method's own real per-position C++ parameter type
    # list (decl_line's own forward-declaration/cross-TU-header codegen
    # reads it, so a devirtualized caller -- same gem or, via
    # OTHER_DECLS_HEADER, a different one -- declares this `_impl` with
    # exactly the signature it was actually emitted with).
    { label: label, owner: d.owner, name: d.name, entry: entry_name, impl: impl_name,
      arity: arg_names.size, arg_c_types: arg_names.each_index.map { |i| native_c_type(arg_native_types[i]) },
      code: out, visibility: d.visibility }
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
        targets << insn.args[/(\d+)\s*$/, 1].to_i
      end
    end
    targets
  end

  def compile_insn(insn, irep, owner_def, idx = nil)
    a = insn.args
    case insn.op
    when 'ENTER'
      "  // #{insn.raw.strip} (args already bound above)\n"
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
      compile_send(a, self_implicit: true)
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
      target = a[/(\d+)\s*$/, 1].to_i
      "  if (!mrb_test(r#{reg})) goto L#{target};\n"
    when 'JMPIF'
      reg = a[/^R(\d+)/, 1]
      target = a[/(\d+)\s*$/, 1].to_i
      "  if (mrb_test(r#{reg})) goto L#{target};\n"
    when 'JMPNIL'
      # "JMPNIL R3 024" -- OP_JMPNIL's own real shape (src/vm.c): jump if
      # r<d> is exactly nil (not merely falsy -- mrb_test/JMPNOT/JMPIF
      # already cover the falsy case; this is the dedicated opcode mrbc
      # emits for `x.nil? ? a : b` / `x || y`-shaped nil-specific tests,
      # e.g. `@opacity.nil? ? 255 : @opacity`).
      reg = a[/^R(\d+)/, 1]
      target = a[/(\d+)\s*$/, 1].to_i
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
      "  r#{d} = mrb_array_p(r#{s}) ? mrb_ary_ref(M, r#{s}, #{c}) : (#{c} == 0 ? r#{s} : mrb_nil_value());\n"
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
      # public API AREF's own codegen above already uses) and Hash
      # (mrb_hash_get, the same public API HASH's own codegen above already
      # uses); anything else (String/Range #[], or a class overriding #[])
      # falls back to the real method the interpreter itself would call --
      # never unsound, just without the in-VM fast path. `r<d>` (the
      # receiver) is read by every branch before any of them writes it, the
      # same "read before overwrite" safety AREF/HASH/ARRAY's own codegen
      # already relies on.
      d, s = regs(a, 2)
      <<~CPP
        if (mrb_array_p(r#{d}) && mrb_integer_p(r#{s})) {
          r#{d} = mrb_ary_ref(M, r#{d}, mrb_integer(r#{s}));
        } else if (mrb_hash_p(r#{d})) {
          r#{d} = mrb_hash_get(M, r#{d}, r#{s});
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
          r#{d} = mrb_ary_ref(M, r#{s}, 0);
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

  def compile_send(args, self_implicit:, irep: nil, idx: nil, owner_def: nil)
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
      return "  #error SEND/SSEND :#{name} has a splat and/or keyword argument list (#{n_match[0]}) -- not in this prototype's supported subset\n"
    end

    n = n_match ? n_match[1].to_i : 0
    recv = self_implicit ? 'self' : "r#{d}"
    argv = (1..n).map { |k| "r#{d.to_i + k}" }

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

    target = monomorphic_target(name)
    # A monomorphic *name* is still only safe to devirtualize if its one
    # real definition fits this prototype's pure-mandatory-args calling
    # convention -- see pure_mandatory_arity?'s own comment (a real bug,
    # caught by running against real code, not a hypothetical).
    target = nil if target && !pure_mandatory_arity?(@ireps.fetch(target.irep))
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
    target = nil if target && n != mandatory_arity(@ireps.fetch(target.irep))
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
    if target.nil? && !self_implicit && irep && idx
      cur_enter = irep.instructions.find { |i| i.op == 'ENTER' }
      cur_mand = cur_enter ? cur_enter.args.split(':').first.to_i : 0
      cur_arg_classes = owner_def && @class_annotations[irep.label]&.args
      ivar_classes = owner_def && @class_layout[owner_def.owner]
      known_class = trace_new_target(irep, idx, d, ivar_classes, cur_mand, cur_arg_classes, owner: owner_def&.owner)
      if known_class
        candidate = @registry[name].find { |md| md.owner == known_class }
        # Same two guards as the MONO path above (its own comments have the
        # real bugs both catch, e.g. Game::State#set_parallax/
        # #set_screen_transition/#show_picture/#erase_picture -- all four
        # real TYPED-path arity mismatches this exact check fixed, caught
        # building Game::Screen's own compiled target): a class-exact
        # candidate still isn't safe to call directly unless its own body
        # actually compiles AND the call site's argument count matches its
        # real mandatory arity.
        if candidate&.irep && pure_mandatory_arity?(@ireps.fetch(candidate.irep)) &&
           compiles_clean?(candidate.irep) && n == mandatory_arity(@ireps.fetch(candidate.irep))
          target = candidate
          typed = true
        end
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
      # name. `target.irep`'s own mandatory arity already equals `argv.size`
      # here (checked above, both for the MONO and TYPED paths), so
      # `native_arg_types` is asked for exactly that many positions.
      call_types = native_arg_types(target, argv.size)
      call_argv = argv.each_with_index.map do |a, i|
        case call_types[i]
        when :fixnum then "mrb_as_int(M, #{a})"
        when :symbol then "mrb_obj_to_sym(M, #{a})"
        else a
        end
      end
      native_positions = call_types.each_index.select { |i| call_types[i] }.map { |i| i + 1 }
      native_note = native_positions.empty? ? '' : " (position#{'s' unless native_positions.one?} " \
                                                    "#{native_positions.join(', ')} unboxed here to match " \
                                                    "#{impl}'s own native argument type)"
      if typed
        check = "mrb_class_ptr(#{const_chain_value_expr(target.owner)}) == mrb_obj_class(M, #{recv})"
        note = "  // TYPED :#{name} -> #{target.owner}##{target.name} (receiver traced to #{target.owner}), " \
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
  blocks, block_files = parse_disasm_blocks(disasm_text)
  merge!(ireps, order, blocks, block_files)
  registry = build_registry(ireps, root_label)

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

  class_layout = ClassLayout.analyze(ireps, registry, class_annotations)
  warn ''
  warn '== known-ivar-class hints (devirtualization only, never embedded) =='
  if class_layout.empty?
    warn '  (none)'
  else
    class_layout.each do |klass, ivars|
      ivars.each { |name, cls| warn "  CLASS_HINT  #{klass}#@#{name}  (#{cls})" }
    end
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
  gen = CodeGen.new(ireps, registry, ivar_layout, class_layout, class_annotations, annotations)
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
  # OTHER_DECLS_HEADER: shell-word-separated list of real file paths (each
  # another gem's own *_decls.h, written by this same OUT_DIR mechanism
  # below) to #include so a devirtualized call to an OTHER_OWNERS target
  # has a real declaration in scope -- paired with OTHER_OWNERS above.
  if ENV['OTHER_DECLS_HEADER']
    Shellwords.split(ENV['OTHER_DECLS_HEADER']).each { |path| puts "#include \"#{path}\"" }
  end
  puts ''
  print gen.emit_structs
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
end
