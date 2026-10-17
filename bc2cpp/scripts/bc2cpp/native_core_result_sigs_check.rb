#!/usr/bin/env ruby
# frozen_string_literal: true

# NativeCoreResultSigs (sig/bc2cpp/core_results.rbs) replaces the hand-written EXACT_CORE_KINDS table. Host only:
# the loaded table must equal the audited entries, and malformed signature files must fail loudly.
require 'set'
require 'tmpdir'
require_relative '../../tools/bc2cpp/native_core_result_sigs'
require_relative '../../tools/bc2cpp/core_hierarchy_sigs'
require_relative '../../tools/bc2cpp/native_result_facts'
require_relative '../../tools/bc2cpp/core_block_param_sigs'

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

AUDITED_RGSS = {
  'RGSS::Bitmap' => { 'width' => :fixnum, 'height' => :fixnum, 'rect' => 'RGSS::Rect', 'text_size' => 'RGSS::Rect' },
  'RGSS::Rect' => { 'x' => :fixnum, 'y' => :fixnum, 'width' => :fixnum, 'height' => :fixnum },
  'RGSS::Color' => { 'red' => :float, 'green' => :float, 'blue' => :float, 'alpha' => :float },
  'RGSS::Tone' => { 'red' => :float, 'green' => :float, 'blue' => :float, 'gray' => :float }
}.freeze
check.call('RGSS result kinds equal the audited map', NativeResultFacts::KINDS == AUDITED_RGSS)

# CORE_BLOCK_ELEMENT_HINT (sig/bc2cpp/core_block_params.rbs): where a core iterator's block gets an element.
def rejects_block_params(text)
  Dir.mktmpdir do |dir|
    path = File.join(dir, 'b.rbs')
    File.write(path, text)
    CoreBlockParamSigs.load_shapes(path)
    false
  rescue RuntimeError
    true
  end
end

shapes = CoreBlockParamSigs.shapes
shape_of = ->(klass, name) { shapes[[klass, name]]&.to_h&.slice(:argc, :arity, :elements) }
check.call('block shapes: Array#each yields the element to a one-parameter block',
           shape_of.call('Array', 'each') == { argc: 0..0, arity: 1, elements: [0] })
check.call('block shapes: Array#inject passes the element second, with or without an initial value',
           shape_of.call('Array', 'inject') == { argc: 0..1, arity: 2, elements: [1] })
check.call('block shapes: Array#sort passes two elements',
           shape_of.call('Array', 'sort') == { argc: 0..0, arity: 2, elements: [0, 1] })
check.call('block shapes: Array#each_with_object takes its memo and passes the element first',
           shape_of.call('Array', 'each_with_object') == { argc: 1..1, arity: 2, elements: [0] })
check.call('block shapes: Hash#each passes the value second, Hash#each_key no element',
           shape_of.call('Hash', 'each') == { argc: 0..0, arity: 2, elements: [1] } &&
             shape_of.call('Hash', 'each_key') == { argc: 0..0, arity: 1, elements: [] })
check.call('block shapes: the table is frozen', shapes.frozen? && shapes.values.all?(&:frozen?))
check.call('block shapes: rejects a non-container class', rejects_block_params("class String[E]\n  def each: () { (E) -> void } -> untyped\nend\n"))
check.call('block shapes: rejects a container without its element parameter',
           rejects_block_params("class Array\n  def each: () { (untyped) -> void } -> untyped\nend\n"))
check.call('block shapes: rejects a method without a required block',
           rejects_block_params("class Array[Elem]\n  def each: () ?{ (Elem) -> void } -> untyped\nend\n"))
check.call('block shapes: rejects an optional block parameter',
           rejects_block_params("class Array[Elem]\n  def each: () { (Elem, ?untyped) -> void } -> untyped\nend\n"))
check.call('block shapes: rejects an overloaded method',
           rejects_block_params("class Array[Elem]\n  def each: () { (Elem) -> void } -> untyped\n    | () -> untyped\nend\n"))

puts failures.empty? ? 'native core result sigs: all checks passed' : "native core result sigs: #{failures.size} failure(s)"
exit(failures.empty? ? 0 : 1)
