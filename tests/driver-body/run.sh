#!/bin/bash
# Stage B1 of docs/notes/driver-body-port.md, kept after the B8 switch: the oracle of the driver body.
# tests/driver-body/nfcxx-oracle.sh is the bash driver as it was when the port began (frozen; the body the Ruby driver runs).
# ./nfcxx is a shim that runs scripts/nfcxx.rb (B8), so this checks: the frozen copy parses, the Ruby driver runs that copy
# as its oracle (scripts/nfcxx.rb names it), the shim runs the Ruby driver with the same status and output, and the flag
# NFCXX_RUBY_DRIVER no longer changes anything.
# Retired at B8: the line-by-line diff of the frozen copy against the driver (it compared ./nfcxx's text, which is now a
# shim) and its strip rules. The frozen copy is the reference now; the port's changes are checked by the suites that run it.
set -u
here=$(cd "$(dirname "$0")" && pwd -P)
repo=$(cd "$here/../.." && pwd -P)
oracle=$here/nfcxx-oracle.sh
pass=0; fail=0
check() { if [ "$2" = 0 ]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL $1"; fi; }
bash -n "$oracle"; check "the frozen driver parses" $?
# the Ruby driver runs this copy as its oracle, and the shim runs the Ruby driver
grep -q 'File.join(root, "tests", "driver-body", "nfcxx-oracle.sh")' "$repo/scripts/nfcxx.rb"; check "the Ruby driver runs the frozen copy" $?
grep -q 'scripts/nfcxx.rb' "$repo/nfcxx"; check "./nfcxx runs the Ruby driver" $?
# B2: the flag runs the Ruby skeleton, which runs the oracle: a compile gives the same stdout, stderr and status
src=$(mktemp -d); printf 'int main() { return 0; }\n' > "$src/m.cpp"
# the tool the driver builds on first use (cuda-rewrite) is built here, before the comparison: a first build prints ninja's output to
# standard error, which only the first run would have, so the comparison would fail on a fresh tree
ruby "$repo/scripts/nfcxx-ensure-tool.rb" "$repo/tools/cuda-rewrite" "$repo/build/cuda-rewrite" >/dev/null 2>&1 || true
(cd "$src" && "$repo/nfcxx" -c m.cpp -o plain.o >p.out 2>p.err; echo $? > p.rc; NFCXX_RUBY_DRIVER=1 "$repo/nfcxx" -c m.cpp -o flag.o >f.out 2>f.err; echo $? > f.rc)
check "the flag changes nothing: the same stdout, stderr and status" "$(cd "$src" && cmp -s p.out f.out && cmp -s p.err f.err && cmp -s p.rc f.rc && echo 0 || echo 1)"
# the shim passes the arguments, the output and the status of the Ruby driver through
(cd "$src" && ruby "$repo/scripts/nfcxx.rb" -c m.cpp -o direct.o >d.out 2>d.err; echo $? > d.rc)
check "the shim gives the Ruby driver's stdout, stderr and status" "$(cd "$src" && cmp -s p.out d.out && cmp -s p.err d.err && cmp -s p.rc d.rc && echo 0 || echo 1)"
rm -rf "$src"

echo "driver-body: $pass passed, $fail failed"
[ "$fail" = 0 ]
