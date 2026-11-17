#!/bin/bash
# scripts/nfcxx-k1om.rb plan must leave the state the bash k1om block of nfcxx leaves (verbatim below): backend, the k1om root and
# the exports, or the refusal (message and status), for each target, freestanding and backend setting, toolchain, runtime and
# NFCXX_K1OM_ROOT setting.   bash tests/driver-k1om/run.sh
here=$(cd "$(dirname "$0")" && pwd -P); repo=$(cd "$here/../.." && pwd -P)
t=$(mktemp -d); trap 'rm -rf "$t"' EXIT
bash_block() {   # the driver's block, verbatim
if [ "$target" = linux_k1om ]; then
  [ $freestanding = 1 ] || { echo "nfcxx: --target=linux_k1om needs --freestanding (the host's C++ headers are GCC 13's, not k1om's)" >&2; exit 2; }
  [ "$backend_explicit" = 0 ] || [ "$backend" = gcc ] || { echo "nfcxx: --target=linux_k1om uses the gcc backend (the k1om GCC)" >&2; exit 2; }
  backend=gcc
  k1om_root=${NFCXX_K1OM_ROOT:-/opt/k1om}
  [ -x "$k1om_root/bin/k1om-mpss-linux-gcc" ] || { echo "nfcxx: no k1om toolchain at $k1om_root (NFCXX_K1OM_ROOT; docs/notes/k1om.md)" >&2; exit 2; }
  [ -f "$root/build/k1om/libC.a" ] || { echo "nfcxx: no k1om runtime at $root/build/k1om/libC.a (run scripts/setup-k1om.sh)" >&2; exit 2; }
  export NFCXX_GCC="$root/scripts/k1om-cc.rb" NFCXX_AS="$root/scripts/k1om-bin/as.rb" NFCXX_K1OM_ROOT="$k1om_root"
fi
}
# state ENGINE: the driver's state after the block (bash) or after the plan (ruby), one line; a refusal prints its status and message
state() {
  local out rc
  if [ "$1" = bash ]; then
    out=$( bash_block 2>"$t/err" && printf 'backend=%s gcc=%s as=%s k1om=%s' "$backend" "${NFCXX_GCC:-}" "${NFCXX_AS:-}" "${NFCXX_K1OM_ROOT:-}" ); rc=$?
  else
    out=$(ruby "$repo/scripts/nfcxx-k1om.rb" plan target="$target" freestanding="$freestanding" backend_explicit="$backend_explicit" backend="$backend" root="$root" 2>"$t/err"); rc=$?
    if [ $rc = 0 ]; then [ -n "$out" ] && eval "$out"; out="backend=$backend gcc=${NFCXX_GCC:-} as=${NFCXX_AS:-} k1om=${NFCXX_K1OM_ROOT:-}"; fi
  fi
  printf 'status=%s %s | %s\n' "$rc" "$out" "$(cat "$t/err")"
}
pass=0; fail=0
for tc in ok missing; do
  root="$t/$tc"; mkdir -p "$root/build/k1om" "$root/scripts" "$root/tc/bin"
  if [ $tc = ok ]; then : > "$root/build/k1om/libC.a"; printf '#!/bin/sh\n' > "$root/tc/bin/k1om-mpss-linux-gcc"; chmod +x "$root/tc/bin/k1om-mpss-linux-gcc"; fi
  for target in linux_k1om other; do for freestanding in 0 1; do for backend_explicit in 0 1; do for backend in gcc pathb; do for envroot in unset "$root/tc"; do
    if [ "$envroot" = unset ]; then unset NFCXX_K1OM_ROOT; else export NFCXX_K1OM_ROOT="$envroot"; fi
    unset NFCXX_GCC NFCXX_AS
    want=$(state bash)
    unset NFCXX_GCC NFCXX_AS
    got=$(state ruby)
    if [ "$want" = "$got" ]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL tc=$tc target=$target fs=$freestanding be=$backend_explicit backend=$backend env=$envroot"; echo "  bash: $want"; echo "  ruby: $got"; fi
  done; done; done; done; done
done
unset NFCXX_K1OM_ROOT
echo "driver-k1om: $pass passed, $fail failed"
[ $fail = 0 ]
