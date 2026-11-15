#!/usr/bin/env bash
# Differential test of the fetch scripts. scripts/fetch-cuda-libs.rb and scripts/fetch-cudart-wheel.rb run next to their bash
# originals (tests/fetch/oracle/) with the same arguments. Each pair is compared on stdout, the exit status, the tree it leaves
# (tests/fetch/tree.rb: names, modes, sizes, sha256, symlinks), and stderr where the two are meant to agree.
#   cuda-libs     the oracle (pip, which finds a wheel already in its directory) and the port read the same cached wheels:
#                 FETCH_WHEELS (default ~/.cache/nfcxx/cuda-libs/wheels; filled on the first run) is symlinked as wheels/ in
#                 each output, so no wheel is copied or downloaded twice. Needs PyPI (pip's index, the port's JSON API) and unzip.
#   cudart-wheel  a stub PyPI on 127.0.0.1 (python3's http.server) serves the JSON API and the wheels. The runtime and cccl
#                 wheels are the cached ones; nvidia-cuda-crt is synthetic. The oracle's curl reaches the stub through a shim
#                 on PATH; the port reads NFCXX_PYPI_URL. Needs the cached runtime and cccl wheels (run cuda-libs first).
# Usage: tests/fetch/run.sh [cuda-libs|cudart-wheel]     (default: both)
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../.." && pwd)
WHEELS=${FETCH_WHEELS:-$HOME/.cache/nfcxx/cuda-libs/wheels}
T=$(mktemp -d "${TMPDIR:-/tmp}/fetch-test.XXXXXX")
server_pid=
cleanup() {
  if [ -n "$server_pid" ]; then kill "$server_pid" 2>/dev/null || true; fi
  rm -rf "$T"
}
trap cleanup EXIT
export no_proxy="127.0.0.1,localhost${no_proxy:+,$no_proxy}"
export NO_PROXY=$no_proxy

pass=0
fail=0
# check LABEL COMMAND...: passes when COMMAND succeeds.
check() {
  local label=$1
  shift
  if "$@"; then
    pass=$((pass + 1))
    echo "  ok    $label"
  else
    fail=$((fail + 1))
    echo "  FAIL  $label"
  fi
}
both_zero() { [ "$1" -eq 0 ] && [ "$2" -eq 0 ]; }
both_nonzero() { [ "$1" -ne 0 ] && [ "$2" -ne 0 ]; }
both_empty() { [ ! -s "$1" ] && [ ! -s "$2" ]; }
# same_or_show LABEL A B: the files match, or the difference is printed.
same_or_show() {
  if cmp -s "$2" "$3"; then
    check "$1" true
  else
    check "$1" false
    diff "$2" "$3" | head -20 | sed 's/^/        /'
  fi
}

# ---------------------------------------------------------------------------------------------------------------------------
cuda_libs() {
  echo "cuda-libs: oracle (bash, pip) vs port (Ruby, PyPI JSON); wheels: $WHEELS"
  mkdir -p "$WHEELS"
  local impl out rc
  for impl in oracle ruby; do
    out=$T/cuda-libs/$impl/out
    mkdir -p "$out"
    ln -s "$WHEELS" "$out/wheels"
    set +e
    if [ $impl = oracle ]; then
      (cd "$T" && bash "$here/oracle/fetch-cuda-libs.sh" "$out") >"$T/cuda-libs.$impl.out" 2>"$T/cuda-libs.$impl.err"
    else
      (cd "$T" && ruby "$root/scripts/fetch-cuda-libs.rb" "$out") >"$T/cuda-libs.$impl.out" 2>"$T/cuda-libs.$impl.err"
    fi
    rc=$?
    set -e
    echo "$rc" >"$T/cuda-libs.$impl.rc"
    sed "s#$out#OUT#g" "$T/cuda-libs.$impl.out" >"$T/cuda-libs.$impl.out.n"
    ruby "$here/tree.rb" "$out" >"$T/cuda-libs.$impl.tree"
    rm -rf "$out"
  done
  local rco rcr
  rco=$(cat "$T/cuda-libs.oracle.rc")
  rcr=$(cat "$T/cuda-libs.ruby.rc")
  check "both exit 0" both_zero "$rco" "$rcr"
  same_or_show "same stdout (cuda-home line)" "$T/cuda-libs.oracle.out.n" "$T/cuda-libs.ruby.out.n"
  same_or_show "same tree" "$T/cuda-libs.oracle.tree" "$T/cuda-libs.ruby.tree"
  check "libcudart.so is a link to libcudart.so.12" grep -q -- '-> libcudart.so.12 lib64/libcudart.so$' "$T/cuda-libs.ruby.tree"
  check "stderr empty in both" both_empty "$T/cuda-libs.oracle.err" "$T/cuda-libs.ruby.err"
  echo "        tree: $(wc -l <"$T/cuda-libs.ruby.tree") entries, $(awk '$1 == "f" { n++; b += $3 } END { print n " files, " b " bytes" }' "$T/cuda-libs.ruby.tree")"
}

# ---------------------------------------------------------------------------------------------------------------------------
# make_stub MODE: the stub PyPI for the cases that follow (see stub.rb).
make_stub() {
  ruby "$here/stub.rb" "$T/stub" "$FETCH_STUB_URL" "$1" "$rtw" "$ccw" "$T/crt/crt-base.whl"
}

# cudart_case NAME MODE WANT CUDA_HOME OK EXPECT STDERR
#   OK=1: both succeed, and stdout has the line EXPECT. OK=0: both fail, with nothing on stdout.
#   STDERR=1: stderr must match as well (where the port's message is meant to be the bash's).
cudart_case() {
  local name=$1 mode=$2 want=$3 cuda=$4 ok=$5 expect=$6 want_stderr=$7
  local impl out rc
  make_stub "$mode"
  for impl in oracle ruby; do
    out=$T/cudart/$name/$impl/out
    mkdir -p "$out"
    set +e
    if [ $impl = oracle ]; then
      PATH="$T/shim:$PATH" CUDART_WHEEL_DIR="$out" CUDA_HOME="$cuda" \
        bash "$here/oracle/fetch-cudart-wheel.sh" "$want" \
        >"$T/cudart/$name.$impl.out" 2>"$T/cudart/$name.$impl.err"
    else
      CUDART_WHEEL_DIR="$out" CUDA_HOME="$cuda" NFCXX_PYPI_URL=$FETCH_STUB_URL \
        ruby "$root/scripts/fetch-cudart-wheel.rb" "$want" \
        >"$T/cudart/$name.$impl.out" 2>"$T/cudart/$name.$impl.err"
    fi
    rc=$?
    set -e
    echo "$rc" >"$T/cudart/$name.$impl.rc"
    sed "s#$out#OUT#g" "$T/cudart/$name.$impl.out" >"$T/cudart/$name.$impl.out.n"
    ruby "$here/tree.rb" "$out" >"$T/cudart/$name.$impl.tree"
  done
  local o=$T/cudart/$name.oracle r=$T/cudart/$name.ruby
  local rco rcr
  rco=$(cat "$o.rc")
  rcr=$(cat "$r.rc")
  echo "$name (mode $mode, want '$want', CUDA_HOME ${cuda##*/}):"
  if [ "$ok" = 1 ]; then
    check "    both exit 0" both_zero "$rco" "$rcr"
    check "    stdout has '$expect'" grep -qx -- "$expect" "$r.out.n"
    same_or_show "    same stdout" "$o.out.n" "$r.out.n"
  else
    check "    both exit non-zero" both_nonzero "$rco" "$rcr"
    check "    nothing on stdout" both_empty "$o.out" "$r.out"
    if [ "$want_stderr" = 1 ]; then
      same_or_show "    same stderr" "$o.err" "$r.err"
    else
      echo "    exit $rco (oracle) vs $rcr (port); stderr differs by design:"
      echo "      oracle: $(head -1 "$o.err")"
      echo "      port:   $(head -1 "$r.err")"
    fi
  fi
  same_or_show "    same tree" "$o.tree" "$r.tree"
}

cudart_wheel() {
  echo "cudart-wheel: oracle (bash, curl shim) vs port (Ruby, NFCXX_PYPI_URL); stub PyPI from the cached wheels"
  rtw=$WHEELS/nvidia_cuda_runtime_cu12-12.9.79-py3-none-manylinux2014_x86_64.manylinux_2_17_x86_64.whl
  ccw=$WHEELS/nvidia_cuda_cccl_cu12-12.9.27-py3-none-manylinux2014_x86_64.manylinux_2_17_x86_64.whl
  if [ ! -f "$rtw" ] || [ ! -f "$ccw" ]; then
    fail=$((fail + 1))
    echo "  FAIL  cached runtime and cccl wheels in $WHEELS (run: tests/fetch/run.sh cuda-libs first)"
    return
  fi

  mkdir -p "$T/crt" "$T/stub" "$T/cuda-single" "$T/cuda-multi"
  python3 -I -c '
import sys, zipfile
with zipfile.ZipFile(sys.argv[1], "w", zipfile.ZIP_DEFLATED) as z:
    z.writestr("nvidia/cuda_crt/include/crt/host_config.h", "/* synthetic, tests/fetch/run.sh */\n")
    z.writestr("nvidia/cuda_crt/include/crt/device_functions.h", "/* synthetic */\n")
' "$T/crt/crt-base.whl"
  printf '{"cuda_cudart" : {"name": "CUDA Runtime (cudart)", "version": "12.8.90"}}\n' >"$T/cuda-single/version.json"
  printf '{\n   "cuda_cudart" : {\n      "name" : "CUDA Runtime (cudart)",\n      "version" : "12.8.90"\n   }\n}\n' \
    >"$T/cuda-multi/version.json"

  # The oracle's curl: https://pypi.org/ goes to the stub, everything else is curl.
  mkdir -p "$T/shim"
  cat >"$T/shim/curl" <<'SH'
#!/usr/bin/env bash
args=()
for a in "$@"; do
  case $a in
    https://pypi.org/*) a=$FETCH_STUB_URL/${a#https://pypi.org/} ;;
  esac
  args+=("$a")
done
exec "$FETCH_REAL_CURL" "${args[@]}"
SH
  chmod +x "$T/shim/curl"
  export FETCH_REAL_CURL
  FETCH_REAL_CURL=$(command -v curl)

  local port
  port=$(python3 -I -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])')
  export FETCH_STUB_URL="http://127.0.0.1:$port"
  python3 -I -m http.server --bind 127.0.0.1 --directory "$T/stub" "$port" >"$T/http.log" 2>&1 &
  server_pid=$!
  local i
  for i in $(seq 100); do
    "$FETCH_REAL_CURL" -s -o /dev/null "$FETCH_STUB_URL/" && break
    sleep 0.1
  done

  cudart_case newest-of-major      normal "12.9" "$T/nocuda"       1 "runtime: 12.9.79" 1
  cudart_case fallback-to-major    normal "12.7" "$T/nocuda"       1 "runtime: 12.9.79" 1
  cudart_case newest               normal ""     "$T/nocuda"       1 "runtime: 13.0.1"  1
  cudart_case version-json         normal ""     "$T/cuda-single"  1 "runtime: 12.8.90" 1
  # version.json pretty-printed: the bash's line-by-line match finds no version, so it takes the newest (kept as is).
  cudart_case version-json-pretty  normal ""     "$T/cuda-multi"   1 "runtime: 13.0.1"  1
  cudart_case no-match             normal "99.1" "$T/nocuda"       0 ""                 0
  cudart_case bad-sha256           badsha "12.9" "$T/nocuda"       0 ""                 1
  cudart_case missing-wheel        missing "12.9" "$T/nocuda"      0 ""                 0
}

# ---------------------------------------------------------------------------------------------------------------------------
case ${1:-all} in
  cuda-libs) cuda_libs ;;
  cudart-wheel) cudart_wheel ;;
  all)
    cuda_libs
    cudart_wheel
    ;;
  *)
    echo "usage: $0 [cuda-libs|cudart-wheel]" >&2
    exit 2
    ;;
esac
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
