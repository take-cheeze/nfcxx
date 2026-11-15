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
# an empty field). The first field is the kind: RUN ARGV..., EXEC ARGV..., CP SRC DST, CAT FILE (to standard output), and
# LN -s TARGET LINK; ENV NAME=VALUE exports a variable for the programs that follow (as the bash's export does). Blank lines and lines that start with # are skipped. A plan is read and checked in full before it runs.
# When a plan runs, each field that is ROOT or starts with ROOT/ has ROOT replaced by --root, and TMP likewise by --tmp (also after
# -I or --NAME=, as in -IROOT/lib and --gen_c_file_name=TMP/out.c); and a
# RUN or EXEC whose program is nfcxx runs ROOT/nfcxx. The port's arguments must not hold a tab or a newline.
# The driver's trace (--trace=FILE, --time-log=FILE: scripts/trace.rb's Recorder, with the bash's spans and texts). TRACE FILE
# UNIT starts the trace file (the bash's trace_begin: its span is the run's, and its closing lines the run's end); TIMELOG FILE
# sets the time log; START VAR takes a clock reading into VAR (0 when no trace is on); SPAN VAR NAME CAT UNIT records the span
# from VAR to now; SPANF is SPAN, and is recorded also when the command just before it failed (the bash's trace_end after a
# pathb-cc status it passes on). The files are written when the run ends. The run's end is the plan's end, with any status.
# --fallback: the bash runs the arguments again when the plan fails (the default backend's Path B build), so a failed run
# writes no files: the bash writes them, from the start.
# Exit status: the status of the command that failed (127 or 126 when it cannot be started), 0 when the plan ran to its end,
# 2 for a usage or plan error, and the port's status when the port refuses the arguments (3 for an unported option).

require "open3"
require "fileutils"
require "tmpdir"
require "rbconfig"
require_relative "trace"

PORT = File.expand_path("nfcxx-loop.rb", __dir__)
ROOT_DEFAULT = File.expand_path("..", __dir__)
KINDS = %w[ENV RUN EXEC CP CAT LN TRACE TIMELOG START SPAN SPANF].freeze
TRACE_KINDS = %w[TRACE TIMELOG START SPAN SPANF].freeze

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
  text.each_line.with_index(1) do |line, number|
    line = line.chomp
    next if line.empty? || line.start_with?("#")

    fields = line.split("\t", -1)
    kind = fields.shift
    raise PlanError, "line #{number}: unknown command #{kind.inspect}" unless KINDS.include?(kind)

    case kind
    when "ENV"
      raise PlanError, "line #{number}: ENV needs NAME=VALUE" unless fields.size == 1 && fields[0].include?("=")
    when "RUN", "EXEC"
      raise PlanError, "line #{number}: #{kind} needs a program" if fields.empty?
    when "CP"
      raise PlanError, "line #{number}: CP needs SRC DST" unless fields.size == 2
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
    end
    plan << [kind, fields]
  end
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

# Runs one program without a shell. Returns its status (128 + the signal when it was killed).
def run_command(env, argv)
  $stdout.flush
  $stderr.flush
  pid = Process.spawn(env, [argv[0], argv[0]], *argv[1..])
  Process.wait(pid)
  $?.exitstatus || 128 + $?.termsig
rescue SystemCallError => e
  $stderr.puts "nfcxx-run: #{argv[0]}: #{e.message}"
  e.is_a?(Errno::ENOENT) ? 127 : 126
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

def run_plan(plan, env, root, tmp, rec)
  exported = {}  # ENV lines: exported as the bash exports them, for the programs that follow
  vars = {}      # START variables: clock readings for SPAN
  plan.each_with_index do |(kind, fields), index|
    if TRACE_KINDS.include?(kind)
      trace_step(kind, fields, rec, vars)
      next
    end
    args = fields.map { |field| expand(field, root, tmp) }
    status = case kind
             when "ENV"
               name, value = fields[0].split("=", 2)
               exported[name] = value
               0
             when "RUN", "EXEC"
               args[0] = File.join(root, "nfcxx") if args[0] == "nfcxx"
               run_command(env.merge(exported), args)
             when "CP"
               file_step(kind) { FileUtils.cp(args[0], args[1]) }
             when "CAT"
               file_step(kind) { File.open(args[0], "rb") { |io| IO.copy_stream(io, $stdout) } }
             when "LN"
               file_step(kind) { File.symlink(args[1], args[2]) }
             end
    if status != 0
      # a failed command stops the plan (set -e); a SPANF after it is still the bash's span (its status is passed on)
      nxt = plan[index + 1]
      trace_step(nxt[0], nxt[1], rec, vars) if nxt && nxt[0] == "SPANF"
      return status
    end
    # EXEC ends the plan with its status, as the bash's exec does
    return 0 if kind == "EXEC"
  end
  0
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

  run = lambda do |tmp|
    rec = NfccxxTrace::Recorder.new
    status = if opts[:chdir]
               Dir.chdir(opts[:chdir]) { run_plan(plan, opts[:env], opts[:root], tmp, rec) }
             else
               run_plan(plan, opts[:env], opts[:root], tmp, rec)
             end
    # the run's end: the driver's span and the closing lines, then the files. With --fallback a failed run writes nothing
    rec.finish_trace
    rec.commit if status.zero? || !opts[:fallback]
    status
  end
  return run.call(File.expand_path(opts[:tmp])) if opts[:tmp]

  Dir.mktmpdir("nfcxx-run") { |dir| run.call(dir) }
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
