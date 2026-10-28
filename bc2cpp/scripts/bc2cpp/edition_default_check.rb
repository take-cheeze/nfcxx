#!/usr/bin/env ruby
# frozen_string_literal: true

# EDITION_DEFAULT (mruby-lcf/mrblib/schema.rb, LCF.edition_default): the schema's edition-dependent defaults are the
# Symbols `:level_max` / `:exp_default`, which LCF.to_rb resolves through a compiled module function. They used to be
# `-> { LCF.level_max }` lambdas; a lambda made by a class body is bytecode, so each read of an absent field entered
# the VM twice (Proc#call, then the lambda). They are not objects of an engine class either: the registration proof
# gives up as soon as load-time code (and a class body's blocks count as that) instantiates one. The check takes the
# helper's real text out of lcf.rb, compiles it with the edition helpers it calls and a reader that mirrors
# LCF.to_rb's default step, and runs both interpreted and compiled. Needs MRBC and a full-core libmruby
# (BC2CPP_MRUBY_FULL, or rake and a C++ compiler).
ENV['BC2CPP_SIG_DIRS'] = ''

require 'tmpdir'
require_relative 'check_support'
require_relative 'fixture_runtime'

suite = FixtureCheck.new('edition_default_check')
suite.require_mrbc!

MRBLIB = File.expand_path('../../mruby-lcf/mrblib', __dir__)
LCF_TEXT = File.read(File.join(MRBLIB, 'lcf.rb'), encoding: 'UTF-8')
SCHEMA_TEXT = File.read(File.join(MRBLIB, 'schema.rb'), encoding: 'UTF-8')
LINES = LCF_TEXT.lines
FIRST = LINES.index { |l| l.start_with?('  def edition_default kind') }
LAST = FIRST && (FIRST...LINES.size).find { |i| LINES[i] == "  end\n" }
suite.check('lcf.rb defines LCF.edition_default', !FIRST.nil? && !LAST.nil?)
suite.check('no schema default is a lambda, and the two edition ones are Symbols',
            SCHEMA_TEXT.lines.none? { |l| l =~ /default: *->/ } &&
            SCHEMA_TEXT.include?('default: :level_max') && SCHEMA_TEXT.include?('default: :exp_default'))
suite.check('schema.rb creates no object for them (an engine class instantiated at load collapses the proof)',
            SCHEMA_TEXT.lines.reject { |l| l.strip.start_with?('#') }.none? { |l| l.include?('EditionDefault') })
suite.check("LCF.to_rb resolves a Symbol default before it treats a default as callable",
            LCF_TEXT.include?("      return edition_default(dv) if dv.is_a?(Symbol)\n      return dv.respond_to?(:call) ? dv.call : dv\n"))
suite.finish! if FIRST.nil? || LAST.nil?

HELPER = LINES[FIRST..LAST].join

SOURCE = <<~RUBY
  module LCF
    MODE = 2000
    def level_max; MODE == 2003 ? 99 : 50 end
    def exp_default; MODE == 2003 ? 300 : 30 end

  #{HELPER.gsub("\n", "\n  ")}
    module_function :level_max, :exp_default, :edition_default
  end

  # LCF.to_rb's default step, as it reads a schema entry.
  class EdReader
    def default_of schema
      dv = schema[:default]
      return LCF.edition_default(dv) if dv.is_a?(Symbol)
      dv.respond_to?(:call) ? dv.call : dv
    end

    # A callable default is still honoured (the generic lazy default of lcf_test.rb).
    def lambda_case
      default_of({ default: -> { 7 } })
    end
  end
RUBY

OWNERS = ['LCF', 'LCF.singleton', 'EdReader'].freeze

Dir.mktmpdir('bc2cpp-edition-default') do |dir|
  code, err = Bc2cppFixtureRuntime.generate(SOURCE, dir, core: true, only_owners: OWNERS)
  suite.check('the helper and the reader compile',
              code.include?('mrb_value LCF_edition_default_impl(mrb_state* M') &&
              code.include?('mrb_value EdReader_default_of_impl(mrb_state* M'))

  build = ENV['CC_GENERATED_ONLY'] == '1' ? nil : Bc2cppFixtureRuntime.full_or_build
  if build.nil?
    puts '  SKIP edition default behaviour: needs a full-core libmruby (BC2CPP_MRUBY_FULL, or rake and g++)'
  else
    scenario = <<~CPP
      static mrb_value sym(mrb_state* M, const char* s) { return mrb_symbol_value(mrb_intern_cstr(M, s)); }
      static mrb_value entry(mrb_state* M, mrb_value v) {
        mrb_value h = mrb_hash_new(M);
        mrb_hash_set(M, h, sym(M, "default"), v);
        return h;
      }
      static int scenario(mrb_state* M) {
        mrb_value lcf = mrb_obj_value(mrb_module_get(M, "LCF"));
        mrb_value level = sym(M, "level_max");
        mrb_value exp = sym(M, "exp_default");
        mrb_value nope = sym(M, "nope");
        call(M, "level_max", lcf, "edition_default", 1, &level);
        call(M, "exp_default", lcf, "edition_default", 1, &exp);
        call(M, "unknown_kind", lcf, "edition_default", 1, &nope);
        mrb_value reader = mrb_funcall(M, mrb_obj_value(mrb_class_get(M, "EdReader")), "new", 0);
        mrb_value s1 = entry(M, level);
        call(M, "reader_level", reader, "default_of", 1, &s1);
        mrb_value s2 = entry(M, exp);
        call(M, "reader_exp", reader, "default_of", 1, &s2);
        mrb_value s3 = entry(M, mrb_fixnum_value(42));
        call(M, "reader_plain", reader, "default_of", 1, &s3);
        mrb_value s4 = entry(M, nope);
        call(M, "reader_unknown", reader, "default_of", 1, &s4);
        call(M, "reader_lambda", reader, "lambda_case");
        return 0;
      }
    CPP
    built, output = Bc2cppFixtureRuntime.run(dir, err, OWNERS, scenario, build: build, full: true)
    suite.check('fixture builds and runs', built)
    sections = Bc2cppFixtureRuntime.sections(output)
    plain = ->(lines) { lines.to_a.reject { |l| l.start_with?('  dispatches=') } }
    interpreted = plain.call(sections['interpreted'])
    compiled = plain.call(sections['compiled'])
    suite.check('the edition values come back, and a plain or callable default still does',
                interpreted.include?('level_max => 50') && interpreted.include?('exp_default => 30') &&
                interpreted.include?('reader_level => 50') && interpreted.include?('reader_exp => 30') &&
                interpreted.include?('reader_plain => 42') && interpreted.include?('reader_lambda => 7'))
    suite.check('an unknown kind raises ArgumentError',
                interpreted.any? { |l| l.start_with?('unknown_kind') && l.include?('ArgumentError') } &&
                interpreted.any? { |l| l.start_with?('reader_unknown') && l.include?('ArgumentError') })
    suite.check('compiled matches interpreted', compiled == interpreted)
    # The point of the change: reading a Symbol default makes no lambda call.
    lines = sections['compiled'].to_a
    at = lines.index { |l| l.start_with?('reader_level') }
    suite.check('a compiled read of a Symbol default makes no dynamic dispatch', at && lines[at + 1].to_s.strip == 'dispatches=0')
  end
end

suite.finish!
