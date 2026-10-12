#!/usr/bin/env ruby
# encoding: UTF-8
# frozen_string_literal: true

# Check NOMETHOD_REVIEWED (docs/adr/0226): on a closed-world build every
# proven-dead guard-chain fallback (a bc2cpp_nomethod site, ADR 0210) is a
# build error unless tools/bc2cpp/nomethod_reviewed.rb lists it.
#
#   - the gate: an unlisted site and a listed site gone from a method this run
#     compiled are violations; a listed site in a method the run did not
#     compile (another gem) is not, and a hot-only run checks unlisted only;
#   - bc2cpp.rb itself aborts a closed-world run on an unreviewed site, and
#     marks nothing without the switch;
#   - the real wio closed world: its hot-only codegen (what the build runs)
#     passes the gate, and with every method compiled it has exactly the
#     listed sites, no more and no fewer.
#
#   MRBC=path/to/host/mrbc ruby scripts/bc2cpp/nomethod_reviewed_check.rb

require 'open3'
require 'shellwords'
require 'tmpdir'
require_relative '../../tools/bc2cpp/nomethod_reviewed_probe'

root = File.expand_path('../..', __dir__)
mrbc = ENV['MRBC'] || 'mrbc'
failures = []
check = lambda do |what, condition|
  puts "  #{condition ? 'ok  ' : 'FAIL'} #{what}"
  failures << what unless condition
end

# -- the gate ---------------------------------------------------------------------

puts '== NomethodReviewed.violations'
marked = { owner: 'A', name: 'm', code: "r1 = x; #{NomethodReviewed.marker('foo', self_receiver: true)}\n" }
plain = { owner: 'B', name: 'n', code: "r1 = y;\n" }
skipped = { owner: 'C', name: 'k', code: "#error\n", unsupported: true }
compiled = [marked, plain, skipped]
sites = NomethodReviewed.sites(compiled)
check.call('a marked site becomes its "Owner#method -> name" key',
           sites == [{ key: 'A#m -> foo', owner: 'A', method: 'm', called: 'foo', self_receiver: true }])
check.call('a listed site passes', NomethodReviewed.violations(sites, compiled, reviewed: Set['A#m -> foo']).empty?)
v = NomethodReviewed.violations(sites, compiled, reviewed: Set[])
check.call('an unlisted site fails', v == ['unreviewed dead fallback: A#m -> foo'])
v = NomethodReviewed.violations(sites, compiled, reviewed: Set['A#m -> foo', 'B#n -> gone'])
check.call('a listed site gone from a compiled method fails as stale', v.size == 1 && v.first.start_with?('stale'))
check.call('a listed site in a method this run did not compile is not stale',
           NomethodReviewed.violations(sites, compiled, reviewed: Set['A#m -> foo', 'Z#q -> x', 'C#k -> x']).empty?)
check.call('a hot-only run (stale: false) checks unreviewed sites only',
           NomethodReviewed.violations(sites, compiled, reviewed: Set['B#n -> gone'], stale: false) ==
             ['unreviewed dead fallback: A#m -> foo'])
listing = "  NOMETHOD A#m -> foo [self]\n  NOMETHOD Z.singleton#q -> bar?\n"
check.call('the stderr listing parses back',
           NomethodReviewed.parse_listing(listing) == [{ key: 'A#m -> foo', self_receiver: true },
                                                      { key: 'Z.singleton#q -> bar?', self_receiver: false }])

# -- bc2cpp.rb fails the build ------------------------------------------------------

puts '== bc2cpp.rb on a fixture closed world'
# No method_missing class, so CwCaller#talk's chain lists every definer.
WORLD = <<~'RUBY'
  class CwPet
    def cw_speak; 1; end
  end
  class CwRobot
    def cw_speak; 2; end
  end
  class CwCaller
    def talk(x); x.cw_speak; end
  end
RUBY
gems_env = Shellwords.join(NomethodReviewedProbe.wio_gems(root).map { |n, d| "#{n}=#{d}" })
generate = lambda do |closed, allow|
  Dir.mktmpdir do |dir|
    path = File.join(dir, 'cw_gate.rb')
    File.write(path, WORLD)
    env = { 'MRBC' => mrbc, 'OUT_SYMBOL' => 'cw_gate', 'OUT_DIR' => dir, 'SKIP_UNSUPPORTED' => '1' }
    if closed
      env.merge!('BC2CPP_CLOSED_WORLD' => '1', 'BC2CPP_BUILD_NAME' => 'wio', 'BC2CPP_BUILD_GEMS' => gems_env,
                 NomethodReviewed::ALLOW_ENV => (allow ? 'allow' : nil))
    end
    Open3.capture3(env, RbConfig.ruby, File.join(root, 'tools/bc2cpp/bc2cpp.rb'), path)
  end
end
_out, err, status = generate.call(true, false)
check.call('an unreviewed dead fallback aborts the closed-world run and names the site',
           !status.success? && err.include?('unreviewed dead fallback: CwCaller#talk -> cw_speak'))
out, err, status = generate.call(true, true)
check.call("#{NomethodReviewed::ALLOW_ENV}=allow (fixtures only) reports it and still generates",
           status.success? && err.include?('ignoring') && out.include?('/* CLOSED_WORLD nomethod: recv.cw_speak */'))
out, _err, status = generate.call(false, false)
check.call('without the switch nothing is marked', status.success? && !out.include?('CLOSED_WORLD nomethod'))

# -- the real wio closed world ------------------------------------------------------

puts '== the wio closed world (mruby-lcf/rgss/rpg2k-compiled)'
runs = NomethodReviewedProbe.runs(root, mrbc)
runs[:hot].sort.each do |gem_name, (status, err)|
  n = NomethodReviewed.parse_listing(err).size
  check.call("#{gem_name}: the real hot-only wio codegen passes the gate (#{n} site(s))", status.success?)
  err.scan(/^  (?:unreviewed dead fallback|stale NOMETHOD_REVIEWED entry).*$/) { |l| puts "    #{l.strip}" }
end
real = runs[:full]
keys = real.map { |s| s[:key] }.to_set
unreviewed = (keys - NOMETHOD_REVIEWED).sort
stale = (NOMETHOD_REVIEWED - keys).sort
puts '  every method compiled (the superset the list must equal):'
real.group_by { |s| s[:gem] }.sort.each do |gem_name, group|
  puts "  #{gem_name}: #{group.size} bc2cpp_nomethod site(s), #{group.map { |s| s[:key] }.uniq.size} key(s)"
end
unreviewed.each { |k| puts "    unreviewed: #{k}" }
stale.each { |k| puts "    stale: #{k}" }
check.call("every dead fallback is reviewed (#{keys.size} key(s), #{real.size} site(s))", unreviewed.empty?)
check.call("every NOMETHOD_REVIEWED entry (#{NOMETHOD_REVIEWED.size}) is still a dead fallback", stale.empty?)

if failures.empty?
  puts "bc2cpp_nomethod_reviewed_check: ok (#{NOMETHOD_REVIEWED.size} reviewed, #{real.size} sites)"
else
  abort "bc2cpp_nomethod_reviewed_check: #{failures.size} failure(s) -- regenerate with " \
        'scripts/bc2cpp/nomethod_reviewed_update.rb after reviewing each site (docs/adr/0226)'
end
