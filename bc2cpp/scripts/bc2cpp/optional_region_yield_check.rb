#!/usr/bin/env ruby
# frozen_string_literal: true

# OPTIONAL_REST_YIELD for a yield inside a block (optional_rest_region_yield?): a method with optional or rest
# parameters whose `yield` sits in a block it passes on (`list.reduce(init) { |acc, x| acc | yield(x) }`) extracts its
# block in the wrapper, as one with a bare `yield` does, and the block region forwards it. The fixture covers an
# optional parameter given and omitted, a rest parameter, calls from compiled code with a literal block (which may call
# the `_impl` directly, the block after the optionals) and a call without a block (LocalJumpError). The behaviour part
# needs BC2CPP_MRUBY_FULL, or rake and a C++ compiler.
ENV['BC2CPP_SIG_DIRS'] = ''

require 'tmpdir'
require_relative 'check_support'
require_relative 'fixture_runtime'

suite = FixtureCheck.new('optional_region_yield_check')
suite.require_mrbc!

SOURCE = <<~RUBY
  class OryHost
    def mask(list, init = 0)
      list.reduce(init) { |joined, x| joined | yield(x) }
    end

    def each_of(*list)
      list.each { |x| yield x, list.size }
      list.size
    end
  end
  class OryUser
    def run_mask(h) = [h.mask([1, 2]) { |x| x * 4 }, h.mask([1], 1) { |x| x * 2 }]
    def run_each(h)
      got = []
      n = h.each_of(:a, :b) { |x, size| got << [x, size] }
      [n, got]
    end
    def run_noblk(h)
      h.mask([1])
    rescue LocalJumpError => e
      e.class
    end
  end
RUBY

OWNERS = %w[OryHost OryUser].freeze

def compiled?(code, name)
  code.match?(/^(?:static )?mrb_value #{name}\(mrb_state\* M/)
end

Dir.mktmpdir('bc2cpp-optional-region-yield') do |dir|
  code, err = Bc2cppFixtureRuntime.generate(SOURCE, dir, core: true, only_owners: OWNERS)
  suite.check('optional and rest methods yielding inside a block compile',
              %w[OryHost_mask_impl OryHost_each_of_impl].all? { |f| compiled?(code, f) })

  build = ENV['CC_GENERATED_ONLY'] == '1' ? nil : Bc2cppFixtureRuntime.full_or_build
  if build.nil?
    puts '  SKIP optional region yield behaviour: needs a full-core libmruby (BC2CPP_MRUBY_FULL, or rake and g++)'
  else
    scenario = <<~CPP
      static int scenario(mrb_state* M) {
        mrb_value u = mrb_funcall_argv(M, mrb_obj_value(mrb_class_get(M, "OryUser")), mrb_intern_lit(M, "new"), 0, nullptr);
        mrb_value h = mrb_funcall_argv(M, mrb_obj_value(mrb_class_get(M, "OryHost")), mrb_intern_lit(M, "new"), 0, nullptr);
        const char* calls[] = {"run_mask", "run_each", "run_noblk"};
        for (const char* m : calls) call(M, m, u, m, 1, &h);
        return 0;
      }
    CPP
    built, output = Bc2cppFixtureRuntime.run(dir, err, OWNERS, scenario, build: build, full: true)
    suite.check('fixture builds and runs', built)
    sections = Bc2cppFixtureRuntime.sections(output)
    plain = ->(lines) { lines.to_a.reject { |l| l.start_with?('  dispatches=') } }
    interpreted = plain.call(sections['interpreted'])
    compiled = plain.call(sections['compiled'])
    suite.check('the interpreter forwards the block into the nested yield',
                interpreted.include?('run_mask => [12, 3]') && interpreted.include?('run_each => [2, [[:a, 2], [:b, 2]]]') &&
                interpreted.include?('run_noblk => LocalJumpError'))
    suite.check('compiled matches interpreted', compiled == interpreted)
  end
end

suite.finish!
