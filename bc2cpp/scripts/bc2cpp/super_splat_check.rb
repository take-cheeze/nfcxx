#!/usr/bin/env ruby
# frozen_string_literal: true

# SUPER_SPLAT (super_splat_call): `super(key, *args)`, `super(key, *args, &blk)` and `super(*args)` (SUPER n=*) call the
# superclass method with the packed argument Array the compiler built (ARRAY/LOADNIL then ARYCAT), through
# bc2cpp_super_call. The check reads the generated calls and, when a full-core libmruby is available, runs the methods
# interpreted and compiled. BC2CPP_SUPER_SPLAT=0 keeps the `#error`. Needs MRBC; the behaviour part needs
# BC2CPP_MRUBY_FULL, or rake and a C++ compiler.
ENV['BC2CPP_SIG_DIRS'] = ''

require 'tmpdir'
require_relative 'check_support'
require_relative 'fixture_runtime'

suite = FixtureCheck.new('super_splat_check')
suite.require_mrbc!

SOURCE = <<~RUBY
  class SpBase
    def m(key, *args)
      [key, args]
    end

    def n(key, *args)
      [key, args]
    end
  end

  class SpExplicit < SpBase
    def m(key, *args)
      super(key, *args)
    end

    def n(key, *args)
      super(key, *args)
    end
  end

  class SpSplat < SpBase
    def n(key, *args)
      super(*args)
    end
  end
RUBY

OWNERS = %w[SpBase SpExplicit SpSplat].freeze

Dir.mktmpdir('bc2cpp-super-splat') do |dir|
  code, err = Bc2cppFixtureRuntime.generate(SOURCE, dir, core: true, only_owners: OWNERS)
  suite.check('the explicit splat supers compile to the packed-array call, without #error',
              code.include?('mrb_value SpExplicit_n_impl(mrb_state* M') &&
              code.include?('mrb_value SpSplat_n_impl(mrb_state* M') &&
              code.scan(/bc2cpp_super_call\(M, self, .*RARRAY_LEN\(r5\), RARRAY_PTR\(r5\)/).size >= 2 &&
              !code.lines.any? { |l| l.include?('#error') && l.include?('SUPER') })

  build = ENV['CC_GENERATED_ONLY'] == '1' ? nil : Bc2cppFixtureRuntime.full_or_build
  if build.nil?
    puts '  SKIP super splat behaviour: needs a full-core libmruby (BC2CPP_MRUBY_FULL, or rake and g++)'
  else
    scenario = <<~CPP
      static mrb_value sp_new(mrb_state* M, const char* cls) {
        return mrb_funcall_argv(M, mrb_obj_value(mrb_class_get(M, cls)), mrb_intern_lit(M, "new"), 0, nullptr);
      }
      static int scenario(mrb_state* M) {
        mrb_value three[] = {mrb_fixnum_value(1), mrb_fixnum_value(2), mrb_fixnum_value(3)};
        mrb_value two[] = {mrb_fixnum_value(2), mrb_fixnum_value(3)};
        mrb_value one[] = {mrb_fixnum_value(7)};
        mrb_value ex = sp_new(M, "SpExplicit");
        mrb_value sp = sp_new(M, "SpSplat");
        call(M, "explicit_m", ex, "m", 3, three);
        call(M, "explicit_n", ex, "n", 3, three);
        call(M, "splat_n", sp, "n", 3, three);
        call(M, "splat_empty", sp, "n", 1, one);
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
    suite.check('the superclass method ran with the splatted arguments',
                interpreted.include?('explicit_m => [1, [2, 3]]') &&
                interpreted.include?('explicit_n => [1, [2, 3]]') &&
                interpreted.include?('splat_n => [2, [3]]'))
    suite.check('compiled matches interpreted', compiled == interpreted)
  end
end

suite.finish!
