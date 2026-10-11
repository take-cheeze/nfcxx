#!/usr/bin/env ruby
# frozen_string_literal: true

# Aggregates BC2CPP_RECEIVER_PROOF_REPORT (tools/bc2cpp/receiver_proof_report.rb, ADR 0331):
#
#   BC2CPP_RECEIVER_PROOF_REPORT=rp.tsv MRBC=<host mrbc> ruby scripts/bc2cpp/coverage_report.rb > /dev/null
#   ruby scripts/bc2cpp/receiver_proof_report.rb rp.tsv [--list SOURCE]
#
# Per source of an unproven receiver: how many by-name sites it has, how many lose every by-name line when the
# receiver is forced to the source's own set (`own`) or to every class that answers the name (`floor`: holds
# whatever set is proven), each without and with nil allowed, and what blocks the rest. Stats only.
require_relative '../../tools/bc2cpp/receiver_proof_report_columns'

path = ARGV.first or abort "usage: #{$PROGRAM_NAME} rp.tsv [--list SOURCE]"
list = (i = ARGV.index('--list')) ? ARGV[i + 1] : nil
cols = ReceiverProofReport::COLUMNS
rows = File.readlines(path, chomp: true).reject(&:empty?).map { |l| cols.zip(l.split("\t", -1)).to_h }

# What a proof of each source has to establish, as risk tiers (1 = a local fact of the method, 2 = a fact about a
# value's producer, 3 = a whole-program fact or a container's contents): the unit the ranking divides by.
RISK = { 'merge' => 2, 'call' => 2, 'element' => 3, 'argument' => 3, 'ivar' => 3, 'const' => 2, 'upvar' => 2,
         'self' => 1, 'literal' => 1, 'other' => 3 }.freeze

def tally(rows)
  rows.group_by { |r| yield r }.transform_values(&:size).sort_by { |k, v| [-v, k.to_s] }
end

def table(title, pairs)
  puts "-- #{title} --"
  pairs.each { |k, v| puts format('%6d  %s', v, Array(k).join(' | ')) }
  puts
end

proven = ->(r) { r['existing'] != '-' }
unproven = rows.reject(&proven)
gone = ->(value, r) { value != '-' && r['before'].to_i.positive? && value.to_i.zero? }
modelled = ->(r) { r['hyp'] != '-' }
own = ->(r) { modelled.call(r) && gone.call(r['after'], r) }
own_nil = ->(r) { modelled.call(r) && gone.call(r['after_nil'], r) }
floor = ->(r) { gone.call(r['floor_after'], r) }
floor_nil = ->(r) { gone.call(r['floor_nil'], r) }
blocker = lambda do |r|
  kinds = r['kinds'].split('+') - %w[ruby_direct native_direct native_core_direct absent]
  if r['answerers'] == 'unbounded' then 'name unbounded (a dynamic definer)'
  elsif r['answerers'] == '-' then 'no instance class answers'
  elsif kinds.empty? then 'every cell direct, a gate other than a cell'
  else kinds.sort.join('+')
  end
end

puts "rows #{rows.size} (engine sends with a by-name line); proven receiver set #{rows.count(&proven)}, unproven #{unproven.size}"
puts "by-name lines: #{rows.sum { |r| r['before'].to_i }} (unproven #{unproven.sum { |r| r['before'].to_i }})"
puts

table('unproven sites by source', tally(unproven) { |r| r['source'] })
puts '-- per source: sites | own set | own removes | own, nil allowed | floor removes | floor, nil allowed | risk | floor per risk --'
unproven.group_by { |r| r['source'] }.sort_by { |_s, g| -g.size }.each do |source, g|
  risk = RISK.fetch(source, 3)
  puts format('%-9<s>s %5<n>d %5<h>d %5<o>d %5<on>d %5<f>d %5<fn>d  risk %<r>d  %<p>.1f', s: source, n: g.size,
                                                                                         h: g.count(&modelled), o: g.count(&own),
                                                                                         on: g.count(&own_nil), f: g.count(&floor),
                                                                                         fn: g.count(&floor_nil), r: risk,
                                                                                         p: g.count(&floor_nil).fdiv(risk))
end
puts format('%-9<s>s %5<n>d %5<h>d %5<o>d %5<on>d %5<f>d %5<fn>d', s: 'total', n: unproven.size,
                                                                   h: unproven.count(&modelled), o: unproven.count(&own),
                                                                   on: unproven.count(&own_nil), f: unproven.count(&floor),
                                                                   fn: unproven.count(&floor_nil))
puts

# The first thing that stops the floor freeing a site (the sites it frees are `freed`).
blocker_class = lambda do |r|
  kinds = r['kinds'].split('+')
  if floor_nil.call(r) then 'freed'
  elsif r['answerers'] == 'unbounded' then 'name unbounded (dynamic definer)'
  elsif r['answerers'] == '-' then 'no instance class answers'
  elsif kinds.any? { |k| %w[absent_or_native native_send unknown_lookup].include?(k) } then 'a native cell'
  elsif kinds.include?('ruby_not_direct') then 'a Ruby body that is not direct'
  elsif kinds.any? { |k| k.start_with?('accessor') } then 'an ivar accessor cell'
  else 'a gate other than a cell'
  end
end
order = ['freed', 'a native cell', 'a Ruby body that is not direct', 'an ivar accessor cell', 'name unbounded (dynamic definer)',
         'no instance class answers', 'a gate other than a cell']
puts '-- per source: what the floor (nil allowed) frees, and the first thing that stops it elsewhere --'
puts format('%-9s %5s %s', 'source', 'sites', %w[freed native ruby-not-dir ivar-accessor unbounded no-class other-gate].map { |o| o.ljust(13) }.join(' '))
unproven.group_by { |r| r['source'] }.sort_by { |_s, g| -g.size }.each do |source, g|
  t = g.map { |r| blocker_class.call(r) }.tally
  puts format('%-9s %5d %s', source, g.size, order.map { |o| t.fetch(o, 0).to_s.ljust(13) }.join(' '))
end
puts
table('sites the floor (every answering class, nil allowed) does not free, by what the answering classes define',
      tally(unproven.reject(&floor_nil)) { |r| [r['source'], blocker.call(r)] }.first(30))
table('floor-freed sites (nil allowed) by callee name', tally(unproven.select(&floor_nil)) { |r| [r['name'], r['answerers']] }.first(25))
table('own-set removable sites by source, callee and set (nil allowed)',
      tally(unproven.select(&own_nil)) { |r| [r['source'], r['name'], r['hyp']] }.first(20))
table('own set complete (nothing unmodelled in its source) and still unproven',
      tally(unproven.select { |r| r['hyp_complete'] == '1' }) { |r| [r['source'], r['detail'], r['hyp']] }.first(20))
calls = unproven.select { |r| r['source'] == 'call' }
audited = calls.select { |r| r['hyp_complete'] == 'audit' }
table('call sites whose only unmodelled definitions are natives, with an assumed result class (nil allowed): callee, class, sites, freed',
      audited.group_by { |r| [r['detail'], r['hyp']] }.map { |k, g| [[k, g.size, g.count(&own_nil)].flatten.join(' | '), g.size] }.sort_by { |k, v| [-v, k] })
puts "audited-native sites #{audited.size}, freed with the assumed class #{audited.count(&own_nil)}"
puts
table('call sites: kind of each unmodelled return among the definitions of the callee (a site counts once per kind)',
      calls.flat_map { |r| r['why'].split(',').map { |w| w.split(':').first }.uniq }.tally.sort_by { |k, v| [-v, k] })
table('call sites: unmodelled return, by callee and what the return is', tally(calls) { |r| [r['detail'], r['why']] }.first(25))
table('call sites: the producing call resolved per proven receiver class', tally(calls) { |r| r['percls'].sub(/:.*/, '') })
ivars = unproven.select { |r| r['source'] == 'ivar' }
table('ivar sites: why the slot has no class pool', tally(ivars) { |r| r['why'].start_with?('dropped') ? 'dropped' : r['why'] })
table('ivar sites: the ivar, why, and sites the floor (nil allowed) frees',
      ivars.group_by { |r| [r['detail'], r['why']] }.map { |k, g| [[k, g.count(&floor_nil)].flatten.join(' | '), g.size] }
           .sort_by { |k, v| [-v, k] }.first(25))
args = unproven.select { |r| r['source'] == 'argument' }
# `no_candidate` is a union of entry_arg_candidates' admission rules 1-8, each a different proof, plus two rows no
# rule describes (a block parameter, whose value the callee yields, and a native entry with no bytecode body); the
# rule is in the `why` so the non-candidates split by what they actually need.
no_cand = ->(r) { r['why'].start_with?('no_candidate') }
table('argument sites: why the parameter has no class pool', tally(args) { |r| r['why'].start_with?('dropped') ? 'dropped' : r['why'] })
table('non-candidate sites: the rule each refuses on, and how many the floor (nil allowed) frees',
      tally(args.select(&no_cand)) { |r| [r['why'].sub('no_candidate:', ''), floor_nil.call(r) ? 'freed' : 'blocked'] }
        .sort_by { |k, _v| [-k[1].to_s.size, k[0].to_s] })
table('non-candidate sites the floor (nil allowed) frees, by rule',
      tally(args.select(&no_cand).select(&floor_nil)) { |r| r['why'].sub('no_candidate:', '') })
table('non-candidate rows: rule, method, and how many of its sites the floor frees',
      args.select(&no_cand).group_by { |r| [r['why'].sub('no_candidate:', ''), r['owner']] }
        .map { |k, g| [[k, g.count(&floor_nil)].join(' | '), g.size] }.sort_by { |k, v| [-v, k] }.first(25))
table('argument sites: dropped, by the producers of the unmodelled arguments',
      tally(args.select { |r| r['why'].start_with?('dropped') }) { |r| r['why'].sub('dropped:', '').split(',').map { |k| k.sub(/:.*/, '') }.uniq.sort.join(',') }.first(12))
table('merge sites: class and what the other arm is', tally(unproven.select { |r| r['source'] == 'merge' }) { |r| r['detail'] }.first(15))
table('by-name lines the own set removes (nil allowed), nil-helper lines it adds instead',
      [["by-name lines removed #{unproven.select(&own_nil).sum { |r| r["before"].to_i - r["after_nil"].to_i }}", 0],
       ["bc2cpp_nil_receiver lines added #{unproven.select(&own_nil).sum { |r| r["reloc"].to_i }}", 0],
       ["bc2cpp_nomethod lines added #{unproven.select(&own_nil).sum { |r| r["nomethod_delta"].to_i }}", 0]])

# ADR 0341: which LEVER removes a site's by-name line. The risk-tier table above ranks how hard a proof would be; this
# one ranks what would actually have to change, and the two are not the same population -- most unproven sites are not
# waiting on a receiver proof at all.
ABSENT_CELLS = %w[absent absent_or_native].freeze
lever = lambda do |r|
  return 'no_floor (unbounded or unanswered name)' unless r['floor_nil'] =~ /\A\d+\z/
  return 'freed by any receiver proof' if floor_nil.call(r)
  return 'consumer gap (no Ruby body to call)' if (r['kinds'].split('+') & ABSENT_CELLS).any?

  'other cell'
end
puts '-- structural lever: what would actually remove the by-name line (ADR 0341) --'
puts format('%-42s %6s %6s', 'lever', 'sites', 'lines')
unproven.group_by { |r| lever.call(r) }.sort_by { |_k, g| -g.size }.each do |name, g|
  puts format('%-42s %6d %6d', name, g.size, g.sum { |r| r['before'].to_i })
end
block_only = unproven.select { |r| r['argc'].to_i.zero? && r['before'].to_i.positive? }
puts format('%-42s %6d %6d', 'of which a block-only callee (argc 0)', block_only.size,
            block_only.sum { |r| r['before'].to_i })
gap = unproven.select { |r| lever.call(r).start_with?('consumer gap') }
puts format('%-42s %6d %6d', 'consumer-gap sites with a block-only callee',
            gap.count { |r| r['argc'].to_i.zero? }, gap.select { |r| r['argc'].to_i.zero? }.sum { |r| r['before'].to_i })
# The check ADR 0341 exists to keep honest: relaxing direct_callable? for a &block parameter looks like a win from the
# `each` concentration, so count what it would actually reach (a site with no absent cell to bypass).
rnd = unproven.select { |r| r['kinds'].split('+').include?('ruby_not_direct') }
puts format('%-42s %6d %6d', 'ruby_not_direct sites', rnd.size, rnd.sum { |r| r['before'].to_i })
puts format('%-42s %6d %6d', '  ... of those, no absent cell to bypass',
            rnd.count { |r| (r['kinds'].split('+') & ABSENT_CELLS).empty? },
            rnd.select { |r| (r['kinds'].split('+') & ABSENT_CELLS).empty? }.sum { |r| r['before'].to_i })
puts

puts unproven.select { |r| r['source'] == list }.map { |r| r.values_at(*cols).join("\t") } if list
