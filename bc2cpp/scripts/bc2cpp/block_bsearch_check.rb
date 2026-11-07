#!/usr/bin/env ruby
# frozen_string_literal: true

# BLOCK_FALLBACK_UPVAR_SAFE_METHODS: `bsearch_index { }` / `bsearch { }` capture a local (`v` below) and compile as
# block fallbacks, because mruby-array-ext's implementations call the block only while they run. A user method
# that keeps its block is not on that list, so the capture goes through heap cells (STEP_CLOSURES); without them
# (BC2CPP_STEP_CLOSURES=0) the same capture stays refused (`#error`).
#
# Usage: MRBC=path/to/host/mrbc ruby scripts/bc2cpp/block_bsearch_check.rb

require_relative 'check_support'
require_relative 'fixture_runtime'

ENV['BC2CPP_SIG_DIRS'] = ''

suite = FixtureCheck.new('block_bsearch_check')
suite.require_mrbc!
check = suite.method(:check)

SOURCE = <<~'RUBY'
  class Finder
    def pick(arr, v)
      arr.bsearch_index { |x| x >= v }
    end

    def first_at_least(arr, v)
      arr.bsearch { |x| x >= v }
    end
  end

  class Keeper
    def keep(&blk)
      @blk = blk
    end

    def store(v)
      keep { |x| x + v }
    end
  end

  f = Finder.new
  p f.pick([1, 2, 3], 2)
  p f.first_at_least([1, 2, 3], 2)
  Keeper.new.store(1)
RUBY

# Errors per generated function: each `#error` line is attributed to the function whose body holds it.
def refusals_by_function(dir)
  owner = nil
  counts = Hash.new(0)
  File.foreach(File.join(dir, 'fixture_gen.cpp')) do |line|
    if (match = line.match(/^(?:static )?mrb_value (\w+)\(.*\{\s*$/))
      owner = match[1]
    elsif line.include?('#error')
      counts[owner] += 1
    end
  end
  counts
end

Dir.mktmpdir('block_bsearch') do |dir|
  Bc2cppFixtureRuntime.generate(SOURCE, dir, path: 'fixture.rb', skip_unsupported: false)
  refusals = refusals_by_function(dir)
  finder = refusals.select { |owner, _| owner.to_s.start_with?('Finder_') }
  check.call('bsearch_index and bsearch with a captured local compile without #error',
             finder.empty?)
  check.call('a user method that stores its block captures through cells, not a pointer into the frame',
             refusals.fetch('Keeper_store_impl', 0).zero?)
end

saved = ENV['BC2CPP_STEP_CLOSURES']
ENV['BC2CPP_STEP_CLOSURES'] = '0'
begin
  Dir.mktmpdir('block_bsearch') do |dir|
    Bc2cppFixtureRuntime.generate(SOURCE, dir, path: 'fixture.rb', skip_unsupported: false)
    check.call('a user method that stores its block stays refused without the cells',
               refusals_by_function(dir).fetch('Keeper_store_impl', 0).positive?)
  end
ensure
  saved ? ENV['BC2CPP_STEP_CLOSURES'] = saved : ENV.delete('BC2CPP_STEP_CLOSURES')
end

suite.finish!
