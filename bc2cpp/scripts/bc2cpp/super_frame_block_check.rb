#!/usr/bin/env ruby
# frozen_string_literal: true

# SUPER_FRAME_BLOCK (super_forwards_frame_block?): OP_SUPER sends the frame's block on, so a method with no `&blk`
# whose `super` forwards it (a bare `super`, or `super(args)` with the frame's block MOVEd into the block register) and
# whose callers may pass a block extracts the block in its wrapper and hands it to the super call. The fixture covers a
# bare `super` in a class method (zsuper with arguments and with none), `super(a, b)`, a prepended module's bare
# `super`, an #initialize reached through `new { }` (Class#new passes its block on to #initialize, so a block-carrying
# `new` is a caller of every #initialize for SUPER_NO_CALLER_BLOCK too), and a `super` into a native method
# (Object#freeze). Each caller passes a block and also calls without one. The behaviour part needs BC2CPP_MRUBY_FULL, or
# rake and a C++ compiler.
ENV['BC2CPP_SIG_DIRS'] = ''

require 'tmpdir'
require_relative 'check_support'
require_relative 'fixture_runtime'

suite = FixtureCheck.new('super_frame_block_check')
suite.require_mrbc!

SOURCE = <<~RUBY
  class SfBase
    def initialize(*args, &blk)
      @seen = [args, blk ? blk.call(5) : :noblk]
    end
    attr_reader :seen

    def foo(a, b)
      [:base, a, b, block_given? ? yield(a) : :noblk]
    end

    def bar
      [:bar, block_given?]
    end
  end

  class SfKid < SfBase
    def initialize
      super
      @kid = true
    end
  end

  class SfArgs < SfBase
    def initialize(a, b, c)
      super(a, b)
      @c = c
    end

    def bar
      [:kbar, super]
    end
  end

  class SfZ < SfBase
    def foo(a, b)
      [:z, super]
    end
  end

  class SfOpt < SfBase
    def initialize(opts = {})
      super(opts)
      @opt = true
    end

    def foo(a, b = 9)
      [:opt, super]
    end
  end

  class SfFrozen
    def initialize
      @parts = [1, 2]
    end

    def freeze
      @parts = @parts.sum
      super
    end

    attr_reader :parts
  end

  module SfWrap
    def bar
      [:wrap, super]
    end
  end
  SfZ.prepend(SfWrap)

  class SfUser
    def kid_blk = SfKid.new { |v| v + 1 }.seen
    def kid_plain = SfKid.new.seen
    def args_blk = SfArgs.new(1, 2, 3) { |v| v * 3 }.seen
    def args_plain = SfArgs.new(1, 2, 3).seen
    def args_bar_blk(o) = o.bar { 0 }
    def args_bar(o) = o.bar
    def z_blk(o) = o.foo(4, 5) { |v| v * 100 }
    def z_plain(o) = o.foo(4, 5)
    def wrap_blk(o) = o.bar { 1 }
    def wrap_plain(o) = o.bar
    def frozen = [SfFrozen.new.freeze.parts, SfFrozen.new.freeze.frozen?]
    def opt_blk = [SfOpt.new(k: 1) { |v| v - 1 }.seen, SfOpt.new.seen]
    def opt_foo(o) = [o.foo(1) { |v| v + 7 }, o.foo(2, 3)]
  end
RUBY

OWNERS = %w[SfBase SfKid SfArgs SfZ SfOpt SfFrozen SfWrap SfUser].freeze

def takes_block?(code, name)
  code.match?(/^mrb_value #{name}_impl\(mrb_state\* M, mrb_value self[^)]*, mrb_value bc2cpp_blk[,)]/)
end

Dir.mktmpdir('bc2cpp-super-frame-block') do |dir|
  code, err = Bc2cppFixtureRuntime.generate(SOURCE, dir, core: true, only_owners: OWNERS)
  suite.check('methods whose super forwards a caller block take that block',
              %w[SfZ_foo SfArgs_bar SfWrap_bar SfOpt_initialize SfOpt_foo].all? { |f| takes_block?(code, f) })
  suite.check('their super calls forward it', code.scan(/bc2cpp_super_call\(M, self, [^;]*, bc2cpp_blk\);/).size >= 2)

  build = ENV['CC_GENERATED_ONLY'] == '1' ? nil : Bc2cppFixtureRuntime.full_or_build
  if build.nil?
    puts '  SKIP super frame block behaviour: needs a full-core libmruby (BC2CPP_MRUBY_FULL, or rake and g++)'
  else
    scenario = <<~CPP
      static mrb_value sf_new(mrb_state* M, const char* cls, int argc = 0, const mrb_value* argv = nullptr) {
        return mrb_funcall_argv(M, mrb_obj_value(mrb_class_get(M, cls)), mrb_intern_lit(M, "new"), argc, argv);
      }
      static int scenario(mrb_state* M) {
        mrb_value u = sf_new(M, "SfUser");
        for (const char* m : {"kid_blk", "kid_plain", "args_blk", "args_plain", "frozen", "opt_blk"}) call(M, m, u, m);
        mrb_value opt = sf_new(M, "SfOpt");
        call(M, "opt_foo", u, "opt_foo", 1, &opt);
        mrb_value args[] = {mrb_fixnum_value(1), mrb_fixnum_value(2), mrb_fixnum_value(3)};
        mrb_value a = sf_new(M, "SfArgs", 3, args);
        mrb_value z = sf_new(M, "SfZ");
        call(M, "args_bar_blk", u, "args_bar_blk", 1, &a);
        call(M, "args_bar", u, "args_bar", 1, &a);
        call(M, "z_blk", u, "z_blk", 1, &z);
        call(M, "z_plain", u, "z_plain", 1, &z);
        call(M, "wrap_blk", u, "wrap_blk", 1, &z);
        call(M, "wrap_plain", u, "wrap_plain", 1, &z);
        return 0;
      }
    CPP
    built, output = Bc2cppFixtureRuntime.run(dir, err, OWNERS, scenario, build: build, full: true)
    suite.check('fixture builds and runs', built)
    sections = Bc2cppFixtureRuntime.sections(output)
    plain = ->(lines) { lines.to_a.reject { |l| l.start_with?('  dispatches=') } }
    interpreted = plain.call(sections['interpreted'])
    compiled = plain.call(sections['compiled'])
    suite.check('the interpreter forwards the caller block through super',
                interpreted.include?('kid_blk => [[], 6]') && interpreted.include?('args_blk => [[1, 2], 15]') &&
                interpreted.include?('z_blk => [:z, [:base, 4, 5, 400]]') &&
                interpreted.include?('wrap_blk => [:wrap, [:bar, true]]') &&
                interpreted.include?('opt_blk => [[[{k: 1}], 4], [[{}], :noblk]]') &&
                interpreted.include?('opt_foo => [[:opt, [:base, 1, 9, 8]], [:opt, [:base, 2, 3, :noblk]]]'))
    suite.check('compiled matches interpreted', compiled == interpreted)
  end
end

suite.finish!
