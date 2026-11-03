#!/usr/bin/env ruby
# frozen_string_literal: true

# KEYWORD_REST_ONLY (keyword_rest_call, the entry branch in compile_method): a method whose only keyword parameter is
# `**opts` takes its keyword hash as one extra parameter, built by a direct call from the literal pairs, or read from
# the call info when a dynamic send (no keywords, or a keyword call through mrb_funcall) reaches the entry. The check
# reads the generated calls and, with a full-core libmruby, runs the methods interpreted and compiled. Needs MRBC;
# the behaviour part needs BC2CPP_MRUBY_FULL, or rake and a C++ compiler.
ENV['BC2CPP_SIG_DIRS'] = ''

require 'tmpdir'
require_relative 'check_support'
require_relative 'fixture_runtime'

suite = FixtureCheck.new('keyword_send_check')
suite.require_mrbc!

SOURCE = <<~RUBY
  class KwBox
    def scan(items, **opts)
      items.size + (opts[:bias] || 0) + opts.size * 10
    end

    def pick(items, mode: 1, strict: false)
      items.map { |x| x + mode }
    end

    def run(a)
      [scan([1, 2], bias: 5), scan([1]), scan([1], bias: 2, other: 3), pick([1, 2], mode: 3, strict: true), pick([4])]
    end
  end
RUBY

OWNERS = %w[KwBox].freeze

Dir.mktmpdir('bc2cpp-keyword-send') do |dir|
  code, err = Bc2cppFixtureRuntime.generate(SOURCE, dir, core: true, only_owners: OWNERS)
  suite.check('the keyword-rest and named-keyword calls compile without #error',
              code.include?('mrb_value KwBox_scan_impl(mrb_state* M') &&
              code.include?('mrb_hash_set(M, bc2cpp_kwrest') &&
              !code.lines.any? { |l| l.include?('#error') && l.include?('SEND') })

  build = ENV['CC_GENERATED_ONLY'] == '1' ? nil : Bc2cppFixtureRuntime.full_or_build
  if build.nil?
    puts '  SKIP keyword send behaviour: needs a full-core libmruby (BC2CPP_MRUBY_FULL, or rake and g++)'
  else
    scenario = <<~CPP
      static mrb_value kw_new(mrb_state* M) {
        return mrb_funcall_argv(M, mrb_obj_value(mrb_class_get(M, "KwBox")), mrb_intern_lit(M, "new"), 0, nullptr);
      }
      static int scenario(mrb_state* M) {
        mrb_value one_v[] = {mrb_fixnum_value(1)};
        mrb_value two_v[] = {mrb_fixnum_value(1), mrb_fixnum_value(2)};
        mrb_value one = mrb_ary_new_from_values(M, 1, one_v);
        mrb_value two = mrb_ary_new_from_values(M, 2, two_v);
        mrb_value obj = kw_new(M);
        call(M, "run", obj, "run", 1, &one);
        call(M, "scan_plain", obj, "scan", 1, &one);
        call(M, "scan_two", obj, "scan", 1, &two);
        return 0;
      }
    CPP
    built, output = Bc2cppFixtureRuntime.run(dir, err, OWNERS, scenario, build: build, full: true)
    suite.check('fixture builds and runs', built)
    sections = Bc2cppFixtureRuntime.sections(output)
    plain = ->(lines) { lines.to_a.reject { |l| l.start_with?('  dispatches=') } }
    interpreted = plain.call(sections['interpreted'])
    compiled = plain.call(sections['compiled'])
    suite.check('every call ran', interpreted.size == 3)
    suite.check('the keyword values reach the callee as the hash',
                interpreted.include?('run => [17, 1, 23, [4, 5], [5]]') &&
                interpreted.include?('scan_plain => 1') &&
                interpreted.include?('scan_two => 2'))
    suite.check('compiled matches interpreted', compiled == interpreted)
  end
end

suite.finish!
