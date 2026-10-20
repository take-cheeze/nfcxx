#!/usr/bin/env ruby
# frozen_string_literal: true

# Dumps every review site of the engine (nomethod, proven_miss and strict_hint from its closed-world runs, constant from
# its type check; docs/adr/0226, 0275, 0419, 0491) as JSON: [{gate:, spec:, file:, line:}]. The input of
# source_review_migrate.rb and of source_review_check.rb's exactness check.
#
#   MRBC=path/to/host/mrbc ruby scripts/bc2cpp/source_review_sites.rb OUT.json
require 'json'
require_relative '../../tools/bc2cpp/review_sites'

root = File.expand_path('../..', __dir__)
mrbc = ENV['MRBC'] || 'mrbc'
sites = ReviewSites.all(root, mrbc)
File.write(ARGV.fetch(0), JSON.pretty_generate(sites))
warn "#{sites.size} review site(s): #{sites.group_by { |s| s[:gate] }.transform_values(&:size)}"
