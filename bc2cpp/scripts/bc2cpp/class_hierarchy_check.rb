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

EXTEND_SOURCE = <<~RUBY
  module Helpers; def tag; end; end
  module Extra; end
  module Game
    class Hero
      extend Helpers, Extra
      extend self
      extend Util.make
      def self.hook; end
      class << self
        def build; end
        include Extra
        extend Helpers
        define_method(:made) {}
        prepend Helpers
      end
      def setup; extend Helpers; end
    end
  end
  extend Helpers
  Other.extend Helpers
RUBY

Tempfile.create(['extend', '.rb']) do |src|
  src.write(EXTEND_SOURCE)
  src.flush
  rows = ClassHierarchy.rows([src.path])
  extends = rows.select { |k, o, _| k == 'EXTEND' && o == 'Game::Hero' }.map(&:last)
  sdefs = rows.select { |k, *| k == 'SDEF' }.map { |_, o, m| [o, m] }

  check.call('extend A, B is recorded in application order (B then A)', extends.index('Extra') < extends.index('Helpers'))
  check.call('extend self records the extending class itself', extends.include?('Game::Hero'))
  check.call('a computed extend argument records a wildcard module', extends.include?('*'))
  check.call('a class-body include in class << self is an extend of the class', extends.count('Extra') == 2)
  check.call('an extend inside class << self extends only the singleton class, so it is not recorded',
             extends.count('Helpers') == 1)
  check.call('a prepend in class << self records a wildcard (its place in the lookup is not read)',
             extends.count('*') == 3)
  check.call('an extend inside a def is dynamic: it records a wildcard for the owner', rows.include?(['EXTEND', 'Game::Hero', '*']))
  check.call('a top-level extend belongs to main, so it has no row', rows.none? { |k, o, _| k == 'EXTEND' && o == 'Object' })
  check.call('an explicit receiver extend is an unknown class, a global wildcard row', rows.include?(['EXTEND', '*', '*']))
  check.call('a def self.x and a class << self def are singleton rows',
             sdefs.include?(['Game::Hero', 'hook']) && sdefs.include?(['Game::Hero', 'build']) &&
             sdefs.include?(['Game::Hero', 'made']))
  check.call('a singleton def is not an instance method row', rows.none? { |k, o, m| k == 'DEF' && o == 'Game::Hero' && %w[hook build].include?(m) })
  check.call('the instance method of the same class is still a DEF row', rows.include?(['DEF', 'Game::Hero', 'setup']))
end

if failures.empty?
  puts 'class hierarchy check: PASS'
else
  puts "class hierarchy check: FAIL #{failures.join('; ')}"
  exit 1
end
