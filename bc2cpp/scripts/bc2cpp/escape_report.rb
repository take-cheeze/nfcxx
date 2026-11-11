#!/usr/bin/env ruby
# frozen_string_literal: true

# Aggregate the BC2CPP_ESCAPE_REPORT TSV (tools/bc2cpp/escape_report.rb): per creation kind,
# how many sites the shared escape analysis proves non-escaping, why the rest escape, and what that is
# worth to each consumer. Given the shipped C++ of the same run, a second pass counts only the sites in
# methods that ship (the ones the build actually contains).
#
#   BC2CPP_ESCAPE_REPORT=escape.tsv MRBC=<host mrbc> BC2CPP_COVERAGE_KEEP_DIR=out ruby scripts/bc2cpp/coverage_report.rb > /dev/null
#   ruby scripts/bc2cpp/escape_report.rb escape.tsv [out/shipped.cxx]

require 'set'

path = ARGV.fetch(0) { abort 'usage: bc2cpp_escape_report.rb escape.tsv [shipped.cxx]' }
rows = File.readlines(path, chomp: true).map { |line| line.split("\t", -1) }
all_sites = rows.select { |r| r[0] == 'site' }
ivars = rows.select { |r| r[0] == 'ivars' }
selves = rows.select { |r| r[0] == 'self' }
shipped = ARGV[1] && File.read(ARGV[1], encoding: 'BINARY').scan(%r{^// (\S+#\S+) \(compiled from irep}).flatten.to_set

def kind(row)
  row[5].sub(/\Ablock:.*/, 'block')
end

def table(sites, title)
  puts "#{title}: #{sites.size} creation sites"
  puts format('%-8s %-8s %7s %9s %9s', 'origin', 'kind', 'sites', 'confined', 'escapes')
  sites.group_by { |r| [r[3], kind(r)] }.sort.each do |(origin, k), list|
    conf = list.count { |r| r[6] == 'confined' }
    puts format('%-8s %-8s %7d %9d %9d', origin, k, list.size, conf, list.size - conf)
  end
end

def lambdas_and_blocks(sites)
  lambdas = sites.select { |r| r[4] == 'LAMBDA' }
  puts "-- lambdas: #{lambdas.size} sites; compiled today as confined (CONFINED_LAMBDA_CALL): " \
       "#{lambdas.count { |r| r[9] == 'confined' }}, as plain LAMBDA_FALLBACK: #{lambdas.count { |r| r[9] == 'lambda' }}; " \
       "proven confined by the analysis: #{lambdas.count { |r| r[6] == 'confined' }}, with " \
       "#{lambdas.select { |r| r[6] == 'confined' }.sum { |r| r[8].to_i }} `.call` uses"
  lambdas.select { |r| r[6] == 'confined' && r[9] != 'confined' }.each { |r| puts "   newly confined: #{r[2]} (#{r[9]})" }
  lambdas.select { |r| r[6] == 'escapes' && r[9] == 'confined' }.each { |r| puts "   LOST: #{r[2]} (#{r[7]})" }
  puts "   why the others escape: #{lambdas.select { |r| r[6] == 'escapes' }.map { |r| r[7] }.tally.sort_by { |_, n| -n }.to_h}"

  blocks = sites.select { |r| r[4] == 'BLOCK' }
  rproc = blocks.select { |r| r[9] == 'rproc' }
  puts "-- blocks: #{blocks.size} sites; #{rproc.size} build an RProc (BLOCK_FALLBACK); the analysis confines " \
       "#{rproc.count { |r| r[6] == 'confined' }} of those and #{blocks.count { |r| r[6] == 'confined' }} of all"
  puts '   by callee (RProc sites / confined of them / all sites):'
  blocks.group_by { |r| r[5] }.sort_by { |_, v| -v.size }.first(25).each do |callee, list|
    r = list.select { |x| x[9] == 'rproc' }
    puts format('     %-34s %4d %4d %4d', callee, r.size, r.count { |x| x[6] == 'confined' }, list.size)
  end
  exact = rproc.reject { |r| r[10].to_s == '-' }
  puts "   RProc sites whose receiver class the class flow names: #{exact.size}, confined: #{exact.count { |r| r[6] == 'confined' }}"
end

def containers(sites)
  %w[array hash string object].each do |k|
    list = sites.select { |r| kind(r) == k }
    puts "-- #{k}: #{list.size} sites, #{list.count { |r| r[6] == 'confined' }} used only locally (stack-allocation candidates, count only)"
  end
end

# The `ivars` rows (tools/bc2cpp/escape_immediate_ivars.rb): confined `new` sites by whether every ivar store that
# can reach the object is provably immediate. Reasons are grouped with the labels and counts taken out.
def ivar_table(ivars, title)
  immediate = ivars.count { |r| r[7] == 'immediate' }
  puts "-- #{title}: #{ivars.size} confined object sites; immediate-only ivars: #{immediate}; " \
       "not immediate (a heap store or unenumerated): #{ivars.size - immediate}"
  why = ivars.reject { |r| r[7] == 'immediate' }.map { |r| r[8].gsub(/\S*:\d+\)?/, '').squeeze(' ').strip }
  why.tally.sort_by { |_, n| -n }.first(12).each { |reason, n| puts format('     %6d  %s', n, reason) }
end

table(all_sites, 'every irep of the closed world')
puts
puts '-- why sites escape (kind, reason), top 24 --'
all_sites.select { |r| r[6] == 'escapes' }.group_by { |r| [kind(r), r[7]] }.sort_by { |_, v| -v.size }.first(24).each do |(k, why), list|
  puts format('%6d  %-8s %s', list.size, k, why)
end
puts
lambdas_and_blocks(all_sites)
containers(all_sites)
ivar_table(ivars, 'object ivars, every irep')

if shipped
  in_shipped = all_sites.select { |r| shipped.include?(r[2]) }
  puts
  puts "=== methods that ship (#{shipped.size} compiled entry points) ==="
  table(in_shipped, 'shipped methods')
  lambdas_and_blocks(in_shipped)
  containers(in_shipped)
  ivar_table(ivars.select { |r| shipped.include?(r[2]) }, 'object ivars, shipped methods')
end

puts
puts "-- constructors (`initialize` definitions): #{selves.size}; self does not escape: " \
     "#{selves.count { |r| r[6] == 'confined' }}; escapes: #{selves.count { |r| r[6] == 'escapes' }}"
puts "-- sites that make the callee world unknowable (dynamic): #{rows.count { |r| r[0] == 'dynamic' }}; " \
     "frame/heap reflection (binding, eval, ObjectSpace): #{rows.count { |r| r[0] == 'reflective' }}"
