#!/usr/bin/env ruby
# frozen_string_literal: true

# Aggregates BC2CPP_DEAD_ARM_REPORT (tools/bc2cpp/dead_arm_report.rb, ADR 0330):
#
#   BC2CPP_DEAD_ARM_REPORT=da.tsv MRBC=... ruby scripts/bc2cpp/coverage_report.rb
#   ruby scripts/bc2cpp/dead_arm_report.rb da.tsv [--lcov coverage/lcov.info] [--list]
#
# Prints the proven-error arms by class, the other must-raise shapes, and the REACHABLE sole-arm (b) and nil-path (c)
# sites grouped by receiver origin. `--list` prints every such site with file:line; `--lcov` (scripts/coverage/report.rb)
# adds whether a passing CRuby check executed the line. Stats only; it changes nothing.
require_relative '../../tools/bc2cpp/dead_arm_report_columns'

args = ARGV.dup
list = args.delete('--list')
lcov = (i = args.index('--lcov')) ? args.slice!(i, 2).last : nil
path = args.first or abort "usage: #{$PROGRAM_NAME} da.tsv [--lcov lcov.info] [--list]"
rows = File.readlines(path, chomp: true).reject(&:empty?).map { |l| DeadArmReport::COLUMNS.zip(l.split("\t", -1)).to_h }

covered = {}
if lcov
  file = nil
  File.foreach(lcov) do |l|
    if l.start_with?('SF:') then file = covered[l[3..].strip] = {}
    elsif l.start_with?('DA:')
      line, count = l[3..].strip.split(',')
      file[line.to_i] = count.to_i
    end
  end
end
# Whether a CRuby check ran the site's line: :covered, :uncovered, or :unknown (no data for it).
coverage = lambda do |row|
  file, line = row['where'].split(/:(?=\d+\z)/)
  hits = covered.find { |k, _| file.end_with?(k) }&.last&.dig(line.to_i)
  hits.nil? ? :unknown : (hits.positive? ? :covered : :uncovered)
end

def table(title, pairs)
  puts "-- #{title} --"
  pairs.each { |k, v| puts format('%6d  %s', v, k) }
  puts
end

def tally(rows)
  rows.group_by { |r| yield r }.transform_values(&:size).sort_by { |k, v| [-v, k.to_s] }
end

arms = rows.select { |r| %w[nomethod nil_receiver].include?(r['kind']) }
# Exclusive classes, first match wins: (d) the body cannot be called, (e) a rescue / probe / receiver branch guards the
# site, (b) the send has no other arm, (c) the arm is a nil path, (a) the else of a send with live arms.
klass = lambda do |r|
  if r['live'] == 'dead' then '(d) unreachable method body'
  elsif r['guard'] != '-' then "(e) guarded: #{r['guard']}"
  elsif r['shape'] == 'sole' then '(b) the only arm of the send'
  elsif r['shape'] == 'nil' then '(c) nil path of a nil-or-one-class receiver'
  else '(a) dead fallback of a send with live arms'
  end
end

puts "rows #{rows.size}; arms #{arms.size} (nomethod #{arms.count { |r| r['kind'] == 'nomethod' }}, " \
     "nil_receiver #{arms.count { |r| r['kind'] == 'nil_receiver' }})"
puts
table('arms by class (exclusive: d, e, b, c, a)', tally(arms, &klass).sort)
provable = rows.select { |r| r['kind'] == 'partial_miss' && r['shape'] == 'all' }
table('(b) sends that always raise', [
        ['arms that are the only arm of their send', arms.count { |r| r['shape'] == 'sole' }],
        ['sends whose proven receiver classes all lack the name (dispatch kept)', provable.size]
      ])
table('arms by shape, liveness and guard', tally(arms) { |r| "#{r['shape']} #{r['live']} #{r['guard']}" })
table('arms by gem and class', tally(arms) { |r| "#{r['gem']} #{klass.call(r)}" }.sort)

reachable = arms.select { |r| r['live'] == 'live' && %w[sole nil].include?(r['shape']) }
open = reachable.select { |r| r['guard'] == '-' }
puts "REACHABLE sole/nil arms: #{reachable.size}; with no guard #{open.size} (sole #{open.count { |r| r['shape'] == 'sole' }}, " \
     "nil #{open.count { |r| r['shape'] == 'nil' }})"
puts
table('REACHABLE (b)/(c) by shape and entry', tally(open) { |r| "#{r['shape']} entry=#{r['entry']}" })
origin = ->(r) { r['origin'].sub(/ \[.*\]/, '').sub(/ ctor\z/, '').sub(/call:.*/, 'call:*') }
table('REACHABLE (b)/(c) by receiver origin', tally(open, &origin).first(25))
table('REACHABLE (b)/(c) by owner class and origin (top 40)', tally(open) { |r| "#{r['method'].split('#', 2).first} #{origin.call(r)}" }.first(40))
unless covered.empty?
  table('REACHABLE (b)/(c): a passing CRuby check executed the line', tally(open) { |r| coverage.call(r).to_s })
end

other = rows - arms
table('other must-raise shapes', tally(other) { |r| "#{r['kind']}#{r['kind'] == 'partial_miss' ? " (#{r['shape']})" : ''} #{r['live']} #{r['guard']}" }.sort)
table('partial_miss by missing class set', tally(rows.select { |r| r['kind'] == 'partial_miss' }) { |r| r['origin'] }.first(10))
table('const_unresolved by name', tally(rows.select { |r| r['kind'] == 'const_unresolved' }) { |r| "#{r['name']} (#{r['guard']})" })

if list
  puts '== REACHABLE (b)/(c) sites (unguarded)'
  open.sort_by { |r| [r['where'].split(':').first, r['where'].split(':').last.to_i, r['name']] }.each do |r|
    cov = covered.empty? ? '' : " [#{coverage.call(r)}]"
    puts "#{r['where']}  #{r['method']}  #{r['name']}  #{r['shape']}  #{r['origin']}  entry=#{r['entry']}#{cov}"
  end
  puts
  puts '== guarded and dead (b)/(c) sites'
  (arms - open).reject { |r| r['shape'] == 'chain' }.sort_by { |r| [r['where'].split(':').first, r['where'].split(':').last.to_i] }.each do |r|
    puts "#{r['where']}  #{r['method']}  #{r['name']}  #{r['shape']}  live=#{r['live']} guard=#{r['guard']}"
  end
end
