#!/bin/bash
# Differential test: scripts/fetch-cuda-libs.rb against scripts/fetch-cuda-libs.sh, with pip, unzip and curl stubbed (see
# ../fetch-build/common.sh). Nothing is downloaded.
here=$(cd "$(dirname "$0")" && pwd -P)
RBM_NAME=fetch-cuda-libs
. "$here/../fetch-build/common.sh"

# the wheels' tree (what unzip extracts); the without-ptxas variant leaves bin/ptxas out
fixtures() {
  local t=$SB/fix/tree/nvidia
  mkdir -p "$t/cuda_runtime/include" "$t/cuda_runtime/lib" "$t/cuda_nvcc/include/crt" "$t/cuda_nvcc/bin" \
           "$t/cuda_cccl/include/nv" "$t/cublas/include" "$t/cublas/lib" "$t/cudnn/include" "$t/cudnn/lib"
  echo cudart > "$t/cuda_runtime/include/cuda_runtime.h"
  echo host > "$t/cuda_nvcc/include/crt/host_config.h"
  echo target > "$t/cuda_cccl/include/nv/target"
  echo cublas > "$t/cublas/include/cublas_v2.h"
  echo cudnn > "$t/cudnn/include/cudnn.h"
  echo rt > "$t/cuda_runtime/lib/libcudart.so.12"
  echo cb > "$t/cublas/lib/libcublas.so.12"
  echo cdnn > "$t/cudnn/lib/libcudnn.so.9"
  [ -n "$NO_PTXAS" ] || echo ptxas > "$t/cuda_nvcc/bin/ptxas"
}
# the hooks: pip creates the wheel files (or fails with FAKE_PIP_FAIL), unzip copies the fixture tree
setup() {
  fixtures
  mkdir -p "$SB/hooks"
  cat > "$SB/hooks/python3" <<'H'
#!/bin/bash
[ -z "$FAKE_PIP_FAIL" ] || exit 1
dir= prev=
for a; do
  [ "$prev" = -d ] && dir=$a
  case $a in *==*) : > "$dir/${a%%==*}.whl" ;; esac
  prev=$a
done
H
  cat > "$SB/hooks/unzip" <<'H'
#!/bin/bash
d=${*: -1}
mkdir -p "$d" && cp -r "$NFCXX_STUB_FIX/tree/." "$d/"
H
  chmod +x "$SB/hooks/python3" "$SB/hooks/unzip"
}
# the pip hook needs the -d directory, which the script creates first; the stub runs the hook in place of python3
setup_fail() { setup; }
setup_noptxas() { NO_PTXAS=1 setup; }

rbm_case default-dir setup "HOME=$SB/home"
rbm_case explicit-dir setup "" "$SB/work/cuda"
rbm_case explicit-dir-slash setup "" "$SB/work/cuda/"
rbm_case env-cuda-libs setup "CUDA_LIBS_DIR=$SB/work/libs"
rbm_case env-xdg setup "XDG_CACHE_HOME=$SB/work/xdg"
rbm_case env-empty-dir setup "CUDA_LIBS_DIR=" 
rbm_case arg-beats-env setup "CUDA_LIBS_DIR=$SB/work/libs" "$SB/work/arg"
rbm_case rerun setup "" "$SB/work/cuda"
rbm_case pip-fails setup "FAKE_PIP_FAIL=1" "$SB/work/cuda"
rbm_case no-ptxas setup_noptxas "" "$SB/work/cuda"
rbm_summary
