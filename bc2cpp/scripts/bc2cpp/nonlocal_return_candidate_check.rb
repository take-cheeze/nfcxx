#!/usr/bin/env ruby
# frozen_string_literal: true

# The return candidate of a method whose `return` sits in a block. That `return` leaves the method through a
# RETURN_BLK in the block's own body, not in the method's exit list, so a method whose own exits are only RETNIL must
# not be typed `nil` (the RETNIL is its fall-through, not its value). Needs MRBC (set it, or put mrbc on PATH).
#
#   MRBC=path/to/host/mrbc ruby scripts/bc2cpp/nonlocal_return_candidate_check.rb

require 'tmpdir'
require_relative 'type_check_fixture'

ROOT = File.expand_path('../..', __dir__)
TOOLS = ENV['BC2CPP_TOOLS_DIR'] || File.join(ROOT, 'tools/bc2cpp')

failures = []
check = lambda do |label, condition|
  puts "#{condition ? 'ok' : 'FAIL'} #{label}"
  failures << label unless condition
end

unless ENV['MRBC'] || ENV.fetch('PATH', '').split(File::PATH_SEPARATOR).any? { |dir| File.executable?(File.join(dir, 'mrbc')) }
  puts 'SKIP nonlocal_return_candidate: set MRBC to a host mrbc'
  exit 0
end

SOURCE = <<~'RUBY'
  class Blk
    FOUND = ['', '.mid'].freeze

    # Returns a parameter from the block; the fall-through is nil. The return is the parameter's value (unknown).
    def param_from_block(base)
      FOUND.each { |ext| return base if ext }
      nil
    end

    # The same shape, but the returned value is a String built in the block.
    def string_from_block(base)
      FOUND.each { |ext| return "#{base}#{ext}" if ext }
      nil
    end

    # No block return: the fall-through nil is the whole answer.
    def plain_nil(base)
      FOUND.each { |ext| ext }
      nil
    end
  end
RUBY

Dir.mktmpdir('nonlocal-return-candidate') do |dir|
  File.write(File.join(dir, 'fixture.rb'), SOURCE)
  Dir.mkdir(File.join(dir, 'sig'))
  report = TypeCheckFixture.report(dir, files: ['fixture.rb'], env: { 'BC2CPP_TOOLS_DIR' => TOOLS },
                                   options: ['--sig', File.join(dir, 'sig')], label: 'nonlocal return candidate')
  returns = report['methods'].to_h { |row| [row['name'], row['return']] }

  check.call('a block return of an unknown value does not type the method nil',
             returns['param_from_block'] && returns['param_from_block']['type'] != 'nil')
  check.call('a block return of a String types the method String? (the block value and the fall-through nil)',
             returns['string_from_block'] && returns['string_from_block']['type'] == 'String?')
  check.call('a method with no block return keeps its nil fall-through type',
             returns['plain_nil'] && returns['plain_nil']['type'] == 'nil')
end

abort "#{failures.length} nonlocal return candidate checks failed" unless failures.empty?
puts 'nonlocal return candidate: all checks passed'
