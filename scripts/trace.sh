# Chrome trace-event output for nfcxx, viewable in https://ui.perfetto.dev ("Open trace file").
# Enabled by --trace=FILE on the nfcxx driver, or by NFCXX_TRACE=FILE in the environment.
# Every process that runs with NFCXX_TRACE set appends complete ("X") events to the file; the driver
# writes the opening "[" and the closing "]", so the file is valid JSON. Times are wall-clock
# microseconds from GNU date (Linux). Every function is a no-op when NFCXX_TRACE is unset.

trace_now() { local t; t=$(date +%s%N); echo $((t / 1000)); }

# Start time for trace_end: a clock reading when tracing, 0 otherwise (no date call when disabled).
trace_start() { if [ -n "${NFCXX_TRACE:-}" ]; then trace_now; else echo 0; fi; }

trace_escape() { local s=${1//\\/\\\\}; printf '%s' "${s//\"/\\\"}"; }

# Record a span from start (from trace_start) to now. Args: start name category.
trace_end() {
  [ -n "${NFCXX_TRACE:-}" ] || return 0
  local start=$1 now
  now=$(trace_now)
  printf '{"name":"%s","cat":"%s","ph":"X","ts":%s,"dur":%s,"pid":%s,"tid":1},\n' \
    "$(trace_escape "$2")" "$3" "$start" $((now - start)) "${BASHPID:-$$}" >> "$NFCXX_TRACE"
}

# Driver only: start a trace file at $1 and record the whole run when the driver exits.
trace_begin() {
  NFCXX_TRACE=$(realpath -m "$1"); export NFCXX_TRACE
  printf '[\n' > "$NFCXX_TRACE"
  NFCXX_TRACE_T0=$(trace_now)
  trap trace_finish EXIT
}

trace_finish() {
  [ -n "${NFCXX_TRACE_T0:-}" ] || return 0
  local t0=$NFCXX_TRACE_T0
  unset NFCXX_TRACE_T0
  trace_end "$t0" nfcxx driver
  printf '{"name":"trace_end","ph":"i","s":"g","ts":%s,"pid":%s,"tid":1}\n]\n' "$(trace_now)" "$$" >> "$NFCXX_TRACE"
}
