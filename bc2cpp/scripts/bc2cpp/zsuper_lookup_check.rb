#!/usr/bin/env ruby
# frozen_string_literal: true

# ZSUPER_LOOKUP (zsuper_lookup_plan): a bare `super` into a method no direct rule calls -- here the C methods
# Array#initialize and Array#push -- is looked up from the superclass at run time and called with the arguments
# OP_ARGARY would pack (mandatory and optional ones, a rest Array's elements). A method some caller may hand a block
# it would forward (method_missing gets the missing call's block) keeps the `#error`. The check reads the generated
# calls and runs the methods interpreted and compiled. Needs MRBC and a full-core libmruby (BC2CPP_MRUBY_FULL, or
# rake and a C++ compiler).
ENV['BC2CPP_SIG_DIRS'] = ''

require 'tmpdir'
require_relative 'check_support'
require_relative 'fixture_runtime'

suite = FixtureCheck.new('zsuper_lookup_check')
suite.require_mrbc!

SOURCE = <<~RUBY
  class ZlArr < Array
    def initialize(n, v = 0)
      super
    end

    def push(first, *rest)
      super
    end
  end

  class ZlMm
    def method_missing(name, *args)
      return [:hi, args] if name == :zl_hi

      super
    end
  end
RUBY

OWNERS = %w[ZlArr ZlMm].freeze

Dir.mktmpdir('bc2cpp-zsuper-lookup') do |dir|
  code, err = Bc2cppFixtureRuntime.generate(SOURCE, dir, core: true, only_owners: OWNERS)
  body = lambda do |fn|
    i = code.index("mrb_value #{fn}(mrb_state* M")
    i && code[i...(code.index(/^(?:mrb_value|static|\[\[)/, i + 10) || code.size)]
  end
  suite.check('a bare super into a C method compiles to the run-time lookup',
              %w[ZlArr_initialize_impl ZlArr_push_impl].all? { |fn| body.call(fn)&.include?('bc2cpp_zsuper_args') })
  suite.check('a rest parameter is spliced, as OP_ARGARY does',
              body.call('ZlArr_push_impl').to_s.include?('if (mrb_array_p(r2)) mrb_ary_concat(M, bc2cpp_zsuper_args, r2);'))
  suite.check('a method whose callers may pass a block keeps its bytecode',
              !code.include?('mrb_value ZlMm_method_missing_impl(mrb_state* M'))

  build = ENV['CC_GENERATED_ONLY'] == '1' ? nil : Bc2cppFixtureRuntime.full_or_build
  if build.nil?
    puts '  SKIP zsuper lookup behaviour: needs a full-core libmruby (BC2CPP_MRUBY_FULL, or rake and g++)'
  else
    scenario = <<~CPP
      static mrb_value zl_new(mrb_state* M, const char* cls, mrb_int argc, const mrb_value* argv) {
        return mrb_funcall_argv(M, mrb_obj_value(mrb_class_get(M, cls)), mrb_intern_lit(M, "new"), argc, argv);
      }
      static int scenario(mrb_state* M) {
        mrb_value one[] = {mrb_fixnum_value(2)};
        mrb_value two[] = {mrb_fixnum_value(3), mrb_fixnum_value(7)};
        call(M, "arr_default", zl_new(M, "ZlArr", 1, one), "to_a");
        mrb_value arr = zl_new(M, "ZlArr", 2, two);
        mrb_value three[] = {mrb_fixnum_value(1), mrb_fixnum_value(2), mrb_fixnum_value(3)};
        call(M, "arr_push", arr, "push", 3, three);
        mrb_value mm = zl_new(M, "ZlMm", 0, nullptr);
        call(M, "mm_listed", mm, "zl_hi", 2, two);
        call(M, "mm_other", mm, "zl_nope", 2, two);
        return 0;
      }
    CPP
    built, output = Bc2cppFixtureRuntime.run(dir, err, OWNERS, scenario, build: build, full: true)
    suite.check('fixture builds and runs', built)
    sections = Bc2cppFixtureRuntime.sections(output)
    plain = ->(lines) { lines.to_a.reject { |l| l.start_with?('  dispatches=') } }
    interpreted = plain.call(sections['interpreted'])
    compiled = plain.call(sections['compiled'])
    suite.check('every call ran', interpreted.size == 4)
    suite.check('the superclass methods answered with the arguments',
                interpreted.include?('arr_default => [0, 0]') && interpreted.include?('arr_push => [7, 7, 7, 1, 2, 3]'))
    suite.check('compiled matches interpreted', compiled == interpreted)
  end
end

suite.finish!
