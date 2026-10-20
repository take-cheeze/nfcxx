#!/usr/bin/env ruby
# frozen_string_literal: true

# Checks the TC1017 constant ratchet (docs/adr/0491, 0522, tools/bc2cpp/constant_reviewed.rb): an untyped engine
# constant needs a `# bc2cpp-reviewed: constant <Name>` annotation on its line or the line above, and an annotation
# that no longer matches an untyped engine constant is stale.
#
#   - fixtures (no compiler): the gate on synthetic constant rows and temporary source files;
#   - with MRBC (a host mrbc, the closed build makes one): the engine's own type check must pass the gate.
#
#   ruby scripts/bc2cpp/constant_reviewed_check.rb            # fixtures only
#   MRBC=path/to/host/mrbc ruby scripts/bc2cpp/constant_reviewed_check.rb
require 'fileutils'
require 'json'
require 'tmpdir'
require_relative '../../tools/bc2cpp/constant_reviewed'

failures = []
check = lambda do |name, ok|
  puts "  #{ok ? 'ok  ' : 'FAIL'} #{name}"
  failures << name unless ok
end

puts '== fixtures'
Dir.mktmpdir('constant_reviewed_check') do |root|
  FileUtils.mkdir_p(File.join(root, 'mruby-rpg2k'))
  src = File.join(root, 'mruby-rpg2k', 'k.rb')
  File.write(src, <<~RUBY)
    module K
      # bc2cpp-reviewed: constant K::A -- read: a menu colour
      A = 1
      B = 2
      # bc2cpp-reviewed: constant K::C -- read
      C = 3
    end
  RUBY
  row = ->(name, line, type: nil, scope: 'engine') do
    { 'name' => name, 'file' => 'mruby-rpg2k/k.rb', 'line' => line, 'col' => 1, 'scope' => scope, 'type' => type,
      'source' => 'literal' }
  end

  check.call('an annotated untyped constant passes', ConstantReviewed.violations([row.call('K::A', 3)], root: root)
                                                          .none? { |v| v[:message].include?('K::A') && v[:message].include?('no type') })
  check.call('an unannotated untyped constant is a violation',
             ConstantReviewed.violations([row.call('K::B', 4)], root: root).any? { |v| v[:message].include?('K::B') })
  check.call('a typed row is never a violation for lacking an annotation',
             ConstantReviewed.violations([row.call('K::B', 4, type: 'Integer')], root: root).none? { |v| v[:message].include?('no type') })
  stale = ConstantReviewed.violations([row.call('K::A', 3, type: 'Integer'), row.call('K::C', 6)], root: root)
  check.call('an annotation on a typed constant is stale',
             stale.any? { |v| v[:message].include?('K::A') && v[:message].include?('is typed') })
  check.call('an annotation on a constant that is not in the program is stale',
             ConstantReviewed.violations([row.call('K::A', 3)], root: root).any? { |v| v[:message].include?('K::C') &&
               v[:message].include?('not an engine constant') })
  check.call('a non-engine row is not judged',
             ConstantReviewed.violations([row.call('K::B', 4, scope: 'core')], root: root).none? { |v| v[:message].include?('K::B') })
  check.call('the sites of the dump are the untyped engine rows, at their absolute paths',
             ConstantReviewed.sites([row.call('K::B', 4), row.call('K::A', 3, type: 'Integer')], root: root) ==
             [{ gate: 'constant', spec: 'K::B', file: src, line: 4 }])
end

puts '== engine run'
mrbc = ENV['MRBC']
if mrbc.to_s.empty?
  puts '  (MRBC unset: the engine check is skipped)'
else
  require_relative '../../tools/bc2cpp/type_check_run'
  root = ConstantReviewed::ROOT
  facts = Dir.mktmpdir('constant_reviewed') do |dir|
    result = TypeCheckRun.run(root: root, mrbc: mrbc, workdir: dir, sends: false)
    JSON.parse(File.read(result.facts_path))
  end
  abort 'constant_reviewed_check: the analysis produced no constants' if facts['constants'].empty?

  violations = ConstantReviewed.violations(facts['constants'], root: root)
  check.call("the engine's untyped constants are all annotated and no annotation is stale (#{violations.size} violation(s))",
             violations.empty?)
  violations.first(20).each { |v| puts "    #{v[:file]}:#{v[:line]}: #{v[:message]}" }
end

puts
if failures.empty?
  puts 'constant_reviewed_check: ok'
else
  abort "constant_reviewed_check: #{failures.size} failure(s): #{failures.join('; ')}"
end
