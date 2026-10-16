#!/usr/bin/env ruby
# encoding: UTF-8
# frozen_string_literal: true

# Check PROVEN_MISS_REVIEWED (docs/adr/0275): on a closed-world build a send
# whose receiver class is PROVEN (fresh `Klass.new`, instance literal, lexical
# instance `self`, class constant) and whose chain has no definition of the
# name and no method_missing is a build error unless
# tools/bc2cpp/proven_miss_reviewed.rb lists it.
#
#   - the gate logic (unreviewed / stale / hot-only), like NOMETHOD_REVIEWED's;
#   - a fixture world: the error fires for proven-class misses, and does NOT
#     fire for hint-only receivers, respond_to?-guarded sends, method_missing
#     classes, rescued sends, inherited definitions or defined names;
#   - bc2cpp.rb aborts on an unreviewed site in an engine-owner method; a fixture
#     program's sites are listed, and judged here through a scope with its owners;
#   - the real wio closed world has exactly the listed sites, in both
#     directions, and its hot-only codegen passes the gate.
#
#   MRBC=path/to/host/mrbc ruby scripts/bc2cpp/proven_miss_check.rb

require 'open3'
require 'shellwords'
require 'tmpdir'
require_relative '../../tools/bc2cpp/nomethod_reviewed_probe'
require_relative '../../tools/bc2cpp/closed_world'
require_relative '../../tools/bc2cpp/wio_world_env'

root = File.expand_path('../..', __dir__)
mrbc = ENV['MRBC'] || 'mrbc'
failures = []
check = lambda do |what, condition|
  puts "  #{condition ? 'ok  ' : 'FAIL'} #{what}"
  failures << what unless condition
end

# -- the gate ---------------------------------------------------------------------

puts '== ProvenMiss.violations'
marked = { owner: 'A', name: 'm', code: "r1 = x;\n  #{ProvenMiss.marker('foo', :fresh_new, 'B')}\n" }
plain = { owner: 'B', name: 'n', code: "r1 = y;\n" }
compiled = [marked, plain]
sites = ProvenMiss.sites(compiled)
all = ReviewScope::ALL
check.call('a marked site becomes its "Owner#method -> name (kind Class)" key',
           sites.map { |s| s[:key] } == ['A#m -> foo (fresh_new B)'])
check.call('a listed site passes', ProvenMiss.violations(sites, compiled, scope: all, reviewed: Set['A#m -> foo (fresh_new B)']).empty?)
v = ProvenMiss.violations(sites, compiled, scope: all, reviewed: Set[])
check.call('an unlisted site fails', v == ['unreviewed proven-class miss: A#m -> foo (fresh_new B)'])
v = ProvenMiss.violations(sites, compiled, scope: all, reviewed: Set['A#m -> foo (fresh_new B)', 'B#n -> gone (literal Array)'])
check.call('a listed site gone from a compiled method fails as stale', v.size == 1 && v.first.start_with?('stale'))
check.call('a hot-only run (stale: false) checks unreviewed sites only',
           ProvenMiss.violations(sites, compiled, scope: all, reviewed: Set['B#n -> gone (literal Array)'], stale: false).size == 1)
check.call('a site outside the scope is not judged',
           ProvenMiss.violations(sites, compiled, scope: Set['B'], reviewed: Set[]).empty?)
check.call('the stderr listing parses back',
           ProvenMiss.parse_listing("  PROVEN_MISS A#m -> foo? (lexical_self X::Y)\n") ==
             [{ key: 'A#m -> foo? (lexical_self X::Y)' }])

puts '== outside definitions'
Dir.mktmpdir do |dir|
  path = File.join(dir, 'kernel.rb')
  File.write(path, "module Kernel\n  private def loop(&block); end\n  public def pm_public; end\n  def self.pm_s; end\nend\n")
  # ClosedWorld is built by the compiler; only its private outside-source scan is exercised.
  names = ClosedWorld.allocate.send(:broad_def_names, [path])
  check.call('`private def loop` (mruby Kernel#loop) counts as an outside definition, not a missing name',
             names >= Set['loop', 'pm_public', 'pm_s'])
end

# -- a fixture closed world ---------------------------------------------------------

puts '== bc2cpp.rb on a fixture closed world'
# Methods named fires_* must be flagged; quiet_* must not.
WORLD = <<~'RUBY'
  class PmPet
    def pm_speak; 1; end
  end
  class PmKid < PmPet
  end
  class PmRobot
    def pm_beep; 2; end
  end
  class PmGhost
    def method_missing(name, *args); name; end
    def respond_to_missing?(name, priv = false); true; end
  end
  class PmHolder
    def initialize
      @pet = PmPet.new
    end
    def quiet_hint_only
      @pet.pm_hint_typo
    end
    def fires_self_implicit
      pm_self_typo
    end
    def fires_self_explicit
      self.pm_self_typo2
    end
    def fires_fresh_new
      PmPet.new.pm_fresh_typo
    end
    def fires_defined_elsewhere
      PmPet.new.pm_beep
    end
    def fires_literal
      [1, 2].pm_literal_typo
    end
    def fires_string_literal
      'abc'.pm_string_typo
    end
    def fires_constant_object
      PmPet.pm_const_typo
    end
    def pm_helper(x, y = nil); [x, y]; end
    def quiet_implicit_self_after_literal
      pm_helper([1, 2], pm_helper({}))
    end
    def quiet_defined
      PmPet.new.pm_speak
    end
    def quiet_inherited
      PmKid.new.pm_speak
    end
    def quiet_method_missing
      PmGhost.new.pm_ghost_anything
    end
    def quiet_respond_to
      pet = PmPet.new
      pet.pm_probed if pet.respond_to?(:pm_probed)
    end
    def quiet_rescue_no_method_error
      PmPet.new.pm_rescued
    rescue NoMethodError
      0
    end
    def quiet_rescue_in_block
      begin
        [1].each { PmPet.new.pm_rescued_block }
      rescue StandardError
        0
      end
    end
  end
RUBY
gems_env = Shellwords.join(NomethodReviewedProbe.wio_gems(root).map { |n, d| "#{n}=#{d}" })
ENGINE_WORLD = <<~'RUBY'
  class PmPet
    def pm_beep; 1; end
  end
  module Game
    class Shop
      def pm_fires
        PmPet.new.pm_fresh_typo
      end
    end
  end
RUBY
generate = lambda do |world|
  Dir.mktmpdir do |dir|
    path = File.join(dir, 'pm_fixture.rb')
    File.write(path, world)
    # The repo's sig/bc2cpp signatures describe the engine's classes; this fixture program has none of them.
    env = { 'MRBC' => mrbc, 'OUT_SYMBOL' => 'pm_fixture', 'OUT_DIR' => dir, 'SKIP_UNSUPPORTED' => '1',
            'BC2CPP_BUILD_NAME' => 'wio', 'BC2CPP_BUILD_GEMS' => gems_env,
            'BC2CPP_SIG_DIRS' => '' }
    Open3.capture3(bc2cpp_wio_world_env(env), RbConfig.ruby, File.join(root, 'tools/bc2cpp/bc2cpp.rb'), '--annotated', path)
  end
end
out, err, status = generate.call(WORLD)
found = ProvenMiss.parse_listing(err).map { |s| s[:key] }.sort
expected = [
  'PmHolder#fires_constant_object -> pm_const_typo (constant_object PmPet)',
  'PmHolder#fires_defined_elsewhere -> pm_beep (fresh_new PmPet)',
  'PmHolder#fires_fresh_new -> pm_fresh_typo (fresh_new PmPet)',
  'PmHolder#fires_literal -> pm_literal_typo (literal Array)',
  'PmHolder#fires_self_explicit -> pm_self_typo2 (lexical_self PmHolder)',
  'PmHolder#fires_self_implicit -> pm_self_typo (lexical_self PmHolder)',
  'PmHolder#fires_string_literal -> pm_string_typo (literal String)'
]
check.call('the fixture program (outside the reviewed program) generates and lists its sites', status.success?)
(expected - found).each { |k| puts "    missing: #{k}" }
(found - expected).each { |k| puts "    unexpected: #{k}" }
check.call('every proven-class miss is a site; hints, probes, method_missing, rescue and defined names are not',
           found == expected)
check.call('the gate judges those sites through a scope that includes the fixture owner',
           ProvenMiss.violations(ProvenMiss.parse_listing(err), [], scope: Set['PmHolder'], reviewed: Set[]).size ==
             expected.size)
check.call('the site keeps a real dispatch (the miss raises NoMethodError at run time as before)',
           out.include?('/* CLOSED_WORLD proven_miss: fresh_new PmPet.pm_fresh_typo */') &&
           out.match?(%r{/\* CLOSED_WORLD proven_miss: fresh_new PmPet\.pm_fresh_typo \*/\n\s+r\d+ = (?:mrb_funcall|bc2cpp_send)\(}))
_out, err, status = generate.call(ENGINE_WORLD)
check.call('in an engine-owner method bc2cpp.rb aborts and names the unreviewed site, after every listing',
           !status.success? && err.include?('unreviewed proven-class miss: Game::Shop#pm_fires -> pm_fresh_typo') &&
             NomethodReviewedProbe.review_abort?(status, err))

# -- the real wio closed world ------------------------------------------------------

puts '== the wio closed world (mruby-lcf/rgss/rpg2k-compiled)'
runs = NomethodReviewedProbe.runs(root, mrbc)
runs[:hot].sort.each do |gem_name, (hot_status, hot_err)|
  check.call("#{gem_name}: the real hot-only wio codegen passes the gate", hot_status.success?)
  hot_err.scan(/^  (?:unreviewed proven-class miss|stale PROVEN_MISS_REVIEWED entry).*$/) { |l| puts "    #{l.strip}" }
end
real = runs[:proven_miss]
keys = real.map { |s| s[:key] }.to_set
unreviewed = (keys - PROVEN_MISS_REVIEWED).sort
stale = (PROVEN_MISS_REVIEWED - keys).sort
unreviewed.each { |k| puts "    unreviewed: #{k}" }
stale.each { |k| puts "    stale: #{k}" }
check.call("every proven-class miss is reviewed (#{keys.size} key(s), #{real.size} site(s))", unreviewed.empty?)
check.call("every PROVEN_MISS_REVIEWED entry (#{PROVEN_MISS_REVIEWED.size}) is still a proven miss", stale.empty?)

if failures.empty?
  puts "bc2cpp_proven_miss_check: ok (#{PROVEN_MISS_REVIEWED.size} reviewed, #{real.size} sites)"
else
  abort "bc2cpp_proven_miss_check: #{failures.size} failure(s) -- read each site and fix it or list it with " \
        'scripts/bc2cpp/proven_miss_update.rb (docs/adr/0275)'
end
