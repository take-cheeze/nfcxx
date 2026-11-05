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
  void __pathb_escape(void *p) { (void)p; }
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

# The C type of each IR scalar that a case's parameter may have (see main's ctypes in the case loop).
C_TYPES = { "long" => "long", "long_long" => "long long", "unsigned_long" => "unsigned long",
            "unsigned_int" => "unsigned int", "int" => "int" }.freeze

def native_ok(arity, inputs, il, ctypes = nil)
  Dir.mktmpdir("pathb-qbe") do |dir|
    qbe_file = File.join(dir, "case.qbe")
    File.write(qbe_file, il)
    asm, err, st = Open3.capture3(QBE, qbe_file)
    return [:fail, "qbe: #{err.lines.first}"] unless st.success?

    # the parameters' C types: each is int unless the case says otherwise (long for the 64-bit cases)
    ctypes ||= Array.new(arity, "int")
    params = Array.new(arity) { |i| "#{ctypes[i]} a#{i}" }.join(", ")
    # Each input runs under setjmp: the emitted code calls pathb_check(cond, code), which longjmps out with the code
    # when cond is nonzero, and that input prints "trap" (the interpreter's answer for it).
    calls = inputs.map do |args|
      "  if (setjmp(trap_buf)) printf(\"trap\\n\"); else printf(\"%d\\n\", case_main(#{args.join(', ')}));"
    end.join("\n")
    driver = File.join(dir, "drv.c")
    File.write(driver, "#include <stdio.h>\n#include <setjmp.h>\n#{HARNESS_C}static jmp_buf trap_buf;\n" \
                       "void pathb_check(int cond, int code) { if (cond) longjmp(trap_buf, code); }\n" \
                       "int case_main(#{arity.zero? ? 'void' : params});\n" \
                       "int main(void) {\n#{calls}\n  return 0;\n}\n")
    File.write(File.join(dir, "case.s"), asm)
    exe = File.join(dir, "prog")
    _, err, st = Open3.capture3("cc", driver, File.join(dir, "case.s"), "-o", exe)
    return [:fail, "cc: #{err.lines.first}"] unless st.success?

    out, _, st = Open3.capture3(exe)
    [st.success? ? :ok : :fail, out.split.map { |t| t == "trap" ? t : t.to_i }]
  end
end

files = ARGV.empty? ? Dir["tests/pathb-ssa/cases/*.ir"] + Dir["tests/pathb-egraph/cases/*.ir"] + Dir["tests/pathb-ssa-qbe/cases/*.ir"] : ARGV
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
    # the C type of each parameter (the 64-bit and unsigned cases need theirs; anything else is int)
    ctypes = main.find { |x| head(x) == "params" }.drop(1).map { |p| C_TYPES.fetch(p[3], "int") }
    lines = File.readlines(args_file).map(&:strip).reject(&:empty?)
    inputs = lines.map { |l| l.split("=>").first.split.map { |t| Integer(t, 10) } }
    # The `=> value` on each line: the expected answer, used where the interpreter does not model the function.
    file_want = lines.map { |l| l.split("=>")[1]&.strip }
    # The interpreter's answer for each input: a value, "trap" (compared with the native longjmp), or unmodelled.
    orig = PathbEgraph.parse_fn(main)
    raw = inputs.map { |args| interpret(orig, args) }
    want = raw.each_index.map do |i|
      r = raw[i]
      if r.is_a?(String)
        r == "trap" ? "trap" : Integer(r, 10)
      else
        fw = file_want[i]
        fw.nil? ? nil : (fw == "trap" ? "trap" : Integer(fw, 10))
      end
    end
    from_file = raw.each_index.count { |i| !raw[i].is_a?(String) && !want[i].nil? }
    keep = inputs.zip(want).reject { |_, w| w.nil? }
    if keep.empty?
      totals[:unsupported] += 1
      puts "SKIP #{File.basename(f)}: the interpreter does not model it"
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
    status, got = native_ok(arity, keep.map(&:first), il, ctypes)
    if status == :fail
      totals[:skipped_or_failed] += 1
      puts "SKIP #{File.basename(f)}: #{got}"
      next
    end
    expected = keep.map(&:last)
    if got == expected
      totals[:ok] += 1
      note = from_file.positive? ? " (#{from_file} input(s) checked against the .args values: the interpreter does not model them)" : ""
      puts "ok   #{File.basename(f)}: #{got.inspect}#{note}"
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
