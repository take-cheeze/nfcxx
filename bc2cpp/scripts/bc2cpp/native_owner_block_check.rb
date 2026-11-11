#!/usr/bin/env ruby
# frozen_string_literal: true

# SYNC_BY_DEFINITION (codegen_block_fallback.rb, `to_h`): a literal block that captures a local and is handed to `to_h`
# compiles as a block fallback when every definition the closed world can dispatch to calls its block without keeping
# it. The core Array/Enumerable/Hash bodies call `block` only, and the native Struct/NilClass/Data `to_h` functions take
# no block (each body is read). A user `to_h` that keeps its block is not trusted to leave it: the capture goes through
# heap cells (STEP_CLOSURES), or, with BC2CPP_STEP_CLOSURES=0, the call stays refused (`#error`).
#
# Usage: MRBC=path/to/host/mrbc ruby scripts/bc2cpp/native_owner_block_check.rb

require 'tmpdir'
require_relative 'check_support'
require_relative 'fixture_runtime'

ENV['BC2CPP_SIG_DIRS'] = ''

suite = FixtureCheck.new('native_owner_block_check')
suite.require_mrbc!
check = suite.method(:check)

# The core-world shape: `to_h` on an Enumerator, a block capturing `nregs`.
POSITIVE = <<~'RUBY'
  class Slots
    def for_run(slots, nregs)
      slots.each_with_index.to_h { |name, k| [name, nregs + k] }
    end
  end

  p Slots.new.for_run([:a, :b], 3)
RUBY

# A user `to_h` that keeps the block it is given; the caller's capturing block must stay refused.
NEGATIVE = <<~'RUBY'
  class Keeper
    def to_h(&blk)
      @blk = blk
      {}
    end
  end

  class Reader
    def read(obj, v)
      obj.to_h { |x| x + v }
    end
  end

  p Reader.new.read(Keeper.new, 2)
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

def refusals_for(source)
  Dir.mktmpdir('native_owner_block') do |dir|
    Bc2cppFixtureRuntime.generate(source, dir, path: 'fixture.rb', skip_unsupported: false, core: true)
    refusals_by_function(dir)
  end
end

positive = refusals_for(POSITIVE)
check.call('a to_h capturing a local compiles without #error (core Array/Enumerable/Hash and native to_h)',
           positive.keys.none? { |owner| owner.to_s.start_with?('Slots_') })

negative = refusals_for(NEGATIVE)
check.call('a user to_h that keeps its block captures through cells, not a pointer into the frame',
           negative.fetch('Reader_read_impl', 0).zero?)
saved = ENV['BC2CPP_STEP_CLOSURES']
ENV['BC2CPP_STEP_CLOSURES'] = '0'
refused = refusals_for(NEGATIVE)
saved ? ENV['BC2CPP_STEP_CLOSURES'] = saved : ENV.delete('BC2CPP_STEP_CLOSURES')
check.call('a user to_h that keeps its block stays refused without the cells',
           refused.fetch('Reader_read_impl', 0).positive?)

suite.finish!
