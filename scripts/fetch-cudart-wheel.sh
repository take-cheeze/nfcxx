#!/usr/bin/env bash
# Fetches the CUDA runtime and CCCL from PyPI (the nvidia-cuda-runtime and nvidia-cuda-cccl wheels) and assembles a
# CUDA_HOME-shaped directory (include/, lib64/) that nfcxx uses in place of the toolkit's, so the build needs no
# toolkit libraries. Usage: scripts/fetch-cudart-wheel.sh [MAJOR.MINOR]
#   Prints "cuda-home: DIR"; use it as NFCXX_CUDA_WHEEL (or CUDA_HOME). Default MAJOR.MINOR is the toolkit's in CUDA_HOME.
#   For each package the release with that MAJOR.MINOR is picked, else the newest of the same major. sha256 is checked
#   against PyPI's JSON before anything is unpacked.
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
out=${CUDART_WHEEL_DIR:-${XDG_CACHE_HOME:-$HOME/.cache}/nfcxx/cudart-wheel}
cuda=${CUDA_HOME:-/usr/local/cuda}
want=${1:-}
if [ -z "$want" ] && [ -f "$cuda/version.json" ]; then
  want=$(sed -n 's/.*"cuda_cudart" *: *{[^}]*"version" *: *"\([0-9]*\.[0-9]*\).*/\1/p' "$cuda/version.json" | head -1)
fi
json=$(mktemp); trap 'rm -f "$json"' EXIT

# fetch PKG: downloads and unpacks the chosen wheel into $out/PKG/VERSION; prints that directory.
fetch() {
  local pkg=$1
  curl -sSfL "https://pypi.org/pypi/$pkg/json" -o "$json"
  local pick
  pick=$(python3 - "$json" "$want" <<'PY'
import json, sys
d = json.load(open(sys.argv[1])); want = sys.argv[2]
rel = []
for v, files in d["releases"].items():
    for f in files:
        n = f["filename"]
        if n.endswith("manylinux_2_17_x86_64.manylinux2014_x86_64.whl") or n.endswith("manylinux2014_x86_64.manylinux_2_17_x86_64.whl"):
            rel.append((v, n, f["url"], f["digests"]["sha256"]))
if not rel:
    sys.exit("no x86_64 wheel on PyPI for this package")
key = lambda v: tuple(int(x) for x in v.split(".") if x.isdigit())
rel.sort(key=lambda r: key(r[0]))
exact = [r for r in rel if want and r[0].startswith(want + ".")]
major = (want or rel[-1][0]).split(".")[0]
pick = exact[-1] if exact else [r for r in rel if r[0].split(".")[0] == major][-1]
print("\t".join(pick))
PY
)
  local ver name url sha
  IFS=$'\t' read -r ver name url sha <<< "$pick"
  mkdir -p "$out/$pkg"
  local whl="$out/$pkg/$name"
  curl -sSfL "$url" -o "$whl"
  [ "$(sha256sum "$whl" | cut -d' ' -f1)" = "$sha" ] || { echo "fetch-cudart-wheel: sha256 mismatch for $name" >&2; rm -f "$whl"; exit 1; }
  local dest="$out/$pkg/$ver"
  rm -rf "$dest"; mkdir -p "$dest"
  python3 -c "import zipfile,sys; zipfile.ZipFile(sys.argv[1]).extractall(sys.argv[2])" "$whl" "$dest"
  echo "$dest"
}

rt=$(fetch nvidia-cuda-runtime)
cc=$(fetch nvidia-cuda-cccl)
crt=$(fetch nvidia-cuda-crt)
rt_inc=$(find "$rt" -type d -name include -path '*nvidia*' | head -1)
rt_lib=$(find "$rt" -type d -name lib -path '*nvidia*' | head -1)
cc_inc=$(find "$cc" -type d -name include -path '*nvidia*' | head -1)
[ -n "$rt_inc" ] && [ -n "$rt_lib" ] && [ -n "$cc_inc" ] || { echo "fetch-cudart-wheel: include/ or lib/ missing in a wheel" >&2; exit 1; }

# The CUDA_HOME shape: include/ (runtime headers, with CCCL's cccl/ beside them) and lib64/ (libcudart.so and its .so.N).
home="$out/cuda-home"
rm -rf "$home"; mkdir -p "$home/lib64"
cp -a "$rt_inc" "$home/include"
# crt/ (host_config.h and the device-side headers) ships in its own package.
crt_inc=$(find "$crt" -type d -name include -path '*nvidia*' | head -1)
if [ -n "$crt_inc" ]; then cp -a "$crt_inc"/. "$home/include/"; fi
[ -e "$home/include/cccl" ] || cp -a "$cc_inc/cccl" "$home/include/cccl" 2>/dev/null || cp -a "$cc_inc" "$home/include/cccl"
# nv/ (the target macros the runtime headers include) is beside cccl/ in the CCCL wheel.
[ -d "$cc_inc/nv" ] && cp -a "$cc_inc/nv" "$home/include/nv"
for f in "$rt_lib"/libcudart.so*; do cp -a "$f" "$home/lib64/"; done
so=$(ls "$home/lib64" | grep -E '^libcudart\.so\.[0-9]+$' | head -1)
[ -n "$so" ] && ln -sf "$so" "$home/lib64/libcudart.so"
echo "cuda-home: $home"
echo "runtime: $(basename "$rt")"
echo "cccl: $(basename "$cc")"
echo "crt: $(basename "$crt")"
