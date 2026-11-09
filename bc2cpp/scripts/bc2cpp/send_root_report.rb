#!/usr/bin/env ruby
# frozen_string_literal: true

# Ranks the producers behind the by-name sends left in the shipped C++.
#
#   mkdir -p /tmp/keep
#   MRBC=<host mrbc> BC2CPP_SEND_ROOT_REPORT=/tmp/keep/rows.tsv BC2CPP_COVERAGE_KEEP_DIR=/tmp/keep \
#     ruby scripts/bc2cpp/coverage_report.rb > /dev/null
#   ruby scripts/bc2cpp/send_root_report.rb /tmp/keep [OWNER_PREFIX_REGEX]
#
# tools/bc2cpp/send_root_report.rb tags every by-name line of the generated C++ with `/*SR:<irep>:<site>*/`
# and writes one row per tagged send (its receiver's producer and why that producer's class is unproven).
# This joins the shipped sites (scripts/bc2cpp/dynamic_site_census.rb) to those rows by the tag, so the
# counts are sites that really ship, then tallies the roots. The tags change the generated text: the
# numbers are for ranking, and the census of an untagged build is the one to quote.
#
# OWNER_PREFIX_REGEX filters on the generated function name (default `\A(RPG2k|Game)_`).

require 'open3'
require 'tmpdir'

dir = ARGV[0] or abort "usage: #{$PROGRAM_NAME} KEEP_DIR [FUNCTION_PREFIX_REGEX]"
prefix = Regexp.new(ARGV[1] || '\A(RPG2k|Game)_')
shipped = File.join(dir, 'shipped.cxx')
rows_path = File.join(dir, 'rows.tsv')
abort "#{shipped} and #{rows_path} are needed (see the header)" unless File.exist?(shipped) && File.exist?(rows_path)

lines = File.readlines(shipped)
rows = {}
pools = []
File.foreach(rows_path) do |l|
  f = l.chomp.split("\t", -1)
  f[0] == 'POOL' ? pools << f : rows[f[0]] = f
end

sites = Dir.mktmpdir do |tmp|
  tsv = File.join(tmp, 'sites.tsv')
  _out, err, status = Open3.capture3(RbConfig.ruby, File.join(__dir__, 'dynamic_site_census.rb'), shipped, '--tsv', tsv)
  abort err unless status.success?
  File.readlines(tsv).map { |l| l.chomp.split("\t", -1) }
end
sites.select! { |s| s[1].match?(prefix) }

# Row fields: id owner irep site name receiver_set producer_kind producer_name producer_status
joined = sites.map do |s|
  tag = lines[s[0].to_i - 1][%r{/\*SR:([^*]*)\*/}, 1]
  [s, tag && rows[tag]]
end

tally = lambda do |title, items, top = 20|
  puts "== #{title}"
  items.tally.sort_by { |k, v| [-v, k.to_s] }.first(top).each { |k, v| puts "#{v}\t#{Array(k).join(' | ')}" }
end

puts "sites matching #{prefix.source}: #{sites.size}; joined to a row: #{joined.count { |_, r| r }}"
tally.call('producer of the receiver', joined.map { |_, r| r ? r[6] : 'untagged' })
tally.call('call-result producers: name | status', joined.select { |_, r| r && r[6] == 'send' }.map { |_, r| [r[7], r[8].sub(/ recv=.*/, '')] }, 30)
tally.call('ivar producers: owner @name | pool state', joined.select { |_, r| r && r[6] == 'ivar' }.map { |_, r| [r[1], "@#{r[7]}", r[8].split(' ').first] }, 20)
tally.call('ivar producers: why the pool is not there', joined.select { |_, r| r && r[6] == 'ivar' }.map { |_, r| r[8].sub(/\Apooled:.*/, 'pooled').split(' ', 2).first }, 10)
tally.call('receivers the flow proves completely (the consumer still goes by name): set | census category',
           joined.select { |_, r| r && r[5] !~ /OTHER|unmodelled|\A-\z/ }.map { |s, r| [r[5], s[8]] }, 20)
puts "== dropped class pools of the matching families: #{pools.count { |p| p[1].match?(/\A(RPG2k|Game)/) }}"
