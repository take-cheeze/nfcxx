#!/usr/bin/env ruby
# frozen_string_literal: true

# Check STRICT_HINTS_REVIEWED (docs/adr/0419) over the real wio closed world, with BC2CPP_STRICT_HINTS=1:
#
#   - the real hot-only codegen of each compiled gem (what a build runs) passes the gate: every forced
#     site is listed in tools/bc2cpp/strict_hints_reviewed.rb;
#   - with every method compiled (the superset) the forced sites are exactly the listed ones, no more
#     and no fewer, so a new forced site is noticed and a vanished one is dropped from the list.
#
#   MRBC=path/to/host/mrbc ruby scripts/bc2cpp/strict_hints_reviewed_check.rb

require 'set'
require_relative '../../tools/bc2cpp/nomethod_reviewed_probe'
require_relative '../../tools/bc2cpp/strict_hints'
require_relative '../../tools/bc2cpp/strict_hints_reviewed'

root = File.expand_path('../..', __dir__)
mrbc = ENV['MRBC'] || 'mrbc'
ENV[StrictHints::ENV_NAME] = 'all'
failures = []
check = lambda do |what, condition|
  puts "  #{condition ? 'ok  ' : 'FAIL'} #{what}"
  failures << what unless condition
end

jobs = BC2CPP_COMPILED_GEMS.keys.flat_map { |g| [[g, :full], [g, :hot]] }
results = jobs.map do |gem_name, kind|
  Thread.new do
    hot = kind == :hot ? BC2CPP_HOT_METHODS_PATH : nil
    _out, err, status = NomethodReviewedProbe.run(gem_name, root, mrbc, hot_methods: hot, allow: kind == :full)
    [gem_name, kind, err, status]
  end
end.map(&:value)

results.select { |_, kind| kind == :hot }.sort.each do |gem_name, _, err, status|
  n = StrictHints.parse_listing(err).size
  check.call("#{gem_name}: the real hot-only wio codegen passes the gate (#{n} forced site(s))", status.success?)
  err.scan(/^  (?:unreviewed forced hint|stale STRICT_HINTS_REVIEWED entry).*$/) { |l| puts "    #{l.strip}" }
end
full = results.select { |_, kind| kind == :full }
full.each { |gem_name, _, err, status| check.call("#{gem_name}: the full codegen runs", status.success? || (puts(err[-1500..]) && false)) }
keys = full.flat_map { |_, _, err, _| StrictHints.parse_listing(err) }.to_set
unreviewed = (keys - STRICT_HINTS_REVIEWED).sort
stale = (STRICT_HINTS_REVIEWED - keys).sort
unreviewed.each { |k| puts "    unreviewed: #{k}" }
stale.each { |k| puts "    stale: #{k}" }
check.call("every forced site is reviewed (#{keys.size} key(s))", unreviewed.empty?)
check.call("every STRICT_HINTS_REVIEWED entry (#{STRICT_HINTS_REVIEWED.size}) is still a forced site", stale.empty?)

if failures.empty?
  puts "bc2cpp strict hints reviewed check: ok (#{STRICT_HINTS_REVIEWED.size} reviewed)"
else
  abort "bc2cpp strict hints reviewed check: #{failures.size} failure(s) -- regenerate with " \
        'scripts/bc2cpp/strict_hints_update.rb after the verify build is clean (docs/adr/0419)'
end
