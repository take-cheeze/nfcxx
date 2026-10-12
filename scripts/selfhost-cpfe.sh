#!/usr/bin/env bash
# Self-hosting step 1: compile EDG's cpfe sources with nfcxx's qbe backend and link them into build/selfhost/cpfe.
#
# EDG's cmake build (scripts/setup-edg.sh) compiles the 75 front-end sources of cpfe with `g++ -x c++`, so each
# one is also a C++ input here. Each source is linked into build/selfhost/src/<name>.cpp (a symlink into 3rd/edg/src,
# nfcxx needs the .cpp suffix) and compiled by ./nfcxx with NFCXX_BACKEND=qbe, using the same defines and include
# directory as the cmake build. The objects are then linked by ./nfcxx, which adds libnfcxxld.a (scripts/qbe-cc) and
# EDG's libC.a. mk_errinfo.c is a host tool, not part of cpfe, and is skipped.
#
# Needs build/edg (scripts/setup-edg.sh) and build/qbe, build/cproc (scripts/setup-qbe.sh).
# Output: build/selfhost/cpfe (the link), build/selfhost/obj/*.o, logs in build/selfhost/run/<name>.log.
# JOBS: parallel compiles (default 4).
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
edg=$root/build/edg
base=$root/build/edg-base
out=$root/build/selfhost
jobs=${JOBS:-4}

[ -x "$edg/bin/cpfe" ] || { echo "selfhost-cpfe: $edg/bin/cpfe missing; run scripts/setup-edg.sh" >&2; exit 2; }
[ -x "$root/build/qbe/qbe" ] || { echo "selfhost-cpfe: QBE missing; run scripts/setup-qbe.sh" >&2; exit 2; }

# The source list is the cpfe link line of EDG's cmake build (ninja knows it).
srcs=$(ninja -C "$edg" -t commands bin/cpfe | grep -o ' -c [^ ]*\.c$' | sed 's/^ -c //' | sort -u | grep -v '/mk_errinfo\.c$')
n=$(printf '%s\n' "$srcs" | wc -l)
echo "selfhost-cpfe: $n sources"

rm -rf "$out/src" "$out/obj" "$out/run"; mkdir -p "$out/src" "$out/obj" "$out/run"
names=()
while read -r f; do
  b=$(basename "$f" .c)
  ln -s "$f" "$out/src/$b.cpp"
  names+=("$b")
done <<< "$srcs"

# One compile per source; each runs in its own directory (cpfe writes <stem>.ti into its working directory).
compile_one() {
  local name=$1 dir=$out/run/$1
  mkdir -p "$dir"
  if ! (cd "$dir" && NFCXX_BACKEND=qbe EDG_BUILD=$edg EDG_BASE=$base "$root/nfcxx" -c \
      -DBACK_END_IS_C_GEN_BE=1 -DCOMPILE_MULTIPLE_TRANSLATION_UNITS=1 \
      -DDO_IL_LOWERING=1 -DLOWER_FIXED_POINT=1 -DLOWER_IFUNC=1 -DNEED_IL_DISPLAY=1 \
      -DRECORD_BACKING_EXPRS_WITH_IL_LOWERING=1 -DUSE_CMAKE_DEFINES \
      -I"$edg/src/includes" -I"$root/3rd/edg/src" \
      -o "$out/obj/$name.o" "$out/src/$name.cpp" > "$out/run/$name.log" 2>&1); then
    echo "selfhost-cpfe: compile failed: $name (see $out/run/$name.log)" >&2
    return 1
  fi
}
export -f compile_one
export root out edg base
printf '%s\n' "${names[@]}" | xargs -P "$jobs" -I{} bash -c 'compile_one "$@"' _ {}
echo "selfhost-cpfe: $(ls "$out/obj"/*.o | wc -l) objects"

# The link: nfcxx passes the objects to eccp, which links libC.a; qbe-cc adds libnfcxxld.a and -lstdc++.
objs=()
for name in "${names[@]}"; do objs+=("$out/obj/$name.o"); done
(cd "$out/run" && NFCXX_BACKEND=qbe EDG_BUILD=$edg EDG_BASE=$base "$root/nfcxx" \
  "${objs[@]}" -o "$out/cpfe" > "$out/link.log" 2>&1) \
  || { echo "selfhost-cpfe: link failed (see $out/link.log)" >&2; exit 1; }
echo "selfhost-cpfe: built $out/cpfe"
