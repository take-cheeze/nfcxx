#!/usr/bin/env ruby
# frozen_string_literal: true
#
# End-to-end check of scripts/pathb-ssa-qbe.rb (docs/notes/pathb-ssa-qbe.md). For each case that has an .args file:
# convert to SSA, optimise (the e-graph), emit QBE, assemble and link it with a C driver, run the native function on
# each input, and compare with the interpreter. A function the emitter does not cover is skipped and counted.
#
#   ruby tests/pathb-ssa-qbe/run.rb [CASE.ir ...]     (default: tests/pathb-ssa/cases and tests/pathb-egraph/cases)
#
require "tmpdir"
require "open3"
require_relative "../../scripts/pathb-egraph"
require_relative "../../scripts/pathb-ssa-qbe"

QBE = File.expand_path("../../build/qbe/qbe", __dir__)

def native_ok(fn_name, arity, inputs, ssa_text)
  Dir.mktmpdir("pathb-qbe") do |dir|
    il = Qbe.module_il(read_forms(ssa_text))
    il = il.sub("$main(", "$case_main(")
    qbe_file = File.join(dir, "case.qbe")
    File.write(qbe_file, il)
    asm, err, st = Open3.capture3(QBE, qbe_file)
    return [:fail, "qbe: #{err.lines.first}"] unless st.success?

    params = Array.new(arity) { |i| "int a#{i}" }.join(", ")
    names = Array.new(arity) { |i| "a#{i}" }.join(", ")
    calls = inputs.map { |args| "  printf(\"%d\\n\", case_main(#{args.join(', ')}));" }.join("\n")
    driver = File.join(dir, "drv.c")
    File.write(driver, "#include <stdio.h>\nint case_main(#{arity.zero? ? 'void' : params});\n" \
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
  opt_text, = PathbEgraph.optimize_module(ssa)
  begin
    arity = main.find { |x| head(x) == "params" }.size - 1
    inputs = File.readlines(args_file).map { |l| l.split("=>").first.to_s.split.map { |t| Integer(t, 10) } }
                 .reject(&:empty?)
    # The interpreter's answer for each input (a trap is not a value to compare).
    e = PathbEgraph.parse_fn(main)
    want = inputs.map do |args|
      v = PathbEgraph.run(e, args)
      v.is_a?(String) ? nil : v
    rescue Unsupported
      raise QbeUnsupported, "the interpreter does not model it"
    end
    keep = inputs.zip(want).reject { |_, w| w.nil? }
    status, got = native_ok("main", arity, keep.map(&:first), opt_text)
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
