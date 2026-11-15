# Sourced by nfcxx and by the scripts it runs: the trace and time-log functions, whose work is scripts/trace.rb's (the
# Chrome trace file and the NFCXX_TIME_LOG lines; docs/notes/driver-port-plan.md, stage 7). The bash original is
# tests/trace/oracle.sh. Every function is a no-op when neither NFCXX_TRACE nor NFCXX_TIME_LOG is set, and no process is
# started then: trace_start answers 0 without one.
_trace_rb="$(dirname "${BASH_SOURCE[0]}")/trace.rb"
_trace_on() { [ -n "${NFCXX_TRACE:-}${NFCXX_TIME_LOG:-}" ]; }

trace_now() { "${RUBY:-ruby}" "$_trace_rb" now; }

# Start time for trace_end: a clock reading when tracing, 0 otherwise.
trace_start() { if _trace_on; then trace_now; else echo 0; fi; }

# Record a span from start (from trace_start) to now. Args: start name category.
trace_end() {
  _trace_on || return 0
  "${RUBY:-ruby}" "$_trace_rb" span "$1" "$2" "$3" "${BASHPID:-$$}" "${trace_unit:-${NFCXX_TRACE_UNIT:-}}"
}

# Driver only: start a trace file at $1 and record the whole run when the driver exits. Only the outermost driver
# (NFCXX_TRACE_OWNER) writes the opening "[" and the closing "]".
trace_begin() {
  NFCXX_TRACE=$(abs_path "$1"); export NFCXX_TRACE
  if [ -z "${NFCXX_TRACE_OWNER:-}" ]; then
    export NFCXX_TRACE_OWNER=$$
    "${RUBY:-ruby}" "$_trace_rb" open "$NFCXX_TRACE"
  fi
  NFCXX_TRACE_T0=$(trace_now)
  trap trace_finish EXIT
}

trace_finish() {
  [ -n "${NFCXX_TRACE_T0:-}" ] || return 0
  local t0=$NFCXX_TRACE_T0
  unset NFCXX_TRACE_T0
  trace_end "$t0" nfcxx driver
  if [ "${NFCXX_TRACE_OWNER:-}" = "$$" ]; then
    "${RUBY:-ruby}" "$_trace_rb" close "$NFCXX_TRACE" "$$"
  fi
}
