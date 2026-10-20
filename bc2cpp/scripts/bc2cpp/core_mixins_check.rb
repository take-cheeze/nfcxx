#!/usr/bin/env ruby
# frozen_string_literal: true

# CORE_MIXINS (docs/adr/0261): mruby's own Enumerable/Comparable as known
# mixins, and the core Ruby methods bc2cpp inlines behind an exact receiver
# guard (Numeric#positive?/#negative? on Integer/Float, Enumerable#min/#max on
# an exact Array of Integers or non-NaN Floats).
#
# 1. Host only: the model verifies a core tree that matches it, refuses one
#    that does not (another definer, an alias, a native registration, a changed
#    body), and matches the real 3rd/mruby when it is present.
# 2. With MRBC: `include Enumerable` is a known ancestor unless the closed
#    world declares its own; the inlines appear in a closed world and go away
#    when anything on the receiver's ancestry redefines the name, when a
#    prepend or dynamic installer could; a
#    module_function body whose blocks never look at self is called directly.
# 3. With MRBC, BC2CPP_MRUBY_FULL and g++: values, exceptions and dispatch
#    counts against the interpreter.
#
# Usage: [MRBC=path/to/mrbc BC2CPP_MRUBY_FULL=dir] ruby scripts/bc2cpp/core_mixins_check.rb

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
           found.one? && found.first.owner == 'Enumerable' && found.first.body == CoreMixins.normalize(CoreMixins::MIN_BODY.lines))
check.call('an alias of the name is a definer of its own',
           CoreMixins.definers_in('x.rb', sample, 'member?').map(&:alias_only) == [true])
check.call('a singleton def is a different owner',
           CoreMixins.definers_in('x.rb', sample, 'positive?').map(&:owner).sort == ['Numeric', 'Numeric.singleton'])
check.call('a longer name is not a definer of the shorter one', CoreMixins.definers_in('x.rb', sample, 'posi').empty?)

Dir.mktmpdir do |dir|
  write = lambda do |rel, text|
    path = File.join(dir, rel)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, text)
    path
  end
  numeric = "class Numeric\n  def positive?\n    self > 0\n  end\n\n  def negative?\n    self < 0\n  end\nend\n"
  enum = "module Enumerable\n#{CoreMixins::MIN_BODY.gsub(/^/, '  ')}\n#{CoreMixins::MAX_BODY.gsub(/^/, '  ')}end\n"
  range = "class Range\n  def min(&block); end\n  def max(&block); end\nend\n"
  core = lambda do |numeric_text: numeric, enum_text: enum, range_text: range, extra: nil|
    paths = [write.call('3rd/mruby/mrbgems/mruby-numeric-ext/mrblib/numeric_ext.rb', numeric_text),
             write.call('3rd/mruby/mrblib/enum.rb', enum_text),
             write.call('3rd/mruby/mrbgems/mruby-range-ext/mrblib/range.rb', range_text)]
    paths << write.call('3rd/mruby/mrbgems/mruby-other/mrblib/other.rb', extra) if extra
    paths
  end
  natives = { 'min' => ['/x/3rd/mruby/mrbgems/mruby-time/src/time.c'] }
  all = %w[positive? negative? min max].to_set
  check.call('a core tree that matches the model verifies every method', CoreMixins.verified(core.call, natives) == all)
  check.call('a changed body turns the method off',
             !CoreMixins.verified(core.call(numeric_text: numeric.sub('self > 0', 'self >= 0')), natives).include?('positive?') &&
               CoreMixins.verified(core.call(numeric_text: numeric.sub('self > 0', 'self >= 0')), natives).include?('negative?'))
  check.call('a second Ruby definer turns it off',
             !CoreMixins.verified(core.call(extra: "class Integer\n  def positive?; true; end\nend\n"), natives).include?('positive?'))
  check.call('an alias of the name turns it off',
             !CoreMixins.verified(core.call(extra: "class Array\n  alias min first\nend\n"), natives).include?('min') &&
               CoreMixins.verified(core.call(extra: "class Array\n  alias min first\nend\n"), natives).include?('max'))
  check.call('an unexpected native registration turns it off',
             !CoreMixins.verified(core.call, natives.merge('min' => ['/x/mruby-rgss/src/lib.cxx'])).include?('min') &&
               !CoreMixins.verified(core.call, natives.merge('positive?' => ['/x/anything.c'])).include?('positive?'))
  check.call('the Range definers are part of the model (a missing one turns min off)',
             !CoreMixins.verified(core.call(range_text: "class Range\nend\n"), natives).include?('min'))
  check.call('no sources prove nothing', CoreMixins.verified(nil, natives).empty? && CoreMixins.verified(core.call, nil).empty?)
end

real = File.join(ROOT, '3rd/mruby/mrblib/enum.rb')
if File.exist?(real)
  require_relative '../../tools/bc2cpp/compiled_gems'
  require_relative '../../tools/bc2cpp/bc2cpp'
  native = core_native_srcs("#{ROOT}/3rd/mruby") + Dir["#{ROOT}/mruby-rgss/src/*.cxx"] + external_gem_native_srcs(ROOT)
  # Program-owned core files still participate in source-model verification.
  ruby = (core_compiled_mrblib_srcs(ROOT) + foreign_mrblib_srcs(ROOT)).uniq
  verified = CoreMixins.verified(ruby, extract_native_method_sources(native))
  check.call('the real 3rd/mruby still matches every modelled method (review CoreMixins::METHODS when this fails)',
             verified == Set.new(CoreMixins::METHODS.map(&:name)))
else
  puts '  SKIP the real 3rd/mruby is not checked out'
end

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

  inlines = <<~RUBY
    class CmProbe
      def lo(a, b); [a, b].min; end
      def hi(arr); arr.max; end
      def sgn(x); x.positive? ? 1 : 0; end
      def neg(x); x.negative? ? 1 : 0; end
      def with_block(arr); arr.min { |a, b| b <=> a }; end
    end
  RUBY
  markers = lambda do |code|
    { min: code.include?('CORE_MIN_MAX :min'), max: code.include?('CORE_MIN_MAX :max'),
      pos: code.include?('CORE_NUMERIC_SIGN :positive?'), neg: code.include?('CORE_NUMERIC_SIGN :negative?') }
  end
  world = lambda do |extra|
    Dir.mktmpdir do |dir|
      code, err = runtime.generate("#{extra}\n#{inlines}", dir)
      [code, err]
    end
  end

  puts '-- generated code'
  code, err = world.call('')
  everything = { min: true, max: true, pos: true, neg: true }
  check.call('a closed world with untouched core sources inlines all four', markers.call(code) == everything)
  check.call('the build reports the verified methods',
             err.include?("== core Ruby methods verified against the build's sources (CORE_MIXINS): max, min, negative?, positive? =="))
  check.call('a block-taking min keeps its dispatch', !body_of.call(code, 'CmProbe_with_block').include?('CORE_MIN_MAX'))
  check.call('the else arm is the ordinary dispatch', body_of.call(code, 'CmProbe_lo').match?(/if \(!bc2cpp_mm_\d+_done\) \{\n\s+r\d+ = bc2cpp_send\(/))
  {
    'class Array; def min; 0; end; end' => { min: false, max: true, pos: true, neg: true },
    'class Array; def each; end; end' => { min: false, max: false, pos: true, neg: true },
    'module Enumerable; def max; 1; end; end' => { min: true, max: false, pos: true, neg: true },
    'class Integer; def positive?; true; end; end' => { min: true, max: true, pos: false, neg: true },
    'class Numeric; def negative?; false; end; end' => { min: true, max: true, pos: true, neg: false },
    'class Object; def positive?; true; end; end' => { min: true, max: true, pos: false, neg: true },
    'module CmShadow; def max; 1; end; end; class Array; include CmShadow; end' =>
      { min: true, max: false, pos: true, neg: true },
    'module CmPre; def min; 1; end; end; class Array; prepend CmPre; end' =>
      { min: false, max: false, pos: true, neg: true },
    'class Integer; alias_method :positive?, :zero?; end' => { min: true, max: true, pos: false, neg: true },
    # A literal class-body define_method is a definition like `def` (ADR 0288): it shadows only its own name.
    'class Integer; define_method(:negative?) { true }; end' => { min: true, max: true, pos: true, neg: false },
    'class Integer; define_method("negat" + "ive?") { true }; end' => { min: false, max: false, pos: false, neg: false },
    'class Float; def >(o); false; end; end' => { min: true, max: true, pos: false, neg: true }
  }.each do |extra, want|
    code, = world.call(extra)
    got = markers.call(code)
    check.call("`#{extra}` #{want == got ? 'leaves exactly the unshadowed inlines' : "-> #{got}, want #{want}"}", got == want)
  end
  code, = world.call('class CmSub < Array; def each; yield 42; end; def min; 7; end; end')
  check.call('a subclass of Array with its own each/min is not the exact-Array receiver, and shadows nothing on Array',
             markers.call(code) == everything)

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
        ['min of 50 Integers', 'max of 50 Integers', 'min of 50 Floats', 'max of 50 Floats', '5.positive?', '-1.5.negative?'].each do |label|
          check.call("#{label} makes no dynamic dispatch", dispatches.call(label) == 0)
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
