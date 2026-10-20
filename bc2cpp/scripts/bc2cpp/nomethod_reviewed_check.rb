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
#   - the scope (tools/bc2cpp/review_scope.rb): the lists judge the engine's
#     owners, matched exactly, and every owner they name is one;
#   - bc2cpp.rb itself aborts a closed-world run on an unreviewed site in an
#     engine-owner method, lists a fixture program's sites without judging
#     them, and marks nothing without the switch;
#   - the real closed world: its hot-only codegen (what the build runs)
#     passes the gate, and with every method compiled it has exactly the
#     listed sites, no more and no fewer.
#
#   MRBC=path/to/host/mrbc ruby scripts/bc2cpp/nomethod_reviewed_check.rb

require 'open3'
require 'shellwords'
require 'tmpdir'
require_relative '../../tools/bc2cpp/nomethod_reviewed_probe'
require_relative '../../tools/bc2cpp/closed_world_env'

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
all = ReviewScope::ALL
check.call('a marked site becomes its "Owner#method -> name" key',
           sites == [{ key: 'A#m -> foo', owner: 'A', method: 'm', called: 'foo', self_receiver: true }])
check.call('a listed site passes', NomethodReviewed.violations(sites, compiled, scope: all, reviewed: Set['A#m -> foo']).empty?)
v = NomethodReviewed.violations(sites, compiled, scope: all, reviewed: Set[])
check.call('an unlisted site fails', v == ['unreviewed dead fallback: A#m -> foo'])
v = NomethodReviewed.violations(sites, compiled, scope: all, reviewed: Set['A#m -> foo', 'B#n -> gone'])
check.call('a listed site gone from a compiled method fails as stale', v.size == 1 && v.first.start_with?('stale'))
check.call('a listed site in a method this run did not compile is not stale',
           NomethodReviewed.violations(sites, compiled, scope: all, reviewed: Set['A#m -> foo', 'Z#q -> x', 'C#k -> x']).empty?)
check.call('a hot-only run (stale: false) checks unreviewed sites only',
           NomethodReviewed.violations(sites, compiled, scope: all, reviewed: Set['B#n -> gone'], stale: false) ==
             ['unreviewed dead fallback: A#m -> foo'])
check.call('a site outside the scope is not judged, and neither is a listed entry of a method outside it',
           NomethodReviewed.violations(sites, compiled, scope: Set['B'], reviewed: Set[]).empty? &&
             NomethodReviewed.violations(sites, compiled, scope: Set['C'], reviewed: Set['B#n -> gone']).empty?)
check.call('a site inside the scope is judged',
           NomethodReviewed.violations(sites, compiled, scope: Set['A'], reviewed: Set[]) ==
             ['unreviewed dead fallback: A#m -> foo'])

puts '== ReviewScope'
check.call('every engine build is held to the engine owners; any other closed-world build to every owner',
           %w[closed].all? { |b| ReviewScope.for_build(b) == ReviewScope::ENGINE_OWNERS } &&
             ReviewScope.for_build('optcarrot-probe') == ReviewScope::ALL && ReviewScope.for_build('') == ReviewScope::ALL)
gem_owners = BC2CPP_COMPILED_GEMS.values.flat_map { |g| g[:owners] }
check.call('the engine owners are every compiled gem owner (core included) and each X.singleton module X',
           gem_owners.all? { |o| ReviewScope::ENGINE_OWNERS.include?(o) } &&
             ReviewScope::ENGINE_OWNERS.include?('LCF') && ReviewScope::ENGINE_OWNERS.include?('Array') &&
             (ReviewScope::ENGINE_OWNERS.to_a - gem_owners).all? { |o| gem_owners.include?("#{o}.singleton") })
list_owners = (NOMETHOD_REVIEWED.to_a + PROVEN_MISS_REVIEWED.to_a + StrictHints.reviewed_set.to_a)
              .map { |k| ReviewScope.key_owner(k) }.uniq
outside = list_owners.reject { |o| ReviewScope::ENGINE_OWNERS.include?(o) }
check.call("every owner the reviewed lists name (#{list_owners.size}) is in the engine scope#{" (not: #{outside.join(', ')})" unless outside.empty?}",
           outside.empty?)
check.call('an engine-owner run that compiles an owner outside the scope is a leak; a fixture run is not',
           ReviewScope.leaks(ReviewScope::ENGINE_OWNERS, %w[LCF.singleton], [{ owner: 'LCF' }, { owner: 'Zz' }]) == ['Zz'] &&
             ReviewScope.leaks(ReviewScope::ENGINE_OWNERS, %w[CwCaller], [{ owner: 'CwCaller' }]).empty? &&
             ReviewScope.leaks(ReviewScope::ENGINE_OWNERS, nil, [{ owner: 'CwCaller' }]).empty?)

listing = "  NOMETHOD A#m -> foo [self]\n  NOMETHOD Z.singleton#q -> bar?\n"
check.call('the stderr listing parses back',
           NomethodReviewed.parse_listing(listing) == [{ key: 'A#m -> foo', self_receiver: true },
                                                      { key: 'Z.singleton#q -> bar?', self_receiver: false }])

# -- bc2cpp.rb fails the build ------------------------------------------------------

puts '== bc2cpp.rb on a fixture closed world'
# No method_missing class, so the caller's chain lists every definer. The same dead fallback sits in a
# fixture-owned method (CwCaller) and in an engine-owner method (Game::Shop, an owner of the compiled gems).
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
ENGINE_WORLD = <<~'RUBY'
  class CwPet
    def cw_speak; 1; end
  end
  class CwRobot
    def cw_speak; 2; end
  end
  module Game
    class Shop
      def cw_talk(x); x.cw_speak; end
    end
  end
RUBY
gems_env = Shellwords.join(NomethodReviewedProbe.closed_gems(root).map { |n, d| "#{n}=#{d}" })
generate = lambda do |world|
  Dir.mktmpdir do |dir|
    path = File.join(dir, 'cw_gate.rb')
    File.write(path, world)
    # The repo's sig/bc2cpp signatures describe the engine's classes; this fixture program has none of them.
    env = { 'MRBC' => mrbc, 'OUT_SYMBOL' => 'cw_gate', 'OUT_DIR' => dir, 'SKIP_UNSUPPORTED' => '1', 'BC2CPP_SIG_DIRS' => '' }
    env.merge!('BC2CPP_BUILD_NAME' => 'closed', 'BC2CPP_BUILD_GEMS' => gems_env)
    Open3.capture3(bc2cpp_closed_world_probe_env(env), RbConfig.ruby, File.join(root, 'tools/bc2cpp/bc2cpp.rb'), '--annotated', path)
  end
end
_out, err, status = generate.call(ENGINE_WORLD)
check.call('an unreviewed dead fallback in an engine-owner method aborts the closed-world run and names the site',
           !status.success? && err.include?('unreviewed dead fallback: Game::Shop#cw_talk -> cw_speak'))
check.call('that run failed only on the reviewed lists, after every listing (NomethodReviewedProbe.review_abort?)',
           NomethodReviewedProbe.review_abort?(status, err) &&
             NomethodReviewed.parse_listing(err).map { |s| s[:key] } == ['Game::Shop#cw_talk -> cw_speak'])
check.call('review_abort? refuses any other failure',
           !NomethodReviewedProbe.review_abort?(status, "#{err}bc2cpp: something else\n") &&
             !NomethodReviewedProbe.review_abort?(status, err.sub(/^== closed world proven-class miss sites: .*$/, '')))
out, err, status = generate.call(WORLD)
fixture_sites = NomethodReviewed.parse_listing(err)
check.call('a fixture-owned site is generated and listed but outside the reviewed program',
           status.success? && out.include?('/* CLOSED_WORLD nomethod: recv.cw_speak */') &&
             fixture_sites.map { |s| s[:key] } == ['CwCaller#talk -> cw_speak'] &&
             err.include?('1 listed site(s) outside the reviewed program'))
check.call('the gate judges that listing through a scope that includes the fixture owner',
           NomethodReviewed.violations(fixture_sites, [], scope: Set['CwCaller'], reviewed: Set[]) ==
             ['unreviewed dead fallback: CwCaller#talk -> cw_speak'])

# -- the real closed world ------------------------------------------------------

puts '== the closed world (mruby-lcf/rgss/rpg2k-compiled)'
runs = NomethodReviewedProbe.runs(root, mrbc)
runs[:hot].sort.each do |gem_name, (status, err)|
  n = NomethodReviewed.parse_listing(err).size
  check.call("#{gem_name}: the real hot-only closed codegen passes the gate (#{n} site(s))", status.success?)
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
