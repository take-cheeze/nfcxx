#!/usr/bin/env ruby
# encoding: UTF-8
# Check EMBED_GUARD_FALLBACK (docs/adr/0206), the one place
# tools/bc2cpp/static_dispatch_registrations.rb stops counting a generated
# C++ literal as a dynamic lookup: a symbol-table name whose every use is the
# by-name fallback of a MONO_EMBED_GUARD for that same method, on an owner
# nothing subclasses. Pins each condition on a fixture, so a change to
# bc2cpp.rb's guard shape or to the rule fails here rather than silently
# unregistering a method something still looks up.

require 'set'
require_relative '../../tools/bc2cpp/static_dispatch_registrations'

S = StaticDispatchRegistrations
failures = []
check = lambda do |what, condition|
  puts "  #{condition ? 'ok  ' : 'FAIL'} #{what}"
  failures << what unless condition
end

def guard(owner, name, sym)
  <<~CPP
    // MONO_EMBED_GUARD :#{name} -> #{owner}##{name} (embeds ivars; method_missing elsewhere could otherwise mistarget this), runtime-class-checked direct C++ call, mrb_funcall fallback
    if (bc2cpp_owner_class_1(M) == mrb_obj_class(M, self)) {
      r5 = #{owner.gsub('::', '__')}_#{name}_impl(M, self);
    } else {
      r5 = bc2cpp_send(M, self, #{sym}, 0);
    }
  CPP
end

table = <<~CPP
  static const char* const bc2cpp_sym_names[4] = {
    "guarded_only",
    "also_sent",
    "on_subclassed",
    "on_singleton",
  };
CPP
src = table + guard('Game::Map', 'guarded_only', 0) + guard('Game::Map', 'also_sent', 1) +
      "  r1 = bc2cpp_send(M, bc2cpp_send(M, r1, 1, 0), 1, 0);\n" +
      guard('RPG2k::Scene::Base', 'on_subclassed', 2) + guard('Game::Map.singleton', 'on_singleton', 3)
subclassed = Set['RPG2k::Scene::Base']
exempt = S.embed_guard_fallback_only(src, subclassed)

check.call('a name used only as its own guard fallback is exempt', exempt.include?('guarded_only'))
check.call('a name with any other use stays dynamic', !exempt.include?('also_sent'))
check.call('a subclassed owner keeps its fallback dynamic', !exempt.include?('on_subclassed'))
check.call('a .singleton owner keeps its fallback dynamic', !exempt.include?('on_singleton'))
check.call('an exempt name leaves c_literals only through the symbol table',
           !S.c_literals(src, exempt: exempt).include?('guarded_only') &&
             S.c_literals(src + %(  const char* s = "guarded_only";\n), exempt: exempt).include?('guarded_only'))

check.call('a relative superclass path blocks every owner ending in it', S.subclassed?('RPG2k::Scene::Base', Set['Base']))
check.call('an unrelated class sharing a short name is not blocked',
           !S.subclassed?('Game::Battle', Set['RPG2k::Scene::Battle']))
check.call('an unnameable superclass (a computed Class.new argument) blocks every owner',
           S.subclassed?('Game::Map', Set[S::ANY_CLASS]))

if failures.empty?
  puts 'bc2cpp embed guard exemption check: PASS'
else
  warn "bc2cpp embed guard exemption check: #{failures.size} failure(s)"
  exit 1
end
