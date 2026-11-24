#!/usr/bin/env ruby
# frozen_string_literal: true

# PREPENDED_OVERRIDE (prepended_override?): a module prepended to a class answers a send before the class's own
# definition, so neither a runtime-class-checked arm (POLY_SMALL_N `bc2cpp_class_is`) nor a lexical-self binding
# (LEXICAL_SELF) may call that class's body directly when a prepended module defines the name. The fixture prepends
# PpOver#foo to PpBase and sends :foo with an explicit receiver, with implicit self in PpBase, and with implicit self
# in a subclass; every one must reach PpOver#foo, whose super then reaches PpBase#foo, as the interpreter does.
# The behaviour part needs BC2CPP_MRUBY_FULL, or rake and a C++ compiler.
ENV['BC2CPP_SIG_DIRS'] = ''

require 'tmpdir'
require_relative 'check_support'
require_relative 'fixture_runtime'
require_relative '../../tools/bc2cpp/codegen'
require_relative '../../tools/bc2cpp/codegen_ivar_poly'

suite = FixtureCheck.new('prepended_override_check')
suite.require_mrbc!

# Unknown owners must still refuse when no prepend list is recorded. Nonempty lists
# still walk included/prepended modules, tolerate cycles, and leave frozen facts intact.
probe = CodeGen.allocate
probe.instance_variable_set(:@registry, { 'foo' => [Struct.new(:owner).new('Over')] })
probe.instance_variable_set(:@unknown_mixins, Set['Unknown', 'Mystery'])
probe.instance_variable_set(:@prepended_modules, {
  'Empty' => [].freeze, 'Wrapped' => ['Wrapper'].freeze,
  'Cycle' => ['CycleMod'].freeze, 'IndirectUnknown' => ['Mystery'].freeze
})
probe.instance_variable_set(:@included_modules, {
  'Wrapper' => ['Over'].freeze, 'CycleMod' => ['CycleMod'].freeze, 'IncludedOnly' => ['Over'].freeze
})
[['Absent', 'foo', false], ['Empty', 'foo', false], ['Unknown', 'foo', true],
 ['Wrapped', 'foo', true], ['Wrapped', 'other', false], ['Cycle', 'foo', false],
 ['IndirectUnknown', 'foo', true], ['IncludedOnly', 'foo', false]].each do |owner, name, expected|
  suite.check("#{owner}##{name}: prepend lookup preserves #{expected}", probe.prepended_override?(owner, name) == expected)
end

SOURCE = <<~RUBY
  class PpBase
    def foo(x) = [:base, x]
    def via_self(x) = foo(x)
  end

  class PpOther
    def foo(x) = [:other, x]
  end

  module PpOver
    def foo(x) = [:over, super]
  end

  PpBase.prepend(PpOver)

  class PpUser
    def call(o) = o.foo(1)
  end

  class PpKid < PpBase
    def kid_self(x) = foo(x)
  end
RUBY

OWNERS = %w[PpBase PpOther PpOver PpUser PpKid].freeze

def function_body(code, name)
  code[/^(?:static )?mrb_value #{name}\(mrb_state\* M.*?^\}/m].to_s
end

Dir.mktmpdir('bc2cpp-prepended-override') do |dir|
  code, err = Bc2cppFixtureRuntime.generate(SOURCE, dir, core: true, only_owners: OWNERS)
  suite.check('the explicit-receiver send has no exact-class arm calling the prepended class body',
              !function_body(code, 'PpUser_call_impl').include?('PpBase_foo_impl('))
  suite.check('the implicit-self send is not bound to the prepended class body',
              !function_body(code, 'PpBase_via_self_impl').include?('PpBase_foo_impl('))

  build = ENV['CC_GENERATED_ONLY'] == '1' ? nil : Bc2cppFixtureRuntime.full_or_build
  if build.nil?
    puts '  SKIP prepended override behaviour: needs a full-core libmruby (BC2CPP_MRUBY_FULL, or rake and g++)'
  else
    scenario = <<~CPP
      static mrb_value pp_new(mrb_state* M, const char* cls) {
        return mrb_funcall_argv(M, mrb_obj_value(mrb_class_get(M, cls)), mrb_intern_lit(M, "new"), 0, nullptr);
      }
      static int scenario(mrb_state* M) {
        mrb_value u = pp_new(M, "PpUser");
        mrb_value b = pp_new(M, "PpBase");
        mrb_value o = pp_new(M, "PpOther");
        mrb_value k = pp_new(M, "PpKid");
        mrb_value one = mrb_fixnum_value(1);
        call(M, "call_base", u, "call", 1, &b);
        call(M, "call_other", u, "call", 1, &o);
        call(M, "via_self", b, "via_self", 1, &one);
        call(M, "kid_self", k, "kid_self", 1, &one);
        call(M, "via_self_kid", k, "via_self", 1, &one);
        return 0;
      }
    CPP
    built, output = Bc2cppFixtureRuntime.run(dir, err, OWNERS, scenario, build: build, full: true)
    suite.check('fixture builds and runs', built)
    sections = Bc2cppFixtureRuntime.sections(output)
    plain = ->(lines) { lines.to_a.reject { |l| l.start_with?('  dispatches=') } }
    interpreted = plain.call(sections['interpreted'])
    compiled = plain.call(sections['compiled'])
    suite.check('the interpreter reaches the prepended module first',
                %w[call_base via_self kid_self via_self_kid].all? { |n| interpreted.include?("#{n} => [:over, [:base, 1]]") } &&
                interpreted.include?('call_other => [:other, 1]'))
    suite.check('compiled matches interpreted', compiled == interpreted)
  end
end

suite.finish!
