#!/usr/bin/env ruby
# frozen_string_literal: true

# RUBY_EXACT_PAST_NATIVE_ARMS and NILABLE_CLASS_TESTS: a zero-argument name an RGSS native also answers (`x`, `y`,
# `width`, `dispose`) went to the native-arm block before any receiver proof was read, so even a receiver the
# exact-class flow proves to be one Ruby class got the native arms and a class-test chain (POLY_SMALL_N). Such a
# receiver now skips the native arms, and a nil-or-K one takes the nil test and K's direct call (NILABLE_RECEIVER)
# also when that only removes class tests. Generated end to end by bc2cpp.rb (no mruby build needed);
# BC2CPP_RUBY_EXACT_PAST_NATIVE=0 BC2CPP_NILABLE_CLASS_TESTS=0 is the output before them.
#
#   MRBC=path/to/mrbc ruby scripts/bc2cpp/nilable_class_tests_check.rb
require 'tmpdir'
require_relative 'check_support'
require_relative 'fixture_runtime'

# The fixtures declare no RBS; the repository's signatures name engine classes these fixtures lack.
ENV['BC2CPP_SIG_DIRS'] = ''

suite = FixtureCheck.new('nilable_class_tests_check')
check = suite.method(:check)
suite.require_mrbc!

SOURCE = <<~RUBY
  class Spot
    def initialize
      @x = 1
      nil
    end

    def x
      @x + 1
    end
  end

  class Mark
    def x
      2
    end
  end

  class Holder
    def initialize
      @spot = nil
      nil
    end

    def place
      @spot = Spot.new
      nil
    end

    def where
      @spot.x
    end

    def mark
      Mark.new.x
    end
  end
RUBY

# { "Owner#name" => generated body } of one run with the given switches.
bodies = lambda do |env|
  env.each { |k, v| ENV[k] = v }
  Dir.mktmpdir('nilable_class_tests') do |dir|
    code, = Bc2cppFixtureRuntime.generate(SOURCE, dir, only_owners: %w[Spot Mark Holder])
    code.split(%r{^(?=// \w+#)}).to_h { |part| [part[%r{\A// (\S+)}, 1], part] }
  end
ensure
  env.each_key { |k| ENV.delete(k) }
end
on = bodies.call({})
off = bodies.call('BC2CPP_RUBY_EXACT_PAST_NATIVE' => '0', 'BC2CPP_NILABLE_CLASS_TESTS' => '0')
class_tests = ->(body) { body.to_s.scan('mrb_obj_class(M,').size }

check.call('before, `@spot.x` and `Mark.new.x` are class-test chains behind the RGSS arms',
           off['Holder#where'].to_s.include?('POLY_SMALL_N :x') && off['Holder#mark'].to_s.include?('POLY_SMALL_N :x'))
check.call('a nil-or-Spot receiver takes the nil test and Spot#x',
           on['Holder#where'].to_s.include?('NILABLE_RECEIVER :x -- receiver is nil or exactly Spot') &&
             !on['Holder#where'].include?('POLY_SMALL_N') && class_tests.call(on['Holder#where']).zero?)
check.call('an exact Mark receiver calls Mark#x with no class test',
           !on['Holder#mark'].to_s.include?('POLY_SMALL_N') && class_tests.call(on['Holder#mark']).zero?)

suite.finish!
