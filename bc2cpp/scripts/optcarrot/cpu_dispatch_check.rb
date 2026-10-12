#!/usr/bin/env ruby
# frozen_string_literal: true

require_relative '../../tools/optcarrot_probe/cpu_dispatch'
require_relative '../../3rd/optcarrot/lib/optcarrot'

cpu = Class.new(Optcarrot::CPU)
cpu.const_set(:RP2A03_CC, Optcarrot::RP2A03_CC)
cpu.class_eval <<~RUBY_CODE, __FILE__, __LINE__ + 1
  def original_dispatch
    send(*DISPATCH[@opcode])
  end
RUBY_CODE
cpu.class_eval OptcarrotCPUDispatch.transform(<<~RUBY_CODE), __FILE__, __LINE__ + 1
  def static_dispatch
    send(*DISPATCH[@opcode])
  end
RUBY_CODE

# Preserve upstream wrapper bodies and observe every call they issue, including
# addressing-mode flags and store order, for official and unofficial opcodes.
wrappers = %i[r_op w_op rw_op a_op no_op]
Optcarrot::CPU::DISPATCH.flatten.grep(Symbol).uniq.each do |name|
  next if wrappers.include?(name)

  cpu.define_method(name) do |*args|
    @trace << [name, args]
    @data += 3
  end
end

256.times do |opcode|
  results = %i[original_dispatch static_dispatch].map do |method|
    instance = cpu.allocate
    { opcode: opcode, clk: 7, data: 11, _a: 19, _pc: 31, trace: [] }.each do |name, value|
      instance.instance_variable_set("@#{name}", value)
    end
    instance.public_send(method)
    %i[trace clk data _a _pc].map { |name| instance.instance_variable_get("@#{name}") }
  end
  raise "opcode #{opcode}: #{results.inspect}" unless results[0] == results[1]
end

begin
  OptcarrotCPUDispatch.transform('unrecognized upstream source')
  raise 'missing dispatch unexpectedly accepted'
rescue RuntimeError => e
  raise unless e.message == 'expected exactly one CPU dispatch splat'
end
puts 'Optcarrot CPU dispatch check: PASS (256 opcodes, call order, flags and wrapper state)'
