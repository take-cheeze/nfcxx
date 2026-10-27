#!/usr/bin/env bash
# --trace output: a valid Chrome trace-event JSON file with the expected spans, for both backends.
# The program's exit code must still match its EXPECT value. Open the file in https://ui.perfetto.dev.
cd "$(dirname "$0")/../.."
root=$PWD
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
src=tests/cases/constexpr_static.cpp   # EXPECT: 120
fail=0

check_json() { # file label expected-names...
  local json=$1 label=$2; shift 2
  python3 -I - "$json" "$label" "$@" <<'PY'
import json, sys
path, label, want = sys.argv[1], sys.argv[2], sys.argv[3:]
events = json.load(open(path))          # fails on invalid JSON
assert isinstance(events, list) and events, "not a non-empty JSON array"
spans = [e for e in events if e.get("ph") == "X"]
for e in spans:
    assert isinstance(e["ts"], int) and isinstance(e["dur"], int) and e["dur"] >= 0, e
    assert "pid" in e and "name" in e, e
names = {e["name"] for e in spans}
missing = [n for n in want if n not in names]
assert not missing, f"{label}: missing spans {missing}; have {sorted(names)}"
print(f"ok   {label}: {len(spans)} spans, all required spans present")
PY
}

backends=${NFCXX_BACKEND:-"qbe gcc"}
for backend in $backends; do
  json=$tmp/$backend.json
  if ! NFCXX_BACKEND=$backend ./nfcxx --trace="$json" "$src" -o "$tmp/$backend.bin" > "$tmp/$backend.log" 2>&1; then
    echo "FAIL $backend: build"; cat "$tmp/$backend.log"; fail=1; continue
  fi
  "$tmp/$backend.bin"; rc=$?
  [ $rc -eq 120 ] || { echo "FAIL $backend: exit $rc, want 120"; fail=1; continue; }
  common=("nfcxx" "host C++ headers" "eccp (front end, C compile, link)")
  if [ $backend = qbe ]; then
    check_json "$json" qbe "${common[@]}" "cc -E (preprocess)" "cproc (C to QBE IL)" \
      "qbe (IL to assembly)" "cc -c (assemble)" || fail=1
  else
    check_json "$json" gcc "${common[@]}" || fail=1
  fi
done

# --emit-c runs the front end alone; its span is named accordingly.
./nfcxx --emit-c --trace="$tmp/emit.json" "$src" > /dev/null || fail=1
check_json "$tmp/emit.json" emit-c "nfcxx" "host C++ headers" "cpfe --emit-c (front end)" || fail=1

# NFCXX_TIME_LOG: one line per stage, "SECONDS<Tab>CATEGORY<Tab>STAGE<Tab>SOURCE", the QBE back end's script stages
# too, and no trace file. Two compiles append to the same log. On the first backend of the run (macOS has gcc only).
tl=$tmp/time.log; tb=${backends%% *}
for i in 1 2; do NFCXX_TIME_LOG=$tl NFCXX_BACKEND=$tb ./nfcxx "$src" -o "$tmp/tl$i.bin" > "$tmp/tl.log" 2>&1 || { echo "FAIL time log: build"; cat "$tmp/tl.log"; fail=1; }; done
qsteps=0; [ "$tb" != qbe ] || qsteps=8
if awk -F'\t' -v src="$src" 'NF != 4 || $1 !~ /^[0-9]+\.[0-9]{6}$/ || $4 != src { bad = 1 } END { exit bad }' "$tl" \
   && [ "$(cut -f3 "$tl" | grep -c '^eccp (front end, C compile, link)$')" = 2 ] && [ "$(cut -f2 "$tl" | grep -c '^qbe-backend$')" -ge $qsteps ]; then
  echo "ok   time log: $(wc -l < "$tl") lines"
else
  echo "FAIL time log:"; cat "$tl"; fail=1
fi

# Without --trace (and without NFCXX_TRACE) no trace file is written.
plain=$tmp/plain; mkdir "$plain"
(cd "$plain" && env -u NFCXX_TRACE NFCXX_BACKEND=gcc "$root/nfcxx" "$root/$src" -o "$plain/a.out") || fail=1
[ -z "$(ls "$plain")" ] || [ "$(ls "$plain")" = a.out ] || { echo "FAIL: unexpected files without --trace"; fail=1; }
[ -z "$(find "$plain" -name '*.json')" ] || { echo "FAIL: a trace file appeared without --trace"; fail=1; }

[ $fail = 0 ] && echo "trace: ok"
exit $fail
