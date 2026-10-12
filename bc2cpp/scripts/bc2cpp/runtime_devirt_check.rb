#!/usr/bin/env ruby
# encoding: UTF-8
# Checks for three compiled-send fast paths found from executed-funcall counts on
# the desktop RPGMAKER_BC2CPP build (RPG2k map scene):
#
#   LONE_ACCESSOR_CHAIN / EMBEDDED_ACCESSOR_CHAIN  a name whose only definition is
#       an attr_reader (`code`/`indent` on LCF::EventCommand) is an exact-class
#       guarded chain with the funcall fallback; an embedded ivar's accessor calls
#       the synthesized struct reader, never mrb_iv_get (which would read nil).
#   INDEX_CHAIN      the untyped `x[i]` tail goes through the same chain.
#   INTEGER_LSHIFT   `a << b` on two immediate Integers uses mrb_num_shift and
#       agrees with Integer#<< (compared on a real mruby core); overflow and
#       MRB_INT_MIN keep the ordinary dispatch.
#   INTEGER_UNARY    `-a`, `a.zero?`, `a.round` on an Integer are computed inline
#       and agree with the Numeric/Integer bodies they replace; a Ruby definition
#       reachable from Integer (reopen or unresolved mixin) keeps the dispatch.

require 'tmpdir'
require_relative '../../tools/bc2cpp/bc2cpp'
require_relative 'cxx'

# The generated symbol for `Vars#[]`, derived through the real CodeGen#cpp_name
# rather than spelled out. `[]` mangles to `_$5b$5d`, and writing that by hand
# inside a regex literal does not work: `$5b` interpolates.
CPP_NAME = CodeGen.instance_method(:cpp_name).bind(CodeGen.allocate)
VARS_INDEX_IMPL = "#{CPP_NAME.call('Vars', '[]')}_impl"

root = File.expand_path('../..', __dir__)
failures = []
check = lambda do |what, condition|
  puts "  #{condition ? 'ok  ' : 'FAIL'} #{what}"
  failures << what unless condition
end

def fixture(source, name, natives: [])
  Dir.mktmpdir do |dir|
    path = File.join(dir, "#{name}.rb")
    File.write(path, source)
    ireps, root_label = compile_ireps(path, "bc2cpp_#{name}", dir)
    order = dfs_order(ireps, root_label)
    registry, _superclass_of, _containers, included, prepended, unknown_mixins = build_registry(ireps, root_label)
    natives.each do |op|
      registry[op] = [MethodDef.new(name: op, owner: '<native>', irep: nil, visibility: :public)] + Array(registry[op])
    end
    gen = CodeGen.new(ireps, registry, {}, {}, {}, {}, {}, {}, {}, {}, {}, Set.new, nil, nil, nil,
                      included, prepended, unknown_mixins)
    yield gen, registry
  end
end

ACCESSOR = <<~'RUBY'
  class Command
    attr_reader :code
    attr_accessor :label
  end
  class Reader
    def read(cmd); cmd.code; end
    def write(cmd, v); cmd.label = v; end
  end
RUBY

fixture(ACCESSOR, 'lone_accessor') do |gen, registry|
  method = registry.fetch('read').find { |d| d.owner == 'Reader' }
  code = gen.compile_method(method.irep).fetch(:code)
  check.call('a lone attr_reader is an exact-class chain, not a bare funcall',
             code.include?('POLY_SMALL_N :code -> Command') &&
               code.match?(/if \(bc2cpp_owner_class_\d+\(M\) == mrb_obj_class\(M, r\d+\)\) \{\n\s+r\d+ = mrb_iv_get\(M, r\d+, mrb_intern_cstr\(M, "@code"\)\);/))
  check.call('any other receiver class still reaches the funcall fallback', code.match?(/\} else \{\n\s+r\d+ = (?:mrb_funcall|bc2cpp_funcall_explicit)\(M, r\d+, "code", 0\);/))

  # An embedded ivar's accessor is the synthesized struct reader.
  gen.instance_variable_get(:@ivar_layout)['Command'] = { 'code' => :fixnum, 'label' => :fixnum }
  gen.instance_variable_get(:@synthesize_accessor_for) << ['Command', 'code', :reader]
  embedded = gen.compile_method(method.irep).fetch(:code)
  check.call('an embedded accessor calls the synthesized struct reader',
             embedded.include?('r') && embedded.match?(/r\d+ = Command_code_impl\(M, r\d+\);/) && !embedded.include?('"@code"'))
  wmethod = registry.fetch('write').find { |d| d.owner == 'Reader' }
  gen.instance_variable_get(:@synthesize_accessor_for) << ['Command', 'label', :writer]
  wcode = gen.compile_method(wmethod.irep).fetch(:code)
  check.call('an embedded writer calls the synthesized struct writer', wcode.match?(/r\d+ = Command_label_eq_impl\(M, r\d+, r\d+\);/))
end

INDEX = <<~'RUBY'
  class Vars
    def [](id); id; end
  end
  class Use
    def get(x, i); x[i]; end
  end
RUBY

fixture(INDEX, 'index_chain', natives: ['[]']) do |gen, registry|
  method = registry.fetch('get').find { |d| d.owner == 'Use' }
  code = gen.compile_method(method.irep).fetch(:code)
  # OUTLINED_INDEX_OPS (docs/adr/0216): the site calls bc2cpp_getidx, which holds the chain.
  helper = gen.emit_index_helpers([code])
  check.call('an untyped x[i] tail dispatches through the exact-class chain',
             code.match?(/r\d+ = bc2cpp_getidx\(M, r\d+, r\d+\);/) &&
               helper.include?('POLY_SMALL_N :[] -> Vars') && helper.include?("#{VARS_INDEX_IMPL}(M, recv, key)"))
  check.call('the exact Array/Hash/String arms are kept in front of it',
             helper.index('bc2cpp_ary_entry') < helper.index('mrb_hash_get(M,') &&
               helper.index('mrb_str_aref(M,') < helper.index('POLY_SMALL_N :[]'))
end

SHIFT = <<~'RUBY'
  class Bits
    def shl(a, b); a << b; end
  end
RUBY

shift_code = nil
shift_helpers = nil
fixture(SHIFT, 'lshift', natives: ['<<']) do |gen, registry|
  method = registry.fetch('shl').find { |d| d.owner == 'Bits' }
  shift_code = gen.compile_method(method.irep).fetch(:code)
  shift_helpers = gen.emit_numeric_slow_helpers([shift_code])
end
# NUMERIC_SLOW_PATH (docs/adr/0292): overflow and every non-immediate case leave the arm for bc2cpp_slow_lshift,
# which holds the by-name call.
check.call('Integer << emits the mrb_num_shift arm with the helper call for overflow',
           shift_code.include?('INTEGER_LSHIFT :<<') && shift_code.include?('mrb_num_shift(M, bc2cpp_shl_v, bc2cpp_shl_w, &bc2cpp_shl_out)') &&
             shift_code.scan('bc2cpp_slow_lshift(M, r').size >= 2 && !shift_code.include?('mrb_funcall(M, r') &&
             shift_code.include?('mrb_integer(r') && shift_code.include?('!= MRB_INT_MIN') &&
             shift_helpers.include?('mrb_funcall(M, a, "<<", 1, b)'))

candidates = [ENV['BC2CPP_MRUBY_CORE']].compact + Dir[File.join(root, 'build*/mruby/host/mrbc')]
core = candidates.find { |dir| File.exist?(File.join(dir, 'lib/libmruby_core.a')) && File.directory?(File.join(dir, 'include')) }
if core.nil? || !system('g++', '--version', out: File::NULL, err: File::NULL)
  puts '  SKIP behavioural comparison: no libmruby_core.a with include/ found (set BC2CPP_MRUBY_CORE)'
else
  snippet = shift_code[%r{// ARRAY_PUSH :<<.*?(?=\n  return r)}m] || shift_code[%r{// INTEGER_LSHIFT.*?(?=\n  return r)}m]
  recv, arg = snippet.scan(/mrb_integer_p\((r\d+)\)/).flatten.first(2)
  dest = recv.delete('r')
  Dir.mktmpdir do |dir|
    source = File.join(dir, 'shl.cpp')
    File.write(source, <<~CPP)
      #include <mruby.h>
      #include <mruby/error.h>
      #include <mruby/array.h>
      #include <cstdio>
      #include <cstdarg>
      extern "C" void mrb_init_mrblib(mrb_state*) {}
      extern "C" mrb_bool mrb_num_shift(mrb_state*, mrb_int, mrb_int, mrb_int*);
      static int fallbacks = 0;
      // Count every trip to the ordinary dispatch the emitted snippet makes.
      #define mrb_funcall(M, s, name, argc, ...) (++fallbacks, (mrb_funcall)(M, s, name, argc, __VA_ARGS__))
      #{shift_helpers}
      static mrb_value emitted(mrb_state* M, mrb_value in_recv, mrb_value in_arg) {
        mrb_value #{recv} = in_recv, #{arg} = in_arg;
        #{recv == "r#{dest}" ? '' : "mrb_value r#{dest} = mrb_nil_value();"}
        #{snippet}
        return r#{dest};
      }
      struct Args { mrb_value a, b; };
      static mrb_value body(mrb_state* M, void* ud) { Args* x = (Args*)ud; return emitted(M, x->a, x->b); }
      static mrb_value ref_body(mrb_state* M, void* ud) { Args* x = (Args*)ud; return (mrb_funcall)(M, x->a, "<<", 1, x->b); }
      int main() {
        mrb_state* M = mrb_open_core();
        mrb_int vals[] = { 0, 1, -1, 2, 5, -5, 1 << 20, -(1 << 20), MRB_INT_MAX, MRB_INT_MIN, MRB_INT_MAX / 2, MRB_INT_MIN / 2 };
        mrb_int shifts[] = { 0, 1, 2, 3, 15, 30, 31, 32, 62, 63, 64, 100, -1, -2, -31, -32, -63, -64, -100, MRB_INT_MAX, MRB_INT_MIN };
        int bad = 0, n = 0, fast = 0, fell = 0;
        for (mrb_int v : vals) for (mrb_int w : shifts) {
          Args args = { mrb_int_value(M, v), mrb_int_value(M, w) };
          mrb_bool e1 = FALSE, e2 = FALSE;
          fallbacks = 0;
          mrb_value got = mrb_protect_error(M, body, &args, &e1);
          int took_fallback = fallbacks;
          mrb_value want = mrb_protect_error(M, ref_body, &args, &e2);
          ++n; took_fallback ? ++fell : ++fast;
          bool same = e1 == e2 && (e1 || (mrb_integer_p(got) == mrb_integer_p(want) && (!mrb_integer_p(got) || mrb_integer(got) == mrb_integer(want))));
          if (!same) { ++bad; std::printf("MISMATCH %ld << %ld\\n", (long)v, (long)w); }
        }
        std::printf("compared %d shifts: %d fast, %d fallback, %d differ\\n", n, fast, fell, bad);
        mrb_close(M);
        return (bad || fast == 0 || fell == 0) ? 1 : 0;
      }
    CPP
    binary = File.join(dir, 'shl')
    built = Bc2cppCxx.system('-std=c++17', '-fexceptions', '-DMRB_USE_CXX_EXCEPTION', '-DMRB_NO_GEMS',
                   "-I#{core}/include", "-I#{root}/3rd/mruby/include", source, "#{core}/lib/libmruby_core.a", '-o', binary)
    check.call('the emitted shift compiles against real mruby headers', built)
    if built
      output = IO.popen(binary, err: %i[child out], &:read)
      puts output.lines.map { |l| "  #{l}" }.join
      check.call('the emitted shift agrees with Integer#<< on every value/count pair, on both the fast and fallback paths',
                 $?.success? && output.include?(' 0 differ'))
    end
  end
end

UNARY = <<~'RUBY'
  class Num
    def neg(a); -a; end
    def zero(a); a.zero?; end
    def rnd(a); a.round; end
  end
RUBY
UNARY_METHODS = { 'neg' => '-@', 'zero' => 'zero?', 'rnd' => 'round' }.freeze

unary_code = {}
unary_helpers = nil
UNARY_HELPER = { '-@' => 'neg', 'zero?' => 'zero', 'round' => 'round' }.freeze
fixture(UNARY, 'int_unary', natives: UNARY_METHODS.values) do |gen, registry|
  UNARY_METHODS.each do |meth, op|
    unary_code[op] = gen.compile_method(registry.fetch(meth).find { |d| d.owner == 'Num' }.irep).fetch(:code)
  end
  unary_helpers = gen.emit_numeric_slow_helpers(unary_code.values)
end
UNARY_METHODS.each_value do |op|
  code = unary_code.fetch(op)
  check.call("Integer #{op} is computed inline with the NUMERIC_SLOW_PATH helper (which holds the funcall) for other receivers",
             code.include?("INTEGER_UNARY :#{op}") && code.match?(/if \(mrb_integer_p\(r\d+\)/) &&
               code.match?(/bc2cpp_slow_#{UNARY_HELPER.fetch(op)}(?:_f)?\(M, r\d+\)/) && !code.include?('mrb_funcall(M') &&
               unary_helpers.match?(/mrb_funcall\(M, a, "#{Regexp.escape(op)}", 0\)/))
end
check.call('-MRB_INT_MIN (a bigint) keeps the dispatch', unary_code.fetch('-@').include?('!= MRB_INT_MIN'))

# A Ruby definition Integer can reach, or an unresolved mixin, keeps the dispatch.
[['a reopened Integer#zero?', "class Integer; def zero?; false; end; end\n", 'zero'],
 ['an unresolved include into Integer', "MODS = [Comparable]\nclass Integer; include(*MODS); end\n", 'rnd']].each do |what, prefix, meth|
  fixture(prefix + UNARY, 'int_unary_blocked', natives: UNARY_METHODS.values) do |gen, registry|
    code = gen.compile_method(registry.fetch(meth).find { |d| d.owner == 'Num' }.irep).fetch(:code)
    check.call("#{what} keeps #{UNARY_METHODS[meth]} on the dispatch", !code.include?('INTEGER_UNARY'))
  end
end

unless core.nil? || !system('g++', '--version', out: File::NULL, err: File::NULL)
  snippets = UNARY_METHODS.values.map do |op|
    body = unary_code.fetch(op)[%r{// INTEGER_UNARY :#{Regexp.escape(op)}.*?\n\}\n}m]
    recv = body[/mrb_integer_p\((r\d+)\)/, 1]
    dest = body[/^\s*(r\d+) = /, 1]
    [op, recv, dest, body]
  end
  Dir.mktmpdir do |dir|
    source = File.join(dir, 'unary.cpp')
    functions = snippets.map.with_index do |(_op, recv, dest, body), i|
      <<~CPP
        static mrb_value emitted_#{i}(mrb_state* M, mrb_value in_recv) {
          mrb_value #{recv} = in_recv;
          #{recv == dest ? '' : "mrb_value #{dest} = mrb_nil_value();"}
          #{body}
          return #{dest};
        }
      CPP
    end
    File.write(source, <<~CPP)
      #include <mruby.h>
      #include <mruby/error.h>
      #include <cstdio>
      #include <cstring>
      extern "C" void mrb_init_mrblib(mrb_state*) {}
      static int fallbacks = 0;
      // The core build has no mrblib, so the reference is each replaced body
      // spelled with its core C operations: Numeric#-@ is `0 - self`,
      // Numeric#zero? is `self == 0`, Integer#round is int_round.
      static mrb_value reference(mrb_state* M, mrb_value self, const char* name) {
        if (!std::strcmp(name, "-@")) return (mrb_funcall)(M, mrb_fixnum_value(0), "-", 1, self);
        if (!std::strcmp(name, "zero?")) return (mrb_funcall)(M, self, "==", 1, mrb_fixnum_value(0));
        return (mrb_funcall)(M, self, "round", 0);
      }
      #define mrb_funcall(M, s, name, argc) (++fallbacks, reference(M, s, name))
      #{unary_helpers}
      #{functions.join}
      static mrb_value (*const emitted[])(mrb_state*, mrb_value) = { #{snippets.each_index.map { |i| "emitted_#{i}" }.join(', ')} };
      static const char* const names[] = { #{snippets.map { |op, *| "\"#{op}\"" }.join(', ')} };
      struct Args { int op; mrb_value v; };
      static mrb_value body(mrb_state* M, void* ud) { Args* a = (Args*)ud; return emitted[a->op](M, a->v); }
      static mrb_value ref_body(mrb_state* M, void* ud) { Args* a = (Args*)ud; return reference(M, a->v, names[a->op]); }
      int main() {
        mrb_state* M = mrb_open_core();
        mrb_value vals[] = { mrb_fixnum_value(0), mrb_fixnum_value(1), mrb_fixnum_value(-1), mrb_fixnum_value(42),
                             mrb_int_value(M, MRB_INT_MAX), mrb_int_value(M, MRB_INT_MIN), mrb_int_value(M, MRB_INT_MIN + 1),
                             mrb_float_value(M, 0.0), mrb_float_value(M, -2.5), mrb_float_value(M, 2.5) };
        int bad = 0, n = 0, fast = 0, fell = 0;
        for (int op = 0; op < #{snippets.size}; ++op) for (mrb_value v : vals) {
          Args args = { op, v };
          mrb_bool e1 = FALSE, e2 = FALSE;
          fallbacks = 0;
          mrb_value got = mrb_protect_error(M, body, &args, &e1);
          int took_fallback = fallbacks;
          mrb_value want = mrb_protect_error(M, ref_body, &args, &e2);
          ++n; took_fallback ? ++fell : ++fast;
          bool same = e1 == e2 && (e1 || (mrb_type(got) == mrb_type(want) &&
                      (mrb_integer_p(got) ? mrb_integer(got) == mrb_integer(want) :
                       mrb_float_p(got) ? mrb_float(got) == mrb_float(want) : mrb_test(got) == mrb_test(want))));
          if (!same) { ++bad; std::printf("MISMATCH %s case %d\\n", names[op], n); }
        }
        std::printf("compared %d unary sends: %d fast, %d fallback, %d differ\\n", n, fast, fell, bad);
        mrb_close(M);
        return (bad || fast == 0 || fell == 0) ? 1 : 0;
      }
    CPP
    binary = File.join(dir, 'unary')
    built = Bc2cppCxx.system('-std=c++17', '-fexceptions', '-DMRB_USE_CXX_EXCEPTION', '-DMRB_NO_GEMS',
                   "-I#{core}/include", "-I#{root}/3rd/mruby/include", source, "#{core}/lib/libmruby_core.a", '-o', binary)
    check.call('the emitted unary sends compile against real mruby headers', built)
    if built
      output = IO.popen(binary, err: %i[child out], &:read)
      puts output.lines.map { |l| "  #{l}" }.join
      check.call('the emitted unary sends agree with the replaced bodies, on both the fast and fallback paths',
                 $?.success? && output.include?(' 0 differ'))
    end
  end
end

if failures.empty?
  puts 'bc2cpp runtime devirt check: PASS'
else
  warn "bc2cpp runtime devirt check: #{failures.size} failure(s)"
  exit 1
end
