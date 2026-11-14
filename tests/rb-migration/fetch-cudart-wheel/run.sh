#!/bin/bash
# Differential test: scripts/fetch-cudart-wheel.rb against scripts/fetch-cudart-wheel.sh (see ../fetch-build/common.sh). PyPI
# (the JSON and the wheels) is a set of fixtures: small zip wheels of the same layout as the real ones, served by the curl
# stub. Nothing is downloaded.
#
# Not in the cases: the paths where the bash original goes on after a failed download or a PyPI JSON with no x86_64 wheel
# (fetch runs in $(...), where bash ignores errexit, so it reaches python3 with an empty pick and prints a Python traceback).
# The port stops there with one line, so those paths differ in their stderr and their logs; the .sh stays for them.
here=$(cd "$(dirname "$0")" && pwd -P)
RBM_NAME=fetch-cudart-wheel
. "$here/../fetch-build/common.sh"

# the wheels: the same layout as the real ones (nvidia/<package>/include, lib); the broken runtime has no include directory
FIX=$RBM_OUT/fixtures
mkdir -p "$FIX/src" "$FIX/wheels" "$FIX/json-good" "$FIX/json-badsha" "$FIX/json-noinc"
wheel() {  # wheel FILE PACKAGE-DIR: a zip of the files of $FIX/src/<tree>
  (cd "$FIX/src/$2" && zip -qry "$FIX/wheels/$1" .)
}
for v in 12.8.90 12.9.79 13.0.1; do
  mkdir -p "$FIX/src/rt-$v/nvidia/cuda_runtime/include" "$FIX/src/rt-$v/nvidia/cuda_runtime/lib"
  echo "cuda_runtime $v" > "$FIX/src/rt-$v/nvidia/cuda_runtime/include/cuda_runtime.h"
  echo "libcudart $v" > "$FIX/src/rt-$v/nvidia/cuda_runtime/lib/libcudart.so.12"
  (cd "$FIX/src/rt-$v/nvidia/cuda_runtime/lib" && ln -sf libcudart.so.12 libcudart.so)
  wheel "nvidia_cuda_runtime_cu12-$v-py3-none-manylinux_2_17_x86_64.manylinux2014_x86_64.whl" "rt-$v"
  mkdir -p "$FIX/src/cc-$v/nvidia/cuda_cccl/include/cccl" "$FIX/src/cc-$v/nvidia/cuda_cccl/include/nv"
  echo "thrust $v" > "$FIX/src/cc-$v/nvidia/cuda_cccl/include/cccl/thrust.h"
  echo "target $v" > "$FIX/src/cc-$v/nvidia/cuda_cccl/include/nv/target"
  wheel "nvidia_cuda_cccl_cu12-$v-py3-none-manylinux_2_17_x86_64.manylinux2014_x86_64.whl" "cc-$v"
  mkdir -p "$FIX/src/crt-$v/nvidia/cuda_crt/include/crt"
  echo "host_config $v" > "$FIX/src/crt-$v/nvidia/cuda_crt/include/crt/host_config.h"
  wheel "nvidia_cuda_crt_cu12-$v-py3-none-manylinux_2_17_x86_64.manylinux2014_x86_64.whl" "crt-$v"
done
# the runtime without its include directory
mkdir -p "$FIX/src/rt-noinc/nvidia/cuda_runtime/lib"
echo "libcudart" > "$FIX/src/rt-noinc/nvidia/cuda_runtime/lib/libcudart.so.12"
(cd "$FIX/src/rt-noinc" && zip -qry "$FIX/wheels/rt-noinc-12.9.79.whl" .)

# the PyPI JSON of each package: its releases, one wheel each, and an aarch64 wheel the script must not pick
python3 - "$FIX" <<'PY'
import hashlib, json, os, sys
fix = sys.argv[1]
def sha(path):
    return hashlib.sha256(open(path, "rb").read()).hexdigest()
pkgs = {"nvidia-cuda-runtime": ("nvidia_cuda_runtime_cu12", "rt", ["12.8.90", "12.9.79", "13.0.1"]),
        "nvidia-cuda-cccl": ("nvidia_cuda_cccl_cu12", "cc", ["12.8.90", "12.9.79", "13.0.1"]),
        "nvidia-cuda-crt": ("nvidia_cuda_crt_cu12", "crt", ["12.8.90", "12.9.79", "13.0.1"])}
for variant in ["good", "badsha", "noinc"]:
    for pkg, (mod, tag, versions) in pkgs.items():
        releases = {}
        for v in versions:
            name = f"{mod}-{v}-py3-none-manylinux_2_17_x86_64.manylinux2014_x86_64.whl"
            path = os.path.join(fix, "wheels", name)
            url = f"https://files.test/{name}"
            if tag == "rt" and v == "12.9.79" and variant == "noinc":
                path = os.path.join(fix, "wheels", "rt-noinc-12.9.79.whl")
                url = "https://files.test/rt-noinc-12.9.79.whl"
            digest = sha(path) if variant != "badsha" else "0" * 64
            releases[v] = [
                {"filename": f"{mod}-{v}-py3-none-manylinux_2_28_aarch64.whl", "url": "https://files.test/unused.whl",
                 "digests": {"sha256": "1" * 64}},
                {"filename": name, "url": url, "digests": {"sha256": digest}},
            ]
        out = os.path.join(fix, f"json-{variant}")
        with open(os.path.join(out, pkg + ".json"), "w") as f:
            json.dump({"releases": releases}, f)
PY

# the fixtures of a case: PyPI's JSON of the variant, and the wheels, served under their URLs
setup_variant() {
  local variant=$1 f key
  for f in "$FIX/json-$variant"/*.json; do
    key=$(printf '%s' "https://pypi.org/pypi/$(basename "$f" .json)/json" | sed 's#[^A-Za-z0-9._-]#_#g')
    cp "$f" "$SB/fix/urls/$key"
  done
  for f in "$FIX/wheels"/*.whl; do
    key=$(printf '%s' "https://files.test/$(basename "$f")" | sed 's#[^A-Za-z0-9._-]#_#g')
    cp "$f" "$SB/fix/urls/$key"
  done
  mkdir -p "$SB/fix/urls"
}
setup_good() { mkdir -p "$SB/fix/urls"; setup_variant good; }
setup_badsha() { mkdir -p "$SB/fix/urls"; setup_variant badsha; }
setup_noinc() { mkdir -p "$SB/fix/urls"; setup_variant noinc; }
# a CUDA_HOME whose version.json names cudart 12.8
setup_cuda_home() {
  setup_good
  mkdir -p "$SB/work/cuda"
  cat > "$SB/work/cuda/version.json" <<'J'
{
   "cuda" : {
      "name" : "CUDA SDK",
      "version" : "12.8.1"
   },
   "cuda_cudart" : { "name" : "CUDA Runtime (cudart)", "version" : "12.8.90" }
}
J
}

rbm_case latest setup_good "HOME=$SB/home"
rbm_case want-12.9 setup_good "" "12.9"
rbm_case want-12 setup_good "" "12"
rbm_case want-12.8 setup_good "" "12.8"
rbm_case empty-arg setup_good "" ""
rbm_case version-json setup_cuda_home "CUDA_HOME=$SB/work/cuda"
rbm_case arg-beats-version-json setup_cuda_home "CUDA_HOME=$SB/work/cuda" "12.9"
rbm_case no-version-json setup_good "CUDA_HOME=$SB/work/none"
rbm_case env-dir setup_good "CUDART_WHEEL_DIR=$SB/work/wheels"
rbm_case env-xdg setup_good "XDG_CACHE_HOME=$SB/work/xdg"
rbm_case sha-mismatch setup_badsha "" "12.9"
rbm_case no-include setup_noinc "" "12.9"
rbm_summary
