#!/usr/bin/env ruby
# frozen_string_literal: true

# OPERATOR_SENDS: an ADD/SUB/MUL whose receiver the exact-class flow proves is no number is the one-argument send
# `recv.op(arg)`, so its result has that send's class (`array - [x]` is an Array) and an ivar it is stored in keeps a
# class pool. Generated end to end by bc2cpp.rb (no mruby build needed); BC2CPP_OPERATOR_SENDS=0 is the output before
# it.
#
#   MRBC=path/to/mrbc ruby scripts/bc2cpp/operator_sends_check.rb
require 'tmpdir'
require_relative 'check_support'
require_relative 'fixture_runtime'

# The fixtures declare no RBS; the repository's signatures name engine classes these fixtures lack.
ENV['BC2CPP_SIG_DIRS'] = ''

suite = FixtureCheck.new('operator_sends_check')
check = suite.method(:check)
suite.require_mrbc!

SOURCE = <<~RUBY
  class Bag
    def initialize
      @items = []
      nil
    end

    def drop(x)
      @items = @items - [x]
      nil
    end

    def add(x)
      @items = @items + [x]
      nil
    end

    def count
      @items.size
    end

    def local(x)
      ([1, 2] - [x]).size
    end
  end

  # One store is an operator on a receiver the flow cannot name.
  class Loose
    def initialize
      @items = []
      nil
    end

    def drop(source, x)
      @items = source.list - [x]
      nil
    end

    def count
      @items.size
    end
  end
RUBY

# { "Owner#name" => generated body } of one run.
bodies = lambda do |flag|
  ENV['BC2CPP_OPERATOR_SENDS'] = flag
  Dir.mktmpdir('operator_sends') do |dir|
    code, = Bc2cppFixtureRuntime.generate(SOURCE, dir, only_owners: %w[Bag Loose])
    code.split(%r{^(?=// \w+#)}).to_h { |part| [part[%r{\A// (\S+)}, 1], part] }
  end
ensure
  ENV.delete('BC2CPP_OPERATOR_SENDS')
end
on = bodies.call('1')
off = bodies.call('0')
exact_size = ->(body) { body.to_s.include?('CLOSED_WORLD_NATIVE_EXACT :size') }

check.call('`array - [x]` and `array + [x]` keep the ivar an Array', exact_size.call(on['Bag#count']))
check.call('without OPERATOR_SENDS the operator result is unknown', !exact_size.call(off['Bag#count']))
check.call('a local `[1, 2] - [x]` is an exact Array receiver', exact_size.call(on['Bag#local']))
check.call('an operator on an unknown receiver stays unknown', !exact_size.call(on['Loose#count']))

suite.finish!
