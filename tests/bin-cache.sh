# Sourced by tests/poly/run.sh, tests/uop/run.sh and tests/uop/run_poly.sh (after they change to the repository root).
# Each test program is compiled by nfcxx on every run. When TEST_BIN_CACHE is set (the CI workflow sets it, with an
# Actions cache keyed on the sources, the compiler and the toolchain), a program is kept there, and a later run with the
# same command line takes that copy instead of compiling. The file name holds a hash of the whole command line (back end,
# flags, sources, libraries and interpreters it links), so a different language set or flag is never served a stale
# program. The program still runs on every run; only the compile is skipped.
#   bin_cache_file NAME CMD...    prints where the program built by CMD is kept (nothing when TEST_BIN_CACHE is unset)
#   bin_cache_store FILE CACHED   keeps a copy of the program FILE at CACHED
bin_cache_file() {
  [ -n "${TEST_BIN_CACHE:-}" ] || return 0
  local name=$1; shift
  echo "$TEST_BIN_CACHE/$name-$(printf '%s\0' "$@" | sha256sum | cut -c1-24)"
}
bin_cache_store() {
  mkdir -p "$(dirname "$2")" && cp -p "$1" "$2.tmp.$$" && mv -f "$2.tmp.$$" "$2"
}
