#!/usr/bin/env ruby
# frozen_string_literal: true

# Checks scripts/bc2cpp/class_hierarchy.rb on a small source: a superclass resolves against the enclosing namespace
# before the top level, a path superclass keeps its written name, instance methods land on their own class, and a
# singleton `def self.x` is not an instance method.
#
#   ruby scripts/bc2cpp/class_hierarchy_check.rb

require 'tempfile'
require_relative 'class_hierarchy'

SOURCE = <<~RUBY
  class Base; def size; end; end
  module Game
    class Base < ::Base; def name; end; end
    class Actor < Base
      def self.make; end
      def hp; end
    end
  end
  class Lone < Game::Actor; end
RUBY

failures = []
check = ->(name, ok) { failures << name unless ok }

Tempfile.create(['hierarchy', '.rb']) do |src|
  src.write(SOURCE)
  src.flush
  rows = ClassHierarchy.rows([src.path])
  supers = rows.select { |k, *| k == 'SUPER' }.to_h { |_, c, s| [c, s] }
  defs = rows.select { |k, *| k == 'DEF' }.group_by { |_, c, _| c }.transform_values { |v| v.map(&:last) }

  check.call('a superclass in the enclosing namespace wins over the top level', supers['Game::Base'] == 'Base')
  check.call('an explicit top-level path names the top-level class', supers['Game::Base'] == 'Base' && supers.key?('Game::Base'))
  check.call('a superclass in the same namespace resolves to it', supers['Game::Actor'] == 'Game::Base')
  check.call('a qualified superclass keeps its written name', supers['Lone'] == 'Game::Actor')
  check.call('instance methods belong to their class', defs['Game::Actor'] == ['hp'])
  check.call('a singleton method is not an instance method', !defs['Game::Actor'].to_a.include?('make'))
  check.call('a class with no superclass has no SUPER row', !supers.key?('Base'))
end

if failures.empty?
  puts 'class hierarchy check: PASS'
else
  puts "class hierarchy check: FAIL #{failures.join('; ')}"
  exit 1
end
