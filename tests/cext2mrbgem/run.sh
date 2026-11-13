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

# 2d. definitions whose return type or name is on another line are found (no false "no definition" refusal)
rc=0; python3 "$conv" --name split_return tools/cext2mrbgem/fixtures/split_return/ext/split_return "$work/split_return" > "$work/split_return.log" 2>&1 || rc=$?
check test "$rc" -eq 0
check test ! -e "$work/split_return/NOT_BUILDABLE"
check grep -qF 'static inline mrb_value split_double(mrb_state *mrb, mrb_value self) {' "$work/split_return/src/split_return.c"
check grep -qF 'mrb_value split_load(mrb_state *mrb, mrb_value self) {' "$work/split_return/src/split_return.c"
check grep -qF 'mrb_value split_name(mrb_state *mrb, mrb_value self) {' "$work/split_return/src/split_return.c"

# 2e. variadic methods (argc -1): argc and argv are read back with mrb_get_args("*") in the converted function,
# and the method is defined with MRB_ARGS_ANY(); argc -2 (array form) stays refused
rc=0; python3 "$conv" --name variadic tools/cext2mrbgem/fixtures/variadic/ext/variadic "$work/variadic" > "$work/variadic.log" 2>&1 || rc=$?
check test "$rc" -eq 0
check test ! -e "$work/variadic/NOT_BUILDABLE"
check grep -qF 'static mrb_value variadic_first(mrb_state *mrb, mrb_value self) {' "$work/variadic/src/variadic.c"
check grep -qF 'mrb_get_args(mrb, "*", &argv, &nfcx_argc);' "$work/variadic/src/variadic.c"
check grep -qF 'int argc = (int)nfcx_argc;' "$work/variadic/src/variadic.c"
check grep -qF 'mrb_define_method(mrb, mVariadic, "first", variadic_first, MRB_ARGS_ANY());' "$work/variadic/src/variadic.c"
rc=0; python3 "$conv" --name variadic_array tools/cext2mrbgem/fixtures/variadic_array/ext/variadic_array "$work/variadic_array" > "$work/variadic_array.log" 2>&1 || rc=$?
check test "$rc" -eq 2
check grep -q 'argc -2 (array form)' "$work/variadic_array/REFUSALS.txt"

# 2f. rb_scan_args in a variadic method: "<lead><optional>" formats become mrb_get_args with nil-initialised
# optional outputs; rest, keyword, used-return and non-variadic forms stay refused
rc=0; python3 "$conv" --name scan_args tools/cext2mrbgem/fixtures/scan_args/ext/scan_args "$work/scan_args" > "$work/scan_args.log" 2>&1 || rc=$?
check test "$rc" -eq 0
check test ! -e "$work/scan_args/NOT_BUILDABLE"
check grep -qF '(second = mrb_nil_value(), mrb_get_args(mrb, "o|o", &first, &second));' "$work/scan_args/src/scan_args.c"
check grep -qF '(mrb_get_args(mrb, ""));' "$work/scan_args/src/scan_args.c"
check grep -qF '(b = mrb_nil_value(), c = mrb_nil_value(), mrb_get_args(mrb, "o|oo", &a, &b, &c));' "$work/scan_args/src/scan_args.c"
rc=0; python3 "$conv" --name scan_args_refused tools/cext2mrbgem/fixtures/scan_args_refused/ext/scan_args_refused "$work/scan_args_refused" > "$work/scan_args_refused.log" 2>&1 || rc=$?
check test "$rc" -eq 2
check test "$(grep -c '  rb_scan_args  ' "$work/scan_args_refused/REFUSALS.txt")" -eq 4
check grep -q 'return value of rb_scan_args is used' "$work/scan_args_refused/REFUSALS.txt"

# 2g. rb_define_module_function (singleton and private instance method, mrb_define_module_function) and
# rb_define_const (mrb_define_const on a tracked module or rb_cObject); a local receiver stays refused
rc=0; python3 "$conv" --name module_const tools/cext2mrbgem/fixtures/module_const/ext/module_const "$work/module_const" > "$work/module_const.log" 2>&1 || rc=$?
check test "$rc" -eq 0
check test ! -e "$work/module_const/NOT_BUILDABLE"
check grep -qF 'mrb_define_module_function(mrb, mMC, "twice", mc_twice, MRB_ARGS_REQ(1));' "$work/module_const/src/module_const.c"
check grep -qF 'mrb_define_module_function(mrb, mMC, "argc", mc_argc, MRB_ARGS_ANY());' "$work/module_const/src/module_const.c"
check grep -qF 'mrb_define_const(mrb, mMC, "VERSION", mrb_fixnum_value(3));' "$work/module_const/src/module_const.c"
check grep -qF 'mrb_define_const(mrb, mrb->object_class, "MODULE_CONST_LOADED", mrb_true_value());' "$work/module_const/src/module_const.c"
rc=0; python3 "$conv" --name module_const_refused tools/cext2mrbgem/fixtures/module_const_refused/ext/module_const_refused "$work/module_const_refused" > "$work/module_const_refused.log" 2>&1 || rc=$?
check test "$rc" -eq 2
check grep -q '  rb_define_const  target .target. is not a tracked' "$work/module_const_refused/REFUSALS.txt"
check grep -q '  rb_define_module_function  target .target. is not a tracked' "$work/module_const_refused/REFUSALS.txt"

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
