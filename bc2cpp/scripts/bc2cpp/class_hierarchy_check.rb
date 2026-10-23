#!/usr/bin/env ruby
# frozen_string_literal: true

# Checks scripts/bc2cpp/class_hierarchy.rb on small sources: a superclass resolves against the enclosing namespace
# before the top level, a path superclass keeps its written name, instance methods land on their own class, and a
# singleton `def self.x` is not an instance method. Mixins keep their application order, modules and their methods
# are rows, and a definer with a computed name is a wildcard.
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

MIXIN_SOURCE = <<~RUBY
  module Walk; def step; end; end
  module Other; end
  module Game
    module Util; def helper; end; end
    class Actor
      include Walk, Other
      prepend Util
      class << self; def build; end; end
      define_method(:tick) {}
      define_method(name_source) {}
      attr_accessor :hp
      alias_method :alias_hp, :hp
      alias boost hp
    end
  end
  include Walk
RUBY

Tempfile.create(['mixins', '.rb']) do |src|
  src.write(MIXIN_SOURCE)
  src.flush
  rows = ClassHierarchy.rows([src.path])
  mixins = rows.select { |k, *| %w[INCLUDE PREPEND].include?(k) }.map { |k, o, m| [k, o, m] }
  kinds = rows.select { |k, *| %w[CLASS MODULE].include?(k) }.to_h { |k, n| [n, k] }
  defs = rows.select { |k, *| k == 'DEF' }.group_by { |_, c, _| c }.transform_values { |v| v.map(&:last) }

  check.call('a module is a MODULE row and a class a CLASS row', kinds['Walk'] == 'MODULE' && kinds['Game::Actor'] == 'CLASS')
  other_at = mixins.index(['INCLUDE', 'Game::Actor', 'Other'])
  walk_at = mixins.index(['INCLUDE', 'Game::Actor', 'Walk'])
  check.call('include A, B is recorded in application order (B then A)', other_at && walk_at && other_at < walk_at)
  check.call('a mixin resolves against the enclosing namespace first', mixins.include?(['PREPEND', 'Game::Actor', 'Game::Util']))
  check.call('a top-level include belongs to Object', mixins.include?(['INCLUDE', 'Object', 'Walk']))
  check.call('a module records its own instance methods', defs['Game::Util'] == ['helper'] && defs['Walk'] == ['step'])
  check.call('a singleton class body is neither a mixin nor an instance method', !defs['Game::Actor'].to_a.include?('build'))
  check.call('define_method, alias_method, attr_accessor and alias record their names',
             %w[tick alias_hp hp hp= boost].all? { |m| defs['Game::Actor'].include?(m) })
  check.call('a computed define_method name records a wildcard', defs['Game::Actor'].include?('*'))
end

if failures.empty?
  puts 'class hierarchy check: PASS'
else
  puts "class hierarchy check: FAIL #{failures.join('; ')}"
  exit 1
end
