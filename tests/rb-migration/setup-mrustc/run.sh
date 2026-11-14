#!/bin/bash
# Differential test: scripts/setup-mrustc.rb against scripts/setup-mrustc.sh (see ../fetch-build/common.sh). git (clone,
# checkout) and make are stubbed: a clone makes the .git directory, and the make steps succeed unless FAKE_MAKE_FAIL names a
# step (a word of the make command line) or FAKE_CHECKOUT_FAIL is set. Nothing is cloned or built.
here=$(cd "$(dirname "$0")" && pwd -P)
RBM_NAME=setup-mrustc
. "$here/../fetch-build/common.sh"

setup() {
  mkdir -p "$SB/hooks"
  cat > "$SB/hooks/git" <<'H'
#!/bin/bash
case "$*" in
  *" checkout "*) [ -z "$FAKE_CHECKOUT_FAIL" ] || exit 128 ;;
  clone*) mkdir -p "${@: -1}/.git" ;;
esac
exit 0
H
  cat > "$SB/hooks/make" <<'H'
#!/bin/bash
case "$*" in *"$FAKE_MAKE_FAIL"*) [ -z "$FAKE_MAKE_FAIL" ] || exit 2 ;; esac
exit 0
H
  chmod +x "$SB/hooks/git" "$SB/hooks/make"
}
setup_checked_out() {                  # a checkout is there: no clone
  setup
  mkdir -p "$SB/repo/build/mrustc/src/.git"
}
setup_built() {                        # the compiler and the library are built: nothing runs
  setup
  mkdir -p "$SB/repo/build/mrustc/src/bin" "$SB/repo/build/mrustc/src/output-1.90.0"
  printf '#!/bin/sh\n' > "$SB/repo/build/mrustc/src/bin/mrustc"
  chmod +x "$SB/repo/build/mrustc/src/bin/mrustc"
  : > "$SB/repo/build/mrustc/src/output-1.90.0/libstd.rlib.o"
}
setup_built_with_checkout() {          # the same, with a checkout: FORCE=1 rebuilds it without a clone
  setup_built
  mkdir -p "$SB/repo/build/mrustc/src/.git"
}

rbm_case clone-default-jobs setup ""
rbm_case clone-parlevel setup "PARLEVEL=3"
rbm_case parlevel-empty setup "PARLEVEL="
rbm_case clone-repo-override setup "MRUSTC_REPO=https://example.test/fork/mrustc.git"
rbm_case checked-out setup_checked_out "PARLEVEL=2"
rbm_case built-skip setup_built ""
rbm_case built-force setup_built_with_checkout "FORCE=1 PARLEVEL=2"
rbm_case make-fails setup "FAKE_MAKE_FAIL=RUSTCSRC"
rbm_case checkout-fails setup "FAKE_CHECKOUT_FAIL=1"
rbm_summary
