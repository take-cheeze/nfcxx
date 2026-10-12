#!/usr/bin/env ruby
# encoding: UTF-8
# Check OWNER_CLASS_CACHE: exact-class guards compare against a cached
# per-owner RClass* instead of re-running the chained mrb_const_get on every
# call. Covers the emitted call sites and, by compiling and running the
# emitted cache against stub mruby functions, the cache's behaviour: one
# lookup per VM, a re-lookup when the state changes or is reset, and a
# class that is not defined yielding nullptr (a false guard, not a NameError)
# without caching it.

require 'tmpdir'
require_relative '../../tools/bc2cpp/bc2cpp'
require_relative 'cxx'

SRC = <<~'RUBY'
  module Game
    class Left
      attr_accessor :label
    end
    class Right
      attr_accessor :label
    end
    class Reader
      def read(target); target.label; end
    end
  end
RUBY

failures = []
check = lambda do |what, condition|
  puts "  #{condition ? 'ok  ' : 'FAIL'} #{what}"
  failures << what unless condition
end

Dir.mktmpdir do |dir|
  source = File.join(dir, 'owner_class_cache.rb')
  File.write(source, SRC)
  ireps, root_label = compile_ireps(source, 'bc2cpp_owner_class_cache', dir)
  order = dfs_order(ireps, root_label)
  registry = build_registry(ireps, root_label)[0]
  gen = CodeGen.new(ireps, registry, {}, {}, {}, {}, {}, {}, {}, {}, {}, Set.new)

  method = registry.fetch('read').find { |md| md.owner == 'Game::Reader' }
  irep = ireps.fetch(method.irep)
  idx = irep.instructions.index { |insn| insn.op == 'SEND0' }
  body = gen.compile_insn(irep.instructions[idx], irep, method, idx)
  cache = gen.emit_owner_class_cache

  check.call('guards call the per-owner cache helper',
             body.scan(/bc2cpp_owner_class_(\d+)\(M\) == mrb_obj_class\(M, r/).flatten.uniq.size == 2)
  check.call('no guard re-runs the chained constant lookup', !body.include?('mrb_const_get'))
  check.call('the helper resolves the owner path segment by segment',
             cache.include?('{"Game", "Left"}') && cache.include?('bc2cpp_owner_class_lookup(M, path, 2)'))
  check.call('an undefined segment is checked before mrb_const_get can raise',
             cache.include?('if (!mrb_const_defined(M, v, s)) return nullptr;'))
  check.call('the cache is reset when the state changes and by bc2cpp_reset_owner_classes',
             cache.include?('bc2cpp_owner_class_state != M') && cache.include?('static void bc2cpp_reset_owner_classes()'))
  check.call('one owner used twice shares one slot',
             gen.owner_class_ptr_expr('Game::Left') == gen.owner_class_ptr_expr('Game::Left'))

  if system('g++', '--version', out: File::NULL, err: File::NULL)
    harness = File.join(dir, 'cache_harness.cpp')
    File.write(harness, <<~CPP)
      #include <cstdio>
      #include <cstring>
      struct RClass { int id; };
      struct mrb_state { RClass* object_class; };
      struct mrb_value { void* p; };
      typedef unsigned mrb_sym;
      static int g_lookups = 0;
      static bool g_undefined = false;
      typedef bool mrb_bool;
      static RClass g_classes[8];
      static mrb_value mrb_obj_value(RClass* c) { return { c }; }
      static mrb_sym mrb_intern_cstr(mrb_state*, const char*) { return 0; }
      static mrb_bool mrb_const_defined(mrb_state*, mrb_value, mrb_sym) {
        ++g_lookups;
        return !g_undefined;
      }
      static mrb_value mrb_const_get(mrb_state*, mrb_value, mrb_sym) {
        if (g_undefined) throw 1;
        return { &g_classes[1] };
      }
      static RClass* mrb_class_ptr(mrb_value v) { return (RClass*)v.p; }
      #{cache}
      int main() {
        RClass object_class = {};
        mrb_state a = { &object_class }, b = { &object_class };
        auto* first = bc2cpp_owner_class_0(&a);
        int after_first = g_lookups;
        bc2cpp_owner_class_0(&a);
        bc2cpp_owner_class_0(&a);
        int after_repeat = g_lookups;
        bc2cpp_owner_class_0(&b);
        int after_switch = g_lookups;
        bc2cpp_reset_owner_classes();
        bc2cpp_owner_class_0(&b);
        int after_reset = g_lookups;
        g_undefined = true;
        bc2cpp_reset_owner_classes();
        bool missing = false;
        try { missing = bc2cpp_owner_class_0(&b) == nullptr; } catch (int) { missing = false; }
        g_undefined = false;
        int before_retry = g_lookups;
        bc2cpp_owner_class_0(&b);
        std::printf("%d %d %d %d %d %d %d\\n", first == &g_classes[1], after_repeat == after_first,
                    after_switch > after_repeat, after_reset > after_switch, missing, g_lookups > before_retry, after_first > 0);
      }
    CPP
    binary = File.join(dir, 'cache_harness')
    built = Bc2cppCxx.system('-std=c++17', '-Wall', '-Werror', harness, '-o', binary)
    check.call('the emitted cache compiles cleanly', built)
    if built
      results = IO.popen(binary, &:read).split.map { |value| value == '1' }
      check.call('a repeated lookup on one state is cached', results[1])
      check.call('a state switch and a reset each force a fresh lookup', results[2] && results[3])
      check.call('an undefined class yields nullptr without raising and is not cached', results[4] && results[5])
      check.call('the cached pointer is the resolved class', results[0] && results[6])
    end
  end
end

if failures.empty?
  puts 'bc2cpp owner class cache check: PASS'
else
  warn "bc2cpp owner class cache check: #{failures.size} failure(s)"
  exit 1
end
