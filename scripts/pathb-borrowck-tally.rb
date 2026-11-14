#!/usr/bin/env ruby
# Tally the Path B borrow checker's verdicts over lowered C++ programs (docs/notes/pathb-borrowck.md, "Refusals and
# limits"): each file is lowered with NFCXX_PATHB_BORROW=1 scripts/pathb-dump --ir and checked in four modes:
#   plain   no options
#   infer   --infer-loan-ends --infer-summaries
#   effects infer, plus --effects scripts/pathb-runtime.effects --effects scripts/pathb-libc.effects
#   emitted effects, plus --emitted-only (the functions the QBE emitter keeps)
# Prints, per mode, the count of each exit status (0 accepted, 1 error, 2 malformed, 3 refused) and of each refusal
# message (digits folded). The checker stops at its first refusal, so a message is the first one in the program.
# Usage: scripts/pathb-borrowck-tally.rb [-o DIR] [FILE.cpp...]
#   default files: tests/pathb-ir, tests/cases, tests/cpp-features, tests/cpp2, tests/pathb-borrow/{cpp,contracts}
#   -o DIR keeps the IR and DIR/MODE.tsv (file, exit status, first message) there
# Ported from scripts/pathb-borrowck-tally.sh; the output is the same. The file lists come from ls, find and sort,
# and the refusal counts from sort, uniq and sort -rn, as the script runs them.

require "fileutils"
require "open3"
require "tmpdir"

ROOT = File.expand_path(File.join(File.dirname($0), ".."))
Dir.chdir(ROOT)

MODES = {
  "plain" => [],
  "infer" => ["--infer-loan-ends", "--infer-summaries"],
  "effects" => ["--infer-loan-ends", "--infer-summaries", "--effects", "scripts/pathb-runtime.effects",
                "--effects", "scripts/pathb-libc.effects"],
}
MODES["emitted"] = MODES["effects"] + ["--emitted-only"]

# Runs a command with its output sent to files (or discarded); returns the exit status as the shell reports it.
def run(env, argv, out: nil, err: nil)
  opts = {}
  opts[:out] = out if out
  opts[:err] = err if err
  ok = system(env, *argv, **opts)
  return 127 if ok.nil?
  $?.exitstatus || 128 + $?.termsig
end

# The contents of a file the command may not have written.
def slurp(path)
  File.exist?(path) ? File.binread(path) : "".b
end

# ls on the given paths (its own sort order); the script discards its errors.
def ls_names(paths)
  return [] if paths.empty?
  out, = Open3.capture2("ls", *paths, err: File::NULL)
  out.lines(chomp: true)
end

def default_files
  first = Dir.glob(%w[tests/pathb-ir/*.cpp tests/pathb-ir/borrow/*.cpp tests/cases/*.cpp])
  found, = Open3.capture2("find", "tests/cpp-features", "tests/cpp2", "-name", "*.cpp", err: File::NULL)
  sorted, = Open3.capture2("sort", stdin_data: found)
  last = Dir.glob(%w[tests/pathb-borrow/cpp/*.cpp tests/pathb-borrow/contracts/*.cpp])
  ls_names(first) + sorted.lines(chomp: true) + ls_names(last)
end

# The name of a program's IR file in the output directory.
def ir_path(out, file)
  File.join(out, "ir", "#{file.tr('/', '_')}.ir")
end

# Lowers each file; then checks the lowered ones in each mode. Returns the exit status (0).
def tally(out, files)
  FileUtils.mkdir_p(File.join(out, "ir"))
  lowered = 0
  failed = 0
  files.each do |f|
    ir = ir_path(out, f)
    if run({ "NFCXX_PATHB_BORROW" => "1" }, ["scripts/pathb-dump", "--ir", f], out: ir, err: File::NULL) == 0
      lowered += 1
    else
      FileUtils.rm_f(ir)
      failed += 1
    end
  end
  puts "#{lowered} programs lowered, #{failed} not lowered by the front end"

  stdout_file = File.join(out, "stdout")
  stderr_file = File.join(out, "stderr")
  MODES.each do |mode, opts|
    tsv = File.join(out, "#{mode}.tsv")
    File.write(tsv, "")
    rows = []
    files.each do |f|
      ir = ir_path(out, f)
      next unless File.file?(ir)
      rc = run({}, ["scripts/mrb", "scripts/pathb-borrowck.rb", *opts, ir], out: stdout_file, err: stderr_file)
      # The first line of the checker's stderr, then its stdout, that is not an "inferred:" line.
      msg = (slurp(stderr_file).lines + slurp(stdout_file).lines)
            .reject { |l| l.start_with?("inferred:") }.first.to_s.delete_suffix("\n")
      line = "#{f.b}\t#{rc}\t#{msg.b}"
      File.open(tsv, "ab") { |io| io.write("#{line}\n") }
      rows << line
    end

    counts = Hash.new(0)
    rows.each { |line| counts[line.split("\t", -1)[1].to_i] += 1 }
    puts "== #{mode}: #{counts[0]} accepted, #{counts[1]} errors, #{counts[2]} malformed, #{counts[3]} refused"

    refused = rows.map { |line| line.split("\t", -1) }
                  .select { |fields| fields[1] == "3" }
                  .map { |fields| fields[2].to_s.gsub(/[0-9]+/, "N") }
    sorted, = Open3.capture2("sort", stdin_data: refused.map { |m| "#{m}\n" }.join.b)
    counted, = Open3.capture2("uniq", "-c", stdin_data: sorted)
    ranked, = Open3.capture2("sort", "-rn", stdin_data: counted)
    $stdout.binmode.write(ranked)
    $stdout.flush
  end
  0
end

args = ARGV.dup
out = ""
if args.first == "-o"
  args.shift
  if args.empty?
    warn "usage: scripts/pathb-borrowck-tally.rb [-o DIR] [FILE.cpp...]"
    exit 1
  end
  out = args.shift
end
files = args.empty? ? default_files : args

if out.empty?
  Dir.mktmpdir do |dir|
    exit tally(dir, files)
  end
else
  exit tally(out, files)
end
