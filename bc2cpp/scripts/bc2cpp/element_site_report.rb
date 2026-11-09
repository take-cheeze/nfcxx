#!/usr/bin/env ruby
# frozen_string_literal: true

# Aggregate the BC2CPP_ELEMENT_REPORT TSV: of the
# instructions that can still reach a by-name call, how many read an element of a container, what that
# container is, and whether the classes written into mutable ivar containers are known at all.
#
#   BC2CPP_ELEMENT_REPORT=elements.tsv MRBC=<host mrbc> ruby scripts/bc2cpp/coverage_report.rb > /dev/null
#   ruby scripts/bc2cpp/element_site_report.rb elements.tsv [owner-regexp]
#
# The owner regexp defaults to the rpg2k engine (`RPG2k` / `Game` namespaces).

path = ARGV.fetch(0) { abort 'usage: bc2cpp_element_site_report.rb elements.tsv [owner-regexp]' }
owners = Regexp.new(ARGV[1] || '\A(RPG2k|Game)')
rows = File.readlines(path, chomp: true).map { |line| line.split("\t") }.select { |row| row[2].match?(owners) }
sites = rows.select { |row| row[0] == 'site' }
stores = rows.select { |row| row[0] == 'store' }

ELEMENT_TAG = /\A(?:idx|first|last|max|min|sample|pop|shift|fetch|at|dig|\[\]|min_by|max_by|detect|find)<(.*)>\z/

# The container kind of an element origin tag, or nil when the tag is not an element read.
def container_kind(tag)
  inner = tag[ELEMENT_TAG, 1] or return nil
  case inner
  when /\Aivar:/ then 'ivar'
  when /\Aidx<|\A\w+<.*>\z/ then 'nested element'
  when 'entry' then 'parameter / block parameter'
  when /\Ascall:/ then 'implicit-self call result'
  when /\Acall:/ then 'call result'
  when 'upvar' then 'captured local'
  when 'fresh_lit' then 'fresh literal'
  when 'const' then 'constant'
  when 'refused' then 'unanalysable (query refused)'
  else 'other'
  end
end

element_sites = sites.filter_map do |row|
  kinds = row[6].split('|').filter_map { |tag| container_kind(tag) }.uniq
  [row, kinds] unless kinds.empty?
end

puts "#{sites.size} sites reach a by-name call (owners #{owners.source}); #{element_sites.size} read an element"
puts '-- element reads by container kind (a site with several origins counts once per kind) --'
element_sites.flat_map { |_row, kinds| kinds }.tally.sort_by { |_, n| -n }.each do |kind, n|
  puts format('%6<n>d  %<kind>s', n: n, kind: kind)
end

ivar_sites = Hash.new { |hash, name| hash[name] = [] }
element_sites.each do |row, _kinds|
  row[6].split('|').each { |tag| ivar_sites[Regexp.last_match(1)] << row if tag =~ /<ivar:(\w+)>\z/ }
end

# Per container ivar: the class sets of what each `@x = <literal>` creation holds and of every element
# write. A set naming OTHER (or "unmodelled") means some stored value's class is not a flow fact.
creations = Hash.new { |hash, name| hash[name] = [] }
writes = Hash.new { |hash, name| hash[name] = [] }
stores.each do |row|
  row[5].split('|').each do |tag|
    name = tag[/\Aivar:(\w+)\z/, 1] or next
    next unless ivar_sites.key?(name)

    (row[3] == 'SETIV' ? creations : writes)[name] << row[6]
  end
end
classed = ->(set) { !set.match?(/OTHER|unmodelled/) }
known = ivar_sites.keys.select do |name|
  !creations[name].empty? && (creations[name] + writes[name]).all?(&classed)
end

puts
puts "-- #{ivar_sites.size} ivar containers read at a by-name site --"
puts format('%6<n>d  creations (`@x = ...`) seen; %<k>d hold only literal contents of known classes (or are empty)',
            n: creations.values.sum(&:size), k: creations.values.flatten.count(&classed))
puts format('%6<n>d  element writes seen; %<k>d store a value whose class set is known', n: writes.values.sum(&:size),
                                                                                         k: writes.values.flatten.count(&classed))
puts format('%6<n>d  ivars with a creation and every creation/write classed (ceiling: aliasing and escapes not even checked)', n: known.size)
puts format('%6<n>d  element-read sites on those ivars, of %<t>d on any ivar container', n: known.sum { |name| ivar_sites[name].size },
                                                                                         t: ivar_sites.values.sum(&:size))

puts "       #{known.map { |name| "@#{name} (#{ivar_sites[name].size})" }.join(', ')}" unless known.empty?

puts
puts '-- ivar containers by element-read sites (sites, ivar, creation / element-write class sets) --'
ivar_sites.sort_by { |_, list| -list.size }.first(25).each do |name, list|
  show = ->(sets) { sets.empty? ? '-' : sets.tally.sort_by { |_, n| -n }.first(3).to_h.inspect }
  puts format('%5<n>d  @%-20<name>s creations %-40<c>s writes %<w>s', n: list.size, name: name, c: show.(creations[name]), w: show.(writes[name]))
end

# `[a, b].max` / `.min`: these sends are the ordinary dispatch (no core inline). The report still sorts them by
# whether every element is proven Integer (a Float may be NaN), as the input to a future inline.
extremes = rows.select { |row| row[0] == 'extreme' }
literal = extremes.select { |row| row[5] == 'literal' }
all_integer = literal.select { |row| row[6].split(',').all?('INT') }
puts
puts "-- min/max sends: #{extremes.size}; #{literal.size} on a literal built by the previous instruction; " \
     "#{all_integer.size} with every element proven Integer --"
literal.map { |row| row[6] }.tally.sort_by { |_, n| -n }.first(8).each { |sets, n| puts format('%5<n>d  [%<sets>s]', n: n, sets: sets) }
