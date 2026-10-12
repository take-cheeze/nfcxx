#!/usr/bin/env ruby
# frozen_string_literal: true

# Every instruction of the real closed-world gems must parse against
# OperandSchema and format back to the decoder's own operand text. Usage:
# MRBC=path/to/mrbc ruby scripts/bc2cpp/operand_schema_check.rb
require 'tmpdir'
require_relative '../../tools/bc2cpp/irep'
require_relative '../../tools/bc2cpp/operand_schema'
require_relative '../../tools/bc2cpp/compiled_gems'

ROOT = File.expand_path('../..', __dir__)
ireps, = Dir.mktmpdir { |dir| compile_ireps(closed_world_mrblib_srcs(ROOT), 'schema_check', dir) }

total = 0
unparsed = Hash.new { |h, k| h[k] = [] }
mismatch = Hash.new { |h, k| h[k] = [] }
ireps.each_value.flat_map(&:instructions).each do |insn|
  total += 1
  ops = OperandSchema.parse(insn.op, insn.args)
  if ops.nil?
    unparsed[insn.op] << insn.args
    next
  end
  want = OperandSchema.strip_comment(insn.args).strip.split(/\s+/).join(' ')
  got = OperandSchema.to_text(ops)
  mismatch[insn.op] << [want, got] unless want == got
end

report = lambda do |title, table|
  next if table.empty?

  warn "#{title}:"
  table.each { |op, samples| warn "  #{op} (#{samples.length}): #{samples.first(3).inspect}" }
end
report.call('unparsed', unparsed)
report.call('round-trip mismatch', mismatch)
abort("bc2cpp operand schema check: FAIL (#{total} instructions)") unless unparsed.empty? && mismatch.empty?
puts "bc2cpp operand schema check: PASS (#{total} instructions)"
