#!/usr/bin/env ruby
# nfcxx, the CRuby driver: the entry point that replaces the bash driver (nfcxx) one step at a time. Four ways run the
# arguments, in this order:
#   1. the pre-loop plan (scripts/nfcxx-loop.rb): the re-runs it models (-fsyntax-only, --bundle-*, the CUDA driver step)
#      print RUN and EXEC lines, and the runner (scripts/nfcxx-run.rb) runs them;
#   2. the gcc plan (scripts/nfcxx-gcc-plan.rb --live): a gcc-backend compile and link, planned from this machine's facts,
#      is written as a plan file and run by the runner;
#   3. the freestanding plan (scripts/nfcxx-freestanding.rb --live): the --emit-c and --emit-hip lists, planned from this
#      machine's facts (the EDG front end and the rewriter, built and fresh);
#   4. the CUDA compile of one .cu input (scripts/nfcxx-cuda-live.rb): the -c compile of a .cu, planned stage by stage
#      (the device image, then the host copy through the Path B port); it exits 3 for what it does not plan, and the
#      arguments then go on to the next step, so the bash runs them.
#   4. the CUDA compile of a .cu input (scripts/nfcxx-cuda-live.rb): its device stages run in Ruby, then the host copy goes
#      to the Path B plan below; exit 3 from it hands the arguments to the bash.
#   5. the Path B plan (scripts/nfcxx-pathb.rb --live): the default backend or --backend=pathb, planned from this machine's
#      facts. The pathb-cc statuses are not facts here: a failed plan under the default backend is run again by the bash
#      with the same arguments, which builds the program with gcc as it always does; under --backend=pathb the status is the
#      driver's, as in the bash;
#   6. the bash driver, with the same arguments: anything the ports refuse (their "unported" status) or do not plan.
# A refusal the bash makes before it runs anything (the gcc port exits 2 with its message and prints no plan line; the Path B
# port does the same for its sanitizer refusals) is the driver's: the message goes to stderr and the status is 2, without the bash.
# The ports' plans are the bash's commands for the argument lists they model (tests/nfcxx-live, tests/nfcxx-gcc,
# tests/nfcxx-driver check that), so the behaviour is the bash's for every argument list.
#
#   ruby scripts/nfcxx.rb ARG...   the driver; NFCXX_DRIVER_TRACE=1 prints "nfcxx: driver: plan|gcc-plan|freestanding-plan|pathb-plan|bash" to stderr
require "open3"
require "rbconfig"
require "tmpdir"

ROOT = File.expand_path("..", __dir__)
LOOP = File.join(ROOT, "scripts", "nfcxx-loop.rb")
GCC_PLAN = File.join(ROOT, "scripts", "nfcxx-gcc-plan.rb")
PATHB_PLAN = File.join(ROOT, "scripts", "nfcxx-pathb.rb")
FREESTANDING_PLAN = File.join(ROOT, "scripts", "nfcxx-freestanding.rb")
CUDA_LIVE = File.join(ROOT, "scripts", "nfcxx-cuda-live.rb")
RUNNER = File.join(ROOT, "scripts", "nfcxx-run.rb")
PLAN_KINDS = %w[RUN EXEC CP CAT LN ENV TRACE TIMELOG START SPAN SPANF].freeze

# true when the port plans these arguments: its output is a plan (its first line is a plan command) and it ran to its end
def planned?(args)
  out, _err, status = Open3.capture3(RbConfig.ruby, LOOP, *args)
  return false unless status.success?

  plan_text?(out)
end

def plan_text?(out)
  first = out.lines.first
  !first.nil? && PLAN_KINDS.include?(first.split(/[ \t]/, 2).first)
end

# a refusal the bash makes before it runs anything: the port exits 2 with its message and prints no plan line. The message is
# the bash's, so the driver prints it and exits 2 (Refusal), without the bash
Refusal = Struct.new(:message)

def refusal_of(out, err, status)
  return nil unless status.exitstatus == 2 && out.strip.empty? && !err.strip.empty?

  Refusal.new(err)
end

# the gcc plan of these arguments as a plan file (text), a Refusal, or nil when the live port does not plan them (its status is
# not 0, or it prints no plan). The Path B port exits 0 on its own refusals (its --tabs plan has no status line), so its refusals
# reach the bash
def gcc_plan(args)
  out, err, status = Open3.capture3(RbConfig.ruby, GCC_PLAN, "--tabs", "--live=#{ROOT}", *args)
  refusal = refusal_of(out, err, status)
  return refusal if refusal
  return nil unless status.success? && plan_text?(out)

  out
end

# the freestanding plan of these arguments (--emit-c and --emit-hip, planned from this machine's facts) as a plan file, or nil
# when the port does not plan them (it is unported, or it refuses them: the bash reports the refusal)
def freestanding_plan(args)
  out, _err, status = Open3.capture3(RbConfig.ruby, FREESTANDING_PLAN, "--tabs", "--live=#{ROOT}", "--", *args)
  return nil unless status.success? && plan_text?(out)

  out
end

# the CUDA compile of these arguments (a .cu input): its status, or nil when the port does not plan them (exit 3 from it).
# It runs the compile itself, in stages, so this is not a probe. Its exit 3 means the bash runs the arguments: when that
# comes after its stages ran (a host compile the Path B port cannot build, under the default backend), the stages' output is
# dropped and the bash's own output is the one printed (the bash rewrites the same files).
def cuda_run(args)
  return nil unless args.any? { |a| a.end_with?(".cu") }

  pid = Process.spawn(RbConfig.ruby, CUDA_LIVE, "--", *args)
  Process.wait(pid)
  status = $?.exitstatus || 128 + $?.termsig
  status == 3 ? nil : status
end

# the Path B plan of these arguments: [plan text, the backend choice the port was given], a Refusal (the sanitizer options the
# bash refuses before it runs anything), or nil when the port does not plan them. The choice is default (no --backend) or
# pathb (--backend=pathb, which the port takes as its own argument).
def pathb_plan(args)
  return nil if ENV.key?("NFCXX_BACKEND")

  backends = args.select { |a| a.start_with?("--backend=") }
  choice, rest =
    if backends.empty? then ["default", args]
    elsif backends == ["--backend=pathb"] then ["pathb", args - backends]
    else return nil
    end
  out, err, status = Open3.capture3(RbConfig.ruby, PATHB_PLAN, "--tabs", "--live=#{ROOT}", "--backend=#{choice}", "--", *rest)
  refusal = refusal_of(out, err, status)
  return refusal if refusal
  return nil unless status.success? && plan_text?(out)

  [out, choice]
end

def trace(kind)
  $stderr.write("nfcxx: driver: #{kind}\n") if ENV["NFCXX_DRIVER_TRACE"] == "1"
end

# runs a plan file with the runner; returns its status. fallback: the bash runs the arguments again when the plan fails (see
# the runner's --fallback): the runner then writes no trace file or time log for a failed run
def run_plan_text(text, fallback: false)
  Dir.mktmpdir("nfcxx-plan") do |dir|
    file = File.join(dir, "plan.txt")
    File.write(file, text)
    opts = fallback ? ["--fallback"] : []
    pid = Process.spawn(RbConfig.ruby, RUNNER, "--root=#{ROOT}", "--plan=#{file}", *opts)
    Process.wait(pid)
    $?.exitstatus || 128 + $?.termsig
  end
end

if planned?(ARGV)
  trace("plan")
  exit(Process.wait(Process.spawn(RbConfig.ruby, RUNNER, "--root=#{ROOT}", "--", *ARGV)) && $?.exitstatus)
end

plan = gcc_plan(ARGV)
if plan.is_a?(Refusal)
  trace("gcc-plan")
  $stderr.write(plan.message)
  exit(2)
end
if plan
  trace("gcc-plan")
  exit(run_plan_text(plan))
end

fs = freestanding_plan(ARGV)
if fs
  trace("freestanding-plan")
  exit(run_plan_text(fs))
end

cu = cuda_run(ARGV)
if cu
  trace("cuda-plan")
  exit(cu)
end

pb = pathb_plan(ARGV)
if pb.is_a?(Refusal)
  trace("pathb-plan")
  $stderr.write(pb.message)
  exit(2)
end
if pb
  trace("pathb-plan")
  status = run_plan_text(pb[0], fallback: pb[1] == "default")
  # the default backend's failure is the bash's to report and to rebuild with gcc: it runs the arguments again
  if status != 0 && pb[1] == "default"
    trace("bash")
    exec("bash", File.join(ROOT, "nfcxx"), *ARGV)
  end
  exit(status)
end

trace("bash")
exec("bash", File.join(ROOT, "nfcxx"), *ARGV)
