#!/usr/bin/env ruby
# frozen_string_literal: true

# Guard the straight-line register-copy cases admitted by
# infer_constructed_constant_classes.
require_relative '../../tools/bc2cpp/bc2cpp'

failures = []
check = lambda do |label, result|
  puts "  #{result ? 'ok  ' : 'FAIL'} #{label}"
  failures << label unless result
end

def fake_irep(*insns)
  Irep.new(instructions: insns.each_with_index.map do |(op, args), i|
    Insn.new(lineno: i, addr: i, op: op, args: args)
  end)
end

direct = fake_irep(['SEND', 'R1 :new n=0'])
copied = fake_irep(['SEND', 'R1 :new n=0'], ['MOVE', 'R2 R1'])
overwritten = fake_irep(['SEND', 'R1 :new n=0'], ['MOVE', 'R2 R1'], ['LOADI_1', 'R2 (1)'])
other_send = fake_irep(['SEND', 'R1 :build n=0'], ['MOVE', 'R2 R1'])

check.call('direct constructor result is admitted', assigned_from_new_send?(direct, 1, '1'))
check.call('plain register copy preserves constructor evidence', assigned_from_new_send?(copied, 2, '2'))
check.call('a later write invalidates constructor evidence', !assigned_from_new_send?(overwritten, 3, '2'))
check.call('a different factory method is refused', !assigned_from_new_send?(other_send, 2, '2'))

if failures.empty?
  puts 'bc2cpp constructed constant check: PASS'
else
  warn "bc2cpp constructed constant check: #{failures.size} failure(s)"
  exit 1
end
