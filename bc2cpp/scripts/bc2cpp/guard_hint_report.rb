#!/usr/bin/env ruby
# frozen_string_literal: true

# Aggregate the BC2CPP_GUARD_HINT_REPORT TSV (tools/bc2cpp/guard_hint_report.rb, ADR 0295):
# how many sites of each hint-based guard family end in a nomethod, a kept dispatch or no else,
# and where the receiver register came from.
#
#   BC2CPP_GUARD_HINT_REPORT=hints.tsv <the usual bc2cpp.rb closed-world command> > code.cpp
#   ruby scripts/bc2cpp/guard_hint_report.rb hints.tsv

path = ARGV.fetch(0) { abort 'usage: bc2cpp_guard_hint_report.rb hints.tsv' }
rows = File.readlines(path, chomp: true).map { |line| line.split("\t") }
by_arm = Hash.new(0)
by_origin = Hash.new(0)
rows.each do |_label, _idx, _name, family, else_arm, origin|
  by_arm[[family, else_arm]] += 1
  by_origin[[family, else_arm, origin]] += 1 unless else_arm == 'nomethod'
end
puts "#{rows.size} sites"
puts '-- family x else arm --'
by_arm.sort.each { |(family, arm), n| puts format('%-26<f>s %-34<a>s %5<n>d', f: family, a: arm, n: n) }
puts '-- family x else arm x receiver origin (nomethod arms omitted) --'
by_origin.sort_by { |key, n| [key[0], key[1], -n] }.each do |(family, arm, origin), n|
  puts format('%-26<f>s %-34<a>s %-30<o>s %5<n>d', f: family, a: arm, o: origin, n: n)
end
