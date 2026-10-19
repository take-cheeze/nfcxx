#!/usr/bin/env bash
# Use EDG's actual harness and recorded expectations, inside its pinned Docker image.
set -euo pipefail
root=$(cd "$(dirname "$0")/../.." && pwd)
src=$root/3rd/edg
if [ ! -f "$src/dev_tools/bin/edg-docker-test" ]; then
  echo 'Initialize the pinned submodule: git submodule update --init 3rd/edg' >&2
  exit 1
fi
command -v docker >/dev/null
docker info >/dev/null
mkdir -p "$root/build/testsuite-snapshots"
lock=$root/build/testsuite-snapshots/edg.lock
mkdir "$lock" 2>/dev/null || { echo 'EDG wrapper is already running' >&2; exit 1; }
trap 'rmdir "$lock"' EXIT
export PATH="$src/dev_tools/bin:$PATH"
export PYTHONPATH="$src/dev_tools/pylibs${PYTHONPATH:+:$PYTHONPATH}"
cd "$src"
# Build the C-generating route and all its runtime/driver dependencies. The
# fork's cpfe-cp target currently fails to build; keep its baseline separate.
# Do not pipe this command: a build failure must prevent the test invocation.
if [ ! -f build/gcc/CMakeCache.txt ]; then
  edg-exec -- cmake --preset linux-gcc-debug
fi
edg-exec -- cmake --build build/gcc --target cpfe edg_prelink edg_decode edg_munch libedgrt.a
before=$(find tests/runs -maxdepth 1 -type d -name '20*' | sort | tail -1)
rc=0
dev_tools/bin/edg-docker-test --non-interactive \
  --timeout="${EDG_TEST_TIMEOUT:-120}" \
  --posture="@$root/tests/upstream/edg-c.json" "${1:-regressions}" || rc=$?
run=$(find tests/runs -maxdepth 1 -type d -name '20*' | sort | tail -1)
[ "$rc" = 0 ] || exit "$rc"
[ -n "$run" ] && [ "$run" != "$before" ] && [ -s "$run/edg_x86_64/executed.elist" ] || {
  echo 'EDG harness produced no new executed-test list' >&2; exit 1;
}
printf '%s\n' "$src/$run" > "$root/build/testsuite-snapshots/edg-last-run.txt"
# Upstream uses output pipelines; verify the emitted report as well as exit status.
if [ -s "$run/edg_x86_64/changes.elog" ]; then
  cat "$run/edg_x86_64/changes.elog" >&2
  echo "EDG unexpected changes: $src/$run" >&2
  exit 1
fi
echo "EDG recorded expectations match: $src/$run"
