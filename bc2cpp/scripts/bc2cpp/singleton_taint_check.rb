#!/usr/bin/env ruby
# frozen_string_literal: true

# INSTANCE_SINGLETON_TAINT (ClosedWorld#instance_singleton_taint): the closed world places each singleton maker on the
# classes whose instances it can reach, so a maker on an unrelated class no longer turns CALL_FACTS off for the whole
# build. The fixture prepends StWrap, whose `run` chains on with a bare `super` and takes no block, to StBase; that
# super compiles only once SUPER_NO_CALLER_BLOCK proves no caller passes a block, which needs call facts.
#
#   - An unrelated class whose instance methods give `self` a singleton class (define_singleton_method in the
#     closed world's Ruby; `extend` of an outside module in an outside Ruby source) leaves the facts on, and the
#     wrapper compiles and runs as the interpreter does. With BC2CPP_SINGLETON_TAINT=0 (the whole-world rule) it
#     stays interpreted.
#   - A singleton of StBase's own instances that may answer `run` (define_singleton_method(:run), instance_eval) sits in
#     front of the wrapper and may call it with a block through `super`: the wrapper stays interpreted.
#   - A block-carrying send whose receiver is proven to be a StBase reaches the prepended module: interpreted too. One
#     proven to hold only an unrelated class does not.
#   - An outside source whose `extend` is data (a Symbol, a String) makes no singleton; one whose receiver it cannot
#     place makes every instance tainted.
# The behaviour part needs BC2CPP_MRUBY_FULL, or rake and a C++ compiler.
ENV['BC2CPP_SIG_DIRS'] = ''

require 'tmpdir'
require_relative 'check_support'
require_relative 'fixture_runtime'

suite = FixtureCheck.new('singleton_taint_check')
suite.require_mrbc!

BASE = <<~RUBY
  class StBase
    def run(x) = [:base, x]
  end
  module StWrap
    def run(x) = [:wrap, super]
  end
  StBase.prepend(StWrap)
  class StUser
    def call(o) = o.run(1)
  end
RUBY

UNRELATED = <<~RUBY
  class StOther
    def mark = define_singleton_method(:zap) { :zapped }
    def zap = :plain
  end
  class StOtherUser
    def try(o) = o.zap
  end
RUBY

OWNER_RUN = <<~RUBY
  class StBase
    def tweak = define_singleton_method(:run) { |x| [:single, x] }
  end
RUBY

OWNER_ANY = <<~RUBY
  class StBase
    def tweak = instance_eval { @tweaked = true }
  end
RUBY

PROVEN_BLOCK_CALLER = <<~RUBY
  class StBlockUser
    def call(o)
      o.run(1)
      o.run(2) { 0 }
    end
  end
RUBY

UNRELATED_BLOCK_CALLER = <<~RUBY
  class StOther2
    def other_only = 1
    def run(x) = [:other2, x, block_given?]
  end
  class StBlockUser2
    def call(o)
      o.other_only
      o.run(2) { 0 }
    end
  end
RUBY

OUTSIDE_EXTEND = <<~RUBY
  module StExt
    def zap2 = 1
  end
  class StOutside
    def mark
      extend StExt
    end
  end
RUBY

OUTSIDE_DATA = <<~RUBY
  class StData
    def to_h = { member: :extend, note: "extend", other: "include/extend" }
  end
RUBY

OUTSIDE_UNPLACED = <<~RUBY
  module StExt2
    def zap3 = 1
  end
  class StAnywhere
    def mark(obj) = obj.extend(StExt2)
  end
RUBY

OWNERS = %w[StBase StWrap StUser StOther StOtherUser StBlockUser StOther2 StBlockUser2].freeze

def compiled?(code, name)
  code.match?(/^(?:static )?mrb_value #{name}\(mrb_state\* M/)
end

def singleton_line(err)
  err[/^  instance singletons: .*$/].to_s.strip
end

def variant(source, foreign: [], env: {})
  Dir.mktmpdir('bc2cpp-singleton-taint') do |dir|
    saved = env.to_h { |key, _| [key, ENV[key]] }
    env.each { |key, value| ENV[key] = value }
    begin
      code, err = Bc2cppFixtureRuntime.generate(source, dir, core: true, only_owners: OWNERS, foreign: foreign)
    ensure
      saved.each { |key, value| ENV[key] = value }
    end
    yield code, err, dir
  end
end

variant(BASE + UNRELATED) do |code, err, dir|
  line = singleton_line(err)
  suite.check("an unrelated class's maker is placed on it (#{line})", line.include?('StOther (zap)') && !line.include?('StBase'))
  suite.check('the wrapper with a bare super compiles when only an unrelated class has singletons',
              compiled?(code, 'StWrap_run_impl'))

  build = ENV['CC_GENERATED_ONLY'] == '1' ? nil : Bc2cppFixtureRuntime.full_or_build
  if build.nil?
    puts '  SKIP singleton taint behaviour: needs a full-core libmruby (BC2CPP_MRUBY_FULL, or rake and g++)'
  else
    scenario = <<~CPP
      static mrb_value st_new(mrb_state* M, const char* cls) {
        return mrb_funcall_argv(M, mrb_obj_value(mrb_class_get(M, cls)), mrb_intern_lit(M, "new"), 0, nullptr);
      }
      static int scenario(mrb_state* M) {
        mrb_value u = st_new(M, "StUser");
        mrb_value b = st_new(M, "StBase");
        call(M, "base_run", u, "call", 1, &b);
        mrb_value o = st_new(M, "StOther");
        mrb_value t = st_new(M, "StOtherUser");
        call(M, "other_plain", t, "try", 1, &o);
        call(M, "other_mark", o, "mark", 0, nullptr);
        call(M, "other_marked", t, "try", 1, &o);
        call(M, "base_run_after", u, "call", 1, &b);
        return 0;
      }
    CPP
    built, output = Bc2cppFixtureRuntime.run(dir, err, OWNERS, scenario, build: build, full: true)
    suite.check('fixture builds and runs', built)
    sections = Bc2cppFixtureRuntime.sections(output)
    plain = ->(lines) { lines.to_a.reject { |l| l.start_with?('  dispatches=') } }
    interpreted = plain.call(sections['interpreted'])
    compiled = plain.call(sections['compiled'])
    suite.check('the interpreter runs the wrapper and the singleton method',
                interpreted.include?('base_run => [:wrap, [:base, 1]]') &&
                interpreted.include?('other_plain => :plain') && interpreted.include?('other_marked => :zapped'))
    suite.check('compiled matches interpreted', !compiled.empty? && compiled == interpreted)
  end
end

variant(BASE + UNRELATED, env: { 'BC2CPP_SINGLETON_TAINT' => '0' }) do |code, _err, _dir|
  suite.check('with BC2CPP_SINGLETON_TAINT=0 (the whole-world rule) the wrapper stays interpreted',
              !compiled?(code, 'StWrap_run_impl'))
end

variant(BASE + UNRELATED + OWNER_RUN) do |code, err, _dir|
  suite.check("a singleton of the wrapper's own class that may answer run keeps it interpreted (#{singleton_line(err)})",
              singleton_line(err).include?('StBase (run)') && !compiled?(code, 'StWrap_run_impl'))
end

variant(BASE + OWNER_ANY) do |code, err, _dir|
  suite.check("a singleton of the wrapper's own class that may answer anything keeps it interpreted (#{singleton_line(err)})",
              singleton_line(err).include?('StBase (any name)') && !compiled?(code, 'StWrap_run_impl'))
end

variant(BASE + UNRELATED + PROVEN_BLOCK_CALLER) do |code, _err, _dir|
  suite.check('a block caller proven to hold an instance of a class the module is prepended to keeps it interpreted',
              !compiled?(code, 'StWrap_run_impl'))
end

variant(BASE + UNRELATED + UNRELATED_BLOCK_CALLER) do |code, _err, _dir|
  suite.check('a block caller proven to hold only an unrelated class leaves the wrapper compiled',
              compiled?(code, 'StWrap_run_impl'))
end

variant(BASE, foreign: [['st_outside.rb', OUTSIDE_EXTEND], ['st_data.rb', OUTSIDE_DATA]]) do |code, err, _dir|
  line = singleton_line(err)
  suite.check("an outside `extend` in an instance method taints its class with the module's methods (#{line})",
              line.include?('StOutside (zap2)'))
  suite.check('an outside Symbol :extend or "extend" String is no maker', !line.include?('StData') && !line.include?('not placed'))
  suite.check('the wrapper compiles beside an outside extend of an unrelated class', compiled?(code, 'StWrap_run_impl'))
end

variant(BASE, foreign: [['st_unplaced.rb', OUTSIDE_UNPLACED]]) do |code, err, _dir|
  line = singleton_line(err)
  suite.check("an outside extend of an unknown receiver is not placed (#{line})", line.include?('not placed'))
  suite.check('the wrapper stays interpreted when a maker is not placed', !compiled?(code, 'StWrap_run_impl'))
end

suite.finish!
