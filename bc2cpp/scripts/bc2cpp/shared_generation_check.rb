#!/usr/bin/env ruby
# frozen_string_literal: true

# Check SHARED_GENERATION (tools/bc2cpp/shared_generation.rb, ADR 0464) at fixture size, in seconds: `bc2cpp.rb
# --units PLAN` runs one analysis and forks one generation per unit. Two units that differ only in
# ONLY_OWNERS/OTHER_OWNERS/OUT_* must give exactly the stdout, stderr and decls header of two separate runs; a plan
# whose units differ in any other key is refused; and the build helper (Bc2cppCompiledGemGeneration) shares an
# analysis only between gems whose environment and sources are otherwise identical.
#
# Usage: MRBC=path/to/mrbc ruby scripts/bc2cpp/shared_generation_check.rb   (without MRBC the generator runs are skipped)

require 'fileutils'
require 'json'
require 'open3'
require 'rbconfig'
require 'stringio'
require 'tmpdir'
require_relative '../../tools/bc2cpp/shared_generation'
require_relative '../../tools/bc2cpp/compiled_gems'
require_relative '../../tools/bc2cpp/closed_world_env'

ROOT = File.expand_path('../..', __dir__)
TOOL = File.join(ROOT, 'tools/bc2cpp/bc2cpp.rb')
failures = []
check = lambda do |what, condition|
  puts "  #{condition ? 'ok  ' : 'FAIL'} #{what}"
  failures << what unless condition
end
raises = lambda do |error, &block|
  block.call
  false
rescue error
  true
end

Dir.mktmpdir('bc2cpp-shared') do |tmp|
  puts '-- SHARED_GENERATION plans'
  plan = File.join(tmp, 'bad.json')
  File.write(plan, JSON.generate([{ 'env' => { 'ONLY_OWNERS' => 'A', 'SKIP_UNSUPPORTED' => '1' }, 'out' => 'o', 'err' => 'e' }]))
  check.call('a plan whose units differ in a non-unit key is refused',
             raises.call(SharedGeneration::Error) { SharedGeneration.load_plan(plan) })

  # A failed unit's error lines are repeated after every unit's report, so the tail of a CI log shows them.
  ok_err = File.join(tmp, 'ok.err')
  bad_err = File.join(tmp, 'bad.err')
  File.write(ok_err, "== report ==\n[bc2cpp] fine\n")
  File.write(bad_err, "== report ==\nx.rb:3:1: error: not proven [TC1013]\n  noise\n[bc2cpp] RBS_CHECKED_PARAMS: 1 unproven\n")
  status = Struct.new(:success?, :exitstatus)
  trailer = lambda do |statuses|
    saved = $stderr
    $stderr = StringIO.new
    SharedGeneration.write_failure_trailer(
      [SharedGeneration::Unit.new(env: { 'OUT_SYMBOL' => 'u_ok' }, out: 'o1', err: ok_err),
       SharedGeneration::Unit.new(env: { 'OUT_SYMBOL' => 'u_bad' }, out: 'o2', err: bad_err)], statuses)
    $stderr.string
  ensure
    $stderr = saved
  end
  failed_text = trailer.call([status.new(true, 0), status.new(false, 1)])
  check.call('a failed unit\'s error lines and last lines are repeated at the end, named and with its status',
             failed_text == "\n== --units: unit u_bad failed (exit 1): 1 of 1 error line(s), then its last 4 line(s) ==\n" \
                            "x.rb:3:1: error: not proven [TC1013]\n--\n== report ==\n" \
                            "x.rb:3:1: error: not proven [TC1013]\n  noise\n[bc2cpp] RBS_CHECKED_PARAMS: 1 unproven\n")
  check.call('no trailer when every unit succeeds', trailer.call([status.new(true, 0), status.new(true, 0)]).empty?)
  SharedGeneration.arm_guard
  guarded = raises.call(SharedGeneration::Error) { ENV['ONLY_OWNERS'] }
  whole = raises.call(SharedGeneration::Error) { ENV.to_h }
  SharedGeneration::EnvGuard.armed = false
  check.call('a unit key read before the fork is a hard error', guarded)
  check.call('so is reading the whole environment before the fork', whole)
  check.call('other keys stay readable, and nothing is guarded after the fork', ENV.key?('PATH') && ENV['ONLY_OWNERS'].nil?)
  check.call('a common environment that holds a unit key is refused',
             raises.call(SharedGeneration::Error) do
               SharedGeneration.run(tool: TOOL, srcs: [], common_env: { 'ONLY_OWNERS' => 'A' }, unit_envs: [{}])
             end)
  groups = lambda do |hot|
    jobs = BC2CPP_COMPILED_GEMS.keys.each_with_index.map do |name, i|
      env = { 'NATIVE_SRCS' => 'x', 'ONLY_OWNERS' => name, 'OUT_DIR' => "/b/#{name}" }
      env['BC2CPP_HOT_METHODS'] = 'h' if hot && i.zero?
      [env, %w[a.rb], "/b/#{name}/gen.cpp"]
    end
    jobs.group_by { |env, srcs, _| [env.reject { |k, _| SharedGeneration::UNIT_KEYS.include?(k) }, srcs] }.size
  end
  check.call('gems that differ only in unit keys form one shared analysis', groups.call(false) == 1)
  check.call('a gem whose analysis environment differs gets its own analysis', groups.call(true) == 2)
  check.call('the build helper groups by exactly that key',
             File.read(File.join(ROOT, 'tools/bc2cpp/compiled_gems.rb'))
                 .include?('jobs.group_by { |env, srcs, _| [env.reject { |k, _| SharedGeneration::UNIT_KEYS.include?(k) }, srcs] }'))

  mrbc = ENV.fetch('MRBC', nil)
  if mrbc.nil? || mrbc.empty?
    puts '  SKIP the generator runs (no MRBC)'
  else
    puts '-- SHARED_GENERATION against separate runs'
    fixture = File.join(tmp, 'fixture.rb')
    File.write(fixture, <<~RUBY)
      class Alpha
        def initialize(n); @n = n; end
        def n; @n + 1; end
      end
      class Beta
        def twice(a); a.n * 2; end
        def make; Alpha.new(3); end
      end
    RUBY
    common = bc2cpp_closed_world_probe_env({ 'MRBC' => mrbc, 'BC2CPP_SELF_REGISTERING' => '1', 'BC2CPP_SIG_DIRS' => '' }, ROOT)
    units = [%w[Alpha Beta], %w[Beta Alpha]].map do |only, other|
      dir = FileUtils.mkdir_p(File.join(tmp, "unit-#{only}")).first
      { 'OUT_SYMBOL' => "u_#{only.downcase}", 'OUT_DIR' => dir, 'ONLY_OWNERS' => only, 'OTHER_OWNERS' => other }
    end
    shared = SharedGeneration.run(tool: TOOL, srcs: [fixture], common_env: common, unit_envs: units)
    shared_decls = units.map { |u| File.read(File.join(u['OUT_DIR'], "#{u['OUT_SYMBOL']}_decls.h")) }
    separate = units.map { |u| Open3.capture3(common.merge(u), RbConfig.ruby, TOOL, fixture) }
    separate_decls = units.map { |u| File.read(File.join(u['OUT_DIR'], "#{u['OUT_SYMBOL']}_decls.h")) }
    check.call('every shared unit succeeds', shared.all? { |_, _, status| status.success? })
    check.call('each unit emits its own owners', shared[0][0].include?('Alpha_n_impl') && shared[1][0].include?('Beta_twice_impl') &&
                                                 shared[0][0] != shared[1][0])
    check.call('shared stdout equals the separate runs', shared.map(&:first) == separate.map(&:first))
    check.call('shared stderr equals the separate runs', shared.map { |r| r[1] } == separate.map { |r| r[1] })
    check.call('shared decls headers equal the separate runs', shared_decls == separate_decls)

  end
end

if failures.empty?
  puts 'bc2cpp shared generation check: PASS'
else
  warn "bc2cpp shared generation check: #{failures.size} failure(s)"
  exit 1
end
