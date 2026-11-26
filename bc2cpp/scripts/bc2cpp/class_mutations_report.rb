#!/usr/bin/env ruby
# frozen_string_literal: true

# CLASS_MUTATIONS: what the runs of a host sweep changed in the classes the boot left (trace_host's
# BC2CPP_HOST_CLASS_MUTATIONS=DIR, scripts/bc2cpp/class_mutations.hxx). A class nothing changes after the boot is one
# whose object and tables could be built in flash; the rest is listed with what changed in it.
#
#   BC2CPP_HOST_CLASS_MUTATIONS=DIR scripts/bc2cpp/host_sweep.bash BUILD_DIR
#   ruby scripts/bc2cpp/class_mutations_report.rb DIR [--expect FILE]
#
# --expect FILE: fails on a change FILE does not list (one `kind<TAB>class<TAB>name` line each, `#` comments), and on a
# listed one no run made. Kinds: new (a class made after the boot), super (an include or prepend), mt (a method-table
# layer added or grown), iv_add / iv_set / iv_del (a class-level instance variable or constant).
require 'optparse'

expect = nil
OptionParser.new { |o| o.on('--expect FILE') { |v| expect = v } }.parse!
dir = ARGV.fetch(0) { abort 'usage: class_mutations_report.rb DIR [--expect FILE]' }
files = Dir[File.join(dir, '*.tsv')]
abort "class_mutations: no reports in #{dir}" if files.empty?

runs = files.size
boot = Hash.new(0)
seen = Hash.new(0)
object_sclasses = 0
files.each do |f|
  File.foreach(f) do |line|
    kind, cls, what = line.chomp.split("\t", 3)
    case kind
    when 'boot_classes' then boot[cls.to_i] += 1
    when 'object_singleton_classes' then object_sclasses += cls.to_i
    else seen[[kind, cls, what.to_s.sub(/\A\d+->\d+ layers\z/, '')]] += 1
    end
  end
end

puts format('class_mutations: %d runs, %s classes at boot, %d singleton classes of ordinary objects made',
            runs, boot.keys.sort.join('/'), object_sclasses)
by_class = seen.keys.group_by { |_, cls, _| cls }
puts format('%d of the boot classes changed after it:', by_class.size)
by_class.sort.each do |cls, keys|
  puts "  #{cls}: " + keys.sort.map { |k, _, what| "#{k} #{what}".strip + (seen[[k, cls, what]] < runs ? " (#{seen[[k, cls, what]]} runs)" : '') }.join(', ')
end
exit 0 unless expect

allowed = File.readlines(expect, chomp: true).reject { |l| l.strip.empty? || l.start_with?('#') }.map { |l| l.split("\t", 3) }
allowed.each { |a| a[2] = a[2].to_s }
unexpected = seen.keys - allowed
stale = allowed - seen.keys
unexpected.sort.each { |k| warn "class_mutations: unexpected #{k.join(' ')}" }
stale.sort.each { |k| warn "class_mutations: #{k.join(' ')} is expected but no run made it" }
exit(unexpected.empty? && stale.empty? ? 0 : 1)
