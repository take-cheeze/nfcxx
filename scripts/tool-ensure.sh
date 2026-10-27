# Sourced by the wrappers of the repo's C++ tools (scripts/weak-symbols, scripts/qbe-prep): tool_ensure NAME builds
# build/NAME from tools/NAME (its build.ninja) when it is missing. Compiles run in parallel (one back end per object),
# so the build is serialized by a lock directory, as the driver's ensure_tool does: the first run builds, the others
# wait for the binary.
tool_ensure() {
  local name=$1 root; root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
  local exe=$root/build/$name lock=$root/build/$name.lock waited=0 rc
  [ -x "$exe" ] && return 0
  mkdir -p "$root/build"
  until [ -x "$exe" ]; do
    if mkdir "$lock" 2>/dev/null; then
      rc=0; [ -x "$exe" ] || ninja -C "$root/tools/$name" >&2 || rc=$?
      rmdir "$lock"
      return $rc
    fi
    sleep 0.2; waited=$((waited + 1))
    [ "$waited" -lt 3000 ] || { echo "$name: $lock is stuck (remove it if no build is running)" >&2; return 1; }
  done
}
