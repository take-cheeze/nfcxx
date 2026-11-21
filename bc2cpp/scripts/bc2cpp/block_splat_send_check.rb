#!/usr/bin/env ruby
# frozen_string_literal: true

# BLOCK_SPLAT_SEND (recognize_block_fallback_regions, emit_block_fallback_glue): a literal block given to a send with a
# splatted argument list (`each_of(*KINDS) { |k| ... }`, `SENDB R(a) :m n=*`) takes the args Array in R(a+1) and the
# block after it. The block body compiles as any BLOCK_FALLBACK body and the site is a by-name call over the Array's
# items, so the method that holds it compiles. The fixture covers a self call and a receiver call, a splat after fixed
# arguments, an empty splat, a block that reads and writes the method's locals, a `break` and a `next` out of the
# block, and a block given to a core method (`Array#each_slice(*[2])`). The behaviour part needs BC2CPP_MRUBY_FULL, or
# rake and a C++ compiler.
ENV['BC2CPP_SIG_DIRS'] = ''

require 'tmpdir'
require_relative 'check_support'
require_relative 'fixture_runtime'

suite = FixtureCheck.new('block_splat_send_check')
suite.require_mrbc!

SOURCE = <<~RUBY
  class BsHost
    KINDS = %i[a b c].freeze

    def each_of(*names)
      names.each { |n| yield n, names.size }
      names.size
    end

    def collect(x)
      out = []
      total = each_of(*KINDS) { |k, size| out << [k, size, x] }
      [out, total]
    end

    def sum_upto(limit)
      acc = 0
      r = each_of(1, *[2, 3], 4) do |v|
        break acc * 100 if v > limit

        acc += v
      end
      [r, acc]
    end

    def none
      seen = []
      r = each_of(*[]) { |v| seen << v }
      [r, seen]
    end

    def skip_b(list)
      kept = []
      each_of(*list) do |v|
        next if v == :b

        kept << v
      end
      kept
    end

    def slices(list)
      out = []
      args = [2]
      list.each_slice(*args) { |s| out << s.sum }
      out
    end

    def other(o, list)
      got = []
      o.each_of(*list) { |v| got << v.to_s }
      got
    end
  end
  class BsUser
    def run_collect(h) = h.collect(9)
    def run_sum(h) = h.sum_upto(3)
    def run_sum_all(h) = h.sum_upto(99)
    def run_none(h) = h.none
    def run_skip(h) = h.skip_b(%i[a b c b d])
    def run_slices(h) = h.slices([1, 2, 3, 4, 5])
    def run_other(h) = h.other(BsHost.new, [1, :x])
  end
RUBY

OWNERS = %w[BsHost BsUser].freeze

def compiled?(code, name)
  code.match?(/^(?:static )?mrb_value #{name}\(mrb_state\* M/)
end

Dir.mktmpdir('bc2cpp-block-splat-send') do |dir|
  code, err = Bc2cppFixtureRuntime.generate(SOURCE, dir, core: true, only_owners: OWNERS)
  methods = %w[collect sum_upto none skip_b slices other]
  suite.check('methods with a block given to a splat send compile',
              methods.all? { |m| compiled?(code, "BsHost_#{m}_impl") })
  suite.check('the site calls over the args Array with the compiled block', code.include?('ary_items(r'))

  build = ENV['CC_GENERATED_ONLY'] == '1' ? nil : Bc2cppFixtureRuntime.full_or_build
  if build.nil?
    puts '  SKIP block splat send behaviour: needs a full-core libmruby (BC2CPP_MRUBY_FULL, or rake and g++)'
  else
    scenario = <<~CPP
      static mrb_value bs_new(mrb_state* M, const char* cls) {
        return mrb_funcall_argv(M, mrb_obj_value(mrb_class_get(M, cls)), mrb_intern_lit(M, "new"), 0, nullptr);
      }
      static int scenario(mrb_state* M) {
        mrb_value u = bs_new(M, "BsUser");
        mrb_value h = bs_new(M, "BsHost");
        const char* calls[] = {"run_collect", "run_sum", "run_sum_all", "run_none", "run_skip", "run_slices", "run_other"};
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
    suite.check('the interpreter spreads the Array and runs the block',
                interpreted.include?('run_collect => [[[:a, 3, 9], [:b, 3, 9], [:c, 3, 9]], 3]') &&
                interpreted.include?('run_sum => [600, 6]') && interpreted.include?('run_sum_all => [4, 10]') &&
                interpreted.include?('run_none => [0, []]') && interpreted.include?('run_skip => [:a, :c, :d]') &&
                interpreted.include?('run_slices => [3, 7, 5]') && interpreted.include?('run_other => ["1", "x"]'))
    suite.check('compiled matches interpreted', compiled == interpreted)
  end
end

suite.finish!
