#!/usr/bin/env ruby
# frozen_string_literal: true

# Aggregate the BC2CPP_ITAB_REPORT TSV (tools/bc2cpp/interface_table_report.rb, ADR 0315): why the else arm of
# a guard chain still dispatches by name, whether the receiver's class set is proven (the precondition for any
# per-class "interface table" cell), what each cell would be, and the per-name method-set sizes.
#
#   BC2CPP_ITAB_REPORT=itab.tsv MRBC=<host mrbc> ruby scripts/bc2cpp/coverage_report.rb > /dev/null
#   ruby scripts/bc2cpp/interface_table_report.rb itab.tsv [owner-regexp]
#
# itab.tsv.names (written beside it) holds one row per method name. The owner regexp filters the TSV by the
# enclosing method's owner; the default is every owner.

path = ARGV.fetch(0) { abort 'usage: bc2cpp_interface_table_report.rb itab.tsv [owner-regexp]' }
owners = Regexp.new(ARGV[1] || '.')
COLUMNS = %i[fn irep idx name argc block family else gates set origin origin_ivar listed cells native].freeze
rows = File.readlines(path, chomp: true).map { |line| COLUMNS.zip(line.split("\t", -1)).to_h }
rows.select! { |row| row[:fn].match?(owners) }

def tally_table(title, pairs, limit = nil)
  puts "-- #{title} --"
  pairs = pairs.sort_by { |key, n| [-n, key.to_s] }
  (limit ? pairs.first(limit) : pairs).each { |key, n| puts format('%6<n>d  %<key>s', n: n, key: Array(key).join(' | ')) }
  puts
end

# The final code of these still reaches a by-name call: a kept reason, or a funcall with no marker.
dispatching = rows.select { |row| row[:else].start_with?('kept:') || row[:else] == 'send' }
proven = ->(row) { !row[:set].start_with?('unproven') }

puts "#{rows.size} explicit-receiver sends with a guard chain (owners #{owners.source})"
tally_table('family x else arm', rows.map { |row| [row[:family], row[:else]] }.tally)
puts "#{dispatching.size} sites whose else arm still dispatches by name; " \
     "#{dispatching.count(&proven)} have a proven receiver class set, #{dispatching.count { |row| !proven.(row) }} do not"
puts

tally_table('(a) why the else is kept x receiver set proven?',
            dispatching.map { |row| [row[:else], proven.(row) ? 'proven set' : 'UNPROVEN set'] }.tally)
tally_table('unproven sets: receiver origin x flow mask',
            dispatching.reject(&proven).map { |row| [row[:origin], row[:set].sub('unproven:', '').gsub(/\b(RPG2k3?|Game|RGSS|LCF)::\w+/, 'K')] }.tally, 14)
tally_table('every refusal gate the name fails (a site counts once per gate), proven sets',
            dispatching.select(&proven).flat_map { |row| row[:gates].split(',') }.tally)
tally_table('every refusal gate the name fails, unproven sets',
            dispatching.reject(&proven).flat_map { |row| row[:gates].split(',') }.tally)
tally_table('gate combinations, proven sets', dispatching.select(&proven).map { |row| row[:gates] }.tally)

puts '-- (b) proven sets: name, set, what each interface-table cell would be --'
dispatching.select(&proven).group_by { |row| [row[:name], row[:else], row[:set], row[:cells]] }
           .sort_by { |_key, group| -group.size }.each do |(name, kind, set, cells), group|
  puts format('%4<n>d  %<name>s  %<kind>s  {%<set>s}  %<cells>s', n: group.size, name: name, kind: kind, set: set, cells: cells)
end
puts

cell_class = lambda do |cells|
  kinds = cells.split('|').map { |cell| cell.split('=').last }
  if kinds.all? { |kind| %w[ruby_direct native_direct native_core_direct absent].include?(kind) } then 'every cell is a direct body or an error'
  elsif kinds.any? { |kind| %w[absent_or_native native_send].include?(kind) } then 'a cell is a native with no frame-independent entry (a send)'
  else 'a cell is not direct-callable'
  end
end
tally_table('proven sets by cell makeup', dispatching.select(&proven).map { |row| cell_class.(row[:cells]) }.tally)

core_or_native = dispatching.select { |row| row[:gates].include?('core_or_native') }
tally_table('core_or_native sites by name (registered natives, audited entries)',
            core_or_native.group_by { |row| [row[:name], row[:native]] }.transform_values(&:size), 20)

names_path = "#{path}.names"
if File.exist?(names_path)
  names = File.readlines(names_path, chomp: true).map { |line| line.split("\t") }
  counts = names.map { |_n, ruby, _single, native, _outside| [ruby.to_i, native.to_i] }
  puts '-- (c) per-name method-set sizes (Ruby instance-method owners per name, whole registry) --'
  puts "#{names.size} names; #{counts.count { |ruby, _| ruby >= 2 }} have >= 2 Ruby instance owners; " \
       "#{counts.count { |ruby, native| ruby >= 2 && native == 1 }} of those are also natively defined"
  buckets = counts.map do |ruby, _|
    case ruby
    when 0..4 then ruby.to_s
    when 5..8 then '5-8'
    when 9..16 then '9-16'
    else '>=17'
    end
  end.tally
  puts "  owners per name: #{%w[0 1 2 3 4 5-8 9-16 >=17].map { |k| "#{k}:#{buckets.fetch(k, 0)}" }.join(' ')}"
  chains = rows.select { |row| %w[POLY_SMALL_N POLY_TABLE].include?(row[:family]) }
  by_len = chains.map { |row| row[:listed].split('|').size }.tally
  puts "  guard-chain classes at POLY sites: #{(1..9).map { |n| "#{n}:#{by_len.fetch(n, 0)}" }.join(' ')} >9:#{by_len.select { |n, _| n > 9 }.values.sum}"
end
