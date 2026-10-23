#!/usr/bin/env ruby
# frozen_string_literal: true

# Promotes reviewed candidate RBS (type_check.rb --emit-rbs DIR or --emit-rbs-suggestions DIR) into a signature file.
# Dry run by default: prints what would be added, the skipped members and a unified diff, and writes nothing.
#
#   ruby scripts/bc2cpp/promote_candidates.rb CANDIDATE_DIR                  # dry run
#   ruby scripts/bc2cpp/promote_candidates.rb --write CANDIDATE_DIR          # apply the diff
#   ruby scripts/bc2cpp/promote_candidates.rb --target FILE CANDIDATE_DIR    # another target (default sig/bc2cpp/declarations.rbs)
#
# Only absent methods, ivars and constants are added; nothing before `# ---- block_types.rbs` is touched; `--write`
# parses the result again and exits 1 if it no longer parses. The rules are in tools/bc2cpp/promote_candidates.rb
# and docs/bc2cpp-promote-candidates.md. Exit status: 0 done (or nothing to add), 1 refused or the write did not parse,
# 2 usage.

require 'optparse'
require_relative '../../tools/bc2cpp/promote_candidates'

ROOT = File.expand_path('../..', __dir__)
options = { write: false, target: File.join(ROOT, 'sig/bc2cpp/declarations.rbs') }
parser = OptionParser.new do |o|
  o.banner = 'usage: promote_candidates.rb [--write] [--target FILE] CANDIDATE_DIR'
  o.on('--write', 'Apply the diff to the target (default: dry run)') { options[:write] = true }
  o.on('--target FILE', 'Signature file to promote into') { |v| options[:target] = v }
end
parser.parse!(ARGV)
unless ARGV.size == 1
  warn parser.to_s
  exit 2
end

candidate_dir = ARGV.first
target = options[:target]
label = target.delete_prefix("#{ROOT}/")
dirname = File.basename(File.expand_path(candidate_dir))

begin
  result = PromoteCandidates.plan(File.read(target), candidate_dir, target_label: label)
rescue PromoteCandidates::Refusal => e
  warn "promote_candidates: refused: #{e.message}"
  exit 1
end

puts "promote candidates: #{dirname} -> #{label}"
result.added.each { |class_name, line| puts "  add   #{class_name}  #{line}" }
result.skipped.each { |what, reason| puts "  skip  #{what}: #{reason}" }
puts "  summary: #{result.added.size} to add, #{result.skipped.size} skipped, #{result.already} already declared"

if result.text == File.read(target)
  puts 'nothing to promote; the target is unchanged'
  exit 0
end

print PromoteCandidates.unified_diff(File.read(target), result.text, label)

unless options[:write]
  puts 'dry run: nothing written (rerun with --write to apply this diff)'
  exit 0
end

File.write(target, result.text)
error = PromoteCandidates.written_error(target)
if error
  warn "promote_candidates: #{label} does not parse after the write (#{error})"
  exit 1
end
puts "wrote #{result.added.size} member(s) to #{label}; the file parses with RBS"
