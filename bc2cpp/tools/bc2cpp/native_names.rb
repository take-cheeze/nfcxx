# frozen_string_literal: true

# Step 5b: method names defined or called outside the compiled bytecode.

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
