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
#   OTHER_MAKER_GEMS: the closed scan reads none of the other makers' sources.
#
# Usage: ruby scripts/bc2cpp/static_dispatch_scan_check.rb   (no mrbc needed)

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

if $failures.zero?
  puts 'static_dispatch_scan_check: all passed'
else
  abort "static_dispatch_scan_check: #{$failures} failure(s)"
end
