#!/usr/bin/env ruby
# frozen_string_literal: true

# Duplicate definitions over a closed world's Ruby sources, from the Ruby emitter's class-scope annotations
# (tools/mrbc_rb/annotations.rb; no bytecode dataflow): methods defined more than once in the same lexical owner (the later
# definition wins), constants assigned more than once, classes/modules reopened (across files or within one), and methods whose
# bodies are identical (a fingerprint of the def's parameters and body Prism subtree with locations stripped).
# Read-only. Needs no mrbc: the emitter compiles the sources.
#
# Usage: ruby scripts/bc2cpp/duplicate_definitions_report.rb [--all] [--sample=N] [FILE.rb ...]
# Without files: the closed world's mrblib sources (BC2CPP_WORLD_ROOT; closed_world_mrblib_srcs, as the closed-world probe passes
# them), compiled as one program in load order. --all lists every group, --sample=N (default 8) the first N.
require_relative '../../tools/bc2cpp/world_root'
require_relative '../../tools/mrbc_rb/mrbc_rb'

args = ARGV.dup
all = args.delete('--all')
sample = (args.find { |a| a.start_with?('--sample=') } || '--sample=8').split('=').last.to_i
files = args
if files.empty?
  require_relative '../../tools/bc2cpp/closed_world_env'
  files = closed_world_mrblib_srcs(BC2CPP_WORLD_ROOT, core_gems: BC2CPP_CORE_MRBLIB_GEMS + BC2CPP_EXTERNAL_MRBLIB_GEMS, tts: false)
end

# [annotations records, skipped] of +files+ compiled as one program, or file by file when the emitter does not cover the set.
def collect(files)
  begin
    return [[MrbcRb.compile_files_result(files.map { |f| [File.binread(f), f] }).annotations], []]
  rescue MrbcRb::Error, StandardError
    nil
  end
  skipped = []
  recs = files.filter_map do |f|
    MrbcRb.compile_result(File.binread(f), f).annotations
  rescue MrbcRb::Error, StandardError => e
    skipped << "#{f}: #{e.message[0, 80]}"
    nil
  end
  [recs, skipped]
end

tables, skipped = collect(files)
order = files.each_with_index.to_h
ops = []
tables.each do |t|
  t[:ireps].each { |rec| rec[:ops].each { |pc, op| ops << op.merge(irep: rec[:index], pc: pc) } }
end
# Program order: file in load order, then line (an irep's ops share the compile order within a file).
ops.sort_by! { |o| [order.fetch(o[:file], 1 << 30), o[:line] || 0, o[:irep], o[:pc]] }
where = ->(o) { "#{o[:file].to_s.sub(%r{\A.*/(?=[^/]+/mrblib/|mruby-)}, '')}:#{o[:line]}" }
shown = ->(list) { all ? list : list.first(sample) }

defs = ops.select { |o| %i[TDEF SDEF DEF].include?(o[:op]) }
resolved, dynamic = defs.partition { |d| d[:owner_path] }
puts "sources: #{files.size} file(s)#{skipped.empty? ? '' : ", #{skipped.size} not covered by the emitter (skipped)"}; " \
     "#{defs.size} def(s): #{resolved.size} with a static owner, #{dynamic.size} owner-dynamic (block/singleton/dynamic receiver: not keyed)"
skipped.first(5).each { |s| puts "  skipped #{s}" }

# 1. a method defined more than once in the same lexical owner
by_method = resolved.group_by { |d| [d[:owner_path], d[:singleton], d[:name]] }.select { |_, v| v.size > 1 }
cross = by_method.select { |_, v| v.map { |d| d[:file] }.uniq.size > 1 }
puts "\n1. methods defined more than once in one owner (later wins): #{by_method.size} method(s), #{by_method.values.sum { |v| v.size - 1 }} shadowed def(s); #{cross.size} across files"
shown.call(by_method.sort_by { |_, v| -v.size }).each do |(owner, singleton, name), v|
  puts "   #{owner}#{singleton ? '.' : '#'}#{name} x#{v.size}: #{v.map(&where).join(' -> ')}"
end

# 2. constants assigned more than once
sets = ops.select { |o| o[:op] == :SETCONST && o[:scope_path] }.group_by { |o| [o[:scope_path], o[:name]] }.select { |_, v| v.size > 1 }
msets = ops.select { |o| o[:op] == :SETMCNST && o[:base] }.group_by { |o| [o[:base], o[:name]] }.select { |_, v| v.size > 1 }
puts "\n2. constants assigned more than once: #{sets.size} (lexical `X = v`), #{msets.size} (`A::X = v`)"
shown.call(sets.to_a + msets.to_a).each { |(scope, name), v| puts "   #{scope}::#{name} x#{v.size}: #{v.map(&where).join(' -> ')}" }

# 3. classes and modules reopened
openers = ops.select { |o| %i[CLASS MODULE].include?(o[:op]) && o[:path] }.group_by { |o| o[:path] }
reopened = openers.select { |_, v| v.size > 1 }
across = reopened.select { |_, v| v.map { |o| o[:file] }.uniq.size > 1 }
unresolved = ops.count { |o| %i[CLASS MODULE].include?(o[:op]) && o[:path].nil? }
puts "\n3. classes/modules opened more than once: #{reopened.size} of #{openers.size} (#{across.size} across files, #{reopened.values.sum { |v| v.size - 1 }} reopenings); #{unresolved} opener(s) with no static path"
shown.call(across.sort_by { |_, v| -v.size }).each { |path, v| puts "   #{path} x#{v.size}: #{v.map { |o| File.basename(o[:file]) }.uniq.join(', ')}" }
supers = reopened.select { |_, v| v.map { |o| o.dig(:superclass, :text) }.compact.uniq.size > 1 }
puts "   reopened with differing explicit superclass text: #{supers.size}" unless supers.empty?

# 4. identical bodies
trivial = ->(d) { d[:fingerprint].nil? }
bodies = defs.reject(&trivial).group_by { |d| d[:fingerprint] }.select { |_, v| v.size > 1 }
same_name = bodies.select { |_, v| v.map { |d| d[:name] }.uniq.size == 1 }
cross_owner = bodies.select { |_, v| v.map { |d| d[:owner_path] }.uniq.size > 1 }
puts "\n4. identical-body methods: #{bodies.size} group(s), #{bodies.values.sum { |v| v.size - 1 }} redundant def(s); #{same_name.size} with one name (shared implementation), #{cross_owner.size} across owners"
shown.call(bodies.sort_by { |_, v| -v.size }).each do |_, v|
  puts "   x#{v.size}: #{v.map { |d| "#{d[:owner_path] || '?'}#{d[:singleton] ? '.' : '#'}#{d[:name]}" }.uniq.first(6).join(', ')} (#{where.call(v.first)})"
end
