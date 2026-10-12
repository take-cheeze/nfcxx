#!/usr/bin/env ruby
# frozen_string_literal: true

require_relative '../../tools/bc2cpp/call_context_arguments'

Insn = Struct.new(:op, :enter_fields)
Body = Struct.new(:enter, :instructions)
def body(fields, jumps = fields[1] + 1)
  enter = Insn.new('ENTER', fields)
  Body.new(enter, [enter] + Array.new(jumps) { Insn.new('JMP', nil) } + [Insn.new('RETURN', nil)])
end

def check(name, condition)
  abort "FAIL: #{name}" unless condition
  puts "ok: #{name}"
end

m = NumericFlow
optional = body([1, 2, 0, 0, 0, 0, 0, 0])
[[[m::STR], [m::STR, m::OTHER, m::OTHER], 1],
 [[m::STR, m::ARR], [m::STR, m::ARR, m::OTHER], 2],
 [[m::STR, m::ARR, m::HSH], [m::STR, m::ARR, m::HSH], 3]].each do |args, masks, slot|
  bound = CallContextArguments.bind(optional, args)
  check("optional #{args.size}", bound&.masks == masks && bound.enter_edges == { 0 => [slot] })
end
check('too few raises', CallContextArguments.bind(optional, []).nil?)
check('too many raises', CallContextArguments.bind(optional, [m::STR] * 4).nil?)
rest = body([1, 1, 1, 1, 0, 0, 0, 0])
[[[m::STR, m::HSH], [m::STR, m::OTHER, m::ARR, m::HSH]],
 [[m::STR, m::RNG, m::HSH], [m::STR, m::RNG, m::ARR, m::HSH]],
 [[m::STR, m::RNG, m::OTHER, m::HSH], [m::STR, m::RNG, m::ARR, m::HSH]]].each do |args, masks|
  check("rest/post #{args.size}", CallContextArguments.bind(rest, args)&.masks == masks)
end
check('rest still needs mandatory', CallContextArguments.bind(rest, [m::STR]).nil?)
check('missing jump slot refuses', CallContextArguments.bind(body([1, 2, 0, 0, 0, 0, 0, 0], 2), [m::STR]).nil?)
(4..7).each do |field|
  fields = [1, 0, 0, 0, 0, 0, 0, 0]
  fields[field] = 1
  check("unsupported field #{field}", CallContextArguments.bind(body(fields), [m::STR]).nil?)
end
ENV['BC2CPP_CONTEXT_ARGUMENT_SHAPES'] = '0'
check('switch refuses optional', CallContextArguments.bind(optional, [m::STR]).nil?)
check('switch keeps mandatory', CallContextArguments.bind(body([1, 0, 0, 0, 0, 0, 0, 0]), [m::STR])&.masks == [m::STR])
puts 'context arguments: PASS'
