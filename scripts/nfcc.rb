#!/usr/bin/env ruby
# nfcc: the C driver, in Ruby (stage 8 of docs/notes/driver-port-plan.md). The decisions are scripts/driver-loop.rb's: its option
# loop, Path B, the compile and link commands, checked against the bash driver by tests/nfcc/loop-state.sh. This file does what
# the bash does at its start (the environment, the host's answers, the temporary directory, the backend choice) and then runs the
# commands the decisions name. The bundle and CUDA wrappers (--bundle-*, --cuda-driver=, a libcuda on the link line) are still
# the bash's: a command line that uses them is run by ./nfcc.
#
#   ruby scripts/nfcc.rb ARG...

require "etc"
require "fileutils"
require "tmpdir"
require_relative "nfcc-args"

ROOT = File.expand_path("..", __dir__)
BASH_NFCC = File.join(ROOT, "nfcc")

$nfcc_front = true
require_relative "driver-loop"

# the output of a command, and whether it succeeded (stderr as given)
def capture_stdout(argv, err: File::NULL)
  out = IO.popen(argv, err: err, &:read)
  [out, $?.success?]
rescue SystemCallError
  ["", false]
end

# the arguments the bash wrappers handle (scripts/bundle-wrap.sh, scripts/cuda-driver-wrap.sh); those command lines are the bash's
def bash_wrapper_arg?(arg)
  arg.start_with?("--bundle-") || arg.start_with?("--cuda-driver=") ||
    ["-lcuda", "-l:libcuda.so", "-l:libcuda.so.1"].include?(arg) ||
    arg.end_with?("/libcuda.so", "/libcuda.so.1")
end

# nfcc's start: the environment decides the backend, the host's answers are asked when needed (the version, the host preprocessor)
def front_setup(config)
  env = config[:env]
  uname = Etc.uname
  host = ENV["NFCC_HOST_CC"].to_s
  host = "cc" if host.empty?
  env.root = ROOT
  env.cwd = Dir.pwd
  env.os = uname[:sysname]
  env.host = host
  $nfcc_tmp_dir = Dir.mktmpdir("nfcc")
  env.tmp = $nfcc_tmp_dir
  log = ENV["NFCXX_PATHB_LOG"].to_s
  env.pathb_log = log unless log.empty?
  edg = ENV["EDG_BUILD"].to_s
  env.edg_build = edg unless edg.empty?

  # the backend, as nfcc chooses it: Path B on x86-64 or arm64 Linux when the harness and QBE are built, else gcc
  backend = ENV["NFCXX_BACKEND"].to_s
  fallback = ENV["NFCXX_PATHB_FALLBACK"].to_s
  if backend.empty?
    cpfe = ENV["PATHB_CPFE"].to_s
    cpfe = File.join(ROOT, "build/pathb/cmake/bin/cpfe") if cpfe.empty?
    pathb_ready = uname[:sysname] == "Linux" && %w[x86_64 aarch64 arm64].include?(uname[:machine]) &&
                  File.executable?(cpfe) && File.executable?(File.join(ROOT, "build/qbe/qbe")) &&
                  File.executable?(File.join(ROOT, "scripts/pathb-cc.rb"))
    if pathb_ready
      backend = "pathb"
      fallback = "gcc" if fallback.empty?
      ENV["NFCXX_PATHB_FALLBACK"] = fallback
    else
      backend = "gcc"
    end
  end
  config[:backend] = backend
  env.pathb_fallback = fallback == "gcc"
  config[:passthrough] = !ENV["NFCXX_GCC_PASSTHROUGH"].to_s.empty?
  gnu_out, _ok = capture_stdout(["gcc", "--version"], err: File::NULL)
  config[:host_gnu_gcc] = gnu_out.include?("Free Software Foundation")

  # the values nfcc asks the host or a helper for, when a command needs them
  env.ldrt = lambda do
    out = IO.popen([File.join(ROOT, "scripts/pathb-ldrt.rb")], &:read)
    out.sub(/\n+\z/, "")
  end
  env.dumpfullversion = lambda do
    out, ok = capture_stdout([host, "-dumpfullversion"])
    (ok ? out : "#{out}0\n").sub(/\n+\z/, "")
  end
  env.host_version_line = lambda do
    line = begin
      IO.popen([host, "--version"], &:read).lines.first
    rescue SystemCallError
      nil
    end
    line.to_s.chomp
  end
  # -fshort-wchar: the host preprocessor shows a wide literal (the same options, as nfcc's pathb_reason runs it)
  env.wide_literal = lambda do |state, csrc|
    wide = File.join(env.tmp, "wide#{state.k}.i")
    ok = system(host, "-E", "-P", *state.gccf, *state.pp, "-x", "c", csrc, out: wide, err: File::NULL)
    next :failed unless ok

    File.foreach(wide).any? { |line| line.match?(/(^|[^A-Za-z0-9_"'])L["']/) }
  end
end

# nfcc's commands and file operations, run for the decisions of driver-loop.rb
class NfccEffects
  # the command's status; a command that cannot be started has the status 127, as in the shell
  def run(argv, environment)
    $stdout.flush
    $stderr.flush
    ok = environment ? system(environment, *argv) : system(*argv)
    return 0 if ok

    status = $?
    status.exitstatus || (128 + status.termsig.to_i)
  end

  def copy(from, to)
    FileUtils.cp(from, to)
    0
  rescue SystemCallError
    raise PathbExit.new(1)
  end

  def cat(path)
    $stdout.write(File.binread(path))
    0
  rescue SystemCallError
    raise PathbExit.new(1)
  end

  def stdin_to(path)
    File.binwrite(path, $stdin.binmode.read)
    0
  rescue SystemCallError
    raise PathbExit.new(1)
  end

  def symlink(target, path)
    File.symlink(target, path)
    0
  rescue SystemCallError
    raise PathbExit.new(1)
  end

  # exec: the process is replaced, so the temporary directory goes first
  def exec(argv)
    $stdout.flush
    FileUtils.rm_rf($nfcc_tmp_dir) if $nfcc_tmp_dir
    Kernel.exec(*argv)
  end
end

def front_main(argv)
  # the bash wrappers' command lines go to ./nfcc unchanged (the same arguments, expanded the same way)
  if NfccArgs.expand_args(argv.dup).any? { |a| bash_wrapper_arg?(a) }
    Kernel.exec(BASH_NFCC, *argv)
  end
  main(argv)
ensure
  FileUtils.rm_rf($nfcc_tmp_dir) if $nfcc_tmp_dir
end

if $PROGRAM_NAME == __FILE__
  $nfcc_setup = ->(config) { front_setup(config) }
  $nfcc_effects = NfccEffects.new
  rc = front_main(ARGV.dup)
  $stdout.flush
  exit(rc) if rc != 0
end
