#!/usr/bin/env ruby
# frozen_string_literal: true

# OPTIONAL_ARG_POOLS: a method with optional positional parameters had no argument pools at all (admission rule 6
# wanted mandatory parameters only), so a mandatory argument every caller passes as one class still took a class-test
# chain, and so did every method it passed that argument on to. Its mandatory positions are now pooled from sites
# passing any accepted count. Generated end to end by bc2cpp.rb (no mruby build needed); BC2CPP_OPTIONAL_ARG_POOLS=0
# is the output before it.
#
#   MRBC=path/to/mrbc ruby scripts/bc2cpp/optional_arg_pools_check.rb
require 'tmpdir'
require_relative 'check_support'
require_relative 'fixture_runtime'

# The fixtures declare no RBS; the repository's signatures name engine classes these fixtures lack.
ENV['BC2CPP_SIG_DIRS'] = ''

suite = FixtureCheck.new('optional_arg_pools_check')
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
    def strike(fighter, combo = 1)
      fighter.power * combo
    end

    def relay(fighter, combo = 1)
      land_blow(fighter) + combo
    end

    def land_blow(fighter)
      fighter.power
    end

    def run
      strike(Fighter.new) + strike(Fighter.new, 2) + relay(Fighter.new) + Rival.new.power
    end
  end
RUBY

# { "Owner#name" => generated body } of one run with the given switches.
bodies = lambda do |env|
  env.each { |k, v| ENV[k] = v }
  Dir.mktmpdir('optional_arg_pools') do |dir|
    code, = Bc2cppFixtureRuntime.generate(SOURCE, dir, only_owners: %w[Fighter Rival Arena])
    code.split(%r{^(?=// \w+#)}).to_h { |part| [part[%r{\A// (\S+)}, 1], part] }
  end
ensure
  env.each_key { |k| ENV.delete(k) }
end
on = bodies.call({})
off = bodies.call('BC2CPP_OPTIONAL_ARG_POOLS' => '0')
class_tests = ->(body) { body.to_s.scan('mrb_obj_class(M,').size }

check.call('before, the mandatory argument of a method with an optional one is a class-test chain',
           off['Arena#strike'].to_s.include?('POLY_SMALL_N :power') && off['Arena#land_blow'].to_s.include?('POLY_SMALL_N :power'))
check.call('the mandatory argument is pooled from both call shapes: Fighter#power, no class test',
           !on['Arena#strike'].to_s.include?('POLY_SMALL_N') && class_tests.call(on['Arena#strike']).zero?)
check.call('the pool carries on to the method the argument is passed to',
           !on['Arena#land_blow'].to_s.include?('POLY_SMALL_N') && class_tests.call(on['Arena#land_blow']).zero?)

suite.finish!
