#!/usr/bin/env ruby
# frozen_string_literal: true

# Check the warm generator (tools/bc2cpp/warm_generator.rb, ADR 0416), opt-in through BC2CPP_WARM_GENERATOR=1:
# 1. a generation forked from the warm server returns the same stdout, stderr and files as one subprocess per run,
#    for fixtures that succeed and for one that fails to compile (the same error text);
# 2. a request whose load-time environment differs (BC2CPP_ESCAPE_REPORT, read when the tool is required) runs as a
#    subprocess, and its output is the subprocess's;
# 3. the server's own state is unchanged by the forked generations (its digest before and after is equal).
# Not run by CI. Needs g++ and an mrbc (MRBC, or mrbc on PATH); prints SKIP without them.
#
# Usage: ruby scripts/bc2cpp/warm_generator_check.rb

require 'tmpdir'
require 'fileutils'
require_relative 'fixture_runtime'

failures = []
check = lambda do |what, condition|
  puts "  #{condition ? 'ok  ' : 'FAIL'} #{what}"
  failures << what unless condition
end

mrbc_banner = begin
  Open3.capture2e(Bc2cppFixtureRuntime.mrbc, '-v').first
rescue SystemCallError
  ''
end
unless Bc2cppFixtureRuntime.compiler? && mrbc_banner.include?('mruby')
  puts 'SKIP: no g++ or no runnable mrbc (set MRBC)'
  exit 0
end

FIXTURES = {
  'one-method' => "class NsWarmOne\n  def add(a, b) = a + b * 3\nend\n",
  'two-methods' => "class NsWarmTwo\n  def first(x) = x - 1\n  def second(a, b)\n    a * b + 7\n  end\nend\n",
  'broken' => "class NsWarmBroken\n  def m(a\n"
}.freeze

# [stdout, stderr, error] of one generation of `source` in `dir`; error is the raised message, or nil.
def generate_once(source, dir)
  FileUtils.rm_rf(dir)
  FileUtils.mkdir_p(dir)
  name = source[/class (\w+)/, 1]
  code, err = Bc2cppFixtureRuntime.generate(source, dir, closed: true, only_owners: [name])
  [code, err, nil]
rescue RuntimeError => e
  [nil, nil, e.message]
end

def with_warm(on)
  saved = ENV.fetch('BC2CPP_WARM_GENERATOR', nil)
  on ? ENV['BC2CPP_WARM_GENERATOR'] = '1' : ENV.delete('BC2CPP_WARM_GENERATOR')
  yield
ensure
  saved ? ENV['BC2CPP_WARM_GENERATOR'] = saved : ENV.delete('BC2CPP_WARM_GENERATOR')
end

check.call('the warm generator is off by default', !WarmGenerator.enabled?) if ENV['BC2CPP_WARM_GENERATOR'].nil?

# A report the tool writes from an at_exit hook (codegen_native_owner_map.rb): it must come out byte-identical too.
REPORT = 'BC2CPP_NATIVE_OWNER_MAP_REPORT'

Dir.mktmpdir('bc2cpp-warm-check') do |base|
  outputs = { cold: {}, warm: {} }
  report = File.join(base, 'owner-map.txt')
  # The report comes from the last generation of each mode, a successful one-method fixture.
  with_warm(false) do
    FileUtils.rm_f(report)
    ENV[REPORT] = report
    FIXTURES.each { |name, source| outputs[:cold][name] = generate_once(source, File.join(base, name)) }
    outputs[:cold][:last] = generate_once(FIXTURES['one-method'], File.join(base, 'last'))
    outputs[:cold][:report] = File.binread(report) if File.exist?(report)
    ENV.delete(REPORT)
  end
  with_warm(true) do
    FileUtils.rm_f(report)
    ENV[REPORT] = report
    FIXTURES.each do |name, source|
      outputs[:warm][name] = generate_once(source, File.join(base, name))
    end
    outputs[:warm][:last] = generate_once(FIXTURES['one-method'], File.join(base, 'last'))
    outputs[:warm][:report] = File.binread(report) if File.exist?(report)
    ENV.delete(REPORT)
    client = WarmGenerator.clients.fetch(File.expand_path(Bc2cppFixtureRuntime::BC2CPP))
    # The fixtures plus the report's last one-method generation, all by fork.
    check.call("the warm path served the generations by fork (#{client.generations} fork, #{client.fallbacks} subprocess)",
               client.generations == FIXTURES.size + 1 && client.fallbacks.zero?)

    FIXTURES.each_key do |name|
      check.call("#{name}: stdout, stderr and error are byte-identical to the subprocess run",
                 outputs[:cold][name] == outputs[:warm][name])
    end
    check.call('the broken fixture fails in both modes with the same message',
               outputs[:cold]['broken'].last && outputs[:cold]['broken'].last == outputs[:warm]['broken'].last)
    check.call('the report written from an at_exit hook is non-empty and byte-identical',
               outputs[:cold][:report].to_s.size.positive? && outputs[:cold][:report] == outputs[:warm][:report])

    # The server's state must not move under forked generations (ADR 0416's state audit).
    before = client.digest
    FIXTURES.each { |name, source| generate_once(source, File.join(base, name)) }
    check.call('the server state digest is unchanged by forked generations', before == client.digest)

    # A load-time gate that differs for one request: that request runs as a subprocess, byte-identically.
    dir = File.join(base, 'gated')
    FileUtils.mkdir_p(dir)
    File.write(File.join(dir, 'fixture.rb'), FIXTURES['one-method'])
    argv = [File.join(dir, 'fixture.rb')]
    changes = { 'OUT_DIR' => dir, 'OUT_SYMBOL' => 'fixture', 'BC2CPP_ESCAPE_REPORT' => File.join(dir, 'escape.txt') }
    gated = client.run(argv, changes)
    expected = Open3.capture3(changes, RbConfig.ruby, Bc2cppFixtureRuntime::BC2CPP, *argv)
    check.call('a request with a differing load-time gate runs as a subprocess', client.fallbacks == 1)
    check.call('...and its stdout, stderr and status match a subprocess run',
               gated[0] == expected[0] && gated[1] == expected[1] && gated[2].success? == expected[2].success?)
  end
end

if failures.empty?
  puts 'warm_generator_check: all checks passed'
else
  puts "warm_generator_check: #{failures.size} failed"
  exit 1
end
