#!/usr/bin/env ruby
# frozen_string_literal: true

# Checks tools/bc2cpp/trace_merge.rb: a proposal never repeats a declared method, a conflict is reported and not proposed,
# the proposals parse back as RBS, and the committed declarations propose nothing against themselves. Host only.
#
#   ruby scripts/bc2cpp/trace_merge_check.rb

require 'tmpdir'
require 'open3'
require 'rbconfig'
require_relative '../../tools/bc2cpp/trace_merge'

ROOT = File.expand_path('../..', __dir__)
failures = []
checks = 0
check = lambda do |what, condition|
  checks += 1
  puts "  #{condition ? 'ok  ' : 'FAIL'} #{what}"
  failures << what unless condition
end

DECLARED = <<~RBS
  class Game::Actor
    def hp: () -> Integer
    def name: () -> String
  end
RBS

CANDIDATES = <<~RBS
  class Game::Actor
    def hp: () -> Integer
    def name: () -> Integer
    def self.make: (Integer) -> Game::Actor
  end
  class Game::Party
    def size: () -> Integer
  end
  interface _Walker
    def walk: () -> untyped
  end
RBS

puts 'fixture: declared, conflicting and new candidates'
result = TraceMerge.compare(CANDIDATES, DECLARED)
proposed = result.proposed.map { |m| "#{m.owner}#{m.singleton ? '.' : '#'}#{m.name}" }
check.call('a method the declarations name is not proposed', !proposed.include?('Game::Actor#hp'))
check.call('a new singleton method is proposed', proposed.include?('Game::Actor.make'))
check.call('a new instance method of a new class is proposed', proposed.include?('Game::Party#size'))
check.call('a method declared with another signature is a conflict, not a proposal',
           result.conflicts.map { |c, _| "#{c.owner}##{c.name}" } == ['Game::Actor#name'] && !proposed.include?('Game::Actor#name'))
check.call('the same signature is counted as already declared', result.same.map(&:name) == ['hp'])
check.call('an interface is counted, not proposed', result.skipped_interfaces == 1)

puts 'fixture: the proposals parse back and render deterministically'
text = TraceMerge.render(result.proposed)
back = TraceMerge.members(text).first.map { |m| [m.owner, m.singleton, m.name] }.sort
check.call('the rendered proposals parse back to the same members',
           back == result.proposed.map { |m| [m.owner, m.singleton, m.name] }.sort)
check.call('rendering twice gives the same text', TraceMerge.render(result.proposed) == text)

puts 'fixture: the committed declarations propose nothing against themselves'
committed = File.read(File.join(ROOT, 'sig/bc2cpp/declarations.rbs'))
self_result = TraceMerge.compare(committed, committed)
check.call('no proposals, and every method is already declared',
           self_result.proposed.empty? && self_result.conflicts.empty? && self_result.same.size.positive?)

puts 'fixture: the CLI refuses an output under sig/'
Dir.mktmpdir('trace-merge-check') do |dir|
  cand = File.join(dir, 'candidates.rbs')
  File.write(cand, CANDIDATES)
  decl = File.join(dir, 'declarations.rbs')
  File.write(decl, DECLARED)
  out, err, status = Open3.capture3(RbConfig.ruby, File.join(ROOT, 'scripts/bc2cpp/trace_merge.rb'), cand, decl,
                                    '--out', File.join(ROOT, 'sig/trace_proposals.rbs'))
  check.call('an output under sig/ is refused', !status.success? && err.include?('must not be under sig/'))
  check.call('the refused run wrote nothing under sig/', !File.exist?(File.join(ROOT, 'sig/trace_proposals.rbs')))
  out2, _err2, status2 = Open3.capture3(RbConfig.ruby, File.join(ROOT, 'scripts/bc2cpp/trace_merge.rb'), cand, decl,
                                        '--out', File.join(dir, 'proposals.rbs'))
  check.call('a valid run writes the proposals and reports the counts', status2.success? && out2.include?('2 proposed'))
end

if failures.empty?
  puts "trace merge check: #{checks} checks passed"
else
  warn "trace merge check: #{failures.size} of #{checks} failed"
  exit 1
end
