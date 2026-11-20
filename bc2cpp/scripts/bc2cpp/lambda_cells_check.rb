#!/usr/bin/env ruby
# frozen_string_literal: true

# LAMBDA_CELLS / LAMBDA_NESTED_BLOCKS (recognize_lambda_fallback_regions): a method-level `->` / `lambda do` that reads
# or writes the method's locals and may leave the frame (returned, stored in an ivar or an Array, passed to another
# method, passed as `&f`, called recursively through its own local) captures those locals through heap cells, as a
# STEP_CLOSURES block does; and a lambda body may hold blocks of its own (nested regions). The fixture checks that such
# methods compile and that they behave as the interpreter does, including a lambda that outlives its frame across a GC,
# lambdas built in a loop sharing one local, a `break` in a block inside a lambda, and a lambda's ArgumentError. A
# `return` inside a block nested in a lambda would leave the lambda, which compiled code has no token for, so that
# method stays on the interpreter. The behaviour part needs BC2CPP_MRUBY_FULL, or rake and a C++ compiler.
ENV['BC2CPP_SIG_DIRS'] = ''

require 'tmpdir'
require_relative 'check_support'
require_relative 'fixture_runtime'

suite = FixtureCheck.new('lambda_cells_check')
suite.require_mrbc!

SOURCE = <<~RUBY
  class LcBox
    def initialize(mult)
      factor = mult
      @scale = ->(v) { v * factor }
      factor += 1
    end

    def scaled(v) = @scale.call(v)

    def make_counter
      n = 0
      -> { n += 1 }
    end

    def counted
      c = make_counter
      c.call
      c.call
      [c.call, make_counter.call]
    end

    def apply(f, v) = f.call(v)

    def use(k)
      add = ->(v) { v + k }
      apply(add, 3) + apply(add, 4)
    end

    def walk_sum(n)
      walk = lambda { |m| m <= 0 ? 0 : m + walk.call(m - 1) }
      walk.call(n)
    end

    def tally(arr)
      sum = 0
      add = ->(v) { sum += v }
      arr.each(&add)
      sum
    end

    def finder(list)
      pick = ->(x) { list.select { |y| y > x }.map { |y| y * x } }
      [pick.call(1), apply(pick, 2)]
    end

    def first_big(list)
      big = ->(xs) { xs.each { |v| break v if v > 2 } }
      [big.call(list), apply(big, [1, 2])]
    end

    def shared_loop
      procs = []
      i = 0
      while i < 3
        procs << -> { i }
        i += 1
      end
      procs.map(&:call)
    end

    def nested_return(list)
      f = ->(xs) { xs.each { |v| return v if v > 1 }; :none }
      [f.call(list), f.call([0])]
    end

    def arity_error
      f = ->(a, b) { a + b }
      begin
        f.call(1)
      rescue ArgumentError
        :argument_error
      end
    end

    def free_lambda
      f = ->(a) { a.to_s * 2 }
      [apply(f, 7), f.lambda?]
    end

    def outlives
      keep = []
      base = 10
      keep << ->(v) { base += v }
      keep
    end

    def outlived
      fs = outlives
      GC.start
      [fs[0].call(1), fs[0].call(2), outlives[0].call(5)]
    end
  end
RUBY

OWNERS = %w[LcBox].freeze
COMPILED = %w[initialize scaled make_counter counted use walk_sum tally finder first_big shared_loop arity_error
              free_lambda outlives outlived].freeze

def compiled?(code, name)
  code.match?(/^mrb_value LcBox_#{name}_impl\(mrb_state\* M/)
end

Dir.mktmpdir('bc2cpp-lambda-cells') do |dir|
  code, err = Bc2cppFixtureRuntime.generate(SOURCE, dir, core: true, only_owners: OWNERS)
  missing = COMPILED.reject { |name| compiled?(code, name) }
  suite.check("escaping and block-holding lambdas compile (missing: #{missing.join(', ')})", missing.empty?)
  suite.check('their captured locals are cells', code.include?('mrb_value& r') && code.include?('bc2cpp_up_cells_0'))
  suite.check('a return in a block inside a lambda stays interpreted', !compiled?(code, 'nested_return'))

  build = ENV['CC_GENERATED_ONLY'] == '1' ? nil : Bc2cppFixtureRuntime.full_or_build
  if build.nil?
    puts '  SKIP lambda cells behaviour: needs a full-core libmruby (BC2CPP_MRUBY_FULL, or rake and g++)'
  else
    scenario = <<~CPP
      static int scenario(mrb_state* M) {
        mrb_value three = mrb_fixnum_value(3);
        mrb_value box = mrb_funcall_argv(M, mrb_obj_value(mrb_class_get(M, "LcBox")), mrb_intern_lit(M, "new"), 1, &three);
        mrb_value four = mrb_fixnum_value(4);
        call(M, "scaled", box, "scaled", 1, &four);
        call(M, "counted", box, "counted");
        call(M, "use", box, "use", 1, &four);
        call(M, "walk_sum", box, "walk_sum", 1, &four);
        mrb_value nums[] = {mrb_fixnum_value(1), mrb_fixnum_value(2), mrb_fixnum_value(3), mrb_fixnum_value(4)};
        mrb_value list = mrb_ary_new_from_values(M, 4, nums);
        call(M, "tally", box, "tally", 1, &list);
        call(M, "finder", box, "finder", 1, &list);
        call(M, "first_big", box, "first_big", 1, &list);
        call(M, "shared_loop", box, "shared_loop");
        call(M, "nested_return", box, "nested_return", 1, &list);
        call(M, "arity_error", box, "arity_error");
        call(M, "free_lambda", box, "free_lambda");
        call(M, "outlived", box, "outlived");
        // A compiled proc's #inspect has no source location, so the counter itself is not printed.
        mrb_value made = mrb_funcall_argv(M, box, mrb_intern_lit(M, "make_counter"), 0, nullptr);
        call(M, "counter_lambda", made, "lambda?");
        call(M, "counter_after_return", made, "call");
        call(M, "counter_wrong_arity", made, "call", 1, &four);
        return 0;
      }
    CPP
    built, output = Bc2cppFixtureRuntime.run(dir, err, OWNERS, scenario, build: build, full: true)
    suite.check('fixture builds and runs', built)
    sections = Bc2cppFixtureRuntime.sections(output)
    plain = ->(lines) { lines.to_a.reject { |l| l.start_with?('  dispatches=') } }
    interpreted = plain.call(sections['interpreted'])
    compiled = plain.call(sections['compiled'])
    suite.check('the interpreter shares and keeps captured locals',
                interpreted.include?('scaled => 16') && interpreted.include?('counted => [3, 1]') &&
                interpreted.include?('shared_loop => [3, 3, 3]') && interpreted.include?('outlived => [11, 13, 15]') &&
                interpreted.include?('tally => 10') && interpreted.include?('walk_sum => 10'))
    suite.check('compiled matches interpreted', compiled == interpreted)
  end
end

suite.finish!
