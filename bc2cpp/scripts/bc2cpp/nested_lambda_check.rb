#!/usr/bin/env ruby
# frozen_string_literal: true

# NESTED_LAMBDA_FALLBACK (emit_proc_fallback_fn_body): a `->() { }` inside a block body is a lambda region of that
# body's frame, as one in a method body is. The fixture covers a lambda reading nothing from the frame and passed on
# (`fetch(k) { walk(->(x) { @table[x] }) }`), one confined to the block and called there (a direct call), one that
# escapes the block and reads its locals and the method's (cells), one that writes a block local, and strict arity.
# The behaviour part needs BC2CPP_MRUBY_FULL, or rake and a C++ compiler.
ENV['BC2CPP_SIG_DIRS'] = ''

require 'tmpdir'
require_relative 'check_support'
require_relative 'fixture_runtime'

suite = FixtureCheck.new('nested_lambda_check')
suite.require_mrbc!

SOURCE = <<~RUBY
  class NlHost
    def initialize
      @table = { 1 => :one, 2 => :two }
      @memo = {}
    end

    def walk(list, f) = list.map { |x| f.call(x) }

    def free(key)
      @memo.fetch(key) do
        walk([1, 2, 3], ->(x) { @table[x] })
      end
    end

    def confined(list)
      list.map do |x|
        add = ->(y) { x + y }
        add.call(10)
      end
    end

    def escaping(base)
      makers = [1, 2].map do |x|
        k = x * 100
        ->(y) { base + k + y }
      end
      makers.map { |m| m.call(3) }
    end

    def writer(list)
      list.map do |x|
        acc = 0
        bump = ->(n) { acc += n }
        bump.call(x)
        bump.call(x)
        acc
      end
    end

    def strict(list)
      list.map do |x|
        f = ->(a, b) { [a, b, x] }
        begin
          f.call(1)
        rescue ArgumentError => e
          e.message
        end
      end
    end
  end
  class NlUser
    def run_free(h) = h.free(:k)
    def run_confined(h) = h.confined([1, 2])
    def run_escaping(h) = h.escaping(7)
    def run_writer(h) = h.writer([2, 5])
    def run_strict(h) = h.strict([9])
  end
RUBY

OWNERS = %w[NlHost NlUser].freeze

def compiled?(code, name)
  code.match?(/^(?:static )?mrb_value #{name}\(mrb_state\* M/)
end

Dir.mktmpdir('bc2cpp-nested-lambda') do |dir|
  code, err = Bc2cppFixtureRuntime.generate(SOURCE, dir, core: true, only_owners: OWNERS)
  suite.check('methods with a lambda inside a block compile',
              %w[free confined escaping writer].all? { |m| compiled?(code, "NlHost_#{m}_impl") })
  suite.check('the lambdas are compiled lambda bodies', code.scan(/_lambda_fallback_\d+_impl\(mrb_state\* M/).size >= 4)

  build = ENV['CC_GENERATED_ONLY'] == '1' ? nil : Bc2cppFixtureRuntime.full_or_build
  if build.nil?
    puts '  SKIP nested lambda behaviour: needs a full-core libmruby (BC2CPP_MRUBY_FULL, or rake and g++)'
  else
    scenario = <<~CPP
      static mrb_value nl_new(mrb_state* M, const char* cls) {
        return mrb_funcall_argv(M, mrb_obj_value(mrb_class_get(M, cls)), mrb_intern_lit(M, "new"), 0, nullptr);
      }
      static int scenario(mrb_state* M) {
        mrb_value u = nl_new(M, "NlUser");
        mrb_value h = nl_new(M, "NlHost");
        const char* calls[] = {"run_free", "run_confined", "run_escaping", "run_writer", "run_strict"};
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
    suite.check('the interpreter runs the nested lambdas',
                interpreted.include?('run_free => [:one, :two, nil]') &&
                interpreted.include?('run_confined => [11, 12]') &&
                interpreted.include?('run_escaping => [110, 210]') &&
                interpreted.include?('run_writer => [4, 10]') &&
                interpreted.include?('run_strict => ["wrong number of arguments (given 1, expected 2)"]'))
    suite.check('compiled matches interpreted', compiled == interpreted)
  end
end

suite.finish!
