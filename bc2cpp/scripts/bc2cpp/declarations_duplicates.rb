#!/usr/bin/env ruby
# frozen_string_literal: true

# Reports the members of sig/bc2cpp/declarations.rbs that repeat: one method of one owner declared more than once, and
# how many of those repeats carry the same signature. Grouped by the section each copy sits in, so the base stubs, the
# native tables and the trace-derived sections can be compared.
#
#   ruby scripts/bc2cpp/declarations_duplicates.rb [DECLARATIONS]
#
# Needs the RBS version the Gemfile pins (4.0.0): older RBS cannot parse the optional record keys (`?battle: Game::Battle`).

require 'rbs'
require 'set'

FILE = File.expand_path(ARGV[0] || File.join(__dir__, '../../sig/bc2cpp/declarations.rbs'))
text = File.read(FILE)
_buf, _dirs, decls = RBS::Parser.parse_signature(RBS::Buffer.new(name: 'declarations.rbs', content: text))

# Section of a line: the nearest preceding `# ---- <name>` heading.
headings = text.lines.each_with_index.filter_map { |l, i| [i + 1, l.strip.delete_prefix('# ---- ')] if l.start_with?('# ---- ') }
section_at = lambda do |line|
  headings.select { |n, _| n <= line }.last&.last || '(file top)'
end

Member = Struct.new(:owner, :kind, :name, :signature, :section, :line)
members = []
walk = lambda do |owner, nodes|
  nodes.each do |node|
    case node
    when RBS::AST::Declarations::Class, RBS::AST::Declarations::Module
      walk.call("#{owner}#{node.name}", node.members)
    when RBS::AST::Members::MethodDefinition
      kind = node.singleton? ? 'self.' : '#'
      members << Member.new(owner, kind, node.name, node.overloads.map { |o| o.method_type.to_s }.join(' | '),
                            section_at.call(node.location.start_line), node.location.start_line)
    end
  end
end
walk.call('', decls)

groups = members.group_by { |m| [m.owner, m.kind, m.name] }
repeated = groups.select { |_, ms| ms.size > 1 }
same_signature = repeated.count { |_, ms| ms.map(&:signature).uniq.size == 1 }

puts "members: #{members.size}, distinct methods: #{groups.size}"
puts "repeated methods: #{repeated.size} (#{repeated.values.sum { |ms| ms.size - 1 }} extra copies)"
puts "  of which every copy has the same signature: #{same_signature}"
puts
puts 'extra copies by section (the first copy of each method is not counted):'
tally = Hash.new(0)
repeated.each_value { |ms| ms.drop(1).each { |m| tally[m.section] += 1 } }
tally.sort_by { |_, n| -n }.each { |section, n| puts format('%6d  %s', n, section) }
puts
puts 'pairs of sections that repeat each other most (repeated method counted once per pair):'
pairs = Hash.new(0)
repeated.each_value do |ms|
  ms.map(&:section).uniq.combination(2) { |a, b| pairs[[a, b].sort] += 1 }
end
pairs.sort_by { |_, n| -n }.first(12).each { |(a, b), n| puts format('%6d  %s  <->  %s', n, a, b) }

puts
puts 'repeats whose copies all carry the same signature, by the sections they sit in:'
same = Hash.new(0)
repeated.each_value do |ms|
  next unless ms.map(&:signature).uniq.size == 1

  same[ms.map(&:section).uniq.sort] += 1
end
same.sort_by { |_, n| -n }.first(12).each { |sections, n| puts format('%6d  %s', n, sections.join('  <->  ')) }
