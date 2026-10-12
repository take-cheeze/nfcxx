#!/usr/bin/env ruby
# encoding: UTF-8
# Check SYMBOL_CACHE (tools/bc2cpp/symbol_cache.rb): generated C++ interns each
# distinct name once per VM instead of on every execution. Covers the rewrite
# (literal forms, funcall -> bc2cpp_send with arbitrary receivers, calls that must
# be left alone) and, by compiling and running the emitted cache against stub
# mruby functions, its behaviour across VMs.

require 'tmpdir'
require_relative '../../tools/bc2cpp/symbol_cache'
require_relative 'cxx'

failures = []
check = lambda do |what, condition|
  puts "  #{condition ? 'ok  ' : 'FAIL'} #{what}"
  failures << what unless condition
end

table = SymbolCache::Table.new
rw = ->(code) { SymbolCache.rewrite(code, table) }

out = rw.call('r1 = mrb_iv_get(M, self, mrb_intern_cstr(M, "@state"));')
check.call('mrb_intern_cstr of a literal becomes a table read', out == 'r1 = mrb_iv_get(M, self, bc2cpp_sym(M, 0));')
out = rw.call('mrb_exc_get_id(M, mrb_intern_lit(M, "TypeError"))')
check.call('mrb_intern_lit is rewritten too', out == 'mrb_exc_get_id(M, bc2cpp_sym(M, 1))')
out = rw.call('a(mrb_intern_cstr(M, "@state")); b(mrb_intern_cstr(M, "@state"));')
check.call('a repeated name shares one slot', out == 'a(bc2cpp_sym(M, 0)); b(bc2cpp_sym(M, 0));' && table.size == 2)

out = rw.call('r3 = mrb_funcall(M, r3, "new", 1, r4);')
check.call('mrb_funcall with a literal name becomes bc2cpp_send', out == 'r3 = bc2cpp_send(M, r3, 2, 1, r4);')
out = rw.call('mrb_funcall(M, r1, "empty?", 0)')
check.call('a zero-argument call keeps its argc', out == 'bc2cpp_send(M, r1, 3, 0)')
out = rw.call('mrb_funcall(M, f(a, "x,y", (b)), "run", 2, m, n)')
check.call('a receiver with commas, parentheses and a string is delimited correctly',
           out == "bc2cpp_send(M, f(a, \"x,y\", (b)), 4, 2, m, n)")
out = rw.call('mrb_funcall(M, mrb_funcall(M, r1, "a", 0), "b", 1, mrb_funcall(M, r2, "c", 0))')
check.call('nested funcalls are all rewritten',
           out == 'bc2cpp_send(M, bc2cpp_send(M, r1, 5, 0), 6, 1, bc2cpp_send(M, r2, 7, 0))')
out = rw.call('mrb_funcall(M, r1, name_var, 0)')
check.call('a name that is not a literal is left alone', out == 'mrb_funcall(M, r1, name_var, 0)')
out = rw.call('mrb_funcall(M, r1, "say \\"hi\\"", 0)')
check.call('a literal with an escaped quote is kept intact',
           out == 'bc2cpp_send(M, r1, 8, 0)' && table.literals[8] == '"say \\"hi\\""')
out = rw.call('x = mrb_funcall_argv(M, r1, id, 0, NULL); y = mrb_intern_cstr(other, "n");')
check.call('other calls and other state variables are untouched', out == 'x = mrb_funcall_argv(M, r1, id, 0, NULL); y = mrb_intern_cstr(other, "n");')
check.call('the rewritten text has no leftover literal interning',
           !rw.call('mrb_intern_cstr(M, "a") mrb_funcall(M, r, "b", 0)').match?(/mrb_intern_cstr\(M, "|mrb_funcall\(M/))

unicode_table = SymbolCache::Table.new
unicode_source = 'préface; mrb_funcall(M, mrb_funcall(M, r, "内", 0), "外", 0); fin'
unicode_output = SymbolCache.rewrite(unicode_source, unicode_table)
check.call('byte scanning preserves Unicode text, nested names and encoding',
           unicode_output == 'préface; bc2cpp_send(M, bc2cpp_send(M, r, 0, 0), 1, 0); fin' &&
           unicode_output.encoding == unicode_source.encoding && unicode_table.literals == ['"内"', '"外"'])
check.call('Unicode prefixes do not shift send indices', SymbolCache.send_indices(unicode_output) == [1, 0])
miss = 'mrb_funcall(M, r, dynamic_name, 0); f(r, "later", 0);'
check.call('a nonliteral name cannot match a later argument', SymbolCache.rewrite(miss, SymbolCache::Table.new) == miss)
check.call('a nonnumeric slot cannot match a later number',
           SymbolCache.send_indices('bc2cpp_send(M, r, dynamic_slot, 0); f(r, 7, 0);').empty?)
many = 'mrb_funcall(M, r, "tick", 0);' * 5_000
many_output = SymbolCache.rewrite(many, SymbolCache::Table.new)
check.call('a large flat scan preserves every call and slot',
           many_output == 'bc2cpp_send(M, r, 0, 0);' * 5_000 && SymbolCache.send_indices(many_output) == [0] * 5_000)

cache = SymbolCache.emit(table)
check.call('the cache declares its table, reset and accessor',
           cache.include?('static void bc2cpp_reset_symbol_cache()') && cache.include?('static inline mrb_sym bc2cpp_sym(mrb_state* M, int i)') &&
             cache.include?("static mrb_sym bc2cpp_syms[#{table.size}]"))

if system('g++', '--version', out: File::NULL, err: File::NULL)
  Dir.mktmpdir do |dir|
    source = File.join(dir, 'sym_harness.cpp')
    File.write(source, <<~CPP)
      #include <cstdio>
      #include <cstring>
      #include <string>
      #include <vector>
      #include <cstdarg>
      typedef unsigned mrb_sym;
      typedef long mrb_int;
      struct mrb_state { int id; };
      struct mrb_value { long v; };
      struct RClass {};
      static RClass arg_error;
      static int raised = 0;
      static RClass* mrb_exc_get_id(mrb_state*, mrb_sym) { return &arg_error; }
      #define mrb_intern_lit(M, s) 0u
      static void mrb_raise(mrb_state*, RClass*, const char*) { ++raised; }
      static mrb_sym sent_sym = 0;
      static mrb_int sent_argc = -1;
      static long sent_sum = 0;
      static mrb_value bc2cpp_funcall_argv(mrb_state*, mrb_value recv, mrb_sym mid, mrb_int argc, const mrb_value* argv) {
        sent_sym = mid; sent_argc = argc; sent_sum = recv.v;
        for (mrb_int k = 0; k < argc; k++) sent_sum += argv[k].v;
        return mrb_value{ 7 };
      }
      static std::vector<std::string> interned;
      static mrb_sym mrb_intern_cstr(mrb_state* M, const char* s) {
        interned.push_back(std::string(s));
        return (mrb_sym)(100 * (M->id + 1) + interned.size());
      }
      #{cache}
      int main() {
        mrb_state a = { 0 }, b = { 1 };
        mrb_sym first = bc2cpp_sym(&a, 0);
        bc2cpp_sym(&a, 0); bc2cpp_sym(&a, 0); bc2cpp_sym(&a, 1);
        size_t after_repeat = interned.size();
        mrb_sym other_vm = bc2cpp_sym(&b, 0);
        size_t after_switch = interned.size();
        bc2cpp_reset_symbol_cache();
        bc2cpp_sym(&b, 0);
        size_t after_reset = interned.size();
        mrb_value got = bc2cpp_send(&b, mrb_value{ 1 }, 0, 3, mrb_value{ 10 }, mrb_value{ 20 }, mrb_value{ 30 });
        bool sent = got.v == 7 && sent_sym == bc2cpp_sym(&b, 0) && sent_argc == 3 && sent_sum == 61 && raised == 0;
        bc2cpp_send(&b, mrb_value{ 1 }, 0, 17);
        std::printf("%d %d %d %d %d %d %d\\n", first != 0, after_repeat == 2, other_vm != first && after_switch == 3,
                    after_reset == 4, interned[0] == "@state", sent, raised == 1);
      }
    CPP
    binary = File.join(dir, 'sym_harness')
    built = Bc2cppCxx.system('-std=c++17', '-Wall', '-Werror', source, '-o', binary)
    check.call('the emitted cache compiles cleanly', built)
    if built
      r = IO.popen(binary, &:read).split.map { |v| v == '1' }
      check.call('a name is interned once per VM however often it is read', r[0] && r[1] && r[4])
      check.call('a second VM re-interns and never sees the first VM\'s ids', r[2])
      check.call('bc2cpp_reset_symbol_cache forces a fresh intern', r[3])
      check.call('bc2cpp_send forwards receiver, cached symbol and every argument to bc2cpp_funcall_argv', r[5])
      check.call('bc2cpp_send raises past 16 arguments, like mrb_funcall_id', r[6])
    end
  end
end

if failures.empty?
  puts 'bc2cpp symbol cache check: PASS'
else
  warn "bc2cpp symbol cache check: #{failures.size} failure(s)"
  exit 1
end
