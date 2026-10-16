#!/usr/bin/env bash
# Real-world check: compile the workstation GC of CoreCLR (dotnet/runtime, src/coreclr/gc: 34 translation units, the
# list of the segments build without the server GC) with nfcxx, on both backends. The source is cloned into
# build/realworld, not vendored. docs/notes/coreclr-gc.md says what this covers and what is not built yet.
#   NFCXX_BACKEND=gcc|qbe   (default: both)
# The config headers the CMake build generates (gc/unix/config.gc.h, minipal/minipalconfig.h) are written here
# from their templates for glibc on x86-64, with the HAVE_* values of that platform.
cd "$(dirname "$0")/../.."
root=$PWD; work=$root/build/realworld
pin=2ec49fefa7c8f8ea911bfcf18360c975ecd5e161   # dotnet/runtime main, 2026-10-16
src=$work/runtime
if [ ! -d "$src/.git" ]; then
  mkdir -p "$src" && git -C "$src" init -q &&
    git -C "$src" remote add origin https://github.com/dotnet/runtime || exit 1
fi
if [ "$(git -C "$src" rev-parse -q --verify "$pin^{commit}" 2>/dev/null)" != "$pin" ]; then
  git -C "$src" fetch -q --depth 1 origin "$pin" || { echo "SKIP coreclr-gc: fetch failed"; exit 0; }
fi
git -C "$src" checkout -q "$pin" || { echo "FAIL coreclr-gc: checkout $pin failed"; exit 1; }

rt=$src/src
gc=$rt/coreclr/gc
gen=$work/coreclr-gc-gen
mkdir -p "$gen/minipal"
# HAVE_* values for glibc on x86-64 (the Linux column of configure.cmake); every other template line is copied.
on=" HAVE_SYS_TIME_H HAVE_SYS_MMAN_H HAVE_SYS_MEMBARRIER_H HAVE_MAP_HUGETLB HAVE_SCHED_GETCPU HAVE_POSIX_MADVISE HAVE_CPUSET_T
 HAVE_SYSCONF HAVE__SC_AVPHYS_PAGES HAVE__SC_PHYS_PAGES HAVE_SCHED_GETAFFINITY HAVE_SCHED_SETAFFINITY HAVE_PTHREAD_SETAFFINITY_NP
 HAVE_PTHREAD_CONDATTR_SETCLOCK HAVE_SYSINFO HAVE_SYSINFO_WITH_MEM_UNIT HAVE_NON_LEGACY_STATFS HAVE_PROCFS_STATM
 HAVE_PTHREAD_RWLOCK_PREFER_WRITER_NONRECURSIVE_NP HAVE_CLOCK_MONOTONIC_COARSE HAVE_ARC4RANDOM_BUF HAVE_GETRANDOM HAVE_GETAUXVAL
 HAVE_AUXV_HWCAP_H HAVE_RESOURCE_H HAVE_O_CLOEXEC HAVE_FSYNC "
gen_config() {  # gen_config TEMPLATE OUTPUT
  awk -v on="$on" '/^#cmakedefine01 /{ v = (index(on, " " $2 " ") ? 1 : 0); print "#define " $2 " " v; next } { print }' "$1" > "$2"
}
gen_config "$gc/unix/config.gc.h.in" "$gen/config.gc.h"
gen_config "$rt/native/minipal/minipalconfig.h.in" "$gen/minipal/minipalconfig.h"

# Compile flags of the GC build (gc/CMakeLists.txt and clrdefinitions.cmake for linux-x64, standalone, segments GC).
flags=(-I"$gen" -I"$gc" -I"$gc/env" -I"$gc/unix" -I"$rt/coreclr/inc" -I"$rt/coreclr/pal/inc" -I"$rt/coreclr/pal/inc/rt"
       -I"$rt/native" -I"$rt/native/minipal" -I"$gc/vxsort"
       -DTARGET_LINUX -DTARGET_UNIX -DTARGET_AMD64 -DHOST_AMD64 -DHOST_64BIT -DTARGET_64BIT -DUNIX_AMD64_ABI
       -DBUILD_AS_STANDALONE -DFEATURE_STANDALONE_GC -DFEATURE_CONSERVATIVE_GC -DGC_DESCRIPTOR -DGC_CONFIG_DRIVEN
       -DVERIFY_HEAP -DFEATURE_CORECLR -DFEATURE_PAL_ANSI)
# gc/CMakeLists.txt GC_WKS_SVR_SOURCES, minus the server-GC variant
files=(gcee gc init no_gc finalization dynamic_tuning region_free_list region_allocator memory sweep collect diagnostics
       dynamic_heap_count card_table relocate_compact mark_phase background interface allocation plan_phase regions_segments
       gceventstatus gcconfig gccommon gcscan handletable handletablecore handletablescan objecthandle softwarewritewatch
       gchandletable gcload gcbridge handletablecache)

backends=${NFCXX_BACKEND:-"gcc qbe"}
fail=0; tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
for b in $backends; do
  ok=0; bad=0
  for f in "${files[@]}"; do
    if NFCXX_BACKEND=$b "$root/nfcxx" -c "${flags[@]}" "$gc/$f.cpp" -o "$tmp/$b-$f.o" >"$tmp/$b-$f.log" 2>&1; then
      ok=$((ok + 1))
    else
      bad=$((bad + 1)); echo "FAIL $b coreclr-gc $f"; grep -m3 "error" "$tmp/$b-$f.log"
    fi
  done
  echo "$b coreclr-gc: $ok of ${#files[@]} translation units compile"
  [ $bad = 0 ] || fail=1
done
exit $fail
