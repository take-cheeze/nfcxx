#!/usr/bin/env ruby
# frozen_string_literal: true

# Regenerates NOMETHOD_REVIEWED (tools/bc2cpp/nomethod_reviewed.rb) from a
# full closed closed-world run of all three compiled gems (docs/adr/0226).
#
#   MRBC=path/to/host/mrbc ruby scripts/bc2cpp/nomethod_reviewed_update.rb [--write]
#
# Without --write it only prints the sites and the diff against the checked-in
# list. Writing is not a review: read the source of every added key first, and
# only list it when the fallback is dead (the receiver's class is always one
# the guard chain lists), not when a real method is missing.
require_relative '../../tools/bc2cpp/nomethod_reviewed_probe'

root = File.expand_path('../..', __dir__)
mrbc = ENV['MRBC'] || 'mrbc'
sites = NomethodReviewedProbe.full_sites(root, mrbc)
keys = sites.map { |s| s[:key] }.uniq.sort

sites.group_by { |s| s[:key] }.sort.each do |key, group|
  recv = group.all? { |s| s[:self_receiver] } ? 'self' : 'non-self'
  puts "#{key}\t#{group.size} site(s)\t#{recv}\t#{group.first[:gem]}"
end
added = keys - NOMETHOD_REVIEWED.to_a
removed = NOMETHOD_REVIEWED.to_a - keys
warn "#{sites.size} bc2cpp_nomethod site(s), #{keys.size} key(s); listed #{NOMETHOD_REVIEWED.size}"
added.each { |k| warn "  + #{k}" }
removed.each { |k| warn "  - #{k}" }

if ARGV.include?('--write')
  path = File.expand_path('../../tools/bc2cpp/nomethod_reviewed.rb', __dir__)
  body = keys.empty? ? 'Set[].freeze' : "Set[\n#{keys.map { |k| "  #{k.inspect}," }.join("\n")}\n].freeze"
  src = File.read(path)
  updated = src.sub(/^NOMETHOD_REVIEWED = Set\[.*?\]\.freeze$/m, "NOMETHOD_REVIEWED = #{body}")
  abort "no NOMETHOD_REVIEWED = Set[...].freeze in #{path}" if updated == src && !src.include?(body)
  File.write(path, updated)
  warn "wrote #{keys.size} key(s) to #{path}"
end
