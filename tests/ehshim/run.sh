#!/usr/bin/env bash
# The EH shim (lib/ehshim, scripts/ehshim, docs/notes/eh-shim.md) on programs that the common runners cannot compile on
# every backend (<future> and <regex> need std::atomic_flag and builtins that cproc and Path B lack).
#
# For each tests/ehshim/*.cpp (foreign/ at the end): `// BACKENDS: gcc qbe pathb` lists the backends that build it (default: gcc); `// EXPECT: N`
# is the exit code. Every backend must give that exit code and the standard output of the same program built by the host
# g++ (its exceptions are the reference). `pathb` needs the Path B harness (PATHB_CPFE, PATHB_BASE) and is skipped
# without it. Exit 1 on a failure.
cd "$(dirname "$0")/../.."
fail=0; tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
cxx=${NFCXX_CXX:-g++}
for f in tests/ehshim/*.cpp; do
  name=$(basename "$f" .cpp)
  want=$(sed -n 's,^// EXPECT: *\(-*[0-9]*\).*,\1,p' "$f" | head -1)
  backends=$(sed -n 's,^// BACKENDS: *\(.*\),\1,p' "$f" | head -1); backends=${backends:-gcc}
  if ! "$cxx" -std=c++23 -w -pthread "$f" -o "$tmp/$name.host" 2> "$tmp/$name.hosterr"; then
    echo "FAIL $f: host $cxx cannot build it"; head -3 "$tmp/$name.hosterr"; fail=1; continue
  fi
  "$tmp/$name.host" > "$tmp/$name.host.out" 2>/dev/null; got=$?
  if [ $((got & 255)) -ne $((want & 255)) ]; then echo "FAIL $f: host $cxx exits $got, expected $want"; fail=1; continue; fi
  for b in $backends; do
    case $b in
      gcc) env_=(NFCXX_BACKEND=gcc) ;;
      qbe) env_=(NFCXX_BACKEND=qbe) ;;
      pathb)
        if [ ! -x "${PATHB_CPFE:-$PWD/build/pathb/cmake/bin/cpfe}" ]; then echo "skip $f ($b: no Path B harness)"; continue; fi
        env_=(NFCXX_PATH=b) ;;
      *) echo "FAIL $f: unknown backend $b"; fail=1; continue ;;
    esac
    if ! env "${env_[@]}" ./nfcxx "$f" -o "$tmp/$name.$b" 2> "$tmp/$name.$b.err"; then
      echo "FAIL $f ($b): compile"; grep -v prelinker "$tmp/$name.$b.err" | head -5; fail=1; continue
    fi
    "$tmp/$name.$b" > "$tmp/$name.$b.out" 2>/dev/null; got=$?
    if [ $((got & 255)) -ne $((want & 255)) ]; then echo "FAIL $f ($b): exit $got, expected $want"; fail=1
    elif ! cmp -s "$tmp/$name.host.out" "$tmp/$name.$b.out"; then echo "FAIL $f ($b): standard output differs from the host $cxx"; fail=1
    else echo "ok   $f ($b)"; fi
  done
done
# foreign/: exceptions thrown with plain `throw` by a library built by g++ (lib.cpp), caught by main.cpp built by nfcxx
# on both backends (and by g++ for the reference output); also with NFCXX_EH_UNWIND=1 on the gcc backend.
d=tests/ehshim/foreign
if "$cxx" -std=c++17 -O1 -shared -fPIC "$d/lib.cpp" -o "$tmp/libforeign.so" 2> "$tmp/foreign.err" &&
   "$cxx" -std=c++17 -pthread -I"$d" "$d/main.cpp" -L"$tmp" -lforeign -Wl,-rpath,"$tmp" -o "$tmp/foreign.host" 2>> "$tmp/foreign.err"; then
  "$tmp/foreign.host" > "$tmp/foreign.host.out"
  for c in "gcc 0" "qbe 0" "gcc 1"; do
    set -- $c; name="$d ($1$([ $2 = 1 ] && echo ', NFCXX_EH_UNWIND=1'))"
    if ! NFCXX_BACKEND=$1 NFCXX_EH_UNWIND=$2 ./nfcxx -I"$d" "$d/main.cpp" -L"$tmp" -lforeign -Wl,-rpath,"$tmp" -o "$tmp/foreign.$1$2" 2> "$tmp/foreign.$1$2.err"; then
      echo "FAIL $name: compile"; grep -v prelinker "$tmp/foreign.$1$2.err" | head -5; fail=1; continue
    fi
    if "$tmp/foreign.$1$2" > "$tmp/foreign.$1$2.out" 2>&1 && cmp -s "$tmp/foreign.host.out" "$tmp/foreign.$1$2.out"; then echo "ok   $name"
    else echo "FAIL $name"; diff "$tmp/foreign.host.out" "$tmp/foreign.$1$2.out" | head -10; fail=1; fi
  done
else
  echo "FAIL $d: host $cxx cannot build it"; head -3 "$tmp/foreign.err"; fail=1
fi
exit $fail
