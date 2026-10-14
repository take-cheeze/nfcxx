#!/usr/bin/env ruby
# frozen_string_literal: true

# NativeCoreResultSigs (sig/native/core_results.rbs) replaces the hand-written EXACT_CORE_KINDS table. Host only:
# the loaded table must equal the audited entries, and malformed signature files must fail loudly.
require 'tmpdir'
require_relative '../../tools/bc2cpp/native_core_result_sigs'

failures = []
check = lambda do |name, ok|
  puts "  #{ok ? 'ok  ' : 'FAIL'} #{name}"
  failures << name unless ok
end

AUDITED = { 'Array' => { 'to_a' => 'Array', 'compact' => 'Array', 'join' => 'String' }, 'String' => { 'bytes' => 'Array' } }.freeze

def rejects(text)
  Dir.mktmpdir do |dir|
    path = File.join(dir, 'bad.rbs')
    File.write(path, text)
    NativeCoreResultSigs.load_kinds(path)
    false
  rescue RuntimeError
    true
  end
end

check.call('loaded table equals the audited entries', NativeCoreResultSigs.kinds == AUDITED)
check.call('table is frozen', NativeCoreResultSigs.kinds.frozen? && NativeCoreResultSigs.kinds['Array'].frozen?)
check.call('rejects an Integer result', rejects("class Array\n  def size: () -> Integer\nend\n"))
check.call('rejects a nil result', rejects("class Array\n  def pop: () -> nil\nend\n"))
check.call('rejects an overloaded method', rejects("class Array\n  def to_a: () -> Array[untyped]\n    | () -> String\nend\n"))
check.call('rejects a module declaration', rejects("module Kernel\n  def foo: () -> String\nend\n"))

puts failures.empty? ? 'native core result sigs: all checks passed' : "native core result sigs: #{failures.size} failure(s)"
exit(failures.empty? ? 0 : 1)
