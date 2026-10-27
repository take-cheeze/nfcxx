#!/usr/bin/env ruby
# frozen_string_literal: true

# UNREGISTERED_VERIFY: an entry static_dispatch_unregistered*.rb leaves unregistered gets no method-table entry, and
# a build with -DBC2CPP_UNREGISTERED_VERIFY (BC2CPP_UNREGISTERED_VERIFY=1, build_config.rb) registers a stub under
# its name instead, so a by-name lookup the proof missed aborts naming the method (codegen_emit.rb,
# emit_owner_registrations, LEFT_OUT). RESPOND_TO_PHANTOM: a closed build keeps respond_to? true for it.
#
#   generated registration (needs a host mrbc)
#     - a listed entry is not registered, an unlisted one is; the listed one goes to bc2cpp_left_out;
#     - bc2cpp_left_out registers the stub only under #if defined(BC2CPP_UNREGISTERED_VERIFY);
#     - BC2CPP_UNREGISTERED_EXTRA adds entries to the list;
#   behaviour (needs a full-core libmruby, see Bc2cppFixtureRuntime.full_or_build)
#     - without the define, a by-name call of the unregistered name raises NoMethodError, the kept one answers;
#     - with it, the same call aborts with "unregistered method looked up by name: VFix#pruned";
#     - with the RESPOND_TO_PHANTOM runtime, respond_to? (the Kernel method and the mrb_respond_to the generated
#       code calls) answers true for the left-out entry on its class, a subclass and, for a singleton entry, the
#       class object, and false elsewhere; without it, false.
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

    def self.cpruned
      3
    end
  end
RUBY

ENTRIES = [
  { owner: 'VFix', name: 'kept', entry: 'vfix_kept', aspec: 'MRB_ARGS_NONE()', visibility: :public },
  { owner: 'VFix', name: 'pruned', entry: 'vfix_pruned', aspec: 'MRB_ARGS_NONE()', visibility: :public },
  { owner: 'VFix.singleton', name: 'cpruned', entry: 'vfix_cpruned', aspec: 'MRB_ARGS_NONE()', visibility: :public }
].freeze
OWNERS = %w[VFix VFix.singleton].freeze

registration = lambda do |unregistered: nil, extra: nil|
  previous = ENV['BC2CPP_UNREGISTERED_EXTRA']
  ENV['BC2CPP_UNREGISTERED_EXTRA'] = extra
  suite.compile(SOURCE) do |ireps, root|
    registry = build_registry(ireps, root)[0]
    gen = CodeGen.new(ireps, registry, {}, {}, {}, {}, {}, {}, {}, {}, {}, Set.new)
    unregistered ? gen.emit_owner_registrations(ENTRIES, OWNERS, unregistered: unregistered)
                 : gen.emit_owner_registrations(ENTRIES, OWNERS)
  end
ensure
  ENV['BC2CPP_UNREGISTERED_EXTRA'] = previous
end

listed = registration.call(unregistered: Set['VFix#pruned', 'VFix.singleton#cpruned'])
suite.check('an unlisted entry is registered', listed.include?('vfix_kept, MRB_ARGS_NONE())'))
suite.check('a listed entry is not registered', !listed.include?('vfix_pruned') && !listed.include?('vfix_cpruned'))
suite.check('a listed entry goes to bc2cpp_left_out, with its singleton flag',
            listed.match?(/^\s*bc2cpp_left_out\(M, \w+, "[^"]+", false\);$/) &&
            listed.match?(/^\s*bc2cpp_left_out\(M, \w+, "[^"]+", true\);$/))
left_out = listed[/static void bc2cpp_left_out\(.*?^}/m].to_s
suite.check('bc2cpp_left_out registers the stub only in a verify build',
            left_out.match?(/#if defined\(BC2CPP_UNREGISTERED_VERIFY\)\n[^#]*bc2cpp_unregistered_stub[^#]*#elif defined\(BC2CPP_RESPOND_TO_PHANTOM\)/m))
extra = registration.call(extra: 'VFix#pruned,VFix.singleton#cpruned')
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
      #include <mruby/array.h>
      #include <mruby/class.h>
      #include <mruby/hash.h>
      #include <mruby/proc.h>
      #include <mruby/string.h>
      #include <mruby/variable.h>
      #include <cstdio>
      static mrb_value vfix_kept(mrb_state*, mrb_value) { return mrb_fixnum_value(1); }
      static mrb_value vfix_pruned(mrb_state*, mrb_value) { return mrb_fixnum_value(2); }
      static mrb_value vfix_cpruned(mrb_state*, mrb_value) { return mrb_fixnum_value(3); }
      #ifdef FIX_PHANTOM
      #{CodeGen.respond_to_phantom_runtime}
      #endif
      #{listed}
      static int responds(mrb_state* M, mrb_value o, const char* name) {
        mrb_value r = mrb_funcall(M, o, "respond_to?", 1, mrb_symbol_value(mrb_intern_cstr(M, name)));
        int direct = mrb_respond_to(M, o, mrb_intern_cstr(M, name)) ? 1 : 0;
        return (mrb_test(r) ? 1 : 0) == direct ? direct : -1;
      }
      int main() {
        mrb_state* M = mrb_open();
        struct RClass* vfix = mrb_define_class(M, "VFix", M->object_class);
        struct RClass* sub = mrb_define_class(M, "VFixSub", vfix);
        bc2cpp_register_owner_methods(M);
        mrb_value o = mrb_obj_new(M, vfix, 0, nullptr);
        mrb_value s = mrb_obj_new(M, sub, 0, nullptr);
        std::printf("responds kept=%d pruned=%d sub_pruned=%d other=%d class_cpruned=%d sub_class_cpruned=%d "
                    "obj_cpruned=%d class_pruned=%d\\n",
                    responds(M, o, "kept"), responds(M, o, "pruned"), responds(M, s, "pruned"),
                    responds(M, o, "nothing_here"), responds(M, mrb_obj_value(vfix), "cpruned"),
                    responds(M, mrb_obj_value(sub), "cpruned"), responds(M, o, "cpruned"),
                    responds(M, mrb_obj_value(vfix), "pruned"));
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
    phantom_exe = File.join(dir, 'phantom')
    suite.check('the plain host compiles', build.call([], plain_exe))
    suite.check('the verify host compiles', build.call(['-DBC2CPP_UNREGISTERED_VERIFY'], verify_exe))
    suite.check('the RESPOND_TO_PHANTOM host compiles', build.call(['-DFIX_PHANTOM'], phantom_exe))
    out, = Open3.capture2e(plain_exe)
    suite.check('without the define the kept name answers and the unregistered one raises NoMethodError',
                out.include?('kept=1') && out.include?('pruned=NoMethodError'))
    suite.check('without RESPOND_TO_PHANTOM respond_to? is false for a left-out entry',
                out.include?('responds kept=1 pruned=0 sub_pruned=0 other=0 class_cpruned=0'))
    out, = Open3.capture2e(phantom_exe)
    suite.check('RESPOND_TO_PHANTOM: respond_to? and mrb_respond_to agree, true for the left-out entry on its class, ' \
                'a subclass and the class object of a singleton entry, false elsewhere',
                out.include?('responds kept=1 pruned=1 sub_pruned=1 other=0 class_cpruned=1 sub_class_cpruned=1 ' \
                             'obj_cpruned=0 class_pruned=0'))
    suite.check('RESPOND_TO_PHANTOM: the left-out entry still is not callable by name', out.include?('pruned=NoMethodError'))
    out, status = Open3.capture2e(verify_exe)
    suite.check('with the define the unregistered name aborts naming the method',
                status.signaled? && out.include?('unregistered method looked up by name: VFix#pruned'))
  end
end

suite.finish!
