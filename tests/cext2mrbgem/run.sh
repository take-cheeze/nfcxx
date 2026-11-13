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

# 2z. every fixture conversion records the scanner forced for its leg; the libclang leg reads every fixture with libclang
for d in "$work"/*/; do
  check grep -q "\"scanner\": \"$scanner\"" "$d/conversion_log.json"
  if [ "$scanner" = libclang ]; then check sh -c "! grep -q scanner_fallback '$d/conversion_log.json'"; fi
done

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
