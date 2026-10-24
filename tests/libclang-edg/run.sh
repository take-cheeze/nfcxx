#!/usr/bin/env bash
# libclang-edg: the EDG-backed libclang subset (lib/libclang-edg) against the system libclang, on the same walker
# (walk.c) and the same sources (cases/). The outputs must match except for the differences in known/, which are
# the documented gaps (docs/notes/libclang-edg.md): parameters of declarations without a body, an alias-declaration
# reported as a typedef, and a reopened namespace.
# Needs: scripts/setup-libclang-edg.sh (the front end), a C compiler, and a libclang.so for the reference
# (LIBCLANG_ORACLE, or /usr/lib/llvm-*/lib/libclang.so.* ; without one only the EDG side runs and is checked
# against expected/).
set -euo pipefail
root=$(cd "$(dirname "$0")/../.." && pwd)
cd "$root"
work=$root/build/libclang-edg/test
mkdir -p "$work"

[ -x build/libclang-edg/cmake/bin/cpfe ] || scripts/setup-libclang-edg.sh
scripts/build-libclang-edg.sh >/dev/null
cc=${CC:-cc}

oracle=${LIBCLANG_ORACLE:-}
if [ -z "$oracle" ]; then
  # the C library only: libclang-cpp exports C++ symbols, not the C API
  oracle=$(ls /usr/lib/llvm-*/lib/libclang.so.* /usr/lib/llvm-*/lib/libclang-*.so.* /usr/lib/x86_64-linux-gnu/libclang-*.so.* 2>/dev/null |
    grep -E '/libclang(\.so\.|-[0-9.]+\.so\.)[0-9.]+$' | sort -V | tail -1 || true)
fi

"$cc" -std=c99 -Wall -Werror -I lib/libclang-edg/include tests/libclang-edg/walk.c \
  -o "$work/walk-edg" -L build/libclang-edg -l:libclang-edg.so -Wl,-rpath,"$root/build/libclang-edg"
if [ -n "$oracle" ]; then
  "$cc" -std=c99 -Wall -Werror -I lib/libclang-edg/include tests/libclang-edg/walk.c \
    -o "$work/walk-ref" "$oracle" -Wl,-rpath,"$(dirname "$(readlink -f "$oracle")")"
  echo "reference: $oracle"
else
  echo "reference: none found (set LIBCLANG_ORACLE); checking the EDG output against expected/ only"
fi

python_ok=""
probe='import os, sys
if os.environ.get("LIBCLANG_EDG_PYTHON"): sys.path.insert(0, os.environ["LIBCLANG_EDG_PYTHON"])
from clang import cindex'
if [ -n "$oracle" ] && python3 -c "$probe" 2>/dev/null; then
  python_ok=1
else
  echo "clang.cindex: not importable (install the libclang Python binding, or set LIBCLANG_EDG_PYTHON); skipped"
fi

status=0
# The change lines of a unified diff (no headers, no hunks): what the EDG side does differently.
changes() { grep -E '^[-+][A-Za-z]' "$1" | LC_ALL=C sort; }
for src in tests/libclang-edg/cases/*.cpp; do
  name=$(basename "$src" .cpp)
  "$work/walk-edg" "$src" -std=c++17 > "$work/$name.edg" || { echo "FAIL $name: walk-edg exited non-zero"; status=1; continue; }
  if [ -n "$oracle" ]; then
    "$work/walk-ref" "$src" -std=c++17 > "$work/$name.ref"
    diff -u "$work/$name.ref" "$work/$name.edg" > "$work/$name.diff" || true
    # Only the differences listed in known/ are accepted: anything else is a regression (or a new gap to list).
    if diff <(changes "$work/$name.diff") "tests/libclang-edg/known/$name.txt" > "$work/$name.known.diff"; then
      echo "ok   $name ($(wc -l < "$work/$name.edg") declarations; $(wc -l < "tests/libclang-edg/known/$name.txt") known differences)"
    else
      echo "FAIL $name: differences not in known/ (see $work/$name.diff)"; status=1
    fi
    # The same walk through the Python binding (clang.cindex), against the same reference and the same known list.
    if [ -n "${python_ok:-}" ]; then
      python3 tests/libclang-edg/cindex_walk.py build/libclang-edg/libclang-edg.so "$src" -std=c++17 > "$work/$name.py.edg"
      python3 tests/libclang-edg/cindex_walk.py "$oracle" "$src" -std=c++17 > "$work/$name.py.ref"
      diff -u "$work/$name.py.ref" "$work/$name.py.edg" > "$work/$name.py.diff" || true
      if diff <(changes "$work/$name.py.diff") "tests/libclang-edg/known/$name.txt" > "$work/$name.py.known.diff"; then
        echo "ok   $name through clang.cindex"
      else
        echo "FAIL $name through clang.cindex: differences not in known/ (see $work/$name.py.diff)"; status=1
      fi
    fi
  fi
  # The front end inside the library (when it was built in): the same records through the runner process
  # (LIBCLANG_EDG_RUNNER), three parses in one process, and a parse after one that failed (a missing file, EDG's
  # catastrophic error) give the same walk.
  if [ -f build/libclang-edg/edg_args.h ]; then
    before=$status
    LIBCLANG_EDG_RUNNER=$root/scripts/libclang-cursors "$work/walk-edg" "$src" -std=c++17 > "$work/$name.proc" &&
      cmp -s "$work/$name.edg" "$work/$name.proc" || { echo "FAIL $name: in-process and runner walks differ"; status=1; }
    WALK_REPEAT=3 "$work/walk-edg" "$src" -std=c++17 > "$work/$name.rep" &&
      cmp -s <(cat "$work/$name.edg" "$work/$name.edg" "$work/$name.edg") "$work/$name.rep" ||
      { echo "FAIL $name: repeated in-process parses differ"; status=1; }
    WALK_FIRST=$work/no-such-file.cpp "$work/walk-edg" "$src" -std=c++17 > "$work/$name.after" 2>/dev/null &&
      cmp -s "$work/$name.edg" "$work/$name.after" || { echo "FAIL $name: a parse after a failed one differs"; status=1; }
    [ $status != $before ] || echo "ok   $name in-process (= runner; repeated; after a failure)"
  fi
done
exit $status
