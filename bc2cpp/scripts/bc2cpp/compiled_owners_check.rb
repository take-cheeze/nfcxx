#!/usr/bin/env ruby
# frozen_string_literal: true

# GEM_OWNERS (tools/bc2cpp/gem_owners.rb): each compiled gem's `owners:` is derived from its base gem's mrblib.
#
#   fixture
#     - nesting, `::` paths, `def self.` and `class << self` give the registry's owner spelling;
#     - a module that calls module_function owns its singleton too;
#     - defs in blocks and method bodies, and on a core class not listed as reopened, are no owner's;
#   closed world (needs a host mrbc)
#     - every engine class or module with a plain `def` in the registry is some gem's owner. One that is not would
#       never be compiled, and nothing would report it. Attr accessors, module_function copies and alias
#       definitions are not plain defs; a def a module_function copy shares counts through the module.
#
# Usage: MRBC=path/to/mrbc ruby scripts/bc2cpp/compiled_owners_check.rb

require 'set'
require 'tmpdir'
require_relative 'check_support'
require_relative '../../tools/bc2cpp/static_dispatch_registrations'

suite = FixtureCheck.new('compiled_owners_check')

SOURCE = <<~'RUBY'
  module Game
    class Scene::Map
      def a; end

      def self.b; end

      class << self
        def c; end
      end

      [1].each { def in_block; end }

      def d
        def in_body; end
      end
    end

    module Util
      def u; end
      module_function :u
    end
  end

  class ::RGSS
    def r; end
  end

  class Array
    def kept; end
  end

  class Object
    def dropped; end
  end
RUBY

Dir.mktmpdir('compiled-owners') do |dir|
  path = File.join(dir, 'fixture.rb')
  File.write(path, SOURCE)
  owners = GemOwners.owners([path])
  suite.check("the registry's owner spelling (#{owners.join(', ')})",
              owners == %w[Array Game::Scene::Map Game::Scene::Map.singleton Game::Util Game::Util.singleton RGSS])
end

suite.require_mrbc!
root = File.expand_path('../..', __dir__)
_ireps, registry, = StaticDispatchRegistrations.closed_world(root, ENV.fetch('MRBC', 'mrbc'))
listed = BC2CPP_COMPILED_GEMS.values.flat_map { |gem| Array(gem[:owners]) }.to_set
copied = registry.each_value.flat_map do |defs|
  defs.select { |d| d.kind == :module_function && listed.include?(d.owner) }.map(&:copy_irep)
end.to_set
unlisted = registry.each_value.flat_map do |defs|
  defs.select { |d| d.irep && d.kind.nil? && d.installer.nil? && d.owner.match?(GemOwners::ENGINE_RE) }
      .reject { |d| listed.include?(d.owner) || copied.include?(d.irep) }.map(&:owner)
end.uniq.sort
suite.check("every engine owner with a plain def is compiled (unlisted: #{unlisted.join(', ')})", unlisted.empty?)
suite.check('the registry has engine defs at all',
            registry.each_value.any? { |defs| defs.any? { |d| d.owner.match?(GemOwners::ENGINE_RE) } })

suite.finish!
