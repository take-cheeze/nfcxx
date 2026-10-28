#!/usr/bin/env ruby
# frozen_string_literal: true

# STATIC_DISPATCH_UNREGISTRATION's scan rules (tools/bc2cpp/static_dispatch_registrations.rb), on fixture text:
#
#   NATIVE_NAME_TOKENS (closed only): a native file names a method only through a string literal, a presym macro
#     (MRB_SYM(name), MRB_SYM_Q(name), ...) or the arguments of a macro that makes a name of its argument
#     (naming_macros: `#param`, a presym macro of the parameter, or a call passing it on to another such macro).
#     A bare C identifier names nothing.
#   NON_LOOKUP_HELPERS: a generated symbol whose every use is bc2cpp_nomethod(_raise), bc2cpp_guard_violation,
#     bc2cpp_hint_violation or bc2cpp_nil_receiver is no dynamic lookup; any bc2cpp_send, uncovered owner call or
#     bc2cpp_sym(M, i) use keeps it one.
#   OWNER_CALL_GUARDED: an owner call covering every engine owner it lists is no lookup either: none listed, or each
#     one tested by the exact-class chain the call is the else of and not subclassed, or carried as a direct entry
#     (OWNER_CALL_DIRECT). An untested listed owner, or a subclassed tested one without its entry, keeps it one.
#     The subclass scan reads a native define call's superclass from its last argument, not its own name.
#   BYTECODE_PROC: what counts as generated C building a proc over a bytecode irep (which keeps every block of a
#     registered compiled method runnable as bytecode).
#   OTHER_MAKER_GEMS: the closed scan reads none of the other makers' sources, nor the workflows.
#   SYMBOL_USES (needs MRBC for its bytecode half): with the closed bytecode's every name-taking call (send,
#     inject, to_enum, a `&` block, ...) on literals, only those literals name a looked-up method, and a generated
#     symbol only made into a value, compared or listed as a keyword name is no lookup. A computed name to such a
#     call, an UNDEF or a call that lists methods refuses. LEFT_OUT calls look nothing up.
#   SUFFIX_BASES: `x=` / `x?` / `x!` follows a dynamic `x` only when `x` was read as text (a Ruby text scan, a naming
#     macro's argument); an exact name from bytecode or a C literal keeps its own suffix only. A pool literal "=",
#     "?" or "!" that may reach a built string (FRAGMENT_USES) puts the rule back for every name.
#   GENERATED_REGISTRATION: no compiled gem's src/register.cxx registers a method by hand (the generated
#     bc2cpp_register_owner_methods is the only registration, so the lists' left-out entries stay out), and the
#     closed list may take RGSS owners and engine module singletons, never reopened core classes (CLOSED_OWNER_RE).
#   CORE_BYTECODE_TOKENS (needs MRBC; skipped without it): core Ruby read as bytecode names a method only through a
#     send whose receiver may be an engine object (self in a module, Object or Kernel method; any unknown value), a
#     symbol or an identifier-shaped string; self in a core class method, a literal and a core constant do not. A
#     file with a reflective send keeps the text rule. engine_ancestry follows superclasses, mruby's native
#     exception chain included, and gives up (:all) on any other native superclass.
#   FRAGMENT_USES (needs MRBC; skipped without it): a pool literal stays a fragment only when a load of it may reach
#     a built string that goes on somewhere -- a concatenation without a non-name character whose result escapes
#     (a send, an interned Symbol), a store, a return a caller passes on, an argument of a method the trace does not
#     know. Comparing it, a native hash key, a constant list only tested for membership, a part of a message with a
#     space or a colon and a part of a string only printed or compared do not. IDENT_USES asks the same of an
#     identifier-shaped literal, an exact name.
#
# Usage: [MRBC=path/to/mrbc] ruby scripts/bc2cpp/static_dispatch_scan_check.rb

require 'set'
require_relative '../../tools/bc2cpp/static_dispatch_registrations'

S = StaticDispatchRegistrations
$failures = 0

def check(label, ok)
  puts "#{ok ? 'ok  ' : 'FAIL'} #{label}"
  $failures += 1 unless ok
end

# --- NATIVE_NAME_TOKENS ---
native = <<~'C'
  static mrb_value f(mrb_state* M, mrb_value self) {
    mrb_int size = 0;               /* a local named like a method */
    int preview_map_id = 1;
    mrb_funcall(M, self, "refresh", 0);
    mrb_funcall_id(M, self, MRB_SYM_Q(visible), 0);
    mrb_funcall_id(M, self, MRB_SYM_E(width), 1, mrb_nil_value());
    CALL_NAMED(self, redraw);
    CALL_VIA(self, relayout);
    return mrb_nil_value();
  }
C
macros = <<~'C'
  #define CALL_NAMED(v, name) mrb_funcall(M, v, #name, 0)
  #define CALL_VIA(v, name) \
    CALL_NAMED(v, name)
  #define STR2(x) #x
  #define PLAIN(x) ((x) + 1)
C
naming = S.naming_macros_in([macros])
check('naming_macros: stringification', naming.include?('CALL_NAMED') && naming.include?('STR2'))
check('naming_macros: a macro passing its parameter on to a naming one', naming.include?('CALL_VIA'))
check('naming_macros: a macro that names nothing', !naming.include?('PLAIN'))
tokens = Set.new
text_tokens = Set.new
S.native_name_tokens(native, tokens, naming, text_tokens: text_tokens)
check('native: string literal', tokens.include?('refresh'))
check('native: MRB_SYM_Q / MRB_SYM_E', tokens.include?('visible?') && tokens.include?('width='))
check('native: naming macro arguments', tokens.include?('redraw') && tokens.include?('relayout'))
check('native: bare identifiers name nothing', !tokens.include?('size') && !tokens.include?('preview_map_id'))
check('native: only naming macro arguments are text tokens',
      text_tokens == Set['self', 'redraw', 'relayout'] && !text_tokens.include?('refresh'))

# --- SUFFIX_BASES ---
dyn = Set['done', 'width']
check('suffix: a text-read base keeps its setter', S.dynamic_name?('width=', dyn, Set.new, Set['width']))
check('suffix: an exact base does not keep its predicate or setter',
      !S.dynamic_name?('done?', dyn, Set.new, Set['width']) && !S.dynamic_name?('done=', dyn, Set.new, Set.new))
check('suffix: the base itself stays dynamic', S.dynamic_name?('done', dyn, Set.new, Set.new))
check('suffix: the default keeps the rule for every dynamic base', S.dynamic_name?('done?', dyn, Set.new))
check('suffix: "=", "?", "!" are the suffix literals',
      %w[= ? !].all? { |c| c.match?(S::SUFFIX_LITERAL) } && !'=='.match?(S::SUFFIX_LITERAL))
root = File.expand_path('../..', __dir__)
scanning = "#{root}/3rd/mruby/include/mruby/presym/scanning.h"
check('naming_macros: presym/scanning.h redefinitions are not the build',
      S.naming_macros_in([File.read(scanning)]).include?('mrb_funcall') && S.naming_macros([scanning]).empty?)

# --- NON_LOOKUP_HELPERS ---
gen = <<~'CPP'
  static const char* const bc2cpp_sym_names[4] = {
    "quiet",
    "sent",
    "symbol",
    "mixed",
  };
  r1 = bc2cpp_nomethod(M, r0, 0);
  r2 = bc2cpp_nil_receiver(M, r0, 0, 1, r1);
  r3 = bc2cpp_hint_violation(M, r0, 0, "site", 0);
  r4 = bc2cpp_send(M, r0, 1, 0);
  r5 = mrb_funcall_id(M, r0, bc2cpp_sym(M, 2), 0);
  r6 = bc2cpp_guard_violation(M, r0, 3, "site", 0);
  r7 = bc2cpp_owner_call(M, r0, 3, 2, BC2CPP_OWNERS("Game::Actor"), mrb_nil_value(), 0);
CPP
free = S.lookup_free_names(gen, {})
check('non-lookup: only nomethod / nil_receiver / hint_violation uses', free.include?('quiet'))
check('non-lookup: a bc2cpp_send use is a lookup', !free.include?('sent'))
check('non-lookup: a bc2cpp_sym(M, i) use is a lookup', !free.include?('symbol'))
check('non-lookup: an owner call next to a guard violation is a lookup', !free.include?('mixed'))

# --- OWNER_CALL_GUARDED ---
owner_gen = <<~'CPP'
  static const char* const bc2cpp_sym_names[6] = {
    "core_only",
    "chained",
    "subclassed",
    "direct",
    "unguarded",
    "other_recv",
  };
  static inline struct RClass* bc2cpp_owner_class_1(mrb_state* M) {
    struct RClass* c = bc2cpp_owner_class_slots[1];
    if (!c) {
      static const char* const path[] = {"Game", "Party"};
  r1 = bc2cpp_owner_call(M, r0, 0, 2, BC2CPP_OWNERS("Array"), mrb_nil_value(), 0);
  if (bc2cpp_class_is(M, r0, bc2cpp_owner_class_1(M))) {
    r2 = Game__Party_chained_impl(M, r0);
  } else if (bc2cpp_class_is(M, r0, rgss::native_bitmap_class())) {
    r2 = rgss::bitmap_chained_direct(M, r0);
  } else {
    BC2CPP_COLD_ARM r2 = bc2cpp_owner_call(M, r0, 1, 2, BC2CPP_OWNERS("Array", "Game::Party", "RGSS::Bitmap"), mrb_nil_value(), 0);
  }
  if (bc2cpp_class_is(M, r0, bc2cpp_owner_class_1(M))) {
    r3 = Game__Party_subclassed_impl(M, r0);
  } else {
    r3 = bc2cpp_owner_call(M, r0, 2, 2, BC2CPP_OWNERS("Game::Party"), mrb_nil_value(), 0);
  }
  if (bc2cpp_class_is(M, r0, bc2cpp_owner_class_1(M))) {
    r4 = Game__Party_direct_impl(M, r0);
  } else {
    r4 = bc2cpp_owner_call(M, r0, 3, 2, BC2CPP_OWNERS_D(BC2CPP_OWNER_DIRECT("Game::Party", Game__Party_direct, MRB_ARGS_REQ(0), MRB_METHOD_PUBLIC_FL) BC2CPP_OWNER_DIRECT("Game::Actor", Game__Actor_direct, MRB_ARGS_REQ(0), MRB_METHOD_PUBLIC_FL), "Game::Actor", "Game::Party"), mrb_nil_value(), 0);
  }
  if (bc2cpp_class_is(M, r0, bc2cpp_owner_class_1(M))) {
    r5 = Game__Party_unguarded_impl(M, r0);
  } else {
    r5 = bc2cpp_owner_call(M, r0, 4, 2, BC2CPP_OWNERS("Game::Actor", "Game::Party"), mrb_nil_value(), 0);
  }
  if (bc2cpp_class_is(M, r9, bc2cpp_owner_class_1(M))) {
    r6 = Game__Party_other_recv_impl(M, r9);
  } else {
    r6 = bc2cpp_owner_call(M, r0, 5, 2, BC2CPP_OWNERS("Game::Party"), mrb_nil_value(), 0);
  }
CPP
owner_free = S.lookup_free_names(owner_gen, %w[Bitmap])
check('owner call: listing no engine owner looks nothing up', owner_free.include?('core_only'))
check('owner call: the else of a chain testing every listed engine owner looks nothing up',
      S.lookup_free_names(owner_gen, []).include?('chained'))
check('owner call: a tested owner something subclasses is still looked up', !owner_free.include?('chained'))
check('owner call: a subclassed tested owner is looked up without its entry',
      !S.lookup_free_names(owner_gen, %w[Party]).include?('subclassed'))
check('owner call: direct entries cover their owners, tested and subclassed or not',
      S.lookup_free_names(owner_gen, %w[Party]).include?('direct'))
check('owner call: a listed owner neither tested nor direct is looked up', !owner_free.include?('unguarded'))
check('owner call: a chain testing another receiver covers nothing', !S.lookup_free_names(owner_gen, []).include?('other_recv'))
supers = S.define_class_superclasses('mrb_define_class_under(M, m, "Bitmap", M->object_class); ' \
                                     'mrb_define_class(M, "X", mrb_class_get(M, "Base, too"));')
check('subclass scan: a define call\'s superclass is its last argument, not its own name',
      supers == ['M->object_class', 'mrb_class_get(M, "Base, too")'] &&
      supers.map { |a| a.match?(S::BUILTIN_SUPERCLASS) } == [true, false])
values = <<~'CPP'
  static const char* const bc2cpp_sym_names[4] = {
    "as_value",
    "compared",
    "keyword",
    "called",
  };
  r1 = mrb_symbol_value(bc2cpp_sym(M, 0));
  r2 = mrb_bool_value(mrb_symbol_p(r1) && mrb_symbol(r1) == bc2cpp_sym(M, 1));
  mrb_sym bc2cpp_kw_table[1] = { bc2cpp_sym(M, 2) };
  r3 = bc2cpp_funcall_argv(M, r0, bc2cpp_sym(M, 3), 0, nullptr);
  r4 = mrb_symbol_value(bc2cpp_sym(M, 3));
CPP
quiet_values = S.lookup_free_names(values, {}, symbol_values: true)
check('symbol uses: a symbol value, a comparison and a keyword name are no lookup',
      quiet_values.include?('as_value') && quiet_values.include?('compared') && quiet_values.include?('keyword'))
check('symbol uses: a by-name call of the symbol is one, beside a value use', !quiet_values.include?('called'))
check('symbol uses: without SYMBOL_USES a symbol value is a lookup', S.lookup_free_names(values, {}).empty?)
check('left out: a bc2cpp_left_out call is no name literal',
      S.c_literals(%(bc2cpp_left_out(M, picture, "finish_zoom", false);\n mrb_funcall(M, v, "kept", 0);)) == ['kept'])

# --- BYTECODE_PROC ---
check('bytecode proc: mrb_proc_new / mrb_closure_new',
      'p = mrb_proc_new(M, irep);'.match?(S::BYTECODE_PROC) && 'mrb_closure_new (M, irep)'.match?(S::BYTECODE_PROC))
check('bytecode proc: a C proc is not one', !'mrb_proc_new_cfunc_with_env(M, f, 1, &v)'.match?(S::BYTECODE_PROC))

# --- OTHER_MAKER_GEMS ---
ruby, natives = S.outside_world_files(root, closed_only: true)
others = (ruby + natives).select { |p| S::OTHER_MAKER_GEMS.any? { |g| p.start_with?("#{root}/#{g}/") } }
check('closed scan reads no other maker gem', others.empty?)
open_ruby, = S.outside_world_files(root)
check('the full scan still reads them', open_ruby.any? { |p| p.start_with?("#{root}/mruby-wolf/") })
check('closed scan reads no workflow', ruby.none? { |p| p.start_with?("#{root}/.github/") })
check('the full scan reads the workflows', open_ruby.any? { |p| p.start_with?("#{root}/.github/") })

# --- engine_ancestry ---
check('ancestry: engine classes only reach Object',
      S.engine_ancestry({ 'Game::A' => 'Game::B', 'Game::B' => :none }, []) == Set['Object', 'BasicObject'])
exc = S.engine_ancestry({ 'LCF::SaveError' => 'LCF::StandardError' }, [])
check('ancestry: a native exception superclass', exc != :all && exc.superset?(Set['StandardError', 'Exception']))
check('ancestry: any other native superclass is unknown', S.engine_ancestry({ 'Game::N' => 'RGSS::Native' }, []) == :all)
check('ancestry: an engine Struct', S.engine_ancestry({}, ['Game::Row']).include?('Struct'))

# --- CORE_BYTECODE_TOKENS ---
if ENV['MRBC']
  require 'tmpdir'
  ENV['BC2CPP_SIG_DIRS'] = ''
  require_relative '../../tools/bc2cpp/bc2cpp'
  Dir.mktmpdir('static_dispatch_scan_check') do |tmp|
    plain = File.join(tmp, 'plain.rb')
    File.write(plain, <<~'RUBY')
      module FixMix
        def fm = mixin_self_send
      end
      class FixCore
        def fc
          core_self_send
          [].literal_send
          FixCore.core_const_send
          x = unknown_value
          x.unknown_recv_send
          [].push(:symbol_literal, 'string_literal_name')
        end
      end
      class Object
        def fo = object_self_send
      end
    RUBY
    reflective = File.join(tmp, 'reflective.rb')
    File.write(reflective, "class FixRefl\n  def r(m) = __send__(m, reflective_local_word)\nend\n")
    tokens = Set.new
    text = S.core_bytecode_tokens([plain, reflective], tokens, mrbc: ENV['MRBC'], superclass_of: {})
    check('core: self in a module method counts', tokens.include?('mixin_self_send'))
    check('core: self in an Object method counts', tokens.include?('object_self_send'))
    check('core: self in a core class method does not', !tokens.include?('core_self_send'))
    check('core: a literal or a core constant receiver does not',
          !tokens.include?('literal_send') && !tokens.include?('core_const_send'))
    check('core: an unknown receiver counts', tokens.include?('unknown_recv_send'))
    check('core: symbols and identifier strings count',
          tokens.include?('symbol_literal') && tokens.include?('string_literal_name'))
    check('core: a reflective file keeps the text rule', text == [reflective] && !tokens.include?('reflective_local_word'))

    # --- FRAGMENT_USES ---
    fragments = File.join(tmp, 'fragments.rb')
    File.write(fragments, <<~'RUBY')
      class FixFrag
        LIST = %w[list_member other_member].freeze
        def compared(x) = x == 'compared_word'
        def looked_up(h) = h['hash_key_word'] == 1
        def member(x) = LIST.include?(x)
        def message(x)
          kind = 'message_word'
          "#{x}: #{kind}"
        end
        def built(x) = respond_to?("#{x}_built_suffix")
        def built_logged(x) = puts("#{x}_logged_suffix")
        def built_compared(x) = "#{x}_compared_suffix" == 'other'
        def built_sent(o, x) = o.send("#{x}_sent_suffix")
        def built_interned(h, x) = h[:"#{x}_interned_suffix"]
        def setter_name(x) = respond_to?("#{x}=")
        def bang_char(c) = c == '!'
        def stored = @word = 'stored_word'
        def handed(o) = o.anything('handed_word')
        def label = 'returned_word'
        def use_label(x) = "#{x}#{label}"
        def duped_array_handed(o)
          list = ['duped_elem_word', 'other'].dup
          o.anything(list)
        end
        def frozen_array_queried(x)
          list = ['frozen_elem_word', 'other'].freeze
          list.include?(x)
        end
      end
    RUBY
    ireps, root_label = compile_ireps([fragments], 'static_dispatch_scan_check', tmp, mrbc: ENV['MRBC'])
    registry, = build_registry(ireps, root_label)
    body_of = {}
    registry.each { |name, defs| defs.each { |d| body_of[d.irep] = [d.owner, name] if d.irep } }
    parent = {}
    ireps.each_value { |irep| irep.reps.each { |c| parent[c] = irep.label } }
    method_of = ireps.keys.to_h do |label|
      up = label
      up = parent[up] until up.nil? || body_of.key?(up)
      [label, up]
    end
    escaping = StaticDispatchFragmentUses.escaping(ireps, body_of, method_of, Set.new, S::FRAGMENT)
    check('fragment uses: a compared literal is no fragment', !escaping.include?('compared_word'))
    check('fragment uses: a native hash key is no fragment', !escaping.include?('hash_key_word'))
    check('fragment uses: a constant list only tested for membership is no fragment',
          !escaping.include?('list_member') && !escaping.include?('other_member'))
    check('fragment uses: a part of a message with a non-name character is no fragment', !escaping.include?('message_word'))
    check('fragment uses: a part of a name reaching respond_to? is one', escaping.include?('_built_suffix'))
    check('fragment uses: a part of a string only printed or compared is no fragment',
          !escaping.include?('_logged_suffix') && !escaping.include?('_compared_suffix'))
    check('fragment uses: a part of a string reaching send, or interned, is one',
          escaping.include?('_sent_suffix') && escaping.include?('_interned_suffix'))
    check('fragment uses: a stored literal is one', escaping.include?('stored_word'))
    check('fragment uses: an argument of an unknown method is one', escaping.include?('handed_word'))
    check('fragment uses: a returned literal concatenated by a caller is one', escaping.include?('returned_word'))
    check('fragment uses: an element of a duped array handed out is one', escaping.include?('duped_elem_word'))
    check('fragment uses: an element of a frozen array only queried is no fragment',
          !escaping.include?('frozen_elem_word'))
    # IDENT_USES: the same question for an exact name; the closed proof asks it only once SYMBOL_USES holds.
    names = StaticDispatchFragmentUses.escaping(ireps, body_of, method_of, Set.new, S::IDENT)
    check('ident uses: a compared or hash-key name is no lookup, a stored or handed-out one is',
          !names.include?('compared_word') && !names.include?('hash_key_word') &&
          names.include?('stored_word') && names.include?('handed_word'))
    # --- SYMBOL_USES ---
    symbols = File.join(tmp, 'symbols.rb')
    File.write(symbols, <<~'RUBY')
      class FixSym
        def keyed(h) = h[:hash_key_sym]
        def probe(o) = o.respond_to?(:probed_sym)
        def labelled(x) = x == :compared_sym
        def summed(list) = list.reduce(0) { |s, e| s + e }
        def mapped(list) = list.map(&:block_sym)
        def forwarded(list, &blk) = list.each(&blk)
        def enumerated = to_enum(:enum_sym)
      end
    RUBY
    sym_ireps, = compile_ireps([symbols], 'static_dispatch_scan_check_sym', tmp, mrbc: ENV['MRBC'])
    found = StaticDispatchSymbolUses.lookups(sym_ireps)
    check('symbol uses: literal name-taking calls pass, and only their literals name a method',
          found == Set['block_sym', 'enum_sym'])
    refused = File.join(tmp, 'symbols_refused.rb')
    File.write(refused, <<~'RUBY')
      class FixSymRefused
        def computed(o, name) = o.send(name)
      end
    RUBY
    refused_ireps, = compile_ireps([refused], 'static_dispatch_scan_check_sym_refused', tmp, mrbc: ENV['MRBC'])
    check('symbol uses: a computed name to send refuses', StaticDispatchSymbolUses.lookups(refused_ireps).nil?)
    blockvar = File.join(tmp, 'symbols_block_var.rb')
    File.write(blockvar, <<~'RUBY')
      class FixSymBlockVar
        def passed(list, name) = list.map(&name)
      end
    RUBY
    blockvar_ireps, = compile_ireps([blockvar], 'static_dispatch_scan_check_sym_block', tmp, mrbc: ENV['MRBC'])
    check('symbol uses: a block argument from a parameter refuses', StaticDispatchSymbolUses.lookups(blockvar_ireps).nil?)
    listing = File.join(tmp, 'symbols_listing.rb')
    File.write(listing, <<~'RUBY')
      class FixSymListing
        def listed(o) = o.methods.size
      end
    RUBY
    listing_ireps, = compile_ireps([listing], 'static_dispatch_scan_check_sym_listing', tmp, mrbc: ENV['MRBC'])
    check('symbol uses: a call that lists methods refuses', StaticDispatchSymbolUses.lookups(listing_ireps).nil?)

    suffixes = StaticDispatchFragmentUses.escaping(ireps, body_of, method_of, Set.new, S::SUFFIX_LITERAL)
    check('suffix: a "=" building a setter name reaches a built string', suffixes.include?('='))
    check('suffix: a compared "!" does not', !suffixes.include?('!'))
  end
else
  puts 'skip CORE_BYTECODE_TOKENS / FRAGMENT_USES fixtures (no MRBC)'
end

# --- GENERATED_REGISTRATION ---
S::GEMS.each do |gem|
  src = File.read(File.join(root, gem, 'src', 'register.cxx')).gsub(%r{//[^\n]*}, '')
  check("#{gem}: src/register.cxx registers nothing by hand", !src.match?(/\bmrb_define_\w*method\s*\(/))
end
check('closed owners: RGSS is unregisterable only for the closed list',
      S.owner_re(true).match?('RGSS::Sprite') && !S.owner_re(false).match?('RGSS::Sprite'))
check('closed owners: engine module singletons, but not reopened core classes',
      S.owner_re(true).match?('Game.singleton') && !S.owner_re(true).match?('Array') &&
      !S.owner_re(true).match?('Game2::X'))

if $failures.zero?
  puts 'static_dispatch_scan_check: all passed'
else
  abort "static_dispatch_scan_check: #{$failures} failure(s)"
end
