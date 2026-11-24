#!/usr/bin/env ruby
# frozen_string_literal: true

# KEYWORD_YIELD (keyword_yield?, keyword_rest_block_entry, compile_keyword_call): a method with keyword parameters and
# no `&blk` that yields (a bare `yield`, `block_given?`, or a `yield` inside a block it passes on) takes its block as the
# `&blk` form does: the wrapper extracts it after the keywords and the `_impl` takes it after the positionals. A keyword
# call compiled as a direct `_impl` call passes nil there, the block the plain send carries. The fixture covers required
# and optional keywords, an optional positional, a keyword-only method, yields at the method level and in a block, and
# calls with and without a block. The behaviour part needs BC2CPP_MRUBY_FULL, or rake and a C++ compiler.
ENV['BC2CPP_SIG_DIRS'] = ''

require 'tmpdir'
require_relative 'check_support'
require_relative 'fixture_runtime'

suite = FixtureCheck.new('keyword_yield_check')
suite.require_mrbc!

SOURCE = <<~RUBY
  class KyHost
    def each_hit(list, min:, scale: 1)
      list.each { |v| yield v * scale if v >= min }
      list.size
    end

    def tagged(x, y = 2, tag: :t)
      return [:noblk, x, y, tag] unless block_given?

      [yield(x + y), tag]
    end

    def opts(verbose: false)
      verbose ? yield(:loud) : :quiet
    end
  end
  class KyUser
    def run_hits(h)
      got = []
      n = h.each_hit([1, 5, 3, 7], min: 3, scale: 10) { |v| got << v }
      [n, got]
    end
    def run_hits_noblk(h)
      h.each_hit([9], min: 5)
    rescue LocalJumpError => e
      e.class
    end
    def run_tagged(h) = [h.tagged(1) { |s| s * 2 }, h.tagged(1, 5, tag: :u) { |s| s }, h.tagged(4, tag: :v)]
    def run_opts(h) = [h.opts { |w| w }, h.opts(verbose: true) { |w| [w] }]
  end
RUBY

OWNERS = %w[KyHost KyUser].freeze

def compiled?(code, name)
  code.match?(/^(?:static )?mrb_value #{name}\(mrb_state\* M/)
end

Dir.mktmpdir('bc2cpp-keyword-yield') do |dir|
  code, err = Bc2cppFixtureRuntime.generate(SOURCE, dir, core: true, only_owners: OWNERS)
  suite.check('keyword methods that yield compile', %w[each_hit tagged opts].all? { |m| compiled?(code, "KyHost_#{m}_impl") })
  suite.check('their wrappers extract the block after the keywords',
              code.scan(/mrb_get_args\(M, "[^"]*:&"/).size >= 3)

  build = ENV['CC_GENERATED_ONLY'] == '1' ? nil : Bc2cppFixtureRuntime.full_or_build
  if build.nil?
    puts '  SKIP keyword yield behaviour: needs a full-core libmruby (BC2CPP_MRUBY_FULL, or rake and g++)'
  else
    scenario = <<~CPP
      static int scenario(mrb_state* M) {
        mrb_value u = mrb_funcall_argv(M, mrb_obj_value(mrb_class_get(M, "KyUser")), mrb_intern_lit(M, "new"), 0, nullptr);
        mrb_value h = mrb_funcall_argv(M, mrb_obj_value(mrb_class_get(M, "KyHost")), mrb_intern_lit(M, "new"), 0, nullptr);
        const char* calls[] = {"run_hits", "run_hits_noblk", "run_tagged", "run_opts"};
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
    suite.check('the interpreter yields from keyword methods',
                interpreted.include?('run_hits => [4, [50, 30, 70]]') &&
                interpreted.include?('run_hits_noblk => LocalJumpError') &&
                interpreted.include?('run_tagged => [[6, :t], [6, :u], [:noblk, 4, 2, :v]]') &&
                interpreted.include?('run_opts => [:quiet, [:loud]]'))
    suite.check('compiled matches interpreted', compiled == interpreted)
  end
end

suite.finish!
