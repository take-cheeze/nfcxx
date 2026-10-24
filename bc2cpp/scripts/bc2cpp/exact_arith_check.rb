#!/usr/bin/env ruby
# frozen_string_literal: true

# EXACT_ARITH: the exact-class flow gives `+ - * /` on numbers the Integer/Float result the numeric flow does, under
# the same gates (numeric_op_native?, numeric_nil_raises?), so an ivar updated by arithmetic keeps its class pool.
# Generated end to end by bc2cpp.rb (no mruby build needed); BC2CPP_EXACT_ARITH=0 is the output before it.
#
#   MRBC=path/to/mrbc ruby scripts/bc2cpp/exact_arith_check.rb
require 'tmpdir'
require_relative 'check_support'
require_relative 'fixture_runtime'

# The fixtures declare no RBS; the repository's signatures name engine classes these fixtures lack.
ENV['BC2CPP_SIG_DIRS'] = ''

suite = FixtureCheck.new('exact_arith_check')
check = suite.method(:check)
suite.require_mrbc!

SOURCE = <<~RUBY
  class Counter
    def initialize
      @count = 0
      @steps = nil
      nil
    end

    def bump
      @count = @count + 1
      @steps = (@steps || 0) + 1
      nil
    end

    def lower(n)
      @count = @count - 3
      @count = @count / 2
      nil
    end
  end

  class User
    def go(c)
      c.lower(3)
      nil
    end
  end
RUBY

REDEFINED = <<~RUBY
  class Integer
    def +(other)
      self
    end
  end
RUBY

# The class pool lines of one run.
pools = lambda do |source, flag|
  ENV['BC2CPP_EXACT_ARITH'] = flag
  Dir.mktmpdir('exact_arith') do |dir|
    _code, stderr = Bc2cppFixtureRuntime.generate(source, dir, only_owners: %w[Counter User Integer])
    stderr.lines.grep(/CLASSIVAR Counter#/).map(&:strip)
  end
ensure
  ENV.delete('BC2CPP_EXACT_ARITH')
end
on = pools.call(SOURCE, '1')
off = pools.call(SOURCE, '0')

check.call('`@count + 1`, `- 3` and `/ 2` keep an Integer pool', on.include?('CLASSIVAR Counter#@count (INT)'))
check.call('`(@steps || 0) + 1` is Integer after nil', on.include?('CLASSIVAR Counter#@steps (INT|NIL)'))
check.call('without EXACT_ARITH the pool is dropped', off.none? { |line| line.start_with?('CLASSIVAR Counter#@count') })
check.call('a program redefining Integer#+ keeps it dropped',
           pools.call(SOURCE + REDEFINED, '1').none? { |line| line.start_with?('CLASSIVAR Counter#@count') })

suite.finish!
