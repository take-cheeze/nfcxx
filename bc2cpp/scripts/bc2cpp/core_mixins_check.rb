#!/usr/bin/env ruby
# frozen_string_literal: true

# CORE_MIXINS: mruby's own Enumerable/Comparable as known
# mixins, and the definer scan (CoreMixins.definers_in) the source checks use.
# The core Ruby methods that were inlined from a verified model (Numeric#
# positive?/#negative?, Enumerable#min/#max) are no longer modelled, so they
# keep the ordinary dispatch.
#
# 1. Host only: the definer scan reads one def, alias and define_method at a time.
# 2. With MRBC: `include Enumerable` is a known ancestor unless the closed
#    world declares its own; the four methods keep their dispatch; a
#    module_function body whose blocks never look at self is called directly.
# 3. With MRBC, BC2CPP_MRUBY_FULL and g++: values, exceptions against the interpreter.
#
# Usage: [MRBC=path/to/mrbc BC2CPP_MRUBY_FULL=dir] ruby scripts/bc2cpp/core_mixins_check.rb

# The fixture program defines none of the engine's classes, which sig/bc2cpp/declarations.rbs declares, so the
# shipped signatures would all be unusable (TC1003). Checked against no signature world, as block_iterator_direct_check does.
ENV['BC2CPP_SIG_DIRS'] = ''

require 'set'
require 'tmpdir'
require 'fileutils'
require_relative '../../tools/bc2cpp/core_mixins'

failures = []
check = lambda do |what, condition|
  puts "  #{condition ? 'ok  ' : 'FAIL'} #{what}"
  failures << what unless condition
end

ROOT = File.expand_path('../..', __dir__)

puts '-- model (host)'
check.call('Enumerable and Comparable are the core mixins',
           CoreMixins.core_mixin?('Enumerable') && CoreMixins.core_mixin?('::Comparable') && !CoreMixins.core_mixin?('Kernel') &&
             !CoreMixins.core_mixin?('Foo::Enumerable'))

sample = <<~RUBY
  module Enumerable
    # a comment
    def min(&block)
      flag = true  # 1st element?
      result = nil
      self.each {|*val|
        val = val.__svalue
        if flag
          result = val
          flag = false
        else
          if block
            result = val if block.call(val, result) < 0
          else
            result = val if (val <=> result) < 0
          end
        end
      }
      result
    end

    alias member? include?
  end

  class Numeric
    def positive?
      self > 0
    end

    def self.positive?; end
  end
RUBY
found = CoreMixins.definers_in('x/mrblib/enum.rb', sample, 'min')
check.call('a def is found with its enclosing module and normalized body',
           found.one? && found.first.owner == 'Enumerable' &&
             found.first.body == 'def min(&block) flag = true result = nil self.each {|*val| val = val.__svalue if flag ' \
                                 'result = val flag = false else if block result = val if block.call(val, result) < 0 else ' \
                                 'result = val if (val <=> result) < 0 end end } result end')
check.call('an alias of the name is a definer of its own',
           CoreMixins.definers_in('x.rb', sample, 'member?').map(&:alias_only) == [true])
check.call('a singleton def is a different owner',
           CoreMixins.definers_in('x.rb', sample, 'positive?').map(&:owner).sort == ['Numeric', 'Numeric.singleton'])
check.call('a longer name is not a definer of the shorter one', CoreMixins.definers_in('x.rb', sample, 'posi').empty?)

if ENV['MRBC']
  require_relative '../../tools/bc2cpp/bc2cpp'
  require_relative 'fixture_runtime'
  runtime = Bc2cppFixtureRuntime
  body_of = lambda do |code, fn|
    code[/^mrb_value #{fn}_impl\(mrb_state\* M.*?(?=^(?:static )?mrb_value \w+\(mrb_state\* M|\z)/m].to_s
  end

  puts '-- known mixins'
  Dir.mktmpdir do |dir|
    path = File.join(dir, 'mixins.rb')
    File.write(path, <<~RUBY)
      class CmBag
        include Enumerable
        include Comparable
        def each; yield 1; end
        def <=>(other); 0; end
      end
      module CmOwn
        module Enumerable
          def each_pair_of; end
        end
        class Inner
          include Enumerable
        end
      end
      class CmRuntime
        include(Object.const_get(:Enumerable))
      end
    RUBY
    ireps, root_label = compile_ireps(path, 'bc2cpp_core_mixins', dir)
    _registry, _superclass_of, _constants, included, _prepended, unknown = build_registry(ireps, root_label)
    check.call('include Enumerable / Comparable is a known ancestor of the class', included['CmBag'] == %w[Enumerable Comparable] &&
                                                                                !unknown.include?('CmBag'))
    check.call('an Enumerable the closed world declares in scope is that module, not the core one',
               included['CmOwn::Inner'] == ['CmOwn::Enumerable'])
    check.call('a computed include stays an unknown mixin', unknown.include?('CmRuntime') && included['CmRuntime'].nil?)
  end

  puts '-- generated code'
  Dir.mktmpdir do |dir|
    code, = runtime.generate(<<~RUBY, dir)
      class CmProbe
        def lo(a, b); [a, b].min; end
        def hi(arr); arr.max; end
        def sgn(x); x.positive? ? 1 : 0; end
        def neg(x); x.negative? ? 1 : 0; end
      end
    RUBY
    check.call('no core method is inlined: min, max, positive? and negative? keep the ordinary dispatch',
               !code.include?('CORE_MIN_MAX') && !code.include?('CORE_NUMERIC_SIGN'))
  end

  puts '-- module_function bodies with blocks'
  Dir.mktmpdir do |dir|
    code, = runtime.generate(<<~RUBY, dir)
      module CmMod
        def sum_to(n)
          total = 0
          [1, 2, 3].each { |i| total += i + n }
          total
        end

        def observes(n)
          total = 0
          [1, 2, 3].each { |i| total += n + @bias.to_i }
          total
        end

        def deep(n)
          total = 0
          [1, 2].each { |i| [3, 4].each { |j| total += i * j + n } }
          total
        end

        def deep_self(n)
          total = 0
          [1, 2].each { |i| [3, 4].each { |j| total += n + (n.equal?(self) ? 1 : 0) } }
          total
        end

        module_function :sum_to, :observes, :deep, :deep_self
      end
      class CmCaller
        def call_sum; CmMod.sum_to(3); end
        def call_observes; CmMod.observes(3); end
        def call_deep; CmMod.deep(3); end
        def call_deep_self; CmMod.deep_self(3); end
      end
    RUBY
    check.call('a module_function body whose block never looks at self is called directly',
               body_of.call(code, 'CmCaller_call_sum').include?('CLOSED_WORLD_CONSTANT_OBJECT :sum_to'))
    check.call('and so is one whose nested blocks do not either',
               body_of.call(code, 'CmCaller_call_deep').include?('CLOSED_WORLD_CONSTANT_OBJECT :deep'))
    check.call('a block that reads an ivar keeps the dispatch (the copy runs with the module as self)',
               !body_of.call(code, 'CmCaller_call_observes').include?('CLOSED_WORLD_CONSTANT_OBJECT'))
    check.call('a nested block that reads self through an upvar keeps the dispatch',
               !body_of.call(code, 'CmCaller_call_deep_self').include?('CLOSED_WORLD_CONSTANT_OBJECT'))
  end

  full = runtime.full
  if full.nil? || !runtime.compiler?
    puts '  SKIP run: set BC2CPP_MRUBY_FULL (libmruby.a with the full-core gems, from the patched 3rd/mruby) and have g++'
  else
    puts '-- values and dispatches on real mruby, interpreted and compiled'
    Dir.mktmpdir do |dir|
      source = <<~RUBY
        class CmProbe
          def lo(arr); arr.min; end
          def hi(arr); arr.max; end
          def sgn(x); x.positive?; end
          def neg(x); x.negative?; end
        end
        class CmSub < Array
          def each; yield 42; end
        end
        module CmMod
          def sum_to(n)
            total = 0
            [1, 2, 3].each { |i| total += i + n }
            total
          end

          module_function :sum_to
        end
        class CmCaller
          def call_sum; CmMod.sum_to(3); end
        end
        def cm_cases
          [[3, 1, 2], [1], [], [5, 5, 5], [-3, -7, 0], (1..200).to_a.reverse, [2.5, 1.5, 3.5], [1.5], [-0.0, 0.0], [0.0, -0.0],
           [1.0, Float::NAN], [Float::NAN, 1.0], [1, 2.5], [2.5, 1], ['b', 'a'], [1, nil], [nil], [2**70, 3], [3, 2**70],
           [1, 2, 'x'], [1.0, 2.0, 'x'], [Float::INFINITY, 1.0], [-Float::INFINITY, 1.0], CmSub.new([3, 1]),
           [[2], [1]], [:b, :a], [1, 2, 3].each_slice(2).to_a]
        end
        def cm_numbers
          [5, -5, 0, 2.5, -2.5, 0.0, -0.0, Float::NAN, 2**70, -(2**70), 'str', nil, Rational(1, 2), Rational(-1, 2), :sym, [1]]
        end
        def cm_drive
          probe = CmProbe.new
          out = []
          cm_cases.each do |arr|
            [:lo, :hi].each do |m|
              out << begin
                probe.send(m, arr)
              rescue => e
                e.class
              end
            end
          end
          cm_numbers.each do |x|
            [:sgn, :neg].each do |m|
              out << begin
                probe.send(m, x)
              rescue => e
                e.class
              end
            end
          end
          out
        end
      RUBY
      _code, err = runtime.generate(source, dir, only_owners: %w[CmProbe CmMod CmMod.singleton CmCaller])
      body = <<~CPP
        static int scenario(mrb_state* M) {
          call(M, "drive", mrb_top_self(M), "cm_drive");
          mrb_value probe = mrb_obj_new(M, mrb_class_get(M, "CmProbe"), 0, nullptr);
          auto ints = mrb_ary_new(M);
          for (int i = 0; i < 50; ++i) mrb_ary_push(M, ints, mrb_fixnum_value((i * 37) % 101 - 40));
          call(M, "min of 50 Integers", probe, "lo", 1, &ints);
          call(M, "max of 50 Integers", probe, "hi", 1, &ints);
          auto floats = mrb_ary_new(M);
          for (int i = 0; i < 50; ++i) mrb_ary_push(M, floats, mrb_float_value(M, ((i * 37) % 101 - 40) / 4.0));
          call(M, "min of 50 Floats", probe, "lo", 1, &floats);
          call(M, "max of 50 Floats", probe, "hi", 1, &floats);
          mrb_value five = mrb_fixnum_value(5), minus = mrb_float_value(M, -1.5);
          call(M, "5.positive?", probe, "sgn", 1, &five);
          call(M, "-1.5.negative?", probe, "neg", 1, &minus);
          mrb_value caller_obj = mrb_obj_new(M, mrb_class_get(M, "CmCaller"), 0, nullptr);
          call(M, "module function", caller_obj, "call_sum");
          call(M, "module function again", caller_obj, "call_sum");
          return 0;
        }
      CPP
      built, output = runtime.run(dir, err, %w[CmProbe CmMod CmMod.singleton CmCaller], body, build: full, full: true)
      check.call('the fixture compiles and runs against real mruby', built)
      puts output unless built
      if built
        puts output if ENV['BC2CPP_CHECK_VERBOSE']
        sections = runtime.sections(output)
        values = ->(name) { sections.fetch(name, []).reject { |l| l.start_with?('  ') } }
        check.call('every value and every exception class is the interpreter\'s',
                   !values.call('interpreted').empty? && values.call('interpreted') == values.call('compiled'))
        compiled = sections.fetch('compiled', [])
        dispatches = lambda do |label|
          at = compiled.index { |l| l.start_with?("#{label} =>") }
          at && compiled[at + 1][/dispatches=(\d+)/, 1].to_i
        end
        # The first call also resolves the constant once (the site cache).
        check.call('the module_function call with a block is a direct call',
                   dispatches.call('module function again') == 0)
      end
    end
  end
end

if failures.empty?
  puts 'bc2cpp core mixins check: PASS'
else
  warn "bc2cpp core mixins check: #{failures.size} failure(s)"
  exit 1
end
