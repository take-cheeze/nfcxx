#!/usr/bin/env ruby
# frozen_string_literal: true

# SUPER_LOOKUP (super_lookup_call): `super(args)` into a method no direct rule calls -- here C methods,
# Exception#initialize and Array#initialize -- is looked up from the superclass at run time and called with the
# arguments and no block (no caller passes one). A literal block (`super(n) { }`) keeps the `#error`. The check
# reads the generated calls and runs the constructors interpreted and compiled. Needs MRBC and a full-core
# libmruby (BC2CPP_MRUBY_FULL, or rake and a C++ compiler).
ENV['BC2CPP_SIG_DIRS'] = ''

require 'tmpdir'
require_relative 'check_support'
require_relative 'fixture_runtime'

suite = FixtureCheck.new('super_lookup_check')
suite.require_mrbc!

SOURCE = <<~RUBY
  class SlErr < RuntimeError
    def initialize(a, b)
      @a = a
      super("failed: \#{a} (\#{b})")
    end

    def a = @a
  end

  class SlArr < Array
    def initialize(n)
      super(n, 7)
    end
  end

  class SlLit < Array
    def initialize(n)
      super(n) { |i| i * 2 }
    end
  end
RUBY

OWNERS = %w[SlErr SlArr SlLit].freeze

Dir.mktmpdir('bc2cpp-super-lookup') do |dir|
  code, err = Bc2cppFixtureRuntime.generate(SOURCE, dir, core: true, only_owners: OWNERS)
  suite.check('super into a C method compiles to the run-time lookup',
              code.include?('mrb_value SlErr_initialize_impl(mrb_state* M') &&
              code.include?('mrb_value SlArr_initialize_impl(mrb_state* M') &&
              code.scan(/bc2cpp_super_call\(M, self, /).size == 2)
  suite.check('the arguments are passed in order', code.include?('bc2cpp_super_argv[] = {r4, r5};'))
  suite.check('a literal block keeps the #error', !code.include?('mrb_value SlLit_initialize_impl(mrb_state* M'))

  build = ENV['CC_GENERATED_ONLY'] == '1' ? nil : Bc2cppFixtureRuntime.full_or_build
  if build.nil?
    puts '  SKIP super lookup behaviour: needs a full-core libmruby (BC2CPP_MRUBY_FULL, or rake and g++)'
  else
    scenario = <<~CPP
      static void sl_new(mrb_state* M, const char* cls, mrb_int argc, const mrb_value* argv, const char* label,
                         const char* method) {
        // Through Class#new: mrb_obj_new does not allocate an exception as Exception.new does.
        mrb_value obj = mrb_funcall_argv(M, mrb_obj_value(mrb_class_get(M, cls)), mrb_intern_lit(M, "new"), argc, argv);
        call(M, label, obj, method);
      }
      static int scenario(mrb_state* M) {
        mrb_value two[] = {mrb_str_new_lit(M, "a.png"), mrb_str_new_lit(M, "missing")};
        mrb_value one[] = {mrb_fixnum_value(3)};
        sl_new(M, "SlErr", 2, two, "err_message", "message");
        sl_new(M, "SlErr", 2, two, "err_ivar", "a");
        sl_new(M, "SlArr", 1, one, "arr", "to_a");
        sl_new(M, "SlLit", 1, one, "lit", "to_a");
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
    suite.check('the superclass methods ran with the arguments',
                interpreted.include?('err_message => "failed: a.png (missing)"') &&
                interpreted.include?('arr => [7, 7, 7]'))
    suite.check('compiled matches interpreted', compiled == interpreted)
  end
end

suite.finish!
