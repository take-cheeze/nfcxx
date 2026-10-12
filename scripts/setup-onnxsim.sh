#!/usr/bin/env bash
# Builds build/onnxsim/libnfconnxsim.so: onnxsim's C++ reverse-mode differentiator (graph_grad.cpp) with the onnx it bundles
# and a C ABI shim (scripts/onnxsim/nfc_onnxsim.cpp), for lib/uop/nfcuop_onnxgrad.cpp to dlopen (docs/notes/uop-autodiff.md).
# Needs cmake, a C++17 compiler, curl, protoc and the protobuf headers (apt: cmake protobuf-compiler libprotobuf-dev), ~10 min.
# The source is the PyPI sdist of onnxsim 0.8.1, pinned by SHA-256 (it unpacks onnx 1.23.0 under third_party/ as well).
#   ONNXSIM_SDIST=<file>   use this copy of the sdist instead of downloading it (the hash is still checked)
#   JOBS=<n>               build parallelism (default: all cores)
# Prints the path of the library; exits 0 at once when it is already built from this pinned source.
set -e
cd "$(dirname "$0")/.."
ver=0.8.1
sha=101c7b3d31e39c609cdfafddb4d3586572435f76f0e1a191d95d0a6797e1b0a4
url=https://files.pythonhosted.org/packages/7e/3c/cbfc805b3716cd7ce4238a0c6980b75227afb87cdccd22f34e986792f8e4/onnxsim-$ver.tar.gz
out=build/onnxsim
mkdir -p $out
stamp=$out/built-$sha
if [ -f "$stamp" ] && [ -f $out/libnfconnxsim.so ]; then echo "$PWD/$out/libnfconnxsim.so"; exit 0; fi
tgz=${ONNXSIM_SDIST:-$out/onnxsim-$ver.tar.gz}
if [ ! -f "$tgz" ]; then curl -fsSL -o "$tgz" "$url"; fi
echo "$sha  $tgz" | sha256sum -c - >&2
rm -rf $out/src; mkdir -p $out/src
tar xzf "$tgz" -C $out/src --strip-components=1
cmake -S scripts/onnxsim -B $out/b -DONNXSIM_SRC="$PWD/$out/src" -DCMAKE_BUILD_TYPE=Release >&2
cmake --build $out/b --target nfconnxsim -j "${JOBS:-$(nproc)}" >&2
cp $out/b/libnfconnxsim.so $out/libnfconnxsim.so
rm -f $out/built-*; touch "$stamp"
echo "$PWD/$out/libnfconnxsim.so"
