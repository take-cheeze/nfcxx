#!/usr/bin/env ruby
# encoding: UTF-8
# frozen_string_literal: true

# Per-point may-hold sets of the escape analysis (tools/bc2cpp/escape_analysis.rb, Verdict#holding_at). With
# BC2CPP_ESCAPE_POINTS=1 the escape report gives a `point` row per instruction of each creation site's method:
# the registers that may hold the creation's value on entry to that instruction. This checks the sets on fixtures
# whose aliasing is known, so later codegen can rely on them to rewrite exactly the registers that hold the value:
#   - the creation's own instruction does not hold the value on entry (it is not made yet);
#   - a plain local holds it at the return;
#   - a copy adds a second register that holds it;
#   - a value copied on one branch only is held by both registers at the merge;
#   - a value that escapes gives no complete sets (`escaped`), since the flow stopped at the escape.
#
# Needs host mrbc (MRBC or on PATH). Usage: MRBC=path/to/mrbc ruby scripts/bc2cpp/escape_points_check.rb

require 'tmpdir'
require 'fileutils'
require_relative 'fixture_runtime'

ENV['BC2CPP_SIG_DIRS'] ||= ''

failures = []
check = lambda do |what, condition|
  puts "  #{condition ? 'ok  ' : 'FAIL'} #{what}"
  failures << what unless condition
end

unless Bc2cppFixtureRuntime.mrbc && system(Bc2cppFixtureRuntime.mrbc, '--version', out: File::NULL, err: File::NULL)
  puts '  SKIP: no host mrbc (set MRBC); the escape points need it'
  exit 0
end

POINTS_SRC = <<~'RUBY'
  class PT
    def straight; a = [1, 2]; a.size; end
    def alias_copy; a = [1, 2]; b = a; b.size; end
    def branch(c); a = [1, 2]; if c; b = a; end; a.size; end
    def escapes; @k = [1, 2]; nil; end
  end
RUBY

# [site row, point rows] of the array creation in method +name+ of owner PT.
def site_points(rows, name)
  site = rows.find { |r| r[0] == 'site' && r[2] == "PT##{name}" && r[5] == 'array' }
  return [nil, []] unless site

  [site, rows.select { |r| r[0] == 'point' && r[1] == site[1] }]
end

# The registers listed at the last instruction with op +op+ (the return), as integers; nil without such a row.
def held_at(points, op)
  row = points.select { |r| r[3] == op }.max_by { |r| r[2].to_i }
  return nil unless row

  row[4].to_s.split(',').map(&:to_i)
end

puts '-- escape points (generation)'
dir = Dir.mktmpdir('bc2cpp-escape-points')
begin
  tsv = File.join(dir, 'escape.tsv')
  saved = ENV.fetch('BC2CPP_ESCAPE_REPORT', nil)
  saved_points = ENV.fetch('BC2CPP_ESCAPE_POINTS', nil)
  ENV['BC2CPP_ESCAPE_REPORT'] = tsv
  ENV['BC2CPP_ESCAPE_POINTS'] = '1'
  begin
    Bc2cppFixtureRuntime.generate(POINTS_SRC, dir, core: true, only_owners: %w[PT])
  ensure
    saved.nil? ? ENV.delete('BC2CPP_ESCAPE_REPORT') : ENV['BC2CPP_ESCAPE_REPORT'] = saved
    saved_points.nil? ? ENV.delete('BC2CPP_ESCAPE_POINTS') : ENV['BC2CPP_ESCAPE_POINTS'] = saved_points
  end
  rows = File.readlines(tsv, chomp: true).map { |line| line.split("\t", -1) }

  site, points = site_points(rows, 'straight')
  creation_index = site && site[1].split(':').last.to_i
  at_return = held_at(points, 'RETURN')
  check.call('straight: the value is held by exactly one register at the return', at_return && at_return.size == 1)
  creation_row = points.find { |r| r[2].to_i == creation_index }
  check.call('straight: the creation instruction does not hold the value on entry',
             creation_row && at_return && !creation_row[4].to_s.split(',').map(&:to_i).include?(at_return.first))

  _, points = site_points(rows, 'alias_copy')
  at_return = held_at(points, 'RETURN')
  check.call('alias_copy: a copy adds a second register that holds the value at the return',
             at_return && at_return.size >= 2)

  _, points = site_points(rows, 'branch')
  at_return = held_at(points, 'RETURN')
  check.call('branch: a copy made on one branch is held by both registers at the merge',
             at_return && at_return.size >= 2)

  site, points = site_points(rows, 'escapes')
  check.call('escapes: the site is reported as escaped, with no complete sets',
             site && !points.empty? && points.all? { |r| r[4] == 'escaped' })
ensure
  FileUtils.remove_entry(dir)
end

if failures.empty?
  puts 'bc2cpp escape points check: PASS'
else
  warn "bc2cpp escape points check: #{failures.size} failure(s)"
  exit 1
end
