#!/usr/bin/env bash
# cext2mrbgem converter tests: text-only. Runs tools/cext2mrbgem/convert_mrbgem.py on the in-repo fixtures
# and on bcrypt-ruby at a pinned commit (fetched unless BCRYPT_DIR points at a checkout). Nothing is compiled.
set -euo pipefail
cd "$(dirname "$0")/../.."
root=$PWD
conv=$root/tools/cext2mrbgem/convert_mrbgem.py
work=${CEXT_WORK:-$root/build/cext2mrbgem}
rm -rf "$work"; mkdir -p "$work"
fail=0
check() { if "$@"; then echo "ok   $*"; else echo "FAIL $*"; fail=1; fi; }

# 1. tiny fixture: converts with no refusals
rc=0; python3 "$conv" --name tiny tools/cext2mrbgem/fixtures/tiny/ext/tiny "$work/tiny" > "$work/tiny.log" 2>&1 || rc=$?
check test "$rc" -eq 0
check test ! -e "$work/tiny/NOT_BUILDABLE"

# 2. refuse fixture: refusal is reported and the output is marked not buildable
rc=0; python3 "$conv" tools/cext2mrbgem/fixtures/refuse/ext/refuse "$work/refuse" > "$work/refuse.log" 2>&1 || rc=$?
check test "$rc" -eq 2
check test -e "$work/refuse/NOT_BUILDABLE"
check grep -q 'rb_ensure' "$work/refuse/REFUSALS.txt"

# 3. bcrypt-ruby at a pinned commit
bcrypt_sha=deb496eaba56077e84bd95ac9bbcca40b6d5d685
if [ -z "${BCRYPT_DIR:-}" ]; then
  BCRYPT_DIR=$work/bcrypt-ruby
  if [ ! -d "$BCRYPT_DIR/.git" ]; then
    git init -q "$BCRYPT_DIR"
    git -C "$BCRYPT_DIR" fetch -q --depth 1 https://github.com/codahale/bcrypt-ruby "$bcrypt_sha"
    git -C "$BCRYPT_DIR" checkout -q FETCH_HEAD
  fi
fi
ext=$BCRYPT_DIR/ext/mri
rc=0; python3 "$conv" --name bcrypt "$ext" "$work/bcrypt" > "$work/bcrypt.log" 2>&1 || rc=$?
check test "$rc" -eq 0
check test ! -e "$work/bcrypt/NOT_BUILDABLE"
check grep -q 'void mrb_bcrypt_gem_init(mrb_state \*mrb)' "$work/bcrypt/src/bcrypt_ext.c"
check grep -q 'mrb_gc_protect(mrb, prefix)' "$work/bcrypt/src/bcrypt_ext.c"
check grep -q 'nfcx_thread_call_without_gvl' "$work/bcrypt/src/bcrypt_ext.c"
check grep -q "spec.add_dependency 'mruby-uv'" "$work/bcrypt/mrbgem.rake"
check grep -q '#if 0' "$work/bcrypt/src/crypt.c"
check test "$(grep -c '^warning' "$work/bcrypt.log")" -eq 2

if [ "$fail" -ne 0 ]; then echo "cext2mrbgem tests FAILED"; exit 1; fi
echo "cext2mrbgem tests OK"
