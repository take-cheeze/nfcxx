#!/bin/bash
# --trace=FILE with a relative file name writes the trace file in the directory the driver was started in. trace.sh made the
# name absolute with a shell function that no longer exists (host-sys.sh was removed), so the driver exited 127 before
# compiling. The name is now made absolute by scripts/host-sys.rb abs_path.
#   bash tests/driver-trace-path/run.sh
here=$(cd "$(dirname "$0")" && pwd -P); repo=$(cd "$here/../.." && pwd -P)
work=$(mktemp -d); trap 'rm -rf "$work"' EXIT
cd "$work" || exit 1
printf 'int main(){return 0;}\n' > m.cpp
"$repo/nfcxx" -c m.cpp -o m.o --trace=t.json >/dev/null 2>&1; st=$?
if [ "$st" = 0 ] && [ -s t.json ] && grep -q 'host C++ headers' t.json; then
  echo "driver-trace-path: 1 passed, 0 failed"; exit 0
fi
echo "driver-trace-path: 0 passed, 1 failed (status $st)"; exit 1
