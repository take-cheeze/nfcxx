#!/usr/bin/env ruby
# frozen_string_literal: true

# MODULE_ZSUPER (zsuper_lookup_plan): a bare `super` (ARGARY + SUPER n=*) in a module's method compiles to
# bc2cpp_super_call, which continues after the module's include-class in self's own chain, as OP_SUPER does for a
# module owner. The fixture prepends ZsOver to two classes and includes ZsInc under a subclass, with optional, rest
# block and keyword parameters, and checks that those module methods compile and behave as the interpreter does. A module
# keyword zsuper without a block parameter (`LOADNIL R(a+3)` before SUPER) passes nil, as the interpreter does even
# when its caller gave a block. A module method without a block parameter whose callers pass a block (ZsOver#qux) extracts
# that block in its wrapper and forwards it (SUPER_FRAME_BLOCK). The behaviour part needs BC2CPP_MRUBY_FULL, or rake and a
# C++ compiler.
ENV['BC2CPP_SIG_DIRS'] = ''

require 'tmpdir'
require_relative 'check_support'
require_relative 'fixture_runtime'

suite = FixtureCheck.new('module_zsuper_check')
suite.require_mrbc!

SOURCE = <<~RUBY
  class ZsBase
    def foo(x, y = 2) = [:base, x, y]
    def bar(*a) = [:bar, a]
    def baz(x) = [:baz, x, (block_given? ? yield(x) : :noblk)]
    def via_self(x) = foo(x)
    def kw(x, k: 1) = [:kw, x, k, block_given?]
    def qux(x) = [:qux, x, block_given?]
  end
  class ZsTwo
    def foo(x, y = 3) = [:two, x, y]
  end
  module ZsOver
    def foo(x, y = 5)
      [:over, super]
    end
    def bar(*a)
      [:obar, super]
    end
    def kw(x, k: 2)
      [:okw, super]
    end
    def qux(x)
      [:oqux, super]
    end
    def baz(x, &b)
      [:obaz, super]
    end
  end
  ZsBase.prepend(ZsOver)
  ZsTwo.prepend(ZsOver)
  module ZsInc
    def foo(x, y = 7) = [:inc, super]
  end
  class ZsKid < ZsBase
    include ZsInc
    def foo(x, y = 9) = [:kid, super]
  end
  class ZsUser
    def call(o) = o.foo(1)
    def call2(o) = o.foo(1, 4)
    def callbar(o) = o.bar(1, 2, 3)
    def callbaz(o) = o.baz(1) { |v| v * 10 }
    def callbaz_noblk(o) = o.baz(1)
    def callkw(o) = o.kw(1)
    def callkw2(o) = o.kw(1, k: 8)
    def callkwblk(o) = o.kw(1) { 0 }
    def callqux(o) = o.qux(1) { 0 }
  end
RUBY

OWNERS = %w[ZsBase ZsTwo ZsOver ZsInc ZsKid ZsUser].freeze

def compiled?(code, name)
  code.match?(/^(?:static )?mrb_value #{name}\(mrb_state\* M/)
end

Dir.mktmpdir('bc2cpp-module-zsuper') do |dir|
  code, err = Bc2cppFixtureRuntime.generate(SOURCE, dir, core: true, only_owners: OWNERS)
  suite.check('module methods with a bare super compile',
              %w[ZsOver_foo_impl ZsOver_bar_impl ZsOver_baz_impl ZsInc_foo_impl ZsOver_kw_impl].all? { |f| compiled?(code, f) })
  suite.check('a module method whose callers pass a block takes it and forwards it',
              code.match?(/^mrb_value ZsOver_qux_impl\(mrb_state\* M, mrb_value self, mrb_value x, mrb_value bc2cpp_blk\)/))

  build = ENV['CC_GENERATED_ONLY'] == '1' ? nil : Bc2cppFixtureRuntime.full_or_build
  if build.nil?
    puts '  SKIP module zsuper behaviour: needs a full-core libmruby (BC2CPP_MRUBY_FULL, or rake and g++)'
  else
    scenario = <<~CPP
      #include <string>
      static mrb_value zs_new(mrb_state* M, const char* cls) {
        return mrb_funcall_argv(M, mrb_obj_value(mrb_class_get(M, cls)), mrb_intern_lit(M, "new"), 0, nullptr);
      }
      static int scenario(mrb_state* M) {
        mrb_value u = zs_new(M, "ZsUser");
        const char* classes[] = {"ZsBase", "ZsTwo", "ZsKid"};
        const char* full[] = {"callbar", "callbaz", "callbaz_noblk", "callkw", "callkw2", "callkwblk", "callqux"};
        for (const char* c : classes) {
          mrb_value o = zs_new(M, c);
          std::string p(c);
          call(M, (p + "_call").c_str(), u, "call", 1, &o);
          call(M, (p + "_call2").c_str(), u, "call2", 1, &o);
          if (p == "ZsTwo") continue;
          for (const char* m : full) call(M, (p + "_" + m).c_str(), u, m, 1, &o);
        }
        mrb_value one = mrb_fixnum_value(1);
        call(M, "via_self", zs_new(M, "ZsBase"), "via_self", 1, &one);
        return 0;
      }
    CPP
    built, output = Bc2cppFixtureRuntime.run(dir, err, OWNERS, scenario, build: build, full: true)
    suite.check('fixture builds and runs', built)
    sections = Bc2cppFixtureRuntime.sections(output)
    plain = ->(lines) { lines.to_a.reject { |l| l.start_with?('  dispatches=') } }
    interpreted = plain.call(sections['interpreted'])
    compiled = plain.call(sections['compiled'])
    suite.check('the interpreter walks prepend, include and subclass chains',
                interpreted.include?('ZsKid_call => [:kid, [:inc, [:over, [:base, 1, 9]]]]') &&
                interpreted.include?('ZsTwo_call => [:over, [:two, 1, 5]]') &&
                interpreted.include?('ZsBase_callbaz => [:obaz, [:baz, 1, 10]]') &&
                interpreted.include?('ZsBase_callkwblk => [:okw, [:kw, 1, 2, false]]') &&
                interpreted.include?('ZsBase_callqux => [:oqux, [:qux, 1, true]]'))
    suite.check('compiled matches interpreted', compiled == interpreted)
  end
end

suite.finish!
