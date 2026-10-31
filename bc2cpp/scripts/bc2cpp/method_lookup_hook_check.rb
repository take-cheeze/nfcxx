#!/usr/bin/env ruby
# frozen_string_literal: true

require 'fileutils'
require 'open3'
require 'tmpdir'

root = File.expand_path('../..', __dir__)
source = ENV.fetch('MRUBY_LOOKUP_SOURCE', File.join(root, '3rd/mruby'))
abort 'method lookup hook missing from mruby source' unless File.read(File.join(source, 'include/mruby.h')).include?('MRB_USE_METHOD_LOOKUP_HOOK')

def run!(*args, **options)
  out, status = Open3.capture2e(*args, **options)
  abort "#{args.inspect} failed:\n#{out}" unless status.success?
end

Dir.mktmpdir('method-lookup-hook') do |dir|
  config = File.join(dir, 'config.rb')
  File.write(config, <<~'CONFIG')
    %w[off on uncached].each do |name|
      MRuby::Build.new(name) do |conf|
        toolchain :gcc
        conf.linker.command = conf.cc.command
        conf.enable_cxx_exception if name == 'on'
        conf.cxx.defines << 'MRB_USE_METHOD_LOOKUP_HOOK' unless name == 'off'
        conf.cc.defines << 'MRB_USE_METHOD_LOOKUP_HOOK' unless name == 'off'
        conf.cc.defines << 'MRB_NO_METHOD_CACHE' if name == 'uncached'
        conf.gem core: 'mruby-compiler'
        conf.gem core: 'mruby-bin-mrbc'
      end
    end
  CONFIG
  test = File.join(dir, 'check.c')
  File.write(test, <<~'C')
    #include <assert.h>
    #include <stdio.h>
    #include <mruby.h>
    #include <mruby/class.h>
    #include <mruby/compile.h>
    #include <mruby/internal.h>
    #include <mruby/proc.h>

    static unsigned hits, misses;
    static mrb_sym target;
    static struct RClass *expected_start, *expected_owner;
    static mrb_value answer(mrb_state *mrb, mrb_value self) { return mrb_fixnum_value(42); }
    #ifdef MRB_USE_METHOD_LOOKUP_HOOK
    static unsigned startup_core, startup_gems;
    static void startup_observe(mrb_state *mrb, struct RClass *start, struct RClass *owner,
                                mrb_sym mid, const mrb_method_t *method) {
      if (mrb->bootstrapping) startup_core++;
      else startup_gems++;
    }
    static void observe(mrb_state *mrb, struct RClass *start, struct RClass *owner,
                        mrb_sym mid, const mrb_method_t *method) {
      if (mid != target) return;
      assert(start == expected_start);
      if (MRB_METHOD_UNDEF_P(*method)) {
        assert(owner == NULL);
        misses++;
      }
      else {
        assert(owner == expected_owner);
        hits++;
      }
    }
    #endif
    int main(void) {
      mrb_state *mrb = mrb_open();
      assert(mrb);
      struct RClass *base = mrb_define_class(mrb, "HookBase", mrb->object_class);
      struct RClass *sub = mrb_define_class(mrb, "HookSub", base);
      target = mrb_intern_lit(mrb, "hook_target");
      mrb_define_method(mrb, base, "hook_target", answer, MRB_ARGS_NONE());
      mrb_value obj = mrb_obj_new(mrb, sub, 0, NULL);
      expected_start = sub;
      expected_owner = base;
      #ifdef MRB_USE_METHOD_LOOKUP_HOOK
      assert(mrb->method_lookup_hook == NULL);
      mrb->method_lookup_hook = observe;
      #endif
      for (int i = 0; i < 2; i++) {
        mrb_value result = mrb_funcall_argv(mrb, obj, target, 0, NULL);
        assert(!mrb->exc && mrb_integer(result) == 42);
      }
      #ifdef MRB_USE_METHOD_LOOKUP_HOOK
      assert(hits == 2 && misses == 0); /* cold lookup and cache hit */
      #endif
      mrb_load_string(mrb, "HookSub.new.hook_target");
      assert(!mrb->exc);
      #ifdef MRB_USE_METHOD_LOOKUP_HOOK
      assert(hits == 3); /* bytecode send */
      #endif
      assert(mrb_respond_to(mrb, obj, target));
      #ifdef MRB_USE_METHOD_LOOKUP_HOOK
      assert(hits == 4); /* a probe is also a lookup */
      #endif
      mrb_undef_method(mrb, sub, "hook_target");
      struct RClass *owner = sub;
      mrb_method_t method = mrb_method_search_vm(mrb, &owner, target);
      assert(MRB_METHOD_UNDEF_P(method));
      #ifdef MRB_USE_METHOD_LOOKUP_HOOK
      assert(misses == 1);
      #endif
      target = mrb_intern_lit(mrb, "absent_hook_target");
      owner = sub;
      method = mrb_method_search_vm(mrb, &owner, target);
      assert(MRB_METHOD_UNDEF_P(method));
      #ifdef MRB_USE_METHOD_LOOKUP_HOOK
      assert(misses == 2);
      mrb_state *early = mrb_open_with_method_lookup_hook(startup_observe);
      assert(early && !early->exc && early->method_lookup_hook == startup_observe);
      assert(startup_core > 0);
      mrb_close(early);
      mrb_state *other = mrb_open();
      assert(other && other->method_lookup_hook == NULL);
      mrb_close(other);
      mrb->method_lookup_hook = NULL;
      #endif
      mrb_close(mrb);
      puts("method lookup hook: PASS");
    }
  C
  run!({ 'MRUBY_CONFIG' => config, 'MRUBY_BUILD_DIR' => File.join(dir, 'build') },
       RbConfig.ruby, 'minirake', '-j8', chdir: source)
  %w[off on uncached].each do |name|
    build = File.join(dir, 'build', name)
    binary = File.join(dir, name)
    defines = name == 'off' ? [] : ['-DMRB_USE_METHOD_LOOKUP_HOOK']
    defines << '-DMRB_NO_METHOD_CACHE' if name == 'uncached'
    run!('cc', '-g', *defines, "-I#{build}/include", "-I#{source}/include", test,
         File.join(build, 'lib/libmruby.a'), '-lm', '-lstdc++', '-o', binary)
    run!(binary)
    puts "method_lookup_hook_check: #{name} passed"
  end
end
