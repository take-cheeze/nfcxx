#!/usr/bin/env ruby
# frozen_string_literal: true

# Summarizes the BC2CPP_TRACE_ELSE=1 dumps (tools/bc2cpp/else_trace.rb): how many
# core class-tag chain else arms ran, at which generated sites, and which receiver
# classes reached them.
#
#   BC2CPP_TRACE_ELSE=1 BC2CPP_TRACE_ELSE_OUT=/path/trace.txt <instrumented binary>
#   ruby scripts/bc2cpp/else_trace_report.rb [--top N] /path/trace.txt [...]
#
# A dump is a set of tab-separated rows, one binary may append several:
#   ELSE_TRACE_SYMBOL  sym  sites N  sites_hit K  hits T
#   ELSE_SITE          sym  id  hits  overflow  method  fn  name  line  category  origin  receiver
#   ELSE_CLASS         sym  id  class  singleton(0/1)  kinds(bit mask)  hits
# kinds: 1 Array, 2 Hash, 4 String, 8 Range (the receiver is a kind of that class).

require 'optparse'

KIND_NAMES = { 1 => 'Array', 2 => 'Hash', 4 => 'String', 8 => 'Range' }.freeze
CORE_NAMES = KIND_NAMES.values.freeze

options = { top: 15 }
OptionParser.new do |o|
  o.banner = 'usage: bc2cpp_else_trace_report.rb [--top N] DUMP...'
  o.on('--top N', Integer, 'rows in the ranking (default 15)') { |n| options[:top] = n }
end.parse!
abort 'no dump files given' if ARGV.empty?

symbols = {}   # sym => { sites:, hit: }
sites = {}     # [sym, id] => { hits:, overflow:, method:, fn:, name:, line:, category:, origin:, receiver:, classes: {} }

ARGV.each do |path|
  File.foreach(path) do |raw|
    f = raw.chomp.split("\t", -1)
    case f[0]
    when 'ELSE_TRACE_SYMBOL'
      sym = f[1]
      # a symbol may be dumped by several processes; the site table is the same each time
      symbols[sym] = { sites: f[3].to_i, hit_sites: f[5].to_i }
    when 'ELSE_SITE'
      key = [f[1], f[2].to_i]
      s = sites[key] ||= { hits: 0, overflow: 0, classes: {} }
      s[:hits] += f[3].to_i
      s[:overflow] += f[4].to_i
      s.merge!(method: f[5], fn: f[6], name: f[7], line: f[8], category: f[9], origin: f[10], receiver: f[11])
    when 'ELSE_CLASS'
      key = [f[1], f[2].to_i]
      s = sites[key] ||= { hits: 0, overflow: 0, classes: {} }
      cls = (s[:classes][[f[3], f[4].to_i, f[5].to_i]] ||= 0)
      s[:classes][[f[3], f[4].to_i, f[5].to_i]] = cls + f[6].to_i
    end
  end
end

# Relation of a receiver class to the core classes the chain tests.
def relation(name, singleton, kinds)
  core = KIND_NAMES.select { |bit, _| kinds & bit != 0 }.values
  if singleton == 1
    base = core.empty? ? "not a core kind" : "kind #{core.join("/")}"
    "object with a singleton class (real class #{name}; #{base})"
  elsif CORE_NAMES.include?(name)
    # The dump does not record which classes each chain tests, so this is only the relation.
    "exact core #{name} (not a subclass and no singleton class)"
  elsif core.any?
    "user subclass of #{core.join('/')} (#{name})"
  else
    "unrelated class #{name}"
  end
end

total_hits = sites.values.sum { |s| s[:hits] }
hit_sites = sites.count { |_, s| s[:hits].positive? }
static_sites = symbols.values.sum { |v| v[:sites] }
overflow = sites.values.sum { |s| s[:overflow] }

puts "symbols traced: #{symbols.keys.join(', ')}"
puts "static core-chain else sites instrumented: #{static_sites}"
puts "distinct sites hit: #{hit_sites}"
puts "else-arm hits (total): #{total_hits}"
puts "hits beyond the per-site class table (class not recorded): #{overflow}"
puts ''
ranked = sites.select { |_, s| s[:hits].positive? }.sort_by { |key, s| [-s[:hits], key] }
puts "top #{[options[:top], ranked.size].min} sites"
ranked.first(options[:top]).each_with_index do |(key, s), rank|
  sym, id = key
  puts format('%2d. %10d  %s#%d  %s  %s  %s  [%s]', rank + 1, s[:hits], sym, id, s[:method], s[:line],
              s[:receiver], s[:category])
  puts "      fn #{s[:fn]}, name #{s[:name]}, origin #{s[:origin]}"
  s[:classes].sort_by { |(_, _, _), n| -n }.each do |(name, singleton, kinds), n|
    puts format('      %10d  %s', n, relation(name, singleton, kinds))
  end
end
