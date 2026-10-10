# Sourced by nfcxx and scripts/pathb-dump: discovery of the host C++ library headers and GNU version, so that
# Path A (eccp / cpfe --gen_c_file_name) and Path B (the harness cpfe) lower hosted programs the same way.
#   host_sys_includes   prints the include directories of the host g++ (NFCXX_CXX), one per line;
#                       NFCXX_SYS_INCLUDES (colon-separated) overrides the discovery.
#   host_gnu_version    prints the --gnu_version value (130000 for g++ 13.x) or nothing
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
  ver=$("${NFCXX_CXX:-g++}" -dumpfullversion 2>/dev/null) && echo "${ver%%.*}0000"
  return 0
}
