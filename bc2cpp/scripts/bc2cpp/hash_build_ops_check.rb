#!/usr/bin/env ruby
# frozen_string_literal: true

# HASHCAT / HASHADD (codegen_insn.rb): the Hash built by `{**h, k: v}` is made by the same steps as vm.c. The check reads
# the generated code (no #error for the literal form) and, with a full-core libmruby, runs the literal forms interpreted
# and compiled: a splatted Hash, then a literal pair, with the later key winning; and a non-Hash splat, which raises the
# same TypeError in both. Needs MRBC; the behaviour part needs BC2CPP_MRUBY_FULL, or rake and a C++ compiler.
ENV['BC2CPP_SIG_DIRS'] = ''

require 'tmpdir'
require_relative 'check_support'
require_relative 'fixture_runtime'

suite = FixtureCheck.new('hash_build_ops_check')
suite.require_mrbc!

SOURCE = <<~RUBY
  class HashBuild
    def merged(h)
      { **h, k: 2 }
    end
  end
RUBY

OWNERS = %w[HashBuild].freeze

Dir.mktmpdir('bc2cpp-hash-build') do |dir|
  code, err = Bc2cppFixtureRuntime.generate(SOURCE, dir, core: true, only_owners: OWNERS)
  suite.check('the literal merge compiles without #error',
              code.include?('mrb_value HashBuild_merged_impl(mrb_state* M') &&
              code.include?('mrb_hash_merge(M, r') &&
              code.include?('mrb_hash_set(M, r') &&
              !code.lines.any? { |l| l.include?('#error') && (l.include?('HASH') || l.include?('merged')) })

  build = ENV['CC_GENERATED_ONLY'] == '1' ? nil : Bc2cppFixtureRuntime.full_or_build
  if build.nil?
    puts '  SKIP hash build behaviour: needs a full-core libmruby (BC2CPP_MRUBY_FULL, or rake and g++)'
  else
    scenario = <<~CPP
      static mrb_value hb_new(mrb_state* M) {
        return mrb_funcall_argv(M, mrb_obj_value(mrb_class_get(M, "HashBuild")), mrb_intern_lit(M, "new"), 0, nullptr);
      }
      static int scenario(mrb_state* M) {
        mrb_value obj = hb_new(M);
        mrb_value h = mrb_hash_new(M);
        mrb_hash_set(M, h, mrb_symbol_value(mrb_intern_lit(M, "k")), mrb_fixnum_value(9));
        mrb_hash_set(M, h, mrb_symbol_value(mrb_intern_lit(M, "x")), mrb_fixnum_value(1));
        mrb_value argv[] = {h};
        call(M, "merged_later_key_wins", obj, "merged", 1, argv);
        mrb_value bad[] = {mrb_fixnum_value(3)};
        call(M, "merged_non_hash", obj, "merged", 1, bad);
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
    suite.check('the later literal key wins over the splatted Hash',
                interpreted.include?('merged_later_key_wins => {k: 2, x: 1}'))
    suite.check('a non-Hash splat raises the same error', interpreted.any? { |l| l.start_with?('merged_non_hash => raised') })
    suite.check('compiled matches interpreted', compiled == interpreted)
  end
end

suite.finish!
