#!/usr/bin/env ruby
# frozen_string_literal: true

# Regenerates STRICT_HINTS_REVIEWED (tools/bc2cpp/strict_hints_reviewed.rb) from a full and a hot-only wio closed-world
# run of the compiled gems with BC2CPP_STRICT_HINTS=1 (docs/adr/0419).
#
#   MRBC=path/to/host/mrbc ruby scripts/bc2cpp/strict_hints_update.rb [--write]
#
# Without --write it only prints the sites and the diff against the checked-in list. Writing is not a
# review: run the verify build (docs/bc2cpp-strict-hints.md) over the real workloads first, and list a
# site only when it reached zero violations there.
require_relative '../../tools/bc2cpp/nomethod_reviewed_probe'
require_relative '../../tools/bc2cpp/strict_hints'

root = File.expand_path('../..', __dir__)
mrbc = ENV['MRBC'] || 'mrbc'
ENV[StrictHints::ENV_NAME] = 'all'
# The full run and the hot-only run: a hot-only build forces sites the full build turns into another form
# (ADR 0428), and both must be listed.
sites = BC2CPP_COMPILED_GEMS.keys.product([nil, BC2CPP_HOT_METHODS_PATH]).map do |gem_name, hot|
  Thread.new do
    # Read past a reviewed-list abort (the unreviewed sites are what this lists); any other failure raises.
    _out, err, = NomethodReviewedProbe.listing_run(gem_name, root, mrbc, hot_methods: hot)

    StrictHints.parse_listing(err).map { |key| { key: key, gem: gem_name } }
  end
end.flat_map(&:value)
keys = sites.map { |s| s[:key] }.uniq.sort

sites.group_by { |s| s[:key] }.sort.each { |key, group| puts "#{key}\t#{group.size} site(s)\t#{group.first[:gem]}" }
require_relative '../../tools/bc2cpp/strict_hints_reviewed'
added = keys - STRICT_HINTS_REVIEWED.to_a
removed = STRICT_HINTS_REVIEWED.to_a - keys
warn "#{sites.size} forced site(s), #{keys.size} key(s); listed #{STRICT_HINTS_REVIEWED.size}"
added.each { |k| warn "  + #{k}" }
removed.each { |k| warn "  - #{k}" }

if ARGV.include?('--write')
  path = File.expand_path('../../tools/bc2cpp/strict_hints_reviewed.rb', __dir__)
  body = keys.empty? ? 'Set[].freeze' : "Set[\n#{keys.map { |k| "  #{k.inspect}," }.join("\n")}\n].freeze"
  src = File.read(path)
  updated = src.sub(/^STRICT_HINTS_REVIEWED = Set\[.*?\]\.freeze$/m, "STRICT_HINTS_REVIEWED = #{body}")
  abort "no STRICT_HINTS_REVIEWED = Set[...].freeze in #{path}" if updated == src && !src.include?(body)
  File.write(path, updated)
  warn "wrote #{keys.size} key(s) to #{path}"
end
