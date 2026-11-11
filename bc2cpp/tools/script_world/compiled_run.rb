#!/usr/bin/env ruby
# frozen_string_literal: true

# One mruby script as a bc2cpp closed world (the script-world build kind; docs/notes/bc2cpp-migration.md, "Adding a
# world"): builds the script as an interpreted mruby program and as a sealed executable bc2cpp compiled to C++ on the
# pinned world's mruby fork, checks that the two give the same stdout, stderr and exit status over every case, and
# times both (and CRuby) on the benchmark arguments.
#
#   ruby compiled_run.rb --script SCRIPT --tail TEXT --entry EXPR --cases FILE --bench ARGS [--bench ARGS ...]
#     --script   the script (it must end with --tail)
#     --tail     the script's final statements; they become the body of ScriptWorld.run, with --entry in their place
#     --entry    the expression that runs it and gives the exit status (e.g. main(ARGV))
#     --cases    a file of command lines, one case each (shell words; blank lines and # lines are skipped). A line
#                starting with `!` is an uncaught-exception case: stdout and the exit status must match and stderr must
#                match without its backtrace (compiled code has no line table, so mruby prints (unknown):0 there)
#     --bench    arguments of a timed run (repeatable); --repeat N runs each N times (default 3) and keeps the best;
#                --bench-status N is the exit status a timed run must give (default 0)
#   The roots: BC2CPP_TREE_ROOT (this tree) and BC2CPP_WORLD_ROOT (the world with the mruby fork), as for the
#   optcarrot probe. SCRIPT_WORLD_COMPILED_FLAGS adds compiler flags to the compiled build.
require_relative '../bc2cpp/world_root'
require 'etc'
require 'fileutils'
require 'open3'
require 'optparse'
require 'rbconfig'
require 'shellwords'
require 'tmpdir'

options = { bench: [], repeat: 3, bench_status: 0 }
OptionParser.new do |o|
  o.on('--script PATH') { |v| options[:script] = File.expand_path(v) }
  o.on('--tail TEXT') { |v| options[:tail] = v }
  o.on('--entry EXPR') { |v| options[:entry] = v }
  o.on('--cases FILE') { |v| options[:cases] = File.expand_path(v) }
  o.on('--bench ARGS') { |v| options[:bench] << v }
  o.on('--repeat N', Integer) { |v| options[:repeat] = v }
  o.on('--bench-status N', Integer) { |v| options[:bench_status] = v }
  o.on('--chdir DIR') { |v| options[:chdir] = File.expand_path(v) }
end.parse!
%i[script tail entry cases].each { |key| abort "--#{key} is required" unless options[key] }
options[:tail] = options[:tail].gsub('\n', "\n")

ROOT = BC2CPP_WORLD_ROOT
MRUBY = File.join(ROOT, '3rd/mruby')
MRBC = ENV['MRBC'] || File.join(MRUBY, 'bin/mrbc')
abort "#{MRBC} is missing -- build the probe mrbc first" unless File.executable?(MRBC)
GRAY_STACK_SIZE = 16_384

require File.join(BC2CPP_TREE_ROOT, 'tools/bc2cpp/compiled_gems')
require File.join(BC2CPP_TREE_ROOT, 'tools/bc2cpp/shard_output')
require File.join(BC2CPP_TREE_ROOT, 'tools/optcarrot_probe/register_emit')
require_relative 'sealed_build'

extend OptcarrotRegister
SHARDS = ShardOutput.count(ENV.to_h.merge('BC2CPP_SHARDS' => ENV.fetch('BC2CPP_SHARDS', '4')))

def run_bc2cpp(sources, env)
  command = [RbConfig.ruby, File.join(BC2CPP_TREE_ROOT, 'tools/bc2cpp/bc2cpp.rb'), '--annotated', *sources]
  stdout, stderr, status = Open3.capture3(env, *command)
  raise "bc2cpp failed (#{status.exitstatus}):\n#{stderr[-4000..] || stderr}" unless status.success?

  [stdout, stderr]
end

def build_compiled(options, temp)
  scan_dir = File.join(temp, 'scan')
  output_dir = File.join(temp, 'gem', 'src')
  generated_dir = File.join(temp, 'gem', 'generated')
  gem_dir = File.join(temp, 'gem')
  FileUtils.mkdir_p([scan_dir, output_dir, generated_dir])
  program, gems = ScriptSealedBuild.prepare(ROOT, temp, gem_dir, script: options[:script], tail: options[:tail],
                                                                  entry: options[:entry])
  native, foreign = bc2cpp_closed_world_outside_srcs('script-world', gems, ROOT)
  core_sources = core_compiled_mrblib_srcs(ROOT, gems.keys).map { |path| File.expand_path(path) }
  foreign -= core_sources
  env = {
    'MRBC' => MRBC, 'OUT_SYMBOL' => 'script_world', 'NATIVE_SRCS' => Shellwords.join(native),
    'FOREIGN_RUBY_SRCS' => Shellwords.join(foreign), 'SKIP_UNSUPPORTED' => '1', 'BC2CPP_SELF_REGISTERING' => '1',
    'BC2CPP_SIG_DIRS' => '', 'BC2CPP_SHARDS' => SHARDS.to_s
  }.merge(ScriptSealedBuild.environment(gems))
  sources = core_sources + [program]
  _cpp, scan = run_bc2cpp(sources, env.merge('OUT_DIR' => scan_dir))
  lines = scan.lines
  header = lines.index { |line| line.start_with?('== closed world (') }
  puts lines[header, 2] if header
  puts lines.grep(/\A== closed world (fallbacks|guard violations|nil receivers|nomethod sites|proven-class miss sites)/)
  owners = section_lines(scan, 'compiled entry points').filter_map { |line| line[/\(([^#]+)#/, 1] }.uniq
  owners |= BC2CPP_CORE_OWNERS
  cpp, diagnostics = run_bc2cpp(sources, env.merge('OUT_DIR' => temp, 'ONLY_OWNERS' => owners.join(',')))
  File.write(File.join(generated_dir, 'script_world_gen.cpp'), cpp)
  FileUtils.cp(File.join(temp, 'script_world_decls.h'), generated_dir)
  (1...SHARDS).each { |k| FileUtils.cp(ShardOutput.shard_path(temp, 'script_world', k), output_dir) }
  count = emit_register(diagnostics, output_dir, symbol: 'script_world', gem: 'script_compiled',
                                                 mod: ScriptSealedBuild::PROBE)
  File.write(File.join(gem_dir, 'mrbgem.rake'), <<~RUBY)
    MRuby::Gem::Specification.new('script-compiled') do |spec|
      spec.license = 'MIT'
      spec.authors = 'script world'
      spec.add_dependency 'mruby-io'
      spec.cxx.include_paths << #{File.join(ROOT, 'include').dump}
      spec.cxx.include_paths << #{generated_dir.dump}
    end
  RUBY
  [gems, count, diagnostics]
end

def mruby_config(temp, gems, flags)
  compiled_gems = gems.reject { |name, _| name.start_with?('script-') }.values.map { |dir| "gem #{dir.dump}" }
  config = File.join(temp, 'mruby_build_config.rb')
  File.write(config, <<~RUBY)
    base = proc do
      toolchain
      gembox 'full-core'
      cc.defines << 'MRB_ARY_LENGTH_MAX=0' << 'MRB_GRAY_STACK_SIZE=#{GRAY_STACK_SIZE}'
      cxx.defines << 'MRB_ARY_LENGTH_MAX=0' << 'MRB_GRAY_STACK_SIZE=#{GRAY_STACK_SIZE}'
    end
    MRuby::Build.new('host') { toolchain }
    MRuby::Build.new('scriptinterpreted') { instance_eval(&base) }
    MRuby::Build.new('scriptcompiled') do
      toolchain
      self.mrbcfile = #{File.expand_path(MRBC).dump}
      #{compiled_gems.join("\n      ")}
      cc.defines << 'MRB_ARY_LENGTH_MAX=0' << 'MRB_GRAY_STACK_SIZE=#{GRAY_STACK_SIZE}'
      cxx.defines << 'MRB_ARY_LENGTH_MAX=0' << 'MRB_GRAY_STACK_SIZE=#{GRAY_STACK_SIZE}'
      #{flags.empty? ? '' : "[cc, cxx, linker].each { |tool| tool.flags << #{flags.inspect} }"}
      enable_cxx_exception
      gem #{File.join(temp, 'gem').dump}
      gem #{gems.fetch('script-benchmark').dump}
    end
    task :verify_script_world do
      actual = MRuby.targets.fetch('scriptcompiled').gems.to_h { |g| [g.name, File.expand_path(g.dir)] }
      expected = #{gems.inspect}
      raise "sealed gem manifest differs: \#{(actual.to_a - expected.to_a)} / \#{(expected.to_a - actual.to_a)}" unless actual == expected
    end
    task :link_script => :all do
      build = MRuby.targets.fetch('scriptcompiled')
      build.linker.run File.join(build.build_dir, 'bin/script'), build.libraries, *build.gems.linker_attrs
    end
  RUBY
  config
end

def run_case(command, chdir)
  stdout, stderr, status = Open3.capture3(*command, stdin_data: '', binmode: true, chdir: chdir)
  [stdout, stderr, status.exitstatus || "signal #{status.termsig}"]
end

# [args, uncaught?] per case line.
def shell_cases(path)
  File.readlines(path, chomp: true).reject { |l| l.strip.empty? || l.start_with?('#') }.map do |line|
    uncaught = line.start_with?('!')
    [Shellwords.split(uncaught ? line[1..] : line), uncaught]
  end
end

# An uncaught exception's report without the backtrace: no "trace" block, and the location prefix of the message dropped.
def without_backtrace(stderr)
  stderr.lines.reject { |l| l.start_with?('trace (most recent call last)') || l.match?(/\A\t\[\d+\]/) }
        .map { |l| l.sub(/\A(?:\S+?:\d+|\(unknown\):0)(?::in \w+)?: /, '') }.join
end

def best_time(command, repeat, chdir, status_ok)
  times = Array.new(repeat) do
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    _out, _err, status = Open3.capture3(*command, stdin_data: '', binmode: true, chdir: chdir)
    abort "timed run failed: #{command.join(' ')} (#{status.inspect})" unless status.exitstatus == status_ok
    Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
  end
  times.min
end

Dir.mktmpdir('script-world-') do |temp|
  chdir = options[:chdir] || Dir.pwd
  flags = ENV['SCRIPT_WORLD_COMPILED_FLAGS'].to_s.split
  puts "Script world: #{options[:script]}#{flags.empty? ? '' : ", extra flags: #{flags.join(' ')}"}"
  gems, count, _diagnostics = build_compiled(options, temp)
  config = mruby_config(temp, gems, flags)
  # Temporary gem paths can leave stale objects in a kept build directory.
  %w[script-compiled script-benchmark].each { |g| FileUtils.rm_rf(File.join(MRUBY, "build/scriptcompiled/mrbgems/#{g}")) }
  rake_env = ENV.to_h.to_h { |k, v| [k, k.start_with?('BUNDLE') || %w[RUBYOPT RUBYLIB].include?(k) ? nil : v] }
                 .merge('MRUBY_CONFIG' => config)
  rake_env['LD'] = rake_env['CC'] || 'cc'
  output, status = Open3.capture2e(rake_env, 'rake', '-m', 'verify_script_world', 'link_script', "-j#{Etc.nprocessors}",
                                   chdir: MRUBY)
  raise "mruby build failed (#{status.exitstatus}):\n#{output[-6000..] || output}" unless status.success?

  compiled = File.join(MRUBY, 'build/scriptcompiled/bin/script')
  interpreted = File.join(MRUBY, 'build/scriptinterpreted/bin/mruby')
  puts "bc2cpp installed #{count} compiled methods"
  runtimes = {
    'mruby interpreter' => ->(args) { [interpreted, options[:script], *args] },
    'mruby + bc2cpp (sealed)' => ->(args) { [compiled, *args] },
    'CRuby' => ->(args) { [RbConfig.ruby, '--disable=jit', options[:script], *args] }
  }

  cases = shell_cases(options[:cases])
  bad = 0
  cases.each do |args, uncaught|
    expected = run_case(runtimes['mruby interpreter'].call(args), chdir)
    got = run_case(runtimes['mruby + bc2cpp (sealed)'].call(args), chdir)
    if uncaught
      expected[1] = without_backtrace(expected[1])
      got[1] = without_backtrace(got[1])
    end
    next if expected == got

    bad += 1
    puts "DIFF #{args.join(' ')}: interpreted status #{expected[2]}, compiled status #{got[2]}; " \
         "stdout #{expected[0] == got[0] ? 'same' : 'differs'}, stderr #{expected[1] == got[1] ? 'same' : 'differs'}"
  end
  puts "cases: #{cases.size - bad}/#{cases.size} give the same stdout, stderr and exit status compiled as interpreted"
  abort 'FAIL script world: compiled and interpreted runs differ' unless bad.zero?

  options[:bench].each do |args|
    argv = Shellwords.split(args)
    puts "benchmark: #{args} (best of #{options[:repeat]})"
    results = runtimes.to_h { |label, make| [label, best_time(make.call(argv), options[:repeat], chdir, options[:bench_status])] }
    results.each { |label, seconds| puts format('%s: %.3f s', label, seconds) }
    puts format('bc2cpp speedup over the mruby interpreter: %.1fx; over CRuby: %.2fx',
                results['mruby interpreter'] / results['mruby + bc2cpp (sealed)'],
                results['CRuby'] / results['mruby + bc2cpp (sealed)'])
  end
end
