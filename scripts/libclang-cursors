#!/usr/bin/env bash
# libclang-edg: list the declarations of one C++ file as tab-separated records (format: be/nfcxx_decl.c).
# Runs the libclang-edg front end (build/libclang-edg, from scripts/setup-libclang-edg.sh) with the same host
# library and GNU options as scripts/pathb-dump. Usage: scripts/libclang-cursors [--c | -std=c++NN] [-Idir] [-Dmacro] file.cpp   (--c: C mode, for C headers)
# The libclang shim (lib/libclang-edg) runs this script; LIBCLANG_EDG_CPFE and LIBCLANG_EDG_BASE override the paths.
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
cpfe=${LIBCLANG_EDG_CPFE:-$root/build/libclang-edg/cmake/bin/cpfe}
base=${LIBCLANG_EDG_BASE:-$root/build/libclang-edg/edg-base}
[ -x "$cpfe" ] || { echo "libclang-cursors: front end not built; run scripts/setup-libclang-edg.sh" >&2; exit 2; }

host_sys() { "${RUBY:-ruby}" "$root/scripts/host-sys.rb" "$@"; }   # the host probes (scripts/host-sys.rb)
host_sys_includes() { host_sys host_sys_includes "$@"; }
host_gnu_version() { host_sys host_gnu_version; }
abs_path() {
  local d b
  d=$(dirname "$1"); b=$(basename "$1")
  if (cd "$d" 2>/dev/null); then (cd "$d" && printf '%s/%s\n' "$(pwd -P)" "$b")
  else printf '%s\n' "$1"; fi
}
std=--c++23; files=(); user_opts=(); c_mode=0
for arg in "$@"; do
  case $arg in
    --c) c_mode=1 ;;
    -std=c++*) std=--c++${arg#-std=c++} ;;
    -I?*) user_opts+=("-I$(abs_path "${arg#-I}")") ;;
    -D?*|-U?*) user_opts+=("$arg") ;;
    -W*) ;;
    *) files+=("$arg") ;;
  esac
done
[ ${#files[@]} -gt 0 ] || { echo "libclang-cursors: no input file" >&2; exit 2; }

sys_inc=(); while IFS= read -r d; do [ -n "$d" ] && sys_inc+=("--sys_include=$d"); done < <(host_sys_includes)
gnu=$(host_gnu_version); gnu_opts=(); [ -z "$gnu" ] || gnu_opts=(--gnu_version="$gnu")

status=0
for file in "${files[@]}"; do
  f=$(realpath "$file")
  stem=$(basename "$f" .cpp)
  ti=$base/$stem.ti; had_ti=0; [ -e "$ti" ] && had_ti=1
  if [ $c_mode = 1 ]; then
    lang=(--c)
  else
    lang=("$std" --g++ -tused)
  fi
  (cd "$base" && "$cpfe" -D_POSIX_SOURCE -D__CHAR_BIT__=8 "${lang[@]}" --wdir / ${gnu_opts[@]+"${gnu_opts[@]}"} ${user_opts[@]+"${user_opts[@]}"} "${sys_inc[@]}" --sys_include="$base/include" "$f") || status=$?
  [ $had_ti = 1 ] || rm -f "$ti"
done
exit $status
