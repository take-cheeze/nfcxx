#!/usr/bin/env ruby
# frozen_string_literal: true

# The optcarrot probe (tools/optcarrot_probe) is in no benchmark job, so its bc2cpp scan of the sealed optcarrot world
# is what keeps it building: a check that began to reject its bundle (CONST_RESOLVE on OptcarrotProbe or Regexp) failed
# nowhere. Scan only, about ten seconds; the full build and 180-frame checksum run is `ruby tools/optcarrot_probe/compiled_run.rb`.
#
# Usage: MRBC=path/to/mrbc ruby scripts/bc2cpp/optcarrot_probe_scan_check.rb

require_relative '../../tools/bc2cpp/world_root'
require 'open3'
require 'rbconfig'

ROOT = BC2CPP_WORLD_ROOT
mrbc = ENV['MRBC'].to_s
if mrbc.empty? || !File.file?(File.join(ROOT, '3rd/optcarrot/lib/optcarrot.rb'))
  puts 'optcarrot probe scan check: SKIP (set MRBC and check out 3rd/optcarrot)'
  exit 0
end

stdout, stderr, status = Open3.capture3({ 'MRBC' => mrbc }, RbConfig.ruby, File.join(BC2CPP_TREE_ROOT, 'tools/optcarrot_probe/bc2cpp_probe.rb'))
abort "optcarrot probe scan check: FAIL, the scan failed:\n#{(stderr.empty? ? stdout : stderr)[-3000..]}" unless status.success?

clean = stdout[/^compiled entry points \(clean, zero #error\): (\d+)/, 1].to_i
abort "optcarrot probe scan check: FAIL, only #{clean} clean entry points" if clean < 400
puts "optcarrot probe scan check: PASS (#{clean} clean entry points)"
