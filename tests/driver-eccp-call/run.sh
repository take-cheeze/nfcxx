#!/bin/bash
# The pinned copy (pinned-eccp-block.txt) was taken from the driver at commit 1aa750d8b52163609481ea3cb4ad631389529a7b, before the B8 switch.
# The eccp call block of ./nfcxx (the one-step build: trace_start, the subshell that runs eccp, trace_end) is pinned before any
# port (docs/notes/driver-eccp-call.md, option B). The block is copied verbatim out of ./nfcxx, so a change to its shape fails
# here. It runs under set -euo pipefail, as the driver does, against a stub eccp, and checks:
#   - the status of a failing eccp is the status of the block (pass-through);
#   - eccp's standard error reaches the caller unchanged;
#   - a successful call writes the span "eccp (front end, C compile, link)" with category eccp;
#   - a failing call writes no span (set -e exits before trace_end; decided in the design note: keep it that way);
#   - with tracing off, nothing is written;
#   - the command runs in eccp_cd, with the eccp environment exported in the child only.
#   bash tests/driver-eccp-call/run.sh
here=$(cd "$(dirname "$0")" && pwd -P); repo=$(cd "$here/../.." && pwd -P)
pass=0; fail=0
work=$(mktemp -d); trap 'rm -rf "$work"' EXIT

block=$(sed -n '/^t=\$(trace_start)$/,/^trace_end "\$t" "eccp (front end, C compile, link)" eccp$/p' "$here/pinned-eccp-block.txt")
if [ -z "$block" ] || [ "$(printf '%s\n' "$block" | wc -l)" -lt 5 ]; then
  echo "driver-eccp-call: the eccp call block was not found in ./nfcxx"; exit 1
fi

# the stub eccp: logs its argv, cwd and NFCXX_STUB_ENV, writes a line to stderr, exits with NFCXX_STUB_STATUS
stub="$work/eccp"
cat > "$stub" <<'EOF'
#!/bin/bash
printf 'argv:%s\n' "$*" >> "$NFCXX_STUB_LOG"
printf 'cwd:%s\n' "$(pwd -P)" >> "$NFCXX_STUB_LOG"
printf 'env:%s\n' "${NFCXX_STUB_ENV-unset}" >> "$NFCXX_STUB_LOG"
echo "stub stderr line" >&2
exit "${NFCXX_STUB_STATUS:-0}"
EOF
chmod +x "$stub"

# run the block once: $1 status of the stub, $2 "trace" or "notrace", $3 the directory eccp runs in ("" = none)
run_block() {
  local status=$1 mode=$2 cd=$3 log="$work/log.$RANDOM" pend="$work/pend.$RANDOM" errf="$work/err.$RANDOM"
  : > "$pend"; : > "$log"
  local trace_env=()
  if [ "$mode" = trace ]; then trace_env=(NFCXX_TRACE=1 NFCXX_TRACE_PENDING="$pend"); fi
  (
    env -i PATH="$PATH" HOME="$HOME" "${trace_env[@]}" NFCXX_STUB_LOG="$log" NFCXX_STUB_STATUS="$status" \
      NFCXX_STUB_ENV=exported bash -c '
        set -euo pipefail
        root='"$repo"'; RUBY=${RUBY:-ruby}; export RUBY
        source "$root/scripts/trace.sh"
        eccp_argv=('"$stub"' -x a.cpp "b c")
        eccp_envs=(NFCXX_STUB_ENV=exported); eccp_cd='"${cd:+$cd}"'
        '"$block"'
      ' > "$work/out" 2> "$errf"
  ) ; st=$?
  RUN_STATUS=$st; RUN_LOG=$(cat "$log"); RUN_PEND=$(tr '\0' '\n' < "$pend"); RUN_ERR=$(cat "$errf")
}

check() {  # check NAME CONDITION...: counts the result of a test expression (passed as a string)
  local name=$1; shift
  if eval "$*"; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL $name"; fi
}

# 1. success: status 0, the span is written, the command runs in the directory and sees the environment
run_block 0 trace "$work"
check "success status" '[ "$RUN_STATUS" = 0 ]'
check "success span" 'printf "%s" "$RUN_PEND" | grep -q "eccp (front end, C compile, link)"'
check "success category" 'printf "%s\n" "$RUN_PEND" | grep -qx eccp'
check "success argv" 'printf "%s\n" "$RUN_LOG" | grep -q "^argv:-x a.cpp b c$"'
check "success cwd" 'printf "%s\n" "$RUN_LOG" | grep -q "^cwd:$work\$"'
check "success env in child" 'printf "%s\n" "$RUN_LOG" | grep -q "^env:exported$"'
check "stderr unchanged" '[ "$RUN_ERR" = "stub stderr line" ]'

# 2. failure: the status passes through, stderr still reaches the caller, and no span is written
run_block 3 trace "$work"
check "failure status passes through" '[ "$RUN_STATUS" = 3 ]'
check "failure writes no span" '[ -z "$RUN_PEND" ]'
check "failure stderr unchanged" '[ "$RUN_ERR" = "stub stderr line" ]'

# 3. tracing off: success writes nothing and fails with no status change
run_block 0 notrace "$work"
check "notrace status" '[ "$RUN_STATUS" = 0 ]'
check "notrace writes nothing" '[ -z "$RUN_PEND" ]'

# 4. no eccp_cd: the command runs in the caller's directory (here the pwd of the test process), so no cd is made
run_block 0 trace ""
check "empty eccp_cd runs" '[ "$RUN_STATUS" = 0 ]'

echo "driver-eccp-call: $pass passed, $fail failed"
[ $fail = 0 ]
