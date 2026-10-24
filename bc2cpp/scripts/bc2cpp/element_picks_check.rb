#!/usr/bin/env ruby
# frozen_string_literal: true

# ELEMENT_PICK_SENDS: `a.first`, `a.last`, `a.find { }` and the like return one element of the Array they are sent
# to, so a value they produce carries that Array's element hint (ELEMENT_CLASS_SUPPORT, guarded) into the Array it is
# stored in (`@x[i] = v`; library writers such as `<<` are not modelled). Read from bc2cpp.rb's
# `== known-array-element-class hints ==` diagnostic; BC2CPP_ELEMENT_PICKS=0 is the output before it.
#
#   MRBC=path/to/mrbc ruby scripts/bc2cpp/element_picks_check.rb
require 'tmpdir'
require_relative 'check_support'
require_relative 'fixture_runtime'

# The fixtures declare no RBS; the repository's signatures name engine classes these fixtures lack.
ENV['BC2CPP_SIG_DIRS'] = ''

suite = FixtureCheck.new('element_picks_check')
check = suite.method(:check)
suite.require_mrbc!

SOURCE = <<~RUBY
  class Thing
    def ok?
      true
    end
  end

  class Shelf
    def initialize
      @things = [Thing.new, Thing.new]
      @front = []
      @found = []
      @mixed = []
      nil
    end

    def keep_front
      @front[0] = @things.first
      @front[1] = @things.last
      nil
    end

    def keep_found
      @found[0] = @things.find { |t| t.ok? }
      nil
    end

    # `first(n)` returns an Array, not an element.
    def keep_mixed
      @mixed[0] = @things.first(1)
      nil
    end
  end
RUBY

# The element hint lines of one run.
hints = lambda do |flag|
  ENV['BC2CPP_ELEMENT_PICKS'] = flag
  Dir.mktmpdir('element_picks') do |dir|
    _code, stderr = Bc2cppFixtureRuntime.generate(SOURCE, dir, only_owners: %w[Thing Shelf])
    stderr.lines.grep(/ELEM_HINT\s+Shelf#/).map { |line| line.split.drop(1).join(' ') }
  end
ensure
  ENV.delete('BC2CPP_ELEMENT_PICKS')
end
on = hints.call('1')
off = hints.call('0')

check.call('`first` and `last` carry the element class', on.include?('Shelf#@front (Array<Thing>)'))
check.call('`find { }` carries the element class', on.include?('Shelf#@found (Array<Thing>)'))
check.call('`first(1)` (an Array) does not', on.none? { |line| line.start_with?('Shelf#@mixed') })
check.call('without ELEMENT_PICKS the picks are unknown', off.none? { |line| line.start_with?('Shelf#@front', 'Shelf#@found') })
check.call('the literal-built Array keeps its hint either way', on.include?('Shelf#@things (Array<Thing>)') &&
                                                               off.include?('Shelf#@things (Array<Thing>)'))

suite.finish!
