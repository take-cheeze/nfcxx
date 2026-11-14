#!/usr/bin/env ruby
# How many C files does nfcc's pathb backend build, and why are the others refused (count per reason)?
#   scripts/nfcc-pathb-measure.rb [-o REPORT] FILE.c...        compile each file with `nfcc -c` on NFCXX_BACKEND=pathb
#   NFCC_MEASURE_FLAGS="-Iinc -DX"   options given to every compile (the kernel's -nostdinc, -isystem, -funsigned-char, -mno-sse ... included:
#                                    nfcc honours them on Path B, or sends the compile to gcc; a compile gcc made is counted as "gcc", not built)
# Prints one line per file (ok, or the refusal) to REPORT (default stdout), then the table: built, and each reason with its
# count. A reason is the first message line with paths, numbers and names inside quotes removed. docs/notes/linux-kernel.md.
require "fileutils"
$stdout.sync = true
$stderr.sync = true

root = File.expand_path("..", File.dirname($PROGRAM_NAME))
rep = "/dev/stdout"
argv = ARGV.dup
if argv[0] == "-o"
  argv.size >= 2 or (warn "#{$PROGRAM_NAME}: 2: unbound variable"; exit 1)
  rep = argv[1]
  argv = argv[2..]
end

tmp = `mktemp -d`.chomp
exit 1 unless $?.success?

def run_status(env, *argv, out: nil, err_to_out: false)
  opts = {}
  opts[:out] = out if out
  opts[:err] = [:child, :out] if err_to_out
  ok = system(env, [argv[0], argv[0]], *argv[1..], **opts)
  return 127 if ok.nil?

  $?.exitstatus || (128 + $?.termsig)
end

# sed s/// without the g flag replaces the first match only
def sub_first(s, re, rep)
  s.sub(re, rep)
end

begin
  res = []
  built = 0
  total = 0
  gcc_made = 0
  flags = ENV["NFCC_MEASURE_FLAGS"].to_s.split
  argv.each do |f|
    total += 1
    log = File.join(tmp, "log")
    outf = File.join(tmp, "out")
    File.write(log, "")
    env = { "NFCXX_PATHB_LOG" => log, "NFCXX_BACKEND" => "pathb" }
    rc = run_status(env, File.join(root, "nfcc"), "-c", *flags, f, "-o", File.join(tmp, "o.o"),
                    out: outf, err_to_out: true)
    log_lines = File.read(log).lines.map(&:chomp)
    if rc.zero? && log_lines.any? { |l| l.start_with?("gcc ") }
      last = log_lines.map { |l| l.sub(/^gcc [^:]*: /, "") }.last
      res << "gcc #{f}: #{last}"
      gcc_made += 1
    elsif rc.zero?
      built += 1
      res << "ok #{f}"
    else
      out_lines = File.read(outf).lines.map(&:chomp)
      # the last line that names the refusal: the SSA route's, or the front end's error; paths, quoted names and numbers removed
      msg = out_lines.grep(/SSA route:|error|nfcc: error|not supported/).last
      msg ||= out_lines.reject { |l| l.match?(/\A *\z/) }.last
      msg = msg.to_s
      msg = sub_first(msg, /\Apathb-cc: [^ ]*: /, "")
      msg = sub_first(msg, /pathb-ssa-build: not emitted: [^:]*: /, "")
      msg = sub_first(msg, /\A"[^"]*", line [0-9]+: /, "")
      msg = msg.gsub(%r{[A-Za-z0-9_.+-]*/[A-Za-z0-9_./+-]+}, "")
      msg = msg.gsub(/"[^"]*"/, '"X"')
      msg = msg.gsub(/'[^']*'/, "X")
      msg = msg.gsub(/[0-9]+/, "N")
      msg = msg.gsub(/ +/, " ")
      res << "refused(#{rc}) #{f}: #{msg[0, 120]}"
    end
  end

  lines = []
  lines.concat(res)
  lines << ""
  lines << "built #{built} of #{total}"
  lines << "made by gcc (an option Path B cannot honour): #{gcc_made}" unless gcc_made.zero?
  refused = res.select { |l| l.start_with?("refused") }
  counts = Hash.new(0)
  refused.each do |l|
    key = l.sub(/\Arefused\(([0-9]+)\) [^:]*: /, '\1: ')
    counts[key] += 1
  end
  # uniq -c | sort -rn: the count, then the line, both descending
  rows = counts.map { |k, c| format("%7d %s", c, k) }
  rows.sort { |a, b| [b.to_i, b] <=> [a.to_i, a] }.each { |r| lines << r }
  File.write(rep, lines.map { |l| "#{l}\n" }.join)
  exit(refused.empty? ? 1 : 0)
ensure
  FileUtils.rm_rf(tmp)
end
