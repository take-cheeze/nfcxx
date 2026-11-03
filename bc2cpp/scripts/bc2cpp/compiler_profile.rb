#!/usr/bin/env ruby
# frozen_string_literal: true

require 'fileutils'
require 'json'
require 'optparse'
require 'tmpdir'

options = { mode: 'none' }
parser = OptionParser.new do |opts|
  opts.banner = 'Usage: compiler_profile.rb --out PREFIX [--mode MODE] [--optcarrot | -- COMPILER_ARGS]'
  opts.on('--out PREFIX', 'Metrics and optional StackProf output prefix') { |value| options[:out] = File.expand_path(value) }
  opts.on('--mode MODE', %w[none object cpu wall], 'none (default), object, cpu, wall; profiling requires stackprof') { |value| options[:mode] = value }
  opts.on('--optcarrot', 'Prepare the sealed Optcarrot compiler workload') { options[:optcarrot] = true }
end
parser.parse!(ARGV)
abort parser.to_s unless options[:out] && (options[:optcarrot] ? ARGV.empty? : !ARGV.empty?)
require 'stackprof' unless options[:mode] == 'none'

root = File.expand_path('../..', __dir__)
compiler = File.join(root, 'tools/bc2cpp/bc2cpp.rb')
FileUtils.mkdir_p(File.dirname(options[:out]))
run = lambda do
  $0 = compiler
  before = GC.stat
  cpu_before = Process.times
  started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  completed = false
  begin
    if options[:mode] == 'none'
      load compiler
    else
      StackProf.run(mode: options[:mode].to_sym, interval: options[:mode] == 'object' ? 100 : 1000,
                    out: "#{options[:out]}.stackprof") { load compiler }
    end
    completed = true
  ensure
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
    after = GC.stat
    cpu_after = Process.times
    metrics = {
      completed: completed, ruby: RUBY_DESCRIPTION, mode: options[:mode], elapsed_seconds: elapsed,
      cpu_seconds: cpu_after.utime + cpu_after.stime - cpu_before.utime - cpu_before.stime,
      allocated_objects: after[:total_allocated_objects] - before[:total_allocated_objects],
      gc_count: after[:count] - before[:count], gc_milliseconds: after[:time] - before[:time]
    }
    # VmHWM is the whole process high-water mark, including workload preparation and the profiler.
    if File.file?('/proc/self/status')
      peak = File.read('/proc/self/status')[/^VmHWM:\s+(\d+) kB$/, 1]
      metrics[:process_peak_rss_kib] = peak.to_i if peak
    end
    File.write("#{options[:out]}.metrics.json", JSON.pretty_generate(metrics) + "\n")
  end
end

if options[:optcarrot]
  require_relative '../../tools/bc2cpp/compiled_gems'
  require_relative '../../tools/optcarrot_probe/sealed_build'
  Dir.mktmpdir('bc2cpp-compiler-profile-') do |temp|
    sources, environment = OptcarrotSealedBuild.bc2cpp_world(root, temp)
    environment.each { |name, value| ENV[name] = value }
    ENV['OUT_SYMBOL'] = 'compiler_profile'
    ENV['OUT_DIR'] = temp
    ARGV.replace(sources)
    run.call
  end
else
  run.call
end
