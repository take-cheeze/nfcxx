# frozen_string_literal: true

# Fails when sig/native/core_direct.rbs or sig/native/rgss_direct.rbs is stale against the native tables they are
# generated from, or does not parse as RBS. Run in CI next to the other bc2cpp checks.
require 'rbs'
require_relative 'native_core_direct_sigs'
require_relative 'native_rgss_direct_sigs'

failures = []
[[NativeCoreDirectSigs, 'scripts/bc2cpp/native_core_direct_sigs.rb'],
 [NativeRgssDirectSigs, 'scripts/bc2cpp/native_rgss_direct_sigs.rb']].each do |generator, script|
  current = File.exist?(generator::PATH) ? File.read(generator::PATH) : nil
  failures << "#{generator::PATH} is stale; run ruby #{script}" unless current == generator.render
  next unless current

  begin
    RBS::Parser.parse_signature(RBS::Buffer.new(name: File.basename(generator::PATH), content: current))
  rescue RBS::ParsingError => e
    failures << "#{generator::PATH} does not parse: #{e.message}"
  end
end

abort failures.map { |f| "bc2cpp: #{f}" }.join("\n") unless failures.empty?
puts 'ok: native signature files match their tables and parse'
