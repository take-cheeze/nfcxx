#!/usr/bin/env ruby
# frozen_string_literal: true

# RECORD_HASH_PROOF: `@slot.update({...})` / `merge!` as one store per pair of a fresh Symbol-keyed literal,
# on compiled fixtures. A block, a non-literal or aliased argument, or a Ruby redefinition keeps the slot refused.
#
#   MRBC=path/to/mrbc ruby scripts/bc2cpp/record_hash_update_check.rb
require 'set'
require_relative '../../tools/bc2cpp/irep'
require_relative '../../tools/bc2cpp/record_hash'
require_relative 'check_support'

suite = FixtureCheck.new('record_hash_update_check')
check = suite.method(:check)
suite.require_mrbc!

# +redefined+: names a foreign Ruby source defines on Hash; +installed+: names a computed installer can define.
World = Struct.new(:redefined, :installed) do
  def global_refusal = nil
  def core_ruby_arm_safe?(name, _owner) = !redefined.include?(name)
  def instance_unknown_def?(name) = installed.include?(name)
end

long_pairs = (1..40).map { |i| "k#{i}: #{i}" }.join(', ')
source = <<~RUBY
  class Scene
    def initialize
      @ui = {}
      @big = {}
      @merged = {}
      @blocked = {}
      @copied = {}
      @aliased = {}
    end

    def start(troop)
      @ui.update({ phase: :command, list: [], troop: troop })
      @big.update({ #{long_pairs} })
      @merged.merge!({ count: 1 })
      @blocked.update({ a: 1 }) { |_k, old, _new| old }
      @copied.update(troop)
      t = { a: 1 }
      @aliased.update(t)
    end

    def go
      (@ui[:list] || []).each { |x| x }
      @big[:k40]
      @merged[:count]
    end
  end
RUBY

suite.compile(source) do |ireps, _root, _directory|
  sites = Hash.new { |h, k| h[k] = { sets: [], gets: [], calls: [] } }
  ireps.each_value do |irep|
    irep.each_with_op('SETIV', 'GETIV') do |insn, i|
      sites[insn.ivar][insn.op == 'SETIV' ? :sets : :gets] << [irep, i] if insn.ivar
    end
  end
  scan = lambda do |name, registry: {}, redefined: Set.new, installed: Set.new|
    RecordHash::Scanner.new(name, sites[name], nil, World.new(redefined, installed), registry).run
  end
  strict = ->(slot, key) { slot.is_a?(RecordHash::Slot) ? slot.keys.fetch(key, {})[:strict] : slot }

  ui = scan.call('ui')
  check.call('update of a fresh literal proves the slot', ui.is_a?(RecordHash::Slot))
  check.call('a key only update stores is its literal class or nil', strict.call(ui, 'list') == Set['Array', 'NilClass'])
  check.call('a Symbol literal value keeps its class', strict.call(ui, 'phase') == Set['Symbol', 'NilClass'])
  check.call('an argument value is unknown, not a refusal', strict.call(ui, 'troop')&.include?(:unknown))

  big = scan.call('big')
  check.call('a long literal split into HASHADD chunks proves every pair',
             big.is_a?(RecordHash::Slot) && big.keys.size == 40 && strict.call(big, 'k40') == Set['Integer', 'NilClass'])
  check.call('merge! is the same store', strict.call(scan.call('merged'), 'count') == Set['Integer', 'NilClass'])

  check.call('update with a block refuses', scan.call('blocked').to_s.include?('operand of SENDB'))
  check.call('update of a non-literal refuses', scan.call('copied').to_s.include?('not a fresh Hash literal'))
  check.call('update of a literal held in a local refuses', scan.call('aliased').to_s.include?('not a fresh Hash literal'))

  ruby_update = MethodDef.new(name: 'update', owner: 'Hash', core: false)
  check.call('a Ruby Hash#update refuses', scan.call('ui', registry: { 'update' => [ruby_update] }).to_s.include?('may be redefined'))
  core_update = MethodDef.new(name: 'update', owner: 'Hash', core: true)
  check.call('the core Hash#update is admitted', scan.call('ui', registry: { 'update' => [core_update] }).is_a?(RecordHash::Slot))
  check.call('a foreign Ruby Hash#merge! refuses', scan.call('ui', redefined: Set['merge!']).to_s.include?('may be redefined'))
  check.call('a computed installer of __merge refuses', scan.call('ui', installed: Set['__merge']).to_s.include?('may be redefined'))
  other_update = MethodDef.new(name: 'update', owner: 'RPG2k::Window', core: false)
  check.call('an update on an unrelated class is admitted',
             scan.call('ui', registry: { 'update' => [other_update] }).is_a?(RecordHash::Slot))

  ENV['BC2CPP_RECORD_HASH_UPDATE'] = '0'
  check.call('BC2CPP_RECORD_HASH_UPDATE=0 restores the escape', scan.call('ui').to_s.include?('operand of SEND'))
  ENV.delete('BC2CPP_RECORD_HASH_UPDATE')
end

suite.finish!
