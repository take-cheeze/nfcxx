#!/usr/bin/env ruby
# frozen_string_literal: true

# CONSTRUCTOR_OPTIONALS: an optional `initialize` position whose defaults are all literal loads pools the values the
# `new` sites that pass it give, so the ivar it is stored in gets a class pool. Generated end to end by bc2cpp.rb
# (no mruby build needed); BC2CPP_CTOR_OPTIONALS=0 is the output before it.
#
#   MRBC=path/to/mrbc ruby scripts/bc2cpp/constructor_optionals_check.rb
require 'tmpdir'
require_relative 'check_support'
require_relative 'fixture_runtime'

# The fixtures declare no RBS; the repository's signatures name engine classes these fixtures lack.
ENV['BC2CPP_SIG_DIRS'] = ''

suite = FixtureCheck.new('constructor_optionals_check')
check = suite.method(:check)
suite.require_mrbc!

SOURCE = <<~RUBY
  # Every default a literal: @items is the passed Arrays or the nil default.
  class Box
    def initialize(items = nil, name = "box")
      @items = items
      @name = name
      nil
    end

    def count
      (@items || []).size
    end
  end

  # The second default reads the first parameter's register: no optional position is pooled.
  class Pair
    def initialize(first = nil, second = first)
      @first = first
      @second = second
      nil
    end

    def count
      (@first || []).size
    end
  end

  # A keyword call to an initialize without keyword parameters passes its Hash as the optional position.
  class Bag
    def initialize(items = nil)
      @items = items
      nil
    end

    def count
      (@items || []).size
    end
  end

  # One site passes a value the flow cannot name.
  class Crate
    def initialize(items = nil)
      @items = items
      nil
    end

    def count
      (@items || []).size
    end
  end

  class Maker
    def make(source)
      Box.new([1, 2])
      Box.new
      Box.new([3], "named")
      Pair.new([1])
      Bag.new([1])
      Bag.new(tag: 1)
      Crate.new([1])
      Crate.new(source.list)
      nil
    end
  end
RUBY

# { "Owner#name" => generated body } of one run.
bodies = lambda do |flag|
  ENV['BC2CPP_CTOR_OPTIONALS'] = flag
  Dir.mktmpdir('constructor_optionals') do |dir|
    code, = Bc2cppFixtureRuntime.generate(SOURCE, dir, only_owners: %w[Box Pair Bag Crate Maker])
    code.split(%r{^(?=// \w+#)}).to_h { |part| [part[%r{\A// (\S+)}, 1], part] }
  end
ensure
  ENV.delete('BC2CPP_CTOR_OPTIONALS')
end
on = bodies.call('1')
off = bodies.call('0')
exact_size = ->(body) { body.to_s.include?('CLOSED_WORLD_NATIVE_EXACT :size') }

check.call('a literal-default optional position pools the passed Arrays', exact_size.call(on['Box#count']))
check.call('without CONSTRUCTOR_OPTIONALS it does not', !exact_size.call(off['Box#count']))
check.call('a default that reads another parameter refuses the positions', !exact_size.call(on['Pair#count']))
check.call('a keyword call whose Hash lands in the position refuses it', !exact_size.call(on['Bag#count']))
check.call('a passed value the flow cannot name leaves the pool unknown', !exact_size.call(on['Crate#count']))

suite.finish!
