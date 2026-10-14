#!/usr/bin/env ruby
# frozen_string_literal: true

# NativeCoreResultSigs (sig/native/core_results.rbs) replaces the hand-written EXACT_CORE_KINDS table. Host only:
# the loaded table must equal the audited entries, and malformed signature files must fail loudly.
require 'set'
require 'tmpdir'
require_relative '../../tools/bc2cpp/native_core_result_sigs'
require_relative '../../tools/bc2cpp/core_hierarchy_sigs'

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

def rejects_fresh(text)
  Dir.mktmpdir do |dir|
    path = File.join(dir, 'fresh.rbs')
    File.write(path, text)
    NativeCoreResultSigs.fresh_array_names(path)
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

check.call('fresh-array names equal the audited list',
           NativeCoreResultSigs.fresh_array_names == Set[*%w[keys values compact flatten split uniq]])
check.call('fresh-array file rejects a non-Array return', rejects_fresh("class Hash\n  def keys: () -> String\nend\n"))

AUDITED_SUPER = {
  'BasicObject' => nil, 'Object' => 'BasicObject', 'Module' => 'Object', 'Class' => 'Module',
  'NilClass' => 'Object', 'TrueClass' => 'Object', 'FalseClass' => 'Object', 'Numeric' => 'Object',
  'Integer' => 'Numeric', 'Float' => 'Numeric', 'String' => 'Object', 'Symbol' => 'Object',
  'Array' => 'Object', 'Hash' => 'Object', 'Range' => 'Object', 'Proc' => 'Object',
  'Exception' => 'Object', 'StandardError' => 'Exception', 'Struct' => 'Object'
}.freeze
AUDITED_MIXINS = {
  'Object' => %w[Kernel], 'Numeric' => %w[Comparable], 'String' => %w[Comparable],
  'Symbol' => %w[Comparable], 'Array' => %w[Enumerable], 'Hash' => %w[Enumerable],
  'Range' => %w[Enumerable], 'Struct' => %w[Enumerable]
}.freeze

def rejects_hierarchy(text)
  Dir.mktmpdir do |dir|
    path = File.join(dir, 'h.rbs')
    File.write(path, text)
    CoreHierarchySigs.load(path)
    false
  rescue RuntimeError
    true
  end
end

hierarchy_super, hierarchy_mixins = CoreHierarchySigs.load
check.call('hierarchy superclasses equal the audited map, in order', hierarchy_super == AUDITED_SUPER && hierarchy_super.keys == AUDITED_SUPER.keys)
check.call('hierarchy mixins equal the audited map', hierarchy_mixins == AUDITED_MIXINS)
check.call('rejects a class without a superclass line', rejects_hierarchy("class Foo\nend\n"))
check.call('rejects a class declared twice', rejects_hierarchy("class Foo < Object\nend\nclass Foo < Object\nend\n"))

puts failures.empty? ? 'native core result sigs: all checks passed' : "native core result sigs: #{failures.size} failure(s)"
exit(failures.empty? ? 0 : 1)
