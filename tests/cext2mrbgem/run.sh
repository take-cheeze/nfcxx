#!/usr/bin/env bash
# cext2mrbgem converter tests: text-only. Runs tools/cext2mrbgem/convert_mrbgem.rb (CRuby, standard library only;
# RUBY selects the interpreter, default ruby) on the in-repo fixtures and on bcrypt-ruby at a pinned commit
# (fetched unless BCRYPT_DIR points at a checkout). Nothing is compiled.
# Two legs run the same assertions: --scanner regex (the DEF_RE regex scan) and --scanner libclang (the declaration
# scan through libclang-edg, tools/cext2mrbgem/decl_scan.rb). The libclang leg prints SKIP when the library does not
# load: CEXT_LIBCLANG, default build/libclang-edg/libclang-edg.so.
set -euo pipefail
cd "$(dirname "$0")/../.."
root=$PWD
conv=$root/tools/cext2mrbgem/convert_mrbgem.rb
rb=${RUBY:-ruby}
root_work=${CEXT_WORK:-$root/build/cext2mrbgem}
rm -rf "$root_work"; mkdir -p "$root_work"
fail=0
leg=none
check() { if "$@"; then echo "ok   [$leg] $*"; else echo "FAIL [$leg] $*"; fail=1; fi; }

run_leg() {
  local scanner=$1
  leg=$scanner
  work=$root_work/$scanner
  mkdir -p "$work"
# 1. tiny fixture: converts with no refusals
rc=0; "$rb" "$conv" --scanner "$scanner" --name tiny tools/cext2mrbgem/fixtures/tiny/ext/tiny "$work/tiny" > "$work/tiny.log" 2>&1 || rc=$?
check test "$rc" -eq 0
check test ! -e "$work/tiny/NOT_BUILDABLE"

# 2. refuse fixture: refusal is reported and the output is marked not buildable
rc=0; "$rb" "$conv" --scanner "$scanner" tools/cext2mrbgem/fixtures/refuse/ext/refuse "$work/refuse" > "$work/refuse.log" 2>&1 || rc=$?
check test "$rc" -eq 2
check test -e "$work/refuse/NOT_BUILDABLE"
check grep -q 'rb_ensure' "$work/refuse/REFUSALS.txt"

# 2b. registration refused because its function has no definition (a prototype remains): exit 0 or 2, never a traceback
ok_rc() { [ "$1" -eq 0 ] || [ "$1" -eq 2 ]; }
rc=0; "$rb" "$conv" --scanner "$scanner" --name refused_reg tools/cext2mrbgem/fixtures/refused_reg/ext/refused_reg "$work/refused_reg" > "$work/refused_reg.log" 2>&1 || rc=$?
check ok_rc "$rc"
check sh -c "! grep -q Traceback '$work/refused_reg.log'"
check grep -q 'rr_missing  registered function has no definition' "$work/refused_reg/REFUSALS.txt"
check test -e "$work/refused_reg/NOT_BUILDABLE"

# 2c. a parameter named like a file-scope class variable: no overlapping edits (used to raise), and the
# parameter is not wrapped as a class (header and body); the file-scope declaration is still rewritten
rc=0; "$rb" "$conv" --scanner "$scanner" --name shadow_param tools/cext2mrbgem/fixtures/shadow_param/ext/shadow_param "$work/shadow_param" > "$work/shadow_param.log" 2>&1 || rc=$?
check test "$rc" -eq 0
check sh -c "! grep -q 'overlapping\\|Traceback' '$work/shadow_param.log'"
check grep -qF 'static mrb_value dump_it(mrb_state *mrb, mrb_value obj, mrb_value klass, int depth) {' "$work/shadow_param/src/shadow_param.c"
check grep -qF 'if (klass == obj)' "$work/shadow_param/src/shadow_param.c"
check grep -qF 'static struct RClass * klass;' "$work/shadow_param/src/shadow_param.c"

# 2d. definitions whose return type or name is on another line are found (no false "no definition" refusal)
rc=0; "$rb" "$conv" --scanner "$scanner" --name split_return tools/cext2mrbgem/fixtures/split_return/ext/split_return "$work/split_return" > "$work/split_return.log" 2>&1 || rc=$?
check test "$rc" -eq 0
check test ! -e "$work/split_return/NOT_BUILDABLE"
check grep -qF 'static inline mrb_value split_double(mrb_state *mrb, mrb_value self) {' "$work/split_return/src/split_return.c"
check grep -qF 'mrb_value split_load(mrb_state *mrb, mrb_value self) {' "$work/split_return/src/split_return.c"
check grep -qF 'mrb_value split_name(mrb_state *mrb, mrb_value self) {' "$work/split_return/src/split_return.c"

# 2e. variadic methods (argc -1): argc and argv are read back with mrb_get_args("*") in the converted function,
# and the method is defined with MRB_ARGS_ANY(); argc -2 (array form) stays refused
rc=0; "$rb" "$conv" --scanner "$scanner" --name variadic tools/cext2mrbgem/fixtures/variadic/ext/variadic "$work/variadic" > "$work/variadic.log" 2>&1 || rc=$?
check test "$rc" -eq 0
check test ! -e "$work/variadic/NOT_BUILDABLE"
check grep -qF 'static mrb_value variadic_first(mrb_state *mrb, mrb_value self) {' "$work/variadic/src/variadic.c"
check grep -qF 'mrb_get_args(mrb, "*", &argv, &nfcx_argc);' "$work/variadic/src/variadic.c"
check grep -qF 'int argc = (int)nfcx_argc;' "$work/variadic/src/variadic.c"
check grep -qF 'mrb_define_method(mrb, mVariadic, "first", variadic_first, MRB_ARGS_ANY());' "$work/variadic/src/variadic.c"
rc=0; "$rb" "$conv" --scanner "$scanner" --name variadic_array tools/cext2mrbgem/fixtures/variadic_array/ext/variadic_array "$work/variadic_array" > "$work/variadic_array.log" 2>&1 || rc=$?
check test "$rc" -eq 2
check grep -q 'argc -2 (array form)' "$work/variadic_array/REFUSALS.txt"

# 2f. rb_scan_args in a variadic method: "<lead><optional>" formats become mrb_get_args with nil-initialised
# optional outputs; rest, keyword, used-return and non-variadic forms stay refused
rc=0; "$rb" "$conv" --scanner "$scanner" --name scan_args tools/cext2mrbgem/fixtures/scan_args/ext/scan_args "$work/scan_args" > "$work/scan_args.log" 2>&1 || rc=$?
check test "$rc" -eq 0
check test ! -e "$work/scan_args/NOT_BUILDABLE"
check grep -qF '(second = mrb_nil_value(), mrb_get_args(mrb, "o|o", &first, &second));' "$work/scan_args/src/scan_args.c"
check grep -qF '(mrb_get_args(mrb, ""));' "$work/scan_args/src/scan_args.c"
check grep -qF '(b = mrb_nil_value(), c = mrb_nil_value(), mrb_get_args(mrb, "o|oo", &a, &b, &c));' "$work/scan_args/src/scan_args.c"
rc=0; "$rb" "$conv" --scanner "$scanner" --name scan_args_refused tools/cext2mrbgem/fixtures/scan_args_refused/ext/scan_args_refused "$work/scan_args_refused" > "$work/scan_args_refused.log" 2>&1 || rc=$?
check test "$rc" -eq 2
check test "$(grep -c '  rb_scan_args  ' "$work/scan_args_refused/REFUSALS.txt")" -eq 4
check grep -q 'return value of rb_scan_args is used' "$work/scan_args_refused/REFUSALS.txt"

# 2g. rb_define_module_function (singleton and private instance method, mrb_define_module_function) and
# rb_define_const (mrb_define_const on a tracked module or rb_cObject); a local receiver stays refused
rc=0; "$rb" "$conv" --scanner "$scanner" --name module_const tools/cext2mrbgem/fixtures/module_const/ext/module_const "$work/module_const" > "$work/module_const.log" 2>&1 || rc=$?
check test "$rc" -eq 0
check test ! -e "$work/module_const/NOT_BUILDABLE"
check grep -qF 'mrb_define_module_function(mrb, mMC, "twice", mc_twice, MRB_ARGS_REQ(1));' "$work/module_const/src/module_const.c"
check grep -qF 'mrb_define_module_function(mrb, mMC, "argc", mc_argc, MRB_ARGS_ANY());' "$work/module_const/src/module_const.c"
check grep -qF 'mrb_define_const(mrb, mMC, "VERSION", mrb_fixnum_value(3));' "$work/module_const/src/module_const.c"
check grep -qF 'mrb_define_const(mrb, mrb->object_class, "MODULE_CONST_LOADED", mrb_true_value());' "$work/module_const/src/module_const.c"
rc=0; "$rb" "$conv" --scanner "$scanner" --name module_const_refused tools/cext2mrbgem/fixtures/module_const_refused/ext/module_const_refused "$work/module_const_refused" > "$work/module_const_refused.log" 2>&1 || rc=$?
check test "$rc" -eq 2
check grep -q '  rb_define_const  target .target. is not a tracked' "$work/module_const_refused/REFUSALS.txt"
check grep -q '  rb_define_module_function  target .target. is not a tracked' "$work/module_const_refused/REFUSALS.txt"

# 2h. rb_const_get maps to mrb_const_get (the receiver as a VALUE, rb_cObject as its VALUE); rb_const_get_at has no
# exact mruby equivalent and stays refused
rc=0; "$rb" "$conv" --scanner "$scanner" --name const_get tools/cext2mrbgem/fixtures/const_get/ext/const_get "$work/const_get" > "$work/const_get.log" 2>&1 || rc=$?
check test "$rc" -eq 0
check test ! -e "$work/const_get/NOT_BUILDABLE"
check grep -qF 'return mrb_const_get(mrb, mrb_obj_value(mCG), id);' "$work/const_get/src/const_get.c"
check grep -qF 'mrb_const_get(mrb, mrb_obj_value(mrb->object_class), mrb_intern_cstr(mrb, "String"));' "$work/const_get/src/const_get.c"
rc=0; "$rb" "$conv" --scanner "$scanner" --name const_get_at tools/cext2mrbgem/fixtures/const_get_at/ext/const_get_at "$work/const_get_at" > "$work/const_get_at.log" 2>&1 || rc=$?
check test "$rc" -eq 2
check grep -q '  rb_const_get_at  no exact mruby equivalent' "$work/const_get_at/REFUSALS.txt"

# 2i. helper threading: a helper with a header declaration, called from another file and from a registered
# method, is threaded everywhere (declaration, definition, calls) with a caveat; a helper taken as a value and a
# helper name shadowed by a local stay refused
rc=0; "$rb" "$conv" --scanner "$scanner" --name helper_thread tools/cext2mrbgem/fixtures/helper_thread/ext/helper_thread "$work/helper_thread" > "$work/helper_thread.log" 2>&1 || rc=$?
check test "$rc" -eq 0
check test ! -e "$work/helper_thread/NOT_BUILDABLE"
check grep -qF 'mrb_value ht_wrap(mrb_state *mrb, mrb_value self, mrb_value s);' "$work/helper_thread/include/helper_thread.h"
check grep -qF 'return ht_wrap(mrb, self, s);' "$work/helper_thread/src/helper_thread_other.c"
check grep -qF 'return ht_static(mrb, s);' "$work/helper_thread/src/helper_thread.c"
check grep -q 'mrb-threaded ht_wrap' "$work/helper_thread/conversion_log.json"
rc=0; "$rb" "$conv" --scanner "$scanner" --name helper_thread_refused tools/cext2mrbgem/fixtures/helper_thread_refused/ext/helper_thread_refused "$work/helper_thread_refused" > "$work/helper_thread_refused.log" 2>&1 || rc=$?
check test "$rc" -eq 2
check grep -q '  ht_cb  helper needs the mruby state threaded in, but is used outside a direct call' "$work/helper_thread_refused/REFUSALS.txt"
check grep -q '  ht_shadow_helper  helper needs the mruby state threaded in, but its name is shadowed' "$work/helper_thread_refused/REFUSALS.txt"

# 2i2. a helper whose name is also a struct member (t.tm_isdst, a member of struct tm declared outside the input): the
# member accesses are not uses of the helper, so its direct calls from a registered method alone decide and it takes mrb
rc=0; "$rb" "$conv" --scanner "$scanner" --name helper_member_thread tools/cext2mrbgem/fixtures/helper_member_thread/ext/helper_member_thread "$work/helper_member_thread" > "$work/helper_member_thread.log" 2>&1 || rc=$?
check test "$rc" -eq 0
check test ! -e "$work/helper_member_thread/NOT_BUILDABLE"
check grep -qF 'static mrb_value tm_isdst(mrb_state *mrb, mrb_value s) {' "$work/helper_member_thread/src/helper_member_thread.c"
check grep -qF 'return tm_isdst(mrb, s);' "$work/helper_member_thread/src/helper_member_thread.c"
check grep -qF 't.tm_isdst = 0;' "$work/helper_member_thread/src/helper_member_thread.c"
# negative: a helper whose address is stored in a static table (a file-scope initializer) stays refused, with the reason
rc=0; "$rb" "$conv" --scanner "$scanner" --name helper_table_refused tools/cext2mrbgem/fixtures/helper_table_refused/ext/helper_table_refused "$work/helper_table_refused" > "$work/helper_table_refused.log" 2>&1 || rc=$?
check test "$rc" -eq 2
check test -e "$work/helper_table_refused/NOT_BUILDABLE"
check grep -q '  htr_cb  helper needs the mruby state threaded in, but is used outside a direct call' "$work/helper_table_refused/REFUSALS.txt"

# 2k. global state (no mrb argument): a helper whose only uses are direct calls through a macro expanded in two registered
# methods is not threaded: it uses the file-scope state, defined once in Init's file and declared in the others. Each
# method saves the previous state and restores it on every return (the two returns of hg_pick). No refusal.
rc=0; "$rb" "$conv" --scanner "$scanner" --name helper_global tools/cext2mrbgem/fixtures/helper_global/ext/helper_global "$work/helper_global" > "$work/helper_global.log" 2>&1 || rc=$?
check test "$rc" -eq 0
check test ! -e "$work/helper_global/NOT_BUILDABLE"
check grep -qF 'struct mrb_state *helper_global_bc2_mrb = NULL;' "$work/helper_global/src/helper_global.c"
check grep -qF 'static mrb_value hg_make(mrb_value s) {' "$work/helper_global/src/helper_global.c"
check grep -qF 'return mrb_str_new_cstr(helper_global_bc2_mrb, "made");' "$work/helper_global/src/helper_global.c"
check grep -qF '  mrb_state *nfcx_bc2_old = helper_global_bc2_mrb;' "$work/helper_global/src/helper_global.c"
check test "$(grep -c 'helper_global_bc2_mrb = nfcx_bc2_old; return nfcx_bc2_ret; }' "$work/helper_global/src/helper_global.c")" -eq 3
check grep -qF ' helper_global_bc2_mrb = nfcx_bc2_old; }' "$work/helper_global/src/helper_global.c"
check grep -q 'global-state hg_make' "$work/helper_global/conversion_log.json"

# 2l. global state refused: a helper whose address sits in a file-scope initializer may run with no method context
rc=0; "$rb" "$conv" --scanner "$scanner" --name helper_global_refused tools/cext2mrbgem/fixtures/helper_global_refused/ext/helper_global_refused "$work/helper_global_refused" > "$work/helper_global_refused.log" 2>&1 || rc=$?
check test "$rc" -eq 2
check test -e "$work/helper_global_refused/NOT_BUILDABLE"
check grep -q '  hgr_cb  helper needs the mruby state threaded in, but is used outside a direct call (not supported): its address is in a file-scope initializer' "$work/helper_global_refused/REFUSALS.txt"

# 2j. GC: rb_gc_register_mark_object -> mrb_gc_register (rooted in mruby's table, src/gc.c), rb_gc_start as a statement
# -> mrb_full_gc, rb_gc_writebarrier on plain locals -> immediate-guarded barrier. Each GC form without an exact
# equivalent (address registration, enable/disable, rb_gc_mark with no mark callback, a used rb_gc_start value, a
# non-variable barrier argument) stays refused with its reason.
rc=0; "$rb" "$conv" --scanner "$scanner" --name gc_map tools/cext2mrbgem/fixtures/gc_map/ext/gc_map "$work/gc_map" > "$work/gc_map.log" 2>&1 || rc=$?
check test "$rc" -eq 0
check test ! -e "$work/gc_map/NOT_BUILDABLE"
check grep -qF 'mrb_gc_register(mrb, gcm_cache);' "$work/gc_map/src/gc_map.c"
check grep -qF 'if (mrb_test(force)) mrb_full_gc(mrb);' "$work/gc_map/src/gc_map.c"
check grep -qF 'do { if (!mrb_immediate_p(self)) mrb_field_write_barrier_value(mrb, mrb_basic_ptr(self), v); } while (0);' "$work/gc_map/src/gc_map.c"
rc=0; "$rb" "$conv" --scanner "$scanner" --name gc_map_refused tools/cext2mrbgem/fixtures/gc_map_refused/ext/gc_map_refused "$work/gc_map_refused" > "$work/gc_map_refused.log" 2>&1 || rc=$?
check test "$rc" -eq 2
check test -e "$work/gc_map_refused/NOT_BUILDABLE"
check grep -q '  rb_gc_register_address  address form (VALUE \*)' "$work/gc_map_refused/REFUSALS.txt"
check grep -q '  rb_global_variable  address form' "$work/gc_map_refused/REFUSALS.txt"
check grep -q '  rb_gc_disable  no mruby disable function' "$work/gc_map_refused/REFUSALS.txt"
check grep -q '  rb_gc_enable  no mruby enable function' "$work/gc_map_refused/REFUSALS.txt"
check grep -q '  rb_gc_start  the return value of rb_gc_start (nil) is used' "$work/gc_map_refused/REFUSALS.txt"
check grep -q '  rb_gc_mark  no mark callback in mruby' "$work/gc_map_refused/REFUSALS.txt"
check grep -q '  rb_gc_writebarrier  argument .rb_str_new_cstr("x"). is not a plain local variable' "$work/gc_map_refused/REFUSALS.txt"

# 2k. String, Hash and Array calls with exact mruby equivalents (api_map.json batch B1; header lines in the commit)
rc=0; "$rb" "$conv" --scanner "$scanner" --name api_str_hash_ary tools/cext2mrbgem/fixtures/api_str_hash_ary/ext/api_str_hash_ary "$work/api_str_hash_ary" > "$work/api_str_hash_ary.log" 2>&1 || rc=$?
check test "$rc" -eq 0
check test ! -e "$work/api_str_hash_ary/NOT_BUILDABLE"
check grep -qF 'mrb_str_cat(mrb, dup, "!", 1);' "$work/api_str_hash_ary/src/api_str_hash_ary.c"
check grep -qF 'mrb_str_intern(mrb, dup);' "$work/api_str_hash_ary/src/api_str_hash_ary.c"
check grep -qF 'mrb_check_frozen_value(mrb, s);' "$work/api_str_hash_ary/src/api_str_hash_ary.c"
check grep -qF 'long n = mrb_hash_size(mrb, h);' "$work/api_str_hash_ary/src/api_str_hash_ary.c"
check grep -qF 'mrb_hash_delete_key(mrb, h, k);' "$work/api_str_hash_ary/src/api_str_hash_ary.c"
check grep -qF 'mrb_ary_set(mrb, copy, 0, fresh);' "$work/api_str_hash_ary/src/api_str_hash_ary.c"
check grep -qF 'mrb_ary_new_capa(mrb, 2);' "$work/api_str_hash_ary/src/api_str_hash_ary.c"

# 2l. numeric, symbol, constant, block and type-test calls (api_map.json batch B2). RB_LIKELY and RB_UNLIKELY keep their
# argument as !!(x) (the hint is dropped, the 0 or 1 value kept). RB_TYPE_P of a caveated, unknown or nested form is refused.
rc=0; "$rb" "$conv" --scanner "$scanner" --name api_num_sym_ctl tools/cext2mrbgem/fixtures/api_num_sym_ctl/ext/api_num_sym_ctl "$work/api_num_sym_ctl" > "$work/api_num_sym_ctl.log" 2>&1 || rc=$?
check test "$rc" -eq 0
check test ! -e "$work/api_num_sym_ctl/NOT_BUILDABLE"
check grep -qF 'double d = mrb_as_float(mrb, x);' "$work/api_num_sym_ctl/src/api_num_sym_ctl.c"
check grep -qF 'mrb_float_value(mrb, d * 2.0)' "$work/api_num_sym_ctl/src/api_num_sym_ctl.c"
check grep -qF 'mrb_int_value(mrb, 3)' "$work/api_num_sym_ctl/src/api_num_sym_ctl.c"
check grep -qF 'mrb_sym_name(mrb, id)' "$work/api_num_sym_ctl/src/api_num_sym_ctl.c"
check grep -qF 'mrb_symbol_p(name)' "$work/api_num_sym_ctl/src/api_num_sym_ctl.c"
check grep -qF 'if (mrb_const_defined(mrb, mrb_obj_value(cNumSymBase), id))' "$work/api_num_sym_ctl/src/api_num_sym_ctl.c"
check grep -qF 'if (mrb_block_given_p(mrb))' "$work/api_num_sym_ctl/src/api_num_sym_ctl.c"
check grep -qF 'if ((mrb_type(obj) == MRB_TT_STRING))' "$work/api_num_sym_ctl/src/api_num_sym_ctl.c"
check grep -qF 'if (!!((mrb_type(obj) == MRB_TT_ARRAY)))' "$work/api_num_sym_ctl/src/api_num_sym_ctl.c"
check grep -qF 'if (!!(mrb_nil_p(obj)))' "$work/api_num_sym_ctl/src/api_num_sym_ctl.c"
rc=0; "$rb" "$conv" --scanner "$scanner" --name api_type_refused tools/cext2mrbgem/fixtures/api_type_refused/ext/api_type_refused "$work/api_type_refused" > "$work/api_type_refused.log" 2>&1 || rc=$?
check test "$rc" -eq 2
check test -e "$work/api_type_refused/NOT_BUILDABLE"
check grep -q '  RB_TYPE_P  T_DATA has no exact mruby type' "$work/api_type_refused/REFUSALS.txt"
check grep -q "  RB_TYPE_P  object 'rb_ary_entry(a, 0)' is not a plain local variable" "$work/api_type_refused/REFUSALS.txt"
check grep -q '  RB_TYPE_P  T_FIXNUM has no exact mruby type' "$work/api_type_refused/REFUSALS.txt"
check grep -q '  RB_TYPE_P  T_NIL has no exact mruby type' "$work/api_type_refused/REFUSALS.txt"

# 2m. class-name and method-undef calls (api_map.json batch C1): the class variable is passed as a struct RClass * (not
# wrapped in mrb_obj_value, which the mruby functions do not take)
rc=0; "$rb" "$conv" --scanner "$scanner" --name api_class_undef tools/cext2mrbgem/fixtures/api_class_undef/ext/api_class_undef "$work/api_class_undef" > "$work/api_class_undef.log" 2>&1 || rc=$?
check test "$rc" -eq 0
check test ! -e "$work/api_class_undef/NOT_BUILDABLE"
check grep -qF 'const char *name = mrb_class_name(mrb, cApiBase);' "$work/api_class_undef/src/api_class_undef.c"
check grep -qF 'mrb_undef_method(mrb, cApiBase, "to_s");' "$work/api_class_undef/src/api_class_undef.c"

# 2n. symbol id and integer type tag (api_map.json batch C2): SYM2ID is mrb_symbol, T_FIXNUM is MRB_TT_INTEGER (caveated)
rc=0; "$rb" "$conv" --scanner "$scanner" --name api_sym_type tools/cext2mrbgem/fixtures/api_sym_type/ext/api_sym_type "$work/api_sym_type" > "$work/api_sym_type.log" 2>&1 || rc=$?
check test "$rc" -eq 0
check test ! -e "$work/api_sym_type/NOT_BUILDABLE"
check grep -qF 'mrb_sym id = mrb_symbol(sym);' "$work/api_sym_type/src/api_sym_type.c"
check grep -qF 'if (mrb_type(v) == MRB_TT_INTEGER) return mrb_true_value();' "$work/api_sym_type/src/api_sym_type.c"

# 2o. exception class, warning and GC location (api_map.json batch C3): rb_eNoMemError is the NoMemoryError lookup,
# rb_warning is mrb_warn (always prints; caveated), rb_gc_location is the identity (strip form keeps the call's parentheses)
rc=0; "$rb" "$conv" --scanner "$scanner" --name api_exc_misc tools/cext2mrbgem/fixtures/api_exc_misc/ext/api_exc_misc "$work/api_exc_misc" > "$work/api_exc_misc.log" 2>&1 || rc=$?
check test "$rc" -eq 0
check test ! -e "$work/api_exc_misc/NOT_BUILDABLE"
check grep -qF 'mrb_warn(mrb, "boom check: %s", "start");' "$work/api_exc_misc/src/api_exc_misc.c"
check grep -qF 'mrb_raisef(mrb, mrb_exc_get(mrb, "NoMemoryError"), "out of room");' "$work/api_exc_misc/src/api_exc_misc.c"
check grep -qF 'mrb_value now = (obj);' "$work/api_exc_misc/src/api_exc_misc.c"

# 2p. identifiers the input defines itself: a #define'd macro, a struct tag with a body, and a local variable or
# parameter (every use inside a function that declares it) are local, not refused. Refused: a name used but never
# defined, a fallback #define under #if !defined(...), and a CRuby call in a local macro's body
rc=0; "$rb" "$conv" --scanner "$scanner" --name local_names tools/cext2mrbgem/fixtures/local_names/ext/local_names "$work/local_names" > "$work/local_names.log" 2>&1 || rc=$?
check test "$rc" -eq 0
check test ! -e "$work/local_names/NOT_BUILDABLE"
check grep -qF '#define LN_TWICE(x) ((x) * 2)' "$work/local_names/src/local_names.c"
check grep -qF 'mrb_int_value(mrb, LN_TWICE(n));' "$work/local_names/src/local_names.c"
check grep -qF 'mrb_value rb_ln_out;' "$work/local_names/src/local_names.c"
check grep -qF 'struct rb_ln_state s;' "$work/local_names/src/local_names.c"
check grep -qF 'return mrb_int_value(mrb, LN_ANSWER);' "$work/local_names/src/local_names.c"
rc=0; "$rb" "$conv" --scanner "$scanner" --name local_names_refused tools/cext2mrbgem/fixtures/local_names_refused/ext/local_names_refused "$work/local_names_refused" > "$work/local_names_refused.log" 2>&1 || rc=$?
check test "$rc" -eq 2
check test -e "$work/local_names_refused/NOT_BUILDABLE"
check grep -q '  rb_reg_nth_match  no entry in api_map.json' "$work/local_names_refused/REFUSALS.txt"
check grep -q '  rb_ln_missing  no entry in api_map.json' "$work/local_names_refused/REFUSALS.txt"
check grep -q '  rb_ln_fallback  no entry in api_map.json' "$work/local_names_refused/REFUSALS.txt"
check grep -q '  rb_lnr_proto  no entry in api_map.json' "$work/local_names_refused/REFUSALS.txt"
check test "$(grep -c '  LNR_CALL  ' "$work/local_names_refused/REFUSALS.txt")" -eq 0

# 2q. includes come from api_map.json ("includes"): ruby/ruby.h and ruby/re.h map to their mruby headers; a header with
# no mruby counterpart (ruby/encoding.h) is refused
rc=0; "$rb" "$conv" --scanner "$scanner" --name includes_map tools/cext2mrbgem/fixtures/includes_map/ext/includes_map "$work/includes_map" > "$work/includes_map.log" 2>&1 || rc=$?
check test "$rc" -eq 2
check grep -qF '#include <mruby/re.h>' "$work/includes_map/src/includes_map.c"
check grep -qF '#include <mruby/numeric.h>' "$work/includes_map/src/includes_map.c"
check grep -q '  #include <ruby/encoding.h>  CRuby header not in the supported subset' "$work/includes_map/REFUSALS.txt"

# 2r. exception classes rb_eIndexError and rb_eRangeError (api_map.json batch D1): the class argument of rb_raise
rc=0; "$rb" "$conv" --scanner "$scanner" --name api_exc_index tools/cext2mrbgem/fixtures/api_exc_index/ext/api_exc_index "$work/api_exc_index" > "$work/api_exc_index.log" 2>&1 || rc=$?
check test "$rc" -eq 0
check test ! -e "$work/api_exc_index/NOT_BUILDABLE"
check grep -qF 'mrb_raisef(mrb, E_INDEX_ERROR, "index out of range");' "$work/api_exc_index/src/api_exc_index.c"
check grep -qF 'mrb_raisef(mrb, E_RANGE_ERROR, "value out of range");' "$work/api_exc_index/src/api_exc_index.c"

# 2s. type tags T_TRUE, RUBY_T_STRING, RUBY_T_SYMBOL, T_FALSE and RUBY_T_FIXNUM (api_map.json batch D2): RB_TYPE_P on an
# exact tag compares the mruby type; the caveated tags (T_FALSE, RUBY_T_FIXNUM) are rewritten as plain expressions
rc=0; "$rb" "$conv" --scanner "$scanner" --name api_type_tags tools/cext2mrbgem/fixtures/api_type_tags/ext/api_type_tags "$work/api_type_tags" > "$work/api_type_tags.log" 2>&1 || rc=$?
check test "$rc" -eq 0
check test ! -e "$work/api_type_tags/NOT_BUILDABLE"
check grep -qF '(mrb_type(v) == MRB_TT_TRUE) ? mrb_true_value() : mrb_false_value();' "$work/api_type_tags/src/api_type_tags.c"
check grep -qF '(mrb_type(v) == MRB_TT_STRING) ? mrb_true_value() : mrb_false_value();' "$work/api_type_tags/src/api_type_tags.c"
check grep -qF 'int sym_tag = MRB_TT_SYMBOL;' "$work/api_type_tags/src/api_type_tags.c"
check grep -qF 'int false_tag = MRB_TT_FALSE;' "$work/api_type_tags/src/api_type_tags.c"
check grep -qF 'int fix_tag = MRB_TT_INTEGER;' "$work/api_type_tags/src/api_type_tags.c"

# 2t. String, Array and Hash helpers and RFLOAT_VALUE (api_map.json batch D3): rb_str_freeze, rb_str_append,
# rb_str_resize, rb_assoc_new, rb_hash_dup (call, mrb injected), rb_array_len (RARRAY_LEN) and RFLOAT_VALUE (mrb_float)
rc=0; "$rb" "$conv" --scanner "$scanner" --name api_str_ops tools/cext2mrbgem/fixtures/api_str_ops/ext/api_str_ops "$work/api_str_ops" > "$work/api_str_ops.log" 2>&1 || rc=$?
check test "$rc" -eq 0
check test ! -e "$work/api_str_ops/NOT_BUILDABLE"
check grep -qF 'return mrb_obj_freeze(mrb, str);' "$work/api_str_ops/src/api_str_ops.c"
check grep -qF 'mrb_str_append(mrb, dst, src);' "$work/api_str_ops/src/api_str_ops.c"
check grep -qF 'return mrb_str_resize(mrb, dst, 4);' "$work/api_str_ops/src/api_str_ops.c"
check grep -qF 'mrb_value pair = mrb_assoc_new(mrb, a, b);' "$work/api_str_ops/src/api_str_ops.c"
check grep -qF 'mrb_value copy = mrb_hash_dup(mrb, a);' "$work/api_str_ops/src/api_str_ops.c"
check grep -qF 'long n = RARRAY_LEN(pair);' "$work/api_str_ops/src/api_str_ops.c"
check grep -qF 'double f = mrb_float(b);' "$work/api_str_ops/src/api_str_ops.c"

# 2u. rb_warn, rb_obj_classname, rb_sym2id and rb_sys_fail (api_map.json batch D4): call kinds, each with a caveat
rc=0; "$rb" "$conv" --scanner "$scanner" --name api_msg tools/cext2mrbgem/fixtures/api_msg/ext/api_msg "$work/api_msg" > "$work/api_msg.log" 2>&1 || rc=$?
check test "$rc" -eq 0
check test ! -e "$work/api_msg/NOT_BUILDABLE"
check grep -qF 'const char *name = mrb_obj_classname(mrb, obj);' "$work/api_msg/src/api_msg.c"
check grep -qF 'mrb_warn(mrb, "say: %s", name);' "$work/api_msg/src/api_msg.c"
check grep -qF 'mrb_sym id = mrb_symbol(path);' "$work/api_msg/src/api_msg.c"
check grep -qF 'if (id == 0) mrb_sys_fail(mrb, "open");' "$work/api_msg/src/api_msg.c"

# 2v. rb_define_alias on a tracked class variable (api_map.json batch D5): mrb_define_alias with the class passed unwrapped
rc=0; "$rb" "$conv" --scanner "$scanner" --name api_alias tools/cext2mrbgem/fixtures/api_alias/ext/api_alias "$work/api_alias" > "$work/api_alias.log" 2>&1 || rc=$?
check test "$rc" -eq 0
check test ! -e "$work/api_alias/NOT_BUILDABLE"
check grep -qF 'mrb_define_alias(mrb, cApiAlias, "copy", "orig");' "$work/api_alias/src/api_alias.c"

# 2w. Check_Type and rb_check_type with a literal exact T_ type (api_map.json type_check): mrb_check_type with the MRB_TT_
# tag; T_DATA maps to MRB_TT_CDATA with its caveat logged. Types with no exact mruby tag (T_FIXNUM, T_NIL, T_CLASS) and a
# type argument that is a variable stay refused, and the T_ name of a refused call is not mapped
rc=0; "$rb" "$conv" --scanner "$scanner" --name check_type tools/cext2mrbgem/fixtures/check_type/ext/check_type "$work/check_type" > "$work/check_type.log" 2>&1 || rc=$?
check test "$rc" -eq 0
check test ! -e "$work/check_type/NOT_BUILDABLE"
check grep -qF 'mrb_check_type(mrb, v, MRB_TT_STRING);' "$work/check_type/src/check_type.c"
check grep -qF 'mrb_check_type(mrb, v, MRB_TT_ARRAY);' "$work/check_type/src/check_type.c"
check grep -qF 'mrb_check_type(mrb, v, MRB_TT_CDATA);' "$work/check_type/src/check_type.c"
check grep -q 'CRuby T_DATA also covers TypedData' "$work/check_type/conversion_log.json"
rc=0; "$rb" "$conv" --scanner "$scanner" --name check_type_refused tools/cext2mrbgem/fixtures/check_type_refused/ext/check_type_refused "$work/check_type_refused" > "$work/check_type_refused.log" 2>&1 || rc=$?
check test "$rc" -eq 2
check test -e "$work/check_type_refused/NOT_BUILDABLE"
check test "$(grep -c '  Check_Type  ' "$work/check_type_refused/REFUSALS.txt")" -eq 2
check test "$(grep -c '  rb_check_type  ' "$work/check_type_refused/REFUSALS.txt")" -eq 2
check grep -q '  Check_Type  mruby has one integer tag' "$work/check_type_refused/REFUSALS.txt"
check grep -q '  rb_check_type  nil and false share' "$work/check_type_refused/REFUSALS.txt"
check grep -q 'MRB_TT_CLASS does not match' "$work/check_type_refused/REFUSALS.txt"
check grep -q '  rb_check_type  type argument is not a literal T_ constant' "$work/check_type_refused/REFUSALS.txt"
check sh -c "! grep -q 'MRB_TT_\|mrb_check_type(' '$work/check_type_refused/src/check_type_refused.c'"

# 2zb. built-in class and exception references (api_map.json batch D1): rb_cHash is mrb->hash_class and rb_eKeyError is
# E_KEY_ERROR; both are expressions, so the lookup stays inline at each use
rc=0; "$rb" "$conv" --scanner "$scanner" --name api_class_exc tools/cext2mrbgem/fixtures/api_class_exc/ext/api_class_exc "$work/api_class_exc" > "$work/api_class_exc.log" 2>&1 || rc=$?
check test "$rc" -eq 0
check test ! -e "$work/api_class_exc/NOT_BUILDABLE"
check grep -qF 'mrb_obj_is_kind_of(mrb, obj, mrb->hash_class)' "$work/api_class_exc/src/api_class_exc.c"
check grep -qF 'mrb_obj_is_kind_of(mrb, obj, mrb->string_class)' "$work/api_class_exc/src/api_class_exc.c"
check grep -qF 'mrb_raisef(mrb, E_KEY_ERROR, "missing key");' "$work/api_class_exc/src/api_class_exc.c"

# 2zc. a private registration (api_map.json batch D2): rb_define_private_method takes the rb_define_method path, so the
# function is wrapped with the mruby signature and registered with mrb_define_private_method
rc=0; "$rb" "$conv" --scanner "$scanner" --name api_private_reg tools/cext2mrbgem/fixtures/api_private_reg/ext/api_private_reg "$work/api_private_reg" > "$work/api_private_reg.log" 2>&1 || rc=$?
check test "$rc" -eq 0
check test ! -e "$work/api_private_reg/NOT_BUILDABLE"
check grep -qF 'mrb_define_private_method(mrb, cApiPriv, "secret", api_secret, MRB_ARGS_REQ(1));' "$work/api_private_reg/src/api_private_reg.c"

# 2zd. instance variables named by a string literal (api_map.json batch D3): the name is interned with mrb_intern_cstr
rc=0; "$rb" "$conv" --scanner "$scanner" --name api_ivar_name tools/cext2mrbgem/fixtures/api_ivar_name/ext/api_ivar_name "$work/api_ivar_name" > "$work/api_ivar_name.log" 2>&1 || rc=$?
check test "$rc" -eq 0
check test ! -e "$work/api_ivar_name/NOT_BUILDABLE"
check grep -qF 'mrb_iv_get(mrb, obj, mrb_intern_cstr(mrb, "@count"))' "$work/api_ivar_name/src/api_ivar_name.c"
check grep -qF 'mrb_iv_set(mrb, obj, mrb_intern_cstr(mrb, "@count"), v);' "$work/api_ivar_name/src/api_ivar_name.c"

# 2ze. rb_protect (api_map.json batch P1): the callback is the first argument, called as mrb_func_t (mrb, data), so it is
# threaded with mrb and passed to mrb_protect; the state argument's type is a caveat
rc=0; "$rb" "$conv" --scanner "$scanner" --name api_protect tools/cext2mrbgem/fixtures/api_protect/ext/api_protect "$work/api_protect" > "$work/api_protect.log" 2>&1 || rc=$?
check test "$rc" -eq 0
check test ! -e "$work/api_protect/NOT_BUILDABLE"
check grep -qF 'static mrb_value protect_body(mrb_state *mrb, mrb_value arg) {' "$work/api_protect/src/api_protect.c"
check grep -qF 'mrb_protect(mrb, protect_body, mrb_nil_value(), &state);' "$work/api_protect/src/api_protect.c"

# 2zf. rb_class_new_instance (api_map.json batch N1): the arguments are reordered to mrb_obj_new(mrb, klass, argc, argv)
rc=0; "$rb" "$conv" --scanner "$scanner" --name api_new_inst tools/cext2mrbgem/fixtures/api_new_inst/ext/api_new_inst "$work/api_new_inst" > "$work/api_new_inst.log" 2>&1 || rc=$?
check test "$rc" -eq 0
check test ! -e "$work/api_new_inst/NOT_BUILDABLE"
check grep -qF 'return mrb_obj_new(mrb, cApiNew, argc, argv);' "$work/api_new_inst/src/api_new_inst.c"

# 2zh. rb_sym2str (api_map.json batch N3): the Symbol argument is wrapped with mrb_symbol(...), and mrb is passed first
rc=0; "$rb" "$conv" --scanner "$scanner" --name api_sym_str tools/cext2mrbgem/fixtures/api_sym_str/ext/api_sym_str "$work/api_sym_str" > "$work/api_sym_str.log" 2>&1 || rc=$?
check test "$rc" -eq 0
check test ! -e "$work/api_sym_str/NOT_BUILDABLE"
check grep -qF 'return mrb_sym_str(mrb, mrb_symbol(sym));' "$work/api_sym_str/src/api_sym_str.c"

# 2z. every fixture conversion records the scanner forced for its leg; the libclang leg reads every fixture with libclang
for d in "$work"/*/; do
  check grep -q "\"scanner\": \"$scanner\"" "$d/conversion_log.json"
  if [ "$scanner" = libclang ]; then check sh -c "! grep -q scanner_fallback '$d/conversion_log.json'"; fi
done

# 2x. a registered method that is also called directly is split: the body is <name>_impl (the direct calls go to it),
# the registration keeps <name> for a wrapper with the mruby signature. The impl takes mrb when its body needs it.
rc=0; "$rb" "$conv" --scanner "$scanner" --name reg_split tools/cext2mrbgem/fixtures/reg_split/ext/reg_split "$work/reg_split" > "$work/reg_split.log" 2>&1 || rc=$?
check test "$rc" -eq 0
check test ! -e "$work/reg_split/NOT_BUILDABLE"
check grep -qF 'static mrb_value reg_split_twice_impl(mrb_state *mrb, mrb_value self, mrb_value x) {' "$work/reg_split/src/reg_split.c"
check grep -qF 'static mrb_value reg_split_twice(mrb_state *mrb, mrb_value self) {' "$work/reg_split/src/reg_split.c"
check grep -qF 'return reg_split_twice_impl(mrb, self, x);' "$work/reg_split/src/reg_split.c"
check grep -qF 'mrb_value a = reg_split_twice_impl(mrb, self, self);' "$work/reg_split/src/reg_split.c"
check grep -qF 'static mrb_value reg_split_plain_impl(mrb_value self, mrb_value x) {' "$work/reg_split/src/reg_split.c"
check grep -qF 'mrb_value b = reg_split_plain_impl(self, a);' "$work/reg_split/src/reg_split.c"
check grep -qF 'static mrb_value reg_split_var_impl(int argc, mrb_value *argv, mrb_value self) {' "$work/reg_split/src/reg_split.c"
check grep -qF 'mrb_value c = reg_split_var_impl(0, NULL, self);' "$work/reg_split/src/reg_split.c"
check grep -qF 'return reg_split_var_impl((int)nfcx_argc, argv, self);' "$work/reg_split/src/reg_split.c"
check grep -qF 'mrb_define_method(mrb, mRegSplit, "twice", reg_split_twice, MRB_ARGS_REQ(1));' "$work/reg_split/src/reg_split.c"
check grep -qF 'mrb_define_method(mrb, mRegSplit, "var", reg_split_var, MRB_ARGS_ANY());' "$work/reg_split/src/reg_split.c"
check sh -c "! grep -q 'reg_split_twice(self, self)\|reg_split_plain(self, a)' '$work/reg_split/src/reg_split.c'"
# negative: the direct caller has no mruby state (its address is taken), so the impl cannot take mrb: stays refused, with the reason
rc=0; "$rb" "$conv" --scanner "$scanner" --name reg_split_refused tools/cext2mrbgem/fixtures/reg_split_refused/ext/reg_split_refused "$work/reg_split_refused" > "$work/reg_split_refused.log" 2>&1 || rc=$?
check test "$rc" -eq 2
check test -e "$work/reg_split_refused/NOT_BUILDABLE"
check grep -qF '  rsr_make  registered method function is also called directly (not supported) (its direct caller rsr_plain_caller has no mruby state in scope' "$work/reg_split_refused/REFUSALS.txt"
check sh -c "! grep -q 'rsr_make_impl' '$work/reg_split_refused/src/reg_split_refused.c'"

# 2j. lowercase CRuby APIs (st_*, ruby_*) are refused, not passed silently
ruby tools/cext2mrbgem/convert_mrbgem.rb --name lowercase_api_refused tools/cext2mrbgem/fixtures/lowercase_api_refused/ext/lowercase_api_refused "$work/lowercase_api_refused" > "$work/lowercase_api_refused.log" 2>&1 || rc=$?
check test "$rc" -eq 2
check grep -q "st_init_numtable  no entry in api_map.json" "$work/lowercase_api_refused/REFUSALS.txt"
check grep -q "ruby_xmalloc  no entry in api_map.json" "$work/lowercase_api_refused/REFUSALS.txt"

# 3. bcrypt-ruby at a pinned commit
bcrypt_sha=deb496eaba56077e84bd95ac9bbcca40b6d5d685
if [ -z "${BCRYPT_DIR:-}" ]; then
  BCRYPT_DIR=$root_work/bcrypt-ruby
  if [ ! -d "$BCRYPT_DIR/.git" ]; then
    git init -q "$BCRYPT_DIR"
    git -C "$BCRYPT_DIR" fetch -q --depth 1 https://github.com/codahale/bcrypt-ruby "$bcrypt_sha"
    git -C "$BCRYPT_DIR" checkout -q FETCH_HEAD
  fi
fi
ext=$BCRYPT_DIR/ext/mri
rc=0; "$rb" "$conv" --scanner "$scanner" --name bcrypt "$ext" "$work/bcrypt" > "$work/bcrypt.log" 2>&1 || rc=$?
check test "$rc" -eq 0
check test ! -e "$work/bcrypt/NOT_BUILDABLE"
check grep -q 'void mrb_bcrypt_gem_init(mrb_state \*mrb)' "$work/bcrypt/src/bcrypt_ext.c"
check grep -q 'mrb_gc_protect(mrb, prefix)' "$work/bcrypt/src/bcrypt_ext.c"
check grep -q 'nfcx_thread_call_without_gvl' "$work/bcrypt/src/bcrypt_ext.c"
check grep -q "spec.add_dependency 'mruby-uv'" "$work/bcrypt/mrbgem.rake"
check grep -q '#if 0' "$work/bcrypt/src/crypt.c"
check test "$(grep -c '^warning' "$work/bcrypt.log")" -eq 2

# 4. api_map.json batch A1 (rb_hash_lookup2, rb_str_buf_cat, rb_usascii_str_new*, rb_ll2inum, NUM2UINT, NUM2SIZET,
# FIX2ULONG, OBJ_FREEZE): each name maps with no refusal, the hash mapping adds mruby/hash.h, and caveats are logged
rc=0; "$rb" "$conv" --scanner "$scanner" --name api_fetch_num_str tools/cext2mrbgem/fixtures/api_fetch_num_str/ext/api_fetch_num_str "$work/api_fetch_num_str" > "$work/api_fetch_num_str.log" 2>&1 || rc=$?
check test "$rc" -eq 0
check test ! -e "$work/api_fetch_num_str/NOT_BUILDABLE"
check grep -q 'STATUS: no refusals' "$work/api_fetch_num_str/REFUSALS.txt"
check grep -qF '#include <mruby/hash.h>' "$work/api_fetch_num_str/src/api_fetch_num_str.c"
check grep -qF 'return mrb_hash_fetch(mrb, h, k, dflt);' "$work/api_fetch_num_str/src/api_fetch_num_str.c"
check grep -qF 'mrb_str_cat(mrb, dst, RSTRING_PTR(src), RSTRING_LEN(src));' "$work/api_fetch_num_str/src/api_fetch_num_str.c"
check grep -qF 'return mrb_str_new(mrb, RSTRING_PTR(src), RSTRING_LEN(src));' "$work/api_fetch_num_str/src/api_fetch_num_str.c"
check grep -qF 'mrb_str_new_cstr(mrb, "ok");' "$work/api_fetch_num_str/src/api_fetch_num_str.c"
check grep -qF 'return mrb_int_value(mrb, big);' "$work/api_fetch_num_str/src/api_fetch_num_str.c"
check grep -qF 'unsigned int u = mrb_as_int(mrb, a);' "$work/api_fetch_num_str/src/api_fetch_num_str.c"
check grep -qF 'size_t s = mrb_as_int(mrb, b);' "$work/api_fetch_num_str/src/api_fetch_num_str.c"
check grep -qF 'unsigned long ul = mrb_fixnum(v);' "$work/api_fetch_num_str/src/api_fetch_num_str.c"
check grep -qF 'mrb_obj_freeze(mrb, str);' "$work/api_fetch_num_str/src/api_fetch_num_str.c"
check grep -q 'rb_obj_freeze_inline, ruby/internal/fl_type.h:911' "$work/api_fetch_num_str/conversion_log.json"

# 5. api_map.json batch B1 (rb_obj_is_kind_of, rb_obj_id, CLASS_OF, rb_class_of, rb_include_module, rb_eFrozenError,
# RB_INTEGER_TYPE_P): mapped with no refusal; the class variables in the class-only argument positions are not wrapped
rc=0; "$rb" "$conv" --scanner "$scanner" --name api_obj_class_int tools/cext2mrbgem/fixtures/api_obj_class_int/ext/api_obj_class_int "$work/api_obj_class_int" > "$work/api_obj_class_int.log" 2>&1 || rc=$?
check test "$rc" -eq 0
check test ! -e "$work/api_obj_class_int/NOT_BUILDABLE"
check grep -q 'STATUS: no refusals' "$work/api_obj_class_int/REFUSALS.txt"
check grep -qF '#include <mruby/class.h>' "$work/api_obj_class_int/src/api_obj_class_int.c"
check grep -qF 'return mrb_obj_is_kind_of(mrb, obj, cApiKind);' "$work/api_obj_class_int/src/api_obj_class_int.c"
check grep -qF 'return mrb_obj_id(obj);' "$work/api_obj_class_int/src/api_obj_class_int.c"
check grep -qF 'mrb_value k = mrb_class(mrb, obj);' "$work/api_obj_class_int/src/api_obj_class_int.c"
check grep -qF 'mrb_include_module(mrb, cApiKind, mApiMix);' "$work/api_obj_class_int/src/api_obj_class_int.c"
check grep -qF 'if (mrb_integer_p(v)) return mrb_true_value();' "$work/api_obj_class_int/src/api_obj_class_int.c"
check grep -qF 'mrb_raisef(mrb, E_FROZEN_ERROR, "not an integer");' "$work/api_obj_class_int/src/api_obj_class_int.c"
check sh -c "! grep -q 'mrb_obj_value(cApiKind)\|mrb_obj_value(mApiMix)' '$work/api_obj_class_int/src/api_obj_class_int.c'"

# 5b. names kept refused in batch B1 (no exact mruby equivalent: rb_str_subseq, rb_iv_get, rb_gv_get, rb_sym2str,
# rb_cstr_to_inum, rb_bug, StringValue) stay refused with the no-entry reason, so a later mapping is a deliberate change
rc=0; "$rb" "$conv" --scanner "$scanner" --name api_skipped_refused tools/cext2mrbgem/fixtures/api_skipped_refused/ext/api_skipped_refused "$work/api_skipped_refused" > "$work/api_skipped_refused.log" 2>&1 || rc=$?
check test "$rc" -eq 2
check test -e "$work/api_skipped_refused/NOT_BUILDABLE"
check test "$(grep -c "no entry in api_map.json" "$work/api_skipped_refused/REFUSALS.txt")" -eq 5
check grep -q '  rb_str_subseq  no entry in api_map.json' "$work/api_skipped_refused/REFUSALS.txt"
check grep -q "  rb_iv_get  argument 2 is not a string literal" "$work/api_skipped_refused/REFUSALS.txt"
check grep -q '  StringValue  no entry in api_map.json' "$work/api_skipped_refused/REFUSALS.txt"

# 6. api_map.json batch C1 (RTYPEDDATA_DATA -> DATA_PTR, an lvalue in both): mapped with no refusal, mruby/data.h included
rc=0; "$rb" "$conv" --scanner "$scanner" --name api_typed_ptr tools/cext2mrbgem/fixtures/api_typed_ptr/ext/api_typed_ptr "$work/api_typed_ptr" > "$work/api_typed_ptr.log" 2>&1 || rc=$?
check test "$rc" -eq 0
check test ! -e "$work/api_typed_ptr/NOT_BUILDABLE"
check grep -q 'STATUS: no refusals' "$work/api_typed_ptr/REFUSALS.txt"
check grep -qF '#include <mruby/data.h>' "$work/api_typed_ptr/src/api_typed_ptr.c"
check grep -qF 'void *p = DATA_PTR(obj);' "$work/api_typed_ptr/src/api_typed_ptr.c"
check grep -qF 'DATA_PTR(obj) = NULL;' "$work/api_typed_ptr/src/api_typed_ptr.c"

}

# the regex leg always runs; the libclang leg runs when the library loads
run_leg regex
if "$rb" "$root/tools/cext2mrbgem/decl_scan.rb" --check > "$root_work/libclang_check.txt" 2>&1; then
  run_leg libclang
else
  leg=libclang
  echo "SKIP [libclang] $(cat "$root_work/libclang_check.txt")"
fi
echo

if [ "$fail" -ne 0 ]; then echo "cext2mrbgem tests FAILED"; exit 1; fi
echo "cext2mrbgem tests OK"
