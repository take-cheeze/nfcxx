#!/usr/bin/env bash
# Builds build/onnxsim/libnfconnxsim.so: onnxsim's C++ reverse-mode differentiator (graph_grad.cpp, qat_graph_builder.cpp) with the onnx
# it pins and a C ABI shim (scripts/onnxsim/nfc_onnxsim.cpp), for lib/uop/nfcuop_onnxgrad.cpp to dlopen (docs/notes/uop-autodiff.md).
# Needs cmake, a C++17 compiler, git, and the protobuf headers (apt: cmake protobuf-compiler libprotobuf-dev), ~10 min.
# The source is onnxsim master at $onnxsim_rev, with the onnx submodule at the commit that master pins, $onnx_rev. Both are fetched
# by commit hash: git checks every object against its hash, so the commit is the pin (no tarball to verify). Bump both together.
#   JOBS=<n>   build parallelism (default: all cores)
# Prints the path of the library; exits 0 at once when it is already built from these commits.
set -e
cd "$(dirname "$0")/.."
onnxsim_rev=c6913888924feae8baeead6b0635239f23849b48
onnx_rev=281e5e6accfd6113fd57d819ce47f32a937bb106
out=build/onnxsim
mkdir -p $out
stamp=$out/built-$onnxsim_rev-$onnx_rev-$(cat scripts/onnxsim/nfc_onnxsim.cpp | sha256sum | cut -c1-12)
if [ -f "$stamp" ] && [ -f $out/libnfconnxsim.so ]; then echo "$PWD/$out/libnfconnxsim.so"; exit 0; fi
# fetch <repo> <commit> <dir>: the commit checked out at <dir>, exactly
fetch() {
  rm -rf "$3"; mkdir -p "$3"
  git -C "$3" init -q
  git -C "$3" fetch -q --depth 1 "$1" "$2" >&2
  git -C "$3" checkout -q FETCH_HEAD >&2
  [ "$(git -C "$3" rev-parse HEAD)" = "$2" ] || { echo "fetch $1: got $(git -C "$3" rev-parse HEAD), wanted $2" >&2; exit 1; }
}
fetch https://github.com/onnxsim/onnxsim $onnxsim_rev $out/src
fetch https://github.com/onnxsim/onnx $onnx_rev $out/src/third_party/onnx
rm -rf $out/src/.git $out/src/third_party/onnx/.git
cmake -S scripts/onnxsim -B $out/b -DONNXSIM_SRC="$PWD/$out/src" -DCMAKE_BUILD_TYPE=Release >&2
cmake --build $out/b --target nfconnxsim -j "${JOBS:-$(nproc)}" >&2
cp $out/b/libnfconnxsim.so $out/libnfconnxsim.so
rm -f $out/built-*; touch "$stamp"
echo "$PWD/$out/libnfconnxsim.so"
