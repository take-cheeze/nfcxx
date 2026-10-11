#!/usr/bin/env ruby
# frozen_string_literal: true

# Aggregates BC2CPP_BLOCK_SEND_REPORT (tools/bc2cpp/block_send_report.rb, ADR 0325):
#
#   BC2CPP_BLOCK_SEND_REPORT=bs.tsv MRBC=... ruby scripts/bc2cpp/coverage_report.rb
#   ruby scripts/bc2cpp/block_send_report.rb bs.tsv [--gem mruby-rpg2k] [--list SHAPE]
#
# Prints, for the engine block sends: callee name by shape, where the receiver is proven, why a dynamic send is
# kept, and how many sites each candidate lever could free. Stats only; `--list` prints the rows of one kind.
require_relative '../../tools/bc2cpp/block_send_report_columns'

args = ARGV.dup
gem_name = (i = args.index('--gem')) ? args.slice!(i, 2).last : 'mruby-rpg2k'
list = (i = args.index('--list')) ? args.slice!(i, 2).last : nil
path = args.first or abort "usage: #{$PROGRAM_NAME} bs.tsv [--gem GEM] [--list SHAPE]"
cols = BlockSendReport::COLUMNS
rows = File.readlines(path, chomp: true).reject(&:empty?).map { |l| cols.zip(l.split("\t", -1)).to_h }
sel = rows.select { |r| r['gem'] == gem_name }
dyn = sel.select { |r| r['byname'].to_i.positive? }

def table(title, pairs)
  puts "-- #{title} --"
  pairs.each { |k, v| puts format('%6d  %s', v, k) }
  puts
end

def tally(rows)
  rows.group_by { |r| yield r }.transform_values(&:size).sort_by { |k, v| [-v, k.to_s] }
end

puts "rows #{rows.size}; #{gem_name}: #{sel.size} block sends, #{dyn.size} still reach by-name dispatch (#{dyn.sum { |r| r['byname'].to_i }} lines)"
puts

table('shape (all block sends)', tally(sel) { |r| r['shape'] })
table('by-name sites by callee name', tally(dyn) { |r| r['name'] })
table('callee name by shape', tally(sel) { |r| "#{r['name']} #{r['shape']}" }.first(40))

proven = ->(r) { r['existing'] != 'unproven' }
table('receiver, sites that keep a by-name line', tally(dyn) do |r|
  if proven.call(r) then "exact flow proves #{r['existing']}"
  elsif r['fact_usable'] == '1' then 'facts bound a user-class set (usable)'
  elsif r['fact_kind'] == '-' then 'no earlier call on the value (no fact)'
  else "facts: #{r['fact_kind']} (not usable)"
  end
end)

table('receiver producer, sites that keep a by-name line', tally(dyn) do |r|
  kind, name = r['producer'].split(':', 2)
  kind == 'ivar' || kind == 'const' || kind == 'send' ? "#{kind} #{name}" : kind
end.first(30))
table('receiver producer kind', tally(dyn) { |r| r['producer'].split(':', 2).first.sub(/\(.*/, '(..)') })

# Why the by-name line is kept.
reason = lambda do |r|
  case r['shape']
  when 'proven_guarded'
    if r['entry'] != '1' then 'proven class, Fiber guard: block has no direct entry'
    elsif r['free'] != '1' then 'proven class, Fiber guard: block not proved yield-free'
    else 'proven class, Fiber guard: callee body not relaxable'
    end
  when 'exact_arms' then 'receiver not proven exact (class-test arms, dynamic else)'
  when 'mono_direct' then 'one resolved call, kept chain else'
  when 'dynamic' then r['arms'].empty? ? 'no compiled core arm for the name' : 'arms exist but none was emitted'
  when 'explicit' then '&expr block (no body)'
  else r['shape']
  end
end
table('why the dynamic line is kept', tally(dyn, &reason))
table('no core arm: first failing gate per name', tally(dyn.select { |r| r['shape'] == 'dynamic' }) { |r| "#{r['name']}: #{r['why'][0, 90]}" }.first(30))

# Levers.
puts '-- levers (sites that would lose their by-name line if the proof held) --'
a = dyn.select { |r| !proven.call(r) && r['fact_usable'] == '1' }
puts format('%6d  (a) SENDB receiver facts: unproven receiver, facts bound a usable user-class set', a.size)
puts format('%6d      of those with shape exact_arms/dynamic/mono_direct: %s', a.size,
            a.group_by { |r| r['shape'] }.transform_values(&:size).inspect)
puts format('%6d  (a2) facts bound a core/native/mixed set (CALL_FACTS rejects it, per-class native arms needed)',
            dyn.count { |r| !proven.call(r) && r['fact_usable'] != '1' && !%w[- unbounded empty].include?(r['fact_kind']) })
new_sites = dyn.select { |r| r['name'] == 'new' }
puts format('%6d  (b) `new` with a block (Array.new / Hash.new / other): receiver proven %s', new_sites.size,
            new_sites.group_by { |r| r['existing'] }.transform_values(&:size).inspect)
no_entry = dyn.select { |r| r['entry'] != '1' && r['kind'] == 'literal' }
puts format('%6d  (c) literal blocks without a direct entry (break/return/receiver self): brk %d ret %d self_source %d',
            no_entry.size, no_entry.count { |r| r['brk'] == '1' }, no_entry.count { |r| r['ret'] == '1' },
            no_entry.count { |r| r['self_source'] == 'receiver' })
c_removable = no_entry.select { |r| r['shape'] == 'proven_guarded' && r['free_if_entry'] == '1' && r['arms'].include?('+') }
puts format('%6d      of those, proven class + yield-free + relaxable body: the else could go', c_removable.size)
puts
if list == 'facts'
  # Sites whose facts name a bounded set the build would not accept (core, native or mixed members).
  dyn.reject { |r| %w[- unbounded].include?(r['fact_kind']) }.each do |r|
    puts [r['name'], r['shape'], r['facts'], r['fact_kind'], r['fact_set'][0, 100], r['where'].sub(%r{.*/(mruby-)}, '\1')].join("\t")
  end
elsif list
  sel.select { |r| r['shape'] == list }.each { |r| puts [r['name'], r['argc'], r['existing'], r['fact_kind'], r['arms'], r['where']].join("\t") }
end
