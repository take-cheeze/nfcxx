#!/bin/bash
# scripts/nfcxx-backend-env.rb plan must give the NFCXX_CC and the refusals of the bash backend case of nfcxx (copied verbatim
# below), for each backend, freestanding setting, host and QBE state. The root's build/qbe/qbe exists or not per case.
#   bash tests/driver-backend-env/run.sh
here=$(cd "$(dirname "$0")" && pwd -P); repo=$(cd "$here/../.." && pwd -P)
t=$(mktemp -d); trap 'rm -rf "$t"' EXIT
pass=0; fail=0
bash_case() {   # the driver's case, verbatim (root, backend, freestanding, pb_fs_host set by the caller)
case $backend in
  pathb) [ $freestanding = 0 ] || [ $pb_fs_host = 1 ] ||
           { echo "nfcxx: Path B (--backend=pathb) compiles freestanding programs on x86-64 and aarch64 Linux and arm64 macOS only" >&2; exit 2; }
       [ -x "$root/build/qbe/qbe" ] || { echo "nfcxx: QBE not built; run scripts/setup-qbe.sh" >&2; exit 2; }
       export NFCXX_CC=$root/scripts/gcc-cc.rb ;;
  gcc) export NFCXX_CC=$root/scripts/gcc-cc.rb ;;
  *) echo "nfcxx: unknown backend '$backend'" >&2; exit 2 ;;
esac
}
for qbe in yes no; do
  root="$t/$qbe"; mkdir -p "$root/build/qbe" "$root/scripts"; export root
  if [ $qbe = yes ]; then printf '#!/bin/sh\n' > "$root/build/qbe/qbe"; chmod +x "$root/build/qbe/qbe"; fi
  for backend in pathb gcc bogus; do for fs in 0 1; do for pb in 0 1; do
    # the bash, in a subshell (its exit is the case's): the status, the stderr and NFCXX_CC
    want=$( (backend=$backend; freestanding=$fs; pb_fs_host=$pb; bash_case; echo "NFCXX_CC=${NFCXX_CC:-}") 2>"$t/w.err"; echo "rc=$?" ) ; wrc=$(echo "$want" | tail -1); want=$(echo "$want" | sed '$d')
    want_err=$(cat "$t/w.err")
    got=$(out=$(ruby "$repo/scripts/nfcxx-backend-env.rb" plan backend="$backend" freestanding="$fs" pb_fs_host="$pb" root="$root" 2>"$t/g.err"); rc=$?
          if [ $rc = 0 ]; then eval "$out"; echo "NFCXX_CC=${NFCXX_CC:-}"; fi; echo "rc=$rc"); grc=$(echo "$got" | tail -1); got=$(echo "$got" | sed '$d')
    got_err=$(cat "$t/g.err")
    if [ "$wrc" = "$grc" ] && [ "$want" = "$got" ] && [ "$want_err" = "$got_err" ]; then pass=$((pass + 1)); else
      fail=$((fail + 1)); echo "FAIL qbe=$qbe backend=$backend fs=$fs pb=$pb: bash [$wrc $want $want_err] ruby [$grc $got $got_err]"; fi
  done; done; done
done
echo "driver-backend-env: $pass passed, $fail failed"
[ $fail = 0 ]
