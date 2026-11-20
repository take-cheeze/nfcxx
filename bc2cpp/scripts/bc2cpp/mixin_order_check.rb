#!/usr/bin/env ruby
# frozen_string_literal: true

# MIXIN_ORDER_UNKNOWN (closed_world_lookup_target): a class's prepended (or included) modules are listed in the order the
# generator read their sites, which is the run-time order only within one file; across files the require graph decides.
# With two of them defining the same name, a self call must not be bound statically to either: in bc2cpp-self,
# CodeGen#compile_timed's `compile_method(label)` was bound to StaticOwnerArms#compile_method and skipped the
# ArmsCompleteElse wrapper prepended after it. One definer among the mixins is still bound. The behaviour part needs
# BC2CPP_MRUBY_FULL, or rake and a C++ compiler.
ENV['BC2CPP_SIG_DIRS'] = ''

require 'tmpdir'
require_relative 'check_support'
require_relative 'fixture_runtime'

suite = FixtureCheck.new('mixin_order_check')
suite.require_mrbc!

SOURCE = <<~RUBY
  class MoBase
    def run(x) = [:base, x]
    def go(x) = run(x)
    def solo(x) = [:solo, x]
    def go_solo(x) = solo(x)
  end
  module MoFirst
    def run(x) = [:first, super]
  end
  module MoSecond
    def run(x) = [:second, super]
    def solo(x) = [:wrapped, super]
  end
  MoBase.prepend(MoFirst)
  MoBase.prepend(MoSecond)
RUBY

OWNERS = %w[MoBase MoFirst MoSecond].freeze

def body(code, name)
  code[/^(?:static )?mrb_value #{name}\(mrb_state\* M.*?^\}/m].to_s
end

Dir.mktmpdir('bc2cpp-mixin-order') do |dir|
  code, err = Bc2cppFixtureRuntime.generate(SOURCE, dir, core: true, only_owners: OWNERS)
  go = body(code, 'MoBase_go_impl')
  # Exact-class POLY arms naming the modules are fine: bc2cpp_class_is never holds for a module, so the send dispatches.
  suite.check('a self call with two prepended definers is not resolved statically to either',
              %w[CLOSED_WORLD_SELF LEXICAL_SELF MONO].none? { |rule| go.include?("#{rule} :run") })
  suite.check('a self call with one prepended definer is still bound to it', body(code, 'MoBase_go_solo_impl').include?('MoSecond_solo_impl('))

  build = ENV['CC_GENERATED_ONLY'] == '1' ? nil : Bc2cppFixtureRuntime.full_or_build
  if build.nil?
    puts '  SKIP mixin order behaviour: needs a full-core libmruby (BC2CPP_MRUBY_FULL, or rake and g++)'
  else
    scenario = <<~CPP
      static int scenario(mrb_state* M) {
        mrb_value o = mrb_funcall_argv(M, mrb_obj_value(mrb_class_get(M, "MoBase")), mrb_intern_lit(M, "new"), 0, nullptr);
        mrb_value one = mrb_fixnum_value(1);
        call(M, "go", o, "go", 1, &one);
        call(M, "go_solo", o, "go_solo", 1, &one);
        return 0;
      }
    CPP
    built, output = Bc2cppFixtureRuntime.run(dir, err, OWNERS, scenario, build: build, full: true)
    suite.check('fixture builds and runs', built)
    sections = Bc2cppFixtureRuntime.sections(output)
    plain = ->(lines) { lines.to_a.reject { |l| l.start_with?('  dispatches=') } }
    interpreted = plain.call(sections['interpreted'])
    suite.check('the interpreter runs the last prepended module first',
                interpreted.include?('go => [:second, [:first, [:base, 1]]]') && interpreted.include?('go_solo => [:wrapped, [:solo, 1]]'))
    suite.check('compiled matches interpreted', plain.call(sections['compiled']) == interpreted)
  end
end

suite.finish!
