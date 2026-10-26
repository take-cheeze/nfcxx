#!/usr/bin/env ruby
# frozen_string_literal: true

require_relative '../../../tools/bc2cpp/irep'
require_relative '../../../tools/bc2cpp/ir_yield_types'

check = lambda do |label, condition|
  raise label unless condition

  puts "ok #{label}"
end
source = <<~SOURCE
  class YieldCases
    def twice(value); yield value; yield 1; end
    def effect(value); @state = value; yield value; end
    def splat(value); yield(*value); end
    def unknown(value); yield value.unknown; end
    def two(value); yield value, 1; end
    def escape(value, &block); @callback = block; yield value; end
    def caller; twice(:tag) { |item| item }; end
    def declared_caller(value); twice(value) { |item| item }; end
    def effect_caller; effect(:tag) { |item| item }; end
    def splat_caller; splat([1]) { |item| item }; end
    def unknown_caller; unknown(:tag) { |item| item }; end
    def wrong_arity; two(:tag) { |item| item }; end
    def escape_caller; escape(:tag) { |item| item }; end
  end
SOURCE
Bc2cppIrBlockFixtures.compile(source, 'yields') do |ireps, _root|
  methods = {}
  ireps.each_value do |body|
    body.instructions.each do |insn|
      methods[insn.sym] = ireps[body.reps[insn.block_index.to_i]] if insn.op == :TDEF
    end
  end
  target = Struct.new(:owner, :name, :irep)
  gen = Object.new
  gen.define_singleton_method(:bytecode_ir_argument_receiver_classes) { |*| Set[:YieldCases] }
  gen.define_singleton_method(:closed_world_exact_target) { |name, _receiver| methods[name] && target.new('YieldCases', name, methods[name].label) }
  ctx = Struct.new(:gen, :ireps).new(gen, ireps)
  summarize = lambda do |name|
    body = methods.fetch(name)
    position = body.instructions.index { |insn| %i[SENDB SSENDB].include?(insn.op) }
    IrYieldTypes.summarize(ctx, body, position, BytecodeIR::Types.new(body))
  end
  summary = summarize.call('caller')
  check.call('multiple direct yields union their independent argument classes', summary && summary.arguments[1].classes == Set[:Symbol, :Integer])
  check.call('independent yields carry no RBS assumptions', summary && !summary.arguments[1].declared? && summary.arguments[1].contracts.empty?)
  %w[effect_caller splat_caller unknown_caller wrong_arity escape_caller].each do |name|
    check.call("unsafe or unsupported #{name} refuses its protocol", summarize.call(name).nil?)
  end
  declared_body = methods.fetch('declared_caller')
  declared_position = declared_body.instructions.index { |insn| %i[SENDB SSENDB].include?(insn.op) }
  actual = BytecodeIR::Types::Fact.new(classes: Set[:String], declared: true, contracts: ['fixture:argument'])
  declared = IrYieldTypes.summarize(ctx, declared_body, declared_position, BytecodeIR::Types.new(declared_body, argument_facts: { 1 => actual }))
  check.call('yielded caller contract preserves conditional provenance', declared && declared.arguments[1].declared? && declared.arguments[1].contracts == ['fixture:argument'] && declared.arguments[1].classes == Set[:String, :Integer])
  gen.define_singleton_method(:closed_world_exact_target) { |*| nil }
  check.call('unproven method identity refuses a literal-looking protocol', summarize.call('caller').nil?)
end
puts 'yield protocol checks passed'
