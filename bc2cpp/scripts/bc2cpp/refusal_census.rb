#!/usr/bin/env ruby
# frozen_string_literal: true

# Census of the bytecode-IR value queries that refuse, by refusal cause.
#
#   MRBC=path/to/mrbc ruby scripts/bc2cpp/refusal_census.rb [--tsv FILE] [FILE.rb ...]
#
# With no files, every mrblib Ruby file of the closed-world gems is used. Each file
# is compiled by mrbc on its own, then every instruction that reads its leading
# register (BytecodeIR::Ops::LEAD_READ_ONLY) asks BytecodeIR::Types#at for that
# register's value classes. The census counts answers and refusals, and the
# refusal causes of the refusals. Output is stats only; nothing is generated.
#
# See docs/bc2cpp-refusal-census.md for the method and its limits.

require 'tmpdir'
require 'set'
require_relative '../../tools/bc2cpp/irep'
require_relative '../../tools/bc2cpp/bytecode_ir'
require_relative '../../tools/bc2cpp/bytecode_ir_types'

ROOT = File.expand_path('../..', __dir__)
DEFAULT_GEMS = %w[mruby-rpg2k mruby-lcf mruby-rgss].freeze

tsv = nil
files = []
until ARGV.empty?
  arg = ARGV.shift
  if arg == '--tsv'
    tsv = ARGV.shift or abort 'usage: --tsv FILE'
  elsif arg.start_with?('--')
    abort "unknown option #{arg} (see #{$PROGRAM_NAME})"
  else
    files << arg
  end
end
if files.empty?
  files = DEFAULT_GEMS.flat_map { |gem| Dir[File.join(ROOT, gem, 'mrblib', '**', '*.rb')] }.sort
end
abort 'bc2cpp: no Ruby files to census' if files.empty?

# Tally of one answer per query. Answered: the class set is known. Refused: the
# first refusal cause the query recorded (see BytecodeIR::Types#query).
Row = Struct.new(:file, :label, :index, :op, :reg, :answered, :cause, keyword_init: true)
rows = []
files.each do |path|
  Dir.mktmpdir('refusal-census') do |dir|
    symbol = File.basename(path, '.rb').gsub(/\W/, '_')
    ireps, _root = compile_ireps([path], symbol, dir)
    ireps.each do |label, irep|
      types = BytecodeIR::Types.new(irep)
      BytecodeIR::Ops::LEAD_READ_ONLY.each do |op|
        irep.each_with_op(op) do |insn, index|
          refusal = {}
          classes = types.at(index, insn.reg.to_s, refusal: refusal)
          rows << Row.new(file: File.basename(path), label: label, index: index, op: op, reg: insn.reg.to_s,
                          answered: !classes.nil?, cause: classes ? nil : (refusal[:cause] || :unrecorded).to_s)
        end
      end
    end
  end
end

def tally(rows, key)
  rows.group_by(&key).transform_values(&:size).sort_by { |k, v| [-v, k.to_s] }
end

answered = rows.count(&:answered)
refused = rows.size - answered
puts "queries: #{rows.size} (answered #{answered}, refused #{refused})"
puts "files: #{files.size}"
puts
puts '-- refusal causes --'
tally(rows.reject(&:answered), :cause).each { |cause, n| puts format('%6d  %s', n, cause) }
puts
puts '-- refusals by leading opcode --'
tally(rows.reject(&:answered), :op).each { |op, n| puts format('%6d  %s', n, op) }
puts
puts '-- refusals by file (top 15) --'
tally(rows.reject(&:answered), :file).first(15).each { |file, n| puts format('%6d  %s', n, file) }

if tsv
  File.open(tsv, 'w') do |out|
    out.puts %w[file irep index op reg answered cause].join("\t")
    rows.each do |r|
      out.puts [r.file, r.label, r.index, r.op, r.reg, r.answered, r.cause].join("\t")
    end
  end
  puts
  puts "wrote #{tsv}"
end
