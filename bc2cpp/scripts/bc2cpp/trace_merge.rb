#!/usr/bin/env ruby
# frozen_string_literal: true

# Writes the trace candidates that sig/bc2cpp/declarations.rbs does not already declare to generated/bc2cpp/
# trace_proposals.rbs, a file nothing loads. Conflicts (a method declared with another signature) are listed and left
# alone. See tools/bc2cpp/trace_merge.rb.
#
#   ruby scripts/bc2cpp/trace_merge.rb CANDIDATES.rbs [DECLARATIONS] [--out FILE]
#
# Refuses an output under sig/: rbs_signatures.rb loads every sig/**/*.rbs.

require 'optparse'
require_relative '../../tools/bc2cpp/trace_merge'

ROOT = File.expand_path('../..', __dir__)
out = File.join(ROOT, 'generated/bc2cpp/trace_proposals.rbs')
parser = OptionParser.new do |opts|
  opts.banner = 'usage: trace_merge.rb CANDIDATES.rbs [DECLARATIONS] [--out FILE]'
  opts.on('--out FILE', 'Write the proposals to FILE (not under sig/)') { |f| out = File.expand_path(f) }
end
parser.parse!(ARGV)
abort parser.to_s unless (1..2).cover?(ARGV.size)
abort 'trace_merge: the output must not be under sig/ (it would be loaded)' if out.start_with?(File.join(ROOT, 'sig') + File::SEPARATOR)

declarations = File.expand_path(ARGV[1] || File.join(ROOT, 'sig/bc2cpp/declarations.rbs'))
result = TraceMerge.compare(File.read(ARGV[0]), File.read(declarations))
File.write(out, TraceMerge.render(result.proposed))
puts "trace merge: #{result.proposed.size} proposed, #{result.same.size} already declared, " \
     "#{result.conflicts.size} conflicting (kept as declared), #{result.skipped_interfaces} interfaces not read"
result.conflicts.first(10).each do |cand, declared|
  puts "  conflict #{cand.owner}#{cand.singleton ? '.' : '#'}#{cand.name}: candidate #{cand.signature}, declared #{declared.join(' | ')}"
end
puts "wrote #{out}"
