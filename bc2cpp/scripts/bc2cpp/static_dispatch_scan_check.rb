#!/usr/bin/env ruby
# frozen_string_literal: true

# STATIC_DISPATCH_UNREGISTRATION's scan rules (tools/bc2cpp/static_dispatch_registrations.rb), on fixture text:
#
#   NATIVE_NAME_TOKENS (closed only): a native file names a method only through a string literal, a presym macro
#     (MRB_SYM(name), MRB_SYM_Q(name), ...) or the arguments of a macro that makes a name of its argument
#     (naming_macros: `#param`, a presym macro of the parameter, or a call passing it on to another such macro).
#     A bare C identifier names nothing.
#   NON_LOOKUP_HELPERS: a generated symbol whose every use is bc2cpp_nomethod(_raise), bc2cpp_guard_violation,
#     bc2cpp_hint_violation or bc2cpp_nil_receiver is no dynamic lookup; any bc2cpp_send, owner call or
#     bc2cpp_sym(M, i) use keeps it one.
#   BYTECODE_PROC: what counts as generated C building a proc over a bytecode irep (which keeps every block of a
#     registered compiled method runnable as bytecode).
#   OTHER_MAKER_GEMS: the closed scan reads none of the other makers' sources, nor the workflows.
#   CORE_BYTECODE_TOKENS (needs MRBC; skipped without it): core Ruby read as bytecode names a method only through a
#     send whose receiver may be an engine object (self in a module, Object or Kernel method; any unknown value), a
#     symbol or an identifier-shaped string; self in a core class method, a literal and a core constant do not. A
#     file with a reflective send keeps the text rule. engine_ancestry follows superclasses, mruby's native
#     exception chain included, and gives up (:all) on any other native superclass.
#   FRAGMENT_USES (needs MRBC; skipped without it): a pool literal stays a fragment only when a load of it may reach
#     a built string -- a concatenation without a non-name character, a store, a return a caller passes on, an
#     argument of a method the trace does not know. Comparing it, a native hash key, a constant list only tested
#     for membership and a part of a message with a space or a colon do not.
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
S.native_name_tokens(native, tokens, naming)
check('native: string literal', tokens.include?('refresh'))
check('native: MRB_SYM_Q / MRB_SYM_E', tokens.include?('visible?') && tokens.include?('width='))
check('native: naming macro arguments', tokens.include?('redraw') && tokens.include?('relayout'))
check('native: bare identifiers name nothing', !tokens.include?('size') && !tokens.include?('preview_map_id'))
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
  r7 = bc2cpp_owner_call(M, r0, 3, 2, BC2CPP_OWNERS(0), mrb_nil_value(), 0);
CPP
free = S.lookup_free_names(gen, {})
check('non-lookup: only nomethod / nil_receiver / hint_violation uses', free.include?('quiet'))
check('non-lookup: a bc2cpp_send use is a lookup', !free.include?('sent'))
check('non-lookup: a bc2cpp_sym(M, i) use is a lookup', !free.include?('symbol'))
check('non-lookup: an owner call next to a guard violation is a lookup', !free.include?('mixed'))

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
        def stored = @word = 'stored_word'
        def handed(o) = o.anything('handed_word')
        def label = 'returned_word'
        def use_label(x) = "#{x}#{label}"
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
    check('fragment uses: a stored literal is one', escaping.include?('stored_word'))
    check('fragment uses: an argument of an unknown method is one', escaping.include?('handed_word'))
    check('fragment uses: a returned literal concatenated by a caller is one', escaping.include?('returned_word'))
  end
else
  puts 'skip CORE_BYTECODE_TOKENS / FRAGMENT_USES fixtures (no MRBC)'
end

if $failures.zero?
  puts 'static_dispatch_scan_check: all passed'
else
  abort "static_dispatch_scan_check: #{$failures} failure(s)"
end
