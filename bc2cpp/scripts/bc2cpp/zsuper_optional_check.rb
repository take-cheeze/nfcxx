#!/usr/bin/env ruby
# frozen_string_literal: true

# ZSUPER_GENERAL_SUPPORT with optional parameters (zsuper_forward_plan): a bare `super` in a method with optionals
# forwards every parameter, defaults already filled in, to the superclass `_impl`, which takes as many mandatory
# arguments or fewer and the rest as optionals. The call passes nil for the target's optionals not forwarded and
# the count it did. The check reads the generated call and runs the constructors interpreted and compiled. Needs
# MRBC and a full-core libmruby (BC2CPP_MRUBY_FULL, or rake and a C++ compiler).
ENV['BC2CPP_SIG_DIRS'] = ''

require 'tmpdir'
require_relative 'check_support'
require_relative 'fixture_runtime'

suite = FixtureCheck.new('zsuper_optional_check')
suite.require_mrbc!

SOURCE = <<~RUBY
  class ZoBase
    def initialize(a, b = 10, c = 20)
      @v = [a, b, c]
    end

    def v = @v
  end

  class ZoFewer < ZoBase
    def initialize(a, b = 5)
      super
    end
  end

  class ZoOptional < ZoBase
    def initialize(a = 1, b = 2, c = 3)
      super
    end
  end
RUBY

OWNERS = %w[ZoBase ZoFewer ZoOptional].freeze

Dir.mktmpdir('bc2cpp-zsuper-optional') do |dir|
  code, err = Bc2cppFixtureRuntime.generate(SOURCE, dir, core: true, only_owners: OWNERS)
  suite.check('both constructors with a bare super compile',
              code.include?('mrb_value ZoFewer_initialize_impl(mrb_state* M') &&
              code.include?('mrb_value ZoOptional_initialize_impl(mrb_state* M'))
  suite.check('fewer forwarded than the target takes: nil for the rest, and the count given',
              code.include?('ZoBase_initialize_impl(M, self, r1, r2, mrb_nil_value(), 1)'))
  suite.check('as many as the target takes: every one given', code.include?('ZoBase_initialize_impl(M, self, r1, r2, r3, 2)'))

  build = ENV['CC_GENERATED_ONLY'] == '1' ? nil : Bc2cppFixtureRuntime.full_or_build
  if build.nil?
    puts '  SKIP zsuper optional behaviour: needs a full-core libmruby (BC2CPP_MRUBY_FULL, or rake and g++)'
  else
    scenario = <<~CPP
      static void zo_new(mrb_state* M, const char* cls, mrb_int argc, const mrb_value* argv, const char* label) {
        struct RClass* c = mrb_class_get(M, cls);
        mrb_value obj = mrb_obj_new(M, c, argc, argv);
        call(M, label, obj, "v");
      }
      static int scenario(mrb_state* M) {
        mrb_value one[] = {mrb_fixnum_value(7)};
        mrb_value two[] = {mrb_fixnum_value(7), mrb_fixnum_value(8)};
        zo_new(M, "ZoFewer", 1, one, "fewer_one");
        zo_new(M, "ZoFewer", 2, two, "fewer_two");
        zo_new(M, "ZoOptional", 0, nullptr, "optional_none");
        zo_new(M, "ZoOptional", 1, one, "optional_one");
        return 0;
      }
    CPP
    built, output = Bc2cppFixtureRuntime.run(dir, err, OWNERS, scenario, build: build, full: true)
    suite.check('fixture builds and runs', built)
    sections = Bc2cppFixtureRuntime.sections(output)
    plain = ->(lines) { lines.to_a.reject { |l| l.start_with?('  dispatches=') } }
    interpreted = plain.call(sections['interpreted'])
    compiled = plain.call(sections['compiled'])
    suite.check('every constructor ran', interpreted.size == 4)
    suite.check('the defaults of both methods apply',
                interpreted.include?('fewer_one => [7, 5, 20]') && interpreted.include?('optional_none => [1, 2, 3]'))
    suite.check('compiled matches interpreted', compiled == interpreted)
  end
end

suite.finish!
