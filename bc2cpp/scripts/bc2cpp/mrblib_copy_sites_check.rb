#!/usr/bin/env ruby
# frozen_string_literal: true

# COPY SITES (tools/bc2cpp/mrblib_stubs.rb, copy_source?): a def named by a copy (alias, alias_method, instance_method,
# module_function) is kept as bytecode unless every site of that name copies from a class whose ancestors are exact
# and do not include the def's owner. This checks the decision on synthetic class graphs, with no host mrbc: accept
# and refuse cases, and a mutation (the rule ignoring ancestry) that the cases must catch.
#
# Usage: ruby scripts/bc2cpp/mrblib_copy_sites_check.rb

require_relative 'check_support'
require_relative '../../tools/bc2cpp/class_world'
require_relative '../../tools/bc2cpp/mrblib_stubs'
require_relative '../../tools/bc2cpp/load_compile'

suite = FixtureCheck.new('mrblib_copy_sites_check')

def fact(name, superclass: nil, includes: [], kind: :class)
  ClassWorld::Fact.new(name: name, kind: kind, superclass: superclass, includes: includes, prepends: [], extends: [],
                       bodies: [], reasons: [], created_by: nil)
end

# RGSS::Window < Object (the alias source of `initialize`); Object; Game::Actor; A includes M; a module M.
CLASSES = {
  'Object' => fact('Object'),
  'RGSS::Window' => fact('RGSS::Window', superclass: 'Object'),
  'Game::Actor' => fact('Game::Actor', superclass: 'Object'),
  'M' => fact('M', kind: :module),
  'A' => fact('A', superclass: 'Object', includes: ['M']),
  'Odd' => fact('Odd', superclass: 'Object')
}.freeze
EXACT = { 'Object' => { 'exact' => true }, 'RGSS::Window' => { 'exact' => true }, 'Game::Actor' => { 'exact' => true },
          'M' => { 'exact' => true }, 'A' => { 'exact' => true }, 'Odd' => { 'exact' => false } }.freeze
WORLD = ClassWorld::World.new(classes: CLASSES, unknown_sites: [], subclass_unknown: false, facts: EXACT)

# expected: true when the copy may take the def as its source (the def is kept), false when it may not (dropped).
CASES = [
  ['accept: a def of an unrelated class, copied from RGSS::Window', 'Game::Actor', ['RGSS::Window'], false],
  ['accept: a singleton def, copied from an instance site', 'Game.singleton', ['RGSS::Window'], false],
  ['refuse: the copy source class itself', 'RGSS::Window', ['RGSS::Window'], true],
  ['refuse: an ancestor of the site (Object)', 'Object', ['RGSS::Window'], true],
  ['refuse: a module included by the site (M)', 'M', ['A'], true],
  ['refuse: an unknown site', 'Game::Actor', [:unknown], true],
  ['refuse: one unknown site among known ones', 'Game::Actor', ['RGSS::Window', :unknown], true],
  ['refuse: a site whose class is not exact', 'Game::Actor', ['Odd'], true],
  ['refuse: a site with no facts', 'Game::Actor', ['Missing'], true],
  ['refuse: no sites recorded', 'Game::Actor', [], true]
].freeze

CASES.each do |label, owner, sites, expected|
  suite.check(label, MrblibStubs.copy_source?(owner, 'initialize', sites, WORLD) == expected)
end
suite.check('refuse: a name outside the staged set is kept (name-based)', MrblibStubs.copy_source?('Game::Actor', 'x', ['RGSS::Window'], WORLD) == true)
suite.check('refuse: without a class world every copy may take the def', MrblibStubs.copy_source?('Game::Actor', 'initialize', ['RGSS::Window'], nil) == true)

# The load plan's pin of a copy source (LoadCompile.copy_pinned?): the same rule with the def_key of the def.
PIN_CASES = [
  ['pin: an alias source defined by the body\'s own class (RGSS::Window#initialize)', 'RGSS::Window#initialize', 'initialize', ['RGSS::Window'], true],
  ['no pin: another class\'s initialize, aliased from RGSS::Window', 'Game::Actor#initialize', 'initialize', ['RGSS::Window'], false],
  ['pin: a source of an unknown body', 'Game::Actor#initialize', 'initialize', [:unknown], true],
  ['no pin: a name with no copy site', 'Game::Actor#x', 'x', [], false]
].freeze
PIN_CASES.each do |label, def_key, name, sites, expected|
  suite.check(label, LoadCompile.copy_pinned?(def_key, name, { name => sites }, WORLD) == expected)
end

# Mutation: the rule without the ancestry test. It must disagree with the expected answer on some case, or the
# cases do not hold the rule.
mutant = lambda do |owner, sites, world|
  return true if sites.nil? || sites.empty?

  sites.any? { |site| site == :unknown || world.facts[site].nil? || !world.facts[site]['exact'] || true }
end
caught = CASES.count { |_label, owner, sites, expected| mutant.call(owner, sites, WORLD) != expected }
suite.check("mutation (ancestry ignored) is caught by #{caught} case(s)", caught.positive?)

suite.finish!
