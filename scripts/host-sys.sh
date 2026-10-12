# Sourced by nfcxx and scripts/pathb-dump: discovery of the host C++ library headers and GNU version, so that
# Path A (eccp / cpfe --gen_c_file_name) and Path B (the harness cpfe) lower hosted programs the same way.
#   host_sys_includes   prints the include directories of the host g++ (NFCXX_CXX), one per line;
#                       NFCXX_SYS_INCLUDES (colon-separated) overrides the discovery.
#   host_gnu_version    prints the --gnu_version value (130300 for g++ 13.3.0) or nothing
host_sys_includes() {
  local cxx=${NFCXX_CXX:-g++}
  if [ -n "${NFCXX_SYS_INCLUDES:-}" ]; then
    printf '%s\n' "${NFCXX_SYS_INCLUDES//:/$'\n'}"; return
  fi
  printf '' | "$cxx" -E -x c++ -v - 2>&1 >/dev/null |
    sed -n '/search starts here:/,/End of search list/{/^ /p}' | sed 's/^ *//'
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
