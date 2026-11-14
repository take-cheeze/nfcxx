#!/usr/bin/env ruby
# frozen_string_literal: true

# DECLARED_ELEMENT_GUARD: `@items: Array[Integer]` (RBS) is checked where an element is read. A GETIDX of the declared
# ivar tests its result after the read, so a non-Integer element raises BC2cppDeclarationViolation in the compiled run
# (the interpreted run has no declaration, so it returns the element). A good element behaves the same in both runs.
# Read from the generated code's DECLARED_ELEMENT_GUARD lines and the behaviour comparison.
#
#   MRBC=path/to/mrbc ruby scripts/bc2cpp/element_guard_check.rb
require 'tmpdir'
require_relative 'check_support'
require_relative 'fixture_runtime'

suite = Bc2cppStepCheck.new('element_guard_check')
check = suite.method(:check)

SOURCE = <<~RUBY
  class Shelf
    def initialize
      @items = [1, 2, 3]
      nil
    end

    def at(i)
      @items[i]
    end

    def poison
      @items << "a"
      nil
    end
  end
RUBY

SIG = <<~RBS
  class Shelf
    @items: Array[Integer]
  end
RBS

DRIVER = <<~'RUBY'
  s = Shelf.new
  puts s.at(0).inspect
  s.poison
  begin
    puts s.at(3).inspect
  rescue => e
    puts "raised #{e.class}"
  end
  puts 'end'
RUBY

Dir.mktmpdir('element_guard_sig') do |sig_dir|
  File.write(File.join(sig_dir, 'shelf.rbs'), SIG)
  ENV['BC2CPP_SIG_DIRS'] = sig_dir
  ENV['BC2CPP_DECLARATION_GUARD'] = nil
  Dir.mktmpdir('element_guard') do |dir|
    code, = Bc2cppFixtureRuntime.generate(SOURCE, dir, only_owners: %w[Shelf])
    check.call('the element read of @items is guarded', code.include?('DECLARED_ELEMENT_GUARD Shelf#items'))
    check.call('the guard names the element, not the array', code.include?('"Shelf#@items[]", "Array[Integer]"'))
  end
  ENV.delete('BC2CPP_SIG_DIRS')
end

Dir.mktmpdir('element_guard_nosig') do |dir|
  ENV['BC2CPP_SIG_DIRS'] = ''
  code, = Bc2cppFixtureRuntime.generate(SOURCE, dir, only_owners: %w[Shelf])
  check.call('without a declaration no element guard is emitted', !code.include?('DECLARED_ELEMENT_GUARD'))
ensure
  ENV.delete('BC2CPP_SIG_DIRS')
end

Dir.mktmpdir('element_guard_run') do |sig_dir|
  File.write(File.join(sig_dir, 'shelf.rbs'), SIG)
  ENV['BC2CPP_SIG_DIRS'] = sig_dir
  suite.generate(SOURCE, %w[Shelf])
  suite.behaviour(DRIVER, banner: 'declared element read, interpreted and compiled', same: false) do |interpreted, compiled|
    check.call('the good element reads the same in both runs', interpreted && compiled && interpreted[0] == compiled[0])
    check.call('the interpreted run returns the bad element', interpreted&.include?('"a"') && interpreted.none? { |l| l.start_with?('raised') })
    check.call('the compiled run raises the declaration violation', compiled&.any? { |l| l.start_with?('raised') })
  end
ensure
  ENV.delete('BC2CPP_SIG_DIRS')
end


# A program class: `@things: Array[Thing]` (an exact-class element), with a Thing and an Other.
THING_SOURCE = <<~RUBY
  class Thing
    def ok?
      true
    end
  end

  class Other
    def ok?
      false
    end
  end

  class Crate
    def initialize
      @things = [Thing.new, Thing.new]
      nil
    end

    def at(i)
      @things[i]
    end

    def poison
      @things << Other.new
      nil
    end

    def first_ok
      @things[0].ok?
    end

    def put(i, v)
      @things[i] = v
      nil
    end
  end
RUBY

THING_SIG = <<~RBS
  class Crate
    @things: Array[Thing]
  end
RBS

THING_DRIVER = <<~'RUBY'
  c = Crate.new
  puts c.at(0).class
  c.poison
  begin
    puts c.at(2).class
  rescue => e
    puts "raised #{e.class}"
  end
  begin
    c.put(1, Other.new)
    puts 'stored'
  rescue => e
    puts "store raised #{e.class}"
  end
  puts 'end'
RUBY

Dir.mktmpdir('element_guard_thing_sig') do |sig_dir|
  File.write(File.join(sig_dir, 'crate.rbs'), THING_SIG)
  ENV['BC2CPP_SIG_DIRS'] = sig_dir
  Dir.mktmpdir('element_guard_thing') do |dir|
    code, = Bc2cppFixtureRuntime.generate(THING_SOURCE, dir, only_owners: %w[Crate Thing])
    check.call('a program-class element read is guarded', code.include?('DECLARED_ELEMENT_GUARD Crate#things'))
    check.call('a send to the declared element is a closed-world exact-class call', code.include?('NILABLE_RECEIVER :ok?') && code.include?('CLOSED_WORLD_EXACT_CLASS :ok? -> Thing#ok?'))
  end
  suite.generate(THING_SOURCE, %w[Crate Thing])
  suite.behaviour(THING_DRIVER, banner: 'declared program-class element read, interpreted and compiled', same: false) do |interpreted, compiled|
    check.call('the good program element reads the same in both runs', interpreted && compiled && interpreted[0] == compiled[0])
    check.call('the interpreted run returns the wrong-class element', interpreted&.include?('Other'))
    check.call('the compiled run raises the declaration violation', compiled&.any? { |l| l.start_with?('raised') })
    check.call('a wrong-class store raises before it writes (compiled), and stores (interpreted)', interpreted&.include?('stored') && compiled&.include?('store raised BC2cppDeclarationViolation'))
  end
ensure
  ENV.delete('BC2CPP_SIG_DIRS')
end

suite.finish
