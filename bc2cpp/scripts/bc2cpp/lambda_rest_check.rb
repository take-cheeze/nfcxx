#!/usr/bin/env ruby
# frozen_string_literal: true

# LAMBDA_REST (lambda_fallback_safe?, emit_proc_fallback_fn_body): `->(a, *r) { }`, `->(a, *) { }` and `->(*r) { }`
# compile as lambda bodies taking the mandatory values and the rest Array, bound as vm.c OP_ENTER binds a strict proc:
# no spread of a lone Array argument, ArgumentError naming the mandatory count for too few. A rest lambda called in its
# frame is not a direct call (its `_impl` takes the rest packed), so one reading the frame's locals captures them
# through cells. The behaviour part needs BC2CPP_MRUBY_FULL, or rake and a C++ compiler.
ENV['BC2CPP_SIG_DIRS'] = ''

require 'tmpdir'
require_relative 'check_support'
require_relative 'fixture_runtime'

suite = FixtureCheck.new('lambda_rest_check')
suite.require_mrbc!

SOURCE = <<~RUBY
  class LrHost
    def apply(f, *args) = f.call(*args)

    def ignore_rest(x)
      f = ->(called, *) { [called, x] }
      [apply(f, 1), apply(f, 2, 3, 4)]
    end

    def mixed(base)
      f = ->(a, *r) { [a, base, r] }
      out = [f.call(1), f.call(1, 2, 3), f.call([4, 5])]
      begin
        f.call
      rescue ArgumentError => e
        out << e.message
      end
      out
    end

    def only_rest
      f = ->(*r) { r.size }
      [f.call, f.call(1, 2), f.call([1, 2])]
    end
  end
  class LrUser
    def run_ignore(h) = h.ignore_rest(:x)
    def run_mixed(h) = h.mixed(10)
    def run_only(h) = h.only_rest
  end
RUBY

OWNERS = %w[LrHost LrUser].freeze

def compiled?(code, name)
  code.match?(/^(?:static )?mrb_value #{name}\(mrb_state\* M/)
end

Dir.mktmpdir('bc2cpp-lambda-rest') do |dir|
  code, err = Bc2cppFixtureRuntime.generate(SOURCE, dir, core: true, only_owners: OWNERS)
  suite.check('methods holding rest lambdas compile',
              %w[ignore_rest mixed only_rest].all? { |m| compiled?(code, "LrHost_#{m}_impl") })

  build = ENV['CC_GENERATED_ONLY'] == '1' ? nil : Bc2cppFixtureRuntime.full_or_build
  if build.nil?
    puts '  SKIP lambda rest behaviour: needs a full-core libmruby (BC2CPP_MRUBY_FULL, or rake and g++)'
  else
    scenario = <<~CPP
      static int scenario(mrb_state* M) {
        mrb_value u = mrb_funcall_argv(M, mrb_obj_value(mrb_class_get(M, "LrUser")), mrb_intern_lit(M, "new"), 0, nullptr);
        mrb_value h = mrb_funcall_argv(M, mrb_obj_value(mrb_class_get(M, "LrHost")), mrb_intern_lit(M, "new"), 0, nullptr);
        const char* calls[] = {"run_ignore", "run_mixed", "run_only"};
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
    suite.check('the interpreter binds rest lambdas strictly',
                interpreted.include?('run_ignore => [[1, :x], [2, :x]]') &&
                interpreted.include?('run_only => [0, 2, 1]') &&
                interpreted.any? { |l| l.start_with?('run_mixed => [[1, 10, []], [1, 10, [2, 3]], [[4, 5], 10, []], ') && l.include?('expected 1)') })
    suite.check('compiled matches interpreted', compiled == interpreted)
  end
end

suite.finish!
