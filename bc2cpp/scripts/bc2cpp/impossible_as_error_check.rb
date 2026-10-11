#!/usr/bin/env ruby
# encoding: UTF-8
# frozen_string_literal: true

# Check ADR 0262 (generated side): code the compiler proves unreachable raises
# instead of carrying on.
#
#   - a function whose every path RETURNs ends in a "fell off the end" raise,
#     not `return mrb_nil_value()`;
#   - the closed-world nomethod helper raises a distinct RuntimeError naming the
#     class and method when its proof turns out false, and still raises the
#     ordinary NoMethodError when the proof holds (run against a real mruby core).
#
#   MRBC=path/to/host/mrbc [BC2CPP_MRUBY_CORE=dir] ruby scripts/bc2cpp/impossible_as_error_check.rb

require 'tmpdir'
require_relative '../../tools/bc2cpp/bc2cpp'
require_relative 'cxx'

root = File.expand_path('../..', __dir__)
failures = []
check = lambda do |what, condition|
  puts "  #{condition ? 'ok  ' : 'FAIL'} #{what}"
  failures << what unless condition
end

def compile_route(source, name)
  Dir.mktmpdir do |dir|
    path = File.join(dir, "#{name}.rb")
    File.write(path, source)
    ireps, root_label = compile_ireps(path, "bc2cpp_#{name}", dir)
    registry = build_registry(ireps, root_label)[0]
    gen = CodeGen.new(ireps, registry, {}, {}, {}, {}, {}, {}, {}, {}, {}, Set.new)
    method = registry.fetch('route').find { |d| d.owner == 'Router' }
    yield gen.compile_method(method.irep).fetch(:code)
  end
end

puts '== fall-off tails'
compile_route("class Router\n  def route(x)\n    x ? 1 : 2\n  end\nend\n", 'tail_plain') do |code|
  check.call('a method tail raises RuntimeError naming the method',
             code.include?('bc2cpp: Router#route fell off the end of its body'))
  check.call('no silent nil return follows the last RETURN',
             !code.include?('unreachable if every path RETURNs') && !code.match?(%r{return mrb_nil_value\(\); // unreachable}))
end
compile_route(<<~'RUBY', 'tail_rescue') do |code|
  class Router
    def route(x)
      begin
        x.foo
      rescue StandardError
        2
      end
    end
  end
RUBY
  tails = code.scan(/fell off the end of its body/).size
  check.call('a recognized rescue region gets the same tail as its method', tails >= 2 && code.include?('_rescue_try'))
  check.call('the rescue try body no longer ends in `return nil // unreachable`', !code.include?('// unreachable'))
end

puts '== nomethod proof violation'
table = SymbolCache::Table.new
table.index_for('"missing"')
table.index_for('"bar"')
table.nomethod_used = true
cache = SymbolCache.emit(table)
check.call('a violated proof raises a distinct RuntimeError, not a look-alike NoMethodError',
           cache.include?('closed-world proof violated') && !cache.include?('mrb_method_missing('))

candidates = [ENV['BC2CPP_MRUBY_CORE']].compact + Dir[File.join(root, 'build*/mruby/host/mrbc')]
core = candidates.find { |dir| File.exist?(File.join(dir, 'lib/libmruby_core.a')) && File.directory?(File.join(dir, 'include')) }
if core.nil? || !system('g++', '--version', out: File::NULL, err: File::NULL)
  puts '  SKIP behavioural check: no libmruby_core.a with include/ found (set BC2CPP_MRUBY_CORE)'
else
  Dir.mktmpdir do |dir|
    source = File.join(dir, 'nomethod_probe.cpp')
    File.write(source, <<~CPP)
      #include <mruby.h>
      #include <mruby/class.h>
      #include <mruby/error.h>
      #include <mruby/string.h>
      #include <cstdarg>
      #include <cstdio>
      #include <cstring>
      #include <string>

      static mrb_value bc2cpp_funcall_argv(mrb_state* M, mrb_value r, mrb_sym m, mrb_int n, const mrb_value* a) { return mrb_funcall_argv(M, r, m, n, a); }

      #{cache}

      extern "C" void mrb_init_mrblib(mrb_state*) {}

      static mrb_value bar(mrb_state*, mrb_value) { return mrb_fixnum_value(1); }

      struct Call { mrb_value recv; int sym; };
      static mrb_value run(mrb_state* M, void* p) {
        Call* c = static_cast<Call*>(p);
        return bc2cpp_nomethod(M, c->recv, c->sym);
      }

      static int failures = 0;
      static void expect(mrb_state* M, const char* label, mrb_value recv, int sym, const char* klass, const char* fragment) {
        Call c{recv, sym};
        mrb_bool raised = FALSE;
        mrb_value exc = mrb_protect_error(M, run, &c, &raised);
        std::string got_class = raised ? mrb_class_name(M, mrb_obj_class(M, exc)) : "(no error)";
        mrb_value message = raised ? mrb_funcall(M, exc, "message", 0) : mrb_nil_value();
        std::string text = mrb_string_p(message) ? std::string(RSTRING_PTR(message), RSTRING_LEN(message)) : "";
        bool ok = raised && got_class == klass && text.find(fragment) != std::string::npos;
        std::printf("%s %s (%s: %s)\\n", ok ? "ok  " : "FAIL", label, got_class.c_str(), text.c_str());
        if (!ok) ++failures;
      }

      int main() {
        mrb_state* M = mrb_open_core();
        // The core alone has no NoMethodError (mrblib/error.rb defines it).
        if (!mrb_class_defined(M, "NameError")) mrb_define_class(M, "NameError", M->eStandardError_class);
        if (!mrb_class_defined(M, "NoMethodError")) mrb_define_class(M, "NoMethodError", mrb_class_get(M, "NameError"));
        struct RClass* foo = mrb_define_class(M, "Foo", M->object_class);
        mrb_define_method(M, foo, "bar", bar, MRB_ARGS_NONE());
        mrb_value obj = mrb_obj_new(M, foo, 0, nullptr);
        expect(M, "a proven-absent method raises the ordinary NoMethodError", obj, 0, "NoMethodError", "missing");
        expect(M, "a method the proof said was absent raises a RuntimeError naming class and method", obj, 1,
               "RuntimeError", "closed-world proof violated: Foo#bar");
        mrb_close(M);
        return failures ? 1 : 0;
      }
    CPP
    binary = File.join(dir, 'nomethod_probe')
    built = Bc2cppCxx.system('-std=gnu++17', '-fexceptions', '-DMRB_USE_CXX_EXCEPTION', '-DMRB_NO_GEMS',
                   "-I#{core}/include", "-I#{root}/3rd/mruby/include", source, "#{core}/lib/libmruby_core.a", '-o', binary)
    check.call('the emitted nomethod helper compiles against real mruby headers', built)
    if built
      output = IO.popen(binary, err: %i[child out], &:read)
      puts output.lines.map { |l| "  #{l}" }.join
      check.call('both errors are raised as specified', $?.success? && !output.include?('FAIL'))
    end
  end
end

if failures.empty?
  puts 'bc2cpp impossible-as-error check: PASS'
else
  warn "bc2cpp impossible-as-error check: #{failures.size} failure(s)"
  exit 1
end
