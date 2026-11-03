#!/usr/bin/env ruby
# frozen_string_literal: true
#
# Checks for scripts/pathb-ssa-build (docs/notes/pathb-ssa-build.md):
#   - a case that the emitter covers: the assembly, linked with a C driver, gives the .args results (status 0);
#   - a case with a function the emitter does not cover: status 3, the reason on stderr, and no assembly for that
#     function (the rest is still written);
#   - a usage error: status 2.
#
#   ruby tests/pathb-ssa-build/run.rb
#
require "open3"
require "rbconfig"
require "tmpdir"

ROOT = File.expand_path("../..", __dir__)
DRIVER = File.join(ROOT, "scripts/pathb-ssa-build")

def run_driver(*args)
  Open3.capture3(RbConfig.ruby, DRIVER, *args, chdir: ROOT)
end

def expected_inputs(args_file)
  File.readlines(args_file).map(&:strip).reject(&:empty?).map do |line|
    inp, want = line.split("=>").map(&:strip)
    [inp.split.map { |t| Integer(t, 10) }, Integer(want, 10)]
  end
end

failures = []

# 1. A covered case: the native results equal the .args expectations.
case_ir = File.join(ROOT, "tests/pathb-ssa/cases/ternary_set.ir")
cases = expected_inputs(case_ir.sub(/\.ir\z/, ".args"))
Dir.mktmpdir("pathb-ssa-build-test") do |dir|
  asm_path = File.join(dir, "case.s")
  _, err, st = run_driver("-o", asm_path, case_ir)
  if st.success?
    # The case's `main` is renamed so the C driver can provide its own main.
    asm = File.read(asm_path).gsub(/\bmain\b/, "case_main")
    File.write(asm_path, asm)
    params = Array.new(cases.first[0].size) { |i| "int a#{i}" }.join(", ")
    calls = cases.map { |inp, _| "  printf(\"%d\\n\", case_main(#{inp.join(', ')}));" }.join("\n")
    driver = File.join(dir, "drv.c")
    File.write(driver, "#include <stdio.h>\nint case_main(#{params});\nint main(void) {\n#{calls}\n  return 0;\n}\n")
    exe = File.join(dir, "prog")
    _, cc_err, cc_st = Open3.capture3("cc", driver, asm_path, "-o", exe)
    if cc_st.success?
      out, _, run_st = Open3.capture3(exe)
      got = out.split.map(&:to_i)
      want = cases.map(&:last)
      if run_st.success? && got == want
        puts "ok   covered case: #{got.inspect}"
      else
        failures << "covered case: native #{got.inspect}, want #{want.inspect}"
      end
    else
      failures << "covered case: cc failed: #{cc_err.lines.first}"
    end
  else
    failures << "covered case: status #{st.exitstatus}: #{err.lines.first}"
  end
end

# 2. A function the emitter does not cover: status 3, the reason named, the assembly still written.
partial_src = <<~IR
  (ir-module "p.cpp" (layout (short 2) (int 4) (long 8) (long_long 8) (pointer 8) (float 4) (double 8) (long_double 16)))
  (function "ld_id"
    (ret int)
    (params (param %0 "x" long_double))
    (return (const int 0)))
  (function "main"
    (ret int)
    (params (param %0 "n" int))
    (return (wadd int %0 (const int 1))))
IR
Dir.mktmpdir("pathb-ssa-build-test") do |dir|
  asm_path = File.join(dir, "partial.s")
  partial_ir = File.join(dir, "partial.ir")
  File.write(partial_ir, partial_src)
  _, err, st = run_driver("-o", asm_path, partial_ir)
  asm = File.exist?(asm_path) ? File.read(asm_path) : ""
  if st.exitstatus == 3 && err.include?("not emitted: ld_id: type long_double") && asm.include?("\nmain:") && !asm.include?("ld_id:")
    puts "ok   partial module: status 3, reason reported, the other function emitted"
  else
    failures << "partial module: status #{st.exitstatus}, stderr #{err.inspect}, main emitted #{asm.include?("\nmain:")}"
  end
end

# 3. Usage error.
_, _, st = run_driver
if st.exitstatus == 2
  puts "ok   no arguments: status 2"
else
  failures << "no arguments: status #{st.exitstatus}, want 2"
end

failures.each { |m| puts "FAIL #{m}" }
puts failures.empty? ? "ok   pathb-ssa-build tests" : "FAIL pathb-ssa-build tests: #{failures.size} failure(s)"
exit(failures.empty? ? 0 : 1)
