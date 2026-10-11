#!/usr/bin/env ruby
# encoding: UTF-8
# frozen_string_literal: true

# Check the NOMETHOD_VERIFY build switch (docs/adr/0275): compiling generated
# code with -DBC2CPP_NOMETHOD_VERIFY makes a reached bc2cpp_nomethod site abort
# WITHOUT dispatching, so a wrong dead-code proof cannot hide behind a rescue.
# Without the define the helper is ADR 0262's unchanged: dispatch first, then
# NoMethodError (proof held) or RuntimeError (proof wrong).
#
#   - a closed-world fixture's dead site emits bc2cpp_nomethod and the helper
#     carries the switch;
#   - against a real mruby core, the same helper built both ways: normal mode
#     dispatches, then raises; verify mode aborts, naming the site, before any
#     dispatch (the method's side effect never runs).
#
#   MRBC=path/to/host/mrbc [BC2CPP_MRUBY_CORE=dir] ruby scripts/bc2cpp/nomethod_verify_check.rb

require 'open3'
require 'shellwords'
require 'tmpdir'
require_relative '../../tools/bc2cpp/bc2cpp'
require_relative '../../tools/bc2cpp/nomethod_reviewed_probe'
require_relative 'cxx'

root = File.expand_path('../..', __dir__)
mrbc = ENV['MRBC'] || 'mrbc'
failures = []
check = lambda do |what, condition|
  puts "  #{condition ? 'ok  ' : 'FAIL'} #{what}"
  failures << what unless condition
end

puts '== a dead site in generated code'
WORLD = <<~'RUBY'
  class VfPet
    def vf_speak; 1; end
  end
  class VfRobot
    def vf_speak; 2; end
  end
  class VfCaller
    def talk(x); x.vf_speak; end
  end
RUBY
gems_env = Shellwords.join(NomethodReviewedProbe.wio_gems(root).map { |n, d| "#{n}=#{d}" })
Dir.mktmpdir do |dir|
  path = File.join(dir, 'vf.rb')
  File.write(path, WORLD)
  env = { 'MRBC' => mrbc, 'OUT_SYMBOL' => 'vf', 'OUT_DIR' => dir, 'SKIP_UNSUPPORTED' => '1',
          'BC2CPP_CLOSED_WORLD' => '1', 'BC2CPP_BUILD_NAME' => 'wio', 'BC2CPP_BUILD_GEMS' => gems_env,
          NomethodReviewed::ALLOW_ENV => 'allow' }
  out, _err, status = Open3.capture3(env, RbConfig.ruby, File.join(root, 'tools/bc2cpp/bc2cpp.rb'), path)
  check.call('the fixture generates and its dead fallback is a bc2cpp_nomethod site',
             status.success? && out.match?(/bc2cpp_nomethod\(M, r\d+, \d+\); \/\* CLOSED_WORLD nomethod: recv\.vf_speak \*\//))
  check.call('the emitted helper carries the verify switch, off unless defined',
             out.include?('#ifdef BC2CPP_NOMETHOD_VERIFY') && out.include?('abort();'))
end

candidates = [ENV['BC2CPP_MRUBY_CORE']].compact + Dir[File.join(root, 'build*/mruby/host/mrbc')]
core = candidates.find { |dir| File.exist?(File.join(dir, 'lib/libmruby_core.a')) && File.directory?(File.join(dir, 'include')) }
if core.nil? || !system('g++', '--version', out: File::NULL, err: File::NULL)
  puts '  SKIP behavioural check: no libmruby_core.a with include/ found (set BC2CPP_MRUBY_CORE)'
else
  puts '== the helper against a real mruby core, both ways'
  table = SymbolCache::Table.new
  table.index_for('"bar"')
  table.nomethod_used = true
  cache = SymbolCache.emit(table)
  Dir.mktmpdir do |dir|
    source = File.join(dir, 'verify_probe.cpp')
    File.write(source, <<~CPP)
      #include <mruby.h>
      #include <mruby/class.h>
      #include <mruby/error.h>
      #include <cstdarg>
      #include <cstdio>

      static mrb_value bc2cpp_funcall_argv(mrb_state* M, mrb_value r, mrb_sym m, mrb_int n, const mrb_value* a) { return mrb_funcall_argv(M, r, m, n, a); }

      #{cache}

      extern "C" void mrb_init_mrblib(mrb_state*) {}

      static mrb_value bar(mrb_state*, mrb_value) { std::puts("BAR-DISPATCHED"); return mrb_fixnum_value(1); }

      struct Call { mrb_value recv; };
      static mrb_value run(mrb_state* M, void* p) { return bc2cpp_nomethod(M, static_cast<Call*>(p)->recv, 0); }

      int main() {
        mrb_state* M = mrb_open_core();
        if (!mrb_class_defined(M, "NameError")) mrb_define_class(M, "NameError", M->eStandardError_class);
        if (!mrb_class_defined(M, "NoMethodError")) mrb_define_class(M, "NoMethodError", mrb_class_get(M, "NameError"));
        struct RClass* foo = mrb_define_class(M, "Foo", M->object_class);
        mrb_define_method(M, foo, "bar", bar, MRB_ARGS_NONE());
        Call c{mrb_obj_new(M, foo, 0, nullptr)};
        mrb_bool raised = FALSE;
        mrb_value exc = mrb_protect_error(M, run, &c, &raised);
        // Reached only when the site did not abort.
        std::printf("RAISED %s\\n", raised ? mrb_class_name(M, mrb_obj_class(M, exc)) : "(nothing)");
        mrb_close(M);
        return 0;
      }
    CPP
    build = lambda do |name, *flags|
      binary = File.join(dir, name)
      ok = Bc2cppCxx.system('-std=gnu++17', '-fexceptions', '-DMRB_USE_CXX_EXCEPTION', '-DMRB_NO_GEMS', *flags,
                  "-I#{core}/include", "-I#{root}/3rd/mruby/include", source, "#{core}/lib/libmruby_core.a", '-o', binary)
      ok ? binary : nil
    end
    normal = build.call('normal')
    verify = build.call('verify', '-DBC2CPP_NOMETHOD_VERIFY')
    check.call('the helper builds with and without -DBC2CPP_NOMETHOD_VERIFY', normal && verify)
    if normal && verify
      out, status = Open3.capture2e(normal)
      check.call('normal mode dispatches first, then raises the RuntimeError (ADR 0262 unchanged)',
                 status.success? && out.include?('BAR-DISPATCHED') && out.include?('RAISED RuntimeError'))
      out, status = Open3.capture2e(verify)
      check.call('verify mode aborts naming the class and method',
                 status.signaled? && status.termsig == Signal.list.fetch('ABRT') &&
                 out.include?('NOMETHOD_VERIFY: dead site reached: Foo#bar'))
      check.call('verify mode dispatches nothing and raises nothing rescuable',
                 !out.include?('BAR-DISPATCHED') && !out.include?('RAISED'))
    end
  end
end

if failures.empty?
  puts 'bc2cpp_nomethod_verify_check: ok'
else
  abort "bc2cpp_nomethod_verify_check: #{failures.size} failure(s)"
end
