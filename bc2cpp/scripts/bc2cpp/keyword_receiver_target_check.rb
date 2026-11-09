#!/usr/bin/env ruby
# frozen_string_literal: true

# CONSTANT_OBJECT_KEYWORD (constant_object_keyword_target): a keyword send to a stable class/module constant resolves to
# the singleton definition that constant's class object reaches, even when the name also has an instance definer. The
# positive case, `RtMod.reach(a, x: 2)`, is a direct C++ call. The negative case, a keyword send on a receiver nothing
# proves is a constant (`h.reach(a, x: 2)`), stays refused: a name with two definers has no single target. The
# behaviour part needs BC2CPP_MRUBY_FULL, or rake and a C++ compiler.
ENV['BC2CPP_SIG_DIRS'] = ''

require 'tmpdir'
require_relative 'check_support'
require_relative 'fixture_runtime'

suite = FixtureCheck.new('keyword_receiver_target_check')
suite.require_mrbc!

SOURCE = <<~RUBY
  module RtMod
    def self.reach(a, **opts)
      a + opts.size * 10 + (opts[:x] || 0)
    end
  end

  class RtCtx
    def reach(a, follow_moves:)
      follow_moves ? a + 1 : a
    end
  end

  class RtUse
    def run(a)
      RtMod.reach(a, x: 2)
    end

    def unproven(h, a)
      h.reach(a, x: 2)
    end
  end
RUBY

OWNERS = %w[RtMod.singleton RtCtx RtUse].freeze

# The generated function that holds each refusal, as in keyword_send_check.rb's attribution.
def refusals_by_function(dir)
  owner = nil
  counts = Hash.new(0)
  File.foreach(File.join(dir, 'fixture_gen.cpp')) do |line|
    if (match = line.match(/^(?:static )?mrb_value (\w+)\(.*\{\s*$/))
      owner = match[1]
    elsif line.include?('#error')
      counts[owner] += 1
    end
  end
  counts
end

Dir.mktmpdir('bc2cpp-keyword-receiver') do |dir|
  # Refusals are read from a generation that keeps the #error lines (skip_unsupported: false); the behaviour build
  # below uses the default, which drops a refused method and so has to compile.
  Dir.mktmpdir('bc2cpp-keyword-receiver-refusals') do |refusal_dir|
    refusal_code, = Bc2cppFixtureRuntime.generate(SOURCE, refusal_dir, core: true, only_owners: OWNERS, skip_unsupported: false)
    refusals = refusals_by_function(refusal_dir)
    suite.check('the constant-receiver keyword send is a direct call to the singleton definition',
                refusals.fetch('RtUse_run_impl', 0).zero? && refusal_code.include?('RtMod_singleton_reach_impl(M, r'))
    suite.check('a keyword send on an unproven receiver with two definers stays refused',
                refusals.fetch('RtUse_unproven_impl', 0).positive?)
  end
  code, err = Bc2cppFixtureRuntime.generate(SOURCE, dir, core: true, only_owners: OWNERS)

  build = ENV['CC_GENERATED_ONLY'] == '1' ? nil : Bc2cppFixtureRuntime.full_or_build
  if build.nil?
    puts '  SKIP constant-receiver keyword behaviour: needs a full-core libmruby (BC2CPP_MRUBY_FULL, or rake and g++)'
  else
    scenario = <<~CPP
      static mrb_value rt_new(mrb_state* M, const char* cls) {
        return mrb_funcall_argv(M, mrb_obj_value(mrb_class_get(M, cls)), mrb_intern_lit(M, "new"), 0, nullptr);
      }
      static int scenario(mrb_state* M) {
        mrb_value five_v[] = {mrb_fixnum_value(5)};
        mrb_value use = rt_new(M, "RtUse");
        call(M, "run", use, "run", 1, five_v);
        return 0;
      }
    CPP
    built, output = Bc2cppFixtureRuntime.run(dir, err, OWNERS, scenario, build: build, full: true)
    suite.check('fixture builds and runs', built)
    sections = Bc2cppFixtureRuntime.sections(output)
    plain = ->(lines) { lines.to_a.reject { |l| l.start_with?('  dispatches=') } }
    interpreted = plain.call(sections['interpreted'])
    compiled = plain.call(sections['compiled'])
    suite.check('the call ran and returned the keyword-aware value', interpreted.include?('run => 17'))
    suite.check('compiled matches interpreted', compiled == interpreted)
  end
end

suite.finish!
