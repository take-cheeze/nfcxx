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

  # the two texts of a span from START to now: the NFCXX_TIME_LOG line and the trace event, each nil when its output is off.
  # span writes them; the Recorder keeps them until its run ends.
  def span_texts(start, name, category, unit:, pid:, log:, trace:)
    dur = now_us - start
    log_text = log ? format("%d.%06d\t%s\t%s\t%s\n", dur / 1_000_000, dur % 1_000_000, category, name, unit) : nil
    trace_text = trace ? format(%({"name":"%s","cat":"%s","ph":"X","ts":%d,"dur":%d,"pid":%d,"tid":1},\n),
                                escape(name), category, start, dur, pid) : nil
    [log_text, trace_text]
  end

  # record a span from START (from start) to now
  def span(start, name, category, unit: nil, pid: Process.pid, env: ENV)
    return unless enabled?(env)

    log = env["NFCXX_TIME_LOG"].to_s
    trace = env["NFCXX_TRACE"].to_s
    unit ||= env["NFCXX_TRACE_UNIT"].to_s
    log_text, trace_text = span_texts(start, name, category, unit: unit, pid: pid, log: !log.empty?, trace: !trace.empty?)
    File.open(log, "a") { |f| f.write(log_text) } if log_text
    File.open(trace, "a") { |f| f.write(trace_text) } if trace_text
  end

# the batched spans of a driver run (trace.sh appends them to the PENDING file, NUL-separated: start, stop, name, category,
  # pid and unit, six fields a span, in the order they ended). flush writes their trace events and time-log lines, in that
  # order, to the files of ENV (as span does), and empties the file's records.
  def flush(pending, env: ENV)
    fields = File.binread(pending).split("\0", -1)
    fields.pop if fields.last == ""
    log = env["NFCXX_TIME_LOG"].to_s
    trace = env["NFCXX_TRACE"].to_s
    log_text = +""
    trace_text = +""
    fields.each_slice(6) do |start, stop, name, category, pid, unit|
      start = start.to_i
      dur = stop.to_i - start
      log_text << format("%d.%06d\t%s\t%s\t%s\n", dur / 1_000_000, dur % 1_000_000, category, name, unit) unless log.empty?
      trace_text << format(%({"name":"%s","cat":"%s","ph":"X","ts":%d,"dur":%d,"pid":%d,"tid":1},\n),
                           escape(name), category, start, dur, pid.to_i) unless trace.empty?
    end
    File.open(log, "a") { |f| f.write(log_text) } unless log.empty? || log_text.empty?
    File.open(trace, "a") { |f| f.write(trace_text) } unless trace.empty? || trace_text.empty?
  end

  # The spans of one run, kept in memory until commit. The runner of a plan (scripts/nfcxx-run.rb) records the driver's spans
  # with it, in the bash's order and with the bash's texts, and writes the files when the run ends. A run that the bash then
  # does again (discard) writes nothing, so the bash's own trace is the whole of the file and of the time log.
  class Recorder
    attr_accessor :trace, :time_log, :unit

    def initialize
      @trace = nil        # the trace file (absolute), nil when the trace is off
      @time_log = nil     # the time log (absolute), nil when it is off
      @unit = ""          # the unit of the time log's lines (the driver's trace_unit)
      @log_lines = []
      @events = []
      @t0 = nil           # the start of the run, from begin_trace (the trace is on)
      @closing = nil      # the closing lines of the trace file, from finish_trace
    end

    def enabled?
      !@trace.nil? || !@time_log.nil?
    end

    # trace_start: a clock reading when tracing, 0 otherwise
    def start
      enabled? ? NfccxxTrace.now_us : 0
    end

    # trace_end: a span from START to now
    def span(start, name, category, unit: @unit, pid: Process.pid)
      return unless enabled?

      log_text, trace_text = NfccxxTrace.span_texts(start, name, category, unit: unit, pid: pid,
                                                    log: !@time_log.nil?, trace: !@trace.nil?)
      @log_lines << log_text if log_text
      @events << trace_text if trace_text
    end

    # trace_begin, for the trace file (written at commit): the start of the run
    def begin_trace
      @t0 = NfccxxTrace.now_us
    end

    # trace_finish: the whole run's span, and the closing lines of the trace file (this run is its owner)
    def finish_trace
      return if @t0.nil?

      span(@t0, "nfcxx", "driver")
      @closing = format(%({"name":"trace_end","ph":"i","s":"g","ts":%d,"pid":%d,"tid":1}\n]\n), NfccxxTrace.now_us, Process.pid) if @trace
      @t0 = nil
    end

    # writes the files: the trace file (the opening "[", the events, the closing lines) and the time log's lines, appended
    def commit
      File.write(@trace, "[\n" + @events.join + @closing.to_s) if @trace
      File.open(@time_log, "a") { |f| f.write(@log_lines.join) } if @time_log && !@log_lines.empty?
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
  when "flush" then NfccxxTrace.flush(ARGV[1])
  when "open" then File.write(ARGV[1], "[\n")
  when "close"
    File.open(ARGV[1], "a") do |f|
      f.write(format(%({"name":"trace_end","ph":"i","s":"g","ts":%d,"pid":%d,"tid":1}\n]\n), NfccxxTrace.now_us, ARGV[2].to_i))
    end
  else abort "trace: unknown command #{ARGV[0].inspect} (now, span, open, close)"
  end
end
