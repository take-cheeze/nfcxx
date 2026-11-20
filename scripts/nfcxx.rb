#!/usr/bin/env ruby
# The Ruby driver (stage B2 of docs/notes/driver-body-port.md): the skeleton that will run the driver's top-level flow in Ruby.
# Until the stages are ported, it runs the bash driver (the oracle, tests/driver-body/nfcxx-bash) with the same arguments,
# environment, standard streams and status, so NFCXX_RUBY_DRIVER=1 changes nothing yet. Each stage moves a part of the flow
# here; the bash driver is the reference the differential tests compare against.
#
#   NFCXX_RUBY_DRIVER=1 ./nfcxx ARGS...      (./nfcxx runs this script when the flag is set)

require "tempfile"
require "tmpdir"
require "fileutils"
require "open3"
require "rbconfig"
require_relative "nfcxx-setup-args"
require_relative "nfcxx-second-pass"
require_relative "nfcxx-cache-config"

root = File.expand_path("..", __dir__)
ROOT = root
oracle = File.join(root, "tests", "driver-body", "nfcxx-bash")

# The route dispatch: the pre-loop plan (scripts/nfcxx-loop.rb) runs in scripts/nfcxx-run.rb, and a gcc-route refusal
# (scripts/nfcxx-gcc-plan.rb --live, status 2) is printed here, as the bash prints it. Every other argument list goes to the
# oracle below, which runs the gcc and Path B plans itself (its routes call nfcxx_plan_run and the --records planner).
LOOP = File.join(ROOT, "scripts", "nfcxx-loop.rb")
GCC_PLAN = File.join(ROOT, "scripts", "nfcxx-gcc-plan.rb")
PATHB_PLAN = File.join(ROOT, "scripts", "nfcxx-pathb.rb")
RUNNER = File.join(ROOT, "scripts", "nfcxx-run.rb")
PLAN_KINDS = %w[RUN EXEC CP CAT LN ENV].freeze
# the kinds of a Path B plan (scripts/nfcxx-pathb.rb --tabs --checks --live): its compiles and links, the CHECK after each
# pathb-cc, and the trace and time log lines
PATHB_KINDS = %w[RUN EXEC CP TRACE TIMELOG START SPAN SPANF CHECK].freeze

def plan_text?(out)
  first = out.lines.first
  !first.nil? && PLAN_KINDS.include?(first.split(/[ \t]/, 2).first)
end

def pathb_text?(out)
  first = out.lines.first
  !first.nil? && PATHB_KINDS.include?(first.split(/[ \t]/, 2).first)
end

# a refusal the bash makes before it runs anything (the Path B port's sanitizer refusals): the message, printed by the driver
Refusal = Struct.new(:message)

def planned_loop?(args)
  out, _err, status = Open3.capture3(RbConfig.ruby, LOOP, *args)
  status.success? && plan_text?(out)
end

# the refusals before the oracle, [input, setup] (scripts/nfcxx-setup-args.rb refusals), computed when one is needed: the
# input's (CUDA, .cpp2 and module) come after the gcc planner in the bash, the setup's after them
def driver_refusals
  @driver_refusals ||= NfcxxSetupArgs.refusals(ARGV, ENV)
end

def gcc_plan(args)
  out, err, status = Open3.capture3(RbConfig.ruby, GCC_PLAN, "--tabs", "--live=#{ROOT}", *args)
  # a refusal (status 2): the port's message is the bash's, so the driver prints it and stops here, as the bash would
  # the setup's refusals come first, as the bash checks them before the backend's name (the setup check below prints them)
  if status.exitstatus == 2 && !plan_text?(out) && driver_refusals[1].nil?
    trace_route("gcc-plan")
    $stderr.write(err)
    exit(2)
  end
  nil
end

# The Path B plan of these arguments (scripts/nfcxx-pathb.rb --live --checks): the default backend, or --backend=pathb (the
# bash's two choices for a hosted compile or link; a gcc choice is the gcc plan's). Returns the plan text, a Refusal (the
# port's refusal, which the bash makes before it runs anything), or nil when the port does not plan these arguments. The
# compile cache (--cache, --cache-log) is the bash's own lookup and store, which the port does not plan: those go to the bash.
def pathb_plan(args)
  return nil if ENV.key?("NFCXX_BACKEND") || args.any? { |a| a.start_with?("--cache") }

  backends = args.select { |a| a.start_with?("--backend=") }
  choice, rest =
    if backends.empty? then ["default", args]
    elsif backends == ["--backend=pathb"] then ["pathb", args - backends]
    else return nil
    end
  out, err, status = Open3.capture3(RbConfig.ruby, PATHB_PLAN, "--tabs", "--checks", "--live=#{ROOT}", "--backend=#{choice}", "--", *rest)
  return Refusal.new(err) if status.exitstatus == 2 && out.strip.empty? && !err.strip.empty?
  return nil unless status.success? && pathb_text?(out)

  out
end

def trace_route(kind)
  $stderr.write("nfcxx: driver: #{kind}\n") if ENV["NFCXX_DRIVER_TRACE"] == "1"
end

# runs a plan text with the runner (scripts/nfcxx-run.rb --plan); returns its status
def run_plan_text(text)
  Dir.mktmpdir("nfcxx-plan") do |dir|
    file = File.join(dir, "plan.txt")
    File.write(file, text)
    pid = Process.spawn(RbConfig.ruby, RUNNER, "--root=#{ROOT}", "--plan=#{file}")
    Process.wait(pid)
    $?.exitstatus || 128 + $?.termsig
  end
end

# B5: the cache configuration's refusal (NFCXX_CACHE_REMOTE, scripts/nfcxx-cache-config.rb plan). The bash checks it first (its
# line 115, before the argument loop, the routes and the setup, and before its trace begins), so it is checked before anything
# else here. The bash's -fsyntax-only pre-loop plan runs before it, so that command is the oracle's.
unless ARGV.include?("-fsyntax-only")
  _cache_config, cache_refusal = NfcxxCacheConfig.plan(ENV, Process.euid)
  if cache_refusal
    $stderr.puts(cache_refusal)
    exit(2)
  end
end

if planned_loop?(ARGV)
  trace_route("plan")
  pid = Process.spawn(RbConfig.ruby, RUNNER, "--root=#{ROOT}", "--", *ARGV)
  Process.wait(pid)
  exit($?.exitstatus || 128 + $?.termsig)
end

# the gcc plan's kinds (CD, NOTE, CHECK, STORE, the placeholders) are the bash's nfcxx_plan_run's: a gcc plan is left to the oracle
# below (only its refusal is printed here). The Path B plan is run below, with the runner, which takes its kinds.
gcc_plan(ARGV) # a refusal exits here; a plan is left to the oracle

# the Path B plan (the default backend, or --backend=pathb), run by the runner: the CHECK lines of the plan are the bash's rule for
# a pathb-cc status (the gcc form re-executes the driver with NFCXX_BACKEND=gcc, as the bash does), so a failed compile is not
# run a second time here. The setup's and the input's refusals come first, as the bash prints them (the oracle prints them).
unless driver_refusals.any?
  pb = pathb_plan(ARGV)
  if pb.is_a?(Refusal)
    trace_route("pathb-plan")
    $stderr.write(pb.message)
    exit(2)
  end
  if pb
    trace_route("pathb-plan")
    exit(run_plan_text(pb))
  end
end
trace_route("bash")

# the oracle computes its root from its own location; here it is this repository's root (the same substitution the
# differential tests make), so its paths are the repository's
text = File.read(oracle).sub(/^root=\$\(cd "\$\(dirname "\$0"\)" && pwd\)$/) { "root=#{root}" }
# the oracle re-runs the driver as "$0" (the -fsyntax-only route): run from a temporary program, $0 is that file, so the
# driver's own path is put there (the program is an executable file of its own, not a driver)
text = text.gsub('"$0"', "\"#{File.join(root, "nfcxx")}\"")
abort "nfcxx: the oracle's root line is not as expected" unless text.include?("root=#{root}")
# B7 (scripts/nfcxx-second-pass.rb): the oracle's second run is the Ruby driver itself, with the same environment and arguments
# (run), inside the oracle's own trace span around it. Its line is the one the oracle has (the oracle is frozen).
text = NfcxxSecondPass.oracle_text(text) or abort "nfcxx: the oracle's second-pass run is not as expected"
program = Tempfile.new(["nfcxx-oracle", ".sh"])
program.write(text)
program.close

# B6 (docs/notes/driver-body-restructure.md): the temporary directories of the driver are made under a root that this process
# owns. TMPDIR points at it, so every mktemp -d the bash makes lands there; the bash removes its own directories in its EXIT
# traps, and this removes whatever is left (a failing or interrupted driver) when the run ends, normally or not.
status = nil
# --keep-intermediates (NFCXX_KEEP_INTERMEDIATES=1): the bash keeps its eccp directory, which is made under this root; the root is then
# kept too, so the directory the user asked for survives the run (the bash's eccp_cleanup removes it only when the flag is off)
keep = ENV["NFCXX_KEEP_INTERMEDIATES"] == "1"
tmproot = Dir.mktmpdir("nfcxx-tmp.")
status_code = 1
begin
  # the stages not yet ported run in bash: the same arguments and environment, the standard streams inherited. Its status is ours.
  # NFCXX_TMP_OWNED: the temporary directories are this process's, removed when it ends (unless intermediates are kept), so the
  # driver's eccp trap keeps only its trace finish (nfcxx: eccp_cleanup is for the plain driver)
  # the trace (--trace=FILE, the last one, or NFCXX_TRACE): this process opens it and closes it, as the bash's trace_begin and
  # trace_finish did; the bash only flushes its spans (its trace_finish keeps its span flush, and does not close the trace)
  trace_file = ARGV.reverse.find { |a| a.start_with?("--trace=") }&.delete_prefix("--trace=") || ENV["NFCXX_TRACE"].to_s
  env = { "RUBY" => ENV["RUBY"] || RbConfig.ruby, "TMPDIR" => tmproot, "NFCXX_TMP_OWNED" => "1" }
  trace_rb = File.join(__dir__, "trace.rb")
  unless trace_file.empty?
    trace_abs = File.join(File.realpath(File.dirname(trace_file)), File.basename(trace_file))
    env["NFCXX_TRACE"] = trace_abs
    env["NFCXX_TRACE_OWNER"] = Process.pid.to_s
    env["NFCXX_TRACE_PENDING"] = File.join(tmproot, "nfcxx-trace-pending.#{Process.pid}")
    File.write(env["NFCXX_TRACE_PENDING"], "")
    system(env["RUBY"], trace_rb, "open", trace_abs)
  end
  # B3 and B4: the refusals before the oracle (scripts/nfcxx-setup-args.rb refusals): the CUDA, .cpp2 and module refusals, which the
  # bash prints before its setup, then the setup's. The bash prints the message and exits with the status, after the trace is
  # opened. Any other command goes on to the oracle unchanged.
  input, setup = driver_refusals
  refusal = input || setup
  # the oracle's status is read here, before the trace calls below: each system call sets $?, so reading it after them
  # gave the trace's status (0) for a failing build
  oracle_code = 0
  if refusal
    $stderr.puts(refusal.message)
  else
    ok = system(env, "bash", program.path, *ARGV)
    oracle_code = ok ? 0 : ($?.exitstatus || 1)
  end
  unless trace_file.empty?
    system(env, env["RUBY"], trace_rb, "flush", env["NFCXX_TRACE_PENDING"]) if File.size?(env["NFCXX_TRACE_PENDING"])
    system(env["RUBY"], trace_rb, "close", trace_abs, Process.pid.to_s)
  end
  status_code = refusal ? refusal.status : oracle_code
ensure
  program.unlink
  FileUtils.rm_rf(tmproot) unless keep
end
exit status_code
