#!/usr/bin/env ruby
# frozen_string_literal: true

# STATIC_DISPATCH_LISTS (tools/bc2cpp/static_dispatch_lists.rb): the method-table lists are computed by the proof and
# read back from the file BC2CPP_STATIC_DISPATCH_LISTS names, so a missing, stale or malformed file has to stop the
# build, and a fixture has to be unaffected.
#
#   the file
#     - a dump parses back to the same sets, and a file without one of the four sets is refused;
#     - 'none' and (for a fixture) an unset variable are empty lists, but an unset variable stops a real gem build;
#     - a file that does not exist stops the run;
#     - a file computed from other sources than the tree (its digest) is refused by verify_current!, and
#       StaticDispatchRegistrations.current? says whether a directory holds the lists for this tree;
#   the generator (needs a host mrbc)
#     - a compiled gem's OUT_SYMBOL with no lists stops emit_owner_registrations, naming the command that makes them;
#     - with 'none' it registers everything, and with a file the open set applies to a build and the closed set to
#       the closed one, as the committed lists did.
#
# Usage: MRBC=path/to/mrbc ruby scripts/bc2cpp/static_dispatch_lists_check.rb

require 'json'
require 'set'
require 'stringio'
require 'tmpdir'
require_relative 'check_support'
require_relative '../../tools/bc2cpp/bc2cpp'
require_relative '../../tools/bc2cpp/static_dispatch_registrations'

ENV['BC2CPP_SIG_DIRS'] = ''
suite = FixtureCheck.new('static_dispatch_lists_check')
suite.require_mrbc!

LISTS = StaticDispatchLists
ROOT = File.expand_path('../..', __dir__)

raises = lambda do |klass = LISTS::Missing, &block|
  block.call
  false
rescue klass
  true
end

lists = LISTS::Lists.new(open: Set['A#a'], closed: Set['A#a', 'B#b'], core_excluded: Set['Array#x'],
                         core_left_out: Set['Array#y'], digest: 'd1')
suite.check('a dump parses back to the same lists', LISTS.parse(LISTS.dump(lists)).to_h == lists.to_h)
suite.check('the closed build takes the closed set, any other build the open one',
            lists.for_build('closed') == lists.closed && lists.for_build('wio') == lists.open)
LISTS::KEYS.each do |key|
  broken = JSON.parse(LISTS.dump(lists)).tap { |data| data.delete(key) }
  suite.check("a file without #{key} is refused", raises.call { LISTS.parse(JSON.generate(broken)) })
end

Dir.mktmpdir('static_dispatch_lists') do |dir|
  path = File.join(dir, 'lists.json')
  File.write(path, LISTS.dump(lists))
  LISTS.reset!
  suite.check('a file is read', LISTS.current(env: { LISTS::PATH_ENV => path }).closed == lists.closed)
  suite.check("'none' is empty lists", LISTS.current(env: { LISTS::PATH_ENV => 'none' }).equal?(LISTS::EMPTY))
  suite.check('unset is empty lists for a fixture', LISTS.current(env: {}).equal?(LISTS::EMPTY))
  suite.check('unset stops a real gem build', raises.call { LISTS.current(required: true, env: {}) })
  suite.check('a file that does not exist stops the run',
              raises.call { LISTS.current(env: { LISTS::PATH_ENV => File.join(dir, 'missing.json') }) })
  suite.check('a file computed from other sources is refused', raises.call { LISTS.verify_current!(lists, ROOT) })

  here = StaticDispatchRegistrations.inputs_digest(ROOT)
  current = LISTS::Lists.new(**lists.to_h, digest: here)
  suite.check('a directory without the file is not current', !StaticDispatchRegistrations.current?(ROOT, dir))
  File.write(File.join(dir, 'static_dispatch_lists.json'), LISTS.dump(lists))
  suite.check('a file for other sources is not current', !StaticDispatchRegistrations.current?(ROOT, dir))
  File.write(File.join(dir, 'static_dispatch_lists.json'), LISTS.dump(current))
  suite.check('a file for this tree is current', StaticDispatchRegistrations.current?(ROOT, dir))
  LISTS.reset!
  suite.check('and verify_current! accepts it', LISTS.verify_current!(LISTS.current(env: { LISTS::PATH_ENV => File.join(dir, 'static_dispatch_lists.json') }), ROOT).nil?)
end

# A restored prefix cache is only a seed. Its omissions must be replaced by the proof's fixed point.
sdr = StaticDispatchRegistrations
saved = %i[inputs_digest pass].to_h { |name| [name, sdr.method(name)] }
begin
  sdr.define_singleton_method(:inputs_digest) { |_| 'current-inputs' }
  Dir.mktmpdir('static_dispatch_seed') do |dir|
    path = File.join(dir, 'static_dispatch_lists.json')
    stale = LISTS::Lists.new(open: Set.new, closed: Set['Old#unsafe'], core_excluded: Set.new,
                            core_left_out: Set.new, digest: 'old-inputs')
    proven = LISTS::Lists.new(open: Set.new, closed: Set.new, core_excluded: Set.new,
                             core_left_out: Set.new, digest: 'current-inputs')
    File.write(path, LISTS.dump(stale))
    seen = []
    sdr.define_singleton_method(:pass) do |_, _, input, _, _|
      seen << input.closed.dup
      suite.check('the old digest is not relabelled before convergence', LISTS.parse(File.read(path)).digest == 'old-inputs')
      proven
    end
    result = sdr.emit(ROOT, 'fixture-mrbc', dir, log: StringIO.new)
    suite.check('unsafe stale omissions are re-proved and removed', seen == [Set['Old#unsafe'], Set.new] && result.closed.empty?)
    suite.check('only the fresh fixed point is published', LISTS.parse(File.read(path)).to_h == proven.to_h)
    File.write(path, LISTS.dump(LISTS::Lists.new(**proven.to_h, digest: 'old-inputs')))
    seen.clear
    sdr.emit(ROOT, 'fixture-mrbc', dir, log: StringIO.new)
    suite.check('an unchanged stale seed settles in one proof pass', seen == [Set.new])
    seen.clear
    sdr.emit(ROOT, 'fixture-mrbc', dir, log: StringIO.new)
    suite.check('a current exact hit needs no proof passes', seen.empty?)
  end
ensure
  saved.each { |name, method| sdr.define_singleton_method(name, method) }
end

# INDEX_CLOSED admission (tools/bc2cpp/index_closed_planner.rb): a planner-proven
# `[]` / `[]=` passes eligible() despite failing IDENT, while an unproven
# operator and an unproven identifier do not. `proven` is the per-name verdict
# analyze() computes; here it is stubbed to pin the gate mechanics.
analysis = lambda do |proven|
  { registered: [{ owner: 'Game::Variables', name: '[]', entry: 'e1' },
                 { owner: 'Game::Variables', name: '[]=', entry: 'e2' },
                 { owner: 'Game::Variables', name: 'kept', entry: 'e3' },
                 { owner: 'Game::Variables', name: 'dropped', entry: 'e4' }],
    closed_only: true, dynamic: Set['dropped'], fragments: Set.new,
    suffix_bases: nil, symbol_lookups: nil, proven: proven }
end
full = sdr.eligible(analysis.call({ '[]' => true, '[]=' => true })).to_set { |m| "#{m[:owner]}##{m[:name]}" }
suite.check('a proven operator passes eligible() despite failing IDENT',
            full == Set['Game::Variables#[]', 'Game::Variables#[]=', 'Game::Variables#kept'])
none = sdr.eligible(analysis.call({})).to_set { |m| "#{m[:owner]}##{m[:name]}" }
suite.check('without the verdict operators stay dynamic', none == Set['Game::Variables#kept'])
partial = sdr.eligible(analysis.call({ '[]' => true, '[]=' => false })).to_set { |m| "#{m[:owner]}##{m[:name]}" }
suite.check('a refused operator stays dynamic', partial == Set['Game::Variables#[]', 'Game::Variables#kept'])

# CORE_NATIVE_CANDIDATES: the same verdict admits proven operators to the ROM
# and RAM candidate lists.
cnc = CoreNativeCandidates
rom = [{ mt_class: 'Array', kind: 'OPSYM', cname: 'aref', name: '[]', fn: 'mrb_ary_aget', path: 'p', installed: 'Array' },
       { mt_class: 'Array', kind: 'SYM', cname: 'freeze', name: 'freeze', fn: 'f', path: 'p', installed: 'Array' }]
suite.check('a proven operator is a ROM candidate, an unproven dynamic name is not',
            cnc.candidates(rom, Set['freeze'], Set.new, { '[]' => true }) == ['Array#[]'])
suite.check('without the verdict no operator is a ROM candidate',
            cnc.candidates(rom, Set.new, Set.new, {}) == [])

SOURCE = <<~'RUBY'
  class VFix
    def kept = 1
    def pruned = 2
    def closed_only = 3
    def core_only = 4
  end
RUBY
ENTRIES = [
  { owner: 'VFix', name: 'kept', entry: 'vfix_kept', aspec: 'MRB_ARGS_NONE()', visibility: :public },
  { owner: 'VFix', name: 'pruned', entry: 'vfix_pruned', aspec: 'MRB_ARGS_NONE()', visibility: :public },
  { owner: 'VFix', name: 'closed_only', entry: 'vfix_closed_only', aspec: 'MRB_ARGS_NONE()', visibility: :public },
  { owner: 'VFix', name: 'core_only', entry: 'vfix_core_only', aspec: 'MRB_ARGS_NONE()', visibility: :public }
].freeze

# The registration code a generation emits with OUT_SYMBOL, BUILD_NAME and lists variable as given.
generate = lambda do |out_symbol:, build: 'closed', lists_value: nil|
  saved = ENV.to_h.slice('OUT_SYMBOL', 'BC2CPP_BUILD_NAME', LISTS::PATH_ENV)
  ENV['OUT_SYMBOL'] = out_symbol
  ENV['BC2CPP_BUILD_NAME'] = build
  lists_value ? ENV[LISTS::PATH_ENV] = lists_value : ENV.delete(LISTS::PATH_ENV)
  LISTS.reset!
  suite.compile(SOURCE) do |ireps, root|
    registry = build_registry(ireps, root)[0]
    CodeGen.new(ireps, registry, {}, {}, {}, {}, {}, {}, {}, {}, {}, Set.new).emit_owner_registrations(ENTRIES, %w[VFix])
  end
ensure
  %w[OUT_SYMBOL BC2CPP_BUILD_NAME].each { |key| ENV.delete(key) }
  ENV.delete(LISTS::PATH_ENV)
  saved.each { |key, value| ENV[key] = value }
  LISTS.reset!
end

Dir.mktmpdir('static_dispatch_lists') do |dir|
  path = File.join(dir, 'lists.json')
  File.write(path, LISTS.dump(LISTS::Lists.new(open: Set['VFix#pruned'], closed: Set['VFix#pruned', 'VFix#closed_only'],
                                               core_excluded: Set.new, core_left_out: Set['VFix#core_only'], digest: 'x')))
  suite.check("a compiled gem's OUT_SYMBOL with no lists stops the generation, naming the command",
              (begin
                 generate.call(out_symbol: 'rgss_compiled')
                 false
               rescue LISTS::Missing => e
                 e.message.include?('static_dispatch_registrations.rb --emit')
               end))
  all = generate.call(out_symbol: 'rgss_compiled', lists_value: 'none')
  suite.check("'none' registers every entry",
              %w[vfix_kept vfix_pruned vfix_closed_only vfix_core_only].all? { |entry| all.include?("#{entry}, MRB_ARGS_NONE())") })
  closed = generate.call(out_symbol: 'rgss_compiled', lists_value: path)
  suite.check("the closed build drops the closed set's names", !closed.include?('vfix_pruned') &&
                                                              !closed.include?('vfix_closed_only') && closed.include?('vfix_kept, MRB_ARGS_NONE())'))
  suite.check('the closed build also drops listed core Ruby entries', !closed.include?('vfix_core_only'))
  other = generate.call(out_symbol: 'rgss_compiled', build: 'other', lists_value: path)
  suite.check("another build drops only the open set's names", !other.include?('vfix_pruned') &&
                                                              other.include?('vfix_closed_only, MRB_ARGS_NONE())'))
  suite.check('other builds retain listed core Ruby entries', other.include?('vfix_core_only, MRB_ARGS_NONE())'))
  fixture = generate.call(out_symbol: 'a_fixture')
  suite.check('a fixture with no lists registers every entry and is not stopped',
              %w[vfix_kept vfix_pruned vfix_closed_only vfix_core_only].all? { |entry| fixture.include?("#{entry}, MRB_ARGS_NONE())") })
end

suite.finish!
