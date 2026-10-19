#!/usr/bin/env ruby
# frozen_string_literal: true

# Compares the bytecode IR's constant facts (BYTECODE_CONSTANT_FACTS, tools/bc2cpp/bytecode_ir_constants.rb) with the
# constant proofs a build reports, from the bc2cpp stderr of that build (the `==` sections of the closed build log):
#
#   ruby scripts/bc2cpp/ir_constant_facts_compare.rb BUILD_LOG [--out FILE]
#
# Each bc2cpp run in the log is one block. Per block it compares, by bare name (the way every read resolves):
#   admitted   INTEGER_CONSTANT_PROOF `CONST name`        vs the IR group's classes being exactly Integer
#   value      INTEGER_CONSTANT_VALUE_PROOF `CONST name = v` vs the IR group value
#   interval   NUMERIC_CONSTANT_RANGES `CONST_RANGE name lo hi` vs the IR group interval
# and, by full lexical path, the constructed/hinted class of a constant (CONST_CLASS, CONST_HINT) vs the IR path classes.
# A disagreement is printed as `CATEGORY name proof=... ir=...`; the exit status is 0 (this is a report).

require 'set'

SECTION_FOR = {
  'integer-valued constants proven (INTEGER_CONSTANT_PROOF)' => :admitted,
  'integer constant literal values proven (INTEGER_CONSTANT_VALUE_PROOF)' => :values,
  'constants with a proven Fixnum interval (NUMERIC_CONSTANT_RANGES)' => :ranges,
  'single-assignment constructed constants (CLOSED_WORLD_VALUE_CONSTANT)' => :constructed,
  'known constant value classes (whole program)' => :hints,
  'BYTECODE_CONSTANT_FACTS' => :ir
}.freeze

# One bc2cpp run: the proof and IR facts it printed.
Block = Struct.new(:admitted, :values, :ranges, :classes, :ir_paths, :ir_groups, keyword_init: true)

def parse(lines)
  blocks = []
  current = nil
  section = nil
  lines.each do |line|
    if line.start_with?('== integer-valued constants proven')
      current = Block.new(admitted: Set.new, values: {}, ranges: {}, classes: {}, ir_paths: {}, ir_groups: {})
      blocks << current
    end
    next unless current

    if (heading = line[/\A== (.*?) ==/, 1])
      section = SECTION_FOR.find { |key, _| heading.start_with?(key) }&.last
      next
    end
    case section
    when :admitted
      current.admitted << Regexp.last_match(1) if line =~ /\A  CONST (\S+)\s*\z/
    when :values
      current.values[Regexp.last_match(1)] = Regexp.last_match(2).to_i if line =~ /\A  CONST (\S+) = (-?\d+)\s*\z/
    when :ranges
      current.ranges[Regexp.last_match(1)] = [Regexp.last_match(2).to_i, Regexp.last_match(3).to_i] if
        line =~ /\A  CONST_RANGE (\S+) (-?\d+) (-?\d+)\s*\z/
    when :constructed, :hints
      current.classes[Regexp.last_match(1)] = Regexp.last_match(2) if line =~ /\A  CONST(?:_CLASS|_HINT)?\s+(\S+)\s+\((\S+)\)\s*\z/
    when :ir
      if line =~ /\A  IR_CONST (\S+) classes=(\S+) value=(\S+) interval=(\S+)\s*\z/
        m = Regexp.last_match
        current.ir_paths[m[1]] = m.captures[1..3]
      elsif line =~ /\A  IR_GROUP (\S+) classes=(\S+) value=(\S+) interval=(\S+)\s*\z/
        m = Regexp.last_match
        current.ir_groups[m[1]] = m.captures[1..3]
      end
    end
  end
  blocks
end

def ir_integer?(classes)
  classes != '?' && classes.split(',') == ['Integer']
end

def compare(block)
  out = []
  names = (block.admitted.to_a + block.values.keys + block.ranges.keys + block.ir_groups.keys).uniq.sort
  names.each do |name|
    classes, value, interval = block.ir_groups.fetch(name, ['?', '-', '-'])
    proof_admitted = block.admitted.include?(name)
    if proof_admitted && !ir_integer?(classes)
      out << ['admitted-only-in-proof', name, "proof=Integer ir=#{classes}"]
    elsif !proof_admitted && ir_integer?(classes)
      out << ['admitted-only-in-ir', name, "proof=none ir=#{classes}"]
    end
    proof_value = block.values[name]
    ir_value = value == '-' ? nil : value.to_i
    out << ['value', name, "proof=#{proof_value.inspect} ir=#{ir_value.inspect}"] if proof_value != ir_value
    proof_range = block.ranges[name]
    ir_range = interval == '-' ? nil : interval.split('..').map(&:to_i)
    out << ['interval', name, "proof=#{proof_range.inspect} ir=#{ir_range.inspect}"] if proof_range != ir_range
  end
  block.classes.each do |path, klass|
    classes, = block.ir_paths.fetch(path, ['?', '-', '-'])
    ir_has = classes != '?' && classes.split(',').include?(klass)
    out << ['class', path, "proof=#{klass} ir=#{classes}"] unless ir_has
  end
  out
end

out_path = nil
args = ARGV.dup
if (i = args.index('--out'))
  args.delete_at(i)
  out_path = args.delete_at(i)
end
abort 'usage: ir_constant_facts_compare.rb BUILD_LOG [--out FILE]' if args.empty?

report = []
args.each do |log|
  blocks = parse(File.readlines(log, chomp: true))
  if blocks.empty?
    report << "#{log}: no bc2cpp constant sections"
    next
  end
  blocks.each_with_index do |block, n|
    rows = compare(block)
    tally = rows.map(&:first).tally.sort.to_h
    report << "#{log} run #{n + 1}: admitted=#{block.admitted.size} values=#{block.values.size} " \
              "ranges=#{block.ranges.size} ir_groups=#{block.ir_groups.size} ir_paths=#{block.ir_paths.size} " \
              "disagreements=#{rows.size} #{tally}"
    rows.each { |category, name, detail| report << "  #{category} #{name} #{detail}" }
  end
end
text = report.join("\n") << "\n"
out_path ? File.write(out_path, text) : $stdout.write(text)
