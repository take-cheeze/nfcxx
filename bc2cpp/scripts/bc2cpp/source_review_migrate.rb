#!/usr/bin/env ruby
# frozen_string_literal: true

# Writes the review annotations (tools/bc2cpp/source_review.rb) for a set of gate sites, one comment above each site
# line, so a closed-world build passes without the central lists. Input: a JSON array of
#   {"gate": "nomethod", "spec": "name", "file": "/abs/path.rb", "line": 12, "reason": "..."}
# as the probe dumps them. Dry run by default; `--write` edits the files.
#
#   ruby scripts/bc2cpp/source_review_migrate.rb SITES.json [--write]
#
# A line that already has a bc2cpp-reviewed comment above it is merged into, keeping its reason; otherwise a new
# comment with the site's indentation is inserted. Files are edited bottom-up so earlier line numbers stay valid.
require 'json'
require_relative '../../tools/bc2cpp/source_review'

sites_path = ARGV.find { |a| !a.start_with?('--') } or abort 'usage: source_review_migrate.rb SITES.json [--write]'
write = ARGV.include?('--write')
sites = JSON.parse(File.read(sites_path))

skipped = sites.reject { |s| s['line'].to_i.positive? && File.file?(s['file'].to_s) }
abort "no source line for #{skipped.size} site(s), e.g. #{skipped.first.inspect}" unless skipped.empty?

by_file = sites.group_by { |s| s['file'] }
totals = Hash.new(0)
by_file.each do |file, file_sites|
  lines = File.readlines(file, encoding: 'UTF-8')
  # The comment goes above the statement a site's line belongs to (a backslash-continued run has no room inside it),
  # so targets are computed from the file as it was before any insertion.
  by_target = file_sites.group_by { |s| SourceReview.statement_start(lines, s['line']) }
  by_target.sort_by { |target, _| -target }.each do |target, group|
    keys = group.map { |s| SourceReview.key(s['gate'], s['spec']) }.uniq.sort
    reason = group.map { |s| s['reason'] }.compact.first || 'reviewed before the source-annotation migration'
    above = target - 2
    existing = above >= 0 && lines[above].include?(SourceReview::TAG) ? lines[above] : nil
    if existing
      old_keys = SourceReview.annotation_keys(existing)
      old_reason = existing.split(' -- ', 2)[1]&.strip
      merged = (old_keys + keys).uniq.sort
      indent = existing[/\A\s*/]
      lines[above] = "#{indent}# #{SourceReview::TAG} #{merged.join(', ')} -- #{old_reason || reason}\n"
      totals[:merged] += 1
    else
      indent = lines[target - 1][/\A\s*/]
      lines.insert(target - 1, "#{indent}# #{SourceReview::TAG} #{keys.join(', ')} -- #{reason}\n")
      totals[:inserted] += 1
    end
  end
  totals[:files] += 1
  File.write(file, lines.join) if write
end

puts "#{sites.size} site(s) in #{totals[:files]} file(s): #{totals[:inserted]} comment(s) inserted, #{totals[:merged]} merged"
puts(write ? 'written' : 'dry run (pass --write to edit the files)')
