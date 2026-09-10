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

# Callers that need this closed-world analysis to see a whole game's worth
# of mrblib (not just the class being compiled -- see build_registry's own
# comment on why a call site's MONO/POLY resolution needs every gem that
# could define the same method name) always pass MRBC explicitly (e.g.
# mruby-lcf-compiled/mrbgem.rake passes `spec.build.mrbcfile`, the exact
# host mrbc the surrounding cross-build already produced). No bundled
# default path: which mrbc is correct depends entirely on which build
# (host/wio/desktop/...) is invoking this script.
MRBC = ENV['MRBC'] || 'mrbc'

Irep = Struct.new(:label, :nlocals, :nregs, :pool, :syms, :reps, :lv, :instructions, keyword_init: true)
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
  current = nil
  text.each_line do |line|
    if line =~ /^irep 0x[0-9a-f]+ /
      blocks << current if current
      current = []
      next
    end
    next unless current
    if line =~ /^\s*(\d+)\s+(\d+)\s+([A-Z][A-Z0-9_]*)\s*(.*)$/
      lineno, addr, op, rest = Regexp.last_match.captures
      current << Insn.new(lineno: lineno.to_i, addr: addr.to_i, op: op, args: rest.strip, raw: line.rstrip)
    end
  end
  blocks << current if current
  blocks
end

# ---------------------------------------------------------------------------
# Step 5: merge -- zip DFS label order against disassembly block order, and
# attach each block's instructions onto its Irep.
# ---------------------------------------------------------------------------
def merge!(ireps, order, blocks)
  raise "irep count mismatch: #{order.size} (C dump) vs #{blocks.size} (disasm)" unless order.size == blocks.size

  order.each_with_index do |label, i|
    ireps.fetch(label).instructions = blocks[i]
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

  def self.analyze(ireps, registry)
    # class_name -> irep labels of every leaf method owned by that class.
    methods_of = Hash.new { |h, k| h[k] = [] }
    registry.each_value { |defs| defs.each { |d| methods_of[d.owner] << d.irep } }

    types = Hash.new { |h, k| h[k] = {} } # class_name -> {ivar_name => type or UNKNOWN}

    10.times do
      changed = false
      methods_of.each do |klass, irep_labels|
        irep_labels.each do |label|
          irep = ireps.fetch(label)
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
            inferred = trace_type(irep, idx, src_reg, types[klass])
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
  def self.trace_type(irep, idx, reg, known_ivar_types)
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
    UNKNOWN # reg was never written in this block -- an incoming argument.
  end
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
  C_TYPE = { fixnum: 'mrb_int' }.freeze

  def initialize(ireps, registry, ivar_layout)
    @ireps = ireps
    @registry = registry
    # irep label -> {owner:, name:} for every leaf method body.
    @owner_of = {}
    registry.each_value do |defs|
      defs.each { |d| @owner_of[d.irep] = d }
    end
    @ivar_layout = drop_unsafe_embeddings(ivar_layout) # class_name -> {ivar_name => :fixnum}
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
  # just an unsupported-opcode gap.
  def pure_mandatory_arity?(irep)
    enter = irep.instructions.find { |i| i.op == 'ENTER' }
    return true unless enter # no ENTER at all: a 0-arg method, trivially fine.

    fields = enter.args.split(':').map { |f| f[/\d+/].to_i }
    fields[1..].all?(&:zero?)
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
  def monomorphic_target(name)
    defs = @registry[name]
    return nil unless defs && defs.size == 1

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
  def compile_all(only_owners: nil)
    @only_owners = only_owners
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
      impl_params = (['mrb_state*'] + ['mrb_value'] * (m[:arity] + 1)).join(', ')
      out << "static mrb_value #{m[:impl]}(#{impl_params});\n"
      out << "static mrb_value #{m[:entry]}(mrb_state*, mrb_value);\n"
    end
    out << "\n"
    out
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
    out << "static mrb_value #{impl_name}(mrb_state* M, #{(['mrb_value self'] + arg_names.map { |a| "mrb_value #{a}" }).join(', ')}) {\n"
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
    irep.instructions.each do |insn|
      out << "  L#{insn.addr}:;\n" if targets.include?(insn.addr)
      out << compile_insn(insn, irep, d)
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

  def compile_insn(insn, irep, owner_def)
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
        note = "  // @#{ivar} embedded (#{type}) -- direct struct field read, no mrb_iv_get\n"
        "#{note}  r#{d} = mrb_fixnum_value(((#{sname}*)DATA_PTR(self))->#{ivar});\n"
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
        note = "  // @#{ivar} embedded (#{type}) -- direct struct field write, no mrb_iv_set\n"
        # Optimistic but guarded: the whole-program analysis proved every
        # *compiled* write site is this type, but it can't see writes from
        # outside this program (reflection, a future uncompiled caller) --
        # so this checks rather than blindly trusting its own analysis.
        # Not E_TYPE_ERROR: that macro hardcodes the identifier `mrb`, and
        # every generated function here names its mrb_state* parameter `M`.
        "#{note}  if (!mrb_integer_p(r#{s})) mrb_raise(M, mrb_exc_get_id(M, mrb_intern_lit(M, \"TypeError\")), \"@#{ivar}: expected Integer\");\n" \
          "  ((#{sname}*)DATA_PTR(self))->#{ivar} = mrb_integer(r#{s});\n"
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
      compile_send(a, self_implicit: false)
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
      d = a[/^R(\d+)/, 1]
      name = a.split(/\s+/, 2)[1]
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

  def compile_send(args, self_implicit:)
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
    # A monomorphic target whose *owner* is being filtered out of this run's
    # emitted output (ONLY_OWNERS) has no _impl function in the generated
    # file at all -- a real bug, caught wiring up the first real caller
    # (docs/adr/0139): LCF::File#to_lcf's own devirtualized calls to
    # LCF.write_ber/LCF.binstr (owner "LCF", not one of the LCF::File-family
    # classes actually being emitted) compiled clean but referenced two
    # functions this run would never define, an undefined-reference link
    # failure waiting to happen. Falling back to ordinary dynamic dispatch
    # here is always safe (just slower) -- the same fallback an unmodeled
    # opcode or a bad arity already gets.
    target = nil if target && @only_owners && !@only_owners.include?(target.owner)

    if target
      impl = cpp_name(target.owner, target.name) + '_impl'
      note = "  // MONO :#{name} -> #{target.owner}##{target.name}, direct C++ call (no mrb_funcall)\n"
      "#{note}  r#{d} = #{impl}(M, #{([recv] + argv).join(', ')});\n"
    else
      note = "  // POLY :#{name} -- real dynamic dispatch, receiver's runtime class decides\n"
      if argv.empty?
        "#{note}  r#{d} = mrb_funcall(M, #{recv}, \"#{name}\", 0);\n"
      else
        "#{note}  r#{d} = mrb_funcall(M, #{recv}, \"#{name}\", #{argv.size}, #{argv.join(', ')});\n"
      end
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
  require 'set'

  c_src, disasm_text = run_mrbc(srcs, symbol, out_dir)
  ireps, root_label = parse_c_dump(c_src, symbol)
  order = dfs_order(ireps, root_label)
  blocks = parse_disasm_blocks(disasm_text)
  merge!(ireps, order, blocks)
  registry = build_registry(ireps, root_label)

  warn '== whole-program method registry =='
  registry.sort.each do |name, defs|
    mono = defs.size == 1
    owners = defs.map(&:owner).join(', ')
    warn "  #{mono ? 'MONO' : 'POLY'}  :#{name}  (#{defs.size} def#{'s' unless defs.size == 1}: #{owners})"
  end

  ivar_layout = IvarLayout.analyze(ireps, registry)
  warn ''
  warn '== ivar embedding =='
  if ivar_layout.empty?
    warn '  (none embeddable)'
  else
    ivar_layout.each do |klass, ivars|
      ivars.each { |name, type| warn "  EMBED  #{klass}#@#{name}  (#{type})" }
    end
  end

  gen = CodeGen.new(ireps, registry, ivar_layout)
  # ONLY_OWNERS narrows *emitted* code to specific classes (comma-separated,
  # e.g. "LCF::File,LCF::Database") without narrowing the closed-world
  # registry itself -- srcs above should still be the whole program (or at
  # least everything that could define a colliding method name); see
  # compile_all's own comment for why that distinction is load-bearing.
  only_owners = ENV['ONLY_OWNERS']&.split(',')
  compiled = gen.compile_all(only_owners: only_owners)

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
  puts ''
  print gen.emit_structs
  print gen.emit_forward_decls(compiled)
  compiled.each { |m| print m[:code] }

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
