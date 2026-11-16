# Sourced by nfcxx and by the scripts it runs: the trace and time-log functions, whose work is scripts/trace.rb's (the
# Chrome trace file and the NFCXX_TIME_LOG lines; docs/notes/driver-port-plan.md, stage 7). The bash original is
# tests/trace/oracle.sh. Every function is a no-op when neither NFCXX_TRACE nor NFCXX_TIME_LOG is set, and no process is
# started then: trace_start answers 0 without one.
#
# Batching: a driver that traces (trace_begin) keeps its spans in a pending file (NFCXX_TRACE_PENDING, exported, so the
# drivers it runs append to the same file). trace_end appends a span to it with no process started; trace_finish writes the
# pending spans in one call of trace.rb (flush), in the order they ended, then the closing lines. Without a pending file
# (no trace_begin: a time log alone, or a script that is not a driver), trace_end runs trace.rb's span directly, as before.
# A process killed without its EXIT trap (SIGKILL) loses its pending spans.
_trace_rb="$(dirname "${BASH_SOURCE[0]}")/trace.rb"
_trace_on() { [ -n "${NFCXX_TRACE:-}${NFCXX_TIME_LOG:-}" ]; }

# The clock in microseconds: date's nanoseconds where date has them (GNU date), else trace.rb's clock (macOS date has no %N).
trace_now() {
  local t
  t=$(date +%s%N 2>/dev/null) || t=
  case $t in
    ''|*[!0-9]*) "${RUBY:-ruby}" "$_trace_rb" now ;;
    *) echo $(( t / 1000 )) ;;
  esac
}

# Start time for trace_end: a clock reading when tracing, 0 otherwise.
trace_start() { if _trace_on; then trace_now; else echo 0; fi; }

# Record a span from start (from trace_start) to now. Args: start name category.
trace_end() {
  _trace_on || return 0
  if [ -n "${NFCXX_TRACE_PENDING:-}" ]; then
    local stop; stop=$(trace_now)
    printf '%s\0%s\0%s\0%s\0%s\0%s\0' "$1" "$stop" "$2" "$3" "${BASHPID:-$$}" "${trace_unit:-${NFCXX_TRACE_UNIT:-}}" \
      >> "$NFCXX_TRACE_PENDING"
    return 0
  fi
  "${RUBY:-ruby}" "$_trace_rb" span "$1" "$2" "$3" "${BASHPID:-$$}" "${trace_unit:-${NFCXX_TRACE_UNIT:-}}"
}

# Writes the pending spans (one trace.rb call), then empties the file.
trace_flush() {
  [ -n "${NFCXX_TRACE_PENDING:-}" ] && [ -s "$NFCXX_TRACE_PENDING" ] || return 0
  "${RUBY:-ruby}" "$_trace_rb" flush "$NFCXX_TRACE_PENDING"
  : > "$NFCXX_TRACE_PENDING"
}

# Driver only: start a trace file at $1 and record the whole run when the driver exits. Only the outermost driver
# (NFCXX_TRACE_OWNER) writes the opening "[" and the closing "]", and owns the pending file (removed at its end).
trace_begin() {
  NFCXX_TRACE=$(abs_path "$1"); export NFCXX_TRACE
  if [ -z "${NFCXX_TRACE_OWNER:-}" ]; then
    export NFCXX_TRACE_OWNER=$$
    "${RUBY:-ruby}" "$_trace_rb" open "$NFCXX_TRACE"
  fi
  if [ -z "${NFCXX_TRACE_PENDING:-}" ]; then
    export NFCXX_TRACE_PENDING="${TMPDIR:-/tmp}/nfcxx-trace-pending.$$"
    : > "$NFCXX_TRACE_PENDING"
  fi
  NFCXX_TRACE_T0=$(trace_now)
  trap trace_finish EXIT
}

trace_finish() {
  [ -n "${NFCXX_TRACE_T0:-}" ] || return 0
  local t0=$NFCXX_TRACE_T0
  unset NFCXX_TRACE_T0
  trace_end "$t0" nfcxx driver
  trace_flush
  if [ "${NFCXX_TRACE_OWNER:-}" = "$$" ]; then
    "${RUBY:-ruby}" "$_trace_rb" close "$NFCXX_TRACE" "$$"
    [ -z "${NFCXX_TRACE_PENDING:-}" ] || rm -f "$NFCXX_TRACE_PENDING"
  fi
}
