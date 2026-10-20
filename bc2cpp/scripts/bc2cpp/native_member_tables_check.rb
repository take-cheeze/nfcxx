#!/usr/bin/env ruby
# frozen_string_literal: true

# Check ADR 0516 steps 1 to 4: native table membership is per member, read by NativeSigs and RbsSignatures.
#
#   1. a fixture block with one tagged and one untagged member: NativeSigs.select_table keeps the tagged member only, the
#      block header stays, a block with no member of the table is skipped, a block with no members keeps its marker;
#   2. the untagged member is a program hint (RbsSignatures.load), the tagged one a native declaration; a fact-table
#      member is skipped while a non-fact member of the same class is declared;
#   3. NativeSigs.table_source writes the members under their markers and reads back as the same members, for the
#      fixture and for every table of sig/bc2cpp/declarations.rbs.
#
# Usage: ruby scripts/bc2cpp/native_member_tables_check.rb

require 'rbs'
require 'tmpdir'
require_relative '../../tools/bc2cpp/native_sigs'
require_relative '../../tools/bc2cpp/rbs_signatures'

failures = []
check = lambda do |what, condition|
  puts "  #{condition ? 'ok  ' : 'FAIL'} #{what}"
  failures << what unless condition
end

FIXTURE = <<~RBS
  # bc2cpp-native: fixture_native
  class Whole
    def first: () -> Integer
    # bc2cpp-native: fixture_other
    def other: () -> Integer
  end

  class Shared
    # bc2cpp-native: fixture_native
    def native_one: () -> Integer

    def hand: () -> String
  end

  # bc2cpp-native: fixture_other
  class OnlyOther
    def ignored: () -> Integer
  end

  # bc2cpp-native: fixture_native
  class Empty
  end

  class Untagged
    def plain: () -> Integer
  end

  # bc2cpp-native: core_class_tests
  class Facts
    def fact_m: () -> Integer
    # bc2cpp-native: fixture_native
    def kept_native: () -> Integer
  end
RBS

def parse_text(text)
  _buf, _dirs, decls = RBS::Parser.parse_signature(RBS::Buffer.new(name: 'fixture.rbs', content: text))
  decls
end

# Names of each block and of its members, in order: what a reader sees.
def summary(decls)
  decls.map do |d|
    [d.name.to_s, d.members.map { |m| m.respond_to?(:name) ? m.name.to_s : m.class.name.split('::').last }]
  end
end

fixture = parse_text(FIXTURE)
lines = FIXTURE.lines
by_name = fixture.to_h { |d| [d.name.to_s, d] }
shared = by_name.fetch('Shared')
whole = by_name.fetch('Whole')

puts '== per-member membership'
check.call('a member with no marker of its own takes the block\'s table', NativeSigs.table_of(whole.members.first, [whole]) == 'fixture_native')
check.call('a member\'s own marker wins over its block\'s', NativeSigs.table_of(whole.members.last, [whole]) == 'fixture_other')
check.call('a hand-owned member beside a tagged one has no table', NativeSigs.table_of(shared.members.last, [shared]).nil?)
check.call('native? is true for the tagged member and false for the hand-owned one',
           NativeSigs.native?(shared.members.first, [shared]) && !NativeSigs.native?(shared.members.last, [shared]))
check.call('table_of a block is its own marker', NativeSigs.table_of(whole) == 'fixture_native')

puts '== decls: restriction'
native = NativeSigs.select_table(fixture, 'fixture_native')
other = NativeSigs.select_table(fixture, 'fixture_other')
native_by_name = native.to_h { |d| [d.name.to_s, d] }
check.call('the tagged member and the block tagged for the table: Whole keeps only `first`',
           native_by_name.key?('Whole') && native_by_name['Whole'].members.map { |m| m.name.to_s } == %w[first])
check.call('an untagged member beside a tagged one: Shared keeps only `native_one`',
           native_by_name.key?('Shared') && native_by_name['Shared'].members.map { |m| m.name.to_s } == %w[native_one])
check.call('a block with no member of the table is skipped (OnlyOther, Untagged)',
           !native_by_name.key?('OnlyOther') && !native_by_name.key?('Untagged'))
check.call('a block with no members keeps today\'s behaviour: Empty is returned whole', native_by_name['Empty'].equal?(by_name['Empty']))
check.call('a member of a fact-table block is restricted too: Facts keeps `kept_native`',
           native_by_name.key?('Facts') && native_by_name['Facts'].members.map { |m| m.name.to_s } == %w[kept_native])
check.call('the restricted block has the same header (name, super class, comment, location)',
           native_by_name['Shared'].name == shared.name && native_by_name['Shared'].super_class == shared.super_class &&
           native_by_name['Shared'].comment.equal?(shared.comment) && native_by_name['Shared'].location == shared.location)
check.call('table fixture_other: Whole keeps `other`, OnlyOther keeps `ignored`',
           summary(other) == [['Whole', ['other']], ['OnlyOther', ['ignored']]])

puts '== program hints (RbsSignatures)'
Dir.mktmpdir('native-member-tables') do |dir|
  path = File.join(dir, 'fixture.rbs')
  File.write(path, FIXTURE)
  loaded = RbsSignatures.load([dir], display_root: dir)
  methods = loaded.methods
  check.call('the untagged member beside a tagged one is a program hint (declared, not native)',
             methods.key?(['Shared', 'hand']) && !methods[['Shared', 'hand']].loc.native)
  check.call('the tagged member is declared as native', methods.key?(['Shared', 'native_one']) && methods[['Shared', 'native_one']].loc.native)
  check.call('a member of a fact table is not declared', !methods.key?(['Facts', 'fact_m']))
  check.call('a non-fact member of a fact-table block is declared as native',
             methods.key?(['Facts', 'kept_native']) && methods[['Facts', 'kept_native']].loc.native)
  check.call('an untagged block is a program hint', methods.key?(['Untagged', 'plain']) && !methods[['Untagged', 'plain']].loc.native)
  check.call('RbsSignatures.fact_table? reads a member with its block', RbsSignatures.fact_table?(fixture.last.members.first, [fixture.last]))
  check.call('RbsSignatures.fact_table? is false for the non-fact member', !RbsSignatures.fact_table?(fixture.last.members.last, [fixture.last]))
  check.call('the diagnostics of the fixture are empty', loaded.diagnostics.empty?)
end

puts '== table_source: markers and round trip'
text = NativeSigs.source_text(fixture, lines, 'fixture_native')
check.call('every kept member is written under the table marker',
           text.scan("# bc2cpp-native: fixture_native\n").size == 4 && !text.include?('def other') && !text.include?('def ignored'))
check.call('the source reads back as the same members (fixture_native)',
           summary(NativeSigs.select_table(parse_text(text), 'fixture_native')) == summary(native))
check.call('the source reads back as the same members (fixture_other)',
           summary(NativeSigs.select_table(parse_text(NativeSigs.source_text(fixture, lines, 'fixture_other')), 'fixture_other')) == summary(other))

puts '== table_source: every table of declarations.rbs'
parsed = NativeSigs.parse
tables = parsed.flat_map { |d| NativeSigs.tables_in(d) }.uniq
check.call("the file names #{tables.size} tables", tables.size > 1)
round = tables.to_h do |name|
  id = NativeSigs.table(name)
  back = parse_text(NativeSigs.table_source(id))
  here = NativeSigs.decls(id)
  only_its_table = back.all? { |d| NativeSigs.tables_in(d) == [name] }
  [name, only_its_table && summary(back) == summary(here)]
end
check.call("each of the #{tables.size} tables reads back as exactly its own members: #{round.reject { |_, ok| ok }.keys.join(', ')}",
           round.values.all?)

puts
if failures.empty?
  puts 'native member tables: all checks passed'
else
  puts "native member tables: #{failures.size} failure(s)"
  exit 1
end
