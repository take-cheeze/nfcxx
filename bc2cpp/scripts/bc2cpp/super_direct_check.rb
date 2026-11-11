#!/usr/bin/env ruby
# frozen_string_literal: true

# SUPER_DIRECT: the evidence InitializerTables.super_direct reads. A `super` every copy of which calls its target's
# `_impl` carries a SUPER_DIRECT marker and its [content digest, index] key is proven; a `super` resolved at run time
# (a module's, which mixes into an unknown class) has no marker and its key is refused. A key any run refuses, or a
# run without exactly one evidence row, proves nothing. Generated end to end by bc2cpp.rb.
#
#   MRBC=path/to/mrbc ruby scripts/bc2cpp/super_direct_check.rb
require 'json'
require 'tmpdir'
require_relative 'check_support'
require_relative 'fixture_runtime'
require_relative '../../tools/bc2cpp/initializer_tables'

ENV['BC2CPP_SIG_DIRS'] = ''

suite = FixtureCheck.new('super_direct_check')
check = suite.method(:check)
suite.require_mrbc!

SOURCE = <<~RUBY
  module Game
    class Base
      def step
        1
      end

      def scaled(x)
        x * 2
      end

      def mixed
        3
      end
    end

    module Mix
      def mixed
        super + 1
      end
    end

    class Mixed < Base
      include Mix
    end

    class Child < Base
      def step
        super + 10
      end

      def scaled(x)
        super(x) + 1
      end
    end
  end
RUBY

code, err = Dir.mktmpdir('super_direct') do |dir|
  Bc2cppFixtureRuntime.generate(SOURCE, dir, only_owners: %w[Game::Base Game::Mix Game::Mixed Game::Child])
end
row = err.lines.grep(/^#{InitializerTables::PREFIX}/)
check.call('one evidence row', row.size == 1)
evidence = JSON.parse(row.first.delete_prefix(InitializerTables::PREFIX))
bodies = code.split(%r{^(?=// \w+(?:::\w+)*#)}).to_h { |part| [part[%r{\A// (\S+)}, 1], part] }

check.call('a bare super with a known target is marked direct', bodies.fetch('Game::Child#step').include?('// SUPER_DIRECT '))
check.call('super(x) with a known target is marked direct', bodies.fetch('Game::Child#scaled').include?('// SUPER_DIRECT '))
check.call("a module's super is not marked direct", !bodies.fetch('Game::Mix#mixed').include?('// SUPER_DIRECT '))
check.call('the two direct sites are proven', evidence.fetch('super_direct').size == 2)
check.call("the module's site is refused", evidence.fetch('super_refused').size == 1)

run = ->(proven, refused) { { err: "#{InitializerTables::PREFIX}#{JSON.generate(super_direct: proven, super_refused: refused)}\n" } }
check.call('a key one run proves and another refuses stays out',
           InitializerTables.super_direct([run.([['d1', 3]], []), run.([], [['d1', 3]])]).empty?)
check.call('a key proven in one run and absent from the other is proven',
           InitializerTables.super_direct([run.([['d1', 3]], []), run.([], [])]) == Set[['d1', 3]])
check.call('a run without an evidence row proves nothing',
           InitializerTables.super_direct([run.([['d1', 3]], []), { err: '' }]).empty?)

suite.finish!
