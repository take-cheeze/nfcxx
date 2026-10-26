#!/usr/bin/env bash
# libtorch with CUDA, bundled (docs/notes/bundle.md, "libtorch with CUDA"). By hand, not in CI: the libtorch download is
# 2.5 GB and the bundle 2.6 GB. Needs LIBTORCH=<the unpacked libtorch directory of a CUDA build>, or TORCH_FETCH=1 to
# download the pinned one (2.5.1+cu124, cxx11 ABI) into ~/.cache/nfcxx/libtorch-cu124 (it has no kernels for Blackwell
# GPUs; 2.14.1+cu130, libtorch-shared-with-deps-2.14.1%2Bcu130.zip, does). No GPU is needed: without one,
# the program reports no CUDA device, and the CUDA libraries are still loaded (libtorch_cuda's constructors run) and
# every library libtorch and cuDNN dlopen is loaded explicitly (T_DLOPEN).
# For each of g++ and nfcxx (gcc backend; NFCXX_BACKEND=qbe for QBE) the program is built normally, then bundled with
# --stubs into DIST/t with DIST/lib holding the stubs and the dlopen'ed libraries. The bundle must print what the
# normal build prints and must open nothing under LIBTORCH (LD_DEBUG=files).
cd "$(dirname "$0")/../.."
root=$PWD
d=tests/bundle
fail=0
if [ -z "${LIBTORCH:-}" ]; then
  if [ "${TORCH_FETCH:-}" != 1 ]; then echo "skip: set LIBTORCH=<libtorch dir> or TORCH_FETCH=1"; exit 0; fi
  LIBTORCH=${XDG_CACHE_HOME:-$HOME/.cache}/nfcxx/libtorch-cu124/libtorch
  if [ ! -f "$LIBTORCH/lib/libtorch_cuda.so" ]; then
    mkdir -p "$(dirname "$LIBTORCH")"
    url=https://download.pytorch.org/libtorch/cu124/libtorch-cxx11-abi-shared-with-deps-2.5.1%2Bcu124.zip
    curl -sSL -o "$(dirname "$LIBTORCH")/libtorch.zip" "$url" && unzip -q -o "$(dirname "$LIBTORCH")/libtorch.zip" -d "$(dirname "$LIBTORCH")" &&
      rm "$(dirname "$LIBTORCH")/libtorch.zip" || { echo "FAIL fetching $url"; exit 1; }
  fi
fi
L=$LIBTORCH/lib
[ -f "$L/libtorch_cuda.so" ] || { echo "FAIL $L/libtorch_cuda.so not found (a CUDA libtorch is needed)"; exit 1; }
ninja -C tools/bundle >/dev/null || exit 1
B=$root/build/nfcbundle
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
# The libraries that are dlopen'ed rather than needed: they stay files next to the stubs.
plugins=""
for f in "$L"/libtorch_cuda_linalg.so "$L"/libcudnn_*.so.9 "$L"/libnvrtc*.so* "$L"/libnvToolsExt*.so*; do
  [ -f "$f" ] && plugins+=" $(basename "$f")"
done
export T_DLOPEN=$plugins
inc=(-I"$LIBTORCH/include" -I"$LIBTORCH/include/torch/csrc/api/include")
# libtorch 2.9 and later need C++20 (ATen.h stops with an #error otherwise); 2.5.1 builds as C++17.
std=c++17; grep -q 'C++20 or later' "$LIBTORCH/include/ATen/ATen.h" 2>/dev/null && std=c++20

run_case() {  # run_case NAME EXE DIST: EXE (normal build) against DIST/t (its bundle)
  local name=$1 exe=$2 dist=$3 ref out opened st
  for p in $plugins; do cp "$L/$p" "$dist/lib/"; done
  # The normal build must run to the end: a bundle that fails the same way would match it.
  ref=$("$exe" 2>&1); st=$?
  if [ $st != 0 ] || ! grep -q '^cuda available' <<<"$ref"; then echo "FAIL $name (the normal build, status $st)"; tail -5 <<<"$ref"; fail=1; return; fi
  out=$("$dist/t" 2>&1)
  if [ "$ref" != "$out" ]; then echo "FAIL $name (output differs)"; diff <(echo "$ref") <(echo "$out") | head -20; fail=1; return; fi
  opened=$(LD_DEBUG=files "$dist/t" 2>&1 >/dev/null | grep -o "file=$LIBTORCH[^ ]*" | sort -u)
  if [ -n "$opened" ]; then echo "FAIL $name: the bundle opened files of LIBTORCH:"; echo "$opened" | head; fail=1; return; fi
  case $(readelf -dW "$dist/t" | grep -c 'NEEDED.*libtorch') in 0) echo "FAIL $name: no stubs needed"; fail=1; return ;; esac
  echo "ok   $name ($(du -sh "$dist/t" | cut -f1), $(ls "$dist/lib" | wc -l) files in lib/)"
  grep -E "cuda available|c10::Error|on cuda|dlopen" <<<"$out" | sed 's/^/       /'
}

# g++: libtorch_cuda is kept a DT_NEEDED with --no-as-needed, as torch's CMake config does.
w=$tmp/gxx; mkdir -p "$w/dist/lib"
if out=$(g++ -O1 -std=$std $d/torch.cpp "${inc[@]}" -L"$L" -Wl,--no-as-needed -ltorch -ltorch_cuda -ltorch_cpu -lc10_cuda -lc10 \
           -Wl,--as-needed -Wl,-rpath,"$L" -o "$w/t" 2>&1) &&
   out=$("$B" "$w/t" --runpath '$ORIGIN/lib' --stubs "$w/dist/lib" -o "$w/dist/t" 2>&1); then
  run_case "g++ libtorch (CUDA) bundled" "$w/t" "$w/dist"
else echo "FAIL g++ libtorch (build or bundle)"; echo "$out" | grep -v warning | head -20; fail=1; fi

# nfcxx: the link drops what the program does not reference (it refuses -Wl,--no-as-needed, which eccp would put
# before every input), so libtorch_cuda and libc10_cuda are added to the bundle with --bundle-add. The normal build
# keeps them with -Wl,--push-state,--no-as-needed, which then applies to every library of the link.
be=${NFCXX_BACKEND:-gcc}
w=$tmp/nfcxx; mkdir -p "$w/dist/lib"
if [ -x "${EDG_BUILD:-build/edg}/bin/eccp" ]; then
  if out=$(NFCXX_BACKEND=$be ./nfcxx -std=$std -c $d/torch.cpp "${inc[@]}" -o "$w/t.o" 2>&1) &&
     out=$(NFCXX_BACKEND=$be ./nfcxx "$w/t.o" -Wl,--push-state,--no-as-needed -L"$L" -ltorch -ltorch_cuda -ltorch_cpu -lc10_cuda \
             -lc10 -Wl,-rpath,"$L" -o "$w/t" 2>&1) &&
     out=$(NFCXX_BACKEND=$be ./nfcxx --bundle-libs --bundle-add=libtorch_cuda.so,libc10_cuda.so --bundle-stubs="$w/dist/lib" \
             --bundle-runpath='$ORIGIN/lib' "$w/t.o" -L"$L" -ltorch -ltorch_cpu -lc10 -o "$w/dist/t" 2>&1); then
    run_case "nfcxx $be libtorch (CUDA) bundled" "$w/t" "$w/dist"
  else echo "FAIL nfcxx $be libtorch (build or bundle)"; echo "$out" | grep -E 'error|FAIL|nfcbundle' | head -20; fail=1; fi
else
  echo "skip nfcxx (EDG not built: scripts/setup-edg.sh)"
fi
exit $fail
