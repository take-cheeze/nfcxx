#!/usr/bin/env ruby
# frozen_string_literal: true

# REGISTRATION_SPLIT (tools/bc2cpp/codegen_emit.rb, emit_owner_registrations): the generated registration has a core
# half that resolves no program class, so the optcarrot probe can install it before its class bodies run
# (OptcarrotProbe.install_prelude!, tools/optcarrot_probe/register_emit.rb) and the program half at install!.
# The probe binary itself takes minutes to build and is not run on pull requests; this fixture stands in for it.
#
#   generated code (needs a host mrbc)
#     - bc2cpp.rb puts a core owner (Integer) in the core half and the program's own class in the program half,
#       and bc2cpp_register_owner_methods calls both;
#     - the probe's install_prelude! calls only the core half and install! the program half;
#   behaviour (needs a full-core libmruby, see Bc2cppFixtureRuntime.full_or_build)
#     - in the bundle's order (install_prelude!, then the class bodies, then install!), install_prelude! raises
#       nothing while the program class is still undefined, and each half installs its compiled method.
#
# Usage: MRBC=path/to/mrbc [BC2CPP_MRUBY_FULL=dir | BC2CPP_FULL_BUILD_DIR=dir] ruby scripts/bc2cpp/registration_split_check.rb

require 'fileutils'
require 'open3'
require 'tmpdir'
require_relative 'check_support'
require_relative 'fixture_runtime'
require_relative '../../tools/optcarrot_probe/register_emit'

# The fixture is its own closed world: the repository signatures name classes it does not define.
ENV['BC2CPP_SIG_DIRS'] = ''
suite = FixtureCheck.new('registration_split_check')
suite.require_mrbc!

SOURCE = <<~'RUBY'
  class Integer
    def split_probe_twice
      self + self
    end
  end

  module SplitProbe
    class Widget
      def value
        21.split_probe_twice
      end
    end
  end
RUBY

function_body = lambda do |code, name|
  code[/^static void #{name}\(\[\[maybe_unused\]\] mrb_state\* M\) \{\n(.*?)^\}/m, 1] ||
    code[/^static void #{name}\(mrb_state\* M\) \{\n(.*?)^\}/m, 1]
end

Dir.mktmpdir('registration-split') do |dir|
  code, err = Bc2cppFixtureRuntime.generate(SOURCE, dir)
  core = function_body.call(code, 'bc2cpp_register_core_owner_methods').to_s
  program = function_body.call(code, 'bc2cpp_register_program_owner_methods').to_s
  both = function_body.call(code, 'bc2cpp_register_owner_methods').to_s
  # Method and constant names are emitted as escaped C strings, so the entry names identify the owners.
  suite.check('the core half registers the core owner and names no program class',
              core.include?(', Integer_split_probe_twice,') && !core.include?('SplitProbe'))
  suite.check('the program half registers the program class and no core owner',
              program.include?(', SplitProbe__Widget_value,') && !program.include?('Integer'))
  suite.check('bc2cpp_register_owner_methods runs the core half, then the program half',
              both.match?(/\A\s*bc2cpp_register_core_owner_methods\(M\);\s*bc2cpp_register_program_owner_methods\(M\);\s*\z/))

  OptcarrotRegister.emit_register(err, dir)
  register = File.read(File.join(dir, 'register.cxx'))
  prelude = register[/^static mrb_value optcarrot_install_prelude\(.*?^\}/m].to_s
  install = register[/^static mrb_value optcarrot_install\(.*?^\}/m].to_s
  suite.check("the probe's install_prelude! installs only the core half",
              prelude.include?('bc2cpp_register_core_owner_methods(M);') &&
              !prelude.match?(/bc2cpp_register_(program_)?owner_methods/))
  suite.check("the probe's install! installs the program half",
              install.include?('bc2cpp_register_program_owner_methods(M);') &&
              !install.match?(/bc2cpp_register_(core_)?owner_methods/))

  full = Bc2cppFixtureRuntime.full_or_build
  if full.nil?
    puts '  SKIP: no full-core libmruby; the behavioural check needs it'
    next
  end

  File.write(File.join(dir, 'optcarrot_probe_gen.cpp'), code)
  FileUtils.cp(File.join(dir, 'fixture_decls.h'), File.join(dir, 'optcarrot_probe_decls.h'))
  File.write(File.join(dir, 'main.cpp'), <<~CPP)
    #include "register.cxx"
    #include <mruby/irep.h>
    #include <cstdio>
    #include <fstream>
    #include <iterator>
    #include <vector>
    static bool compiled(mrb_state* M, struct RClass* c, const char* name) {
      mrb_method_t m = mrb_method_search_vm(M, &c, mrb_intern_cstr(M, name));
      return !MRB_METHOD_UNDEF_P(m) && MRB_METHOD_CFUNC_P(m);
    }
    static void step(mrb_state* M, const char* label) {
      if (M->exc) { std::printf("%s raised %s\\n", label, mrb_obj_classname(M, mrb_obj_value(M->exc))); M->exc = nullptr; }
      else std::printf("%s ok\\n", label);
    }
    int main(int, char** argv) {
      std::ifstream in(argv[1], std::ios::binary);
      std::vector<uint8_t> bin((std::istreambuf_iterator<char>(in)), std::istreambuf_iterator<char>());
      mrb_state* M = mrb_open();
      mrb_optcarrot_compiled_gem_init(M);
      mrb_value probe = mrb_obj_value(mrb_module_get(M, "OptcarrotProbe"));
      mrb_funcall(M, probe, "install_prelude!", 0);
      step(M, "install_prelude!");
      std::printf("prelude core=%d\\n", compiled(M, M->integer_class, "split_probe_twice"));
      // The class bodies, which also put the interpreted Integer#split_probe_twice back; the bundle's shims run
      // before install_prelude! instead, so only the program half is asserted after install!.
      mrb_load_irep_buf(M, bin.data(), bin.size());
      step(M, "class bodies");
      mrb_funcall(M, probe, "install!", 0);
      step(M, "install!");
      struct RClass* widget = mrb_class_get_under(M, mrb_module_get(M, "SplitProbe"), "Widget");
      std::printf("install program=%d\\n", compiled(M, widget, "value"));
      mrb_value v = mrb_funcall(M, mrb_obj_new(M, widget, 0, nullptr), "value", 0);
      step(M, "value");
      std::printf("value=%d\\n", mrb_integer_p(v) ? (int)mrb_integer(v) : -1);
      mrb_close(M);
      return 0;
    }
  CPP
  binary = File.join(dir, 'split')
  flags = %w[-std=c++17 -fexceptions -DMRB_USE_CXX_EXCEPTION -w]
  flags.concat(Bc2cppFixtureRuntime.library_defines(full) - flags)
  root = Bc2cppFixtureRuntime::ROOT
  built = Bc2cppCxx.system(*flags, "-I#{dir}", "-I#{full}/include", "-I#{root}/3rd/mruby/include",
                           "-I#{root}/mruby-rgss/src", "-I#{root}/include", File.join(dir, 'main.cpp'),
                           "#{full}/lib/libmruby.a", '-lm', '-o', binary)
  suite.check('the probe registration links against libmruby', built)
  next unless built

  out, status = Open3.capture2e(binary, File.join(dir, 'fixture.mrb'))
  puts out.lines.map { |line| "    #{line}" }.join
  suite.check('install_prelude! raises nothing before the program class exists', out.include?("install_prelude! ok\n"))
  suite.check('install_prelude! installs the compiled core-owner method', out.include?("prelude core=1\n"))
  suite.check('install! installs the compiled program method, which answers',
              status.success? && out.include?("install! ok\n") && out.include?("install program=1\n") &&
              out.include?("value=42\n"))
end

suite.finish!
