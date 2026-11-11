#!/usr/bin/env ruby
# frozen_string_literal: true

# MIXED_REST_BLOCK (mixed_rest_unpack): a literal block `{ |x, *r| }` captures a local and compiles as a block fallback.
# Its body takes x and the rest Array, bound as vm.c binds them: one Array argument is spread over the parameters, and
# the rest takes what is left. The check reads the generated code (no #error for these blocks) and, with a full-core
# libmruby, runs the blocks interpreted and compiled. Needs MRBC; the behaviour part needs BC2CPP_MRUBY_FULL, or rake
# and a C++ compiler.
ENV['BC2CPP_SIG_DIRS'] = ''

require 'tmpdir'
require_relative 'check_support'
require_relative 'fixture_runtime'

suite = FixtureCheck.new('block_rest_mixed_check')
suite.require_mrbc!

SOURCE = <<~RUBY
  class MxPairs
    def collect_mixed(arr)
      out = []
      arr.each { |x, *r| out << [x, r] }
      out
    end

    def pairs_yielder
      yield 1, 2, 3
      yield [4, 5]
    end

    def two
      out = []
      pairs_yielder { |x, *rest| out << [x, rest] }
      out
    end
  end
RUBY

OWNERS = %w[MxPairs].freeze

Dir.mktmpdir('bc2cpp-block-rest-mixed') do |dir|
  code, err = Bc2cppFixtureRuntime.generate(SOURCE, dir, core: true, only_owners: OWNERS)
  suite.check('the mixed-rest blocks compile without #error',
              code.include?('mrb_value MxPairs_collect_mixed_impl(mrb_state* M') &&
              code.include?('mrb_value MxPairs_two_impl(mrb_state* M') &&
              !code.lines.any? { |l| l.include?('#error') && (l.include?('BLOCK') || l.include?('SENDB')) })

  build = ENV['CC_GENERATED_ONLY'] == '1' ? nil : Bc2cppFixtureRuntime.full_or_build
  if build.nil?
    puts '  SKIP mixed rest block behaviour: needs a full-core libmruby (BC2CPP_MRUBY_FULL, or rake and g++)'
  else
    scenario = <<~CPP
      static mrb_value mx_new(mrb_state* M) {
        return mrb_funcall_argv(M, mrb_obj_value(mrb_class_get(M, "MxPairs")), mrb_intern_lit(M, "new"), 0, nullptr);
      }
      static int scenario(mrb_state* M) {
        mrb_value first[] = {mrb_fixnum_value(1), mrb_fixnum_value(2), mrb_fixnum_value(3)};
        mrb_value a1 = mrb_ary_new_from_values(M, 3, first);
        mrb_value five[] = {mrb_fixnum_value(5)};
        mrb_value a5 = mrb_ary_new_from_values(M, 1, five);
        mrb_value a0 = mrb_ary_new(M);
        mrb_value top[] = {a1, mrb_fixnum_value(4), a5, a0};
        mrb_value arr = mrb_ary_new_from_values(M, 4, top);
        mrb_value obj = mx_new(M);
        call(M, "collect_mixed", obj, "collect_mixed", 1, &arr);
        call(M, "two", obj, "two", 0, nullptr);
        return 0;
      }
    CPP
    built, output = Bc2cppFixtureRuntime.run(dir, err, OWNERS, scenario, build: build, full: true)
    suite.check('fixture builds and runs', built)
    sections = Bc2cppFixtureRuntime.sections(output)
    plain = ->(lines) { lines.to_a.reject { |l| l.start_with?('  dispatches=') } }
    interpreted = plain.call(sections['interpreted'])
    compiled = plain.call(sections['compiled'])
    suite.check('both calls ran', interpreted.size == 2)
    suite.check('the autosplat and the rest follow vm.c',
                interpreted.include?('collect_mixed => [[1, [2, 3]], [4, []], [5, []], [nil, []]]') &&
                interpreted.include?('two => [[1, [2, 3]], [4, [5]]]'))
    suite.check('compiled matches interpreted', compiled == interpreted)
  end
end

suite.finish!
