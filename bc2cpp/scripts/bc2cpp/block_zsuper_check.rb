#!/usr/bin/env ruby
# frozen_string_literal: true

# BLOCK_ZSUPER (block_zsuper_plan): a bare `super` in a block a method makes (`run_it { super }`, `ARGARY R3 1:0:0:0
# (1)` + `SUPER R2 n=*`) packs the method frame's parameters and block (vm.c OP_ARGARY with lv = 1). The compiled block
# body reads the parameters through its upvar pointers and forwards the method's block, so the method and its block
# compile. The fixture covers a class and a prepended module owner, one and two parameters, a caller that passes a
# block and one that does not; a method that reassigns its parameter stays on the interpreter. The behaviour part
# needs BC2CPP_MRUBY_FULL, or rake and a C++ compiler.
ENV['BC2CPP_SIG_DIRS'] = ''

require 'tmpdir'
require_relative 'check_support'
require_relative 'fixture_runtime'

suite = FixtureCheck.new('block_zsuper_check')
suite.require_mrbc!

SOURCE = <<~RUBY
  class BzBase
    def run_it = yield
    def f(x) = [:base, x, block_given? ? yield : :noblk]
    def g(x, y) = [:bg, x, y, block_given?]
    def k(x) = [:bk, x]
  end
  module BzWrap
    def f(x) = run_it { [:wrap, super] }
  end
  class BzKid < BzBase
    def f(x) = run_it { [:kid, super] }
    def g(x, y) = run_it { [super, x] }
    def k(x)
      x += 1
      run_it { super }
    end
  end
  class BzPre < BzBase
    prepend BzWrap
  end
  class BzUser
    def kid_f(o) = o.f(1)
    def kid_fb(o) = o.f(1) { 7 }
    def kid_g(o) = o.g(1, 2)
    def kid_gb(o) = o.g(3, 4) { 0 }
    def kid_k(o) = o.k(1)
    def pre_f(o) = o.f(3)
    def pre_fb(o) = o.f(3) { 8 }
  end
RUBY

OWNERS = %w[BzBase BzWrap BzKid BzPre BzUser].freeze

def compiled?(code, name)
  code.match?(/^(?:static )?mrb_value #{name}\(mrb_state\* M/)
end

Dir.mktmpdir('bc2cpp-block-zsuper') do |dir|
  code, err = Bc2cppFixtureRuntime.generate(SOURCE, dir, core: true, only_owners: OWNERS)
  suite.check('methods with a bare super in a block compile',
              %w[BzKid_f_impl BzKid_g_impl BzWrap_f_impl].all? { |f| compiled?(code, f) })
  suite.check('the block calls the super method by name with the upvar parameters',
              code.include?('mrb_value bc2cpp_zsuper_argv[] = {(*bc2cpp_upvar_1), (*bc2cpp_upvar_2)};'))
  suite.check('a method that reassigns its parameter stays on the interpreter', !compiled?(code, 'BzKid_k_impl'))

  build = ENV['CC_GENERATED_ONLY'] == '1' ? nil : Bc2cppFixtureRuntime.full_or_build
  if build.nil?
    puts '  SKIP block zsuper behaviour: needs a full-core libmruby (BC2CPP_MRUBY_FULL, or rake and g++)'
  else
    scenario = <<~CPP
      static mrb_value bz_new(mrb_state* M, const char* cls) {
        return mrb_funcall_argv(M, mrb_obj_value(mrb_class_get(M, cls)), mrb_intern_lit(M, "new"), 0, nullptr);
      }
      static int scenario(mrb_state* M) {
        mrb_value u = bz_new(M, "BzUser");
        mrb_value kid = bz_new(M, "BzKid");
        mrb_value pre = bz_new(M, "BzPre");
        const char* kid_calls[] = {"kid_f", "kid_fb", "kid_g", "kid_gb", "kid_k"};
        for (const char* m : kid_calls) call(M, m, u, m, 1, &kid);
        call(M, "pre_f", u, "pre_f", 1, &pre);
        call(M, "pre_fb", u, "pre_fb", 1, &pre);
        return 0;
      }
    CPP
    built, output = Bc2cppFixtureRuntime.run(dir, err, OWNERS, scenario, build: build, full: true)
    suite.check('fixture builds and runs', built)
    sections = Bc2cppFixtureRuntime.sections(output)
    plain = ->(lines) { lines.to_a.reject { |l| l.start_with?('  dispatches=') } }
    interpreted = plain.call(sections['interpreted'])
    compiled = plain.call(sections['compiled'])
    suite.check('the interpreter forwards the parameters and the block',
                interpreted.include?('kid_f => [:kid, [:base, 1, :noblk]]') &&
                interpreted.include?('kid_fb => [:kid, [:base, 1, 7]]') &&
                interpreted.include?('kid_gb => [[:bg, 3, 4, true], 3]') &&
                interpreted.include?('kid_k => [:bk, 2]') &&
                interpreted.include?('pre_fb => [:wrap, [:base, 3, 8]]'))
    suite.check('compiled matches interpreted', compiled == interpreted)
  end
end

suite.finish!
