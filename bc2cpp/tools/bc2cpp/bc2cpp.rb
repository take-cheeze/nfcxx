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
    # Track which register currently holds "the class/module most recently
    # opened by CLASS/MODULE/SCLASS", so a same-register EXEC right after
    # it can be matched up -- exactly the shape mrbc's own codegen emits
    # for every `class X ... end` / `module X ... end`.
    pending_reg = nil
    pending_name = nil
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

    irep.instructions.each_with_index do |insn, idx|
      case insn.op
      when 'CLASS', 'MODULE'
        # "CLASS R4 :Animal" / "MODULE R1 :Game" -- args "R4\t:Animal"
        reg, name = insn.args.split(/\s+/, 2)
        pending_reg = reg
        # Real Ruby constant nesting (Game::CharSet, not just "CharSet") --
        # matters so two same-named classes nested under different
        # modules aren't conflated into one registry entry.
        pending_name = namespace ? "#{namespace}::#{name.sub(/^:/, '')}" : name.sub(/^:/, '')
      when 'EXEC'
        reg, irep_ref = insn.args.split(/\s+/, 2)
        idx2 = irep_ref[/I\[(\d+)\]/, 1].to_i
        child_label = irep.reps[idx2]
        walk.call(child_label, pending_name) if reg == pending_reg && pending_name
        pending_reg = nil
        pending_name = nil
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
        visibility = %w[initialize initialize_copy
                         respond_to_missing?].include?(method_name) ? :private : default_visibility
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
        # are: register a synthetic MethodDef (irep: nil -- there is no
        # leaf method body here for this compiler to ever compile into) so
        # a real bytecode instance-method definition of the same bare name
        # elsewhere correctly counts this as a second definition and flips
        # MONO to POLY, never silently staying MONO. This can only ever
        # turn an unsound MONO into a correctly cautious POLY, never remove
        # a genuinely sound one, the same guarantee every other synthetic-
        # MethodDef fix in this file already carries.
        _reg, sname, _irep_ref = insn.args.split(/\s+/, 3)
        sdef_name = sname.sub(/^:/, '')
        registry[sdef_name] << MethodDef.new(name: sdef_name, owner: "#{namespace || 'Object'}.singleton",
                                              irep: nil, visibility: :public)
      when 'SEND0', 'SEND', 'SSEND0', 'SSEND'
        # Same charset as compile_send's own name extraction below (see its
        # own comment for the real bug this fixes) -- kept in sync here too,
        # even though :private/:protected/:public never collide with an
        # operator name, so a future reader never has to wonder why the two
        # differ.
        name = insn.args[/:([\w+\-*\/<>=!?\[\]&|^~%@]+)/, 1]
        next unless %w[private protected public attr_reader attr_writer attr_accessor].include?(name)

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
            found = trace_new_target(irep, idx, src_reg, known_so_far, mand, arg_classes) || UNKNOWN

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
def trace_new_target(irep, idx, reg, ivar_classes = nil, mand = 0, arg_classes = nil)
  path = []
  # GETCONST/GETMCNST are only ever valid class-name evidence *while
  # resolving a `.new` call's own receiver* -- never on their own. A bare
  # `@position = POS_BOTTOM` (a plain Integer constant, no `.new` in
  # sight anywhere) must never be mistaken for "@position always holds
  # an instance of a class named POS_BOTTOM": real bug, caught running
  # this against real game source (`Game::MessageConfig#@position`,
  # `Game::NumberInput#@digits`, ... all Integer-valued constants, none
  # of them classes). `resolving_new` only ever becomes true right after
  # a `SEND :new` is found (with nothing already peeled off `path`),
  # gating GETMCNST/GETCONST on having actually seen one first.
  resolving_new = false
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
      path.unshift(insn.args[/^R\d+\s+(\S+)/, 1])
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

  def initialize(ireps, registry, ivar_layout, class_layout = {}, class_annotations = {})
    @ireps = ireps
    @registry = registry
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
    ivar_layout.select do |owner, _|
      init = @registry['initialize']&.find { |d| d.owner == owner }
      init && pure_mandatory_arity?(@ireps.fetch(init.irep)) && compiles_clean?(init.irep)
    end
  end

  def cpp_name(owner, name)
    sanitize("#{owner}_#{name}")
  end

  # Owner class names are real Ruby constant paths ("Game::Actor",
  # "RPG2k::Scene::Order") once nested module/class tracking is in play --
  # ":: " isn't valid inside an ordinary C++ identifier, so every generated
  # name (function, struct, static var) needs this, not just cpp_name.
  def sanitize(s)
    s.gsub(/[^a-zA-Z0-9_]/, '_')
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

  def decl_line(m)
    impl_params = (['mrb_state*'] + ['mrb_value'] * (m[:arity] + 1)).join(', ')
    "mrb_value #{m[:impl]}(#{impl_params})"
  end

  def compile_method(label)
    irep = @ireps.fetch(label)
    d = @owner_of.fetch(label)
    enter = irep.instructions.find { |i| i.op == 'ENTER' }
    mand = enter ? enter.args.split(':').first.to_i : 0
    arg_names = irep.lv.first(mand).each_with_index.map { |n, i| n || "arg#{i + 1}" }

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
    out << "mrb_value #{impl_name}(mrb_state* M, #{(['mrb_value self'] + arg_names.map { |a| "mrb_value #{a}" }).join(', ')}) {\n"
    (0...irep.nregs).each { |i| out << "  mrb_value r#{i}" << (i.zero? ? ' = self;' : ' = mrb_nil_value();') << "\n" }
    arg_names.each_with_index { |a, i| out << "  r#{i + 1} = #{a};\n" }
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
      out << "  mrb_value #{arg_names.join(', ')};\n"
      fmt = 'o' * arg_names.size
      ptrs = arg_names.map { |a| "&#{a}" }.join(', ')
      out << "  mrb_get_args(M, \"#{fmt}\", #{ptrs});\n"
      out << "  return #{impl_name}(M, self, #{arg_names.join(', ')});\n"
    end
    out << "}\n\n"
    { label: label, owner: d.owner, name: d.name, entry: entry_name, impl: impl_name,
      arity: arg_names.size, code: out, visibility: d.visibility }
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
      owner_path = owner_def.owner.split('::')
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
      known_class = trace_new_target(irep, idx, d, ivar_classes, cur_mand, cur_arg_classes)
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
      if typed
        check = "mrb_class_ptr(#{const_chain_value_expr(target.owner)}) == mrb_obj_class(M, #{recv})"
        note = "  // TYPED :#{name} -> #{target.owner}##{target.name} (receiver traced to #{target.owner}), " \
               "runtime-class-checked direct C++ call, mrb_funcall fallback\n"
        "#{note}  if (#{check}) {\n" \
          "    r#{d} = #{impl}(M, #{([recv] + argv).join(', ')});\n" \
          "  } else {\n" \
          "    #{dynamic_dispatch_line(d, recv, name, argv)}" \
          "  }\n"
      else
        note = "  // MONO :#{name} -> #{target.owner}##{target.name}, direct C++ call (no mrb_funcall)\n"
        "#{note}  r#{d} = #{impl}(M, #{([recv] + argv).join(', ')});\n"
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
  def const_chain_value_expr(owner)
    owner.split('::').reduce('mrb_obj_value(M->object_class)') do |expr, seg|
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

  gen = CodeGen.new(ireps, registry, ivar_layout, class_layout, class_annotations)
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
    warn "  #{m[:entry]} / #{m[:impl]}  (#{m[:owner]}##{m[:name]}, arity #{m[:arity]})#{vis}"
  end

  warn ''
  warn '== classes needing MRB_SET_INSTANCE_TT(..., MRB_TT_DATA) =='
  gen.embedding_classes.each { |k| warn "  #{k}" }
end
