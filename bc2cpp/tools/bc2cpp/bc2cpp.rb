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
        registry[method_name] << MethodDef.new(name: method_name, owner: owner, irep: child_label,
                                                visibility: default_visibility)
      when 'SEND0', 'SEND', 'SSEND0', 'SSEND'
        name = insn.args[/:([\w+\-*\/<>=!?\[\]]+)/, 1]
        next unless %w[private protected public].include?(name)

        n = insn.args[/n=(\d+)/, 1].to_i
        if n.zero?
          default_visibility = name.to_sym
        else
          # `private :a, :b, ...` -- the n Symbol arguments are LOADSYM'd
          # into consecutive registers immediately before this send (real
          # code always emits them right before, no interleaving
          # instructions of any other kind); walk backward collecting them.
          names = []
          (idx - 1).downto(0) do |i|
            break if names.size >= n

            prev = irep.instructions[i]
            break unless prev.op == 'LOADSYM'

            names.unshift(prev.args[/:(\S+)/, 1])
          end
          names.each do |mname|
            def_ = registry[mname]&.find { |d| d.owner == namespace }
            def_.visibility = name.to_sym if def_
          end
        end
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
  sym_or_opsym = /MRB_(?:SYM|OPSYM)\((\w+)\)/

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
    src.scan(/MRB_MT_ENTRY\s*\(\s*\w+\s*,\s*#{sym_or_opsym}/) { |tok| names << (OPSYM_TO_RUBY[tok.first] || tok.first) }

    # mrb_define_method_id(mrb, klass, MRB_SYM(name)/MRB_OPSYM(op), func, aspec)
    # (and the _class_method_id/_module_function_id siblings) -- the direct-call
    # form some core mrbgems (mruby-task, ...) use instead of a ROM table.
    src.scan(/mrb_define_(?:method|class_method|module_function)_id\s*\(\s*\w+\s*,\s*\w+\s*,\s*#{sym_or_opsym}/) do |tok|
      names << (OPSYM_TO_RUBY[tok.first] || tok.first)
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
  # UNKNOWN permanently (a real type mismatch, e.g. nil vs. String).
  def self.join(a, b)
    return b if a.nil?
    return a if b == UNKNOWN || b.nil?
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
          next unless insn.args[/:([\w+\-*\/<>=!?\[\]]+)/, 1] == name

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

      name = insn.args[/:([\w+\-*\/<>=!?\[\]]+)/, 1]
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
      # (ADD/SUB/EQ/LT/LE/GT/GE and their *I immediate forms) is real
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
               when 'ADD', 'SUB', 'EQ', 'LT', 'LE', 'GT', 'GE'
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
    @ivar_layout = drop_unsafe_embeddings(ivar_layout) # class_name -> {ivar_name => :fixnum}
    @class_layout = class_layout # class_name -> {ivar_name => class_name} -- see ClassLayout's own comment.
    @class_annotations = class_annotations # irep label -> ClassAnnotations::Annotation
    @only_owners = nil # set by compile_all -- see its own comment.
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
  def drop_unsafe_embeddings(ivar_layout)
    ivar_layout.select do |owner, _|
      init = @registry['initialize']&.find { |d| d.owner == owner }
      init && pure_mandatory_arity?(@ireps.fetch(init.irep))
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

    defs.first
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
      when 'JMPNOT', 'JMPIF'
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
    when 'GETCONST'
      # "GETCONST R4 Integer" -- a bare top-level/lexical constant lookup.
      # The real VM (OP_GETCONST, vm.c) resolves this against the *current
      # lexical scope chain* (mrb_vm_const_get, which walks the call info
      # stack's target classes) -- info this AOT-compiled function doesn't
      # have at codegen time. Simplification: look it up starting from
      # Object, same as a real top-level `Integer`/`StringIO` reference
      # would resolve to in practice for every constant this prototype has
      # actually seen compiled (see README.md's caveats) -- not sound in
      # general for a constant redefined inside a deeper lexical scope, but
      # every real case here is a genuine top-level class/module name.
      #
      # Real bug, caught by running against real code: a `\s+/, 2` split
      # captured a trailing "; R3:name" local-variable-name comment too
      # whenever the destination register is a named local (real shape,
      # e.g. "GETCONST R3 MAX_DIGITS\t; R3:d") -- interning a garbage
      # symbol name and raising a real NameError at runtime, never caught
      # by a #error check (this compiles and links fine). \S+ stops at
      # the first whitespace/tab instead of swallowing the rest of the
      # line -- same fix trace_new_target's own GETCONST case needed.
      d = a[/^R(\d+)/, 1]
      name = a[/^R\d+\s+(\S+)/, 1]
      "  r#{d} = mrb_const_get(M, mrb_obj_value(M->object_class), mrb_intern_cstr(M, \"#{name}\"));\n"
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
    when 'STOP'
      ''
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
    name = args[/:([\w+\-*\/<>=!?\[\]]+)/, 1]
    n = args[/n=(\d+)/, 1].to_i
    recv = self_implicit ? 'self' : "r#{d}"
    argv = (1..n).map { |k| "r#{d.to_i + k}" }
    target = monomorphic_target(name)
    # A monomorphic *name* is still only safe to devirtualize if its one
    # real definition fits this prototype's pure-mandatory-args calling
    # convention -- see pure_mandatory_arity?'s own comment (a real bug,
    # caught by running against real code, not a hypothetical).
    target = nil if target && !pure_mandatory_arity?(@ireps.fetch(target.irep))
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
        if candidate&.irep && pure_mandatory_arity?(@ireps.fetch(candidate.irep))
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
  puts '#include <mruby/class.h>'
  # OTHER_DECLS_HEADER: shell-word-separated list of real file paths (each
  # another gem's own *_decls.h, written by this same OUT_DIR mechanism
  # below) to #include so a devirtualized call to an OTHER_OWNERS target
  # has a real declaration in scope -- paired with OTHER_OWNERS above.
  if ENV['OTHER_DECLS_HEADER']
    Shellwords.split(ENV['OTHER_DECLS_HEADER']).each { |path| puts "#include \"#{path}\"" }
  end
  puts ''
  print gen.emit_structs
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
