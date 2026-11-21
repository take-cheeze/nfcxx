#!/usr/bin/env ruby
# frozen_string_literal: true

# MIXED_REST_BLOCK under Kernel#lambda (mixed_rest_unpack): a strict proc over `{ |a, *r| }` binds as vm.c OP_ENTER's
# strict branch does. It does not spread a lone Array argument over its parameters (only a plain block does), and too
# few arguments raise ArgumentError naming the mandatory count ("expected 1", argnum_error(m1 + m2)), not a range.
# The plain block keeps its spread. The behaviour part needs BC2CPP_MRUBY_FULL, or rake and a C++ compiler.
ENV['BC2CPP_SIG_DIRS'] = ''

require 'tmpdir'
require_relative 'check_support'
require_relative 'fixture_runtime'

suite = FixtureCheck.new('strict_mixed_rest_check')
suite.require_mrbc!

SOURCE = <<~RUBY
  class SmrHost
    def strict_pair
      f = lambda { |a, *r| [a, r] }
      out = [f.call([1, 2]), f.call(1, 2, 3)]
      begin
        f.call
      rescue ArgumentError => e
        out << e.message
      end
      out
    end

    def plain_pair(list)
      got = []
      list.each { |a, *r| got << [a, r] }
      got
    end
  end
  class SmrUser
    def run_strict(h) = h.strict_pair
    def run_plain(h) = h.plain_pair([[1, 2], 3, [4]])
  end
RUBY

OWNERS = %w[SmrHost SmrUser].freeze

def compiled?(code, name)
  code.match?(/^(?:static )?mrb_value #{name}\(mrb_state\* M/)
end

Dir.mktmpdir('bc2cpp-strict-mixed-rest') do |dir|
  code, err = Bc2cppFixtureRuntime.generate(SOURCE, dir, core: true, only_owners: OWNERS)
  suite.check('methods holding mixed rest blocks compile',
              %w[SmrHost_strict_pair_impl SmrHost_plain_pair_impl].all? { |f| compiled?(code, f) })

  build = ENV['CC_GENERATED_ONLY'] == '1' ? nil : Bc2cppFixtureRuntime.full_or_build
  if build.nil?
    puts '  SKIP strict mixed rest behaviour: needs a full-core libmruby (BC2CPP_MRUBY_FULL, or rake and g++)'
  else
    scenario = <<~CPP
      static int scenario(mrb_state* M) {
        mrb_value u = mrb_funcall_argv(M, mrb_obj_value(mrb_class_get(M, "SmrUser")), mrb_intern_lit(M, "new"), 0, nullptr);
        mrb_value h = mrb_funcall_argv(M, mrb_obj_value(mrb_class_get(M, "SmrHost")), mrb_intern_lit(M, "new"), 0, nullptr);
        call(M, "run_strict", u, "run_strict", 1, &h);
        call(M, "run_plain", u, "run_plain", 1, &h);
        return 0;
      }
    CPP
    built, output = Bc2cppFixtureRuntime.run(dir, err, OWNERS, scenario, build: build, full: true)
    suite.check('fixture builds and runs', built)
    sections = Bc2cppFixtureRuntime.sections(output)
    plain = ->(lines) { lines.to_a.reject { |l| l.start_with?('  dispatches=') } }
    interpreted = plain.call(sections['interpreted'])
    compiled = plain.call(sections['compiled'])
    suite.check('the interpreter binds a strict proc without the spread',
                interpreted.include?('run_strict => [[[1, 2], []], [1, [2, 3]], "wrong number of arguments (given 0, expected 1)"]') &&
                interpreted.include?('run_plain => [[1, [2]], [3, []], [4, []]]'))
    suite.check('compiled matches interpreted', compiled == interpreted)
  end
end

suite.finish!
