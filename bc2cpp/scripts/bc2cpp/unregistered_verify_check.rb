#!/usr/bin/env ruby
# frozen_string_literal: true

# UNREGISTERED_VERIFY: an entry static_dispatch_unregistered*.rb leaves unregistered gets no method-table entry, and
# a build with -DBC2CPP_UNREGISTERED_VERIFY (BC2CPP_UNREGISTERED_VERIFY=1, build_config.rb) registers a stub under
# its name instead, so a by-name lookup the proof missed aborts naming the method (codegen_emit.rb,
# emit_owner_registrations).
#
#   generated registration (needs a host mrbc)
#     - a listed entry is not registered, an unlisted one is;
#     - the stub registration is emitted only inside #ifdef BC2CPP_UNREGISTERED_VERIFY;
#     - BC2CPP_UNREGISTERED_EXTRA adds entries to the list;
#   behaviour (needs a full-core libmruby, see Bc2cppFixtureRuntime.full_or_build)
#     - without the define, a by-name call of the unregistered name raises NoMethodError, the kept one answers;
#     - with it, the same call aborts with "unregistered method looked up by name: VFix#pruned".
#
# Usage: MRBC=path/to/mrbc [BC2CPP_MRUBY_FULL=dir | BC2CPP_FULL_BUILD_DIR=dir] ruby scripts/bc2cpp/unregistered_verify_check.rb

require 'open3'
require 'set'
require 'tmpdir'
require_relative 'check_support'
require_relative 'fixture_runtime'
require_relative '../../tools/bc2cpp/bc2cpp'

ENV['BC2CPP_SIG_DIRS'] = ''
suite = FixtureCheck.new('unregistered_verify_check')
suite.require_mrbc!

SOURCE = <<~'RUBY'
  class VFix
    def kept
      1
    end

    def pruned
      2
    end
  end
RUBY

ENTRIES = [
  { owner: 'VFix', name: 'kept', entry: 'vfix_kept', aspec: 'MRB_ARGS_NONE()', visibility: :public },
  { owner: 'VFix', name: 'pruned', entry: 'vfix_pruned', aspec: 'MRB_ARGS_NONE()', visibility: :public }
].freeze

registration = lambda do |unregistered: nil, extra: nil|
  previous = ENV['BC2CPP_UNREGISTERED_EXTRA']
  ENV['BC2CPP_UNREGISTERED_EXTRA'] = extra
  suite.compile(SOURCE) do |ireps, root|
    registry = build_registry(ireps, root)[0]
    gen = CodeGen.new(ireps, registry, {}, {}, {}, {}, {}, {}, {}, {}, {}, Set.new)
    unregistered ? gen.emit_owner_registrations(ENTRIES, ['VFix'], unregistered: unregistered)
                 : gen.emit_owner_registrations(ENTRIES, ['VFix'])
  end
ensure
  ENV['BC2CPP_UNREGISTERED_EXTRA'] = previous
end

listed = registration.call(unregistered: Set['VFix#pruned'])
plain = listed.sub(/^#ifdef BC2CPP_UNREGISTERED_VERIFY\n.*?^#endif\n/m) { '' }.gsub(/^#ifdef BC2CPP_UNREGISTERED_VERIFY\n.*?^#endif\n/m, '')
suite.check('an unlisted entry is registered', plain.include?('vfix_kept, MRB_ARGS_NONE())'))
suite.check('a listed entry is not registered outside the verify block', !plain.include?('vfix_pruned'))
suite.check('the verify stub is registered under the listed name, only inside #ifdef BC2CPP_UNREGISTERED_VERIFY',
            listed.match?(/^#ifdef BC2CPP_UNREGISTERED_VERIFY\n\s*mrb_define_method\(M, \w+, "[^"]+", bc2cpp_unregistered_stub, MRB_ARGS_ANY\(\)\);\n#endif/))
extra = registration.call(extra: 'VFix#pruned')
suite.check('BC2CPP_UNREGISTERED_EXTRA leaves the entry unregistered', extra == listed)
none = registration.call(unregistered: Set.new)
suite.check('with nothing listed there is no stub', !none.include?('bc2cpp_unregistered_stub'))

full = Bc2cppFixtureRuntime.full_or_build
if full.nil?
  puts '  SKIP: no full-core libmruby; the behavioural checks need it'
else
  Dir.mktmpdir('bc2cpp-unregistered-verify') do |dir|
    File.write(File.join(dir, 'main.cpp'), <<~CPP)
      #include <mruby.h>
      #include <mruby/class.h>
      #include <mruby/string.h>
      #include <mruby/variable.h>
      #include <cstdio>
      static mrb_value vfix_kept(mrb_state*, mrb_value) { return mrb_fixnum_value(1); }
      static mrb_value vfix_pruned(mrb_state*, mrb_value) { return mrb_fixnum_value(2); }
      #{listed}
      int main() {
        mrb_state* M = mrb_open();
        mrb_define_class(M, "VFix", M->object_class);
        bc2cpp_register_owner_methods(M);
        mrb_value o = mrb_obj_new(M, mrb_class_get(M, "VFix"), 0, nullptr);
        mrb_value k = mrb_funcall(M, o, "kept", 0);
        std::printf("kept=%d\\n", (int)mrb_integer(k));
        mrb_funcall(M, o, "pruned", 0);
        if (M->exc) std::printf("pruned=%s\\n", mrb_obj_classname(M, mrb_obj_value(M->exc)));
        else std::printf("pruned=answered\\n");
        mrb_close(M);
        return 0;
      }
    CPP
    build = lambda do |defines, exe|
      cmd = ['g++', '-std=gnu++17', *defines, "-I#{full}/include", '-o', exe, File.join(dir, 'main.cpp'),
             "#{full}/lib/libmruby.a", '-lm']
      out, status = Open3.capture2e(*cmd)
      warn out unless status.success?
      status.success?
    end
    plain_exe = File.join(dir, 'plain')
    verify_exe = File.join(dir, 'verify')
    suite.check('the plain host compiles', build.call([], plain_exe))
    suite.check('the verify host compiles', build.call(['-DBC2CPP_UNREGISTERED_VERIFY'], verify_exe))
    out, = Open3.capture2e(plain_exe)
    suite.check('without the define the kept name answers and the unregistered one raises NoMethodError',
                out.include?('kept=1') && out.include?('pruned=NoMethodError'))
    out, status = Open3.capture2e(verify_exe)
    suite.check('with the define the unregistered name aborts naming the method',
                status.signaled? && out.include?('unregistered method looked up by name: VFix#pruned'))
  end
end

suite.finish!
