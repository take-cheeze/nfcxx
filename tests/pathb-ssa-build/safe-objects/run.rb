#!/usr/bin/env ruby
# frozen_string_literal: true
#
# Slice 3 of --safe on the SSA route (docs/notes/safe-pointers.md): a store through a computed pointer into a stack
# array, and into a global array, is checked. The default build of objects.ir writes one element past the end silently
# in both cases; the --safe build aborts with a safety error for each. In-bounds stores run the same in both builds.

require "open3"
require "tmpdir"

ROOT = File.expand_path("../../..", __dir__)
DRIVER = File.join(ROOT, "scripts", "pathb-ssa-build")
CASE = File.join(__dir__, "objects.ir")
MAIN = File.join(__dir__, "driver.c")

failures = []
ok = ->(msg) { puts "ok   #{msg}" }
bad = ->(msg) { failures << msg; puts "FAIL #{msg}" }

runtime, _, st = Open3.capture3(File.join(ROOT, "scripts", "safeptr-rt.rb"))
abort "safeptr-rt failed" unless st.success?
runtime = runtime.strip

Dir.mktmpdir("pathb-ssa-safe-objects") do |dir|
  default_s = File.join(dir, "default.s")
  safe_s = File.join(dir, "safe.s")
  default_exe = File.join(dir, "default")
  safe_exe = File.join(dir, "safe")

  _, err, st = Open3.capture3(RbConfig.ruby, DRIVER, "-o", default_s, CASE)
  abort "default build failed: #{err.lines.first}" unless st.exitstatus == 0
  _, err, st = Open3.capture3(RbConfig.ruby, DRIVER, "--safe", "-o", safe_s, CASE)
  abort "--safe build failed: #{err.lines.first}" unless st.exitstatus == 0

  _, err, st = Open3.capture3("cc", MAIN, default_s, "-o", default_exe)
  abort "cc default: #{err.lines.first}" unless st.success?
  _, err, st = Open3.capture3("cc", MAIN, safe_s, runtime, "-o", safe_exe)
  abort "cc safe: #{err.lines.first}" unless st.success?

  %w[slot global].each do |obj|
    # In bounds: the same output and status in both builds.
    %w[0 3].each do |i|
      d_out, _, d_st = Open3.capture3(default_exe, obj, i)
      s_out, _, s_st = Open3.capture3(safe_exe, obj, i)
      if d_st.success? && s_st.success? && d_out == s_out && d_out == "ok\n"
        ok.call("#{obj} in bounds (#{i}): both builds print ok, status 0")
      else
        bad.call("#{obj} in bounds (#{i}): default #{d_out.inspect} #{d_st.exitstatus}, safe #{s_out.inspect} #{s_st.exitstatus}")
      end
    end

    # One element past the end: the default build writes it silently; the --safe build aborts with a safety error.
    # The default build is undefined here: a stack write past the array corrupts the frame (it may crash), and a global
    # write past its array is silent. Only the global's silence is asserted.
    d_out, _, d_st = Open3.capture3(default_exe, obj, "4")
    if obj == "global"
      if d_st.success? && d_out == "ok\n"
        ok.call("global out of bounds (4), default build: silent, status 0 (unchecked)")
      else
        bad.call("global out of bounds (4), default build: #{d_out.inspect} status #{d_st.exitstatus}")
      end
    else
      ok.call("slot out of bounds (4), default build: undefined (stack corruption); not asserted")
    end
    _, s_err, s_st = Open3.capture3(safe_exe, obj, "4")
    if !s_st.success? && s_err.include?("out-of-bounds")
      ok.call("#{obj} out of bounds (4), --safe build: aborts with a safety error")
    else
      bad.call("#{obj} out of bounds (4), --safe build: status #{s_st.exitstatus}, stderr #{s_err.inspect}")
    end
  end
end

failures.each { |m| puts "FAIL #{m}" }
puts "ok   pathb-ssa-build safe objects (stack slot and global)" if failures.empty?
exit(failures.empty? ? 0 : 1)
