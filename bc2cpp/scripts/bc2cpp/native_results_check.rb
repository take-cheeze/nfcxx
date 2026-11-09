#!/usr/bin/env ruby
# frozen_string_literal: true

# Native return inference and audited result declarations.
# Their tables share one process; real-source mutation and generated-code checks stay isolated.
require_relative 'native_return_kinds_cases'
require_relative 'native_core_result_sigs_cases'

failures = []
checks = 0
check = lambda do |label, ok|
  checks += 1
  puts "  #{ok ? 'ok  ' : 'FAIL'} #{label}"
  failures << label unless ok
end

[NativeReturnKindsCases, NativeCoreResultSigsCases].each do |cases|
  puts "== #{cases.name}"
  cases.run(check)
end

abort "native results check: #{failures.size} of #{checks} failed" unless failures.empty?
puts "native results check: #{checks} checks passed"
