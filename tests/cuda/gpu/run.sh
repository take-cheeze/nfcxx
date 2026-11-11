#!/usr/bin/env bash
# cuBLAS and cuDNN on a GPU (blas_dnn.c: an SGEMM and a convolution checked against CPU references, and driver API
# calls), linked with -lcuda so the driver calls go through libcudart (docs/notes/cuda-driver.md). By hand, not in CI:
# it needs a GPU. For gcc (the reference; it keeps libcuda), nfcc (gcc backend) and nfcxx (both backends):
#   - the program runs on the GPU and, except for gcc, does not need libcuda.so.1;
#   - bundled (--bundle-libs --bundle-stubs, with cuDNN's dlopen'ed libraries and libcublasLt as files in dist/lib) it
#     runs in a sandbox (bwrap) without the toolkit, the system's and CUDNN_LIB's cuDNN, cuBLAS, cudart or libstdc++:
#     only glibc, libgcc_s and the GPU driver;
#   - with the driver hidden (bwrap) the nfcc and nfcxx builds start and report cuInit CUDA_ERROR_NO_DEVICE, where the
#     gcc build cannot start.
# libcublasLt is excluded from the bundle and shipped as a file: cuDNN dlopens it by name and looks up its functions
# in that handle, which a stub (empty) cannot answer (docs/notes/bundle.md, "Plugins and stubs").
#   CUDA_HOME (default /usr/local/cuda; CUDA 12.5 or later), CUDNN_INCLUDE and CUDNN_LIB (default: the system's)
cd "$(dirname "$0")/../../.."
cuda=${CUDA_HOME:-/usr/local/cuda}
d=tests/cuda/gpu
ma=$(gcc -print-multiarch 2>/dev/null)
dninc=${CUDNN_INCLUDE:-/usr/include/$ma}; dnlib=${CUDNN_LIB:-/usr/lib/$ma}
if ! command -v nvidia-smi >/dev/null || ! nvidia-smi >/dev/null 2>&1; then echo "SKIP: gpu: no GPU (nvidia-smi)"; exit 0; fi
if [ ! -f "$cuda/include/cublas_v2.h" ] || [ ! -f "$dninc/cudnn.h" ] || [ ! -e "$dnlib/libcudnn.so" ]; then
  echo "SKIP: gpu: needs cuBLAS (CUDA_HOME) and cuDNN (CUDNN_INCLUDE, CUDNN_LIB)"; exit 0
fi
fail=0; tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
ok()  { echo "ok   $1"; }
bad() { echo "FAIL $1"; [ -z "${2:-}" ] || head -20 <<<"$2"; fail=1; }
cp $d/blas_dnn.c "$tmp/blas_dnn.cpp"
inc=(-I"$cuda/include" -I"$dninc")
[ -d "$cuda/include/cccl" ] && inc+=(-I"$cuda/include/cccl")   # the PyPI toolkit (scripts/fetch-cuda-libs.sh)
libs=(-L"$cuda/lib64" -L"$dnlib" -lcublas -lcudnn -lcudart -lcuda -lm)
# The output of a run on the GPU: the device, both results within tolerance, the context the runtime made.
good() { grep -q '^cublas .* ok$' <<<"$1" && grep -q '^cudnn .* ok$' <<<"$1" && grep -q '^ctx primary' <<<"$1"; }
needs_libcuda() { readelf -dW "$1" | grep -q 'NEEDED.*libcuda\.so'; }
sandbox=0; command -v bwrap >/dev/null && bwrap --dev-bind / / true 2>/dev/null && sandbox=1
# The sandbox replaces /usr/local and the toolkit with empty directories and binds these files to /dev/null.
hide=(--tmpfs /usr/local)
case $(readlink -f "$cuda") in /usr/local/*) ;; *) hide+=(--tmpfs "$(readlink -f "$cuda")") ;; esac
for f in "$dnlib"/libcudnn* "$dnlib"/libcublas* "$dnlib"/libcudart* /usr/lib/$ma/libcudnn* /usr/lib/$ma/libcublas* \
         /usr/lib/$ma/libcudart* /usr/lib/$ma/libstdc++.so*; do
  [ -e "$f" ] && hide+=(--ro-bind /dev/null "$f")
done
nodrv=()
for f in /usr/lib/$ma/libcuda.so* /usr/lib/$ma/libnvidia*.so* "$cuda"/lib64/stubs/libcuda.so*; do
  [ -e "$f" ] && nodrv+=(--ro-bind /dev/null "$f")
done

build() {  # build NAME DRIVER BACKEND OUT [OPTIONS...]
  local name=$1 drv=$2 be=$3 out=$4 src=$d/blas_dnn.c; shift 4
  [ "$drv" = nfcxx ] && src=$tmp/blas_dnn.cpp
  case $drv in
    gcc) gcc "${inc[@]}" "$src" -L"$cuda/lib64/stubs" "${libs[@]}" -Wl,-rpath,"$cuda/lib64" -o "$out" ;;
    *) NFCXX_BACKEND=$be CUDA_HOME=$cuda ./$drv "$@" "${inc[@]}" "$src" "${libs[@]}" -o "$out" ;;
  esac
}
for c in "gcc gcc" "nfcc gcc" "nfcxx gcc" "nfcxx qbe"; do
  set -- $c; drv=$1 be=$2; name="$drv $be"; [ $drv = gcc ] && name=gcc
  exe=$tmp/$drv-$be
  if ! out=$(build "$name" $drv $be "$exe" 2>&1); then bad "$name (build)" "$(grep -iv warning <<<"$out")"; continue; fi
  got=$("$exe" 2>&1)
  if ! good "$got"; then bad "$name (run)" "$got"; continue; fi
  if [ $drv = gcc ]; then needs_libcuda "$exe" || bad "gcc: expected to need libcuda.so.1"
  elif needs_libcuda "$exe"; then bad "$name: needs libcuda.so.1"; continue; fi
  ok "$name on the GPU: $(grep -E '^(cublas|cudnn)' <<<"$got" | sed 's/ max err.*//' | tr '\n' ';' | sed 's/;$//')"
  if [ $sandbox = 1 ]; then
    got=$(bwrap --dev-bind / / "${nodrv[@]}" "$exe" 2>&1)
    if [ $drv = gcc ]; then
      case $got in *libcuda.so.1*) ok "gcc without the driver: cannot start" ;; *) bad "gcc without the driver" "$got" ;; esac
    else
      [ "$got" = "cuInit CUDA_ERROR_NO_DEVICE" ] && ok "$name without the driver: $got" || bad "$name without the driver" "$got"
    fi
  fi
  [ $drv = gcc ] && continue
  dist=$tmp/dist-$drv-$be; mkdir -p "$dist/lib"
  if ! out=$(build "$name" $drv $be "$dist/t" --bundle-libs --bundle-exclude=libcublasLt.so.13,libcublasLt.so.12 \
               --bundle-stubs="$dist/lib" --bundle-runpath='$ORIGIN/lib' 2>&1); then
    bad "$name bundled (build)" "$(grep -iv warning <<<"$out")"; continue
  fi
  # Every name of each: cuDNN dlopens libcudnn_graph.so.9.27.0 before libcudnn_graph.so.9, and the first name found
  # anywhere wins (a system cuDNN of the same version for another CUDA major would ask for another libcublasLt).
  cp -a "$dnlib"/libcudnn_*.so.9* "$dist/lib/" 2>/dev/null
  cp -L "$cuda"/lib64/libcublasLt.so.1[23] "$dist/lib/" 2>/dev/null
  n=$(readelf -dW "$dist/t" | grep NEEDED | grep -oE 'lib(cuda|cudart|cublas|cudnn)\.so[.0-9]*' | grep -v '^$')
  # The NEEDED entries left are glibc's and the stubs'; the stubs are in dist/lib.
  for x in $n; do [ -e "$dist/lib/$x" ] || { bad "$name bundled: needs $x"; continue 2; }; done
  if [ $sandbox = 1 ]; then
    got=$(bwrap --dev-bind / / "${hide[@]}" "$dist/t" 2>&1)
    where="in the sandbox"
  else got=$("$dist/t" 2>&1); where="(no bwrap: not sandboxed)"; fi
  good "$got" && ok "$name bundled, $where ($(du -sh "$dist/t" | cut -f1))" || bad "$name bundled $where" "$got"
done
[ $sandbox = 1 ] || echo "skip the runs without the driver (no bwrap)"
exit $fail
