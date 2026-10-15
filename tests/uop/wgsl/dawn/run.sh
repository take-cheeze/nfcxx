#!/usr/bin/env bash
# The uop WGSL cases (tests/uop/wgsl/run.sh's runner in Chrome) on Google's Dawn instead, native (Metal on macOS).
# Optional: not in CI, and tests/uop/wgsl/run.sh stays the default. Needs node and a Dawn build from a shallow checkout:
#   git clone --depth 1 https://dawn.googlesource.com/dawn $DAWN_SRC
#   python3 $DAWN_SRC/tools/fetch_dawn_dependencies.py -s -t      (run inside $DAWN_SRC)
#   cmake -S $DAWN_SRC -B $DAWN_BUILD -G Ninja -DCMAKE_BUILD_TYPE=Release -DDAWN_FETCH_DEPENDENCIES=ON \
#     -DDAWN_BUILD_SAMPLES=OFF -DDAWN_BUILD_TESTS=OFF -DDAWN_ENABLE_METAL=ON -DDAWN_ENABLE_VULKAN=OFF \
#     -DDAWN_ENABLE_D3D11=OFF -DDAWN_ENABLE_D3D12=OFF -DDAWN_ENABLE_DESKTOP_GL=OFF -DDAWN_ENABLE_OPENGLES=OFF \
#     -DDAWN_USE_BUILT_DXC=OFF -DTINT_BUILD_TESTS=OFF -DTINT_BUILD_CMD_TOOLS=OFF
#   ninja -C $DAWN_BUILD dawn_native dawn_proc                    (about 2.5 minutes on a 10-core Apple Silicon Mac)
set -euo pipefail
cd "$(dirname "$0")/../../../.."
src=${DAWN_SRC:?set DAWN_SRC to the Dawn checkout}
build=${DAWN_BUILD:?set DAWN_BUILD to the Dawn build directory}
b=$(mktemp -d); trap 'rm -rf "$b"' EXIT

# The cases, as tests/uop/wgsl/run.sh writes them for the browser.
L=$(sed -n 's/^L=(\(.*\))$/\1/p' tests/uop/wgsl/run.sh)
c++ -std=c++17 -O1 -Ilib/uop $L tests/uop/test_wgsl.cpp -o "$b/test_wgsl"
"$b/test_wgsl" "$b" >/dev/null

# The runner links every archive of the build once and again (the archives reference each other); the frameworks are Metal's.
libs=$(find "$build" -name '*.a' ! -name 'libwebgpu_dawn.a' | sort | tr '\n' ' ')
clang++ -std=c++20 -O1 -w -I "$src/src/include" -I "$build/gen/include" tests/uop/wgsl/dawn/run_dawn.cc -o "$b/run_dawn" \
  $libs $libs -framework Metal -framework Foundation -framework IOKit -framework IOSurface -framework QuartzCore \
  -framework CoreGraphics -framework Cocoa -lc++

fail=0
for c in case_reduce case_elementwise; do
  node tests/uop/wgsl/dawn/to_spec.js "$b/$c.js" "$b/$c" >/dev/null
  "$b/run_dawn" "$b/$c.wgsl" "$b/$c.spec" | sed "s/^/uop\/wgsl $c on Dawn: /" || fail=1
done
exit $fail
