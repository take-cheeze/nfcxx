#!/bin/bash
# Differential test: scripts/setup-mruby-wasm.rb against scripts/setup-mruby-wasm.sh (see ../fetch-build/common.sh). The
# repository's setup-mruby.sh, rake and the build's output are stubbed: nothing is compiled.
here=$(cd "$(dirname "$0")" && pwd -P)
RBM_NAME=setup-mruby-wasm
. "$here/../fetch-build/common.sh"

# setup-mruby.sh makes the source directory; rake (the stub) writes the two outputs under MRUBY_BUILD_DIR
setup() {
  cat > "$SB/hooks/setup-mruby.sh" <<H
#!/bin/bash
mkdir -p "$SB/repo/build/mruby-tool/src"
[ -z "\$FAIL_SETUP_MRUBY" ] || exit 4
H
  cat > "$SB/hooks/rake" <<'H'
#!/bin/bash
[ -z "$FAKE_BUILD_FAIL" ] || { echo "rake: boom"; exit 2; }
[ -n "$FAKE_NO_OUTPUT" ] && exit 0
mkdir -p "$MRUBY_BUILD_DIR/wasm/bin"
echo "js" > "$MRUBY_BUILD_DIR/wasm/bin/mruby.js"
printf 'wasm-bytes' > "$MRUBY_BUILD_DIR/wasm/bin/mruby.wasm"
H
  chmod +x "$SB/hooks/setup-mruby.sh" "$SB/hooks/rake"
}
setup_built() {                       # the interpreter is built: nothing runs
  setup
  mkdir -p "$SB/repo/build/mruby-wasm/out/wasm/bin"
  echo js > "$SB/repo/build/mruby-wasm/out/wasm/bin/mruby.js"
}
setup_no_emcc() { setup; rm -f "$SB/bin/emcc"; }
setup_no_rake() { setup; rm -f "$SB/bin/rake"; }

rbm_case build setup "JOBS=4"
rbm_case built-skip setup_built ""
rbm_case force-rebuild setup_built "FORCE=1"
rbm_case no-emcc setup_no_emcc ""
rbm_case build-fails setup "FAKE_BUILD_FAIL=1"
rbm_case no-output setup "FAKE_NO_OUTPUT=1"
rbm_case setup-mruby-fails setup "FAIL_SETUP_MRUBY=1"
rbm_case rake-fallback setup_no_rake ""
rbm_summary
