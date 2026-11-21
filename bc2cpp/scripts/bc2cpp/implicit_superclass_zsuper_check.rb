#!/usr/bin/env ruby
# frozen_string_literal: true

# IMPLICIT_SUPERCLASS (zsuper_lookup_plan): a bare `super` in a method of a class whose body names no superclass
# (`class X`, superclass_of :none) is looked up as ZSUPER_LOOKUP does, through bc2cpp_super_call, which follows the
# class's chain at run time. The fixture covers Object's own methods reached that way (initialize_copy through dup,
# method_missing, respond_to_missing?), a module the class includes answering first, a class reopened without a
# superclass after a body that named one, and a method_missing without a block parameter whose super forwards the
# missing call's block (SUPER_NO_CALLER_BLOCK never proves a method_missing blockless: any send can miss). The behaviour part needs BC2CPP_MRUBY_FULL, or rake and a C++ compiler.
ENV['BC2CPP_SIG_DIRS'] = ''

require 'tmpdir'
require_relative 'check_support'
require_relative 'fixture_runtime'

suite = FixtureCheck.new('implicit_superclass_zsuper_check')
suite.require_mrbc!

SOURCE = <<~RUBY
  class IsWrap
    def initialize(items)
      @items = items
    end

    def initialize_copy(other)
      super
      @items = other.instance_variable_get(:@items).dup
    end

    def items = @items

    def method_missing(name, *args, &block)
      return @items.send(name, *args, &block) if @items.respond_to?(name)

      super
    end

    def respond_to_missing?(name, include_private = false)
      @items.respond_to?(name, include_private) || super
    end
  end
  module IsMix
    def label(x) = [:mix, x]
  end
  class IsHost
    include IsMix
    def label(x) = [:host, super]
  end
  class IsBase
    def tag(x) = [:base, x]
  end
  class IsKid < IsBase
  end
  class IsKid
    def tag(x) = [:kid, super]
  end
  module IsMmMod
    def method_missing(name, *args, &blk) = [:mod, name, args, blk&.call]
  end
  class IsMm
    include IsMmMod
    def method_missing(name, *args)
      return [:hi, args] if name == :hi

      super
    end
  end
  # Not an owner of the build, so it stays interpreted: its missing calls reach IsMm#method_missing through OP_SENDB,
  # which hands it the block (a call from C through mrb_funcall_with_block does not).
  class IsMmCaller
    def go = [IsMm.new.hi(1), IsMm.new.other(2) { 7 }, IsMm.new.other(3)]
  end
  class IsUser
    def run_dup(_o)
      a = IsWrap.new([1, 2])
      b = a.dup
      b.items << 3
      [a.items, b.items]
    end
    def run_mm(_o) = IsWrap.new([3, 1, 2]).sort
    def run_mm_miss(_o)
      IsWrap.new([]).no_such_method
    rescue NoMethodError => e
      e.name
    end
    def run_rtm(_o) = [IsWrap.new([]).respond_to?(:push), IsWrap.new([]).respond_to?(:nope)]
    def run_mix(_o) = IsHost.new.label(4)
    def run_reopen(_o) = IsKid.new.tag(5)
    def run_mm_block(_o) = IsMmCaller.new.go
  end
RUBY

OWNERS = %w[IsWrap IsMix IsHost IsBase IsKid IsMmMod IsMm IsUser].freeze

def compiled?(code, name)
  code.match?(/^(?:static )?mrb_value #{name}\(mrb_state\* M/)
end

Dir.mktmpdir('bc2cpp-implicit-superclass-zsuper') do |dir|
  code, err = Bc2cppFixtureRuntime.generate(SOURCE, dir, core: true, only_owners: OWNERS)
  suite.check('zsuper methods of classes with no superclass written compile',
              %w[IsWrap_initialize_copy_impl IsWrap_method_missing_impl IsWrap_respond_to_missing$3f_impl IsHost_label_impl
                 IsKid_tag_impl].all? { |f| compiled?(code, Regexp.escape(f)) })
  # method_missing receives the block of whatever call missed, so its bare super forwards the frame's block.
  suite.check('a method_missing without a block parameter takes its block and forwards it',
              code.include?('mrb_value IsMm_method_missing_impl(mrb_state* M, mrb_value self, mrb_value name, mrb_value args, ' \
                            'mrb_value bc2cpp_blk)'))

  build = ENV['CC_GENERATED_ONLY'] == '1' ? nil : Bc2cppFixtureRuntime.full_or_build
  if build.nil?
    puts '  SKIP implicit superclass zsuper behaviour: needs a full-core libmruby (BC2CPP_MRUBY_FULL, or rake and g++)'
  else
    scenario = <<~CPP
      static int scenario(mrb_state* M) {
        mrb_value u = mrb_funcall_argv(M, mrb_obj_value(mrb_class_get(M, "IsUser")), mrb_intern_lit(M, "new"), 0, nullptr);
        mrb_value nil = mrb_nil_value();
        const char* calls[] = {"run_dup", "run_mm", "run_mm_miss", "run_rtm", "run_mix", "run_reopen", "run_mm_block"};
        for (const char* m : calls) call(M, m, u, m, 1, &nil);
        return 0;
      }
    CPP
    built, output = Bc2cppFixtureRuntime.run(dir, err, OWNERS, scenario, build: build, full: true)
    suite.check('fixture builds and runs', built)
    sections = Bc2cppFixtureRuntime.sections(output)
    plain = ->(lines) { lines.to_a.reject { |l| l.start_with?('  dispatches=') } }
    interpreted = plain.call(sections['interpreted'])
    compiled = plain.call(sections['compiled'])
    suite.check('the interpreter reaches the superclass chain',
                interpreted.include?('run_dup => [[1, 2], [1, 2, 3]]') && interpreted.include?('run_mm => [1, 2, 3]') &&
                interpreted.include?('run_mm_miss => :no_such_method') && interpreted.include?('run_rtm => [true, false]') &&
                interpreted.include?('run_mix => [:host, [:mix, 4]]') && interpreted.include?('run_reopen => [:kid, [:base, 5]]') &&
                interpreted.include?('run_mm_block => [[:hi, [1]], [:mod, :other, [2], 7], [:mod, :other, [3], nil]]'))
    suite.check('compiled matches interpreted', compiled == interpreted)
  end
end

suite.finish!
