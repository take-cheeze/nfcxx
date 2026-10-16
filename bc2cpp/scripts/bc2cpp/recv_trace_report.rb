#!/usr/bin/env ruby
# frozen_string_literal: true

# Reads the BC2CPP_TRACE_RECV=1 dumps (tools/bc2cpp/recv_trace.rb) and reports the receiver classes of
# every by-name send and block call in the generated methods:
#
#   (a) totals by kind (send, block), and how many sites saw one receiver class (direct-call candidates);
#   (b) the busiest sites with their receiver class histogram.
#
#   ruby scripts/bc2cpp/recv_trace_report.rb [--top N] DUMP [...]
#
# Dump rows (tab separated; a binary may append several, counts are summed by site):
#   RECV_TRACE_SYMBOL sym sites N sites_hit N hits N
#   RECV_SITE  sym id hits overflow method fn name line kind receiver
#   RECV_CLASS sym id class singleton kinds hits

require 'optparse'

options = { top: 20 }
OptionParser.new do |o|
  o.banner = 'usage: recv_trace_report.rb [--top N] DUMP [...]'
  o.on('--top N', Integer, 'busiest sites to list (default 20)') { |n| options[:top] = n }
end.parse!
abort 'no dump files given' if ARGV.empty?

Site = Struct.new(:key, :method, :fn, :name, :line, :kind, :recv, :hits, :overflow, :classes, keyword_init: true)

sites = {}
ARGV.each do |path|
  File.foreach(path) do |raw|
    f = raw.chomp.split("\t", -1)
    case f[0]
    when 'RECV_SITE'
      key = [f[1], f[2].to_i]
      s = sites[key] ||= Site.new(key: key, method: f[5], fn: f[6], name: f[7], line: f[8], kind: f[9], recv: f[10],
                                  hits: 0, overflow: 0, classes: Hash.new(0))
      s.hits += f[3].to_i
      s.overflow += f[4].to_i
    when 'RECV_CLASS'
      s = sites[[f[1], f[2].to_i]] or next
      s.classes[f[3]] += f[6].to_i
    end
  end
end

used = sites.values.select { |s| s.hits.positive? }
puts "sites instrumented: #{sites.size}, reached at run time: #{used.size}"
%w[send block].each do |kind|
  rows = used.select { |s| s.kind == kind }
  calls = rows.sum(&:hits)
  mono = rows.select { |s| s.classes.size == 1 && s.overflow.zero? }
  puts format('  %-6s sites %5d  calls %12d  single receiver class %5d (%d calls)',
              kind, rows.size, calls, mono.size, mono.sum(&:hits))
end
puts ''

puts "== busiest sites (top #{options[:top]} by calls) =="
used.sort_by { |s| [-s.hits, s.method, s.line.to_s] }.first(options[:top]).each_with_index do |s, i|
  hist = s.classes.sort_by { |c, n| [-n, c] }.map { |c, n| format('%s %d', c, n) }.join(', ')
  hist += ", +#{s.overflow} in further classes" if s.overflow.positive?
  puts format('%3d. %10d %-5s %-30s %s %s [%s]', i + 1, s.hits, s.kind, s.name.to_s, s.method, s.line, hist)
end
