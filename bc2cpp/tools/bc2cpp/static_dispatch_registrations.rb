# frozen_string_literal: true

# STATIC_DISPATCH_UNREGISTRATION: the sound form of "a devirtualized method
# does not need its mrb_define_method registration".
#
# A registration exists only so mruby's dynamic method-table lookup can find
# the compiled method. Dropping it was rejected because "every call
# site devirtualized" is a per-call-site property no pass tracked. This file
# asks a stronger, name-level question with a default of "dynamic": can ANY
# runtime lookup of this name happen? A name is eligible only when all of
# these come back empty:
#
#   1. Bytecode that can run (see "Which bytecode can run" in `analyze` and
#      `load_phase`): the root and class bodies, blocks inside registered
#      compiled methods, and bodies of other dynamic names, to a fixpoint.
#      Every SEND*/LOADSYM name counts, plus the operator names implicit-
#      dispatch opcodes (ADD, GETIDX, ...) stand for.
#   2. Compiled code's own dynamic dispatch: every string literal in the
#      generated C++ of all three gems (a guarded call's `mrb_funcall_id`
#      fallback, POLY dispatch, a symbol literal, a redefinition guard),
#      outside the name's own registration call.
#   3. `super`: the enclosing method's name for every SUPER op.
#   4. Names built at runtime: every string-pool literal, plus any name that
#      starts or ends with a pool literal of two or more identifier characters
#      (`"#{field}="`), or ends in `=`/`?`/`!` with a dynamic base name.
#   5. Everything outside the closed world, scanned as plain text: mruby core
#      and core-gem mrblib (Enumerable calls `each`, ...), the external gems,
#      every other maker gem's mrblib and every native source,
#      every gem's test/, scripts/, tools/ (except
#      tools/bc2cpp). Every identifier counts, plus MRB_SYM_Q/_B/_E(x).
#   6. mruby's implicit protocol names (ALWAYS_DYNAMIC), as a backstop for 5.
#
# Only internal RPG2000/2003 owners (NeverCalledRegistrations::
# SAFE_UNREGISTER_OWNER_RE) qualify: RGSS classes are the scripting API a
# game's Data/Scripts.rxdata calls. The closed list (--closed-only) also takes
# RGSS owners and the engine modules' own singletons (CLOSED_OWNER_RE): the
# closed build is RPG2000/2003 only, whose games carry no Ruby, so no script
# can call an RGSS method there.
#
# What remains is reached only through direct `Owner_name_impl(...)` calls, so
# dropping the registration lets `-Wl,--gc-sections` discard the mrb_get_args
# wrapper and the name string. The interpreted `def` is unaffected.
#
# Residual risk: a name assembled at runtime from data that appears nowhere as
# a literal or fragment (read from a game file, then `send`) would be missed.
# Nothing does that for an RPG2000/2003-internal class today, and a listed name
# must stay free of dynamic references, or it ships a NoMethodError.
require 'digest'
require 'fileutils'
require 'json'
require 'set'
require 'strscan'
require_relative 'bytecode_ir_ops'
require 'tmpdir'
require_relative 'compiled_gems'
require_relative 'never_called_registrations'
require_relative 'static_dispatch_lists'
require_relative 'symbol_cache'
require_relative 'bytecode_ir'
require_relative 'bytecode_ir_containers'
require_relative 'static_dispatch_fragment_uses'
require_relative 'static_dispatch_symbol_uses'
require_relative 'owner_call_direct'
require_relative 'core_private_ruby'
require_relative 'core_enumerator_free'
require_relative 'core_methods'
require_relative 'core_native_candidates'
require_relative 'native_owner_map'

module StaticDispatchRegistrations
  GEMS = %w[mruby-rpg2k-compiled mruby-lcf-compiled mruby-rgss-compiled].freeze
  # Ops::SEND plus LOADSYM, whose symbol operand is read as a method name.
  SEND_OPS = (BytecodeIR::Ops::SEND | %i[LOADSYM]).freeze
  NAME_ARG = %r{:([\w+\-*/<>=!?\[\]&|^~%@]+)}
  # The identifier group accepts `$`: a generated symbol for an operator or
  # predicate name carries the mangling's `$<hex>` escapes
  # (`LCF__File_$5b$5d` for `LCF::File#[]`, `Game__Battle_enemy_active$3f` for
  # `#enemy_active?`). `\w+` stops at the first `$`, so those registrations read
  # back as a truncated name that matched no owner and counted as an extra
  # dynamic reference -- which is how a list of provably-unreachable names
  # (the open static dispatch list) suddenly looked reachable.
  REGISTRATION_CALL = /(?:mrb_define_(?:private_|class_)?method|bc2cpp_define_private_class_method)\(\s*M\s*,\s*([A-Za-z_][A-Za-z0-9_$]*)\s*,\s*"((?:[^"\\]|\\.)*)"\s*,\s*([A-Za-z_][A-Za-z0-9_$]*)\s*,[^;]*\);/m
  # LEFT_OUT (codegen_emit.rb): what stands in for a left-out entry's registration, which looks nothing up.
  LEFT_OUT_CALL = /bc2cpp_left_out\(\s*M\s*,\s*[A-Za-z_][A-Za-z0-9_$]*\s*,\s*"(?:[^"\\]|\\.)*"\s*,\s*(?:true|false)\s*\);/m
  # A Ruby identifier, and -- because a generated C++ symbol may contain the
  # mangling's `$<hex>` escapes -- a generated one. Kept lowercase-initial and
  # `$`-accepting so `Game__Battle_enemy_active$3f` is recognized as the
  # identifier it is rather than as a runtime-built name.
  IDENT = /\A[a-z_][A-Za-z0-9_$]*[?!=]?\z/
  FRAGMENT = /\A[\w?!=]{2,}\z/
  # A literal that can turn a base name into its setter / predicate / bang name (SUFFIX_BASES).
  SUFFIX_LITERAL = /\A[=?!]\z/
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
    body = src.gsub(REGISTRATION_CALL, '').gsub(LEFT_OUT_CALL, '').gsub(%r{/\*.*?\*/}m, '').gsub(%r{//[^\n]*}, '')
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

  # A proc over a bytecode irep (mrb_proc_new, mrb_closure_new), as opposed to mrb_proc_new_cfunc*.
  BYTECODE_PROC = /\bmrb_(?:proc_new|closure_new)\s*\(/

  # NON_LOOKUP_HELPERS: the generated helpers whose use of a name finds no compiled method. Each is the else arm of
  # a proof (symbol_cache.rb): bc2cpp_guard_violation and bc2cpp_hint_violation raise without dispatching;
  # bc2cpp_nomethod(_raise) dispatches only to report a violated proof, for a receiver the closed world proved
  # answers the name with no method at all, so its lookup finds nothing, registered or not; bc2cpp_nil_receiver
  # looks the name up on nil, whose ancestors hold no SAFE_UNREGISTER_OWNER_RE owner. (The debug-only
  # -DBC2CPP_*_DISPATCH / -DBC2CPP_HINT_VIOLATION_LOG builds dispatch there; with the registration gone that finds
  # the interpreted method instead, or the BC2CPP_UNREGISTERED_VERIFY stub.)
  NON_LOOKUP_HELPERS = %w[nomethod nomethod_raise guard_violation hint_violation nil_receiver].to_set.freeze
  SYMBOL_VALUE_USE = /(?:mrb_symbol_value\(|==\s*)bc2cpp_sym\(M, (\d+)\)/
  KEYWORD_TABLE = /mrb_sym bc2cpp_kw_table\w*\[\d+\] = \{([^}]*)\}/

  # The names in `src`'s symbol table none of whose uses is a dynamic lookup of a compiled owner's method: each use
  # is a NON_LOOKUP_HELPERS call or an EMBED_GUARD_FALLBACK one.
  #
  # EMBED_GUARD_FALLBACK: the by-name fallback of a MONO_EMBED_GUARD for that same method, on an owner nothing
  # subclasses. The fallback runs only when the receiver's class is not exactly the owner; with no subclass
  # anywhere, such a receiver's method lookup never reaches the owner's method table, so it cannot need the owner's
  # registration -- it finds the name on its own class or raises NoMethodError, registered or not.
  #
  # `symbol_values` (SYMBOL_USES holds): a symbol only made into a value (`mrb_symbol_value(bc2cpp_sym(M, i))`),
  # compared (`== bc2cpp_sym(M, i)`) or listed as a keyword name looks nothing up either.
  def lookup_free_names(src, subclassed, symbol_values: false)
    table = src[SYM_TABLE, 1] or return Set.new
    names = table.scan(STRING_LITERAL).map { |(s)| unescape(s) }
    uses = Hash.new(0)
    quiet = Hash.new(0)
    src.scan(/bc2cpp_sym\(M, (\d+)\)/) { |(i)| uses[i.to_i] += 1 }
    if symbol_values
      src.scan(SYMBOL_VALUE_USE) { |(i)| quiet[i.to_i] += 1 }
      src.scan(KEYWORD_TABLE) { |(list)| list.scan(/bc2cpp_sym\(M, (\d+)\)/) { |(i)| quiet[i.to_i] += 1 } }
    end
    SymbolCache.send_index_kinds(src).each do |kind, i|
      uses[i] += 1
      quiet[i] += 1 if NON_LOOKUP_HELPERS.include?(kind)
    end
    src.scan(EMBED_GUARD_FALLBACK) do |name, owner, idx|
      i = idx.to_i
      next unless names[i] == name
      next if owner.end_with?('.singleton') || subclassed?(owner, subclassed)

      quiet[i] += 1
    end
    guarded_owner_calls(src, subclassed).each { |i| quiet[i] += 1 }
    quiet.select { |i, n| n == uses[i] }.keys.to_set { |i| names[i] }
  end

  # OWNER_CALL_GUARDED: `bc2cpp_owner_call` (symbol_cache.rb) runs only a method its one lookup finds on a listed
  # owner and raises a closed-world violation for any other definer, so it needs no registration but its listed
  # owners'. When it is the final else of an exact-class guard chain on the same receiver (POLY_SMALL_N,
  # MONO_EMBED_GUARD, the RGSS native-direct arms), a listed owner the chain tests is a class (bc2cpp_class_is never
  # holds for a module) whose own instances took their arm; with nothing subclassing it, no other receiver's lookup
  # passes through its method table. A listed owner the call carries a direct entry for (OWNER_CALL_DIRECT,
  # owner_call_direct.rb) needs no table entry either: the call walks the receiver's ancestors itself and answers
  # with that entry where the lookup would have found it. A call so covering every listed owner of the closed
  # world's (CLOSED_OWNER_RE, a superset of the open list's) looks up nothing either list may drop: the symbol index
  # of each.
  OWNER_CALL_SITE = /^[ \t]*(?:BC2CPP_COLD_ARM[ \t]+)?\w+ = bc2cpp_owner_call(?:_argv)?\(M, (\w+), (\d+), \d+, BC2CPP_OWNERS(?:_D)?\((.*)$/
  OWNER_DIRECT = /BC2CPP_OWNER_DIRECT\("((?:[^"\\]|\\.)*)"/

  def guarded_owner_calls(src, subclassed)
    slots = {}
    src.scan(/bc2cpp_owner_class_(\d+)\(mrb_state\* M\) \{\n[^\n]*\n[^\n]*\n\s*static const char\* const path\[\] = \{([^}]*)\}/) do |n, path|
      slots["bc2cpp_owner_class_#{n}(M)"] = path.scan(STRING_LITERAL).map { |(s)| unescape(s) }.join('::')
    end
    lines = src.lines
    found = []
    lines.each_with_index do |line, at|
      site = OWNER_CALL_SITE.match(line) or next
      recv, idx, rest = site.captures
      guarded = (at.positive? && lines[at - 1].strip == '} else {' && OwnerCallDirect.guard_chain_classes(lines, at - 1, recv, slots)) || Set.new
      direct = rest.scan(OWNER_DIRECT).to_set { |(o)| unescape(o) }
      # The rest of the line holds no other string literal: registers, the block, the trailing comment.
      owners = rest.scan(STRING_LITERAL).map { |(s)| unescape(s) }.grep(CLOSED_OWNER_RE)
      covered = owners.all? do |o|
        direct.include?(o) || (guarded.include?(o) && !o.end_with?('.singleton') && !subclassed?(o, subclassed))
      end
      next unless covered

      found << idx.to_i
    end
    found
  end

  # Every class path something could subclass, conservatively: each
  # superclass in the closed world, plus any constant path written after `<`,
  # inside `Class.new(`, or anywhere in an `mrb_define_class*` call, in any
  # scanned source. A written path may be relative, so an owner counts as
  # subclassed when it equals one or ends with `::` plus one (`< Base` inside
  # `RPG2k::Scene` blocks every `...::Base`). closed_only: the closed binary's sources only, as outside_world_files
  # reads them (the check scripts' `Class.new(klass)` fixtures are linked into no build). A whole-line Ruby comment
  # is no code (`# ... Array<Game::Actor>` named a superclass).
  def subclassed_paths(repo_root, superclass_of, closed_only: false)
    found = superclass_of.values.grep(String).to_set
    ruby, native = outside_world_files(repo_root, closed_only: closed_only)
    (closed_world_mrblib_srcs(repo_root, core_gems: nil) + ruby).each do |f|
      text = File.read(f, encoding: 'BINARY').gsub(/^[ \t]*#[^\n]*/, '')
      text.scan(/(?:<\s*|Class\.new\(\s*)(?:::)?((?:[A-Z]\w*::)*[A-Z]\w*)/) { |(n)| found << n }
      # A superclass the scan cannot name (`Class.new(klass)`) could be any.
      found << ANY_CLASS if text.match?(/Class\.new\(\s*[a-z_@$]/)
    end
    native.each do |f|
      text = File.read(f, encoding: 'BINARY')
      next unless text.match?(DEFINE_CLASS)

      # A define call's superclass is its last argument: every capitalized name in it counts. One that is no
      # builtin class (BUILTIN_SUPERCLASS) may hold a superclass named by string (`mrb_class_get(M, "Foo")`) far
      # from the call, so then any capitalized string literal in the file counts. The define call's own class name
      # is not a superclass.
      supers = define_class_superclasses(text)
      supers.each { |arg| arg.scan(/\b([A-Z]\w*)\b/) { |(n)| found << n } }
      next if supers.all? { |arg| arg.match?(BUILTIN_SUPERCLASS) }

      text.scan(/"([A-Z]\w*(?:::[A-Z]\w*)*)"/) { |(n)| found << n }
    end
    found
  end

  ANY_CLASS = :any
  DEFINE_CLASS = /\bmrb_define_class(?:_under)?(?:_id)?\(/
  # A superclass argument that is a builtin class: a field of mrb_state (`M->object_class`, `mrb->eStandardError_class`)
  # or one of mruby's builtin-exception macros (E_STANDARD_ERROR, ...).
  BUILTIN_SUPERCLASS = /\A(?:(?:M|mrb)->\w+_class|E_[A-Z_]+)\z/

  # The last argument of every DEFINE_CLASS call in `text`, stripped (nil-free; an unbalanced call yields "").
  def define_class_superclasses(text)
    supers = []
    pos = 0
    while (m = DEFINE_CLASS.match(text, pos))
      i = m.end(0)
      depth = 1
      arg_start = i
      while i < text.length && depth.positive?
        case text[i]
        when '"', "'"
          q = text[i]
          i += 1
          i += text[i] == '\\' ? 2 : 1 while i < text.length && text[i] != q
        when '(' then depth += 1
        when ')' then depth -= 1
        when ',' then arg_start = i + 1 if depth == 1
        end
        i += 1
      end
      supers << (depth.zero? ? text[arg_start...(i - 1)].strip : '')
      pos = m.end(0)
    end
    supers
  end

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
      # The engine's own Ruby. Core mrblib stays an outside source here (its sends
      # and names are dynamic references: outside_world_tokens), as before it was compiled.
      ireps, root = compile_ireps(closed_world_mrblib_srcs(repo_root, core_gems: nil), 'static_dispatch_probe', tmp)
      tuple = build_registry(ireps, root)
      [ireps, tuple[0], tuple[1], tuple[6].keys, tuple]
    end
  end

  # closed_only: the closed world's own program. Ruby test files, scripts/, tools/ and
  # the workflows are not linked into the shipped closed binary, so they add no
  # lookups to it. Native test sources stay: they are compiled into it.
  def outside_world_files(repo_root, closed_only: false)
    closed = closed_world_mrblib_srcs(repo_root, core_gems: nil).map { |p| File.expand_path(p) }.to_set
    # scripts/ and the CI workflows are scanned whatever their extension: the
    # boot checks feed inline Ruby (heredocs in *.bash) to the real binary's
    # `--script`, which runs it inside the same VM.
    ruby = foreign_mrblib_srcs(repo_root) +
           Dir["#{repo_root}/mruby-*/mrblib/**/*.rb"] +
           (closed_only ? [] : Dir["#{repo_root}/mruby-*/test/**/*.rb"] +
                               Dir["#{repo_root}/scripts/**/*"].select { |p| File.file?(p) } +
                               Dir["#{repo_root}/tools/**/*.rb"].reject { |p| p.include?('/tools/bc2cpp/') }) +
           # The workflows' inline Ruby runs in the desktop binary (`--script`); the closed library is linked only
           # into trace_host.cxx, which runs no script.
           (closed_only ? [] : Dir["#{repo_root}/.github/**/*"].select { |p| File.file?(p) })
    native_glob = '*.{c,cc,cpp,cxx,h,hh,hpp,hxx,inc}'
    native = Dir["#{repo_root}/{src,app,include}/**/#{native_glob}"] +
             Dir["#{repo_root}/mruby-*/{src,include}/**/#{native_glob}"] +
             Dir["#{repo_root}/3rd/mruby/{src,include}/**/#{native_glob}"] +
             Dir["#{repo_root}/3rd/mruby/mrbgems/*/{src,core,include}/**/#{native_glob}"] +
             external_gem_native_srcs(repo_root)
    native = native.reject { |p| p =~ %r{/mruby-[a-z0-9]+-compiled/src/register\.cxx\z} }
    if closed_only
      ruby = ruby.reject { |p| p.start_with?(*OTHER_MAKER_GEMS.map { |g| "#{repo_root}/#{g}/" }) }
      native = native.reject { |p| p.start_with?(*OTHER_MAKER_GEMS.map { |g| "#{repo_root}/#{g}/" }) }
      unlinked = closed_unlinked_dirs(repo_root)
      # The closed world holds every mrblib file of these gems the closed build loads; one outside it is a file their
      # mrbgem.rake swaps out there (mruby-rpg2k's scene/map_tts.rb, for mrblib_limited/map_tts_off.rb).
      world_gems = %w[mruby-rpg2k mruby-lcf mruby-rgss].map { |g| "#{File.expand_path(repo_root)}/#{g}/mrblib/" }
      ruby = ruby.map { |p| File.expand_path(p) }.reject { |p| p.start_with?(*unlinked, *world_gems) }
      native = native.map { |p| File.expand_path(p) }.reject { |p| p.start_with?(*unlinked) }
      native << File.expand_path('scripts/bc2cpp/trace_host.cxx', repo_root)
    end
    [(ruby.map { |p| File.expand_path(p) }.to_set - closed).to_a.sort, native.map { |p| File.expand_path(p) }.uniq.sort]
  end

  # CLOSED_LINKED_ONLY (closed only): the source trees the closed binary does not contain, as directory prefixes.
  # Their Ruby never loads and their C never runs there, so a name they spell is no lookup in it:
  #   - a core mruby-* gem outside the closed build's gem closure (bc2cpp_closed_core_gems: mruby-socket,
  #     mruby-enum-lazy, mruby-complex, ...), and an external gem its rpg_maker_gems lines leave out
  #     (mruby-onig-regexp);
  #   - app/, the device firmwares and their tools: the closed binary is the libmruby above linked into
  #     scripts/bc2cpp/trace_host.cxx (scripts/bc2cpp/trace_host.bash), which outside_world_files scans instead.
  def closed_unlinked_dirs(repo_root)
    root = File.expand_path(repo_root)
    core = bc2cpp_closed_core_gems(root).to_set
    lines = bc2cpp_rpg_maker_gem_lines(bc2cpp_build_config_text, 'closed', root)
    # Only mruby-* gems: the closure follows add_dependency lines, and a HAL gem is added by a rake's own Ruby
    # (mruby-io's `spec.build.gem core: 'hal-posix-io'`), so hal-* stays scanned whatever the closure says.
    dirs = Dir["#{root}/3rd/mruby/mrbgems/mruby-*/"].map { |d| File.basename(d) }.reject { |g| core.include?(g) }
                                                    .map { |g| "#{root}/3rd/mruby/mrbgems/#{g}/" }
    dirs += %w[mruby-marshal mruby-onig-regexp mruby-stringio].reject { |g| lines.key?(g) }
                                                              .map { |g| "#{root}/3rd/#{g}/" }
    dirs << "#{root}/app/"
  end

  # `core`: with closed_only, the closed world's {mrbc:, superclass_of:, struct_owners:} turns on CORE_BYTECODE_TOKENS
  # for the Ruby under 3rd/ (and adds the program-core gems' mrblib, which no other scan reads).
  # `text`: a Set that also receives every token read as text (Ruby read as text, native naming-macro arguments),
  # the only tokens SUFFIX_BASES needs.
  def outside_world_tokens(repo_root, closed_only: false, core: nil, text: nil)
    ruby, native = outside_world_files(repo_root, closed_only: closed_only)
    tokens = Set.new
    text ||= Set.new
    naming = closed_only ? naming_macros(native) : []
    if closed_only && core
      third = "#{File.expand_path(repo_root)}/3rd/"
      precise, ruby = ruby.partition { |p| p.end_with?('.rb') && p.start_with?(third) }
      unlinked = closed_unlinked_dirs(repo_root)
      precise |= core_compiled_mrblib_srcs(repo_root, BC2CPP_CORE_MRBLIB_GEMS + BC2CPP_EXTERNAL_MRBLIB_GEMS)
                 .map { |p| File.expand_path(p) }.reject { |p| p.start_with?(*unlinked) }
      found = Set.new
      reflective = core_bytecode_tokens(precise.sort, found, **core)
      tokens.merge(found)
      cite(found, 'core Ruby sends it to a receiver that may be an engine object')
      reflective.each do |path, names|
        next ruby << path unless names

        names = names.flat_map { |n| [n, n.chomp('=').chomp('?').chomp('!')] }.to_set
        tokens.merge(names)
        text.merge(names)
        cite(names, "a symbol of #{path.delete_prefix("#{File.expand_path(repo_root)}/")}, which sends a computed name")
      end
    end
    (ruby + native).each do |path|
      src = File.read(path, encoding: 'BINARY')
      found = Set.new
      if closed_only && native.include?(path)
        native_name_tokens(src, found, naming, text_tokens: text)
      else
        src.scan(/[A-Za-z_][A-Za-z0-9_]*[?!=]?/) do |t|
          base = t.chomp('=').chomp('?').chomp('!')
          found << t << base
          text << t << base
        end
        src.scan(/MRB_(?:Q?SYM)_([QBE])\((\w+)\)/) do |kind, name|
          found << name + { 'Q' => '?', 'B' => '!', 'E' => '=' }.fetch(kind)
        end
      end
      tokens.merge(found)
      cite(found, "named in #{path.delete_prefix("#{File.expand_path(repo_root)}/")}")
    end
    tokens
  end

  # CORE_BYTECODE_TOKENS (closed only): core and external-gem Ruby, read as bytecode instead of text. A send there
  # names a method only if its receiver may be an RPG2000/2003 object:
  #   - a literal (`[]`, `""`, `1`) is a core object, and a constant receiver is a core class unless it names an
  #     engine one (ENGINE_RE);
  #   - self is one only in a method of a module (any module may be mixed into an engine class), of Object,
  #     BasicObject, Kernel, Class or Module, of a class on an engine class's superclass chain, or the singleton of
  #     such a class; self in a class body or at top level is that class or main;
  #   - any other receiver may be.
  # `super` follows self's rule. Every LOADSYM symbol, implicit-dispatch operator, identifier-shaped pool string
  # and name an ALIAS / UNDEF irep mentions counts whatever its receiver. A file that sends a reflective name
  # (CORE_REFLECTIVE_SENDS: computed sends, eval, instance_exec, define_method, ...) or defines method_missing /
  # respond_to_missing? loses the receiver rule: every symbol its bytecode holds counts, with every send, operator
  # and identifier-shaped string as above. Its comments and local variable names do not -- they never become a
  # symbol, and a name it sends that arrives from its caller (`__send__(@meth)`) is counted where the caller spells it.
  # Returns { path => names } for those files, names nil (keep the text rule) for one that compiled to no irep.
  CORE_REFLECTIVE_SENDS = %w[
    send __send__ public_send method public_method instance_method singleton_method eval instance_eval
    instance_exec class_eval module_eval class_exec module_exec define_method define_singleton_method
    alias_method remove_method undef_method method_missing respond_to_missing? const_missing
  ].to_set.freeze
  CORE_SELF_CONTEXTS = %w[Object BasicObject Kernel Class Module].freeze

  def core_bytecode_tokens(paths, tokens, mrbc:, superclass_of:, struct_owners: [])
    ireps = registry = modules = nil
    Dir.mktmpdir('bc2cpp_core_tokens') do |tmp|
      ireps, root = compile_ireps(paths, 'static_dispatch_core', tmp, mrbc: mrbc)
      result = build_registry(ireps, root)
      registry = result[0]
      modules = result[11]
    end
    body_of = {}
    registry.each { |name, defs| defs.each { |d| body_of[d.irep] = [d.owner, name] if d.irep } }
    parent = {}
    ireps.each_value { |irep| irep.reps.each { |c| parent[c] = irep.label } }
    reflective = ireps.each_value.select { |irep| core_reflective?(irep) }.to_set { |irep| File.expand_path(irep.file.to_s) }
    reflective.merge(paths.reject { |p| ireps.each_value.any? { |irep| File.expand_path(irep.file.to_s) == p } })
    ancestry = engine_ancestry(superclass_of, struct_owners)
    symbols = reflective.to_h { |path| [path, nil] }
    ireps.each_value do |irep|
      file = File.expand_path(irep.file.to_s)
      up = irep.label
      up = parent[up] until up.nil? || body_of.key?(up)
      owner, name = up && body_of[up]
      if reflective.include?(file)
        names = (symbols[file] ||= Set.new)
        names.merge(irep.syms.map(&:to_s))
        core_irep_tokens(irep, names, true, name)
        next
      end

      self_may = owner ? core_self_may_be_engine?(owner, modules, ancestry) : false
      core_irep_tokens(irep, tokens, self_may, name)
    end
    symbols.sort.to_h
  end

  def core_reflective?(irep)
    BytecodeIR.for(irep).each_source.any? do |insn, _|
      (SEND_OPS.include?(insn.op) || %i[TDEF SDEF].include?(insn.op)) && CORE_REFLECTIVE_SENDS.include?(insn.sym.to_s)
    end
  end

  # The names one core irep can look up on an engine object (CORE_BYTECODE_TOKENS).
  def core_irep_tokens(irep, tokens, self_may, method_name)
    irep.pool.each { |v| tokens << v if v.is_a?(String) && v.match?(IDENT) }
    insns = BytecodeIR.for(irep).each_source.to_a
    tokens.merge(irep.syms.map(&:to_s)) if insns.any? { |insn, _| %i[ALIAS UNDEF].include?(insn.op) }
    kinds = receiver_kinds(irep)
    insns.each_with_index do |(insn, _), i|
      if insn.op == :LOADSYM
        tokens << insn.sym.to_s
      elsif SEND_OPS.include?(insn.op)
        kind = kinds[i]
        may = case kind
              when :core then false
              when :self then self_may
              when Array then kind[1].match?(ENGINE_RE)
              else true
              end
        tokens << insn.sym.to_s if may
      elsif insn.op == :SUPER
        tokens << method_name if self_may && method_name
      elsif (op_name = IMPLICIT_DISPATCH_NAMES[insn.op])
        tokens << op_name
      end
    end
  end

  # Whether self in a method of `owner` may be an engine object (CORE_BYTECODE_TOKENS).
  def core_self_may_be_engine?(owner, modules, ancestry)
    return true if owner.start_with?('<') || ancestry == :all
    return ancestry.include?(owner.delete_suffix('.singleton')) if owner.end_with?('.singleton')

    modules.include?(owner) || CORE_SELF_CONTEXTS.include?(owner) || ancestry.include?(owner)
  end

  # Every class an engine class (CLOSED_OWNER_RE, the owners the closed list may unregister) inherits from, outside
  # the engine itself; :all when a superclass is unrecognized or defined only natively (no superclass_of entry), so
  # no class can be ruled out.
  def engine_ancestry(superclass_of, struct_owners)
    re = CLOSED_OWNER_RE
    found = Set['Object', 'BasicObject']
    found << 'Struct' if struct_owners.any? { |o| o.match?(re) }
    superclass_of.each do |klass, sup|
      next unless klass.match?(re)

      seen = Set.new
      while seen.add?(klass)
        sup = superclass_of.fetch(klass) { return :all }
        break if sup == :none

        unless superclass_of.key?(sup)
          # A native class: only mruby's own exception chain (src/error.c) is known; `class E < StandardError`
          # inside a module reads back as "Mod::StandardError". Any other has ancestors this cannot see.
          chain = native_superclass_chain(sup.split('::').last) or return :all
          found.merge(chain)
          break
        end
        found << sup << sup.split('::').last unless sup.match?(re)
        klass = sup
      end
    end
    found
  end

  # mruby's native exception classes (src/error.c) and their superclasses.
  NATIVE_EXCEPTION_SUPERCLASS = {
    'Exception' => 'Object', 'StandardError' => 'Exception', 'ScriptError' => 'Exception',
    'ArgumentError' => 'StandardError', 'RangeError' => 'StandardError', 'RuntimeError' => 'StandardError',
    'TypeError' => 'StandardError', 'IndexError' => 'StandardError', 'KeyError' => 'IndexError',
    'FrozenError' => 'RuntimeError', 'NotImplementedError' => 'ScriptError', 'ZeroDivisionError' => 'StandardError'
  }.freeze

  # `name` and its native superclasses up to Object, or nil for a class outside NATIVE_EXCEPTION_SUPERCLASS.
  def native_superclass_chain(name)
    chain = []
    while name != 'Object'
      return nil unless NATIVE_EXCEPTION_SUPERCLASS.key?(name)

      chain << name
      name = NATIVE_EXCEPTION_SUPERCLASS[name]
    end
    chain
  end

  # The gems of the other makers. The closed build is single-format (build_config.rb's
  # single_format_only loads mruby-rpg2k as its only maker gem), so their Ruby and C never run in it.
  OTHER_MAKER_GEMS = %w[mruby-rpgxp mruby-rpgvx mruby-wolf mruby-mvjs].freeze

  # C_TOKEN: one C or C++ token of strip_c_comments, in the order it tries them. A number swallows its digit
  # separators (`1'000`), so they open no character literal.
  C_TOKEN = %r{
    (?<comment>//[^\n]*|/\*.*?\*/) | (?<string>"(?:[^"\\\n]|\\.)*") | (?<char>'(?:[^'\\\n]|\\.)*') |
    [0-9][0-9A-Za-z_.']* | [A-Za-z_][A-Za-z0-9_]* | [^"'/A-Za-z0-9_]+ | /
  }mx

  # `text` with every comment replaced by a space. Strings and character literals are kept whole, so `"/*"` stays a
  # literal. Text the scan cannot read (an unterminated quote, a raw string R"(...)") is returned as it is: keeping
  # a comment only adds names, which is the safe direction.
  def strip_c_comments(text)
    return text if text.match?(/\b(?:u8|[uUL])?R"/)

    scan = StringScanner.new(text)
    out = +''
    until scan.eos?
      return text unless scan.scan(C_TOKEN)

      out << (scan[:comment] ? ' ' : scan.matched)
    end
    out
  end

  # NATIVE_NAME_TOKENS (closed only): C reaches a method by name only through a string ("name" for
  # mrb_funcall, mrb_intern_lit, a name table), a presym macro (MRB_SYM(name), MRB_SYM_Q(name), ...) or a macro
  # that makes a name of its argument (naming_macros). A bare C identifier spelled like a method name (a local
  # `size`, a field `preview_map_id`) looks nothing up, so native files contribute only those.
  # Comments are left out (strip_c_comments): a name in one (`/* "count" is "width" */`) is never compiled.
  # `text_tokens`: also receives a naming macro's arguments, which the macro may suffix itself (`#name "="`).
  def native_name_tokens(text, tokens, macros, text_tokens: nil)
    text = blank_registration_names(strip_c_comments(text))
    text.scan(STRING_LITERAL) { |(s)| tokens << unescape(s) }
    unless macros.empty?
      text.scan(/\b(?:#{macros.map { |m| Regexp.escape(m) }.join('|')})\s*\(([^()]*)\)/) do |(args)|
        args.scan(/[A-Za-z_][A-Za-z0-9_]*/) do |t|
          tokens << t
          text_tokens << t if text_tokens
        end
      end
    end
    text.scan(/MRB_(?:Q?SYM|OPSYM)(?:_([QBE]))?\(\s*(\w+)\s*\)/) do |kind, name|
      tokens << name
      tokens << name + { 'Q' => '?', 'B' => '!', 'E' => '=' }.fetch(kind) if kind
    end
  end

  # NATIVE_CANDIDATES (closed only): each native registration on a literal engine owner (NativeOwnerMap), which the
  # owner's compiled gem (bc2cpp_native_strip_gem) removes when listed. Not ROM method-table entries
  # (MRB_MT_ENTRY), whose runtime removal adds a RAM tombstone. A key is left out when Ruby defines the name on that
  # owner too (bc2cpp_left_out would remove the Ruby method), when a native alias or undef names it there, when the
  # owner has a computed-name registration, or when it is already a candidate. Pruning needs the registration's
  # owner and name, not a statically named C function: lambda and template bodies still install a fixed key.
  def native_candidates(repo_root, registry, candidates)
    _ruby, native = outside_world_files(repo_root, closed_only: true)
    map = NativeOwnerMap.build(native)
    keys = candidates.to_set { |m| "#{m[:owner]}##{m[:name]}" }
    blocked = Set.new
    map.aliases.each { |owner, new_name, old_name| blocked << "#{owner}##{new_name}" << "#{owner}##{old_name}" }
    map.registrations.filter_map do |owner, name, _fn|
      next unless owner.is_a?(String) && name && !map.computed.include?(owner)

      gem = bc2cpp_native_strip_gem(owner)
      key = "#{owner}##{name}"
      next unless gem && GEMS.include?(gem) && !blocked.include?(key)
      next if Array(registry[name]).any? { |d| d.owner == owner }
      next unless keys.add?(key)

      { owner: owner, name: name, entry: nil, gem: gem, native: true }
    end
  end

  # REGISTRATION_NAME_EXEMPTION (closed only): a native's own registration call (mrb_define_method and the other
  # defining NativeOwnerMap::FAMILIES) defines its name, it looks nothing up, so that one argument -- a string literal
  # or a presym operand -- is blanked before native_name_tokens reads the file. Every other occurrence of the name
  # still counts, an alias's old name included.
  DEFINING_FAMILIES = NativeOwnerMap::FAMILIES.select do |family, spec|
    family.start_with?('define_') && (spec[:fn] || spec[:alias_of])
  end
  REGISTRATION_NAME_ARG = /\A(?:"(?:[^"\\]|\\.)*"|MRB_(?:Q?SYM|OPSYM)(?:_[QBE])?\(\s*\w+\s*\))\z/

  def blank_registration_names(text)
    out = nil
    text.scan(/\bmrb_(define_\w+)\s*\(/) do |(family)|
      spec = DEFINING_FAMILIES[family] or next
      spans = call_arg_spans(text, Regexp.last_match.end(0) - 1) or next
      from, to = spans[spec[:name]] || next
      next unless text[from...to].strip.match?(REGISTRATION_NAME_ARG)

      (out ||= text.dup)[from...to] = ' ' * (to - from)
    end
    out || text
  end

  # [from, to) of each top-level argument of the call whose '(' is at `open`; nil when unbalanced.
  def call_arg_spans(text, open)
    depth = 0
    spans = []
    start = open + 1
    i = open
    while i < text.length
      c = text[i]
      if c == '"' || c == "'"
        i += 1
        i += (text[i] == '\\' ? 2 : 1) while i < text.length && text[i] != c
      elsif c == '('
        depth += 1
      elsif c == ')'
        depth -= 1
        return spans << [start, i] if depth.zero?
      elsif c == ',' && depth == 1
        spans << [start, i]
        start = i + 1
      end
      i += 1
    end
    nil
  end

  # A function-like macro that turns a parameter into a name -- `#param` stringification, a presym macro applied to
  # the parameter, or a call passing it on to another such macro -- lets a bare identifier at its call site become a
  # method name, so native_name_tokens counts every identifier in those macros' arguments. The presym family itself
  # (MRB_SYM(name), ...) is read directly there, and presym/scanning.h's redefinitions only exist for mruby's presym
  # scan, not the build.
  def naming_macros(paths)
    naming_macros_in(paths.reject { |p| p.end_with?('/presym/scanning.h') }.map { |p| File.read(p, encoding: 'BINARY') })
  end

  # naming_macros on source texts.
  def naming_macros_in(texts)
    defs = texts.flat_map do |text|
      text.gsub(/\\\n/, ' ').scan(/^[ \t]*#[ \t]*define[ \t]+(\w+)\(([^)]*)\)([^\n]*)/)
    end
    naming = Set.new
    loop do
      callee = naming.empty? ? nil : /\b(?:#{naming.map { |m| Regexp.escape(m) }.join('|')})\s*\(/
      grew = false
      defs.each do |macro, params, body|
        next if naming.include?(macro) || macro.match?(/\AMRB_\w*SYM/)

        named = params.split(',').map(&:strip).reject(&:empty?).any? do |param|
          name = Regexp.escape(param.end_with?('...') ? '__VA_ARGS__' : param)
          body.match?(/(?<!#)#\s*#{name}\b/) || body.match?(/MRB_\w*SYM\w*\([^)]*\b#{name}\b/) ||
            (callee && body.match?(/#{callee}[^)]*\b#{name}\b/))
        end
        grew = true if named && naming.add?(macro)
      end
      break unless grew
    end
    naming.to_a.sort
  end

  # Runs bc2cpp.rb for each compiled gem and the closed-world parse; returns
  # everything eligibility needs.
  # lists: the lists the probe generates with (StaticDispatchLists, at lists_path): the previous pass's output, or
  # empty. unregistered: what the build being proven leaves out (default: its own list). The probe generates with
  # BC2CPP_BUILD_NAME=closed, so both lists are missing from its registrations whichever build is proven.
  def analyze(repo_root, mrbc, lists: StaticDispatchLists::EMPTY, lists_path: 'none', unregistered: nil,
              closed_only: false)
    both = lists.open | lists.closed
    unregistered ||= closed_only ? both : lists.open
    absent = both | unregistered
    # Every gem, from one shared analysis. The generation depends only on the lists, so the open and the closed
    # analysis of a pass share it.
    fresh = ((@fresh_generation ||= {})[StaticDispatchLists.dump(lists)] ||=
               NeverCalledRegistrations.run_bc2cpp_full_many(GEMS, repo_root, mrbc, lists_path: lists_path))
    runs = GEMS.to_h do |gem|
      out, err = fresh.fetch(gem)
      [gem, { gen: out, entries: NeverCalledRegistrations.parse_compiled_entries(err) }]
    end
    ireps, registry, superclass_of, struct_owners, engine_tuple = closed_world(repo_root, mrbc)
    subclassed = subclassed_paths(repo_root, superclass_of, closed_only: closed_only)
    # SYMBOL_USES (closed only): the Symbol literals that name a looked-up method, or nil (every one does).
    symbol_lookups = closed_only ? StaticDispatchSymbolUses.lookups(ireps) : nil
    send_ops = symbol_lookups ? SEND_OPS - [:LOADSYM] : SEND_OPS

    # Candidates: compiled entries still registered, plus ones already
    # unregistered by this mechanism (so re-running the proof after the
    # registrations are gone re-checks exactly the same set).
    candidates = []
    overridden = Set.new # "Owner#name" whose compiled override the proven build registers
    runs.each do |gem, r|
      live = registrations(r[:gen]).map(&:first).to_set
      r[:entries].each do |m|
        key = "#{m[:owner]}##{m[:name]}"
        present = live.include?(m[:entry]) || absent.include?(key)
        overridden << key if present && !unregistered.include?(key)
        candidates << m.merge(gem: gem) if present
      end
    end

    # ACCESSOR_CANDIDATES: an attr_* accessor of an owner some compiled gem lists, with no compiled entry of its
    # own. That gem's registration removes it when listed (CodeGen#left_out_accessors).
    gem_of = BC2CPP_COMPILED_GEMS.select { |gem, _| GEMS.include?(gem) }
                                 .flat_map { |gem, g| Array(g[:owners]).map { |owner| [owner, gem] } }.to_h
    keys = candidates.to_set { |m| "#{m[:owner]}##{m[:name]}" }
    registry.each do |name, defs|
      defs.each do |d|
        next unless d.kind == :ivar_accessor && !d.core && gem_of.key?(d.owner)
        next unless keys.add?("#{d.owner}##{name}")

        candidates << { owner: d.owner, name: name, entry: nil, gem: gem_of[d.owner], accessor: true }
      end
    end
    candidates.concat(native_candidates(repo_root, registry, candidates)) if closed_only

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
    cite(ALWAYS_DYNAMIC, 'always dynamic (ALWAYS_DYNAMIC)')
    if symbol_lookups
      dynamic.merge(symbol_lookups)
      cite(symbol_lookups, 'a Symbol literal that may name a looked-up method (SYMBOL_USES)')
    end
    fragments = Set.new
    # IDENT_USES (closed only): an identifier-shaped literal names a looked-up method only when it may leave pure
    # uses, the FRAGMENT_USES question for an exact name (decided below, once `outside` is known). Only sound once
    # SYMBOL_USES has proven every lookup in the closed bytecode takes a literal: a compared literal could otherwise
    # be the name a computed `send(x)` ends up looking up (`send(x) if x == "name"`).
    literal_sites = Hash.new { |h, k| h[k] = [] }
    ireps.each_value do |irep|
      BytecodeIR.for(irep).instructions_with_op(:SUPER).each do
        up = method_of[irep.label]
        next unless up

        dynamic << body_of[up][1]
        cite([body_of[up][1]], "super in #{body_of[up].join('#')}")
      end
      irep.pool.each do |s|
        next unless s.is_a?(String)

        literal_sites[s] << irep if s.match?(IDENT)
        fragments << s if s.match?(FRAGMENT)
      end
    end
    runs.each do |gem, r|
      literals = c_literals(r[:gen], exempt: lookup_free_names(r[:gen], subclassed, symbol_values: !symbol_lookups.nil?))
      dynamic.merge(literals)
      cite(literals, "a C string literal in #{gem}'s generated code")
    end
    core = { mrbc: mrbc, superclass_of: superclass_of, struct_owners: struct_owners }
    text = Set.new
    outside = outside_world_tokens(repo_root, closed_only: closed_only, core: core, text: text)
    dynamic.merge(outside)
    looked_up = literal_sites.keys.to_set
    looked_up &= StaticDispatchFragmentUses.escaping(ireps, body_of, method_of, outside, IDENT) if symbol_lookups
    literal_sites.each do |s, sites|
      next unless looked_up.include?(s)

      dynamic << s
      cite([s], "a string literal in #{irep_site(sites.first, method_of, body_of)}")
    end

    # Which bytecode can run. No method body -- compiled or not -- runs as
    # bytecode except after a dynamic lookup of its own name: a direct C++ call
    # targets the compiled `_impl`, never bytecode. A body whose compiled
    # override stays registered can only run as bytecode before its gem's
    # gem_init installs that override, i.e. during mrblib load, so for those
    # only a LOAD-phase lookup counts: `load` is the fixpoint of names sent by
    # the root and class bodies (and blocks made in them) plus by the bodies
    # those names reach. Everything else -- an uncompiled method, a compiled
    # one left unregistered -- runs whenever its name is looked up at all.
    # Blocks run whenever their method might. Inside a registered compiled
    # method that is the LOAD phase too, unless the generated C++ builds a
    # bytecode proc somewhere (BYTECODE_PROC): every block the compiled code
    # makes is otherwise a C proc (mrb_proc_new_cfunc_with_env), so the block's
    # irep runs only from the method's own bytecode. Names are only ever added,
    # so both fixpoints converge.
    sends = lambda do |irep, into|
      grew = false
      BytecodeIR.for(irep).each_source do |insn, _index|
        name = if send_ops.include?(insn.op) then insn.sym
               elsif insn.op != :LOADSYM then IMPLICIT_DISPATCH_NAMES[insn.op]
               end
        next unless name && into.add?(name)

        grew = true
        cite([name], "sent by #{irep_site(irep, method_of, body_of)}, which may run as bytecode")
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

    load_bodies, load_names = load_phase(ireps, body_of, method_of, overridden, send_ops: send_ops)
    dynamic.merge(load_names)
    cite(load_names, 'sent while mrblib loads')
    bytecode_blocks = runs.each_value.any? { |r| r[:gen].match?(BYTECODE_PROC) }
    fixpoint.call(dynamic, lambda do |label|
      m = method_of[label]
      next true if m.nil?

      owner, name = body_of[m]
      if overridden.include?("#{owner}##{name}")
        bytecode_blocks && label != m ? true : load_bodies.include?(m)
      else
        dynamic.include?(name)
      end
    end)

    # FRAGMENT_USES (closed only): only the literals that can reach a built string stay fragments.
    # SUFFIX_BASES (closed only): see dynamic_name?. nil keeps the rule for every dynamic name.
    suffix_bases = nil
    if closed_only
      fragments &= StaticDispatchFragmentUses.escaping(ireps, body_of, method_of, outside, FRAGMENT)
      built = StaticDispatchFragmentUses.escaping(ireps, body_of, method_of, outside, SUFFIX_LITERAL)
      suffix_bases = text if built.empty?
    end

    core_excluded = closed_only ? core_excluded(repo_root, mrbc, ireps, runs.values.map { |r| r[:gen] }, registry, superclass_of,
                                                engine_tuple, symbol_lookups) : nil

    { registered: candidates, dynamic: dynamic, fragments: fragments, load: load_names, load_bodies: load_bodies,
      closed_only: closed_only, suffix_bases: suffix_bases, symbol_lookups: symbol_lookups,
      core_excluded: core_excluded }
  end

  # CORE_NATIVE_CANDIDATES (closed only): [the core ROM entries the closed build leaves out of its tables, the core
  # run-time registrations it removes]. Every Ruby
  # source the binary may load counts -- the core and external mrblib besides the engine's (`ireps`), whose method
  # bodies count while their names are reachable (LIVE_CORE) -- and every native source, with the generated code.
  def core_excluded(repo_root, mrbc, ireps, generated, engine_registry, engine_superclass_of, engine_tuple, symbol_lookups)
    _ruby, native = outside_world_files(repo_root, closed_only: true)
    third = "#{File.expand_path(repo_root)}/3rd/"
    core = core_files(repo_root, mrbc)
    names, fragments = CoreNativeCandidates.reachable(ireps, native, generated, core: core)
    entries = CoreNativeCandidates.entries(native.select { |p| p.start_with?("#{third}mruby/") })
    map = NativeOwnerMap.build(native)
    private_ruby = private_ruby_candidates(core, ireps, native, generated, entries, map, engine_registry, engine_superclass_of,
                                           engine_tuple, symbol_lookups, repo_root)
    ruby = CoreNativeCandidates.ruby_candidates(core, names, fragments, entries)
    [CoreNativeCandidates.candidates(entries, names, fragments),
     (CoreNativeCandidates.ram_candidates(map, names, fragments, entries) + private_ruby + ruby).uniq.sort]
  end

  # The core and external mrblib files the closed binary loads, each compiled on its own, with the name of each method body
  # (LIVE_CORE: a body counts once its name is reachable) and build_registry's tuple.
  def core_files(repo_root, mrbc)
    third = "#{File.expand_path(repo_root)}/3rd/"
    # CLOSED_LINKED_ONLY: an unlinked gem's mrblib never loads there.
    unlinked = closed_unlinked_dirs(repo_root)
    core_ruby = (Dir["#{third}mruby/mrblib/*.rb"] + Dir["#{third}mruby/mrbgems/*/mrblib/**/*.rb"] +
                 BC2CPP_EXTERNAL_MRBLIB_GEMS.flat_map { |g| Dir["#{third}#{g}/mrblib/**/*.rb"] })
                .map { |p| File.expand_path(p) }.reject { |p| p.start_with?(*unlinked) }.sort
    Dir.mktmpdir('bc2cpp_core_natives') do |tmp|
      core_ruby.each_with_index.map do |path, i|
        file_ireps, root = compile_ireps([path], "core_native_#{i}", tmp, mrbc: mrbc)
        body_of = {}
        owner_of = {}
        tuple = build_registry(file_ireps, root)
        registry, superclass_of = tuple
        registry.each do |name, defs|
          defs.each do |d|
            body_of[d.irep] = name if d.irep
            owner_of[d.irep] = d.owner if d.irep
          end
        end
        { ireps: file_ireps, body_of: body_of, owner_of: owner_of, registry: registry, superclass_of: superclass_of, tuple: tuple,
          path: path }
      end
    end
  end

  # CORE_PRIVATE_RUBY (core_private_ruby.rb): "Owner#name" of each Ruby-defined core method the build keeps as bytecode
  # that no lookup can reach -- a `private def` (reached by implicit-self sends and lookups by name only), or a
  # method CoreMethods leaves interpreted whatever the name (mruby-enumerator's Fiber machinery, a lambda builder, a
  # refused one). The removed private methods' bodies stop counting as code that can run, so the scan is run again
  # without a private candidate the end of it rejects.
  def private_ruby_candidates(core, ireps, native, generated, entries, map, engine_registry, engine_superclass_of, engine_tuple,
                              symbol_lookups, repo_root)
    registries = core.map { |file| file[:registry] } << engine_registry
    count = Hash.new(0)
    registries.each { |reg| reg.each { |name, defs| defs.each { |d| count["#{d.owner}##{name}"] += 1 if d.irep || d.kind } } }
    strip = CorePrivateRuby.method(:strip_not_lookups)
    blind, = CoreNativeCandidates.reachable(ireps, native, generated, core: core, strip: strip)
    refused = CoreMethods.load_refused
    shape = /\A(?:[a-z_][A-Za-z0-9_]*[?!=]?|`)\z/
    usable = lambda do |key|
      name = key.split('#', 2).last
      name.match?(shape) && (count[key] == 1 || !blind.include?(name))
    end
    private_keys = core.flat_map { |file| CorePrivateRuby.private_defs(file[:ireps], file[:owner_of]).keys }.uniq.select(&usable)
    reasons = {}
    core.each do |file|
      conditional = CoreDefs.conditional_def_labels(file[:ireps])
      file[:registry].each do |name, defs|
        defs.each do |d|
          next unless d.irep && CoreDefs.core_source?(file[:ireps].fetch(d.irep).file)

          reason = CoreMethods.exclusion_reason(d, file[:ireps], refused, conditional)
          reasons["#{d.owner}##{name}"] ||= reason if reason
        end
      end
    end
    # ENUMERATOR_FREE: the mruby-enumerator methods are released by CoreEnumeratorFree's proof, not by their names (`each`,
    # `zip` and `initialize` are spelled everywhere).
    enumerator_keys = enumerator_free_keys(reasons, core, ireps, native, entries, map, engine_tuple, symbol_lookups, repo_root)
    kept = reasons.keys.select(&usable)
    return [] if private_keys.empty? && kept.empty? && enumerator_keys.empty?

    defined = Set.new
    registries.each { |reg| reg.each { |name, defs| defs.each { |d| defined << "#{d.owner}##{name}" } } }
    map.registrations.each { |owner, name, _fn| defined << "#{owner}##{name}" if owner.is_a?(String) && name }
    entries.each { |e| defined << "#{e[:mt_class]}##{e[:name]}" if e[:name] }
    superclass = core.map { |file| file[:superclass_of] }.inject({}) { |all, h| all.merge(h) }.merge(engine_superclass_of)
    owners = {}.compare_by_identity
    core.each { |file| owners.merge!(enclosing_owners(file[:ireps], file[:owner_of])) }
    owners.merge!(enclosing_owners(ireps, engine_registry.values.flatten.select(&:irep).to_h { |d| [d.irep, d.owner] }))
    defines = CorePrivateRuby.defines_proc(defined, superclass)
    # The backtick is no identifier (dynamic_name? refuses any), but `%x{}` is its only syntax: an implicit-self send.
    unreachable = lambda do |key, names, fragments|
      name = key.split('#', 2).last
      name == '`' ? !names.include?(name) : !dynamic_name?(name, names, fragments)
    end
    loop do
      lookup = CorePrivateRuby::Lookup.new(private_keys.to_set { |key| key.split('#', 2).last }, owners, defines,
                                           kept.to_set { |key| key.split('#', 2).last })
      names, fragments = CoreNativeCandidates.reachable(ireps, native, generated, core: core, lookup: lookup, strip: strip,
                                                        strip_generated: CorePrivateRuby.method(:strip_generated),
                                                        exact_impls: true)
      rejected = private_keys.reject { |key| unreachable.call(key, names, fragments) }
      if rejected.empty?
        # `def Enumerator.produce` inside `class Enumerator` is registered under Enumerator::Enumerator.singleton, a path
        # the run-time removal does not find (bc2cpp_native_owner looks each segment up in the one before it).
        keys = private_keys + kept.select { |key| unreachable.call(key, names, fragments) } + enumerator_keys
        return keys.map { |key| key.sub(/\b([A-Z]\w*)::\1\b/, '\\1') }.uniq.sort
      end

      private_keys -= rejected
    end
  end

  # The "Owner#name" keys of the mruby-enumerator methods the build keeps as bytecode, when CoreEnumeratorFree proves that no
  # Enumerator is ever made; none otherwise. +reasons+ maps each kept core method to why it stays interpreted. The result of
  # the proof is kept in @enumerator_free (the report and the check read it).
  def enumerator_free_keys(reasons, core, ireps, native, entries, map, engine_tuple, symbol_lookups, repo_root)
    # Operators too (`Yielder#<<`): the proof is no name scan, so an operator is released as an identifier is.
    keys = reasons.select { |_key, why| why.start_with?(CoreMethods::ENUMERATOR_REASON) }.keys
    @enumerator_free = nil
    return [] if keys.empty?

    @enumerator_free = enumerator_free_proof(core, ireps, native, map, engine_tuple, symbol_lookups, repo_root)
    return [] unless @enumerator_free.holds

    # `alias enum_for to_enum` is a second table entry of the same body.
    aliases = core.select { |file| file[:path].to_s.match?(CoreEnumeratorFree::GROUP_FILE) }
                  .flat_map { |file| file[:tuple][12] }
                  .filter_map { |site| "#{site[:owner]}##{site[:new]}" if keys.include?("#{site[:owner]}##{site[:old]}") }
    keys + aliases
  end

  # CoreEnumeratorFree's proof over the build's world (see enumerator_free_keys).
  def enumerator_free_proof(core, ireps, native, map, engine_tuple, symbol_lookups, repo_root)
    macros = naming_macros(native)
    inputs = CoreEnumeratorFree.inputs(
      engine: { ireps: ireps, tuple: engine_tuple }, core: core, native: native, entries: CoreNativeCandidates.entries(native),
      map: map, symbol_lookups: symbol_lookups, strip: method(:strip_c_comments),
      tokens: ->(text, found) { native_name_tokens(text, found, macros) }, entry_name: CoreNativeCandidates::ENTRY_NAME,
      implicit_names: ALWAYS_DYNAMIC | IMPLICIT_DISPATCH_NAMES.values, block_returns: declared_block_returns(repo_root)
    )
    CoreEnumeratorFree.prove(inputs)
  end

  # BLOCK_RETURNS: the `[T] ... { ... -> T } -> T` and `-> self` declarations of the signature files, by method name. Each is
  # checked against every definition when the compiled gems are generated, and a false one aborts that run.
  def declared_block_returns(repo_root)
    require_relative 'bc2cpp'
    loaded = RbsSignatures.load(RbsSignatures.dirs_from_env(repo_root), display_root: repo_root)
    BlockReturns.from_signatures(loaded).reject(&:problem).group_by(&:name)
  end

  # The proof alone, for scripts/bc2cpp/core_enumerator_free_report.rb.
  def enumerator_free_result(repo_root, mrbc)
    ireps, _registry, _superclass_of, _owners, tuple = closed_world(repo_root, mrbc)
    _ruby, native = outside_world_files(repo_root, closed_only: true)
    enumerator_free_proof(core_files(repo_root, mrbc), ireps, native, NativeOwnerMap.build(native), tuple,
                          StaticDispatchSymbolUses.lookups(ireps), repo_root)
  end

  # label => owner of the method each irep of +ireps+ belongs to (the method body itself, or the nearest one around a
  # block); absent for the root, class bodies and the blocks made directly in them.
  def enclosing_owners(ireps, owner_of)
    parent = {}
    ireps.each_value { |irep| irep.reps.each { |c| parent[c] = irep.label } }
    ireps.each_with_object({}.compare_by_identity) do |(label, irep), out|
      up = label
      up = parent[up] until up.nil? || owner_of.key?(up)
      out[irep] = owner_of[up] if up
    end
  end

  LITERAL_OPS = %i[LOADL LOADSYM LOADNIL LOADTRUE LOADFALSE STRING STRCAT ARRAY ARRAY2 ARYCAT ARYPUSH ARYDUP
                   HASH HASHADD HASHCAT RANGE_INC RANGE_EXC SYMBOL LAMBDA BLOCK METHOD INTERN].freeze
  # Not dup or clone: they copy an object that already exists, so the first engine instance comes from one of these.
  INSTANTIATING = %w[new allocate load _load marshal_load].freeze
  ENGINE_RE = /\A(?:Game|RPG2k3?|LCF|RGSS)(?:::|\z)/

  # The receiver kind of every instruction of `irep` that sends (nil for the rest): [:const, Name] | :core (a
  # literal) | :self | :unknown. The kind is the one every definition reaching the receiver register agrees on
  # A register a nested block writes (SETUPVAR) is opaque to that query,
  # so its send is :unknown rather than the kind of the local write.
  def receiver_kinds(irep)
    # APOST writes a whole run of registers, which the query does not model: no receiver facts for this irep.
    apost = BytecodeIR.for(irep).op?(:APOST)
    opaque = BytecodeIR.own_upvar_written_regs(irep)
    BytecodeIR.for(irep).each_source.map do |insn, index|
      next nil unless SEND_OPS.include?(insn.op) && insn.op != :LOADSYM
      next :self if BytecodeIR::Ops::SELF_SEND.include?(insn.op)
      next :unknown if apost

      receiver_kind_at(irep, index, insn.reg, opaque)
    end
  end

  # The kind every definition of +reg+ reaching +index+ gives, or :unknown when they disagree or the query refuses.
  def receiver_kind_at(irep, index, reg, opaque)
    defs = BytecodeIR.reaching_definitions(irep, index, reg, opaque_regs: opaque, shared: true)
    return :unknown unless defs && !defs.empty?

    kinds = defs.map { |definition| definition_kind(irep, definition) }.uniq
    kinds.size == 1 ? kinds.first : :unknown
  end

  def definition_kind(irep, definition)
    # Only R0 is a known value at entry; an argument or a caller's local is not.
    return definition.reg == 0 ? :self : :unknown if definition.entry?

    insn = BytecodeIR.for(irep).source_at(definition.index)
    case insn.op
    when :GETCONST, :GETMCNST then [:const, insn.const_name.to_s]
    when :LOADSELF then :self
    else BytecodeIR::Ops::LOADI_OPS.include?(insn.op) || LITERAL_OPS.include?(insn.op) ? :core : :unknown
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
  def load_phase(ireps, body_of, method_of, overridden, send_ops: SEND_OPS)
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
      # A core method's self is a core object: an engine instance there (a subclass of the core class) would have
      # set engine_live where it was made.
      self_kind = if m.nil? then :class
                  elsif singleton.call(body_of[m][0]) then :class
                  elsif core.call(body_of[m][0]) then :core
                  else :instance
                  end
      irep.each_with_op(*(SEND_OPS - [:LOADSYM])) do |insn, idx|
        name = insn.sym
        next unless name

        names << name
        recv = recvs[idx]
        recv = self_kind if recv == :self
        if INSTANTIATING.include?(name) &&
           (recv == :unknown || recv == :instance || (recv.is_a?(Array) && instance_owners.include?(recv[1])))
          engine_live = true
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
      return load_phase_all_names(ireps, method_of, body_of, send_ops: send_ops) if engine_live
    end
    [bodies, names]
  end

  # The original, receiver-blind cascade -- the fallback the moment any
  # load-phase code may instantiate an engine class.
  def load_phase_all_names(ireps, method_of, body_of, send_ops: SEND_OPS)
    names = Set.new
    bodies = Set.new
    loop do
      grew = false
      ireps.each_value do |irep|
        m = method_of[irep.label]
        next unless m.nil? || names.include?(body_of[m][1])

        bodies << m if m
        BytecodeIR.for(irep).instructions_with_op(*send_ops).each do |insn|
          name = insn.sym
          grew = true if name && names.add?(name)
        end
      end
      break unless grew
    end
    [bodies, names]
  end

  # SUFFIX_BASES: `x=` / `x?` / `x!` counts as dynamic when its base `x` is in `suffix_bases` (default: every
  # dynamic name). A text scan reads `obj.x = 1` as `x`, so a base read as text may stand for the suffixed name; a
  # name taken from bytecode or a C string literal is the exact name looked up. The closed analysis passes only the
  # text-read tokens -- unless some pool literal "=", "?" or "!" may reach a string built at run time
  # (FRAGMENT_USES), where `"#{x}="` could name the suffixed method from a base found anywhere.
  def dynamic_name?(name, dynamic, fragments, suffix_bases = dynamic)
    return true if dynamic.include?(name) || !name.match?(IDENT)
    return true if name.end_with?('=', '?', '!') && suffix_bases.include?(name[0..-2])

    fragments.any? { |f| f != name && (name.start_with?(f) || name.end_with?(f)) }
  end

  # Registered compiled entries (owner/name/entry/gem) no runtime lookup can
  # ever reach.
  # CLOSED_OWNER_RE (owner_call_direct.rb, whose emitter completes owner calls over the same owners): the owners the
  # closed list may unregister.
  CLOSED_OWNER_RE = OwnerCallDirect::CLOSED_OWNER_RE

  def owner_re(closed_only)
    closed_only ? CLOSED_OWNER_RE : NeverCalledRegistrations::SAFE_UNREGISTER_OWNER_RE
  end

  # WHY (scripts/bc2cpp/dynamic_names_report.rb): when set, the first reason each name became dynamic, by name.
  class << self
    # The CoreEnumeratorFree::Result of the last core_excluded run (nil when it had nothing to prove).
    attr_reader :enumerator_free
    attr_accessor :why
  end

  def cite(names, reason)
    return unless @why

    names.each { |name| @why[name] ||= reason }
  end

  def irep_site(irep, method_of, body_of)
    m = method_of[irep.label]
    where = m ? body_of[m].join('#') : 'a class body or block at load'
    file = irep.respond_to?(:file) && irep.file ? " (#{File.basename(irep.file.to_s)})" : ''
    "#{where}#{file}"
  end

  def eligible(analysis)
    re = owner_re(analysis[:closed_only])
    analysis[:registered].select do |m|
      m[:owner].match?(re) &&
        !dynamic_name?(m[:name], analysis[:dynamic], analysis[:fragments],
                       analysis[:suffix_bases] || analysis[:dynamic])
    end
  end

  # EMIT_DIGEST: a digest of everything the proof reads, so an emitted file is reused only for the tree it was
  # computed from (and a consumer that is told the digest refuses any other). The file lists are the proof's own:
  # both scans' outside sources, the closed world, the core Ruby, the gem rakes and build_config.rb the closure is
  # derived from, and the generator and proof sources.
  def inputs_digest(repo_root)
    root = File.expand_path(repo_root)
    files = []
    [false, true].each do |closed_only|
      files.concat(closed_world_mrblib_srcs(root, core_gems: nil))
      ruby, native = outside_world_files(root, closed_only: closed_only)
      files.concat(ruby).concat(native)
    end
    files.concat(closed_world_mrblib_srcs(root, core_gems: :canonical))
    files.concat(Dir["#{root}/3rd/mruby/mrblib/*.rb"] + Dir["#{root}/3rd/mruby/mrbgems/*/mrblib/**/*.rb"])
    files.concat(BC2CPP_EXTERNAL_MRBLIB_GEMS.flat_map { |g| Dir["#{root}/3rd/#{g}/mrblib/**/*.rb"] })
    files.concat(Dir["#{root}/3rd/mruby/mrbgems/*/mrbgem.rake"] + Dir["#{root}/mruby-*/mrbgem.rake"])
    files.concat(Dir["#{root}/tools/bc2cpp/**/*.rb"] + Dir["#{root}/tools/bc2cpp/**/*.{rbs,erb}"])
    files.concat([File.join(root, 'build_config.rb'), File.join(root, 'scripts/bc2cpp/trace_host.cxx')])
    files.concat(Dir["#{root}/sig/**/*.rbs"])
    sha = Digest::SHA256.new
    sha << "lists-format 1\n"
    files.map { |p| File.expand_path(p) }.uniq.sort.each do |path|
      next unless File.file?(path)

      sha << path.delete_prefix("#{root}/") << "\0" << Digest::SHA256.file(path).hexdigest << "\n"
    end
    sha.hexdigest
  end

  # One pass of the proof given the lists the probe generated with (`lists`, written at `lists_path`): what it
  # proves unregistered, as the next lists. The closed list holds everything the open one does (a closed build
  # drops the open names too), which the closed analysis rediscovers from its wider scan; a name the open
  # analysis proves and the closed one does not would be a contradiction, so it stops the run.
  def pass(repo_root, mrbc, lists, lists_path, digest)
    names = ->(analysis) { eligible(analysis).to_set { |m| "#{m[:owner]}##{m[:name]}" } }
    closed = analyze(repo_root, mrbc, lists: lists, lists_path: lists_path, closed_only: true)
    open = analyze(repo_root, mrbc, lists: lists, lists_path: lists_path, closed_only: false)
    closed_names = names.call(closed)
    open_names = names.call(open)
    missing = open_names - closed_names
    abort "closed list does not contain #{missing.size} name(s) the full scan proves: #{missing.first(5).join(', ')}" unless missing.empty?

    StaticDispatchLists::Lists.new(open: open_names.freeze, closed: closed_names.freeze,
                                   core_excluded: closed[:core_excluded][0].to_set.freeze,
                                   core_left_out: closed[:core_excluded][1].to_set.freeze, digest: digest)
  end

  def read_lists(path)
    return nil unless File.file?(path)

    StaticDispatchLists.parse(File.read(path))
  rescue StaticDispatchLists::Missing, JSON::ParserError
    nil
  end

  # Whether `dir` holds the lists for this tree's inputs.
  def current?(repo_root, dir)
    lists = read_lists(File.join(dir, 'static_dispatch_lists.json'))
    !lists.nil? && lists.digest == inputs_digest(repo_root)
  end

  def same_lists?(a, b)
    StaticDispatchLists::KEYS.all? { |key| a.public_send(key) == b.public_send(key) }
  end

  # EMIT: the lists for this tree, in `dir`/static_dispatch_lists.json. A file already there for the same inputs is
  # reused. Otherwise the proof runs from the last lists written there (or empty lists) and repeats with its own output
  # until a pass proves exactly what it generated with: each pass is sound only for the generation it read, so a list that has not reached that
  # fixed point is not written. `max_passes` bounds a proof that oscillates, which is an error, never a result.
  def emit(repo_root, mrbc, dir, max_passes: 8, log: $stderr)
    FileUtils.mkdir_p(dir)
    digest = inputs_digest(repo_root)
    out = File.join(dir, 'static_dispatch_lists.json')
    if (cached = read_lists(out)) && cached.digest == digest
      log.puts "static dispatch lists: #{out} is current (#{digest[0, 12]})"
      return cached
    end

    # The last run's lists are the first pass's input, whatever tree they came from: a pass is accepted only when it
    # proves exactly its own input, so a stale seed costs passes, never soundness. An unchanged proof then settles in
    # one pass instead of two.
    seed = read_lists(out)
    lists = seed || StaticDispatchLists::EMPTY
    lists_path = seed ? out : 'none'
    log.puts "static dispatch lists: seeded from #{out} (#{seed.digest[0, 12]})" if seed
    passes = 0
    loop do
      passes += 1
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      nxt = pass(repo_root, mrbc, lists, lists_path, digest)
      log.puts format('static dispatch lists: pass %<n>d, open %<o>d closed %<c>d core ROM %<r>d core run-time %<t>d (%<s>.0fs)',
                      n: passes, o: nxt.open.size, c: nxt.closed.size, r: nxt.core_excluded.size,
                      t: nxt.core_left_out.size, s: Process.clock_gettime(Process::CLOCK_MONOTONIC) - started)
      if same_lists?(nxt, lists)
        File.write("#{out}.tmp", StaticDispatchLists.dump(nxt))
        File.rename("#{out}.tmp", out)
        log.puts "static dispatch lists: wrote #{out} (#{digest[0, 12]})"
        return nxt
      end
      abort "static dispatch lists: no fixed point after #{max_passes} passes" if passes >= max_passes

      lists = nxt
      lists_path = File.join(dir, "pass#{passes}.json")
      File.write(lists_path, StaticDispatchLists.dump(lists))
    end
  end
end

if $PROGRAM_NAME == __FILE__
  repo_root = File.expand_path('../..', __dir__)
  args = ARGV.dup
  take = ->(flag) { args.include?(flag) ? args.slice!(args.index(flag), 2).last : nil }
  emit_dir = take.call('--emit')
  check_dir = take.call('--check')
  digest_only = !args.delete('--digest').nil?
  abort "usage: [MRBC=<host mrbc>] ruby #{$PROGRAM_NAME} --emit DIR | --check DIR | --digest" unless args.empty?

  if digest_only
    puts StaticDispatchRegistrations.inputs_digest(repo_root)
  elsif check_dir
    # Exit 0 when DIR holds the lists for this tree: the cheap test that lets a caller skip building a host mrbc.
    exit(StaticDispatchRegistrations.current?(repo_root, check_dir) ? 0 : 1)
  elsif emit_dir
    lists = StaticDispatchRegistrations.emit(repo_root, ENV['MRBC'] || 'mrbc', emit_dir)
    warn "open #{lists.open.size}, closed #{lists.closed.size}, core ROM #{lists.core_excluded.size}, " \
         "core run-time #{lists.core_left_out.size}"
  else
    abort "usage: [MRBC=<host mrbc>] ruby #{$PROGRAM_NAME} --emit DIR | --check DIR | --digest"
  end
end
