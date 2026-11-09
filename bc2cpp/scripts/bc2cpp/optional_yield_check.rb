#!/usr/bin/env ruby
# frozen_string_literal: true

# OPTIONAL_REST_YIELD (optional_rest_yield?): a method with optional and/or rest parameters that `yield`s without
# declaring `&blk` takes the call's block as an extra parameter, extracted by the wrapper with `&` after the rest. The
# check reads the generated code (no #error for these methods, and the block is passed through) and, with a full-core
# libmruby, runs the methods interpreted and compiled. BC2CPP_OPTIONAL_REST_YIELD=0 keeps the #error; that is the
# negative control. Needs MRBC; the behaviour part needs BC2CPP_MRUBY_FULL, or rake and a C++ compiler.
ENV['BC2CPP_SIG_DIRS'] = ''

require 'tmpdir'
require_relative 'check_support'
require_relative 'fixture_runtime'

suite = FixtureCheck.new('optional_yield_check')
suite.require_mrbc!

SOURCE = <<~RUBY
  class OyYield
    def rest_yield(*ops)
      yield ops.size
    end

    def opt_yield(a, opt = 1)
      yield a + opt
    end

    def drive
      [rest_yield(1, 2) { |n| n + 10 }, opt_yield(3) { |n| n * 2 }, opt_yield(3, 5) { |n| n - 1 }, rest_yield { |n| n }]
    end

    def bare(a)
      opt_yield(a)
    end
  end
RUBY

OWNERS = %w[OyYield].freeze

Dir.mktmpdir('bc2cpp-optional-yield') do |dir|
  code, err = Bc2cppFixtureRuntime.generate(SOURCE, dir, core: true, only_owners: OWNERS)
  suite.check('the optional and rest yield methods compile without #error',
              code.include?('mrb_value OyYield_rest_yield_impl(mrb_state* M') &&
              code.include?('mrb_value OyYield_opt_yield_impl(mrb_state* M') &&
              !code.lines.any? { |l| l.include?('#error') && l.include?('OyYield') })
  suite.check('the block is extracted with & after the rest, and passed to the impl',
              code.include?('mrb_get_args(M, "*&", &bc2cpp_rest_ptr, &bc2cpp_rest_len, &bc2cpp_blk);') &&
              code.include?('return bc2cpp_cfunc_result({M, M->gc.arena_idx, OyYield_rest_yield_impl(M, self, ops, bc2cpp_blk)});'))

  build = ENV['CC_GENERATED_ONLY'] == '1' ? nil : Bc2cppFixtureRuntime.full_or_build
  if build.nil?
    puts '  SKIP optional yield behaviour: needs a full-core libmruby (BC2CPP_MRUBY_FULL, or rake and g++)'
  else
    scenario = <<~CPP
      static mrb_value oy_new(mrb_state* M) {
        return mrb_funcall_argv(M, mrb_obj_value(mrb_class_get(M, "OyYield")), mrb_intern_lit(M, "new"), 0, nullptr);
      }
      static int scenario(mrb_state* M) {
        mrb_value three[] = {mrb_fixnum_value(3)};
        mrb_value obj = oy_new(M);
        call(M, "drive", obj, "drive", 0, nullptr);
        call(M, "bare", obj, "bare", 1, three);
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
    suite.check('the block values follow the yield arguments',
                interpreted.include?('drive => [12, 8, 7, 0]'))
    suite.check('a bare yield with no block raises LocalJumpError',
                interpreted.include?('bare => raised LocalJumpError'))
    suite.check('compiled matches interpreted', compiled == interpreted)
  end
end

suite.finish!
