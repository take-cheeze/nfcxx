# Sourced by nfcxx and scripts/pathb-dump: discovery of the host C++ library headers and GNU version, so that
# Path A (eccp / cpfe --gen_c_file_name) and Path B (the harness cpfe) lower hosted programs the same way.
#   host_sys_includes   prints the include directories of the host g++ (NFCXX_CXX), one per line;
#                       NFCXX_SYS_INCLUDES (colon-separated) overrides the discovery. host_sys_includes c prints the
#                       host C compiler's (NFCXX_CC, default gcc) instead, without the C++ library.
#   host_gnu_version    prints the --gnu_version value (130300 for g++ 13.3.0) or nothing
#   host_dialect        prints clang when the host C++ compiler is clang (Apple's g++ is clang), else g++
#   host_clang_version  prints the --clang_version value (210000 for clang 21.0.0) or nothing
#   abs_path PATH       prints the absolute path of PATH without requiring it to exist (what realpath -m does; BSD
#                       realpath on macOS has no -m)
abs_path() {
  local d b
  d=$(dirname "$1"); b=$(basename "$1")
  if (cd "$d" 2>/dev/null); then (cd "$d" && printf '%s/%s\n' "$(pwd -P)" "$b")
  else printf '%s\n' "$1"; fi
}
host_dialect() {
  if "${NFCXX_CXX:-g++}" --version 2>/dev/null | head -1 | grep -qi clang; then echo clang; else echo g++; fi
}
host_clang_version() {
  local ver maj min pat v
  # --version rather than -dumpfullversion: Apple's clang++ rejects -dumpfullversion without an input file.
  ver=$("${NFCXX_CXX:-g++}" --version 2>/dev/null | head -1 | sed -n 's/.*version \([0-9][0-9.]*\).*/\1/p') || return 0
  [ -n "$ver" ] || return 0
  IFS=. read -r maj min pat <<< "$ver"
  v=$(( ${maj:-0} * 10000 + ${min:-0} * 100 + ${pat:-0} ))
  # EDG's clang builtin tables stop at clang 20: at 21 libc++'s __is_nothrow_convertible is parsed as a type name
  # (the EH shim fails to build). The host clang still compiles the generated C.
  [ "$v" -gt 200000 ] && v=200000
  echo "$v"
  return 0
}
host_sys_includes() {
  local cxx=${NFCXX_CXX:-g++} lang=${1:-c++}
  if [ -n "${NFCXX_SYS_INCLUDES:-}" ]; then
    printf '%s\n' "${NFCXX_SYS_INCLUDES//:/$'\n'}"; return
  fi
  [ "$lang" != c ] || cxx=${NFCXX_CC:-gcc}
  # awk, not sed: BSD sed (macOS) rejects the one-line form of this script.
  printf '' | "$cxx" -E -x "$lang" -v - 2>&1 >/dev/null |
    awk '/search starts here:/ { on = 1; next } /End of search list/ { on = 0 } on && /^ / { sub(/^ +/, "") }
      on && /framework directory/ { next } on && /^[^ ]/ { print }'
}
host_gnu_version() {
  local ver
  # major.minor.patch -> major*10000 + minor*100 + patch, as EDG's --gnu_version. The minor version matters:
  # EDG's builtin table gates builtins that GCC added in a minor release (GCC 15.2 has the AVX10.2 conversions,
  # which 150000 does not).
  local maj min pat
  ver=$("${NFCXX_CXX:-g++}" -dumpfullversion 2>/dev/null) || return 0
  IFS=. read -r maj min pat <<< "$ver"
  echo $(( ${maj:-0} * 10000 + ${min:-0} * 100 + ${pat:-0} ))
  return 0
}
