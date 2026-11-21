#!/usr/bin/env ruby
# frozen_string_literal: true

# BLOCK_FALLBACK_UPVAR_SAFE_METHODS' bc2cpp names (with_fresh_method_state, straight_line, each_call_site): a block that
# forwards the method's block (`with_fresh_method_state { yield }`) or reads its locals may be given to them as to any
# synchronous iterator, so the method holding it compiles and the block body yields the method's block. The fixture
# defines the three names as bc2cpp does (a wrapper calling `super` among them) and checks the compiled result against
# the interpreter, with and without a block. The behaviour part needs BC2CPP_MRUBY_FULL, or rake and a C++ compiler.
ENV['BC2CPP_SIG_DIRS'] = ''

require 'tmpdir'
require_relative 'check_support'
require_relative 'fixture_runtime'

suite = FixtureCheck.new('sync_yield_names_check')
suite.require_mrbc!

SOURCE = <<~RUBY
  class SynBase
    def with_fresh_method_state
      saved = @state
      @state = :fresh
      yield
    ensure
      @state = saved
    end

    def straight_line(start, window)
      k = start
      while k < start + window
        yield k
        k += 1
      end
      nil
    end

    def each_call_site(list, offset:)
      list.each_with_index { |x, i| yield x + offset, i }
    end

    def probe(label) = with_fresh_method_state { yield label, @state }

    def first_hit(start)
      found = nil
      straight_line(start, 4) do |k|
        verdict = yield k
        found ||= k if verdict
      end
      found
    end

    def sites(list) = each_call_site(list, offset: 10) { |x, i| yield [x, i] }
  end
  module SynWrap
    def with_fresh_method_state
      @wrapped = true
      super
    end
  end
  SynBase.prepend(SynWrap)
  class SynUser
    def run(o)
      got = []
      [o.probe(:l) { |l, s| [l, s] }, o.first_hit(3) { |k| k.even? }, o.sites([1, 2]) { |p| got << p }, got]
    end
    def run_noblk(o)
      o.probe(:l)
    rescue LocalJumpError => e
      e.class
    end
  end
RUBY

OWNERS = %w[SynBase SynWrap SynUser].freeze

def compiled?(code, name)
  code.match?(/^(?:static )?mrb_value #{name}\(mrb_state\* M/)
end

Dir.mktmpdir('bc2cpp-sync-yield-names') do |dir|
  code, err = Bc2cppFixtureRuntime.generate(SOURCE, dir, core: true, only_owners: OWNERS)
  suite.check('methods yielding through the listed names compile',
              %w[SynBase_probe_impl SynBase_first_hit_impl SynBase_sites_impl].all? { |f| compiled?(code, f) })

  build = ENV['CC_GENERATED_ONLY'] == '1' ? nil : Bc2cppFixtureRuntime.full_or_build
  if build.nil?
    puts '  SKIP sync yield names behaviour: needs a full-core libmruby (BC2CPP_MRUBY_FULL, or rake and g++)'
  else
    scenario = <<~CPP
      static int scenario(mrb_state* M) {
        mrb_value u = mrb_funcall_argv(M, mrb_obj_value(mrb_class_get(M, "SynUser")), mrb_intern_lit(M, "new"), 0, nullptr);
        mrb_value o = mrb_funcall_argv(M, mrb_obj_value(mrb_class_get(M, "SynBase")), mrb_intern_lit(M, "new"), 0, nullptr);
        call(M, "run", u, "run", 1, &o);
        call(M, "run_noblk", u, "run_noblk", 1, &o);
        return 0;
      }
    CPP
    built, output = Bc2cppFixtureRuntime.run(dir, err, OWNERS, scenario, build: build, full: true)
    suite.check('fixture builds and runs', built)
    sections = Bc2cppFixtureRuntime.sections(output)
    plain = ->(lines) { lines.to_a.reject { |l| l.start_with?('  dispatches=') } }
    interpreted = plain.call(sections['interpreted'])
    compiled = plain.call(sections['compiled'])
    suite.check('the interpreter yields through them',
                interpreted.include?('run => [[:l, :fresh], 4, [1, 2], [[11, 0], [12, 1]]]') &&
                interpreted.include?('run_noblk => LocalJumpError'))
    suite.check('compiled matches interpreted', compiled == interpreted)
  end
end

suite.finish!
