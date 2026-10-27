#!/usr/bin/env ruby
# frozen_string_literal: true

# GETCONST's compiled lexical lookup (emit_const_lookup_helper) follows mrb_vm_const_get: the own table of every
# lexical scope, innermost first and Object last, then the innermost scope's ancestors (and Object's, for a module),
# then const_missing. Each read below sits where two of those steps disagree; the check runs them interpreted and
# compiled and compares the output. Needs MRBC and a full-core libmruby (BC2CPP_MRUBY_FULL, or rake and a C++
# compiler).
ENV['BC2CPP_SIG_DIRS'] = ''

require 'tmpdir'
require_relative 'check_support'
require_relative 'fixture_runtime'

suite = FixtureCheck.new('const_lexical_order_check')
suite.require_mrbc!

SOURCE = <<~RUBY
  W = 0
  module LoMix
    MIXED = :mixin
  end
  class LoBase
    W = :base
    ONLY_BASE = :only_base
    MIXED = :base
  end
  module LoOuter
    W = :outer
    class LoSub < LoBase
      include LoMix
      def outer_before_super = W
      def super_when_outer_lacks = ONLY_BASE
      def mixin_before_super = MIXED
      def missing = LO_NOWHERE
    end
    module LoMod
      def self.object_from_module = String
    end
  end
  class LoTop < LoBase
    def object_before_super = W
  end
RUBY

OWNERS = %w[LoOuter::LoSub LoOuter::LoMod.singleton LoTop].freeze

Dir.mktmpdir('bc2cpp-const-lexical-order') do |dir|
  code, err = Bc2cppFixtureRuntime.generate(SOURCE, dir, core: true, only_owners: OWNERS)
  suite.check('the reads compile to the lexical lookup', code.include?('bc2cpp_const_inherited('))

  build = ENV['CC_GENERATED_ONLY'] == '1' ? nil : Bc2cppFixtureRuntime.full_or_build
  if build.nil?
    puts '  SKIP const lexical order behaviour: needs a full-core libmruby (BC2CPP_MRUBY_FULL, or rake and g++)'
  else
    scenario = <<~CPP
      static mrb_value lo_const(mrb_state* M, mrb_value scope, const char* name) {
        return mrb_const_get(M, scope, mrb_intern_cstr(M, name));
      }
      static int scenario(mrb_state* M) {
        mrb_value object = mrb_obj_value(M->object_class);
        mrb_value outer = lo_const(M, object, "LoOuter");
        mrb_value sub = mrb_obj_new(M, mrb_class_ptr(lo_const(M, outer, "LoSub")), 0, nullptr);
        mrb_value top = mrb_obj_new(M, mrb_class_ptr(lo_const(M, object, "LoTop")), 0, nullptr);
        for (const char* meth : {"outer_before_super", "super_when_outer_lacks", "mixin_before_super", "missing"}) {
          call(M, meth, sub, meth);
        }
        call(M, "object_before_super", top, "object_before_super");
        call(M, "object_from_module", lo_const(M, outer, "LoMod"), "object_from_module");
        return 0;
      }
    CPP
    built, output = Bc2cppFixtureRuntime.run(dir, err, OWNERS, scenario, build: build, full: true)
    suite.check('fixture builds and runs', built)
    sections = Bc2cppFixtureRuntime.sections(output)
    plain = ->(lines) { lines.to_a.reject { |l| l.start_with?('  dispatches=') } }
    interpreted = plain.call(sections['interpreted'])
    compiled = plain.call(sections['compiled'])
    suite.check('every read ran', interpreted.size == 6 && compiled.size == 6)
    suite.check('an outer scope is read before a superclass', interpreted.include?('outer_before_super => :outer'))
    suite.check('a missing name raises', interpreted.include?('missing => raised NameError'))
    suite.check('interpreted and compiled runs print the same', interpreted == compiled)
    interpreted.zip(compiled).reject { |a, b| a == b }.each do |a, b|
      puts "    interpreted: #{a}\n    compiled:    #{b}"
    end
  end
end

suite.finish!
