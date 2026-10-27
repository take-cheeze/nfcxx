#!/usr/bin/env ruby
# frozen_string_literal: true

# COMPILED_OWNERS: every engine class or module (Game, RPG2k, RPG2k3, LCF, RGSS) with a plain `def` in the closed
# world's mrblib is an `owners:` entry of some compiled gem (tools/bc2cpp/compiled_gems.rb). An owner on no list is
# never compiled at all: its methods stay bytecode, and nothing reports it. Attr accessors, module_function copies
# and alias definitions are not plain defs; a def a listed owner's module_function copy shares counts as compiled.
#
# Usage: MRBC=path/to/mrbc ruby scripts/bc2cpp/compiled_owners_check.rb

require 'set'
require_relative 'check_support'
require_relative '../../tools/bc2cpp/static_dispatch_registrations'

suite = FixtureCheck.new('compiled_owners_check')
suite.require_mrbc!

root = File.expand_path('../..', __dir__)
_ireps, registry, = StaticDispatchRegistrations.closed_world(root, ENV.fetch('MRBC', 'mrbc'))
listed = BC2CPP_COMPILED_GEMS.values.flat_map { |gem| Array(gem[:owners]) }.to_set
engine = /\A(?:Game|RPG2k3?|LCF|RGSS)(?:::|\.singleton\z|\z)/
# A module's own def is compiled through its listed `Mod.singleton` copy too (compile_all).
copied = registry.each_value.flat_map do |defs|
  defs.select { |d| d.kind == :module_function && listed.include?(d.owner) }.map(&:copy_irep)
end.to_set
unlisted = registry.each_value.flat_map do |defs|
  defs.select { |d| d.irep && d.kind.nil? && d.installer.nil? && d.owner.match?(engine) }
      .reject { |d| listed.include?(d.owner) || copied.include?(d.irep) }.map(&:owner)
end.uniq.sort
suite.check("every engine owner with a plain def is compiled (unlisted: #{unlisted.join(', ')})", unlisted.empty?)
suite.check('the registry has engine defs at all', registry.each_value.any? { |defs| defs.any? { |d| d.owner.match?(engine) } })

suite.finish!
