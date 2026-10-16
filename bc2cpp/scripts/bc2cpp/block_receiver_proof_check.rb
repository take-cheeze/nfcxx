#!/usr/bin/env ruby
# encoding: UTF-8
# Receivers of block-taking sends that stay procs (BLOCK_FALLBACK): the two
# proofs added for them.
#   CHAINED_ARRAY_RECURSION: a block-carrying select/reject whose receiver is
#   itself a fresh Array by proven_array_source_scan (`[x].select { }.reject { }`)
#   is an Array; a Hash#select chain is not.
#   SELF_ACCESSOR_RECEIVER: an implicit-self attr_reader call (`elems.each`)
#   answers like a GETIV of the ivar, but only when self's class is exact and
#   registers the reader itself.

require 'tmpdir'
require_relative '../../tools/bc2cpp/bc2cpp'

SRC = <<~'RUBY'
  class Elem
    def zork; 1; end
  end
  class Chains
    def array_chain; [Elem.new].select { |e| e }.reject { |e| e.nil? }.each { |e| e.zork }; end
    def hash_chain; { a: 1 }.select { |k, v| v }.reject { |k, v| v.nil? }.each { |k, v| v }; end
    def unknown_chain(x); x.select { |e| e }.reject { |e| e.nil? }.each { |e| e.zork }; end
  end
  class Holder
    attr_reader :elems
    def initialize; @elems = [Elem.new]; end
    def run; elems.each { |e| e.zork }; end
    def run_chained; elems.reject { |e| e.nil? }.each { |e| e.zork }; end
  end
  class Base
    attr_reader :elems
    def initialize; @elems = [Elem.new]; end
    def run; elems.each { |e| e.zork }; end
  end
  class Sub < Base
    def elems; nil; end
  end
  class Reader
    def initialize; @elems = [Elem.new]; end
    def elems; @elems; end
    def run; elems.each { |e| e.zork }; end
  end
RUBY

failures = []
check = lambda do |what, actual, expected|
  if actual == expected
    puts "  ok  #{what}"
  else
    puts "  FAIL #{what}: expected #{expected.inspect}, got #{actual.inspect}"
    failures << what
  end
end

# The last SENDB :each of a method, as [irep, index, receiver register].
last_each = lambda do |ireps, registry, owner, name|
  md = registry.fetch(name).find { |d| d.owner == owner }
  irep = ireps.fetch(md.irep)
  idx = irep.instructions.rindex { |insn| insn.op == 'SENDB' && insn.sym == 'each' }
  [irep, idx, irep.instructions[idx].reg]
end

Dir.mktmpdir do |dir|
  source = File.join(dir, 'block_receivers.rb')
  File.write(source, SRC)
  ireps, root_label = compile_ireps(source, 'bc2cpp_block_receivers', dir)
  registry = build_registry(ireps, root_label)[0]

  irep, idx, reg = last_each.call(ireps, registry, 'Chains', 'array_chain')
  check.call('select/reject chain on an Array literal proves an Array',
             proven_array_source_scan(irep, idx, reg, registry), 'Array')
  irep, idx, reg = last_each.call(ireps, registry, 'Chains', 'hash_chain')
  check.call('select/reject chain on a Hash literal stays unproven (Hash#select keeps the Hash)',
             proven_array_source_scan(irep, idx, reg, registry), nil)
  irep, idx, reg = last_each.call(ireps, registry, 'Chains', 'unknown_chain')
  check.call('select/reject chain on an untyped argument stays unproven',
             proven_array_source_scan(irep, idx, reg, registry), nil)

  class_layout = { 'Holder' => { 'elems' => 'Array' }, 'Base' => { 'elems' => 'Array' },
                   'Reader' => { 'elems' => 'Array' } }
  element_layout = { 'Holder' => { 'elems' => 'Elem' }, 'Base' => { 'elems' => 'Elem' },
                     'Reader' => { 'elems' => 'Elem' } }
  superclass_of = { 'Sub' => 'Base' }
  gen = CodeGen.new(ireps, registry, {}, class_layout, {}, {}, superclass_of, element_layout, {}, {}, {}, Set.new)

  irep, idx, reg = last_each.call(ireps, registry, 'Holder', 'run')
  check.call('self attr_reader on an exact class reads the ivar class',
             gen.block_fallback_receiver_class(irep, idx, reg, 'Holder'), 'Array')
  check.call('self attr_reader on an exact class reads the ivar element class',
             gen.proven_element_class(irep, idx, reg, class_layout['Holder'], 0, nil, 'Holder'), 'Elem')
  irep, idx, reg = last_each.call(ireps, registry, 'Holder', 'run_chained')
  check.call('reject on a self attr_reader proves an Array with the method owner',
             gen.proven_array_source(irep, idx, reg, owner: 'Holder'), 'Array')
  check.call('reject on a self attr_reader stays unproven without the owner',
             gen.proven_array_source(irep, idx, reg), nil)

  irep, idx, reg = last_each.call(ireps, registry, 'Base', 'run')
  check.call('self attr_reader on a subclassed class stays unproven (a subclass overrides it)',
             gen.block_fallback_receiver_class(irep, idx, reg, 'Base'), nil)
  check.call('self attr_reader element on a subclassed class stays unproven',
             gen.proven_element_class(irep, idx, reg, class_layout['Base'], 0, nil, 'Base'), nil)

  irep, idx, reg = last_each.call(ireps, registry, 'Reader', 'run')
  check.call('a hand-written reader is not an attr_reader (its body could return anything)',
             gen.block_fallback_receiver_class(irep, idx, reg, 'Reader'), nil)
end

if failures.empty?
  puts 'block receiver proof: all checks passed'
else
  abort "block receiver proof: #{failures.size} failure(s)"
end
