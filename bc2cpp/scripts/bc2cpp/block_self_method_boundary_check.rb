#!/usr/bin/env ruby
# frozen_string_literal: true

# BLOCK_SELF_METHOD_BOUNDARY (codegen_block_self.rb block_self_rebound_from_creator?): BlockSelfWorld marks every irep
# nested in a rebinder's literal block as rebound, the methods `Struct.new(...) do ... end` defines and their blocks
# included. A block's self is the self of the frame that creates it, so a block in such a method is not rebound: it
# compiles (with its captured locals and the struct's readers on self), while the Struct.new block itself and a block
# nested in a define_method body (a rebinder's block, run under the receiver) stay interpreted. All of them behave as
# the interpreter does. The behaviour part needs BC2CPP_MRUBY_FULL, or rake and a C++ compiler.
ENV['BC2CPP_SIG_DIRS'] = ''

require 'tmpdir'
require_relative 'check_support'
require_relative 'fixture_runtime'

suite = FixtureCheck.new('block_self_method_boundary_check')
suite.require_mrbc!

SOURCE = <<~RUBY
  BsmPair = Struct.new(:a, :b) do
    def scaled(k)
      [a, b].map { |v| v * k + a }
    end

    def nested(k)
      [a, b].map { |v| [1, 2].map { |w| v * w + k + b } }
    end
  end
  class BsmMaker
    def build(n)
      Struct.new(:x) { def twice = x * 2 }.new(n).twice
    end

    def defining(n)
      klass = Class.new
      klass.define_method(:items) { [1, 2].map { |v| v + n } }
      klass.new.items
    end
  end
RUBY

OWNERS = %w[BsmPair BsmMaker].freeze

def compiled?(code, name)
  code.match?(/^(?:static )?mrb_value #{name}\(mrb_state\* M/)
end

Dir.mktmpdir('bc2cpp-block-self-method-boundary') do |dir|
  code, err = Bc2cppFixtureRuntime.generate(SOURCE, dir, core: true, only_owners: OWNERS)
  suite.check('blocks in methods a Struct.new block defines compile',
              compiled?(code, 'BsmPair_scaled_impl') && compiled?(code, 'BsmPair_nested_impl'))
  suite.check('a rebinder\'s own literal block keeps its method interpreted',
              !compiled?(code, 'BsmMaker_build_impl') && !compiled?(code, 'BsmMaker_defining_impl'))

  build = ENV['CC_GENERATED_ONLY'] == '1' ? nil : Bc2cppFixtureRuntime.full_or_build
  if build.nil?
    puts '  SKIP block self method boundary behaviour: needs a full-core libmruby (BC2CPP_MRUBY_FULL, or rake and g++)'
  else
    scenario = <<~CPP
      static int scenario(mrb_state* M) {
        mrb_value pargs[] = {mrb_fixnum_value(3), mrb_fixnum_value(5)};
        mrb_value pair = mrb_funcall_argv(M, mrb_obj_value(mrb_class_get(M, "BsmPair")), mrb_intern_lit(M, "new"), 2, pargs);
        mrb_value k = mrb_fixnum_value(10);
        call(M, "scaled", pair, "scaled", 1, &k);
        call(M, "nested", pair, "nested", 1, &k);
        mrb_value maker = mrb_funcall_argv(M, mrb_obj_value(mrb_class_get(M, "BsmMaker")), mrb_intern_lit(M, "new"), 0, nullptr);
        mrb_value n = mrb_fixnum_value(21);
        call(M, "build", maker, "build", 1, &n);
        call(M, "defining", maker, "defining", 1, &n);
        return 0;
      }
    CPP
    built, output = Bc2cppFixtureRuntime.run(dir, err, OWNERS, scenario, build: build, full: true)
    suite.check('fixture builds and runs', built)
    sections = Bc2cppFixtureRuntime.sections(output)
    plain = ->(lines) { lines.to_a.reject { |l| l.start_with?('  dispatches=') } }
    interpreted = plain.call(sections['interpreted'])
    compiled = plain.call(sections['compiled'])
    suite.check('the interpreter runs the struct methods and the rebinders',
                interpreted.include?('scaled => [33, 53]') && interpreted.include?('nested => [[18, 21], [20, 25]]') &&
                interpreted.include?('build => 42') && interpreted.include?('defining => [22, 23]'))
    suite.check('compiled matches interpreted', compiled == interpreted)
  end
end

suite.finish!
