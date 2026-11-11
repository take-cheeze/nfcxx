#!/usr/bin/env ruby
# frozen_string_literal: true

# INITIALIZER_SITE / INITIALIZER_DIRECT: the evidence InitializerTables.proven reads. Every emitted copy of a
# construction site carries one SITE marker, and the copies that reach `#initialize` only through its `_impl` carry a
# DIRECT marker: a keyword-declaring initialize called without keywords, a block in a method, an unrolled `n=*` and
# a guarded construct whose else arm is a NEW_IDENTITY violation. A site whose class is not one known class
# (a polymorphic receiver) keeps its by-name initialize and is not direct. Generated end to end by bc2cpp.rb.
#
#   MRBC=path/to/mrbc ruby scripts/bc2cpp/initializer_sites_check.rb
require 'json'
require 'tmpdir'
require_relative 'check_support'
require_relative 'fixture_runtime'

# The fixtures declare no RBS; the repository's signatures name engine classes these fixtures lack.
ENV['BC2CPP_SIG_DIRS'] = ''

suite = FixtureCheck.new('initializer_sites_check')
check = suite.method(:check)
suite.require_mrbc!

# Game::MoveRoute and Game::Timer are DIRECT_CONSTRUCT_TARGETS owners (mruby-rpg2k's own classes).
SOURCE = <<~RUBY
  module Game
    class MoveRoute
      def initialize(commands, repeat: false, skippable: false)
        @commands = commands
        @repeat = repeat
        @skippable = skippable
        nil
      end
    end

    class Timer
      def initialize(a, b)
        @a = a
        @b = b
        nil
      end
    end
  end

  class Maker
    def keywordless
      Game::MoveRoute.new([1])
    end

    def keyword
      Game::MoveRoute.new([1], repeat: true)
    end

    def in_block
      [1].each { |x| Game::Timer.new(x, 2) }
    end

    def unrolled
      Game::Timer.new(*[1, 2])
    end

    def polymorphic(flag)
      klass = flag ? Game::Timer : Game::MoveRoute
      klass.new(1, 2)
    end
  end
RUBY

code, err = Dir.mktmpdir('initializer_sites') do |dir|
  Bc2cppFixtureRuntime.generate(SOURCE, dir, only_owners: %w[Game::MoveRoute Game::Timer Maker])
end
evidence = JSON.parse(err.lines.grep(/^INITIALIZER_TABLE_EVIDENCE /).first.delete_prefix('INITIALIZER_TABLE_EVIDENCE '))
direct = evidence.fetch('direct').map { |label, index, owner| [label.to_s, index, owner] }

# { "Owner#name" => [[label, index]] }: the SITE markers of each generated body.
sites = code.split(%r{^(?=// \w+#)}).to_h do |part|
  [part[%r{\A// (\S+)}, 1], part.scan(%r{// INITIALIZER_SITE (\w+):(\d+)}).map { |label, index| [label, index.to_i] }]
end
direct_in = lambda do |method, owner|
  sites.fetch(method).all? { |label, index| direct.include?([label, index, owner]) } && !sites.fetch(method).empty?
end

check.call('a keyword-declaring initialize called without keywords is a direct construct',
           sites.fetch('Maker#keywordless').size == 1 && direct_in.call('Maker#keywordless', 'Game::MoveRoute') &&
           code.include?('Game__MoveRoute_initialize_impl(M, r2, r3, mrb_nil_value(), 0, mrb_nil_value(), 0)'))
check.call('a call with the keyword is a direct construct', direct_in.call('Maker#keyword', 'Game::MoveRoute'))
check.call('a construct inside a block is direct', direct_in.call('Maker#in_block', 'Game::Timer'))
check.call('an unrolled n=* construct is one site copy, direct',
           sites.fetch('Maker#unrolled').size == 1 && direct_in.call('Maker#unrolled', 'Game::Timer'))
check.call('a polymorphic class receiver keeps its by-name initialize',
           sites.fetch('Maker#polymorphic').size == 1 &&
           direct.none? { |label, index, _| sites.fetch('Maker#polymorphic').include?([label, index]) })
check.call('no site has more than one copy marker',
           sites.values.all? { |list| list.uniq.size == list.size })

suite.finish!
