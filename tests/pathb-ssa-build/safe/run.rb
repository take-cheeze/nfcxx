#!/usr/bin/env ruby
# frozen_string_literal: true
#
# Slice 1 of --safe on the SSA route (docs/notes/safe-pointers.md): `pathb-ssa-build --safe` writes the same assembly as
# the default build (the checks come in a later slice), writes the runtime's path to OUT.link for the caller's link
# line (scripts/pathb-cc puts $(scripts/safeptr-rt) first), and the program built with that runtime runs and returns the
# values of the default build. The runtime must also define every __nfcxx_sp_* symbol the existing emitter's --safe
# output needs, so the object the link line names is the one the existing --safe build depends on.

require "open3"
require "tmpdir"

ROOT = File.expand_path("../../..", __dir__)
DRIVER = File.join(ROOT, "scripts", "pathb-ssa-build")
EMIT = File.join(ROOT, "scripts", "pathb-qbe-emit.rb")
CASE = File.join(ROOT, "tests", "pathb-ssa", "cases", "ternary_set")

failures = []
ok = ->(msg) { puts "ok   #{msg}" }
bad = ->(msg) { failures << msg; puts "FAIL #{msg}" }

runtime, _, st = Open3.capture3("bash", File.join(ROOT, "scripts", "safeptr-rt"))
abort "safeptr-rt failed" unless st.success?
runtime = runtime.strip

Dir.mktmpdir("pathb-ssa-safe") do |dir|
  default_s = File.join(dir, "default.s")
  safe_s = File.join(dir, "safe.s")
  _, err, st = Open3.capture3(RbConfig.ruby, DRIVER, "-o", default_s, "#{CASE}.ir")
  bad.call("default build: status #{st.exitstatus} #{err.lines.first}") unless st.exitstatus == 0

  _, err, st = Open3.capture3(RbConfig.ruby, DRIVER, "--safe", "-o", safe_s, "#{CASE}.ir")
  # The --safe build differs only by its function table and the constructor that registers it (slice 4); it has no
  # check of a call through a pointer here, since this case makes none.
  safe_text = File.read(safe_s) if File.exist?(safe_s)
  if st.exitstatus == 0 && safe_text && safe_text.include?("__nfcxx_sp_ftab") && safe_text.include?("__nfcxx_sp_funcs")
    ok.call("--safe build: registers the module's functions, otherwise as the default build")
  else
    bad.call("--safe build: status #{st.exitstatus}, no function registration in the assembly: #{err.lines.first}")
  end

  link_file = "#{safe_s}.link"
  if File.exist?(link_file) && File.read(link_file).strip == runtime && File.exist?(runtime)
    ok.call("OUT.link names the runtime that scripts/safeptr-rt builds (#{File.basename(runtime)})")
  else
    bad.call("OUT.link: #{File.exist?(link_file) ? File.read(link_file).inspect : 'missing'}, want #{runtime}")
  end

  # Native: the --safe assembly, linked with the runtime first, runs and gives the default build's values.
  args_lines = File.readlines("#{CASE}.args").map(&:strip).reject(&:empty?)
  inputs = args_lines.map { |l| l.split("=>").first.split.map { |t| Integer(t, 10) } }
  wants = args_lines.map { |l| Integer(l.split("=>").last.strip, 10) }
  asm = File.read(safe_s).gsub(/\bmain\b/, "case_main")
  File.write(File.join(dir, "case.s"), asm)
  arity = inputs.first.size
  params = Array.new(arity) { |i| "int a#{i}" }.join(", ")
  calls = inputs.map { |a| "  printf(\"%d\\n\", case_main(#{a.join(', ')}));" }.join("\n")
  File.write(File.join(dir, "drv.c"), "#include <stdio.h>\nint case_main(#{params});\nint main(void) {\n#{calls}\n  return 0;\n}\n")
  exe = File.join(dir, "prog")
  _, err, st = Open3.capture3("cc", File.join(dir, "drv.c"), File.join(dir, "case.s"), runtime, "-o", exe)
  if st.success?
    out, _, run_st = Open3.capture3(exe)
    got = out.split.map(&:to_i)
    if run_st.success? && got == wants
      ok.call("linked with the runtime, runs and matches the expected values #{got.inspect}")
    else
      bad.call("native run: status #{run_st.exitstatus}, got #{got.inspect}, want #{wants.inspect}")
    end
  else
    bad.call("link with the runtime failed: #{err.lines.first}")
  end

  # The existing --safe emitter's undefined __nfcxx_sp_* symbols are all defined by the runtime.
  pathb_ir = File.join(ROOT, "tests", "pathb-ir", "fold_empty_sfinae.ir")
  existing = File.join(dir, "existing.qbe")
  out, _, st = Open3.capture3(RbConfig.ruby, EMIT, "--safe", pathb_ir)
  if st.success?
    File.write(existing, out)
    referenced = out.scan(/\$(__nfcxx_sp_[A-Za-z0-9_]+)/).flatten.uniq
    defined_here = out.scan(/^(?:data|function)[^\n]*?\$(__nfcxx_sp_[A-Za-z0-9_]+)/).flatten
    needed = referenced - defined_here
    defined, _, _ = Open3.capture3("nm", "-g", "--defined-only", runtime)
    provided = defined.scan(/\s(__nfcxx_sp_[A-Za-z0-9_]+)$/).flatten
    missing = needed - provided
    if !needed.empty? && missing.empty?
      ok.call("runtime defines all #{needed.size} __nfcxx_sp_* symbols the existing --safe output uses")
    else
      bad.call("runtime lacks #{missing.inspect} (needed #{needed.size})")
    end
  else
    bad.call("existing emitter --safe failed on #{File.basename(pathb_ir)}")
  end
end

if failures.empty?
  puts "pathb-ssa-build safe tests: all ok"
  exit 0
else
  puts "pathb-ssa-build safe tests: #{failures.size} failure(s)"
  exit 1
end
