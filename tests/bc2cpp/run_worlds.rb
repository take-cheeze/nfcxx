#!/usr/bin/env ruby
# frozen_string_literal: true

# Runs bc2cpp worlds (tests/bc2cpp/run_<world>.sh) one after another in one process tree, so a CI job pays for the checkout, Ruby
# and the build tools once for several worlds instead of once per world (.github/workflows/bc2cpp.yml shards the list).
#
#   ruby tests/bc2cpp/run_worlds.rb [--shard N/M] [--list FILE] [--print] [WORLD...]
#     --shard N/M  run shard N of M (0-based): the worlds of tests/bc2cpp/worlds.list balanced by their weights (the heaviest
#                  first, each to the lightest shard so far), so a world's shard depends only on the list
#     --list FILE  the worlds list (default tests/bc2cpp/worlds.list: `<world> <weight> [<mrbc_rb mode>]` per line)
#     --print      print the selected worlds, one per line, and run nothing
#     WORLD...     run these worlds (in the order given) instead of a shard
#   Environment: BC2CPP_MRBC_RB_OVERRIDE replaces every world's mrbc_rb mode (a workflow dispatch's input; `record` means verify
#   plus recording); BC2CPP_MRBC_RECORD_DIR is the directory the per-world snapshot records go to when the override is `record`.
#
# Every world runs even after one fails; the exit status is 1 when any failed. A world's `SKIP` line (a missing tool) is a pass
# here as it is for run_<world>.sh. The build directories the script-world kind leaves in the world's mruby build are removed
# before each world: two worlds in one checkout share them, and a stale one from the previous world fails the next one.
require 'optparse'
require 'fileutils'

ROOT = File.expand_path('../..', __dir__)
WORLD_BUILD = File.join(ROOT, 'build/bc2cpp/rpg-maker-clone/3rd/mruby/build')
STALE_DIRS = %w[scriptcompiled scriptinterpreted].freeze

options = { list: File.join(ROOT, 'tests/bc2cpp/worlds.list') }
OptionParser.new do |o|
  o.on('--shard N/M') { |v| options[:shard] = v }
  o.on('--list FILE') { |v| options[:list] = v }
  o.on('--print') { options[:print] = true }
end.parse!

# World => [weight, mode].
def read_list(path)
  File.readlines(path, chomp: true).filter_map do |line|
    line = line.sub(/#.*/, '').strip
    next if line.empty?

    world, weight, mode = line.split
    abort "#{path}: bad line #{line.inspect} (want: world weight [mode])" unless world && weight =~ /\A\d+\z/
    [world, [weight.to_i, mode]]
  end.to_h
end

def shard_of(list, n, m)
  abort "bad shard #{n}/#{m}" unless m.positive? && (0...m).cover?(n)

  loads = Array.new(m, 0)
  assigned = Array.new(m) { [] }
  list.each_with_index.sort_by { |(_, (weight, _)), i| [-weight, i] }.each do |(world, (weight, _)), _i|
    k = loads.each_with_index.min_by { |load, idx| [load, idx] }.last
    loads[k] += weight
    assigned[k] << world
  end
  # Back in list order, so the log reads like the list.
  assigned[n].sort_by { |w| list.keys.index(w) }
end

list = read_list(options[:list])
worlds =
  if ARGV.any?
    ARGV.each { |w| abort "#{w}: not in #{options[:list]}" unless list.key?(w) }
    ARGV.dup
  elsif options[:shard]
    n, m = options[:shard].split('/', 2).map { |x| Integer(x) }
    shard_of(list, n, m)
  else
    list.keys
  end

if options[:print]
  puts worlds
  exit 0
end

override = ENV['BC2CPP_MRBC_RB_OVERRIDE'].to_s
record_dir = ENV['BC2CPP_MRBC_RECORD_DIR'].to_s
results = []
worlds.each do |world|
  script = File.join(ROOT, "tests/bc2cpp/run_#{world}.sh")
  unless File.exist?(script)
    results << [world, :missing, 0.0]
    puts "::error::#{world}: #{script} does not exist"
    next
  end

  STALE_DIRS.each { |d| FileUtils.rm_rf(File.join(WORLD_BUILD, d)) }
  mode = override.empty? ? (list[world][1] || 'verify') : override
  env = {}
  env['BC2CPP_MRBC_RB'] = mode == 'record' ? 'verify' : mode if mode
  env['BC2CPP_MRBC_SNAPSHOT_RECORD'] = File.join(record_dir, "mrbc-record-#{world}.txt") if mode == 'record' && !record_dir.empty?

  puts "::group::bc2cpp world #{world}#{" (mrbc_rb #{mode})" if mode}"
  $stdout.flush
  started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  ok = system(env, script, chdir: ROOT)
  seconds = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
  puts '::endgroup::'
  puts "::error::bc2cpp world #{world} failed (see its group above)" unless ok
  results << [world, ok ? :pass : :fail, seconds]
  $stdout.flush
end

puts "\nbc2cpp worlds#{" (shard #{options[:shard]})" if options[:shard]}:"
results.each { |world, status, seconds| puts format('  %-5s %-26s %6.1f min', status.to_s.upcase, world, seconds / 60.0) }
failed = results.reject { |_, status, _| status == :pass }
puts "#{results.size - failed.size}/#{results.size} passed"
exit(failed.empty? ? 0 : 1)
