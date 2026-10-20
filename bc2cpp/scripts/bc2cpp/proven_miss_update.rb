#!/usr/bin/env ruby
# frozen_string_literal: true

# Regenerates PROVEN_MISS_REVIEWED (tools/bc2cpp/proven_miss_reviewed.rb) from a
# full closed closed-world run of all three compiled gems (docs/adr/0275).
#
#   MRBC=path/to/host/mrbc ruby scripts/bc2cpp/proven_miss_update.rb [--write]
#
# Without --write it only prints the sites and the diff against the checked-in
# list. Writing is not a review: read the source of every added key first, fix
# a real missing method, and list only defensive or dead code.
require_relative '../../tools/bc2cpp/nomethod_reviewed_probe'

root = File.expand_path('../..', __dir__)
mrbc = ENV['MRBC'] || 'mrbc'
sites = NomethodReviewedProbe.full_proven_miss_sites(root, mrbc)
keys = sites.map { |s| s[:key] }.uniq.sort

keys.each { |key| puts "#{key}\t#{sites.find { |s| s[:key] == key }[:gem]}" }
added = keys - PROVEN_MISS_REVIEWED.to_a
removed = PROVEN_MISS_REVIEWED.to_a - keys
warn "#{sites.size} proven-class miss site(s), #{keys.size} key(s); listed #{PROVEN_MISS_REVIEWED.size}"
added.each { |k| warn "  + #{k}" }
removed.each { |k| warn "  - #{k}" }

if ARGV.include?('--write')
  path = File.expand_path('../../tools/bc2cpp/proven_miss_reviewed.rb', __dir__)
  body = keys.empty? ? 'Set[].freeze' : "Set[\n#{keys.map { |k| "  #{k.inspect}," }.join("\n")}\n].freeze"
  src = File.read(path)
  updated = src.sub(/^PROVEN_MISS_REVIEWED = Set\[.*?\]\.freeze$|^PROVEN_MISS_REVIEWED = Set\[\]\.freeze$/m,
                    "PROVEN_MISS_REVIEWED = #{body}")
  abort "no PROVEN_MISS_REVIEWED = Set[...].freeze in #{path}" if updated == src && !src.include?(body)
  File.write(path, updated)
  warn "wrote #{keys.size} key(s) to #{path}"
end
