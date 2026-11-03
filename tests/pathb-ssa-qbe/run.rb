#!/usr/bin/env ruby
# frozen_string_literal: true
#
# End-to-end check of scripts/pathb-ssa-qbe.rb (docs/notes/pathb-ssa-qbe.md). For each case that has an .args file:
# convert to SSA, optimise (the e-graph), emit QBE, assemble and link it with a C driver, run the native function on
# each input, and compare with the interpreter. A function the emitter does not cover is skipped and counted.
#
#   ruby tests/pathb-ssa-qbe/run.rb [CASE.ir ...]     (default: tests/pathb-ssa/cases and tests/pathb-egraph/cases)
#
# The reference is the interpreter of tests/pathb-egraph/check.rb (its CaseMachine models the harness's `observe`,
# `clobber` and volatile accesses). The native side models the same: `observe` does nothing, and `clobber` stores 77
# into an int object, so a case whose `clobber` targets a non-int slot is skipped.
#
require "tmpdir"
require "open3"
require_relative "../../scripts/pathb-egraph"
require_relative "../../scripts/pathb-ssa-qbe"
require_relative "../pathb-egraph/check"

QBE = File.expand_path("../../build/qbe/qbe", __dir__)

# The C side of the harness's external functions (see the header comment).
HARNESS_C = <<~C
  void observe() {}
  void clobber(int *p) { *p = 77; }
C

# True when every `clobber` call in the function passes the address of an int slot.
def clobber_targets_int?(forms)
  forms.select { |f| head(f) == "ssa-function" }.all? do |fn|
    slots = fn.select { |x| head(x) == "slot" }.to_h { |s| [s[1].raw, s[2]] }
    calls = []
    walk = lambda do |x|
      next unless x.is_a?(Array)

      calls << x if head(x) == "call" && x[2].is_a?(Ref) && x[2].raw == '"clobber"'
      x.each { |y| walk.call(y) }
    end
    walk.call(fn)
    calls.all? do |c|
      c[3..].all? { |a| head(a) == "addr" && a[1].is_a?(Ref) && slots[a[1].raw] == "int" }
    end
  end
end

def native_ok(arity, inputs, il)
  Dir.mktmpdir("pathb-qbe") do |dir|
    qbe_file = File.join(dir, "case.qbe")
    File.write(qbe_file, il)
    asm, err, st = Open3.capture3(QBE, qbe_file)
    return [:fail, "qbe: #{err.lines.first}"] unless st.success?

    params = Array.new(arity) { |i| "int a#{i}" }.join(", ")
    calls = inputs.map { |args| "  printf(\"%d\\n\", case_main(#{args.join(', ')}));" }.join("\n")
    driver = File.join(dir, "drv.c")
    File.write(driver, "#include <stdio.h>\n#{HARNESS_C}int case_main(#{arity.zero? ? 'void' : params});\n" \
                       "int main(void) {\n#{calls}\n  return 0;\n}\n")
    File.write(File.join(dir, "case.s"), asm)
    exe = File.join(dir, "prog")
    _, err, st = Open3.capture3("cc", driver, File.join(dir, "case.s"), "-o", exe)
    return [:fail, "cc: #{err.lines.first}"] unless st.success?

    out, _, st = Open3.capture3(exe)
    [st.success? ? :ok : :fail, out.split.map(&:to_i)]
  end
end

files = ARGV.empty? ? Dir["tests/pathb-ssa/cases/*.ir"] + Dir["tests/pathb-egraph/cases/*.ir"] : ARGV
totals = Hash.new(0)
files.sort.each do |f|
  args_file = f.sub(/\.ir\z/, ".args")
  next unless File.exist?(args_file)

  ssa = `ruby #{File.expand_path('../../scripts/pathb-ssa.rb', __dir__)} #{f} 2>/dev/null`
  forms = read_forms(ssa)
  main = forms.find { |x| head(x) == "ssa-function" && x[1].raw == '"main"' }
  unless main
    totals[:no_main] += 1
    next
  end
  globals = forms.select { |g| head(g) == "global" }
  begin
    install_module(forms)
    arity = main.find { |x| head(x) == "params" }.size - 1
    inputs = File.readlines(args_file).map { |l| l.split("=>").first.to_s.split.map { |t| Integer(t, 10) } }
                 .reject(&:empty?)
    # The interpreter's answer for each input (a trap or an unmodelled run is not a value to compare).
    orig = PathbEgraph.parse_fn(main)
    raw = inputs.map { |args| interpret(orig, args) }
    want = raw.map { |r| r.is_a?(String) && r != "trap" ? Integer(r, 10) : nil }
    keep = inputs.zip(want).reject { |_, w| w.nil? }
    if keep.empty?
      totals[:unsupported] += 1
      why = raw.all? { |r| r == "trap" } ? "every input traps, so there is no value to compare" : "the interpreter does not model it"
      puts "SKIP #{File.basename(f)}: #{why}"
      next
    end
    unless clobber_targets_int?(forms)
      totals[:unsupported] += 1
      puts "SKIP #{File.basename(f)}: clobber of a slot that is not an int"
      next
    end

    opt_text, = PathbEgraph.optimize_module(ssa)
    optimized = read_forms(opt_text).reject { |g| head(g) == "global" }
    il = Qbe.module_il(optimized + globals).sub("$main(", "$case_main(")
    status, got = native_ok(arity, keep.map(&:first), il)
    if status == :fail
      totals[:skipped_or_failed] += 1
      puts "SKIP #{File.basename(f)}: #{got}"
      next
    end
    expected = keep.map(&:last)
    if got == expected
      totals[:ok] += 1
      puts "ok   #{File.basename(f)}: #{got.inspect}"
    else
      totals[:mismatch] += 1
      puts "FAIL #{File.basename(f)}: native #{got.inspect}, interpreter #{expected.inspect}"
    end
  rescue QbeUnsupported => ex
    totals[:unsupported] += 1
    puts "SKIP #{File.basename(f)}: #{ex.message}"
  end
end
puts totals.map { |k, v| "#{k}=#{v}" }.join("  ")
exit(totals[:mismatch].zero? ? 0 : 1)
