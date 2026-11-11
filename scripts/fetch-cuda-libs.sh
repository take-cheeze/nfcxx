#!/usr/bin/env bash
# Fetches the CUDA libraries that the library-link tests need from PyPI (NVIDIA's wheels) and assembles a
# CUDA_HOME-shaped directory: include/ (cuda_runtime.h, the crt/ headers, cccl/ under include/cccl, cublas_v2.h,
# cudnn.h), lib64/ (libcudart, libcublas, libcudnn, with unversioned names) and bin/ptxas. Nothing is run on a GPU:
# the directory is for compiling and linking. Usage: scripts/fetch-cuda-libs.sh [DIR]   (default: $CUDA_LIBS_DIR or
# ~/.cache/nfcxx/cuda-libs). Prints "cuda-home: DIR"; use it as CUDA_HOME.
# Wheel versions are pinned, so the directory is the same from run to run. Each wheel is a zip; the files are
# copied out of it and the libraries get the unversioned symlinks that -lcublas, -lcudnn and -lcudart need.
set -euo pipefail
out=${1:-${CUDA_LIBS_DIR:-${XDG_CACHE_HOME:-$HOME/.cache}/nfcxx/cuda-libs}}
wheels=$out/wheels
pkgs=(nvidia-cuda-runtime-cu12==12.9.79 nvidia-cuda-cccl-cu12==12.9.27 nvidia-cuda-nvcc-cu12==12.9.86
      nvidia-cublas-cu12==12.9.2.10 nvidia-cudnn-cu12==9.27.0.42)
mkdir -p "$wheels"
python3 -m pip download --no-deps -q -d "$wheels" "${pkgs[@]}"
rm -rf "$out/x" "$out/include" "$out/lib64" "$out/bin"
for w in "$wheels"/*.whl; do unzip -oq "$w" -d "$out/x"; done
n=$out/x/nvidia
mkdir -p "$out/include/cccl" "$out/lib64" "$out/bin"
cp -r "$n/cuda_runtime/include/." "$out/include/"
cp -r "$n/cuda_nvcc/include/." "$out/include/"
cp -r "$n/cuda_cccl/include/." "$out/include/cccl/"
cp -r "$n/cublas/include/." "$out/include/"
cp -r "$n/cudnn/include/." "$out/include/"
cp "$n"/cuda_runtime/lib/*.so.* "$n"/cublas/lib/*.so.* "$n"/cudnn/lib/*.so.* "$out/lib64/"
cp "$n/cuda_nvcc/bin/ptxas" "$out/bin/"
chmod +x "$out/bin/ptxas"
(cd "$out/lib64" && for f in lib*.so.*; do ln -sf "$f" "${f%%.so.*}.so"; done)
rm -rf "$out/x"
for f in include/cuda_runtime.h include/crt/host_config.h include/cccl/nv/target include/cublas_v2.h include/cudnn.h \
         lib64/libcudart.so lib64/libcublas.so lib64/libcudnn.so bin/ptxas; do
  [ -e "$out/$f" ] || { echo "fetch-cuda-libs: $f missing from the wheels" >&2; exit 1; }
done
echo "cuda-home: $out"
