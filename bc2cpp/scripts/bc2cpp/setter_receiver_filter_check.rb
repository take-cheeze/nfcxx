#!/usr/bin/env ruby
# frozen_string_literal: true

# SETTER_RECEIVER_FILTER: an ivar's setter pool joins only the `x=` sites whose receiver may be of its class family.
# A site whose receiver classes all reach another class's `x=` stores into that class's slot. Generated end to end by
# bc2cpp.rb (no mruby build needed); BC2CPP_SETTER_RECEIVER_FILTER=0 is the output before it.
#
#   MRBC=path/to/mrbc ruby scripts/bc2cpp/setter_receiver_filter_check.rb
require 'tmpdir'
require_relative 'check_support'
require_relative 'fixture_runtime'

# The fixtures declare no RBS; the repository's signatures name engine classes these fixtures lack.
ENV['BC2CPP_SIG_DIRS'] = ''

suite = FixtureCheck.new('setter_receiver_filter_check')
check = suite.method(:check)
suite.require_mrbc!

SOURCE = <<~RUBY
  class Slot
    attr_accessor :items

    def initialize
      @items = []
      nil
    end

    def count
      @items.size
    end
  end

  # Another class answering items=, handed a value the flow cannot name.
  class Ledger
    def items=(v)
      @items = v
    end
  end

  class Filler
    def fill(source)
      Slot.new.items = [1]
      Ledger.new.items = source.list
      nil
    end
  end

  # Here the unnamed value goes to a Slot, so its pool has no class.
  class Mixed
    attr_accessor :items

    def initialize
      @items = []
      nil
    end

    def count
      @items.size
    end
  end

  class MixedFiller
    def fill(source)
      Mixed.new.items = source.list
      nil
    end
  end
RUBY

# { "Owner#name" => generated body } of one run.
bodies = lambda do |flag|
  ENV['BC2CPP_SETTER_RECEIVER_FILTER'] = flag
  Dir.mktmpdir('setter_receiver_filter') do |dir|
    code, = Bc2cppFixtureRuntime.generate(SOURCE, dir, only_owners: %w[Slot Ledger Filler Mixed MixedFiller])
    code.split(%r{^(?=// \w+#)}).to_h { |part| [part[%r{\A// (\S+)}, 1], part] }
  end
ensure
  ENV.delete('BC2CPP_SETTER_RECEIVER_FILTER')
end
on = bodies.call('1')
off = bodies.call('0')
exact_size = ->(body) { body.to_s.include?('CLOSED_WORLD_NATIVE_EXACT :size') }

check.call("another class's setter site does not reach the pool", exact_size.call(on['Slot#count']))
check.call('without the filter every items= site joins it', !exact_size.call(off['Slot#count']))
check.call('a site reaching the class still drops an unnamed value into it', !exact_size.call(on['Mixed#count']))

suite.finish!
