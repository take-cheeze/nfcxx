#!/usr/bin/env ruby
# frozen_string_literal: true

require 'tmpdir'
require_relative '../../tools/bc2cpp/ir_rbs_block_types'

def check(label, condition)
  raise label unless condition

  puts "ok #{label}"
end

def fact(*classes)
  BytecodeIR::Types::Fact.new(classes: classes.to_set.freeze, declared: true, contracts: ['fixture'].freeze).freeze
end

Dir.mktmpdir('ir-rbs-block') do |dir|
  File.write(File.join(dir, 'callback.rbs'), <<~RBS)
    class Callback
      def transform: [T, U] (Array[T]) { (T) -> U } -> Array[U]
      def concrete: () { (String) -> Integer } -> Integer
      def bounded: [T < Numeric] (T) { (T) -> T } -> T
      def unknown: [T] () { (T) -> T } -> T
      def numeric: () { (String) -> Numeric } -> Numeric
      def optional: (?String) { (String) -> Integer } -> Integer
      def unsupported: () { (*String) -> Integer } -> Integer
    end
  RBS
  loaded = RbsSignatures.load([dir])
  check('valid callback signatures parse', loaded.diagnostics.none? { |diag| diag.severity == 'error' })
  binding = IrRbsBlockTypes.bind(loaded.methods.fetch(['Callback', 'transform']), arguments: [fact(:Array)], argument_elements: [fact(:String)])
  check('Array[T] binds callback T', binding.argument_facts.first.classes == Set[:String])
  check('unbound callback result stays unknown before block', binding.callback_expected.nil?)
  result = binding.complete(fact(:Integer))
  check('block result binds U', result.status == :compatible && result.return_fact.classes == Set[:Array] && result.return_elements.classes == Set[:Integer])
  check('contract provenance retained', result.return_elements.declared && result.return_elements.contracts.include?('rbs-block:Callback#transform'))
  check('missing array elements refused', !IrRbsBlockTypes.bind(loaded.methods.fetch(['Callback', 'transform']), arguments: [fact(:Array)]))
  concrete = IrRbsBlockTypes.bind(loaded.methods.fetch(['Callback', 'concrete']), arguments: [])
  check('concrete callback input', concrete.argument_facts.first.classes == Set[:String])
  check('concrete callback mismatch', concrete.complete(fact(:Symbol)).status == :mismatch)
  check('unknown block return is not inferred', concrete.complete(nil).status == :unknown)
  check('unbound generic input refused', !IrRbsBlockTypes.bind(loaded.methods.fetch(['Callback', 'unknown']), arguments: []))
  numeric = IrRbsBlockTypes.bind(loaded.methods.fetch(['Callback', 'numeric']), arguments: [])
  check('subtype without hierarchy stays unknown', numeric.complete(fact(:Integer)).status == :unknown)
  check('caller hierarchy can validate subtype', numeric.complete(fact(:Integer), compatible: ->(_actual, _expected) { true }).status == :compatible)
  check('optional invocation shape refused', !IrRbsBlockTypes.bind(loaded.methods.fetch(['Callback', 'optional']), arguments: []))
  check('bounded generic refused', !IrRbsBlockTypes.bind(loaded.methods.fetch(['Callback', 'bounded']), arguments: [fact(:String)]))
  check('rest callback refused', !IrRbsBlockTypes.bind(loaded.methods.fetch(['Callback', 'unsupported']), arguments: []))
end
puts 'ir_rbs_block_types_check: ok (host-only callback binding; MRBC is not required)'
