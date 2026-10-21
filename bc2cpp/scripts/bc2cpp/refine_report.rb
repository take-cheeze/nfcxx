#!/usr/bin/env ruby
# frozen_string_literal: true

# Aggregates BC2CPP_REFINE_REPORT (tools/bc2cpp/refine_report.rb, ADR 0317):
#
#   BC2CPP_CALL_FACTS=0 BC2CPP_REFINE_REPORT=refine.tsv MRBC=... ruby scripts/bc2cpp/coverage_report.rb
#   ruby scripts/bc2cpp/refine_report.rb refine.tsv [--list-bugs]
#
# Run it with BC2CPP_CALL_FACTS=0 to measure what the facts would add to the master build; with the facts on, the
# `else`/`kept` columns already show their effect. Prints stats only (and, with --list-bugs, the interface
# lint candidates).
require_relative '../../tools/bc2cpp/refine_report_columns'

path = ARGV.reject { |a| a.start_with?('--') }.first or abort "usage: #{$PROGRAM_NAME} refine.tsv [--list-bugs]"
list_bugs = ARGV.include?('--list-bugs')
cols = RefineReport::COLUMNS
rows = File.readlines(path, chomp: true).reject(&:empty?).map { |l| cols.zip(l.split("\t", -1)).to_h }
chains = File.exist?("#{path}.chains") ? File.readlines("#{path}.chains", chomp: true).reject(&:empty?).map { |l| l.split("\t", -1) } : []
engine = rows.select { |r| RefineReport::ENGINE_GEMS.include?(r['gem']) }
by_name = engine.select { |r| r['byname'].to_i.positive? }
unproven = by_name.select { |r| r['existing'] == 'unproven' }

def table(title, pairs)
  puts "-- #{title} --"
  pairs.each { |k, v| puts format('%6d  %s', v, k) }
  puts
end

puts "rows: #{rows.size}; engine gems #{engine.size}; by-name sites #{by_name.size} (#{by_name.sum { |r| r['byname'].to_i }} lines)"
rows.group_by { |r| r['gem'] }.sort.each do |gem, rs|
  puts format('  %-12s sends %5d  by-name sites %4d (%d lines)  unproven receivers %5d', gem, rs.size,
              rs.count { |r| r['byname'].to_i.positive? }, rs.sum { |r| r['byname'].to_i }, rs.count { |r| r['existing'] == 'unproven' })
end
puts

# What the by-name text of a site is: the chain's kept else, an arm of a chain whose else is already dead, or bare.
shape = lambda do |r|
  if r['kept'] != '-' then 'kept else (core_or_native etc.)'
  elsif r['else'] == 'nomethod' then 'nomethod else, by-name arm'
  else 'no chain (bare dispatch)'
  end
end
kept_all = by_name.select { |r| r['kept'] != '-' }
puts "kept-else sites (CLOSED_WORLD kept): #{kept_all.size}, receiver unproven #{kept_all.count { |r| r['existing'] == 'unproven' }}"
puts

verdict_of = lambda do |r, prefix|
  v = r[prefix == :fwd ? 'verdict' : 'web_verdict']
  usable = r[prefix == :fwd ? 'usable' : 'web_usable'] == '1'
  case v
  when 'none' then 'no name'
  when 'unbounded' then 'names bound nothing'
  when 'empty', 'error' then usable ? v : "#{v} (not user classes)"
  else usable ? "user-class set, #{v}" : "finite set with core/native/class-object members, #{v}"
  end
end

[[:fwd, 'FORWARD interface (sound): names an earlier call on the value answered on every path'],
 [:bwd, 'BACKWARD interface (upper bound, unsound): every name called on the value anywhere in the method']].each do |prefix, title|
  puts "== #{title}"
  table('by-name sites with an unproven receiver, by what the interface gives',
        unproven.group_by { |r| verdict_of.call(r, prefix) }.map { |k, v| [k, v.size] }.sort_by { |k, v| [-v, k] })
  removal = unproven.select { |r| r[prefix == :fwd ? 'verdict' : 'web_verdict'] == 'removal' && r[prefix == :fwd ? 'usable' : 'web_usable'] == '1' }
  table("sites whose by-name else would go (#{removal.size}), by the shape of today's by-name text",
        removal.group_by(&shape).map { |k, v| [k, v.size] }.sort_by { |k, v| [-v, k] })
  elsewhere = removal.select { |r| shape.call(r) == 'kept else (core_or_native etc.)' }
  puts "  by-name sends removed (kept else): #{elsewhere.size} sites, #{elsewhere.sum { |r| r['byname'].to_i }} lines"
  puts "  by kept reason: #{elsewhere.group_by { |r| r['kept'] }.map { |k, v| "#{k}=#{v.size}" }.join(' ')}"
  puts "  by gem: #{elsewhere.group_by { |r| r['gem'] }.map { |k, v| "#{k}=#{v.size}" }.join(' ')}"
  puts
  next unless prefix == :fwd

  usable = unproven.select { |r| r['usable'] == '1' }
  single = usable.select { |r| r['single_usable'] == '1' }
  puts "  usable user-class sets: #{usable.size}; one fact alone gives a usable set at #{single.size}, only the multi-name interface at #{usable.size - single.size}"
  rem_single = elsewhere.select { |r| r['single'] == 'removal' && r['single_usable'] == '1' }
  puts "  kept-else removals: one fact alone suffices at #{rem_single.size}, only the multi-name interface at #{elsewhere.size - rem_single.size}"
  puts "  facts per usable site: #{usable.group_by { |r| [r['facts'].split(',').size, 4].min }.sort.map { |k, v| "#{k == 4 ? '4+' : k}=#{v.size}" }.join(' ')}"
  puts "  empty/error (a contradiction between two names, or a send no class answers): #{unproven.count { |r| %w[empty error].include?(r['verdict']) }}"
  puts
end

# -- the lint: classes that cannot satisfy the interface used at a site
puts '== BACKWARD interface as a lint (candidates only: a branch may test the class first)'
lint = by_name.select { |r| r['web_verdict'] == 'empty' }
puts "  by-name sites whose value is called with names no single class answers: #{lint.size}"
all_with_web = rows.select { |r| r['web'] != '' }
puts "  all sends with an interface: #{all_with_web.size}; no class satisfies it: #{all_with_web.count { |r| r['web_verdict'] == 'empty' }}"
if list_bugs
  all_with_web.select { |r| r['web_verdict'] == 'empty' }.sort_by { |r| [r['where'], r['name']] }.each do |r|
    puts "    #{r['where']}  #{r['method']} -> #{r['name']}  interface: #{r['web']}"
  end
end
puts

# -- NOMETHOD sites classified by the interface of the value they send to
puts "== NOMETHOD sites classified by the interface of their receiver"
nm = rows.select { |r| r['else'] == 'nomethod' && %w[SEND SEND0 SENDB].include?(r['op']) }
keyed = nm.group_by { |r| "#{r['method']} -> #{r['name']}" }
classify = lambda do |r|
  listed = r['listed'].split(',')
  set = r['web_set'].split(',')
  return 'no interface (receiver not traced)' if r['web'] == ''
  return 'interface bounds no class' if r['web_verdict'] == 'unbounded'
  return 'POSSIBLE BUG: no class satisfies the interface' if set.empty?
  if (set & listed).empty? && r['web_kind'].match?(/native|core|classobj/)
    return 'satisfied by native or core classes (their arms are not in the chain)'
  end
  return 'POSSIBLE BUG: no listed class satisfies the interface' if (set & listed).empty? && !listed.empty?
  return 'monomorphic (one arm)' if listed.size <= 1
  return 'polymorphic else arm (several listed classes satisfy the interface)' if (set & listed).size >= 2

  'narrowed (the interface leaves one listed class)'
end
table("nomethod sites: #{nm.size}, keys: #{keyed.size}", nm.group_by(&classify).map { |k, v| [k, v.size] }.sort_by { |k, v| [-v, k] })
key_class = keyed.transform_values do |rs|
  cs = rs.map(&classify)
  cs.find { |c| c.start_with?('POSSIBLE BUG') } || cs.first
end
table('keys (the worst site of a key decides)', key_class.values.tally.sort_by { |k, v| [-v, k] })
bugs = nm.select { |r| classify.call(r).start_with?('POSSIBLE BUG') }
puts "  possible bugs: #{bugs.size} sites in #{bugs.map { |r| "#{r['method']} -> #{r['name']}" }.uniq.size} keys"
bugs.sort_by { |r| [r['where'], r['name']] }.each do |r|
  puts "    #{r['where']}  #{r['method']} -> #{r['name']}  interface: #{r['web']}  listed: #{r['listed']}  satisfy: #{r['web_set']}"
end
puts

# -- chains whose classes reach the same definition
puts '== guard chains whose classes share a definition (a shared arm or a class-id interval check)'
engine_chains = chains.select { |c| engine.any? { |r| r['irep'] == c[0] && r['idx'] == c[1] } }
shared = engine_chains.select { |c| c[5].to_i < c[4].to_i }
puts "  chains of 2+ classes: #{engine_chains.size}; with at least two classes on one definition: #{shared.size}"
puts "  arms now #{engine_chains.sum { |c| c[4].to_i }}, distinct definitions #{engine_chains.sum { |c| c[5].to_i }} (#{engine_chains.sum { |c| c[4].to_i - c[5].to_i }} compares a shared arm saves)"
table('by family', engine_chains.group_by { |c| c[3] }.map { |f, cs| ["#{f}: #{cs.size} chains, #{cs.count { |c| c[5].to_i < c[4].to_i }} with sharing, #{cs.sum { |c| c[4].to_i - c[5].to_i }} saved", cs.size] })
table('chain length of the sharing chains', shared.group_by { |c| c[4].to_i }.sort.map { |k, v| ["#{k} classes", v.size] })
