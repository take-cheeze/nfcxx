#!/usr/bin/env ruby
# frozen_string_literal: true

# VISIBILITY_ONLY: `public :name` in a class body spelled the name as a Symbol literal, which poisons it for every
# proof that enumerates call sites (ENTRY_ARG_CALLSITE_PROOF rule 7), so its arguments had no class pools.
# Module#public only changes the visibility, so such a literal is now neither a call nor a computed-send name.
# Generated end to end by bc2cpp.rb (no mruby build needed); BC2CPP_VISIBILITY_LITERALS=0 is the output before it.
#
#   MRBC=path/to/mrbc ruby scripts/bc2cpp/visibility_literal_pools_check.rb
require 'tmpdir'
require_relative 'check_support'
require_relative 'fixture_runtime'

# The fixtures declare no RBS; the repository's signatures name engine classes these fixtures lack.
ENV['BC2CPP_SIG_DIRS'] = ''

suite = FixtureCheck.new('visibility_literal_pools_check')
check = suite.method(:check)
suite.require_mrbc!

SOURCE = <<~RUBY
  class Fighter
    def initialize
      @power = 3
      nil
    end

    def power
      @power + 1
    end
  end

  class Rival
    def power
      2
    end
  end

  class Arena
    def run
      measure_blow(Fighter.new) + weigh_blow(Fighter.new) + Rival.new.power
    end

    def weigh_blow(fighter)
      fighter.power
    end

    private

    def measure_blow(fighter)
      fighter.power
    end
    public :measure_blow
  end

  class Ledger
    def tally(fighter)
      fighter.power
    end
  end

  class Clerk
    def file
      Ledger.new.tally(Fighter.new)
    end

    def names
      [:tally]
    end
  end
RUBY

# { "Owner#name" => generated body } of one run with the given switches.
bodies = lambda do |env|
  env.each { |k, v| ENV[k] = v }
  Dir.mktmpdir('visibility_literal_pools') do |dir|
    code, = Bc2cppFixtureRuntime.generate(SOURCE, dir, only_owners: %w[Fighter Rival Arena Ledger Clerk])
    code.split(%r{^(?=// \w+#)}).to_h { |part| [part[%r{\A// (\S+)}, 1], part] }
  end
ensure
  env.each_key { |k| ENV.delete(k) }
end
on = bodies.call({})
off = bodies.call('BC2CPP_VISIBILITY_LITERALS' => '0')
class_tests = ->(body) { body.to_s.scan('mrb_obj_class(M,').size }

check.call('before, the argument of a method named by `public :name` is a class-test chain',
           off['Arena#measure_blow'].to_s.include?('POLY_SMALL_N :power'))
check.call('`public :name` no longer poisons the name: Fighter#power, no class test',
           !on['Arena#measure_blow'].to_s.include?('POLY_SMALL_N') && class_tests.call(on['Arena#measure_blow']).zero?)
check.call('a literal used any other way still poisons the name',
           on['Ledger#tally'].to_s.include?('POLY_SMALL_N :power'))

suite.finish!
