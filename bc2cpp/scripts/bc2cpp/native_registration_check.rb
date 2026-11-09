#!/usr/bin/env ruby
# frozen_string_literal: true

# Native owner scope parsing and per-source registration caching share one host-only suite.
# Generated owner-map arms and whole-world mutations remain in their independent checks.
require_relative 'native_owner_scopes_cases'
require_relative 'native_path_registrations_cases'

failures = []
checks = 0
check = lambda do |label, ok|
  checks += 1
  puts "  #{ok ? 'ok  ' : 'FAIL'} #{label}"
  failures << label unless ok
end

[NativeOwnerScopesCases, NativePathRegistrationsCases].each do |cases|
  puts "== #{cases.name}"
  cases.run(check)
end

abort "native registration check: #{failures.size} of #{checks} failed" unless failures.empty?
puts "native registration check: #{checks} checks passed"
