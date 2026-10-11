#!/usr/bin/env ruby
# encoding: UTF-8
# Check EQQ_INTEGER_FAST: an Integer receiver of `===` (every `when CONST` arm of
# a command switch) is compared natively against an Integer argument instead of
# through mrb_equal, which runs a full `funcall("==")` for each non-matching arm.
# The fast path is only emitted when no Ruby-defined Integer#== exists in the
# closed world, and the emitted switch must agree with mrb_equal (compared here
# against a real mruby core library) on every Integer/Float/Integer-vs-other pair.

require 'tmpdir'
require_relative '../../tools/bc2cpp/bc2cpp'
require_relative 'cxx'

root = File.expand_path('../..', __dir__)
failures = []
check = lambda do |what, condition|
  puts "  #{condition ? 'ok  ' : 'FAIL'} #{what}"
  failures << what unless condition
end

def build(source, name)
  Dir.mktmpdir do |dir|
    path = File.join(dir, "#{name}.rb")
    File.write(path, source)
    ireps, root_label = compile_ireps(path, "bc2cpp_#{name}", dir)
    order = dfs_order(ireps, root_label)
    registry = build_registry(ireps, root_label)[0]
    # The real build learns these from mruby's own C registrations; a fixture has
    # to declare that Object#=== / Integer#== exist natively.
    %w[=== ==].each do |op|
      registry[op] = [MethodDef.new(name: op, owner: '<native>', irep: nil, visibility: :public)] + Array(registry[op])
    end
    gen = CodeGen.new(ireps, registry, {}, {}, {}, {}, {}, {}, {}, {}, {}, Set.new)
    method = registry.fetch('route').find { |d| d.owner == 'Router' }
    code = gen.compile_method(method.irep).fetch(:code)
    yield code, gen.emit_eqq_helper([code])
  end
end

SRC = <<~'RUBY'
  class Router
    A = 10
    B = 20
    def route(code)
      case code
      when A then :a
      when B then :b
      else :none
      end
    end
  end
RUBY

# The tag switch is the shared bc2cpp_eqq helper (ADR 0293); a site is one call to it.
fast = nil
site = nil
build(SRC, 'eqq_default') { |code, helper| site = code; fast = helper }
check.call('a generic `when` site is one call of the shared helper', site.scan(/= bc2cpp_eqq\(M, r\d+, r\d+\);/).size == 2)
check.call('the default build emits the Integer-vs-Integer fast path',
           fast.match?(/case MRB_TT_INTEGER:\n\s+if \(mrb_integer_p\(arg\)\) return mrb_bool_value\(mrb_integer\(recv\) == mrb_integer\(arg\)\);/))
check.call('a non-Integer argument still goes through mrb_equal', fast.match?(/case MRB_TT_INTEGER:.*?mrb_equal\(M, recv, arg\)/m))
check.call('the other receiver types keep their mrb_equal arm', fast.match?(/case MRB_TT_FLOAT:\n\s+case MRB_TT_STRING:/))

overridden = nil
build(SRC + "\nclass Integer\n  def ==(other)\n    true\n  end\nend\n", 'eqq_override') { |_code, helper| overridden = helper }
check.call('a Ruby-defined Integer#== disables the fast path', !overridden.include?('mrb_integer(recv) == mrb_integer(arg)'))

candidates = [ENV['BC2CPP_MRUBY_CORE']].compact + Dir[File.join(root, 'build*/mruby/host/mrbc')]
core = candidates.find { |dir| File.exist?(File.join(dir, 'lib/libmruby_core.a')) && File.directory?(File.join(dir, 'include')) }
if core.nil? || !system('g++', '--version', out: File::NULL, err: File::NULL)
  puts '  SKIP behavioural comparison: no libmruby_core.a with include/ found (set BC2CPP_MRUBY_CORE)'
else
  Dir.mktmpdir do |dir|
    source = File.join(dir, 'eqq.cpp')
    File.write(source, <<~CPP)
      #include <mruby.h>
      #include <mruby/class.h>
      #include <mruby/range.h>
      #include <mruby/numeric.h>
      #include <cstdio>
      #include <climits>
      extern "C" void mrb_init_mrblib(mrb_state*) {}
      #{fast}
      static mrb_value emitted(mrb_state* M, mrb_value in_recv, mrb_value in_arg) {
        return bc2cpp_eqq(M, in_recv, in_arg);
      }
      int main() {
        mrb_state* M = mrb_open_core();
        mrb_int ints[] = { 0, 1, -1, 5, 10, 1 << 30, -(1 << 30), MRB_INT_MAX, MRB_INT_MIN };
        mrb_float floats[] = { 0.0, 5.0, 5.5, -1.0 };
        int bad = 0, n = 0;
        for (mrb_int a : ints) {
          for (mrb_int b : ints) {
            mrb_bool want = mrb_equal(M, mrb_int_value(M, a), mrb_int_value(M, b));
            mrb_value got = emitted(M, mrb_int_value(M, a), mrb_int_value(M, b));
            ++n; if (mrb_test(got) != want) { ++bad; std::printf("int/int %ld %ld\\n", (long)a, (long)b); }
          }
          for (mrb_float f : floats) {
            mrb_bool want = mrb_equal(M, mrb_int_value(M, a), mrb_float_value(M, f));
            mrb_value got = emitted(M, mrb_int_value(M, a), mrb_float_value(M, f));
            ++n; if (mrb_test(got) != want) { ++bad; std::printf("int/float %ld %g\\n", (long)a, f); }
          }
          mrb_value other[] = { mrb_nil_value(), mrb_true_value(), mrb_symbol_value(mrb_intern_cstr(M, "x")) };
          for (mrb_value o : other) {
            mrb_bool want = mrb_equal(M, mrb_int_value(M, a), o);
            mrb_value got = emitted(M, mrb_int_value(M, a), o);
            ++n; if (mrb_test(got) != want) { ++bad; std::printf("int/other %ld\\n", (long)a); }
          }
        }
        std::printf("compared %d pairs, %d differ\\n", n, bad);
        mrb_close(M);
        return bad ? 1 : 0;
      }
    CPP
    binary = File.join(dir, 'eqq')
    built = Bc2cppCxx.system('-std=c++17', '-fexceptions', '-DMRB_USE_CXX_EXCEPTION', '-DMRB_NO_GEMS',
                   "-I#{core}/include", "-I#{root}/3rd/mruby/include", source, "#{core}/lib/libmruby_core.a", '-o', binary)
    check.call('the emitted switch compiles against real mruby headers', built)
    if built
      output = IO.popen(binary, err: %i[child out], &:read)
      puts output.lines.map { |l| "  #{l}" }.join
      check.call('the emitted switch agrees with mrb_equal on every Integer pair', $?.success? && output.include?(' 0 differ'))
    end
  end
end

if failures.empty?
  puts 'bc2cpp EQQ integer check: PASS'
else
  warn "bc2cpp EQQ integer check: #{failures.size} failure(s)"
  exit 1
end
