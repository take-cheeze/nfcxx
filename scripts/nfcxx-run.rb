#!/usr/bin/env ruby
# nfcxx-run: runs a plan for real, the way nfcxx's bash runs its commands. A plan is what the Ruby port prints for an argument
# list (scripts/nfcxx-loop.rb: RUN and EXEC, from its -fsyntax-only and --bundle-* steps), or a plan file. The runner runs each
# command with Process.spawn (no shell), waits for it, and stops at the first nonzero status (like set -e), exiting with that
# status. EXEC is the bash's exec: its command runs as the last step, and the plan ends with its status.
#
#   ruby scripts/nfcxx-run.rb [OPTIONS] -- ARG...             plans ARG... with the port, then runs the plan
#   ruby scripts/nfcxx-run.rb --emit-plan [OPTIONS] -- ARG... prints the plan (tab-separated), runs nothing
#   ruby scripts/nfcxx-run.rb [OPTIONS] --plan=FILE           runs a plan file (--plan=- reads standard input)
#
# OPTIONS:
#   --env NAME=VALUE (or --env=NAME=VALUE)  an environment variable of the commands (repeatable); the port gets the same
#                                           variables as --nfcxx-env=NAME=VALUE, so it plans with them
#   --root=DIR     the repository: ROOT in the plan, and the driver nfcxx (default: the directory above scripts/)
#   --tmp=DIR      the directory for TMP in the plan (default: a temporary directory, removed afterwards)
#   --chdir=DIR    the working directory of the commands (default: the current one)
#
# Plan format: one command per line, its fields separated by single tabs (so an argument may hold spaces; an empty argument is
# an empty field). The first field is the kind: RUN ARGV..., EXEC ARGV..., CP SRC DST (CP -R SRC DST for a directory), CAT FILE
# (to standard output), and LN -s TARGET LINK; ENV NAME=VALUE exports a variable for the programs that follow (as the bash's
# export does). The prefixes of the next RUN or EXEC, as the bash writes them: ENV1 NAME=VALUE (NAME=VALUE cmd), OUT FILE
# (cmd > FILE) and APP FILE (cmd >> FILE). JOBS N does nothing (the bash's ptxas parallelism). RUN ensure_tool DIR OUT is the
# bash's ensure_tool: it builds DIR with ninja when OUT is missing or older than a source of DIR, under the lock OUT.lock.
# Blank lines and lines that start with # are skipped. A plan is read and checked in full before it runs.
# When a plan runs, each field that is ROOT or starts with ROOT/ has ROOT replaced by --root, and TMP likewise by --tmp (also after
# -I or --NAME=, as in -IROOT/lib and --gen_c_file_name=TMP/out.c); and a
# RUN or EXEC whose program is nfcxx runs ROOT/nfcxx. The port's arguments must not hold a tab or a newline.
# The driver's trace (--trace=FILE, --time-log=FILE: scripts/trace.rb's Recorder, with the bash's spans and texts). TRACE FILE
# UNIT starts the trace file (the bash's trace_begin: its span is the run's, and its closing lines the run's end); TIMELOG FILE
# sets the time log; START VAR takes a clock reading into VAR (0 when no trace is on); SPAN VAR NAME CAT UNIT records the span
# from VAR to now; SPANF is SPAN, and is recorded also when the command just before it failed (the bash's trace_end after a
# pathb-cc status it passes on). The files are written when the run ends. The run's end is the plan's end, with any status.
# --fallback: for a caller that runs the arguments again with the bash when the plan fails, so a failed run writes no files (the
# bash writes them, from the start). The Path B dispatch does not use it: its default-backend failure is a CHECK line (above).
# Exit status: the status of the command that failed (127 or 126 when it cannot be started), 0 when the plan ran to its end,
# 2 for a usage or plan error, and the port's status when the port refuses the arguments (3 for an unported option).

require "open3"
require "fileutils"
require "tmpdir"
require "rbconfig"
require_relative "trace"

PORT = File.expand_path("nfcxx-loop.rb", __dir__)
ROOT_DEFAULT = File.expand_path("..", __dir__)
KINDS = %w[ENV RUN EXEC CP CAT LN TRACE TIMELOG START SPAN SPANF ENV1 OUT APP JOBS CHECK STORE].freeze
TRACE_KINDS = %w[TRACE TIMELOG START SPAN SPANF].freeze
# ENV1, OUT and APP are the prefixes of the next RUN or EXEC (the bash's NAME=VALUE cmd, cmd > FILE and cmd >> FILE): they
# apply to that command only. JOBS N is the bash's ptxas parallelism, which the runner does not need: it does nothing.
# The Path B plan (scripts/nfcxx-pathb.rb --tabs --checks): a RUN that fails does not stop the plan at once; the CHECK after it
# (or a span, then the CHECK) is the bash's rule for its status. CHECK exit ends the plan with the status; CHECK gcc BEFORE AFTER
# ARGV... prints BEFORE, the status and AFTER on standard error and replaces the process with ARGV... (the bash's exec of the
# driver with NFCXX_BACKEND=gcc), with a zero status it goes on. STORE OBJ ENTRY REMOTE is the bash's cache_store: the store
# of scripts/nfcxx-cache-check.rb (REMOTE "" for none), nothing when ENTRY is empty, and a failed store does not stop the plan.

# The print step of the port's main, and the copy of it this runner plans with: the same plan, one tab-separated line per
# command (kind, then the argv), instead of the words joined by spaces. The copy is made in memory; the port file is not changed.
PORT_PRINT = 'plan.each { |kind, cmd| $stdout.write("#{kind} #{cmd.join(" ")}\n") }'
PORT_PRINT_TABBED = 'plan.each { |kind, cmd| abort("nfcxx-run: a tab or a newline in an argument") if cmd.any? { |x| x.match?(/[\t\n]/) }; $stdout.write([kind, *cmd].join("\t") + "\n") }'

class PlanError < StandardError
end

# The plan the port prints for the arguments, as [kind, fields] pairs, or [nil, status] when the port refuses them.
def plan_for(port_args, env)
  source = File.read(PORT)
  raise PlanError, "the port's print step is not as expected" unless source.scan(PORT_PRINT).size == 1

  tabbed = source.sub(PORT_PRINT) { PORT_PRINT_TABBED }
  env_opts = env.map { |name, value| "--nfcxx-env=#{name}=#{value}" }
  out, status = Open3.capture2(RbConfig.ruby, "-", *env_opts, *port_args, stdin_data: tabbed)
  return [nil, status.exitstatus || 1] unless status.success?

  begin
    plan = parse_plan(out)
  rescue PlanError => e
    raise PlanError, "the port printed no plan for these arguments (#{e.message})"
  end
  raise PlanError, "the port printed no plan for these arguments" if plan.empty?

  [plan, nil]
end

def parse_plan(text)
  plan = []
  pending = nil   # the line number of an ENV1, OUT or APP that the next RUN or EXEC takes
  text.each_line.with_index(1) do |line, number|
    line = line.chomp
    next if line.empty? || line.start_with?("#")

    fields = line.split("\t", -1)
    kind = fields.shift
    raise PlanError, "line #{number}: unknown command #{kind.inspect}" unless KINDS.include?(kind)
    raise PlanError, "line #{number}: #{kind} must come before a RUN or EXEC" if pending && !%w[RUN EXEC ENV1 OUT APP].include?(kind)

    case kind
    when "ENV"
      raise PlanError, "line #{number}: ENV needs NAME=VALUE" unless fields.size == 1 && fields[0].include?("=")
    when "ENV1"
      raise PlanError, "line #{number}: ENV1 needs NAME=VALUE" unless fields.size == 1 && fields[0].include?("=")
    when "OUT", "APP"
      raise PlanError, "line #{number}: #{kind} needs one file" unless fields.size == 1
    when "JOBS"
      raise PlanError, "line #{number}: JOBS needs a count" unless fields.size == 1 && fields[0].match?(/\A[0-9]+\z/)
    when "RUN", "EXEC"
      raise PlanError, "line #{number}: #{kind} needs a program" if fields.empty?
    when "CP"
      raise PlanError, "line #{number}: CP needs SRC DST" unless fields.size == 2 || (fields.size == 3 && fields[0] == "-R")
    when "CAT"
      raise PlanError, "line #{number}: CAT needs one file" unless fields.size == 1
    when "LN"
      raise PlanError, "line #{number}: LN needs -s TARGET LINK" unless fields.size == 3 && fields[0] == "-s"
    when "TRACE"
      raise PlanError, "line #{number}: TRACE needs FILE UNIT" unless fields.size == 2 && !fields[0].empty?
    when "TIMELOG"
      raise PlanError, "line #{number}: TIMELOG needs FILE" unless fields.size == 1 && !fields[0].empty?
    when "START"
      raise PlanError, "line #{number}: START needs VAR" unless fields.size == 1 && fields[0].match?(/\A\w+\z/)
    when "SPAN", "SPANF"
      raise PlanError, "line #{number}: #{kind} needs VAR NAME CAT UNIT" unless fields.size == 4 && fields[0].match?(/\A\w+\z/)
    when "CHECK"
      raise PlanError, "line #{number}: CHECK needs exit, or gcc BEFORE AFTER ARGV..." unless
        (fields == ["exit"]) || (fields.size >= 4 && fields[0] == "gcc")
    when "STORE"
      raise PlanError, "line #{number}: STORE needs OBJ ENTRY REMOTE" unless fields.size == 3
    end
    pending = %w[ENV1 OUT APP].include?(kind) ? number : nil
    pending = nil if %w[RUN EXEC].include?(kind)
    plan << [kind, fields]
  end
  raise PlanError, "line #{pending}: a redirect or ENV1 with no command after it" if pending

  plan
end

def expand(field, root, tmp)
  # the placeholder may follow an -I or a --NAME= option (-I ROOT/lib, --gen_c_file_name=TMP/out.c), as the bash expands it
  head = field[/\A(-I|--[A-Za-z][\w-]*=)?/].to_s
  rest = field[head.size..]
  { "ROOT" => root, "TMP" => tmp }.each do |name, dir|
    return head + dir if rest == name
    return head + dir + rest[name.size..] if rest.start_with?("#{name}/")
  end
  field
end

# Runs one program without a shell. Returns its status (128 + the signal when it was killed). out: [FILE, MODE] sends its
# standard output to FILE (MODE "w": the bash's >, "a": >>).
def run_command(env, argv, out: nil)
  $stdout.flush
  $stderr.flush
  opts = out ? { out: out } : {}
  pid = Process.spawn(env, [argv[0], argv[0]], *argv[1..], **opts)
  Process.wait(pid)
  $?.exitstatus || 128 + $?.termsig
rescue SystemCallError => e
  $stderr.puts "nfcxx-run: #{argv[0]}: #{e.message}"
  e.is_a?(Errno::ENOENT) ? 127 : 126
end

# RUN ensure_tool DIR OUT: the bash's ensure_tool. OUT is fresh when it is executable and no source file of DIR (the top
# level only: .c, .cpp, .h, .hpp, .inc, .rb) is newer; otherwise DIR is built with ninja (CXX from NFCXX_CXX, default g++).
# The bash's lock is not needed: a plan runs its commands one at a time.
def tool_fresh?(dir, out)
  return false unless File.file?(out) && File.executable?(out)

  Dir.children(dir).none? do |name|
    f = File.join(dir, name)
    name.match?(/\.(c|cpp|h|hpp|inc|rb)\z/) && File.file?(f) && File.mtime(f) > File.mtime(out)
  end
end

# The lock is a directory OUT.lock (the bash's mkdir lock): a parallel run waits for the build and finds OUT fresh.
def ensure_tool(dir, out, env)
  return 0 if tool_fresh?(dir, out)

  FileUtils.mkdir_p(File.dirname(out))
  lock = "#{out}.lock"
  waited = 0
  until (begin Dir.mkdir(lock); true; rescue Errno::EEXIST; false; end)
    return 0 if tool_fresh?(dir, out)
    sleep 0.2
    waited += 1
    next if waited < 3000

    $stderr.puts "nfcxx: #{lock} is stuck (remove it if no build is running)"
    return 1
  end
  begin
    return 0 if tool_fresh?(dir, out)

    cxx = env["NFCXX_CXX"] || ENV["NFCXX_CXX"] || "g++"
    $stdout.flush
    $stderr.flush
    pid = Process.spawn(env.merge("CXX" => cxx), "ninja", "-C", dir, out: $stderr)
    Process.wait(pid)
    $?.exitstatus || 128 + $?.termsig
  ensure
    Dir.rmdir(lock) rescue nil
  end
rescue SystemCallError => e
  $stderr.puts "nfcxx-run: ensure_tool: #{e.message}"
  127
end

def file_step(kind)
  yield
  0
rescue SystemCallError, IOError => e
  $stderr.puts "nfcxx-run: #{kind}: #{e.message}"
  1
end

# the directory the runner started in: the trace file and the time log are named relative to it (a --chdir does not move them)
START_DIR = Dir.pwd

# one trace step of a plan (TRACE_KINDS), recorded in rec; vars holds the clock readings of START
def trace_step(kind, fields, rec, vars)
  case kind
  when "TRACE"
    rec.trace = HostSys.abs_path(File.expand_path(fields[0], START_DIR))
    rec.unit = fields[1]
    rec.begin_trace
  when "TIMELOG"
    rec.time_log = HostSys.abs_path(File.expand_path(fields[0], START_DIR))
  when "START"
    vars[fields[0]] = rec.start
  when "SPAN", "SPANF"
    start = vars.fetch(fields[0]) { raise PlanError, "#{kind} uses #{fields[0]}, which no START set" }
    rec.span(start, fields[1], fields[2], unit: fields[3])
  end
end

# CHECK exit | CHECK gcc BEFORE AFTER ARGV...: the rule for the status prc of the RUN before it (the bash's CHECK, after its
# pathb-cc). A zero status goes on (nil). exit ends the plan with the status. gcc prints BEFORE, the status and AFTER on
# standard error, then replaces this process with ARGV... (the bash's exec of the driver with NFCXX_BACKEND=gcc). The bash's
# exec keeps the process ID, so the driver it runs is the trace's owner (NFCXX_TRACE_OWNER is this process's ID); the trace and
# the time log written so far are kept first (state[:before_exec]), as the bash has written them.
def check_step(args, prc, env, state)
  return nil if prc.zero?
  return prc if args == ["exit"]

  $stderr.write("#{args[1]}#{prc}#{args[2]}\n")
  state[:before_exec].call
  env = env.merge("NFCXX_TRACE_OWNER" => Process.pid.to_s) if state[:traced]
  $stdout.flush
  $stderr.flush
  Kernel.exec(env, *args[3..])
end

# STORE OBJ ENTRY REMOTE: the bash's cache_store (scripts/nfcxx-cache-check.rb store, with the entry its cache_check set and the
# remote tier of NFCXX_CACHE_REMOTE, "" for none). Nothing when ENTRY is empty; a failed store does not stop the plan (|| true).
def store_step(args, root, env)
  obj, entry, remote = args
  return 0 if entry.nil? || entry.empty?

  argv = [RbConfig.ruby, File.join(root, "scripts", "nfcxx-cache-check.rb"), "store", "--out=#{obj}", "--entry=#{entry}"]
  argv << "--remote=#{remote}" unless remote.nil? || remote.empty?
  run_command(env, argv)
  0
end

# Runs the plan; returns its status. A RUN that fails does not stop the plan at once: the bash's CHECK after it (or a span,
# which is recorded first) decides, and a plan with no CHECK stops there, as set -e does. A CHECK's exec (see check_step)
# ends the process: state[:before_exec] runs first, and state[:traced] tells whether the run traces.
def run_plan(plan, env, root, tmp, rec, state)
  exported = {}  # ENV lines: exported as the bash exports them, for the programs that follow
  vars = {}      # START variables: clock readings for SPAN
  prefix = { env: {}, out: nil }   # ENV1, OUT and APP: for the next RUN or EXEC only
  failed = 0     # the status of the last RUN when it failed (the bash's prc)
  plan.each_with_index do |(kind, fields), index|
    # a failed command stops the plan (set -e), unless a CHECK comes next; a span before the CHECK is still recorded
    return failed if failed != 0 && kind != "CHECK" && !TRACE_KINDS.include?(kind)
    state[:traced] = true if kind == "TRACE"
    if TRACE_KINDS.include?(kind)
      trace_step(kind, fields, rec, vars)
      next
    end
    args = fields.map { |field| expand(field, root, tmp) }
    if kind == "CHECK"
      prc = failed
      failed = 0
      status = check_step(args, prc, env.merge(exported), state)
      return status unless status.nil?
      next
    end
    status = case kind
             when "ENV"
               name, value = fields[0].split("=", 2)
               exported[name] = value
               0
             when "ENV1"
               name, value = fields[0].split("=", 2)
               prefix[:env][name] = value
               0
             when "OUT"
               prefix[:out] = [expand(fields[0], root, tmp), "w"]
               0
             when "APP"
               prefix[:out] = [expand(fields[0], root, tmp), "a"]
               0
             when "JOBS"
               0
             when "RUN", "EXEC"
               args[0] = File.join(root, "nfcxx") if args[0] == "nfcxx"
               st = if kind == "RUN" && args[0] == "ensure_tool"
                      ensure_tool(args[1], args[2], env.merge(exported).merge(prefix[:env]))
                    else
                      run_command(env.merge(exported).merge(prefix[:env]), args, out: prefix[:out])
                    end
               prefix = { env: {}, out: nil }
               st
             when "CP"
               if args[0] == "-R"
                 file_step(kind) { FileUtils.cp_r(args[1], args[2]) }
               else
                 file_step(kind) { FileUtils.cp(args[0], args[1]) }
               end
             when "CAT"
               file_step(kind) { File.open(args[0], "rb") { |io| IO.copy_stream(io, $stdout) } }
             when "LN"
               file_step(kind) { File.symlink(args[1], args[2]) }
             when "STORE"
               store_step(args, root, env.merge(exported))
             end
    # a RUN's status is the CHECK's to decide (see the top of the loop)
    if kind == "RUN"
      failed = status
      next
    end
    return status unless status.zero?
    # EXEC ends the plan with its status, as the bash's exec does
    return 0 if kind == "EXEC"
  end
  failed
end

def main(argv)
  opts = { mode: :run, env: {}, root: ROOT_DEFAULT, tmp: nil, chdir: nil, plan: nil, fallback: false }
  port_args = nil
  args = argv.dup
  until args.empty?
    a = args.shift
    case a
    when "--"
      port_args = args
      args = []
    when "--emit-plan" then opts[:mode] = :emit
    when "--fallback" then opts[:fallback] = true
    when /\A--plan=(.*)\z/m then opts[:plan] = $1
    when /\A--root=(.*)\z/m then opts[:root] = File.expand_path($1)
    when /\A--tmp=(.*)\z/m then opts[:tmp] = File.expand_path($1)
    when /\A--chdir=(.*)\z/m then opts[:chdir] = File.expand_path($1)
    when "--env", /\A--env=/
      pair = a == "--env" ? args.shift : a.delete_prefix("--env=")
      eq = pair && pair.index("=")
      raise PlanError, "--env needs NAME=VALUE" if eq.nil? || eq.zero?

      opts[:env][pair[0...eq]] = pair[(eq + 1)..]
    else
      raise PlanError, "unknown option #{a} (see the header of scripts/nfcxx-run.rb)"
    end
  end
  if opts[:plan]
    raise PlanError, "--plan takes no port arguments" if port_args
    raise PlanError, "--emit-plan needs port arguments" if opts[:mode] == :emit

    text = opts[:plan] == "-" ? $stdin.read : File.read(opts[:plan])
    plan = parse_plan(text)
  else
    raise PlanError, "give the port's arguments after --" if port_args.nil?

    plan, status = plan_for(port_args, opts[:env])
    return status if plan.nil?
  end
  if opts[:mode] == :emit
    plan.each { |kind, fields| $stdout.write([kind, *fields].join("\t") + "\n") }
    return 0
  end

  run = lambda do |tmp, owned|
    rec = NfccxxTrace::Recorder.new
    # before a CHECK's exec: the files so far, and the temporary directory (the exec leaves no ensure to remove it)
    state = { traced: false, before_exec: lambda { rec.commit; FileUtils.rm_rf(tmp) if owned } }
    status = if opts[:chdir]
               Dir.chdir(opts[:chdir]) { run_plan(plan, opts[:env], opts[:root], tmp, rec, state) }
             else
               run_plan(plan, opts[:env], opts[:root], tmp, rec, state)
             end
    # the run's end: the driver's span and the closing lines, then the files. With --fallback a failed run writes nothing
    rec.finish_trace
    rec.commit if status.zero? || !opts[:fallback]
    status
  end
  return run.call(File.expand_path(opts[:tmp]), false) if opts[:tmp]

  Dir.mktmpdir("nfcxx-run") { |dir| run.call(dir, true) }
end

begin
  status = main(ARGV)
rescue PlanError => e
  $stderr.puts "nfcxx-run: #{e.message}"
  status = 2
rescue SystemCallError, IOError => e
  $stderr.puts "nfcxx-run: #{e.message}"
  status = 1
end
$stdout.flush
exit(status)
