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

suite.finish
