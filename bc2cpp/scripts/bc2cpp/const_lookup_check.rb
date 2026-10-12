#!/usr/bin/env ruby
# encoding: UTF-8
# Check bc2cpp_const_try, the per-scope constant probe every GETCONST inside a
# namespaced owner walks: it must answer a miss without raising (the old
# mrb_protect_error + NameError probe allocated an exception, message and
# backtrace per miss, ~70k allocations/s in the RPG2k map scene) and must agree
# with that old probe on every scope shape -- own constant, inherited, from an
# included module, prepended, only on Object (a miss: const_get_nohook stops
# before Object), missing.
#
# The comparison runs against a real mruby core library. It needs one built
# with MRB_USE_CXX_EXCEPTION (what every host build here uses); point
# BC2CPP_MRUBY_CORE at its build dir (containing lib/libmruby_core.a and
# include/) or run after a build that leaves one under build*/mruby/host/mrbc.

require 'tmpdir'
require_relative '../../tools/bc2cpp/bc2cpp'
require_relative 'cxx'

root = File.expand_path('../..', __dir__)
failures = []
check = lambda do |what, condition|
  puts "  #{condition ? 'ok  ' : 'FAIL'} #{what}"
  failures << what unless condition
end

gen = CodeGen.new({}, {}, {}, {}, {}, {}, {}, {}, {}, {}, {}, Set.new)
gen.instance_variable_set(:@const_lookup_helper_used, true)
gen.const_lookup_block('1', 'DEEP', %w[Outer Inner])
repeated = gen.const_lookup_block('2', 'IN_MODULE', %w[Outer Inner])
check.call('one owner helper serves different constants and registers',
           repeated.include?('bc2cpp_const_scope_0') && gen.emit_const_scope_helpers.scan('static mrb_value').size == 1)
helper = gen.emit_const_lookup_helper + gen.emit_const_scope_helpers
check.call('the probe no longer raises through mrb_protect_error for a class scope',
           helper.include?('mrb_const_defined_at') && helper.include?('MRB_FL_CLASS_IS_PREPENDED'))

candidates = [ENV['BC2CPP_MRUBY_CORE']].compact + Dir[File.join(root, 'build*/mruby/host/mrbc')]
core = candidates.find { |dir| File.exist?(File.join(dir, 'lib/libmruby_core.a')) && File.directory?(File.join(dir, 'include')) }
if core.nil? || !system('g++', '--version', out: File::NULL, err: File::NULL)
  puts '  SKIP behavioural comparison: no libmruby_core.a with include/ found (set BC2CPP_MRUBY_CORE)'
else
  Dir.mktmpdir do |dir|
    source = File.join(dir, 'const_probe.cpp')
    File.write(source, <<~CPP)
      #include <mruby.h>
      #include <mruby/class.h>
      #include <mruby/variable.h>
      #include <mruby/error.h>
      #include <mruby/throw.h>
      #include <cstdio>

      #{helper}

      // The probe this replaced, kept verbatim as the reference.
      static mrb_value old_try(mrb_state* M, mrb_value scope, mrb_sym name, mrb_bool* ok) {
        Bc2cppConstLookupCtx ctx{scope, name};
        mrb_bool err = FALSE;
        mrb_value result = mrb_protect_error(M, bc2cpp_const_lookup_body, &ctx, &err);
        *ok = !err;
        return result;
      }

      // libmruby_core.a alone does not carry the compiled mrblib the core init
      // expects; constants need none of it.
      extern "C" void mrb_init_mrblib(mrb_state*) {}

      static int failures = 0;
      static void compare(mrb_state* M, const char* label, mrb_value scope, const char* name, int expect_ok) {
        mrb_sym sym = mrb_intern_cstr(M, name);
        mrb_bool ok_old, ok_new;
        mrb_value old_v = old_try(M, scope, sym, &ok_old);
        mrb_value new_v = bc2cpp_const_try(M, scope, sym, &ok_new);
        int same = ok_old == ok_new && (!ok_new || mrb_obj_eq(M, old_v, new_v));
        int right = ok_new == (mrb_bool)expect_ok;
        std::printf("%s %s\\n", (same && right) ? "ok  " : "FAIL", label);
        if (!(same && right)) ++failures;
      }

      static long objects(mrb_state* M) { return (long)M->gc.live; }

      int main() {
        mrb_state* M = mrb_open_core();
        auto setc = [&](struct RClass* k, const char* n, mrb_int v) {
          mrb_const_set(M, mrb_obj_value(k), mrb_intern_cstr(M, n), mrb_fixnum_value(v));
        };
        struct RClass* mixin = mrb_define_module(M, "Mixin");   setc(mixin, "FROM_MIXIN", 1);
        struct RClass* pre = mrb_define_module(M, "Pre");       setc(pre, "FROM_PRE", 2);
        setc(M->object_class, "TOP_ONLY", 3);
        struct RClass* base = mrb_define_class(M, "Base", M->object_class); setc(base, "INHERITED", 4);
        struct RClass* kid_class = mrb_define_class(M, "Kid", base);        setc(kid_class, "OWN", 5);
        mrb_include_module(M, kid_class, mixin);
        mrb_prepend_module(M, kid_class, pre);
        struct RClass* outer_module = mrb_define_module(M, "Outer");        setc(outer_module, "IN_MODULE", 6);
        struct RClass* inner_class = mrb_define_class_under(M, outer_module, "Inner", M->object_class); setc(inner_class, "DEEP", 7);
        if (M->exc) { std::printf("FAIL setup\\n"); return 1; }
        mrb_value kid = mrb_obj_value(mrb_class_get(M, "Kid"));
        mrb_value outer = mrb_obj_value(mrb_module_get(M, "Outer"));
        mrb_value inner = mrb_const_get(M, outer, mrb_intern_cstr(M, "Inner"));
        compare(M, "own constant", kid, "OWN", 1);
        compare(M, "inherited from the superclass", kid, "INHERITED", 1);
        compare(M, "from an included module", kid, "FROM_MIXIN", 1);
        compare(M, "from a prepended module", kid, "FROM_PRE", 1);
        compare(M, "defined only on Object is a miss for a class scope", kid, "TOP_ONLY", 0);
        compare(M, "missing entirely", kid, "NOPE", 0);
        compare(M, "constant of a module scope", outer, "IN_MODULE", 1);
        compare(M, "nested class own constant", inner, "DEEP", 1);
        compare(M, "an outer module's constant is not inherited by a nested class", inner, "IN_MODULE", 0);
        compare(M, "module scope does not see Object's constants", outer, "TOP_ONLY", 0);
        auto lookup = [&](const char* name, mrb_int expected) {
          mrb_value value = bc2cpp_const_scope_0(M, mrb_intern_cstr(M, name));
          if (!mrb_integer_p(value) || mrb_integer(value) != expected) {
            std::printf("FAIL outlined lookup %s\\n", name); ++failures;
          }
        };
        setc(outer_module, "DEEP", 99);
        lookup("DEEP", 7);
        lookup("IN_MODULE", 6);
        lookup("TOP_ONLY", 3);
        setc(inner_class, "DEEP", 8);
        lookup("DEEP", 8);
        mrb_sym missing = mrb_intern_cstr(M, "MISSING_OUTLINED");
        mrb_bool raised = FALSE;
        mrb_protect_error(M, [](mrb_state* vm, void* data) {
          return bc2cpp_const_scope_0(vm, *(mrb_sym*)data);
        }, &missing, &raised);
        if (!raised) { std::printf("FAIL outlined missing constant must raise\\n"); ++failures; }
        mrb_full_gc(M);
        lookup("DEEP", 8);
        // The point of the change: a miss must not allocate an exception.
        mrb_sym nope = mrb_intern_cstr(M, "NOPE");
        mrb_bool ok;
        mrb_full_gc(M);
        long before = objects(M);
        for (int i = 0; i < 1000; ++i) bc2cpp_const_try(M, kid, nope, &ok);
        long after = objects(M);
        std::printf("%s a miss allocates no objects (%ld -> %ld over 1000 misses)\\n", after == before ? "ok  " : "FAIL", before, after);
        if (after != before) ++failures;
        // Guard the measurement itself: the probe this replaced must show up.
        long old_before = objects(M);
        for (int i = 0; i < 100; ++i) old_try(M, kid, nope, &ok);
        long old_after = objects(M);
        std::printf("%s the reference probe does allocate per miss (%ld -> %ld over 100 misses)\\n", old_after > old_before ? "ok  " : "FAIL", old_before, old_after);
        if (!(old_after > old_before)) ++failures;
        mrb_close(M);
        return failures ? 1 : 0;
      }
    CPP
    binary = File.join(dir, 'const_probe')
    built = Bc2cppCxx.system('-std=c++17', '-fexceptions', '-DMRB_USE_CXX_EXCEPTION', '-DMRB_NO_GEMS',
                   "-I#{core}/include", "-I#{root}/3rd/mruby/include", source, "#{core}/lib/libmruby_core.a", '-o', binary)
    check.call('the emitted probe compiles against real mruby headers', built)
    if built
      output = IO.popen(binary, err: %i[child out], &:read)
      puts output.lines.map { |l| "  #{l}" }.join
      check.call('the probe agrees with the old raise-and-rescue probe on every scope shape and never allocates on a miss',
                 $?.success? && !output.include?('FAIL'))
    end
  end
end

if failures.empty?
  puts 'bc2cpp const lookup check: PASS'
else
  warn "bc2cpp const lookup check: #{failures.size} failure(s)"
  exit 1
end
