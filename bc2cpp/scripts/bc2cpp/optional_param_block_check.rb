#!/usr/bin/env ruby
# frozen_string_literal: true

# OPTIONAL_PARAM_BLOCK (optional_param_block?, optional_block_unpack): a block or lambda with optional parameters
# (`lambda do |node, depth = 0, seen = depth + 1| ... end`, ENTER m:o:0:0:0:0:0:0 and OP_ENTER's jump table) compiles as
# a BLOCK_FALLBACK body taking the m + o values and the count of optionals given; the jump table is a switch, so each
# default runs only when its value was not passed, reading the parameters before it and the method's locals. A plain
# block spreads one Array argument over its parameters, drops extra values and leaves missing ones nil; a lambda raises
# ArgumentError outside m..m+o, with vm.c's message. The behaviour part needs BC2CPP_MRUBY_FULL, or rake and a C++
# compiler.
ENV['BC2CPP_SIG_DIRS'] = ''

require 'tmpdir'
require_relative 'check_support'
require_relative 'fixture_runtime'

suite = FixtureCheck.new('optional_param_block_check')
suite.require_mrbc!

SOURCE = <<~RUBY
  class OpbHost
    def each_pair_of(list)
      list.each { |v| yield v }
      list.size
    end

    def lam(base)
      f = lambda do |a, b = base, c = (b * 2)|
        [a, b, c]
      end
      out = [f.call(1), f.call(1, 2), f.call(1, 2, 3)]
      begin
        f.call
      rescue ArgumentError => e
        out << e.message
      end
      begin
        f.call(1, 2, 3, 4)
      rescue ArgumentError => e
        out << e.message
      end
      out
    end

    def rec(tree)
      walk = lambda do |node, depth = 0|
        node.is_a?(Array) ? node.map { |n| walk.call(n, depth + 1) } : [node, depth]
      end
      walk.call(tree)
    end

    def plain(list)
      seen = []
      each_pair_of(list) { |a, b = :dflt, c = [a, b]| seen << [a, b, c] }
      seen
    end

    def one_opt(list)
      got = []
      list.each { |x = :none| got << x }
      got
    end
  end
  class OpbUser
    def run_lam(h) = h.lam(5)
    def run_rec(h) = h.rec([1, [2, [3]], 4])
    def run_plain(h) = h.plain([[1, 2], 3, [4, 5, 6, 7], [], [8]])
    def run_one(h) = h.one_opt([1, [2, 3], nil])
  end
RUBY

OWNERS = %w[OpbHost OpbUser].freeze

def compiled?(code, name)
  code.match?(/^(?:static )?mrb_value #{name}\(mrb_state\* M/)
end

Dir.mktmpdir('bc2cpp-optional-param-block') do |dir|
  code, err = Bc2cppFixtureRuntime.generate(SOURCE, dir, core: true, only_owners: OWNERS)
  suite.check('methods holding blocks with optional parameters compile',
              %w[lam rec plain one_opt].all? { |m| compiled?(code, "OpbHost_#{m}_impl") })
  suite.check('the block body dispatches on the optionals given', code.include?('switch (bc2cpp_given_opt)'))

  build = ENV['CC_GENERATED_ONLY'] == '1' ? nil : Bc2cppFixtureRuntime.full_or_build
  if build.nil?
    puts '  SKIP optional parameter block behaviour: needs a full-core libmruby (BC2CPP_MRUBY_FULL, or rake and g++)'
  else
    scenario = <<~CPP
      static mrb_value opb_new(mrb_state* M, const char* cls) {
        return mrb_funcall_argv(M, mrb_obj_value(mrb_class_get(M, cls)), mrb_intern_lit(M, "new"), 0, nullptr);
      }
      static int scenario(mrb_state* M) {
        mrb_value u = opb_new(M, "OpbUser");
        mrb_value h = opb_new(M, "OpbHost");
        const char* calls[] = {"run_lam", "run_rec", "run_plain", "run_one"};
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
    suite.check('the interpreter binds the optionals and runs the defaults',
                interpreted.include?('run_lam => [[1, 5, 10], [1, 2, 4], [1, 2, 3], ' \
                                     '"wrong number of arguments (given 0, expected 1)", ' \
                                     '"wrong number of arguments (given 4, expected 1)"]') &&
                interpreted.include?('run_rec => [[1, 1], [[2, 2], [[3, 3]]], [4, 1]]') &&
                interpreted.include?('run_one => [1, [2, 3], nil]'))
    suite.check('compiled matches interpreted', compiled == interpreted)
  end
end

suite.finish!
