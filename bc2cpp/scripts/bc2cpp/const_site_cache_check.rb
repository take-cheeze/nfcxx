#!/usr/bin/env ruby
# encoding: UTF-8
# Check CONST_SITE_CACHE (tools/bc2cpp/const_site_cache.rb): a GETCONST site is
# cached only for a bare name the whole program provably binds to ONE
# class/module for the life of the VM (StableClassConstants), and the cached
# helper stores a class/module value only, never a failed lookup, per VM,
# without disturbing the symbol cache (tools/bc2cpp/symbol_cache.rb).
#
# Cached wrongly, a reassigned or shadowed constant would keep resolving to its
# first value; the analysis cases below are the ways that can happen.

require 'tmpdir'
require_relative '../../tools/bc2cpp/bc2cpp'
require_relative 'cxx'

failures = []
check = lambda do |what, condition|
  puts "  #{condition ? 'ok  ' : 'FAIL'} #{what}"
  failures << what unless condition
end

SRC = <<~'RUBY'
  module Game
    class Stable; end
    class Reopened; end
    class Reopened; def again; end; end
    class Assigned; end
    Assigned = 1
    Value = 5
    class UserOfStable
      def use; Stable; end
    end
  end
  module Other
    class Shadowed; end
  end
  module Elsewhere
    class Shadowed; end
  end
  class NativeDefined; end
RUBY

Dir.mktmpdir do |dir|
  source = File.join(dir, 'stable.rb')
  File.write(source, SRC)
  ireps, root_label = compile_ireps(source, 'bc2cpp_stable', dir)
  order = dfs_order(ireps, root_label)

  native = File.join(dir, 'native.cxx')
  File.write(native, 'void f(mrb_state* M) { mrb_define_class(M, "NativeDefined", M->object_class); }')
  clean_foreign = File.join(dir, 'clean.rb')
  File.write(clean_foreign, "class Foreign; end\n")
  mutating_foreign = File.join(dir, 'mutating.rb')
  File.write(mutating_foreign, "Object.const_set(:Sneaky, Class.new)\n")

  stable = StableClassConstants.analyze(ireps, [native], [clean_foreign])
  check.call('a class defined by exactly one class statement is stable', stable.include?('Stable'))
  check.call('a class reopened (two class statements) is not', !stable.include?('Reopened'))
  check.call('a name that is also assigned with `Name = ...` is not', !stable.include?('Assigned'))
  check.call('a plain value constant is not (only class statements qualify)', !stable.include?('Value'))
  check.call('two classes of one bare name in different scopes are not (shadowing)', !stable.include?('Shadowed'))
  check.call('a name a native source defines is not', !stable.include?('NativeDefined'))
  check.call('a name a foreign Ruby source defines is not', !stable.include?('Foreign'))
  check.call('without the native/foreign inputs nothing can be proven',
             StableClassConstants.analyze(ireps, nil, [clean_foreign]).empty? &&
               StableClassConstants.analyze(ireps, [native], nil).empty?)
  check.call('a program that calls const_set caches nothing', StableClassConstants.analyze(ireps, [native], [mutating_foreign]).empty?)

  # Emission through the real GETCONST codegen.
  CodeGen.stable_class_constants = Set['Stable']
  registry = build_registry(ireps, root_label)[0]
  gen = CodeGen.new(ireps, registry, {}, {}, {}, {}, {}, {}, {}, {}, {}, Set.new)
  user = registry.fetch('use').find { |md| md.owner == 'Game::UserOfStable' }
  irep = ireps.fetch(user.irep)
  idx = irep.instructions.index { |insn| insn.op == 'GETCONST' }
  code = gen.compile_insn(irep.instructions[idx], irep, user, idx)
  check.call('a stable name is read through its site helper', code.match?(/r\d+ = bc2cpp_cconst_0\(M\);/) && !code.include?('mrb_const_get'))
  CodeGen.stable_class_constants = Set.new
  gen2 = CodeGen.new(ireps, registry, {}, {}, {}, {}, {}, {}, {}, {}, {}, Set.new)
  plain = gen2.compile_insn(irep.instructions[idx], irep, user, idx)
  check.call('an unproven name keeps the ordinary lookup', plain.include?('bc2cpp_const_scope_') && !plain.include?('bc2cpp_cconst_'))

  # Helper behaviour against stubs, and its independence from the symbol cache.
  if system('g++', '--version', out: File::NULL, err: File::NULL)
    helper_gen = CodeGen.new({}, {}, {}, {}, {}, {}, {}, {}, {}, {}, {}, Set.new)
    helper_gen.instance_variable_set(:@const_site_cache,
                                     { %w[Object Stable] => { index: 0, body: helper_gen.const_lookup_block('0', 'Stable', ['Object']) },
                                       %w[Object Plain] => { index: 1, body: helper_gen.const_lookup_block('0', 'Plain', ['Object']) } })
    table = SymbolCache::Table.new
    text = SymbolCache.rewrite(helper_gen.emit_const_site_cache, table)
    sym_table = SymbolCache.emit(table)
    harness = File.join(dir, 'const_harness.cpp')
    File.write(harness, <<~CPP)
      #include <cstdarg>
      #include <cstdio>
      #include <string>
      #include <vector>
      typedef unsigned mrb_sym;
      enum { MRB_TT_CLASS = 1, MRB_TT_MODULE = 2, MRB_TT_INTEGER = 3 };
      struct RClass { int id; };
      struct mrb_state { RClass* object_class; };
      struct mrb_value { int tt; long w; };
      static std::vector<std::string> interned;
      static mrb_sym mrb_intern_cstr(mrb_state*, const char* s) {
        for (size_t i = 0; i < interned.size(); ++i) if (interned[i] == s) return (mrb_sym)(i + 1);
        interned.push_back(s); return (mrb_sym)interned.size();
      }
      static int lookups = 0; static bool missing = false;
      static mrb_value mrb_obj_value(RClass*) { return { MRB_TT_CLASS, 0 }; }
      static mrb_value mrb_nil_value() { return { 0, 0 }; }
      static int mrb_type(mrb_value v) { return v.tt; }
      // Declared for symbol_cache.rb's bc2cpp_send, which this harness never calls.
      typedef long mrb_int;
      #define mrb_intern_lit(M, s) mrb_intern_cstr(M, s)
      static RClass* mrb_exc_get_id(mrb_state*, mrb_sym) { return nullptr; }
      static void mrb_raise(mrb_state*, RClass*, const char*) {}
      static mrb_value bc2cpp_funcall_argv(mrb_state*, mrb_value r, mrb_sym, mrb_int, const mrb_value*) { return r; }
      static mrb_value mrb_const_get(mrb_state*, mrb_value, mrb_sym s) {
        ++lookups;
        if (missing) throw 1;
        return interned[s - 1] == "Stable" ? mrb_value{ MRB_TT_CLASS, 42 } : mrb_value{ MRB_TT_INTEGER, 7 };
      }
      #{sym_table}
      #{text}
      static RClass object_class_storage;
      static mrb_state a = { &object_class_storage }, b = { &object_class_storage };
      int main() {
        long v = bc2cpp_cconst_0(&a).w; int first = lookups;
        for (int i = 0; i < 100; ++i) bc2cpp_cconst_0(&a);
        int cached = lookups == first && v == 42;
        bc2cpp_cconst_0(&b); int per_vm = lookups == first + 1;
        int before = lookups;
        for (int i = 0; i < 5; ++i) bc2cpp_cconst_1(&a);       // integer-valued: never stored
        int uncached_value = lookups == before + 5;
        // The two caches must be independent: interning a symbol must not
        // flush the const-site cache and vice versa. Re-establish slot 0 for
        // VM `a` first -- the cconst_1(&a) calls above already switched (and so
        // reset) the const-site cache's own state back to `a`.
        bc2cpp_cconst_0(&a);
        int before_sym = lookups;
        bc2cpp_sym(&a, 0);
        int sym_keeps_const = bc2cpp_cconst_have[0] && lookups == before_sym;
        bc2cpp_reset_const_site_cache();
        bc2cpp_sym(&a, 0);
        int const_reset_keeps_sym = lookups == before_sym;
        // gem_final calls both reset entry points; the const-site cache's own
        // entry point is what actually drops it. bc2cpp_cconst_0(&b) already
        // has a fresh (never-cached) slot 0 for VM b at this point (b was last
        // touched at line "per_vm" above, then untouched), so the only way this
        // call can add a lookup is via the explicit reset just below.
        bc2cpp_cconst_0(&b);
        int before_reset = lookups;
        bc2cpp_reset_const_site_cache();
        bc2cpp_cconst_0(&b);
        int reset = lookups == before_reset + 1;
        bc2cpp_reset_symbol_cache(); bc2cpp_reset_const_site_cache();
        missing = true; bool raised = false;
        try { bc2cpp_cconst_0(&b); } catch (int) { raised = true; }
        missing = false; int before2 = lookups; bc2cpp_cconst_0(&b);
        int failure_not_cached = raised && lookups > before2;
        std::printf("%d %d %d %d %d %d %d\\n", cached, per_vm, uncached_value, sym_keeps_const, const_reset_keeps_sym, reset, failure_not_cached);
      }
    CPP
    binary = File.join(dir, 'const_harness')
    built = Bc2cppCxx.system('-std=c++17', '-Wall', '-Werror', '-Wno-unused-function', '-Wno-unused-variable', harness, '-o', binary)
    check.call('the emitted const helpers compile', built)
    if built
      cached, per_vm, uncached_value, sym_keeps_const, const_reset_keeps_sym, reset, failure =
        IO.popen(binary, &:read).split.map { |v| v == '1' }
      check.call('a class constant is looked up once, then served from the cache', cached)
      check.call('a different VM looks it up again', per_vm)
      check.call('a non-class value is never cached', uncached_value)
      check.call('interning a symbol does not flush the const-site cache', sym_keeps_const)
      check.call('resetting the const-site cache does not flush interned symbols', const_reset_keeps_sym)
      check.call('bc2cpp_reset_const_site_cache (gem_final) forces a fresh lookup', reset)
      check.call('a failed lookup raises and stores nothing', failure)
    end
  end
end

if failures.empty?
  puts 'bc2cpp const site cache check: PASS'
else
  warn "bc2cpp const site cache check: #{failures.size} failure(s)"
  exit 1
end
