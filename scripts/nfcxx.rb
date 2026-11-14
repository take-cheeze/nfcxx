#!/usr/bin/env ruby
# nfcxx, the CRuby driver: the entry point that replaces the bash driver (nfcxx) one step at a time. Three ways run the
# arguments, in this order:
#   1. the pre-loop plan (scripts/nfcxx-loop.rb): the re-runs it models (-fsyntax-only, --bundle-*, the CUDA driver step)
#      print RUN and EXEC lines, and the runner (scripts/nfcxx-run.rb) runs them;
#   2. the gcc plan (scripts/nfcxx-gcc-plan.rb --live): a gcc-backend compile and link, planned from this machine's facts,
#      is written as a plan file and run by the runner;
#   3. the bash driver, with the same arguments: anything the ports refuse (their "unported" status) or do not plan.
# The ports' plans are the bash's commands for the argument lists they model (tests/nfcxx-live, tests/nfcxx-gcc,
# tests/nfcxx-driver check that), so the behaviour is the bash's for every argument list.
#
#   ruby scripts/nfcxx.rb ARG...   the driver; NFCXX_DRIVER_TRACE=1 prints "nfcxx: driver: plan|gcc-plan|bash" to stderr
require "open3"
require "rbconfig"
require "tmpdir"

ROOT = File.expand_path("..", __dir__)
LOOP = File.join(ROOT, "scripts", "nfcxx-loop.rb")
GCC_PLAN = File.join(ROOT, "scripts", "nfcxx-gcc-plan.rb")
RUNNER = File.join(ROOT, "scripts", "nfcxx-run.rb")
PLAN_KINDS = %w[RUN EXEC CP CAT LN ENV].freeze

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

# the gcc plan of these arguments as a plan file (text), or nil when the live port does not plan them (its status is not 0,
# or it prints no plan)
def gcc_plan(args)
  out, _err, status = Open3.capture3(RbConfig.ruby, GCC_PLAN, "--tabs", "--live=#{ROOT}", *args)
  return nil unless status.success? && plan_text?(out)

  out
end

def trace(kind)
  $stderr.write("nfcxx: driver: #{kind}\n") if ENV["NFCXX_DRIVER_TRACE"] == "1"
end

# runs a plan file with the runner; returns its status
def run_plan_text(text)
  Dir.mktmpdir("nfcxx-plan") do |dir|
    file = File.join(dir, "plan.txt")
    File.write(file, text)
    pid = Process.spawn(RbConfig.ruby, RUNNER, "--root=#{ROOT}", "--plan=#{file}")
    Process.wait(pid)
    $?.exitstatus || 128 + $?.termsig
  end
end

if planned?(ARGV)
  trace("plan")
  exit(Process.wait(Process.spawn(RbConfig.ruby, RUNNER, "--root=#{ROOT}", "--", *ARGV)) && $?.exitstatus)
end

plan = gcc_plan(ARGV)
if plan
  trace("gcc-plan")
  exit(run_plan_text(plan))
end

trace("bash")
exec("bash", File.join(ROOT, "nfcxx"), *ARGV)
