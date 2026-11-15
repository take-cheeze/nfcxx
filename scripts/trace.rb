# Chrome trace-event output and the time log of nfcxx, ported to Ruby from scripts/trace.sh (stage 7 of
# docs/notes/driver-port-plan.md). The same settings and the same files: NFCXX_TRACE=FILE (trace events, viewable in
# https://ui.perfetto.dev) and NFCXX_TIME_LOG=FILE (one line per span: SECONDS<Tab>CATEGORY<Tab>NAME<Tab>UNIT). The
# driver's begin and finish are begin_trace and finish_trace; every function is a no-op when neither setting is set.
# tests/trace/run.sh checks the files against scripts/trace.sh.
#
#   require_relative "trace"
#   t0 = NfccxxTrace.start                 # 0 when tracing is off
#   ... work ...
#   NfccxxTrace.span(t0, "name", "category", unit: "x.c")

require_relative "host-sys"

module NfccxxTrace
  module_function

  # tracing is on when either setting is non-empty (the bash test is on the two concatenated)
  def enabled?(env = ENV)
    !(env["NFCXX_TRACE"].to_s + env["NFCXX_TIME_LOG"].to_s).empty?
  end

  # wall-clock microseconds (date +%s%N, divided by 1000)
  def now_us
    t = Time.now
    t.to_i * 1_000_000 + t.usec
  end

  # the start of a span, for span(): a clock reading when tracing, 0 otherwise
  def start(env = ENV)
    enabled?(env) ? now_us : 0
  end

  # a string for a JSON string: backslashes, then quotes (as trace_escape)
  def escape(s)
    s.gsub("\\") { "\\\\" }.gsub('"') { '\\"' }
  end

  # record a span from START (from start) to now
  def span(start, name, category, unit: nil, pid: Process.pid, env: ENV)
    return unless enabled?(env)

    now = now_us
    dur = now - start
    log = env["NFCXX_TIME_LOG"].to_s
    unless log.empty?
      unit ||= env["NFCXX_TRACE_UNIT"].to_s
      File.open(log, "a") do |f|
        f.write(format("%d.%06d\t%s\t%s\t%s\n", dur / 1_000_000, dur % 1_000_000, category, name, unit))
      end
    end
    trace = env["NFCXX_TRACE"].to_s
    return if trace.empty?

    File.open(trace, "a") do |f|
      f.write(format(%({"name":"%s","cat":"%s","ph":"X","ts":%d,"dur":%d,"pid":%d,"tid":1},\n),
                     escape(name), category, start, dur, pid))
    end
  end

  # the driver only: starts the trace file at FILE and returns the start for finish_trace. A driver run by another
  # driver shares the file: only the outermost one (NFCXX_TRACE_OWNER) writes the opening "[" and the closing "]".
  # The settings are set in ENV for the processes this one runs.
  def begin_trace(file, env: ENV)
    path = HostSys.abs_path(file)
    env["NFCXX_TRACE"] = path
    if env["NFCXX_TRACE_OWNER"].to_s.empty?
      env["NFCXX_TRACE_OWNER"] = Process.pid.to_s
      File.write(path, "[\n")
    end
    now_us
  end

  # the driver only: the span of the whole run (from begin_trace), and the closing "]" when this is the owner
  def finish_trace(t0, env: ENV)
    return if t0.nil?

    span(t0, "nfcxx", "driver", env: env)
    return unless env["NFCXX_TRACE_OWNER"].to_s == Process.pid.to_s

    File.open(env["NFCXX_TRACE"], "a") do |f|
      f.write(format(%({"name":"trace_end","ph":"i","s":"g","ts":%d,"pid":%d,"tid":1}\n]\n), now_us, Process.pid))
    end
  end
end

# The command line that scripts/trace.sh (nfcxx's shim) calls. The files and the settings are the environment's, as above.
#   ruby scripts/trace.rb now                          prints the clock reading (microseconds)
#   ruby scripts/trace.rb span START NAME CAT PID UNIT   records a span from START to now, for process PID
#   ruby scripts/trace.rb open FILE                    starts the trace file (the opening "[")
#   ruby scripts/trace.rb close FILE PID               the closing instant event and "]"
if $PROGRAM_NAME == __FILE__
  case ARGV[0]
  when "now" then puts NfccxxTrace.now_us
  when "span"
    _, start, name, cat, pid, unit = ARGV
    NfccxxTrace.span(start.to_i, name, cat, unit: unit, pid: pid.to_i)
  when "open" then File.write(ARGV[1], "[\n")
  when "close"
    File.open(ARGV[1], "a") do |f|
      f.write(format(%({"name":"trace_end","ph":"i","s":"g","ts":%d,"pid":%d,"tid":1}\n]\n), NfccxxTrace.now_us, ARGV[2].to_i))
    end
  else abort "trace: unknown command #{ARGV[0].inspect} (now, span, open, close)"
  end
end
