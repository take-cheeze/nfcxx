#!/usr/bin/env ruby
# frozen_string_literal: true

# SEALED_HASH_STORES: a sealed Hash ivar (SEALED_HASH_IVAR) may also be filled by `@h[k] = v` and read by the native
# key-only sends (`keys`, `key?`, `size`, ...), so a `-> C?` declaration over `@h[k]` is proven when every stored
# value is exactly C. Generated end to end by bc2cpp.rb, whose DECLARED_RETURN_CHECK aborts on a declaration a body
# does not prove; BC2CPP_SEALED_HASH_STORES=0 is the literal-only rule before it.
#
#   MRBC=path/to/mrbc ruby scripts/bc2cpp/sealed_hash_stores_check.rb
require 'tmpdir'
require 'fileutils'
require_relative 'check_support'
require_relative 'fixture_runtime'

suite = FixtureCheck.new('sealed_hash_stores_check')
check = suite.method(:check)
suite.require_mrbc!

SOURCE = <<~RUBY
  class Thing
    def initialize
      nil
    end
  end

  class Roster
    def initialize
      @all = {}
      nil
    end

    def fetch_thing(id)
      a = @all[id]
      return a if a

      @all[id] = Thing.new
    end

    def known?(id)
      @all.key?(id)
    end

    def count
      @all.keys.size
    end
  end

  class User
    def go(roster)
      roster.fetch_thing(1)
      roster.known?(2)
      roster.count
      nil
    end
  end
RUBY

SIGS = <<~RBS
  class Roster
    def fetch_thing: (Integer) -> Thing?
  end
RBS

# Another class's Hash is stored into the slot: the store is not a Thing.
LEAKY = SOURCE.sub('@all[id] = Thing.new', '@all[id] = Roster.new')
# The Hash leaves the slot through a call argument.
ESCAPED = SOURCE.sub("  def count\n    @all.keys.size", "  def count\n    User.new.go(@all)\n    @all.keys.size")
raise 'ESCAPED fixture did not apply' if ESCAPED == SOURCE

# [success?, the DECLARED_RET line for Roster#fetch_thing or the failure tail].
run = lambda do |source, flag|
  ENV['BC2CPP_SEALED_HASH_STORES'] = flag
  Dir.mktmpdir('sealed_hash_stores') do |dir|
    sig = File.join(dir, 'sig')
    FileUtils.mkdir_p(sig)
    File.write(File.join(sig, 'roster.rbs'), SIGS)
    ENV['BC2CPP_SIG_DIRS'] = sig
    _code, stderr = Bc2cppFixtureRuntime.generate(source, dir, only_owners: %w[Thing Roster User])
    [true, stderr.lines.grep(/DECLARED_RET Roster#fetch_thing/).first.to_s.strip]
  rescue RuntimeError => e
    [false, e.message.lines.last(3).join.strip]
  end
ensure
  ENV.delete('BC2CPP_SEALED_HASH_STORES')
  ENV.delete('BC2CPP_SIG_DIRS')
end

ok, line = run.call(SOURCE, '1')
check.call('`@h[k] = Thing.new` and key-only reads prove `-> Thing?`', ok && line.include?('checked'))
ok, = run.call(SOURCE, '0')
check.call('without SEALED_HASH_STORES the declaration is refused', !ok)
ok, = run.call(LEAKY, '1')
check.call('a store of another class is refused', !ok)
ok, = run.call(ESCAPED, '1')
check.call('a Hash passed out as an argument is refused', !ok)

suite.finish!
