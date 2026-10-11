#!/usr/bin/env ruby
# frozen_string_literal: true

# Census of the dynamic dispatch left in bc2cpp's generated C++.
#
# Static mode (counts every site once):
#   BC2CPP_COVERAGE_KEEP_DIR=DIR MRBC=... ruby scripts/bc2cpp/coverage_report.rb
#   ruby scripts/bc2cpp/dynamic_site_census.rb DIR/shipped.cxx [--tsv sites.tsv]
#
# Counts by-name dispatch (`bc2cpp_send`, `mrb_funcall*`, `mrb_yield_argv`) split
# into call sites in generated methods and the by-name calls held inside shared
# helpers, and classifies every `bc2cpp_send` site by its neighbouring
# diagnostics.
#
# Rank mode (ranks the same sites by how often a run executes them):
#   ruby scripts/bc2cpp/dynamic_site_census.rb --rank SITES_DIR \
#        --workload NAME=HITS_DIR [--workload ...] [--top 30] [--tsv ranked.tsv]
#   SITES_DIR holds the <symbol>.sites.tsv files bc2cpp wrote under
#   BC2CPP_SITE_PROFILE=SITES_DIR; HITS_DIR the <symbol>.<pid>.hits files a
#   binary built from that output wrote under BC2CPP_SITE_PROFILE_OUT.
#
# See docs/bc2cpp-dynamic-site-census.md for the method and its limits. Output
# is stats only.

$LOAD_PATH.unshift(File.expand_path('../../tools/bc2cpp', __dir__))
require 'site_census'
require 'site_rank'

if ARGV.first == '--rank'
  ARGV.shift
  SiteRank.main(ARGV)
  exit
end

path = ARGV.shift or abort "usage: #{$PROGRAM_NAME} shipped.cxx [--origins TABLE] [--tsv FILE] | --rank SITES_DIR --workload NAME=HITS_DIR"
tsv = nil
origins = nil
until ARGV.empty?
  case ARGV.shift
  when '--tsv' then tsv = ARGV.shift
  when '--origins' then origins = ARGV.shift
  else abort "unknown option (see #{$PROGRAM_NAME})"
  end
end
src = File.read(path)
begin
  scan = SiteCensus.scan(src, origins: origins && SiteCensus.origin_table(origins))
rescue RuntimeError => e
  abort e.message
end
lines = scan.lines
first_method = scan.first_method
sites = scan.sites
helper_sends = scan.helper_sends

def tally(rows, key)
  rows.group_by(&key).transform_values(&:size).sort_by { |k, v| [-v, k.to_s] }
end

def show(title, pairs, limit = nil)
  puts "-- #{title} --"
  (limit ? pairs.first(limit) : pairs).each { |k, v| puts format('%6d  %s', v, k) }
end

body_count = ->(re) { lines.each_with_index.count { |l, i| l =~ re && l !~ %r{^\s*//} && i >= first_method } }
open_form = SiteCensus.open_form_mask(lines, first_method)
helper_count = ->(re) { lines[0...first_method].each_with_index.count { |l, i| l =~ re && l !~ %r{^\s*//} && !open_form[i] } }

puts "file: #{File.basename(path)} (#{lines.size} lines); helper region = lines 1..#{first_method}"
puts
puts '-- raw counts (generated-method bodies; helper-region counts in parentheses) --'
puts format('bc2cpp_send call sites:              %6d (%d)', sites.size, helper_sends.values.sum)
puts format('mrb_funcall_with_block:              %6d (%d)', body_count.(/mrb_funcall_with_block\(/), helper_count.(/mrb_funcall_with_block\(/))
puts format('BLOCK_FALLBACK markers:              %6d', lines.count { |l| l.include?('BLOCK_FALLBACK :') })
puts format('mrb_funcall(_argv/_id):              %6d (%d)', body_count.(/\bmrb_funcall(?:_argv|_id)?\(/), helper_count.(/\bmrb_funcall(?:_argv|_id)?\(/))
puts format('mrb_yield_argv:                      %6d (%d)', body_count.(/\bmrb_yield_argv\(/), helper_count.(/\bmrb_yield_argv\(/))
puts format('bc2cpp_nomethod sites (not dynamic): %6d', body_count.(/bc2cpp_nomethod\(/))
puts

puts '-- by-name calls held inside shared helpers (and how many generated call sites reach each) --'
helper_sends.group_by { |(f, _), _| f }.each do |f, rows|
  callers = lines.each_with_index.count { |l, i| i >= first_method && l =~ /\b#{Regexp.escape(f.to_s)}\(/ }
  puts format('%-26<f>s %-10<n>s by-name calls:%<c>d  generated callers:%<k>d',
              f: f, n: rows.map { |(_, n), _| n }.uniq.join(','), c: rows.sum { |_, c| c }, k: callers)
end
puts

show('else-arm of an inline fast path vs only dispatch', tally(sites, ->(s) { s[:class_arm] ? 'known-class arm (class proven, still by name)' : (s[:else_arm] ? 'fast-path else-arm' : 'bare dispatch') }))
puts
show('category (exclusive; first matching rule wins)', tally(sites, ->(s) { s[:category] }), 30)
puts
show(origins ? 'receiver origin (exact walk, SiteOriginTable)' : 'receiver origin (heuristic text walk)', tally(sites, ->(s) { s[:origin] }))
puts
show('receiver origin status', tally(sites, ->(s) { s[:origin_status] }))
puts
if origins
  show('receiver origin of a join (ambiguous row: the origins its definitions have)',
       tally(sites.select { |s| s[:origin_set] }, ->(s) { s[:origin_set].join('|') }))
  puts
end
show('guard shape guarding the dispatch (code immediately before the site)', tally(sites, ->(s) { s[:shape] }))
puts
show('marker family (nearest preceding family comment)', tally(sites, ->(s) { s[:marker] }), 30)
puts
show('why dynamic (POLY_DIAG path/receiver/origin)', tally(sites, ->(s) { s[:why] }), 40)
puts
show('why dynamic, path only', tally(sites, ->(s) { s[:why].split('/').first }))
puts
show('why dynamic, receiver only', tally(sites, ->(s) { s[:why].split('/')[1] || '-' }))
puts
show('why dynamic, origin only', tally(sites, ->(s) { s[:why].split('/')[2] || '-' }))
puts
show('excluded= reasons', sites.flat_map { |s| (s[:excluded] || '').split(',').map { |e| e.sub(/=\d+\z/, '') } }.reject(&:empty?).tally.sort_by { |k, v| [-v, k] })
puts
show('TOP 40 method names', tally(sites, ->(s) { s[:name] }), 40)

if tsv
  File.open(tsv, 'w') do |f|
    sites.each { |s| f.puts [s[:line], s[:fn], s[:name], s[:argc], s[:class_arm] ? 'class_arm' : s[:else_arm], s[:marker], s[:shape], s[:origin], s[:category], s[:why], s[:origin_status], s[:origin_set]&.join('|')].join("\t") }
  end
end
