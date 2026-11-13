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

# 2b. registration refused because its function has no definition (a prototype remains): exit 0 or 2, never a traceback
ok_rc() { [ "$1" -eq 0 ] || [ "$1" -eq 2 ]; }
rc=0; python3 "$conv" --name refused_reg tools/cext2mrbgem/fixtures/refused_reg/ext/refused_reg "$work/refused_reg" > "$work/refused_reg.log" 2>&1 || rc=$?
check ok_rc "$rc"
check sh -c "! grep -q Traceback '$work/refused_reg.log'"
check grep -q 'rr_missing  registered function has no definition' "$work/refused_reg/REFUSALS.txt"
check test -e "$work/refused_reg/NOT_BUILDABLE"

# 2c. a parameter named like a file-scope class variable: no overlapping edits (used to raise), and the
# parameter is not wrapped as a class (header and body); the file-scope declaration is still rewritten
rc=0; python3 "$conv" --name shadow_param tools/cext2mrbgem/fixtures/shadow_param/ext/shadow_param "$work/shadow_param" > "$work/shadow_param.log" 2>&1 || rc=$?
check test "$rc" -eq 0
check sh -c "! grep -q 'overlapping\\|Traceback' '$work/shadow_param.log'"
check grep -qF 'static mrb_value dump_it(mrb_state *mrb, mrb_value obj, mrb_value klass, int depth) {' "$work/shadow_param/src/shadow_param.c"
check grep -qF 'if (klass == obj)' "$work/shadow_param/src/shadow_param.c"
check grep -qF 'static struct RClass * klass;' "$work/shadow_param/src/shadow_param.c"

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
