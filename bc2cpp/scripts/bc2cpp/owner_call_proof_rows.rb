#!/usr/bin/env ruby
# frozen_string_literal: true

# The owner calls of generated sources built with BC2CPP_OWNER_CALL_PROOF_NOTE=1 (tools/bc2cpp/owner_call_proof_note.rb),
# one TSV row each: file, name, then the fields of the note ahead of it (`-` when none, or when the note is another
# name's). With --exact, only the rows whose class-flow mask is one class and not nil.
#
# Usage: ruby scripts/bc2cpp/owner_call_proof_rows.rb [--exact] GENERATED.cpp...

FIELDS = %w[op in self argc mask num exact regs at].freeze

exact_only = ARGV.delete('--exact')
puts (%w[file name] + FIELDS).join("\t")
ARGV.each do |path|
  note = nil
  File.foreach(path, encoding: 'BINARY') do |line|
    if (text = line[%r{/\* OWNER_CALL_PROOF (.*) \*/}, 1])
      note = text.scan(/(\w+)=(\S+)/).to_h
      next
    end
    note = nil if line.start_with?('// ') && line.include?('(compiled from irep')
    next unless (name = line[%r{/\* CLOSED_WORLD owner-call: (\S+) \*/}, 1])

    fields = note && (note['name'].nil? || note['name'] == name) ? note : {}
    note = nil
    mask = fields['mask'].to_s
    next if exact_only && (mask.empty? || mask.match?(/[|+]|NIL|NONE|CHECKED|unmodelled/))

    puts ([File.basename(path), name] + FIELDS.map { |f| fields[f] || '-' }).join("\t")
  end
end
