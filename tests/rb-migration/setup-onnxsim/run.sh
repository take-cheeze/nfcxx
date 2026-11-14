#!/bin/bash
# Differential test: scripts/setup-onnxsim.rb against scripts/setup-onnxsim.sh (see ../fetch-build/common.sh). git, cmake and
# the library's build are stubbed: git's rev-parse answers with the commit it was last asked to fetch (GIT_HEAD overrides it),
# and cmake's build creates the library. Nothing is cloned or built.
here=$(cd "$(dirname "$0")" && pwd -P)
RBM_NAME=setup-onnxsim
. "$here/../fetch-build/common.sh"

STAMP_HASH=$(sha256sum "$REPO/scripts/onnxsim/nfc_onnxsim.cpp" | cut -c1-12)
STAMP=built-21f95fd13fae374827e6cdd836987eeff32ebfea-281e5e6accfd6113fd57d819ce47f32a937bb106-$STAMP_HASH

# git: fetch records the commit, rev-parse prints it (or GIT_HEAD); init, checkout and the rest succeed.
# cmake: the build writes the library; FAKE_BUILD_FAIL makes it fail.
setup() {
  mkdir -p "$SB/hooks"
  cat > "$SB/hooks/git" <<'H'
#!/bin/bash
case "$*" in
  *" fetch "*) echo "${@: -1}" > "$NFCXX_STUB_STATE/head" ;;
  *rev-parse*) if [ -n "$GIT_HEAD" ]; then echo "$GIT_HEAD"; else cat "$NFCXX_STUB_STATE/head"; fi ;;
esac
exit 0
H
  cat > "$SB/hooks/cmake" <<'H'
#!/bin/bash
if [ "$1" = --build ]; then
  [ -z "$FAKE_BUILD_FAIL" ] || { echo "build failed" >&2; exit 2; }
  mkdir -p "$2" && : > "$2/libnfconnxsim.so"
fi
exit 0
H
  chmod +x "$SB/hooks/git" "$SB/hooks/cmake"
}
setup_built() {
  setup
  mkdir -p "$SB/repo/build/onnxsim"
  : > "$SB/repo/build/onnxsim/$STAMP"; : > "$SB/repo/build/onnxsim/libnfconnxsim.so"
}
setup_stamp_no_lib() {
  setup
  mkdir -p "$SB/repo/build/onnxsim"; : > "$SB/repo/build/onnxsim/$STAMP"
}
setup_old_stamp() {
  setup                          # a stamp of other sources, and the library: built again, the old stamp removed
  mkdir -p "$SB/repo/build/onnxsim"
  : > "$SB/repo/build/onnxsim/built-old"; : > "$SB/repo/build/onnxsim/libnfconnxsim.so"
}

rbm_case default-jobs setup "JOBS=4"
rbm_case default-nproc setup ""
rbm_case built-early-exit setup_built "JOBS=4"
rbm_case stamp-without-lib setup_stamp_no_lib "JOBS=4"
rbm_case old-stamp setup_old_stamp "JOBS=2"
rbm_case head-mismatch setup "JOBS=4 GIT_HEAD=0000000000000000000000000000000000000000"
rbm_case build-fails setup "JOBS=4 FAKE_BUILD_FAIL=1"
rbm_summary
