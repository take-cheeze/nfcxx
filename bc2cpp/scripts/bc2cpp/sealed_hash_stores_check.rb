#!/usr/bin/env ruby
# frozen_string_literal: true

# SEALED_HASH_STORES: a sealed Hash ivar (SEALED_HASH_IVAR) may also be filled by `@h[k] = v` and read by the native
# key-only sends (`keys`, `key?`, `size`, ...). A `-> C?` declaration over `@h[k]` is trusted as written (RBS only:
# the per-return-path proofs were deleted, 0fb29edf3), so each fixture runs interpreted and compiled. Where every store
# is a C the two must print the same. A store that is not a C (LEAKY, ESCAPED) breaks the declaration: the interpreter
# raises NoMethodError on `label`, and the compiled call that trusts `-> Thing?` runs Thing#label on the wrong object
# instead. That divergence is the declaration's contract, not a compiler bug, so those two cases pin it: the compiled
# run must finish and differ from the interpreted one only by the missing 'no label' line.
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

    def label
      'thing'
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
      roster.fetch_thing(1).label
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
# The Hash leaves the slot through a call argument, and a holder stores a String into it.
STASH = <<~RUBY
  class Stash
    def put(h)
      h[1] = 'junk'
      nil
    end
  end
RUBY
ESCAPED = SOURCE.sub("  def count\n    @all.keys.size", "  def count\n    Stash.new.put(@all)\n    @all.keys.size") + STASH
raise 'ESCAPED fixture did not apply' if ESCAPED == SOURCE + STASH

# go calls label on what fetch_thing returns. A Roster or a String there is a NoMethodError in the interpreter; a
# compiled call that trusts `-> Thing?` would run Thing#label on it instead, so the rescue prints a line only then.
DRIVER = <<~RUBY
  r = Roster.new
  puts r.count
  begin
    User.new.go(r)
  rescue NoMethodError
    puts 'no label'
  end
  puts r.count
  puts 'end'
RUBY

OWNERS = %w[Thing Roster User Stash].freeze

# Generates `source` with the sealed-hash rule on or off, then runs its driver interpreted and compiled. Returns
# [generated, interpreted output lines, compiled output lines]; a nil side means that run did not finish.
run = lambda do |source, flag, build|
  ENV['BC2CPP_SEALED_HASH_STORES'] = flag
  Dir.mktmpdir('sealed_hash_stores') do |dir|
    sig = File.join(dir, 'sig')
    FileUtils.mkdir_p(sig)
    File.write(File.join(sig, 'roster.rbs'), SIGS)
    ENV['BC2CPP_SIG_DIRS'] = sig
    _code, stderr = Bc2cppFixtureRuntime.generate(source, dir, only_owners: OWNERS)
    body = <<~CPP
      static int scenario(mrb_state* M) {
        std::fflush(stdout);
        const char* src = R"APD(#{DRIVER})APD";
        mrb_load_string(M, src);
        std::fflush(stdout);
        if (M->exc) { mrb_print_error(M); M->exc = nullptr; return 1; }
        return 0;
      }
    CPP
    built, output = Bc2cppFixtureRuntime.run(dir, stderr, OWNERS, body, build: build, full: true)
    sections = built ? Bc2cppFixtureRuntime.sections(output) : {}
    [true, sections['interpreted'], sections['compiled']]
  rescue RuntimeError => e
    warn "  generation refused: #{e.message.lines.last(3).join.strip}"
    [false, nil, nil]
  end
ensure
  ENV.delete('BC2CPP_SEALED_HASH_STORES')
  ENV.delete('BC2CPP_SIG_DIRS')
end

build = Bc2cppFixtureRuntime.full_or_build
check.call('a full-core libmruby builds for the parity runs', !build.nil?)
if build
  cases = [
    ['`@h[k] = Thing.new` with the sealed rule: interpreted and compiled run the same', SOURCE, '1', true],
    ['without the sealed rule the declaration is still trusted: interpreted and compiled run the same', SOURCE, '0', true],
    ['a store of another class breaks the declaration: the compiled call trusts `-> Thing?` (no NoMethodError)', LEAKY, '1', false],
    ['a Hash passed out as an argument breaks the declaration: the compiled call trusts `-> Thing?`', ESCAPED, '1', false]
  ]
  cases.each do |name, source, flag, parity|
    generated, interpreted, compiled = run.call(source, flag, build)
    check.call("#{name} (the driver runs to its end)", generated && interpreted&.last == 'end')
    # A broken declaration: only the interpreter reaches the rescue, so the compiled lines are the interpreted ones
    # without 'no label'.
    expected = parity ? interpreted : interpreted&.reject { |l| l == 'no label' }
    check.call(name, generated && !interpreted.nil? && expected == compiled)
    check.call("#{name} (the interpreter does raise)", interpreted.include?('no label')) unless parity
    next unless generated && interpreted && compiled && expected != compiled

    interpreted.zip(compiled).reject { |a, b| a == b }.first(10).each { |a, b| puts "    interpreted: #{a}\n    compiled:    #{b}" }
  end
end

suite.finish!
