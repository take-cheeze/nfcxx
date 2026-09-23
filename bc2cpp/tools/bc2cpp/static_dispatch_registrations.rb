# frozen_string_literal: true

# STATIC_DISPATCH_UNREGISTRATION: the sound form of "a devirtualized method
# does not need its mrb_define_method registration" (docs/adr/0203).
#
# A `register.cxx` / generated `bc2cpp_register_owner_methods` line exists
# only so mruby's own dynamic method-table lookup can find the compiled
# method. docs/adr/0198 rejected dropping it on the grounds that "every call
# site devirtualized" is a per-call-site property no existing pass tracked,
# and that interpreted callers still dispatch dynamically. This file does not
# try to prove devirtualization per call site at all. It asks a strictly
# stronger, name-level question with a default of "dynamic": is there ANY
# place a runtime lookup of this method name could come from? A name is only
# eligible when every one of these comes back empty:
#
#   1. Bytecode that can run. A method body -- compiled or not -- only runs
#      as bytecode after a dynamic lookup of its own name (a direct C++ call
#      targets `_impl`, never bytecode). A body whose compiled override stays
#      registered can only do so during mrblib load, before its gem_init
#      installs the override -- so for those only a load-phase lookup counts
#      (load_phase: seeded from the root and class bodies, receiver-aware,
#      since no engine object exists at load unless load-time code builds
#      one -- it falls back to a receiver-blind cascade if any does). So: the
#      root and class-body ireps, every block/lambda irep inside a registered
#      compiled method (bc2cpp may keep one as a bytecode proc), and the body
#      (and blocks) of any other method whose name is dynamic -- to a
#      fixpoint. Every SEND/SEND0/SSEND/SSEND0/SENDB/SSENDB and LOADSYM name
#      in those counts, plus the operator names the implicit-dispatch
#      opcodes (ADD, GETIDX, ...) stand for.
#   2. Compiled code's own dynamic dispatch. Every string literal in the
#      generated C++ of all three compiled gems -- this is where a guarded
#      direct call's `mrb_funcall_id` fallback, a POLY dispatch, a symbol
#      literal, or a runtime redefinition guard interns the name, so the
#      name showing up here at all (outside its own registration call)
#      counts, no matter why.
#   3. `super`. The enclosing method's name for every SUPER op anywhere.
#   4. Names built at runtime. Every string-pool literal in the closed world:
#      the literal itself, and -- because `"#{field}="`/`"#{type}_x"` are
#      real, present shapes -- any name that starts or ends with a pool
#      literal of two or more identifier characters, or that ends in `=`/`?`/
#      `!` when its base name is itself dynamic.
#   5. Everything outside the closed world bc2cpp.rb never parses: mruby's
#      own core and core-gem mrblib (Enumerable calls `each`, Comparable
#      calls `<=>`, ...), the three external gems, every other maker gem's
#      mrblib (mruby-rpgxp/rpgvx/wolf/mvjs -- the gap docs/adr/0195 found),
#      every gem's own test/ (mrbtest runs inside the built VM), scripts/,
#      tools/ (except tools/bc2cpp itself), and every native C/C++ source in
#      this repository or the vendored mruby tree (src/, app/, include/,
#      mruby-*/src/ -- the top-level src/*.cxx gap docs/adr/0195 found --
#      3rd/mruby/src, core gem src). These are scanned as plain text: every
#      identifier token counts, plus MRB_SYM_Q/_B/_E(x) as x?/x!/x=.
#   6. mruby's own implicit protocol names (ALWAYS_DYNAMIC below), as a
#      belt-and-braces backstop for (5).
#
# Only owners in the internal RPG2000/2003 namespaces
# (NeverCalledRegistrations::SAFE_UNREGISTER_OWNER_RE) are considered:
# mruby-rgss-compiled's classes are the RGSS scripting API an RPG Maker XP
# game's own Data/Scripts.rxdata calls, which no scan here can see.
#
# What remains is a name nothing can look up at runtime: every real caller
# reaches it through a direct `Owner_name_impl(...)` call in generated C++,
# which does not consult the method table. Dropping its registration lets
# `-Wl,--gc-sections` discard the `mrb_get_args` wrapper (the registration
# was its only reference), and the registration call and name string with it.
# The method's interpreted `def` stays exactly as stripped or unstripped as
# before (strip_wio_bc2cpp_stubs.rb still lists it) -- nothing dispatches to
# either.
#
# Residual risk, stated plainly: a method name assembled at runtime from data
# that never appears as a literal or fragment anywhere in any scanned source
# (e.g. read out of a game file and then `send`) would be missed. Nothing in
# this codebase does that for an RPG2000/2003-internal class today; the
# regression check (scripts/bc2cpp_static_dispatch_check.rb) re-proves every
# listed name on every run, so a later change that adds a dynamic reference
# fails CI instead of shipping a NoMethodError.
require 'fileutils'
require 'set'
require 'tmpdir'
require_relative 'compiled_gems'
require_relative 'never_called_registrations'
require_relative 'static_dispatch_unregistered'
require_relative 'symbol_cache'

module StaticDispatchRegistrations
  GEMS = %w[mruby-rpg2k-compiled mruby-lcf-compiled mruby-rgss-compiled].freeze
  SEND_OPS = %w[SEND SEND0 SSEND SSEND0 SENDB SSENDB LOADSYM].freeze
  NAME_ARG = %r{:([\w+\-*/<>=!?\[\]&|^~%@]+)}
  REGISTRATION_CALL = /mrb_define_(?:private_|class_)?method\(\s*M\s*,\s*(\w+)\s*,\s*"((?:[^"\\]|\\.)*)"\s*,\s*(\w+)\s*,[^;]*\);/m
  IDENT = /\A[a-z_][A-Za-z0-9_]*[?!=]?\z/
  FRAGMENT = /\A[\w?!=]{2,}\z/
  ALWAYS_DYNAMIC = %w[
    initialize initialize_copy method_missing respond_to_missing? respond_to?
    to_s inspect == != ! eql? equal? <=> === =~ hash call to_proc to_ary to_a
    to_hash to_h to_str to_int to_i to_f to_sym each each_pair coerce new
    allocate inherited included extended prepended method_added const_missing
    marshal_dump marshal_load _dump _load dup clone freeze send __send__
    public_send instance_eval instance_exec class_eval
  ].to_set.freeze

  module_function

  def unescape(s)
    s.gsub(/\\x(\h{2})|\\([0-7]{1,3})|\\(.)/m) do
      if Regexp.last_match(1) then Regexp.last_match(1).hex.chr
      elsif Regexp.last_match(2) then Regexp.last_match(2).to_i(8).chr
      else { 'n' => "\n", 't' => "\t", 'r' => "\r" }.fetch(Regexp.last_match(3), Regexp.last_match(3))
      end
    end
  end

  # Every C string literal in `src` that is not the name argument of a
  # registration call, with comments dropped first.
  def c_literals(src, exempt: Set.new)
    body = src.gsub(REGISTRATION_CALL, '').gsub(%r{/\*.*?\*/}m, '').gsub(%r{//[^\n]*}, '')
    table = nil
    body = body.sub(SYM_TABLE) { table = Regexp.last_match(1); '' }
    names = body.scan(STRING_LITERAL).map { |(s)| unescape(s) }
    names + (table ? table.scan(STRING_LITERAL).map { |(s)| unescape(s) }.reject { |n| exempt.include?(n) } : [])
  end

  STRING_LITERAL = /"((?:[^"\\\n]|\\.)*)"/
  # symbol_cache.rb's interned-name table; every use is `bc2cpp_sym(M, <index>)`
  # or the index argument of `bc2cpp_send(M, recv, <index>, ...)`.
  SYM_TABLE = /bc2cpp_sym_names\[\d+\] = \{\n(.*?)^\};/m
  # MONO_EMBED_GUARD's shape (bc2cpp.rb): an exact-class check around the
  # direct `_impl` call, and a by-name `bc2cpp_send` for every other class.
  EMBED_GUARD_FALLBACK = %r{
    //\ MONO_EMBED_GUARD\ :(\S+)\ ->\ (\S+)\#\S+\ [^\n]*\n
    \s*if\ \([^\n]*\)\ \{\n
    (?:(?!\s*//\ MONO_EMBED_GUARD)[^\n]*\n){0,12}?
    \s*\}\ else\ \{\n
    \s*r\d+\ =\ bc2cpp_send\(M,\ [^,]+,\ (\d+),
  }x

  # EMBED_GUARD_FALLBACK (docs/adr/0206): the names in `src`'s symbol table
  # whose every use is the by-name fallback of a MONO_EMBED_GUARD for that
  # same method, on an owner nothing subclasses. The fallback runs only when
  # the receiver's class is not exactly the owner; with no subclass anywhere,
  # such a receiver's method lookup never reaches the owner's method table, so
  # it cannot need the owner's registration -- it finds the name on its own
  # class or raises NoMethodError, registered or not. Such a use is therefore
  # not a dynamic lookup of the owner's method.
  def embed_guard_fallback_only(src, subclassed)
    table = src[SYM_TABLE, 1] or return Set.new
    names = table.scan(STRING_LITERAL).map { |(s)| unescape(s) }
    uses = Hash.new(0)
    src.scan(/bc2cpp_sym\(M, (\d+)\)/) { |(i)| uses[i.to_i] += 1 }
    SymbolCache.send_indices(src).each { |i| uses[i] += 1 }
    guarded = Hash.new(0)
    src.scan(EMBED_GUARD_FALLBACK) do |name, owner, idx|
      i = idx.to_i
      next unless names[i] == name
      next if owner.end_with?('.singleton') || subclassed?(owner, subclassed)

      guarded[i] += 1
    end
    guarded.select { |i, n| n == uses[i] }.keys.to_set { |i| names[i] }
  end

  # Every class path something could subclass, conservatively: each
  # superclass in the closed world, plus any constant path written after `<`,
  # inside `Class.new(`, or anywhere in an `mrb_define_class*` call, in any
  # scanned source. A written path may be relative, so an owner counts as
  # subclassed when it equals one or ends with `::` plus one (`< Base` inside
  # `RPG2k::Scene` blocks every `...::Base`).
  def subclassed_paths(repo_root, superclass_of)
    found = superclass_of.values.grep(String).to_set
    ruby, native = outside_world_files(repo_root)
    (closed_world_mrblib_srcs(repo_root) + ruby).each do |f|
      text = File.read(f, encoding: 'BINARY')
      text.scan(/(?:<\s*|Class\.new\(\s*)(?:::)?((?:[A-Z]\w*::)*[A-Z]\w*)/) { |(n)| found << n }
      # A superclass the scan cannot name (`Class.new(klass)`) could be any.
      found << ANY_CLASS if text.match?(/Class\.new\(\s*[a-z_@$]/)
    end
    native.each do |f|
      text = File.read(f, encoding: 'BINARY')
      next unless text.match?(DEFINE_CLASS)

      # Native code names a Ruby superclass by string (`mrb_class_get(M,
      # "Foo")`), possibly far from the define call: any capitalized string
      # literal in a file that defines classes counts, as does every
      # capitalized identifier in the define call itself.
      text.scan(/#{DEFINE_CLASS}[^;]*/) { |call| call.scan(/\b([A-Z]\w*)\b/) { |(n)| found << n } }
      text.scan(/"([A-Z]\w*(?:::[A-Z]\w*)*)"/) { |(n)| found << n }
    end
    found
  end

  ANY_CLASS = :any
  DEFINE_CLASS = /\bmrb_define_class(?:_under)?(?:_id)?\(/

  def subclassed?(owner, paths)
    paths.include?(ANY_CLASS) || paths.any? { |p| owner == p || owner.end_with?("::#{p}") }
  end

  def registrations(src)
    src.scan(REGISTRATION_CALL).map { |_var, name, entry| [entry, unescape(name)] }
  end

  # The closed world, parsed by bc2cpp.rb's own front end (required as a
  # library -- its driver only runs as a program).
  def closed_world(repo_root, mrbc)
    ENV['MRBC'] = mrbc
    require_relative 'bc2cpp'
    Dir.mktmpdir('bc2cpp_static_dispatch') do |tmp|
      c_src, disasm = run_mrbc(closed_world_mrblib_srcs(repo_root), 'static_dispatch_probe', tmp)
      ireps, root = parse_c_dump(c_src, 'static_dispatch_probe')
      blocks, files, catches = parse_disasm_blocks(disasm)
      merge!(ireps, dfs_order(ireps, root), blocks, files, catches)
      registry, superclass_of = build_registry(ireps, root)
      [ireps, registry, superclass_of]
    end
  end

  def outside_world_files(repo_root)
    closed = closed_world_mrblib_srcs(repo_root).map { |p| File.expand_path(p) }.to_set
    # scripts/ and the CI workflows are scanned whatever their extension: the
    # boot checks feed inline Ruby (heredocs in *.bash) to the real binary's
    # `--script`, which runs it inside the same VM.
    ruby = foreign_mrblib_srcs(repo_root) +
           Dir["#{repo_root}/mruby-*/mrblib/**/*.rb"] +
           Dir["#{repo_root}/mruby-*/test/**/*.rb"] +
           Dir["#{repo_root}/scripts/**/*"].select { |p| File.file?(p) } +
           Dir["#{repo_root}/.github/**/*"].select { |p| File.file?(p) } +
           Dir["#{repo_root}/tools/**/*.rb"].reject { |p| p.include?('/tools/bc2cpp/') }
    native_glob = '*.{c,cc,cpp,cxx,h,hh,hpp,hxx,inc}'
    native = Dir["#{repo_root}/{src,app,include}/**/#{native_glob}"] +
             Dir["#{repo_root}/mruby-*/{src,include}/**/#{native_glob}"] +
             Dir["#{repo_root}/3rd/mruby/{src,include}/**/#{native_glob}"] +
             Dir["#{repo_root}/3rd/mruby/mrbgems/*/{src,core,include}/**/#{native_glob}"] +
             external_gem_native_srcs(repo_root)
    native = native.reject { |p| p =~ %r{/mruby-[a-z0-9]+-compiled/src/register\.cxx\z} }
    [(ruby.map { |p| File.expand_path(p) }.to_set - closed).to_a.sort, native.map { |p| File.expand_path(p) }.uniq.sort]
  end

  def outside_world_tokens(repo_root)
    ruby, native = outside_world_files(repo_root)
    tokens = Set.new
    (ruby + native).each do |path|
      text = File.read(path, encoding: 'BINARY')
      text.scan(/[A-Za-z_][A-Za-z0-9_]*[?!=]?/) do |t|
        tokens << t
        tokens << t.chomp('=').chomp('?').chomp('!')
      end
      text.scan(/MRB_(?:Q?SYM)_([QBE])\((\w+)\)/) do |kind, name|
        tokens << name + { 'Q' => '?', 'B' => '!', 'E' => '=' }.fetch(kind)
      end
    end
    tokens
  end

  # Runs bc2cpp.rb for each compiled gem and the closed-world parse; returns
  # everything eligibility needs.
  def analyze(repo_root, mrbc, unregistered: STATIC_DISPATCH_UNREGISTERED)
    cache = ENV['STATIC_DISPATCH_CACHE'] # dev-only: reuse bc2cpp.rb output across runs
    runs = GEMS.to_h do |gem|
      paths = cache && %w[out err].map { |k| File.join(cache, "#{gem}.#{k}") }
      if paths&.all? { |p| File.exist?(p) }
        out, err = paths.map { |p| File.read(p, encoding: 'UTF-8') }
      else
        out, err = NeverCalledRegistrations.run_bc2cpp_full(gem, repo_root, mrbc)
        if paths
          FileUtils.mkdir_p(cache)
          paths.zip([out, err]).each { |p, s| File.write(p, s) }
        end
      end
      [gem, { gen: out, entries: NeverCalledRegistrations.parse_compiled_entries(err),
              hand: File.read(File.join(repo_root, gem, 'src', 'register.cxx'), encoding: 'UTF-8') }]
    end
    ireps, registry, superclass_of = closed_world(repo_root, mrbc)
    subclassed = subclassed_paths(repo_root, superclass_of)

    # Candidates: compiled entries still registered, plus ones already
    # unregistered by this mechanism (so re-running the proof after the
    # registrations are gone re-checks exactly the same set).
    candidates = []
    overridden = Set.new # "Owner#name" whose compiled override stays registered
    runs.each do |gem, r|
      live = (registrations(r[:hand]) + registrations(r[:gen])).map(&:first).to_set
      r[:entries].each do |m|
        key = "#{m[:owner]}##{m[:name]}"
        listed = unregistered.include?(key)
        overridden << key if live.include?(m[:entry]) && !listed
        candidates << m.merge(gem: gem, listed: listed) if listed || live.include?(m[:entry])
      end
    end

    body_of = {} # method-body irep label => [owner, name]
    registry.each do |name, defs|
      defs.each { |d| body_of[d.irep] = [d.owner, name] if d.irep }
    end
    parent = {}
    ireps.each_value { |irep| irep.reps.each { |c| parent[c] = irep.label } }
    # Nearest enclosing method body (the irep itself when it is one); nil for
    # the root, class bodies and blocks created directly in them.
    method_of = {}
    ireps.each_key do |label|
      up = label
      up = parent[up] until up.nil? || body_of.key?(up)
      method_of[label] = up
    end

    dynamic = Set.new(ALWAYS_DYNAMIC)
    fragments = Set.new
    ireps.each_value do |irep|
      irep.instructions.each do |insn|
        next unless insn.op == 'SUPER'

        up = method_of[irep.label]
        dynamic << body_of[up][1] if up
      end
      irep.pool.each do |s|
        next unless s.is_a?(String)

        dynamic << s if s.match?(IDENT)
        fragments << s if s.match?(FRAGMENT)
      end
    end
    runs.each_value do |r|
      dynamic.merge(c_literals(r[:gen], exempt: embed_guard_fallback_only(r[:gen], subclassed)))
             .merge(c_literals(r[:hand]))
    end
    dynamic.merge(outside_world_tokens(repo_root))

    # Which bytecode can run. No method body -- compiled or not -- runs as
    # bytecode except after a dynamic lookup of its own name: a direct C++ call
    # targets the compiled `_impl`, never bytecode. A body whose compiled
    # override stays registered can only run as bytecode before its gem's
    # gem_init installs that override, i.e. during mrblib load, so for those
    # only a LOAD-phase lookup counts: `load` is the fixpoint of names sent by
    # the root and class bodies (and blocks made in them) plus by the bodies
    # those names reach. Everything else -- an uncompiled method, a compiled
    # one left unregistered -- runs whenever its name is looked up at all.
    # Blocks run whenever their method might: always inside a registered
    # compiled method (bc2cpp may keep a block as a bytecode proc), otherwise
    # with the method. Names are only ever added, so both fixpoints converge.
    sends = lambda do |irep, into|
      grew = false
      irep.instructions.each do |insn|
        name = if SEND_OPS.include?(insn.op) then insn.args[NAME_ARG, 1]
               else IMPLICIT_DISPATCH_NAMES[insn.op]
               end
        grew = true if name && into.add?(name)
      end
      grew
    end
    fixpoint = lambda do |into, runs|
      done = Set.new
      loop do
        grew = false
        ireps.each_value do |irep|
          next if done.include?(irep.label) || !runs.call(irep.label)

          done << irep.label
          grew = true if sends.call(irep, into)
        end
        break unless grew
      end
    end

    load_bodies, load_names = load_phase(ireps, body_of, method_of, overridden)
    dynamic.merge(load_names)
    fixpoint.call(dynamic, lambda do |label|
      m = method_of[label]
      next true if m.nil?

      owner, name = body_of[m]
      if overridden.include?("#{owner}##{name}")
        label == m ? load_bodies.include?(m) : true
      else
        dynamic.include?(name)
      end
    end)

    { registered: candidates, dynamic: dynamic, fragments: fragments, load: load_names, load_bodies: load_bodies }
  end

  LITERAL_OPS = %w[LOADL LOADSYM LOADNIL LOADTRUE LOADFALSE STRING STRCAT ARRAY ARRAY2 ARYCAT ARYPUSH ARYDUP
                   HASH HASHADD HASHCAT RANGE_INC RANGE_EXC SYMBOL LAMBDA BLOCK METHOD INTERN].freeze
  INSTANTIATING = %w[new allocate dup clone load _load marshal_load].freeze
  ENGINE_RE = /\A(?:Game|RPG2k3?|LCF|RGSS)(?:::|\z)/

  # What each register of `irep` can hold, flow-insensitively: the join of
  # every write to it anywhere in the irep (so a value reaching a send along
  # any path is covered). [:const, Name] | :core (a literal) | :self |
  # :unknown. Registers never written here (arguments, locals set by a
  # caller) are :unknown; R0 is :self.
  def register_kinds(irep)
    kinds = Hash.new { |h, k| h[k] = [] }
    # APOST writes a whole run of registers, not just its first argument --
    # not modelled, so an irep using it gets no register facts at all.
    return Hash.new(:unknown) if irep.instructions.any? { |i| i.op == 'APOST' }

    irep.instructions.each do |insn|
      args = insn.args.to_s.split(/\s+/)
      dst = args.first&.then { |a| a[/\AR(\d+)\z/, 1] }
      next unless dst

      kinds[dst] << case insn.op
                    when 'GETCONST', 'GETMCNST' then [:const, args[1].to_s.split('::').last]
                    when 'LOADSELF' then :self
                    when 'MOVE' then [:move, args[1].to_s[/\AR(\d+)\z/, 1]]
                    else
                      insn.op.start_with?('LOADI') || LITERAL_OPS.include?(insn.op) ? :core : :unknown
                    end
    end
    resolve = lambda do |reg, seen = Set.new|
      return :self if reg == '0' && !kinds.key?('0')
      return :unknown unless kinds.key?(reg) && seen.add?(reg)

      vals = kinds[reg].map { |k| k.is_a?(Array) && k[0] == :move ? resolve.call(k[1], seen.dup) : k }.uniq
      vals.size == 1 ? vals.first : :unknown
    end
    Hash.new { |h, reg| h[reg] = resolve.call(reg) }
  end

  BLOCK_ENDERS = %w[RETURN RETURN_BLK RETNIL RETTRUE RETFALSE RETSELF BREAK RAISEIF EXCEPT RESCUE].freeze

  # The receiver kind of every send in `irep` (nil for other instructions).
  # Within one basic block the last write before the send is exact; a
  # register not written earlier in the same block (so its value may arrive
  # along another path) falls back to register_kinds' whole-irep join, which
  # covers every path. Blocks start at every jump target, every catch-handler
  # target, and right after every jump/return/raise.
  def receiver_kinds(irep)
    global = register_kinds(irep)
    insns = irep.instructions
    starts = Set.new
    insns.each_with_index do |insn, i|
      if insn.op.start_with?('JMP')
        target = insn.args.to_s.split(/\s+/).last
        starts << target.to_i if target.to_s.match?(/\A\d+\z/)
      end
      starts << insns[i + 1].addr.to_i if insns[i + 1] && (insn.op.start_with?('JMP') || BLOCK_ENDERS.include?(insn.op))
    end
    (irep.catch_handlers || []).each { |h| starts << h.target.to_i }

    local = {}
    kind_of = ->(reg) { local.key?(reg) ? local[reg] : global[reg] }
    insns.map do |insn|
      local = {} if starts.include?(insn.addr.to_i) || insn.op == 'APOST'
      args = insn.args.to_s.split(/\s+/)
      reg = args.first.to_s[/\AR(\d+)\z/, 1]
      kind = if SEND_OPS.include?(insn.op) && insn.op != 'LOADSYM'
               insn.op.start_with?('SS') ? :self : kind_of.call(reg)
             end
      if reg
        local[reg] = case insn.op
                     when 'GETCONST', 'GETMCNST' then [:const, args[1].to_s.split('::').last]
                     when 'LOADSELF' then :self
                     when 'MOVE' then kind_of.call(args[1].to_s[/\AR(\d+)\z/, 1])
                     else insn.op.start_with?('LOADI') || LITERAL_OPS.include?(insn.op) ? :core : :unknown
                     end
      end
      kind
    end
  end

  # LOAD phase: which method bodies can run as bytecode while mrblib is
  # still loading -- before any compiled gem's gem_init has installed an
  # override. Only the root and class bodies (and blocks made there) run on
  # their own. From there a send can only reach, by receiver:
  #   - self in a class body / a constant: a singleton method;
  #   - a literal: a core-class method (e.g. mruby-rgss's own Array patch);
  #   - self inside a running method: that method's own kind (instance or
  #     singleton) of body;
  #   - anything else: a singleton or core-class method -- or, only if some
  #     load-phase code may have instantiated an engine class (never true in
  #     this tree today: load-time `new` only ever targets Struct/Color/
  #     Rect/Array), any engine instance method too.
  # Name-matched, never owner-matched, within each kind: coarse, but always a
  # superset. Returns [runnable method-body labels, every name they send].
  def load_phase(ireps, body_of, method_of, overridden)
    by_name = Hash.new { |h, k| h[k] = [] }
    body_of.each { |label, (owner, name)| by_name[name] << [label, owner] }
    singleton = ->(owner) { owner.end_with?('.singleton') }
    core = ->(owner) { !singleton.call(owner) && !owner.match?(ENGINE_RE) }
    engine_instance = ->(owner) { !singleton.call(owner) && owner.match?(ENGINE_RE) }
    # Classes whose instances would matter: engine classes with overridden
    # instance methods (a core class like the Array mruby-rgss-compiled
    # patches always has live instances and is already handled as :core).
    instance_owners = overridden.map { |k| k.split('#', 2).first }.select { |o| engine_instance.call(o) }
                                .to_set { |o| o.split('::').last }

    irep_of_method = Hash.new { |h, k| h[k] = [] }
    method_of.each { |l, m| irep_of_method[m] << l if m }
    runnable = ireps.keys.select { |l| method_of[l].nil? }.to_set
    bodies = Set.new
    names = Set.new
    engine_live = false
    queue = runnable.to_a
    until queue.empty?
      label = queue.shift
      irep = ireps.fetch(label)
      recvs = receiver_kinds(irep)
      m = method_of[label]
      self_kind = if m.nil? then :class
                  else singleton.call(body_of[m][0]) ? :class : :instance
                  end
      irep.instructions.each_with_index do |insn, idx|
        next unless SEND_OPS.include?(insn.op) && insn.op != 'LOADSYM'

        name = insn.args[NAME_ARG, 1]
        next unless name

        names << name
        recv = recvs[idx]
        recv = self_kind if recv == :self
        if INSTANTIATING.include?(name) &&
           (recv == :unknown || recv == :instance || (recv.is_a?(Array) && instance_owners.include?(recv[1])))
          engine_live = true
          warn "load_phase: engine instance possible at load: #{recv.inspect}.#{name} " \
               "#{irep.file}:#{insn.lineno}" if ENV['STATIC_DISPATCH_DEBUG']
        end
        targets = by_name[name].select do |_l, owner|
          case recv
          when :class, Array then singleton.call(owner) || core.call(owner)
          when :core then core.call(owner)
          when :instance then !singleton.call(owner)
          else singleton.call(owner) || core.call(owner) || (engine_live && engine_instance.call(owner))
          end
        end
        targets.each do |l, _o|
          next unless bodies.add?(l)

          irep_of_method[l].each { |k| queue << k if runnable.add?(k) }
        end
      end
      # An engine instance may exist at load after all: earlier filtering is
      # no longer sound, so fall back to the receiver-blind cascade entirely.
      return load_phase_all_names(ireps, method_of, body_of) if engine_live
    end
    [bodies, names]
  end

  # The original, receiver-blind cascade -- the fallback the moment any
  # load-phase code may instantiate an engine class.
  def load_phase_all_names(ireps, method_of, body_of)
    names = Set.new
    bodies = Set.new
    loop do
      grew = false
      ireps.each_value do |irep|
        m = method_of[irep.label]
        next unless m.nil? || names.include?(body_of[m][1])

        bodies << m if m
        irep.instructions.each do |insn|
          next unless SEND_OPS.include?(insn.op)

          name = insn.args[NAME_ARG, 1]
          grew = true if name && names.add?(name)
        end
      end
      break unless grew
    end
    [bodies, names]
  end

  def dynamic_name?(name, dynamic, fragments)
    return true if dynamic.include?(name) || !name.match?(IDENT)
    return true if name.end_with?('=', '?', '!') && dynamic.include?(name[0..-2])

    fragments.any? { |f| f != name && (name.start_with?(f) || name.end_with?(f)) }
  end

  # Registered compiled entries (owner/name/entry/gem) no runtime lookup can
  # ever reach.
  def eligible(analysis)
    analysis[:registered].select do |m|
      m[:owner].match?(NeverCalledRegistrations::SAFE_UNREGISTER_OWNER_RE) &&
        !dynamic_name?(m[:name], analysis[:dynamic], analysis[:fragments])
    end
  end
end

if $PROGRAM_NAME == __FILE__
  repo_root = File.expand_path('../..', __dir__)
  mrbc = ENV['MRBC'] || 'mrbc'
  analysis = StaticDispatchRegistrations.analyze(repo_root, mrbc)
  list = StaticDispatchRegistrations.eligible(analysis)
  warn "registered compiled entries: #{analysis[:registered].size}, statically-dispatched-only: #{list.size}"
  list.sort_by { |m| [m[:owner], m[:name]] }.each { |m| puts "#{m[:owner]}##{m[:name]}\t#{m[:entry]}\t#{m[:gem]}" }

  if ARGV.include?('--write')
    path = File.join(__dir__, 'static_dispatch_unregistered.rb')
    src = File.read(path)
    keys = list.map { |m| "#{m[:owner]}##{m[:name]}" }.uniq.sort
    body = keys.empty? ? 'Set[].freeze' : "Set[\n#{keys.map { |k| "  #{k.inspect}," }.join("\n")}\n].freeze"
    File.write(path, src.sub(/^STATIC_DISPATCH_UNREGISTERED = Set\[.*?\]\.freeze$/m,
                             "STATIC_DISPATCH_UNREGISTERED = #{body}"))
    warn "wrote #{keys.size} name(s) to #{path}"
  end
end
