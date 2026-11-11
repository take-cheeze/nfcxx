#!/usr/bin/env ruby
# frozen_string_literal: true
#
# Native check of by-value aggregates (sret results and byval parameters) in the SSA-to-QBE emitter. The interpreter does
# not model by-value aggregates, so this compares against the C ABI instead: byval.ir is emitted with the driver
# (scripts/pathb-ssa-build), linked with driver.c, which calls each function with its C struct and checks the result.
#
#   ruby tests/pathb-ssa-qbe/byval/run.rb
#
require "open3"
require "tmpdir"

HERE = __dir__
ROOT = File.expand_path("../../..", HERE)
IR = File.join(HERE, "byval.ir")
DRIVER = File.join(HERE, "driver.c")

Dir.mktmpdir("pathb-byval") do |dir|
  asm = File.join(dir, "byval.s")
  exe = File.join(dir, "prog")
  _, err, st = Open3.capture3("ruby", File.join(ROOT, "scripts/pathb-ssa-build"), "-o", asm, IR)
  abort "emit failed: #{err.lines.first}" unless st.success?

  _, err, st = Open3.capture3("cc", DRIVER, asm, "-o", exe)
  abort "cc failed: #{err.lines.first}" unless st.success?

  out, _, st = Open3.capture3(exe)
  puts out
  exit(st.success? && out.lines.last&.strip == "ok" ? 0 : 1)
end
