#!/usr/bin/env ruby
# Borrow-check a Rust program's own functions with scripts/pathb-borrowck.rb, through mrustc's
# monomir dump (see docs/notes/mrustc-borrowck.md). mrustc itself has no borrow checker.
#   scripts/mrustc-borrowck.rb prog.rs [mrustc flags...]
# Exit status is the checker's: 0 accepted, 1 a borrow or initialization error, 2 malformed IR,
# 3 refused (outside the supported subset). 4 means mrustc or the translator failed.
#   MRUSTC=<bin>, MRUSTC_STD=<dir>  as for scripts/mrustc-monomir.sh
#   MRUSTC_BORROWCK_KEEP=<dir>      keep the dump (prog.mir) and the checker input (prog.ir) there
# Ported from scripts/mrustc-borrowck.sh; the output and the exit status are the same.

require "fileutils"
require "tmpdir"

start = Dir.pwd
root = File.expand_path(File.join(File.dirname($0), ".."))
Dir.chdir(root)

def fail_with(message, status)
  warn message
  exit status
end

mrustc = ENV["MRUSTC"].to_s.empty? ? File.join(Dir.pwd, "build/mrustc/src/bin/mrustc") : ENV["MRUSTC"]
std = ENV["MRUSTC_STD"].to_s.empty? ? File.join(Dir.pwd, "build/mrustc/src/output-1.90.0") : ENV["MRUSTC_STD"]

src = nil
extra = []
ARGV.each do |a|
  if a.end_with?(".rs")
    src = a
  else
    extra << a
  end
end
fail_with("usage: scripts/mrustc-borrowck.rb prog.rs [mrustc flags...]", 4) unless src
src = "#{start}/#{src}" unless src.start_with?("/")
unless File.executable?(mrustc) && File.file?(File.join(std, "libstd.rlib.o"))
  fail_with("mrustc-borrowck: no mrustc or standard library; run scripts/setup-mrustc.sh", 4)
end

# The lines the script prints for a mrustc failure that is a verdict on the program (the checker's
# errors are reported the same way), or nil when the log shows none.
def verdict_lines(log)
  lines = File.binread(log).lines.map { |l| l.delete_suffix("\n") }
  if lines.any? { |l| l.match?(/\AMIR ERROR: .*Use of non-valid lvalue/) }
    return lines.select { |l| l.start_with?("MIR ERROR: ") }
                .map { |l| l.sub("MIR ERROR: ", "mrustc-mir-validation: ") }.first(1)
  end
  if lines.any? { |l| l.match?(/error:0: Lifetime bound .* failed/) }
    return lines.map { |l| l[/\A.* error:0: (Lifetime bound .* failed.*)\z/, 1] }
                .compact.map { |l| "mrustc-lifetime: #{l}" }.first(1)
  end
  nil
end

def run_checker(root, tmp)
  mrb = File.join(root, "scripts/mrb")
  checker = File.join(root, "scripts/pathb-borrowck.rb")
  system(mrb, checker, "--infer-loan-ends", "--infer-summaries", File.join(tmp, "prog.ir"))
  $?.exitstatus || 128 + $?.termsig
end

def check(src, extra, mrustc, std, tmp, root)
  log = File.join(tmp, "mrustc.log")
  env = { "MRUSTC_MMIR_SCOPE_END" => "1", "MRUSTC_TARGET_VER" => ENV["MRUSTC_TARGET_VER"].to_s.empty? ? "1.90" : ENV["MRUSTC_TARGET_VER"] }
  ok = system(env, mrustc, src, "-o", File.join(tmp, "prog"), "-L", std,
              "--edition", "2021", "-C", "codegen-type=monomir", "-Z", "disable-mir-opt",
              "-Z", "dump-hir", "-Z", "dump-ast", *extra, out: log, err: [:child, :out])
  unless ok
    verdict = verdict_lines(log)
    if verdict
      verdict.each { |l| puts l }
      return 1
    end
    lines = File.binread(log).lines
    $stderr.write(lines.last(20).join)
    fail_with("mrustc-borrowck: mrustc failed", 4)
  end

  ok = system("ruby", File.join(root, "scripts/monomir-to-pathb.rb"), "--borrow",
              "--hir", File.join(tmp, "prog_2_hir.rs"), "--ast", File.join(tmp, "prog_1_ast.rs"),
              File.join(tmp, "prog.mir"), File.join(tmp, "prog.ir"))
  fail_with("mrustc-borrowck: monomir-to-pathb failed", 4) unless ok

  run_checker(root, tmp)
end

status =
  if ENV["MRUSTC_BORROWCK_KEEP"].to_s.empty?
    Dir.mktmpdir { |tmp| check(src, extra, mrustc, std, tmp, root) }
  else
    tmp = ENV["MRUSTC_BORROWCK_KEEP"]
    FileUtils.mkdir_p(tmp)
    check(src, extra, mrustc, std, tmp, root)
  end
exit status
