#!/usr/bin/env ruby
# frozen_string_literal: true

# NATIVE_CALLBACKS (phase 1, report only): the callback names of each native registration's C closure
# (tools/bc2cpp/native_callbacks.rb). Every rule is checked on a fixture whose closure is known, in both directions:
# a name that is reached is listed, and a name that is not reached is not. Then the real mruby tree: `Kernel#class`
# has no callbacks and a complete closure, which is what the phase-2 Fiber analysis will rely on.
#
# Usage: ruby scripts/bc2cpp/native_callbacks_check.rb

require 'tmpdir'
require_relative '../../tools/bc2cpp/native_callbacks'

ROOT = File.expand_path('../..', __dir__)
failures = []
check = lambda do |description, ok|
  puts "  #{ok ? 'ok  ' : 'FAIL'} #{description}"
  failures << description unless ok
end

# Stubs for the mruby API the fixtures call, so the closures stay inside the fixture.
STUBS = <<~C
  mrb_value mrb_funcall(mrb_state *mrb, mrb_value self, const char *name, int n) { return self; }
  mrb_value mrb_funcall_id(mrb_state *mrb, mrb_value self, int sym, int n) { return self; }
  mrb_value mrb_iterate(mrb_state *mrb, mrb_value self, mrb_value (*fn)(mrb_state *, mrb_value)) { return self; }
  mrb_value mrb_obj_value(void *p) { return 0; }
  void mrb_define_method(mrb_state *mrb, void *c, const char *name, void *fn, int a) {}
  void mrb_define_alias(mrb_state *mrb, void *c, const char *new_name, const char *old_name) {}
C

FIXTURE = <<~C
  #define GEN(c, n) void c##_##n(void *p) { mrb_funcall(p, 0, "gen_callee", 0); }
  #define GEN2(c, n) GEN(c, n)
  GEN2(fx, gen)
  mrb_value fx_dyn(mrb_state *mrb, mrb_value self, mrb_value mid) { return mrb_funcall(mrb, self, mid, 0); }
  mrb_value fx_gen_user(mrb_state *mrb, mrb_value self) { fx_gen(0); return self; }
  mrb_value fx_dyn_user(mrb_state *mrb, mrb_value self) { return fx_dyn(mrb, self, self); }
  #define fx_macro(mrb) mrb_funcall(mrb, 0, "via_macro", 0)
  #define mrb_int_m(mrb, v) mrb_funcall(mrb, 0, "macro_only", 0)
  mrb_value helper(mrb_state *mrb, mrb_value self) { return mrb_funcall(mrb, self, "fixture_callee", 0); }
  mrb_value fx_m(mrb_state *mrb, mrb_value self) { return helper(mrb, self); }
  mrb_value ghost(mrb_state *mrb, mrb_value self) { /* mrb_funcall(mrb, self, "ghost_name", 0) */ return self; }
  mrb_value cb(mrb_state *mrb, mrb_value self) { return mrb_funcall(mrb, self, "via_ref", 0); }
  mrb_value fx_ref(mrb_state *mrb, mrb_value self) { return mrb_iterate(mrb, self, cb); }
  mrb_value via_field_name(mrb_state *mrb, mrb_value self) { return mrb_funcall(mrb, self, "should_not_appear", 0); }
  mrb_value fx_field(mrb_state *mrb, mrb_value self) { struct S *s = 0; return mrb_obj_value(s->via_field_name); }
  mrb_value fx_sym(mrb_state *mrb, mrb_value self) { return mrb_funcall_id(mrb, self, MRB_SYM(sym_token), 0); }
  mrb_value fx_macro_user(mrb_state *mrb, mrb_value self) { return fx_macro(mrb); }
  mrb_value fx_cast(mrb_state *mrb, mrb_value self) { return (mrb_value)(mrb_int_m); }
  mrb_value fx_ptr(mrb_state *mrb, mrb_value self) { struct ops *o = 0; return o->fn(mrb); }
  mrb_value fx_unknown(mrb_state *mrb, mrb_value self) { return unknown_fn(mrb); }
  void init(mrb_state *mrb) {
    void *c = 0;
    mrb_define_method(mrb, c, "fx", fx_m, 0);
    mrb_define_method(mrb, c, "ref", fx_ref, 0);
    mrb_define_method(mrb, c, "ghost", ghost, 0);
    mrb_define_method(mrb, c, "field", fx_field, 0);
    mrb_define_method(mrb, c, MRB_SYM(sym_name), fx_sym, 0);
    mrb_define_method(mrb, c, "macro_user", fx_macro_user, 0);
    mrb_define_method(mrb, c, "cast", fx_cast, 0);
    mrb_define_method(mrb, c, "ptr", fx_ptr, 0);
    mrb_define_method(mrb, c, "unknown", fx_unknown, 0);
    mrb_define_alias(mrb, c, "fx_alias", "fx");
    mrb_define_method(mrb, c, "gen", fx_gen_user, 0);
    mrb_define_method(mrb, c, "dyn", fx_dyn_user, 0);
  }
C

Dir.mktmpdir('native_callbacks_check') do |dir|
  path = File.join(dir, 'fixture.c')
  File.write(path, STUBS + FIXTURE)
  entries = NativeCallbacks.analyze([path])
  cb = ->(name) { entries.fetch(name).callbacks }

  puts 'fixture closures:'
  check.call('a call through a helper reaches the callee string', cb.('fx').include?('fixture_callee'))
  check.call('a function pointer passed on reaches its body', cb.('ref').include?('via_ref'))
  check.call('a comment is not code', !cb.('ghost').include?('ghost_name'))
  check.call('a struct field read does not reach a same-named function', !cb.('field').include?('should_not_appear'))
  check.call('MRB_SYM tokens are callbacks', cb.('sym_name').include?('sym_token'))
  check.call('a call of a function-like macro reaches its body', cb.('macro_user').include?('via_macro'))
  check.call('a bare type name does not reach a macro body', !cb.('cast').include?('macro_only'))
  check.call('an alias carries its target closure', cb.('fx_alias').include?('fixture_callee'))
  check.call('a member call through a pointer makes the closure incomplete', !entries['ptr'].complete)
  check.call('a call to an unindexed function makes the closure incomplete', !entries['unknown'].complete)
  check.call('the unindexed call is named', entries['unknown'].unresolved.include?('unknown_fn'))
  check.call('a complete fixture closure is complete', entries['fx'].complete)
  check.call('a function generated by a file-local macro is reached', cb.('gen').include?('gen_callee'))
  check.call('a dispatch with a run-time name makes the closure incomplete', !entries['dyn'].complete)
  check.call('the run-time dispatch is named', entries['dyn'].unresolved.include?('mrb_funcall(dynamic callee)'))
end

if File.directory?(File.join(ROOT, '3rd/mruby/src'))
  puts 'real mruby tree:'
  paths = Dir["#{ROOT}/3rd/mruby/src/**/*.c"] + Dir["#{ROOT}/3rd/mruby/mrbgems/*/{src,core}/**/*.c"]
  paths += Dir["#{ROOT}/3rd/mruby/include/**/*.h"] + Dir["#{ROOT}/include/**/*.h"] + Dir["#{ROOT}/3rd/mruby/src/**/*.h"]
  paths += Dir["#{ROOT}/3rd/mruby/mrbgems/*/{src,include,core}/**/*.h"]
  paths.reject! { |p| p.include?('/test/') || p.include?('mruby-bin-') }
  kernel_class = NativeCallbacks.analyze(paths).fetch('class')
  check.call('Kernel#class has no callbacks', kernel_class.callbacks.empty?)
  check.call('Kernel#class has a complete closure', kernel_class.complete)
  check.call('hash.c accessors generated by DEFINE_ACCESSOR are indexed', NativeCallbacks.index(paths).any? { |b| b.name == 'ar_ea' })
  check.call('hash.c switchers generated by DEFINE_SWITCHER are indexed (each function on its own line)', NativeCallbacks.index(paths).any? { |b| b.name == 'h_ht_p' } && NativeCallbacks.index(paths).any? { |b| b.name == 'h_ht_off' })
else
  puts '  SKIP: 3rd/mruby is not checked out; the real-tree assertions did not run'
end

exit(failures.empty? ? 0 : 1)
