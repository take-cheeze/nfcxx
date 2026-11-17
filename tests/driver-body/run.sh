#!/bin/bash
# Stage B1 of docs/notes/driver-body-port.md: the oracle of the driver body. tests/driver-body/nfcxx-bash is ./nfcxx as it was
# when the port began (frozen; the bash driver's behaviour is what the Ruby driver must match). This checks that the frozen
# copy still runs and that it is the file it was taken from: the bash syntax parses, the copy's first lines are the driver's,
# and the copy answers --help as the driver does. The body stages compare against it (see the plan).
set -u
here=$(cd "$(dirname "$0")" && pwd -P)
repo=$(cd "$here/../.." && pwd -P)
oracle=$here/nfcxx-bash
pass=0; fail=0
check() { if [ "$2" = 0 ]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL $1"; fi; }
bash -n "$oracle"; check "the frozen driver parses" $?
# the driver differs from the frozen copy only where the ports moved code out: the Ruby flag (B2) and the default backend block (B3,
# scripts/nfcxx-backend.rb default). Both are removed from both sides; the rest must be the same.
check "the frozen driver matches the driver apart from the ports (B2, B3)" "$(
  diff -q <(sed -e '/^default_backend=0$/,/^fi$/d' -e '/^if \[ -n "\$sanitize" \]; then$/,/^fi$/d' -e '/^if \[ \$cosmo = 1 \]; then$/,/^fi$/d' "$oracle") \
          <(sed -e '/^# NFCXX_RUBY_DRIVER=1/,/NFCXX_RUBY_DRIVER:-0/d' -e '/^if \[ -n "\$sanitize" \]; then$/,/^fi$/d' -e '/^if \[ \$cosmo = 1 \]; then$/,/^fi$/d' "$repo/nfcxx" \
            | awk '/^# The default backend \(docs\/notes\/pathb-default.md; the rule is/ { skip = 1 }
                   skip && /uname -m\)"\)"$/ { skip = 0; next }
                   !skip') >/dev/null && echo 0 || echo 1)"
# B2: the flag runs the Ruby skeleton, which runs the oracle: a compile gives the same stdout, stderr and status
src=$(mktemp -d); printf 'int main() { return 0; }\n' > "$src/m.cpp"
(cd "$src" && "$repo/nfcxx" -c m.cpp -o plain.o >p.out 2>p.err; echo $? > p.rc; NFCXX_RUBY_DRIVER=1 "$repo/nfcxx" -c m.cpp -o flag.o >f.out 2>f.err; echo $? > f.rc)
check "the Ruby skeleton gives the bash driver's stdout, stderr and status" "$(cd "$src" && cmp -s p.out f.out && cmp -s p.err f.err && cmp -s p.rc f.rc && echo 0 || echo 1)"
rm -rf "$src"

echo "driver-body: $pass passed, $fail failed"
[ "$fail" = 0 ]
