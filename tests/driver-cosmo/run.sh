#!/bin/bash
# scripts/nfcxx-cosmo-setup.rb setup must leave the driver in the state the bash --cosmo block leaves: the same backend, environment,
# gnu version and cflags, or the same refusal (message and status), for each combination of the inputs. The block is copied
# verbatim from tests/driver-body/nfcxx-oracle.sh; the compiler is a stub (its -dumpfullversion prints STUB_GCC).
#   bash tests/driver-cosmo/run.sh
here=$(cd "$(dirname "$0")" && pwd -P); repo=$(cd "$here/../.." && pwd -P)
t=$(mktemp -d); trap 'rm -rf "$t"' EXIT
mkdir -p "$t/stub/bin" "$t/root"
printf '#!/bin/bash\n[ "$1" = -dumpfullversion ] && echo "${STUB_GCC-13.2.0}"\nexit 0\n' > "$t/stub/bin/cosmocc"; chmod +x "$t/stub/bin/cosmocc"
cat > "$t/lib.sh" <<'LIB'
# the bash block, verbatim
block() {
if [ $cosmo = 1 ]; then
  [ $path_b = 0 ] || backend=pathb
  if [ $backend != pathb ]; then
    [ $backend_explicit = 0 ] || [ $backend = gcc ] || { echo "nfcxx: --cosmo needs --backend=gcc or --backend=pathb" >&2; exit 2; }
    backend=gcc
  fi
  cosmo_bin=${NFCXX_COSMOCC:-$root/build/cosmocc/bin/cosmocc}
  [ -x "$cosmo_bin" ] || { echo "nfcxx: $cosmo_bin is not installed; run scripts/setup-cosmo.sh (or set NFCXX_COSMOCC)" >&2; exit 2; }
  cosmo_root=$(cd "$(dirname "$cosmo_bin")/.." && pwd)
  export NFCXX_GCC=$cosmo_bin
  export NFCXX_SYS_INCLUDES=$cosmo_root/include/third_party/libcxx:$cosmo_root/include
  gver=$cosmo_root/bin/x86_64-linux-cosmo-g++; [ -x "$gver" ] || gver=$cosmo_bin
  [ -n "${gnu:-}" ] || gnu=$({ "$gver" -dumpfullversion 2>/dev/null || true; } | awk -F. '{ printf "%d%02d%02d\n", $1, $2, $3 }')
  cflags+=(-D__COSMOPOLITAN__ -D__COSMOCC__ -D__FATCOSMOCC__)
  [ $backend = pathb ] && cflags+=('-D__has_feature(x)=0' -include "$cosmo_root/include/libc/integral/normalize.inc" -include "$root/lib/cosmo/libcxx_traits.h")
fi
}
# the state after the block (or the refusal): one line
report() { printf 'status=%s backend=%s gcc=%s sys=%s gnu=%s cflags=%s\n' "$1" "$backend" "${NFCXX_GCC:-}" "${NFCXX_SYS_INCLUDES:-}" "$gnu" "$(printf '%s|' ${cflags[@]+"${cflags[@]}"})"; }
LIB
pass=0; fail=0
for cmd in "$t/stub/bin/cosmocc" "$t/missing/cosmocc"; do
for backend in gcc pathb bogus; do for be in 0 1; do for pb in 0 1; do for gnu0 in "" 130000; do for sg in 13.2.0 "" 12.1.0.x; do
  pre="source '$t/lib.sh'; root='$t/root'; cosmo=1; path_b=$pb; backend_explicit=$be; backend='$backend'; gnu='$gnu0'; cflags=()"
  # bash: the block, then the state (a refusal exits the block: its status is the result)
  bout=$(env -i PATH="$PATH" STUB_GCC="$sg" NFCXX_COSMOCC="$cmd" bash -c "$pre; block; report 0" 2>"$t/bash.err"); bs=$?
  # ruby: the setup's output evaluated in the driver, then the state (a refusal of the setup is the result)
  gout=$(env -i PATH="$PATH" STUB_GCC="$sg" NFCXX_COSMOCC="$cmd" bash -c "$pre
    sh=\$(ruby '$repo/scripts/nfcxx-cosmo-setup.rb' setup root='$t/root' backend=\"\$backend\" backend_explicit=$be path_b=$pb gnu=\"\$gnu\" 2>'$t/ruby.err') || exit \$?
    eval \"\$sh\"; report 0" 2>/dev/null); gs=$?
  [ $bs = 0 ] && want="$bout" || want="status=$bs"
  [ $gs = 0 ] && got="$gout" || got="status=$gs"
  if [ "$want" = "$got" ] && [ "$(cat "$t/bash.err")" = "$(cat "$t/ruby.err")" ]; then pass=$((pass + 1)); else
    fail=$((fail + 1)); echo "FAIL cmd=$cmd backend=[$backend] be=$be pb=$pb gnu=[$gnu0] stub=[$sg]"
    echo "  bash: $want | $(cat "$t/bash.err")"; echo "  ruby: $got | $(cat "$t/ruby.err")"; fi
done; done; done; done; done; done
echo "driver-cosmo: $pass passed, $fail failed"
[ $fail = 0 ]
