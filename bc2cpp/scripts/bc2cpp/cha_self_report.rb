#!/usr/bin/env ruby
# frozen_string_literal: true

# Aggregates the CHA_SELF site report: how many self-receiver
# sends a build has, by the construct compile_send chose and by what class
# hierarchy analysis says about each, and by method name.
#
# Usage:
#   BC2CPP_CHA_REPORT=report.tsv <the usual bc2cpp.rb closed-world command> > code.cpp
#   ruby scripts/bc2cpp/cha_self_report.rb report.tsv [code.cpp]
#
# With the generated code, only sites in methods that made it into the output
# (a SKIP_UNSUPPORTED build drops the rest) are counted.

report, code = ARGV
abort "usage: #{$PROGRAM_NAME} REPORT.tsv [CODE.cpp]" unless report

emitted = code && File.foreach(code).filter_map { |l| l[/\(compiled from irep (\d+),/, 1] }.to_set(&:to_i)
rows = File.readlines(report, chomp: true).reject(&:empty?).map do |line|
  label, addr, name, owner, construct, dispatches, plan, detail, method_irep = line.split("\t", -1)
  { label: label.to_i, addr: addr.to_i, name: name, owner: owner, construct: construct,
    dispatches: dispatches.to_i, plan: plan, detail: detail, method_irep: method_irep.to_i }
end
rows.select! { |r| emitted.include?(r[:method_irep]) } if emitted

eligible = ->(r) { %w[direct arms].include?(r[:plan]) }
puts "self-receiver sends: #{rows.size} (#{rows.count { |r| r[:dispatches].positive? }} still dispatch dynamically)"
puts "eligible for CHA_SELF: #{rows.count(&eligible)} (direct #{rows.count { |r| r[:plan] == 'direct' }}, " \
     "exact-class arms #{rows.count { |r| r[:plan] == 'arms' }})"
puts "eligible and dispatching today: #{rows.count { |r| eligible.call(r) && r[:dispatches].positive? }}"
puts
puts 'by construct (total / eligible / dispatching / eligible+dispatching):'
rows.group_by { |r| r[:construct] }.sort_by { |_, rs| -rs.size }.each do |construct, rs|
  puts format('  %-30s %5d %5d %5d %5d', construct, rs.size, rs.count(&eligible),
              rs.count { |r| r[:dispatches].positive? }, rs.count { |r| eligible.call(r) && r[:dispatches].positive? })
end
puts
puts 'by plan / refusal:'
rows.group_by { |r| r[:plan] }.sort_by { |_, rs| -rs.size }.each { |plan, rs| puts format('  %-22s %5d', plan, rs.size) }
puts
puts 'eligible by name (top 25):'
rows.select(&eligible).group_by { |r| r[:name] }.sort_by { |n, rs| [-rs.size, n] }.first(25).each do |name, rs|
  puts format('  %4d  :%s', rs.size, name)
end
puts
puts 'eligible dispatching sites by name (top 25):'
rows.select { |r| eligible.call(r) && r[:dispatches].positive? }.group_by { |r| r[:name] }
    .sort_by { |n, rs| [-rs.size, n] }.first(25).each { |name, rs| puts format('  %4d  :%s', rs.size, name) }
