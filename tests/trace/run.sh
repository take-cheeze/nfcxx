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

for backend in qbe gcc; do
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

# Without --trace (and without NFCXX_TRACE) no trace file is written.
plain=$tmp/plain; mkdir "$plain"
(cd "$plain" && env -u NFCXX_TRACE NFCXX_BACKEND=gcc "$root/nfcxx" "$root/$src" -o "$plain/a.out") || fail=1
[ -z "$(ls "$plain")" ] || [ "$(ls "$plain")" = a.out ] || { echo "FAIL: unexpected files without --trace"; fail=1; }
[ -z "$(find "$plain" -name '*.json')" ] || { echo "FAIL: a trace file appeared without --trace"; fail=1; }

[ $fail = 0 ] && echo "trace: ok"
exit $fail
