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
check grep -qF 'if (mrb_nil_p(klass))' "$work/shadow_param/src/shadow_param.c"
check grep -qF 'static struct RClass *klass;' "$work/shadow_param/src/shadow_param.c"

# 2c'. a registered method named like the header it includes (ruby/encoding.h): its identifier in the include path is not a
# use, so no refusal marker overlaps the include rewrite (used to raise "overlapping edits")
rc=0; "$rb" "$conv" --scanner "$scanner" --name include_name_overlap tools/cext2mrbgem/fixtures/include_name_overlap/ext/include_name_overlap "$work/include_name_overlap" > "$work/include_name_overlap.log" 2>&1 || rc=$?
check ok_rc "$rc"
check sh -c "! grep -q 'overlapping edits\\|Traceback' '$work/include_name_overlap.log'"
check grep -qx '#include <mruby/encoding.h>' "$work/include_name_overlap/src/include_name_overlap.c"

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
check grep -q 'format "1\*1" not supported' "$work/scan_args_refused/REFUSALS.txt"

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
check grep -qF 'BC2CPP-MRBGEM stub: refused code' "$work/module_const_refused/src/module_const_refused.c"

# 2h. rb_const_get maps to mrb_const_get (the receiver as a VALUE, rb_cObject as its VALUE); rb_const_get_at has no
# exact mruby equivalent and stays refused
rc=0; "$rb" "$conv" --scanner "$scanner" --name const_get tools/cext2mrbgem/fixtures/const_get/ext/const_get "$work/const_get" > "$work/const_get.log" 2>&1 || rc=$?
check test "$rc" -eq 0
check test ! -e "$work/const_get/NOT_BUILDABLE"
check grep -qF 'return mrb_const_get(mrb, mrb_obj_value(mCG), id);' "$work/const_get/src/const_get.c"
check grep -qF 'mrb_const_get(mrb, mrb_obj_value(mrb->object_class), mrb_intern_cstr(mrb, "String"));' "$work/const_get/src/const_get.c"
rc=0; "$rb" "$conv" --scanner "$scanner" --name const_get_at tools/cext2mrbgem/fixtures/const_get_at/ext/const_get_at "$work/const_get_at" > "$work/const_get_at.log" 2>&1 || rc=$?
check test "$rc" -eq 0
check grep -qF 'return mrb_const_get_at(mrb, mCGA, version);' "$work/const_get_at/src/const_get_at.c"
rc=0; "$rb" "$conv" --scanner "$scanner" --name const_get_at_value tools/cext2mrbgem/fixtures/const_get_at_value/ext/const_get_at_value "$work/const_get_at_value" > "$work/const_get_at_value.log" 2>&1 || rc=$?
check test "$rc" -eq 0
check grep -qF 'mrb_const_get_at(mrb, mrb_class_ptr(mod), version)' "$work/const_get_at_value/src/const_get_at_value.c"

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
check test "$rc" -eq 0
check test ! -e "$work/helper_table_refused/NOT_BUILDABLE"
check grep -qF 'static mrb_value htr_dispatch(mrb_state *mrb, mrb_value s) {' "$work/helper_table_refused/src/helper_table_refused.c"

# 2k. global state (no mrb argument): a helper whose only uses are direct calls through a macro expanded in two registered
# methods is not threaded: it uses the file-scope state, defined once in Init's file and declared in the others. Each
# method saves the previous state and restores it on every return (the two returns of hg_pick). No refusal.
rc=0; "$rb" "$conv" --scanner "$scanner" --name helper_global tools/cext2mrbgem/fixtures/helper_global/ext/helper_global "$work/helper_global" > "$work/helper_global.log" 2>&1 || rc=$?
check test "$rc" -eq 0
check test ! -e "$work/helper_global/NOT_BUILDABLE"
# the macro HG_MAKE expands in registered methods, which have mrb: the expansion passes that mrb (threaded), so no file-scope state
check grep -qF 'static mrb_value hg_make(mrb_state *mrb, mrb_value s) {' "$work/helper_global/src/helper_global.c"
check grep -qF 'return mrb_str_new_cstr(mrb, "made");' "$work/helper_global/src/helper_global.c"
check grep -qF '#define HG_MAKE(x) hg_make(mrb, x)' "$work/helper_global/src/helper_global.c"
check sh -c "! grep -q helper_global_bc2_mrb '$work/helper_global/src/helper_global.c'"
check grep -qF 'static mrb_value hg_make(mrb_state *mrb, mrb_value s)' "$work/helper_global/conversion_log.json"

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
# rb_gc_enable / rb_gc_disable map to the GC class methods (see 2zzz109), so they are not refused here
check test "$(grep -c '  rb_gc_disable  ' "$work/gc_map_refused/REFUSALS.txt")" -eq 0
check test "$(grep -c '  rb_gc_enable  ' "$work/gc_map_refused/REFUSALS.txt")" -eq 0
check grep -q '  rb_gc_start  the return value of rb_gc_start (nil) is used' "$work/gc_map_refused/REFUSALS.txt"
check grep -q '  rb_gc_mark  stuck point (GC mark callback): rb_gc_mark is valid only in a data type mark callback' "$work/gc_map_refused/REFUSALS.txt"
check grep -q '  rb_gc_writebarrier  argument .rb_str_new_cstr("x"). is not a plain local variable' "$work/gc_map_refused/REFUSALS.txt"

# 2k. String, Hash and Array calls with exact mruby equivalents (api_map.json batch B1; header lines in the commit)
rc=0; "$rb" "$conv" --scanner "$scanner" --name api_str_hash_ary tools/cext2mrbgem/fixtures/api_str_hash_ary/ext/api_str_hash_ary "$work/api_str_hash_ary" > "$work/api_str_hash_ary.log" 2>&1 || rc=$?
check test "$rc" -eq 0
check test ! -e "$work/api_str_hash_ary/NOT_BUILDABLE"
check grep -qF 'mrb_str_cat(mrb, dup, "!", 1);' "$work/api_str_hash_ary/src/api_str_hash_ary.c"
check grep -qF 'mrb_str_intern(mrb, dup);' "$work/api_str_hash_ary/src/api_str_hash_ary.c"
check grep -qF 'mrb_check_frozen(mrb, mrb_ptr(s));' "$work/api_str_hash_ary/src/api_str_hash_ary.c"
check grep -qF 'long n = mrb_hash_size(mrb, h);' "$work/api_str_hash_ary/src/api_str_hash_ary.c"
check grep -qF 'mrb_hash_delete_key(mrb, h, k);' "$work/api_str_hash_ary/src/api_str_hash_ary.c"
check grep -qF 'mrb_ary_set(mrb, copy, 0, fresh);' "$work/api_str_hash_ary/src/api_str_hash_ary.c"
check grep -qF 'mrb_ary_new_capa(mrb, 2);' "$work/api_str_hash_ary/src/api_str_hash_ary.c"

# 2zzz14. allocation, GC, hash, singleton class, alias and string-to-integer calls (api_map.json batch B14). rb_alias maps to
# mrb_alias_method only when its class argument is a tracked class variable (a plain VALUE parameter is refused).
rc=0; "$rb" "$conv" --scanner "$scanner" --name api_alloc_alias tools/cext2mrbgem/fixtures/api_alloc_alias/ext/api_alloc_alias "$work/api_alloc_alias" > "$work/api_alloc_alias.log" 2>&1 || rc=$?
check test "$rc" -eq 0
check test ! -e "$work/api_alloc_alias/NOT_BUILDABLE"
check grep -qF 'mrb_malloc(mrb, sizeof(char) * (16))' "$work/api_alloc_alias/src/api_alloc_alias.c"
check grep -qF 'mrb_funcall_argv(mrb, s, mrb_intern_cstr(mrb, "hash"), 0, NULL)' "$work/api_alloc_alias/src/api_alloc_alias.c"
check grep -qF 'mrb_singleton_class(mrb, s)' "$work/api_alloc_alias/src/api_alloc_alias.c"
check grep -qF 'mrb_str_to_inum(mrb, s, 10, 0)' "$work/api_alloc_alias/src/api_alloc_alias.c"
check grep -qF '((p) = RSTRING_PTR(s), (len) = RSTRING_LEN(s));' "$work/api_alloc_alias/src/api_alloc_alias.c"
check grep -qF 'mrb_full_gc(mrb)' "$work/api_alloc_alias/src/api_alloc_alias.c"
check grep -qF 'mrb_alias_method(mrb, mAl, ia, ib)' "$work/api_alloc_alias/src/api_alloc_alias.c"

# 2zzz15. an ID variable written once in the gem from rb_intern of a literal names that literal in a call (mrb_intern_cstr);
# an ID variable written twice is already an mrb_sym whatever its write order, so the call passes it unchanged.
rc=0; "$rb" "$conv" --scanner "$scanner" --name api_id_global tools/cext2mrbgem/fixtures/api_id_global/ext/api_id_global "$work/api_id_global" > "$work/api_id_global.log" 2>&1 || rc=$?
check test "$rc" -eq 0
check grep -qF 'mrb_funcall_argv(mrb, obj, mrb_intern_cstr(mrb, "hello"), 1, (mrb_value[]){arg});' "$work/api_id_global/src/api_id_global.c"
check grep -qF 'mrb_funcall_argv(mrb, obj, id_twice, 1, (mrb_value[]){arg});' "$work/api_id_global/src/api_id_global.c"

# 2zzz16. a comparison with Qundef inside a condition that also has NIL_P: the Qundef rewrite is part of the comparison,
# so the comparison is converted (mrb_obj_equal with mrb_undef_value()), not refused as overlapping a rewrite.
rc=0; "$rb" "$conv" --scanner "$scanner" --name api_qundef_eq tools/cext2mrbgem/fixtures/api_qundef_eq/ext/api_qundef_eq "$work/api_qundef_eq" > "$work/api_qundef_eq.log" 2>&1 || rc=$?
check test "$rc" -eq 0
check grep -qF 'if (mrb_obj_equal(mrb, mode, mrb_undef_value()) || mrb_nil_p(mode))' "$work/api_qundef_eq/src/api_qundef_eq.c"
check grep -qF 'if (!mrb_obj_equal(mrb, mode, mrb_true_value()))' "$work/api_qundef_eq/src/api_qundef_eq.c"

# 2zzz17. RB_TYPE_P of T_NIL and T_FALSE is the value test (nil and false share mruby's MRB_TT_FALSE tag), not a tag compare.
rc=0; "$rb" "$conv" --scanner "$scanner" --name api_rb_type_p_nil tools/cext2mrbgem/fixtures/api_rb_type_p_nil/ext/api_rb_type_p_nil "$work/api_rb_type_p_nil" > "$work/api_rb_type_p_nil.log" 2>&1 || rc=$?
check test "$rc" -eq 0
check grep -qF 'if (mrb_nil_p(v)) return mrb_true_value();' "$work/api_rb_type_p_nil/src/api_rb_type_p_nil.c"
check grep -qF 'if (mrb_false_p(v)) return mrb_fixnum_value(0);' "$work/api_rb_type_p_nil/src/api_rb_type_p_nil.c"

# 2zzz18. rb_class_new_instance with a literal argc, NULL argv and a VALUE class: the class is unwrapped with mrb_class_ptr.
rc=0; "$rb" "$conv" --scanner "$scanner" --name api_new_value_class tools/cext2mrbgem/fixtures/api_new_value_class/ext/api_new_value_class "$work/api_new_value_class" > "$work/api_new_value_class.log" 2>&1 || rc=$?
check test "$rc" -eq 0
check grep -qF 'nfcx_class_new_instance(mrb, 0, NULL, mrb_class_ptr(klass))' "$work/api_new_value_class/src/api_new_value_class.c"
check grep -qF 'return nfcx_class_new_instance(mrb, 3, argv, mrb->range_class);' "$work/api_new_value_class/src/api_new_value_class.c"

# 2zzz19. rb_ensure with two static VALUE callbacks used only here: both are threaded and the call is mrb_ensure.
rc=0; "$rb" "$conv" --scanner "$scanner" --name api_ensure_call tools/cext2mrbgem/fixtures/api_ensure_call/ext/api_ensure_call "$work/api_ensure_call" > "$work/api_ensure_call.log" 2>&1 || rc=$?
check test "$rc" -eq 0
check grep -qF 'return mrb_ensure(mrb, ec_body, arr, ec_ensure, mrb_nil_value());' "$work/api_ensure_call/src/api_ensure_call.c"
check grep -qF 'static mrb_value ec_body(mrb_state *mrb, mrb_value data) {' "$work/api_ensure_call/src/api_ensure_call.c"

# 2zzz20. a feature test (#ifdef of a CRuby macro) is a conditional directive: its name stays as written, the directive is
# answered by mruby's preprocessor (no RSTRUCT_LEN there), and the name is not refused as an unmapped use.
rc=0; "$rb" "$conv" --scanner "$scanner" --name api_pp_feature tools/cext2mrbgem/fixtures/api_pp_feature/ext/api_pp_feature "$work/api_pp_feature" > "$work/api_pp_feature.log" 2>&1 || rc=$?
check test "$rc" -eq 0
check grep -qF '#ifdef RSTRUCT_LEN' "$work/api_pp_feature/src/api_pp_feature.c"

# 2zzz21. a one-argument conversion whose argument is a call: only the text around the argument is rewritten, so the call
# inside it is converted by its own mapping (rb_funcall2 -> mrb_funcall_argv) and the outer NUM2LL keeps its template.
rc=0; "$rb" "$conv" --scanner "$scanner" --name api_num_call_arg tools/cext2mrbgem/fixtures/api_num_call_arg/ext/api_num_call_arg "$work/api_num_call_arg" > "$work/api_num_call_arg.log" 2>&1 || rc=$?
check test "$rc" -eq 0
check grep -qF 'long long sec = ((long long)mrb_int(mrb, mrb_funcall_argv(mrb, obj, mrb_intern_cstr(mrb, "tv_sec"), 0, 0)));' "$work/api_num_call_arg/src/api_num_call_arg.c"

# 2zzz22. an ID global set lazily (0 when unset, then rb_intern of one literal): a call names the literal.
rc=0; "$rb" "$conv" --scanner "$scanner" --name api_id_lazy tools/cext2mrbgem/fixtures/api_id_lazy/ext/api_id_lazy "$work/api_id_lazy" > "$work/api_id_lazy.log" 2>&1 || rc=$?
check test "$rc" -eq 0
check grep -qF 'mrb_funcall_argv(mrb, obj, mrb_intern_cstr(mrb, "lazy"), 0, NULL)' "$work/api_id_lazy/src/api_id_lazy.c"

# 2zzz23. registration and constants on a CRuby core class (rb_cString) use the mapped mruby class (mrb->string_class).
rc=0; "$rb" "$conv" --scanner "$scanner" --name api_core_class_reg tools/cext2mrbgem/fixtures/api_core_class_reg/ext/api_core_class_reg "$work/api_core_class_reg" > "$work/api_core_class_reg.log" 2>&1 || rc=$?
check test "$rc" -eq 0
check grep -qF 'mrb_define_method(mrb, mrb->string_class, "shout", ccr_shout, MRB_ARGS_NONE());' "$work/api_core_class_reg/src/api_core_class_reg.c"
check grep -qF 'mrb_define_const(mrb, mrb->string_class, "CCR_LIMIT", mrb_fixnum_value(5));' "$work/api_core_class_reg/src/api_core_class_reg.c"

# 2zzz24. a registration on CLASS_OF(cls) of a tracked class targets its singleton class.
rc=0; "$rb" "$conv" --scanner "$scanner" --name api_class_of_target tools/cext2mrbgem/fixtures/api_class_of_target/ext/api_class_of_target "$work/api_class_of_target" > "$work/api_class_of_target.log" 2>&1 || rc=$?
check test "$rc" -eq 0
check grep -qF 'mrb_define_method(mrb, mrb_class_ptr(mrb_singleton_class(mrb, mrb_obj_value(cCot))), "helper", cot_helper, MRB_ARGS_NONE());' "$work/api_class_of_target/src/api_class_of_target.c"

# 2zzz25. rb_scan_args with a keyword part ("11:"): the trailing Hash is taken by mrb_kwargs (empty table, so rest holds the
# whole hash), and an empty result is nil as CRuby gives.
rc=0; "$rb" "$conv" --scanner "$scanner" --name api_scan_kw tools/cext2mrbgem/fixtures/api_scan_kw/ext/api_scan_kw "$work/api_scan_kw" > "$work/api_scan_kw.log" 2>&1 || rc=$?
check test "$rc" -eq 0
check grep -qF 'mrb_get_args(mrb, "o|o:", &a, &b, (const mrb_kwargs[]){{0, NULL, NULL, 0, &kw}})' "$work/api_scan_kw/src/api_scan_kw.c"
check grep -qF 'kw = (mrb_hash_size(mrb, kw) ? kw : mrb_nil_value())' "$work/api_scan_kw/src/api_scan_kw.c"
# 2zzz42. the used return of the keyword form: a statement expression takes the mrb_get_args count, then normalises the hash.
rc=0; "$rb" "$conv" --scanner "$scanner" --name api_scan_kw_used tools/cext2mrbgem/fixtures/api_scan_kw_used/ext/api_scan_kw_used "$work/api_scan_kw_used" > "$work/api_scan_kw_used.log" 2>&1 || rc=$?
check test "$rc" -eq 0
check grep -qF 'int n = ({ kw = mrb_nil_value(); mrb_int nfcx_n = mrb_get_args(mrb, "o:", &a, (const mrb_kwargs[]){{0, NULL, NULL, 0, &kw}}); kw = (mrb_hash_size(mrb, kw) ? kw : mrb_nil_value()); nfcx_n; });' "$work/api_scan_kw_used/src/api_scan_kw_used.c"
# 2zzz31. the used return of rb_scan_args (no keyword part) is the mrb_get_args count (the arguments consumed).
rc=0; "$rb" "$conv" --scanner "$scanner" --name api_scan_used tools/cext2mrbgem/fixtures/api_scan_used/ext/api_scan_used "$work/api_scan_used" > "$work/api_scan_used.log" 2>&1 || rc=$?
check test "$rc" -eq 0
check grep -qF 'int n = (b = mrb_nil_value(), mrb_get_args(mrb, "o|o", &a, &b));' "$work/api_scan_used/src/api_scan_used.c"

# 2zzz26. rb_block_given_p is the fork's mrb_block_given_p (branch claude/block-given-p).
rc=0; "$rb" "$conv" --scanner "$scanner" --name api_block_given tools/cext2mrbgem/fixtures/api_block_given/ext/api_block_given "$work/api_block_given" > "$work/api_block_given.log" 2>&1 || rc=$?
check test "$rc" -eq 0
check grep -qF 'return mrb_block_given_p(mrb) ? mrb_true_value() : mrb_false_value();' "$work/api_block_given/src/api_block_given.c"

# 2zzz27. a two-argument template with a call among its arguments: the separator between them is rewritten, the arguments stay.
rc=0; "$rb" "$conv" --scanner "$scanner" --name api_rational_args tools/cext2mrbgem/fixtures/api_rational_args/ext/api_rational_args "$work/api_rational_args" > "$work/api_rational_args.log" 2>&1 || rc=$?
check test "$rc" -eq 0
check grep -qF 'mrb_funcall_argv(mrb, mrb_top_self(mrb), mrb_intern_cstr(mrb, "Rational"), 2, (mrb_value[]){mrb_funcall_argv(mrb, n, mrb_intern_cstr(mrb, "to_i"), 0, NULL), mrb_fixnum_value(3)});' "$work/api_rational_args/src/api_rational_args.c"

# 2zzz28. RB_TYPE_P(v, T_RATIONAL) is a Rational class test (the gem's Rational class is final in CRuby too).
rc=0; "$rb" "$conv" --scanner "$scanner" --name api_rb_type_rational tools/cext2mrbgem/fixtures/api_rb_type_rational/ext/api_rb_type_rational "$work/api_rb_type_rational" > "$work/api_rb_type_rational.log" 2>&1 || rc=$?
check test "$rc" -eq 0
check grep -qF 'return mrb_obj_is_kind_of(mrb, v, mrb_class_get(mrb, "Rational")) ? mrb_true_value() : mrb_false_value();' "$work/api_rb_type_rational/src/api_rb_type_rational.c"

# 2zzz29. RB_TYPE_P of T_CLASS (classes and singleton classes) and T_MODULE: mruby's MRB_TT_CLASS or MRB_TT_SCLASS, and MRB_TT_MODULE.
rc=0; "$rb" "$conv" --scanner "$scanner" --name api_rb_type_class tools/cext2mrbgem/fixtures/api_rb_type_class/ext/api_rb_type_class "$work/api_rb_type_class" > "$work/api_rb_type_class.log" 2>&1 || rc=$?
check test "$rc" -eq 0
check grep -qF '(mrb_type(v) == MRB_TT_CLASS || mrb_type(v) == MRB_TT_SCLASS) ? mrb_true_value() : mrb_false_value();' "$work/api_rb_type_class/src/api_rb_type_class.c"
check grep -qF 'return mrb_module_p(v) ? mrb_true_value() : mrb_false_value();' "$work/api_rb_type_class/src/api_rb_type_class.c"

# 2zzz30. a data type initializer with a preprocessor line inside its braces: the line is not an element, and the members after
# free (dsize, dcompact) are dropped (mruby never moves objects).
rc=0; "$rb" "$conv" --scanner "$scanner" --name api_dtype_ifdef tools/cext2mrbgem/fixtures/api_dtype_ifdef/ext/api_dtype_ifdef "$work/api_dtype_ifdef" > "$work/api_dtype_ifdef.log" 2>&1 || rc=$?
check test "$rc" -eq 0
check grep -qF 'static const mrb_data_type dt_type = { "DtBox", dt_free, dt_mark };' "$work/api_dtype_ifdef/src/api_dtype_ifdef.c"
# 2zzz33. a data type declared in another file, with a mark function from a third file, and an initializer that leaves out flags.
rc=0; "$rb" "$conv" --scanner "$scanner" --name api_dtype_xfile tools/cext2mrbgem/fixtures/api_dtype_xfile/ext/api_dtype_xfile "$work/api_dtype_xfile" > "$work/api_dtype_xfile.log" 2>&1 || rc=$?
check test "$rc" -eq 0
check grep -qF 'const mrb_data_type xf_type = { "Xf", xf_free, xf_mark };' "$work/api_dtype_xfile/src/xfile_cache.c"
# 2zzz34. a class argument that is a VALUE parameter (rb_obj_is_kind_of(x, c)) is unwrapped with mrb_class_ptr.
rc=0; "$rb" "$conv" --scanner "$scanner" --name api_kind_value tools/cext2mrbgem/fixtures/api_kind_value/ext/api_kind_value "$work/api_kind_value" > "$work/api_kind_value.log" 2>&1 || rc=$?
check test "$rc" -eq 0
check grep -qF 'mrb_obj_is_kind_of(mrb, x, mrb_class_ptr(c))' "$work/api_kind_value/src/api_kind_value.c"
# 2zzz35. a data type with a trailing comma in its braces (mark, free, NULL,): its mark function may call rb_gc_mark.
rc=0; "$rb" "$conv" --scanner "$scanner" --name api_mark_sw tools/cext2mrbgem/fixtures/api_mark_sw/ext/api_mark_sw "$work/api_mark_sw" > "$work/api_mark_sw.log" 2>&1 || rc=$?
check test "$rc" -eq 0
check grep -qF 'mrb_gc_mark_value(mrb, sw->stream);' "$work/api_mark_sw/src/api_mark_sw.c"

# 2zzz36. a class variable declared with others in one statement (VALUE mod, eng;) is typed per declarator, and a helper Init
# function the entry calls is live (it is not kept under #if 0).
rc=0; "$rb" "$conv" --scanner "$scanner" --name api_init_helper tools/cext2mrbgem/fixtures/api_init_helper/ext/api_init_helper "$work/api_init_helper" > "$work/api_init_helper.log" 2>&1 || rc=$?
check test "$rc" -eq 0
check grep -qF 'struct RClass *mod, *eng;' "$work/api_init_helper/src/api_init_helper.c"
check sh -c "! grep -q '#if 0' '$work/api_init_helper/src/api_init_helper.c'"
# 2zzz38. K&R-style prototypes with the _(( )) compatibility macro are ordinary prototypes: the helper is threaded, not refused
# as used at file scope.
rc=0; "$rb" "$conv" --scanner "$scanner" --name api_kr_proto tools/cext2mrbgem/fixtures/api_kr_proto/ext/api_kr_proto "$work/api_kr_proto" > "$work/api_kr_proto.log" 2>&1 || rc=$?
check test "$rc" -eq 0
check grep -qF 'return kp_helper(mrb, v);' "$work/api_kr_proto/src/api_kr_proto.c"
# 2zzz39. a function in a file-scope table of this file: the table is used only in registered methods, so the function runs in a
# method's dynamic extent, where the global state is set (global mode); the table's declaration is not a use.
rc=0; "$rb" "$conv" --scanner "$scanner" --name api_fn_table tools/cext2mrbgem/fixtures/api_fn_table/ext/api_fn_table "$work/api_fn_table" > "$work/api_fn_table.log" 2>&1 || rc=$?
check test "$rc" -eq 0
check grep -qF 'static mrb_value ft_item(mrb_value v) {' "$work/api_fn_table/src/api_fn_table.c"
check grep -qF 'static FtCallbacks ft_cbs = { ft_item };' "$work/api_fn_table/src/api_fn_table.c"
# 2zzz40. an inline rb_intern("lit") argument of a template (an ID position) is the literal's symbol (mrb_intern_cstr).
rc=0; "$rb" "$conv" --scanner "$scanner" --name api_const_intern tools/cext2mrbgem/fixtures/api_const_intern/ext/api_const_intern "$work/api_const_intern" > "$work/api_const_intern.log" 2>&1 || rc=$?
check test "$rc" -eq 0
check grep -qF 'return mrb_const_get_at(mrb, mrb->object_class, mrb_intern_cstr(mrb, "Comparable"));' "$work/api_const_intern/src/api_const_intern.c"
# 2zzz43. rb_streql_lit(s, "add"): the literal is a mruby String (mrb_str_new_cstr) for the mapping's string argument.
rc=0; "$rb" "$conv" --scanner "$scanner" --name api_streql_lit tools/cext2mrbgem/fixtures/api_streql_lit/ext/api_streql_lit "$work/api_streql_lit" > "$work/api_streql_lit.log" 2>&1 || rc=$?
check test "$rc" -eq 0
check grep -qF 'if (mrb_str_equal(mrb, s, mrb_str_new_cstr(mrb, "add"))) return mrb_true_value();' "$work/api_streql_lit/src/api_streql_lit.c"
# 2zzz44. rb_ary_freeze is mrb_obj_freeze (an array is an object).
rc=0; "$rb" "$conv" --scanner "$scanner" --name api_ary_freeze tools/cext2mrbgem/fixtures/api_ary_freeze/ext/api_ary_freeze "$work/api_ary_freeze" > "$work/api_ary_freeze.log" 2>&1 || rc=$?
check test "$rc" -eq 0
check grep -qF 'mrb_obj_freeze(mrb, ary);' "$work/api_ary_freeze/src/api_ary_freeze.c"
# 2zzz49. an object-like alias of a callback (#define alias real_cb) is not a use in its own define line: its invocations are.
rc=0; "$rb" "$conv" --scanner "$scanner" --name api_macro_ret_cb tools/cext2mrbgem/fixtures/api_macro_ret_cb/ext/api_macro_ret_cb "$work/api_macro_ret_cb" > "$work/api_macro_ret_cb.log" 2>&1 || rc=$?
# a truth test of an int call (return mr_run2(...) ? Qtrue : Qfalse) is not an int returned as a VALUE: it converts (no refusal)
check test "$rc" -eq 0
check test ! -e "$work/api_macro_ret_cb/NOT_BUILDABLE"
check grep -qF '? mrb_true_value() : mrb_false_value();' "$work/api_macro_ret_cb/src/api_macro_ret_cb.c"
# 2zzz50. two files each define the same macro (f_negate): a file's macro has only its own file's uses.
mkdir -p tools/cext2mrbgem/fixtures/api_macro_twofile/ext/api_macro_twofile
rc=0; "$rb" "$conv" --scanner "$scanner" --name api_macro_twofile tools/cext2mrbgem/fixtures/api_macro_twofile/ext/api_macro_twofile "$work/api_macro_twofile" > "$work/api_macro_twofile.log" 2>&1 || rc=$?
check test "$rc" -eq 0
check grep -qF '#define tf_neg(x) mrb_funcall_argv(api_macro_twofile_bc2_mrb' "$work/api_macro_twofile/src/tf_other.c"
# 2zzz51. a direct call of a variadic method whose body reads its arguments with rb_scan_args (lead and optional only) is a call of
# the split implementation with the caller's argv (NULL with argc 0), which reads argv with the argc check.
rc=0; "$rb" "$conv" --scanner "$scanner" --name api_direct_scan tools/cext2mrbgem/fixtures/api_direct_scan/ext/api_direct_scan "$work/api_direct_scan" > "$work/api_direct_scan.log" 2>&1 || rc=$?
check test "$rc" -eq 0
check grep -qF 'return ds_inner_impl(mrb, 0, (mrb_value *)NULL, self);' "$work/api_direct_scan/src/api_direct_scan.c"
# 2zzz53. Data_Make_Struct: a static mrb_data_type (threaded mark and free) and a zeroed struct from mrb_calloc.
rc=0; "$rb" "$conv" --scanner "$scanner" --name api_data_make tools/cext2mrbgem/fixtures/api_data_make/ext/api_data_make "$work/api_data_make" > "$work/api_data_make.log" 2>&1 || rc=$?
check test "$rc" -eq 0
check grep -qF 'static const mrb_data_type nfcx_dt_1 = { "DmBox", dm_free, dm_mark };' "$work/api_data_make/src/api_data_make.c"
check grep -qF 'mrb_data_object_alloc(mrb, mrb_class_ptr(klass), (box = (DmBox *)mrb_calloc(mrb, 1, sizeof(DmBox))), &nfcx_dt_1)' "$work/api_data_make/src/api_data_make.c"
# 2zzz54. rb_scan_args with a rest and a block part ("1*&"): mrb_get_args "o*&", the rest array from the pointer and length.
rc=0; "$rb" "$conv" --scanner "$scanner" --name api_scan_rest tools/cext2mrbgem/fixtures/api_scan_rest/ext/api_scan_rest "$work/api_scan_rest" > "$work/api_scan_rest.log" 2>&1 || rc=$?
check test "$rc" -eq 0
check grep -qF 'mrb_get_args(mrb, "o*&", &first, &nfcx_ra, &nfcx_rn, &blk)' "$work/api_scan_rest/src/api_scan_rest.c"
# 2zzz57. switch (rb_type(v)) with case T_NIL: the switch is on (nil test ? 1000 : mrb_type), nil is case 1000.
rc=0; "$rb" "$conv" --scanner "$scanner" --name api_rb_type_switch tools/cext2mrbgem/fixtures/api_rb_type_switch/ext/api_rb_type_switch "$work/api_rb_type_switch" > "$work/api_rb_type_switch.log" 2>&1 || rc=$?
check test "$rc" -eq 0
check grep -qF 'switch ((mrb_nil_p(v) ? 1000 : mrb_type(v))) {' "$work/api_rb_type_switch/src/api_rb_type_switch.c"
check grep -qF 'case 1000 /* nil */: return mrb_str_new_cstr(mrb, "nil");' "$work/api_rb_type_switch/src/api_rb_type_switch.c"
# 2zzz58. switch (rb_type(p->field)): a member-chain subject is side-effect free, so nil is still case 1000.
rc=0; "$rb" "$conv" --scanner "$scanner" --name api_rb_type_member tools/cext2mrbgem/fixtures/api_rb_type_member/ext/api_rb_type_member "$work/api_rb_type_member" > "$work/api_rb_type_member.log" 2>&1 || rc=$?
check test "$rc" -eq 0
check grep -qF 'switch ((mrb_nil_p(parent->val) ? 1000 : mrb_type(parent->val))) {' "$work/api_rb_type_member/src/api_rb_type_member.c"
check grep -qF 'case 1000 /* nil */:' "$work/api_rb_type_member/src/api_rb_type_member.c"
# 2zzz59. rb_obj_is_kind_of(member chain, rb_eException): the exception class is mrb_exc_get, and a member chain is substituted.
rc=0; "$rb" "$conv" --scanner "$scanner" --name api_kind_args tools/cext2mrbgem/fixtures/api_kind_args/ext/api_kind_args "$work/api_kind_args" > "$work/api_kind_args.log" 2>&1 || rc=$?
check test "$rc" -eq 0
check grep -qF 'mrb_obj_is_kind_of(mrb, p.val, mrb_exc_get(mrb, "Exception"))' "$work/api_kind_args/src/api_kind_args.c"
# 2zzz60. rb_ensure with pointer data (VALUE)&arg: the data is mrb_cptr_value, and each callback casts mrb_cptr(a).
rc=0; "$rb" "$conv" --scanner "$scanner" --name api_ensure_ptr tools/cext2mrbgem/fixtures/api_ensure_ptr/ext/api_ensure_ptr "$work/api_ensure_ptr" > "$work/api_ensure_ptr.log" 2>&1 || rc=$?
check test "$rc" -eq 0
check grep -qF 'mrb_ensure(mrb, ensure_body, mrb_cptr_value(mrb, &arg), ensure_done, mrb_cptr_value(mrb, &arg))' "$work/api_ensure_ptr/src/api_ensure_ptr.c"
check grep -qF '(struct EnsureArg *)mrb_cptr(a)' "$work/api_ensure_ptr/src/api_ensure_ptr.c"
# 2zzz61. rb_isdigit (a ctype macro of CRuby, ASCII-only) maps to the C library ctype function.
rc=0; "$rb" "$conv" --scanner "$scanner" --name api_ctype tools/cext2mrbgem/fixtures/api_ctype/ext/api_ctype "$work/api_ctype" > "$work/api_ctype.log" 2>&1 || rc=$?
check test "$rc" -eq 0
check grep -qF 'isdigit((unsigned char)' "$work/api_ctype/src/api_ctype.c"
# 2zzz62. rb_errinfo is mrb->exc with a nil guard (no exception: nil).
rc=0; "$rb" "$conv" --scanner "$scanner" --name api_errinfo tools/cext2mrbgem/fixtures/api_errinfo/ext/api_errinfo "$work/api_errinfo" > "$work/api_errinfo.log" 2>&1 || rc=$?
check test "$rc" -eq 0
check grep -qF '(mrb->exc ? mrb_obj_value(mrb->exc) : mrb_nil_value())' "$work/api_errinfo/src/api_errinfo.c"
# 2zzz63. T_BIGNUM is a recorded stuck point (the fork has no Bignum): the refusal carries that reason.
# 2zzz165. T_BIGNUM is the MRB_TT_BIGINT tag (a bigint is the value outside the fixnum range): a type test and a Check_Type on it.
rc=0; "$rb" "$conv" --scanner "$scanner" --name api_bignum_tag tools/cext2mrbgem/fixtures/api_bignum_tag/ext/api_bignum_tag "$work/api_bignum_tag" > "$work/api_bignum_tag.log" 2>&1 || rc=$?
check test "$rc" -eq 0
check test ! -e "$work/api_bignum_tag/NOT_BUILDABLE"
check grep -qF 'return mrb_type(v) == MRB_TT_BIGINT ? mrb_true_value() : mrb_false_value();' "$work/api_bignum_tag/src/api_bignum_tag.c"
check grep -qF 'mrb_check_type(mrb, v, MRB_TT_BIGINT);' "$work/api_bignum_tag/src/api_bignum_tag.c"
check test "$(grep -c 'stuck point' "$work/api_bignum_tag/REFUSALS.txt")" -eq 0
# 2zzz64. rb_hash_bulk_insert and rb_class_inherited_p map to the fork's mrb_hash_bulk_insert and mrb_class_inherited_p.
rc=0; "$rb" "$conv" --scanner "$scanner" --name api_hash_class tools/cext2mrbgem/fixtures/api_hash_class/ext/api_hash_class "$work/api_hash_class" > "$work/api_hash_class.log" 2>&1 || rc=$?
check test "$rc" -eq 0
check grep -qF 'mrb_hash_bulk_insert(mrb, 4, pairs, h);' "$work/api_hash_class/src/api_hash_class.c"
check grep -qF 'mrb_class_inherited_p(mrb, mrb_class_ptr(sub), mrb_class_ptr(sup))' "$work/api_hash_class/src/api_hash_class.c"
# 2zzz65. rb_apply(recv, mid, args) calls mrb_funcall_argv with the array's elements.
rc=0; "$rb" "$conv" --scanner "$scanner" --name api_apply tools/cext2mrbgem/fixtures/api_apply/ext/api_apply "$work/api_apply" > "$work/api_apply.log" 2>&1 || rc=$?
check test "$rc" -eq 0
check grep -qF 'mrb_funcall_argv(mrb, recv, mrb_intern_cstr(mrb, "to_s"), RARRAY_LEN(args), RARRAY_PTR(args))' "$work/api_apply/src/api_apply.c"
# 2zzz66. A macro whose body calls a state macro needs the state too (nested macros); an unused macro is kept under #if 0.
rc=0; "$rb" "$conv" --scanner "$scanner" --name api_macro_nested tools/cext2mrbgem/fixtures/api_macro_nested/ext/api_macro_nested "$work/api_macro_nested" > "$work/api_macro_nested.log" 2>&1 || rc=$?
check test "$rc" -eq 0
check grep -qF 'static mrb_value nest_sum(mrb_state *mrb, union DD *x)' "$work/api_macro_nested/src/api_macro_nested.c"
# 2zzz67. A direct call with (VALUE *)0 and a class receiver: the receiver is mrb_obj_value of the class.
rc=0; "$rb" "$conv" --scanner "$scanner" --name api_direct_null tools/cext2mrbgem/fixtures/api_direct_null/ext/api_direct_null "$work/api_direct_null" > "$work/api_direct_null.log" 2>&1 || rc=$?
check test "$rc" -eq 0
check grep -qF 'dn_today_impl(0, (mrb_value *)0, mrb_obj_value(mDirectNull))' "$work/api_direct_null/src/api_direct_null.c"
# 2zzz68. rb_copy_generic_ivar(dst, src) maps to mrb_iv_copy(mrb, dst, src).
rc=0; "$rb" "$conv" --scanner "$scanner" --name api_copy_ivar tools/cext2mrbgem/fixtures/api_copy_ivar/ext/api_copy_ivar "$work/api_copy_ivar" > "$work/api_copy_ivar.log" 2>&1 || rc=$?
check test "$rc" -eq 0
check grep -qF 'mrb_iv_copy(mrb, dst, src)' "$work/api_copy_ivar/src/api_copy_ivar.c"
# 2zzz69. rb_check_arity(argc, min, max) raises ArgumentError outside min..max and yields argc.
rc=0; "$rb" "$conv" --scanner "$scanner" --name api_check_arity tools/cext2mrbgem/fixtures/api_check_arity/ext/api_check_arity "$work/api_check_arity" > "$work/api_check_arity.log" 2>&1 || rc=$?
check test "$rc" -eq 0
check grep -qF 'mrb_argnum_error(mrb, argc, 0, 1)' "$work/api_check_arity/src/api_check_arity.c"
# 2zzz70. rb_scan_args("11") in a split method reads lead and optional outputs from its argv array (argc checked).
rc=0; "$rb" "$conv" --scanner "$scanner" --name api_scan_split tools/cext2mrbgem/fixtures/api_scan_split/ext/api_scan_split "$work/api_scan_split" > "$work/api_scan_split.log" 2>&1 || rc=$?
check test "$rc" -eq 0
check grep -qF 'int nfcx_ac = argc; if (nfcx_ac < 1 || nfcx_ac > 2) mrb_argnum_error(mrb, nfcx_ac, 1, 2);' "$work/api_scan_split/src/api_scan_split.c"
check grep -qF 'ss_pick_impl(mrb, 1, &a, self)' "$work/api_scan_split/src/api_scan_split.c"
# 2zzz71. rb_scan_args("1:") in a split method: the trailing Hash is the keyword part (nil when empty), and the count excludes it.
rc=0; "$rb" "$conv" --scanner "$scanner" --name api_scan_kw_split tools/cext2mrbgem/fixtures/api_scan_kw_split/ext/api_scan_kw_split "$work/api_scan_kw_split" > "$work/api_scan_kw_split.log" 2>&1 || rc=$?
check test "$rc" -eq 0
check grep -qF 'if (nfcx_ac > 1 && mrb_hash_p(argv[nfcx_ac - 1])) { opt = argv[--nfcx_ac]; }' "$work/api_scan_kw_split/src/api_scan_kw_split.c"
# 2zzz72. A macro whose body is `if (C) return E` and whose uses are all in registered methods restores the global state itself.
rc=0; "$rb" "$conv" --scanner "$scanner" --name api_macro_ret_restore tools/cext2mrbgem/fixtures/api_macro_ret_restore/ext/api_macro_ret_restore "$work/api_macro_ret_restore" > "$work/api_macro_ret_restore.log" 2>&1 || rc=$?
check test "$rc" -eq 0
check grep -qF '{ mrb_value nfcx_bc2_ret = ( mrb_false_value()); api_macro_ret_restore_bc2_mrb = nfcx_bc2_old; return nfcx_bc2_ret; }' "$work/api_macro_ret_restore/src/api_macro_ret_restore.c"
# 2zzz73. A helper that is not a registered method reads rb_scan_args on its own (argc, argv): the argv form, with the argc check.
rc=0; "$rb" "$conv" --scanner "$scanner" --name api_scan_helper tools/cext2mrbgem/fixtures/api_scan_helper/ext/api_scan_helper "$work/api_scan_helper" > "$work/api_scan_helper.log" 2>&1 || rc=$?
check test "$rc" -eq 0
check grep -qF 'int nfcx_ac = argc; if (nfcx_ac < 1 || nfcx_ac > 2) mrb_argnum_error(mrb, nfcx_ac, 1, 2);' "$work/api_scan_helper/src/api_scan_helper.c"
# 2zzz74. ruby_scan_digits maps to the fork's mrb_scan_digits; its prototype is removed (the fork declares it).
rc=0; "$rb" "$conv" --scanner "$scanner" --name api_scan_digits tools/cext2mrbgem/fixtures/api_scan_digits/ext/api_scan_digits "$work/api_scan_digits" > "$work/api_scan_digits.log" 2>&1 || rc=$?
check test "$rc" -eq 0
check grep -qF 'mrb_scan_digits(p, (ssize_t)n, 10, &n, &ov)' "$work/api_scan_digits/src/api_scan_digits.c"
check test "$(grep -c 'ruby_scan_digits(' "$work/api_scan_digits/src/api_scan_digits.c")" -eq 0
# 2zzz75. rb_strlen_lit("lit") is sizeof of the literal less the terminator.
rc=0; "$rb" "$conv" --scanner "$scanner" --name api_strlen_lit tools/cext2mrbgem/fixtures/api_strlen_lit/ext/api_strlen_lit "$work/api_strlen_lit" > "$work/api_strlen_lit.log" 2>&1 || rc=$?
check test "$rc" -eq 0
check grep -qF '(sizeof(".%N") - 1)' "$work/api_strlen_lit/src/api_strlen_lit.c"
# 2zzz77. rb_str_format(argc, argv, fmt) is the fork's mrb_str_format over the same argv.
rc=0; "$rb" "$conv" --scanner "$scanner" --name api_str_format tools/cext2mrbgem/fixtures/api_str_format/ext/api_str_format "$work/api_str_format" > "$work/api_str_format.log" 2>&1 || rc=$?
check test "$rc" -eq 0
check grep -qF 'mrb_str_format(mrb, 2, args, mrb_str_new_cstr(mrb, "%*d"))' "$work/api_str_format/src/api_str_format.c"
# 2zzz79. #ifndef of a macro the gem defines: the #ifndef branch is inactive, the #else branch is the live one.
rc=0; "$rb" "$conv" --scanner "$scanner" --name api_alt_branch tools/cext2mrbgem/fixtures/api_alt_branch/ext/api_alt_branch "$work/api_alt_branch" > "$work/api_alt_branch.log" 2>&1 || rc=$?
check test "$rc" -eq 0
check grep -qF 'mrb_obj_as_string(api_alt_branch_bc2_mrb, (x))' "$work/api_alt_branch/src/api_alt_branch.c"
# a method entered while another mruby state is active aborts (the global state is one state; a nested one would be wrong)
check grep -qF 'if (nfcx_bc2_old != NULL && nfcx_bc2_old != mrb) abort();' "$work/api_alt_branch/src/api_alt_branch.c"
# 2zzz80. A callee that takes two callbacks: each function-pointer parameter takes its own helper, and both helpers gain mrb.
# (The regex scanner cannot read two parenthesis levels in a parameter list, so it refuses this safely: the test is libclang's.)
if [ "$scanner" = libclang ]; then
rc=0; "$rb" "$conv" --scanner "$scanner" --name api_fnptr_thread tools/cext2mrbgem/fixtures/api_fnptr_thread/ext/api_fnptr_thread "$work/api_fnptr_thread" > "$work/api_fnptr_thread.log" 2>&1 || rc=$?
check test "$rc" -eq 0
check grep -qF 'mrb_value (*conv2)(mrb_state *mrb, mrb_value)' "$work/api_fnptr_thread/src/api_fnptr_thread.c"
# 2zzz81. A file-scope table of dump functions: the table's type and its entries take mrb, and a dispatch helper calls through it.
rc=0; "$rb" "$conv" --scanner "$scanner" --name api_dispatch_table tools/cext2mrbgem/fixtures/api_dispatch_table/ext/api_dispatch_table "$work/api_dispatch_table" > "$work/api_dispatch_table.log" 2>&1 || rc=$?
check test "$rc" -eq 0
check grep -qF 'typedef void (*DumpFunc)(mrb_state *mrb, mrb_value obj, int depth);' "$work/api_dispatch_table/src/api_dispatch_table.c"
check grep -qF 'dt_funcs[mrb_nil_p(obj) ? 0 : 1](mrb, obj, depth);' "$work/api_dispatch_table/src/api_dispatch_table.c"
# 2zzz82. rb_ivar_foreach(obj, callback, data) is the fork's mrb_iv_foreach; the callback takes (mrb, sym, value, void *).
rc=0; "$rb" "$conv" --scanner "$scanner" --name api_ivar_foreach tools/cext2mrbgem/fixtures/api_ivar_foreach/ext/api_ivar_foreach "$work/api_ivar_foreach" > "$work/api_ivar_foreach.log" 2>&1 || rc=$?
check test "$rc" -eq 0
check grep -qF 'mrb_iv_foreach(mrb, obj, iv_count_cb, (void *)&count);' "$work/api_ivar_foreach/src/api_ivar_foreach.c"
# 2zzz83. rb_complex_new / rb_complex_real / rb_complex_imag map to the complex mrbgem's Kernel#Complex, #real and #imaginary.
rc=0; "$rb" "$conv" --scanner "$scanner" --name api_complex tools/cext2mrbgem/fixtures/api_complex/ext/api_complex "$work/api_complex" > "$work/api_complex.log" 2>&1 || rc=$?
check test "$rc" -eq 0
check grep -qF 'mrb_funcall(mrb, mrb_top_self(mrb), "Complex", 2, re, im)' "$work/api_complex/src/api_complex.c"
check grep -qF 'mrb_funcall(mrb, c, "imaginary", 0)' "$work/api_complex/src/api_complex.c"
# 2zzz84. rb_time_timespec(t) reads the seconds (to_i) and the nanoseconds (usec * 1000) of a Time from the mruby-time gem.
rc=0; "$rb" "$conv" --scanner "$scanner" --name api_time_ts tools/cext2mrbgem/fixtures/api_time_ts/ext/api_time_ts "$work/api_time_ts" > "$work/api_time_ts.log" 2>&1 || rc=$?
check test "$rc" -eq 0
check grep -qF '.tv_sec = mrb_fixnum(mrb_funcall(mrb, t, "to_i", 0))' "$work/api_time_ts/src/api_time_ts.c"
# 2zzz85. rb_ivar_count(obj) is the length of the object's instance variable names.
rc=0; "$rb" "$conv" --scanner "$scanner" --name api_ivar_count tools/cext2mrbgem/fixtures/api_ivar_count/ext/api_ivar_count "$work/api_ivar_count" > "$work/api_ivar_count.log" 2>&1 || rc=$?
check test "$rc" -eq 0
check grep -qF '(size_t)RARRAY_LEN(mrb_obj_instance_variables(mrb, obj))' "$work/api_ivar_count/src/api_ivar_count.c"
# 2zzz86. rb_range_values(r, &beg, &end, &excl) reads the Range's edges through the fork's accessors (range.h is included).
rc=0; "$rb" "$conv" --scanner "$scanner" --name api_range_values tools/cext2mrbgem/fixtures/api_range_values/ext/api_range_values "$work/api_range_values" > "$work/api_range_values.log" 2>&1 || rc=$?
check test "$rc" -eq 0
check grep -qF '*(&beg) = RANGE_BEG(mrb_range_ptr(mrb, r))' "$work/api_range_values/src/api_range_values.c"
check grep -qF '#include <mruby/range.h>' "$work/api_range_values/src/api_range_values.c"
# 2zzz87. rb_time_timespec_new with a fixed offset maps to the fork's fixed-offset Time (mrb_time_at_offset).
rc=0; "$rb" "$conv" --scanner "$scanner" --name api_time_new tools/cext2mrbgem/fixtures/api_time_new/ext/api_time_new "$work/api_time_new" > "$work/api_time_new.log" 2>&1 || rc=$?
check test "$rc" -eq 0
# the fork has fixed-offset Time (mrb_time_at_offset): rb_time_timespec_new maps to it, so no Time-offset refusal
check grep -q 'nfcx_time_timespec_new' "$work/api_time_new/src/api_time_new.c"
# 2zzz92. A file-scope table used from a registered method: a member of the same name, a prototype parameter and a shadowing
# parameter are not uses of the table, so the table's callbacks convert (yajl's callbacks table).
rc=0; "$rb" "$conv" --scanner "$scanner" --name api_tbl_names tools/cext2mrbgem/fixtures/api_tbl_names/ext/api_tbl_names "$work/api_tbl_names" > "$work/api_tbl_names.log" 2>&1 || rc=$?
check test "$rc" -eq 0
check grep -qF 'h.cbs->on_null(ctx)' "$work/api_tbl_names/src/api_tbl_names.c"
# 2zzz93. A struct field whose type is a typedef'd function pointer: its assigned helper and calls convert; the comparison of a
# helper with the field is not a use that escapes.
rc=0; "$rb" "$conv" --scanner "$scanner" --name api_fnptr_typedef tools/cext2mrbgem/fixtures/api_fnptr_typedef/ext/api_fnptr_typedef "$work/api_fnptr_typedef" > "$work/api_fnptr_typedef.log" 2>&1 || rc=$?
check test "$rc" -eq 0
check grep -qF 'if (h.dump == ftd_attrs) {' "$work/api_fnptr_typedef/src/api_fnptr_typedef.c"
# 2zzz95. RB_OBJ_WRITE with a call as its value and a field address: mrb_write_field takes each argument once, in order.
rc=0; "$rb" "$conv" --scanner "$scanner" --name api_obj_write tools/cext2mrbgem/fixtures/api_obj_write/ext/api_obj_write "$work/api_obj_write" > "$work/api_obj_write.log" 2>&1 || rc=$?
check test "$rc" -eq 0
check grep -qF 'mrb_write_field(mrb, holder, &box->v, ow_canon(val));' "$work/api_obj_write/src/api_obj_write.c"
# 2zzz96. rb_hash_aset used as a value returns the stored value (the fork's mrb_hash_set_value).
rc=0; "$rb" "$conv" --scanner "$scanner" --name api_hash_aset_value tools/cext2mrbgem/fixtures/api_hash_aset_value/ext/api_hash_aset_value "$work/api_hash_aset_value" > "$work/api_hash_aset_value.log" 2>&1 || rc=$?
check test "$rc" -eq 0
check grep -qF 'mrb_hash_set_value(mrb, h, k, v)' "$work/api_hash_aset_value/src/api_hash_aset_value.c"
# 2zzz98. A helper called from a macro that is itself used in a macro body: the nesting is followed to the functions that expand it.
rc=0; "$rb" "$conv" --scanner "$scanner" --name api_macro_nested tools/cext2mrbgem/fixtures/api_macro_nested/ext/api_macro_nested "$work/api_macro_nested2" > "$work/api_macro_nested2.log" 2>&1 || rc=$?
check test "$rc" -eq 0
# 2zzz94. An inline static function defined in two .c files is renamed per file (as a plain static is).
rc=0; "$rb" "$conv" --scanner "$scanner" --name api_inline_static tools/cext2mrbgem/fixtures/api_inline_static/ext/api_inline_static "$work/api_inline_static" > "$work/api_inline_static.log" 2>&1 || rc=$?
check test "$rc" -eq 0
check grep -qF 'is_first__other' "$work/api_inline_static/src/other.c"
# 2zzz90. A helper defined in a header included by exactly one source converts with that source (its registered callers too).
rc=0; "$rb" "$conv" --scanner "$scanner" --name api_header_single tools/cext2mrbgem/fixtures/api_header_single/ext/api_header_single "$work/api_header_single" > "$work/api_header_single.log" 2>&1 || rc=$?
check test "$rc" -eq 0
check grep -qF 'mrb_funcall' "$work/api_header_single/include/helper.h"
# 2zzz88. rb_method_boundp(obj, id, 1) is mrb_respond_to; rb_proc_call_with_block(proc, argc, argv, Qnil) is a call of the proc.
rc=0; "$rb" "$conv" --scanner "$scanner" --name api_proc_method tools/cext2mrbgem/fixtures/api_proc_method/ext/api_proc_method "$work/api_proc_method" > "$work/api_proc_method.log" 2>&1 || rc=$?
check test "$rc" -eq 0
check grep -qF 'mrb_respond_to(mrb, obj, pm_hset_id)' "$work/api_proc_method/src/api_proc_method.c"
check grep -qF 'mrb_funcall_argv(mrb, proc, mrb_intern_cstr(mrb, "call"), 1, &arg)' "$work/api_proc_method/src/api_proc_method.c"
check grep -qF '(*conv2)(mrb, c)' "$work/api_fnptr_thread/src/api_fnptr_thread.c"
fi
# 2zzz78. A macro expanded only in inactive code converts without refusal (its expansions are dead).
rc=0; "$rb" "$conv" --scanner "$scanner" --name api_dead_use tools/cext2mrbgem/fixtures/api_dead_use/ext/api_dead_use "$work/api_dead_use2" > "$work/api_dead_use2.log" 2>&1 || rc=$?
check test "$rc" -eq 0
# 2zzz76. A use of a helper in inactive code (#if 0) is not a use: the converter does not refuse it, and the live code converts.
rc=0; "$rb" "$conv" --scanner "$scanner" --name api_dead_use tools/cext2mrbgem/fixtures/api_dead_use/ext/api_dead_use "$work/api_dead_use" > "$work/api_dead_use.log" 2>&1 || rc=$?
check test "$rc" -eq 0
check grep -qF '#if 0' "$work/api_dead_use/src/api_dead_use.c"  # the inactive block stays inactive (its text is not compiled)
check grep -qF 'du_dead(' "$work/api_dead_use/src/api_dead_use.c"
# 2zzz91. Direct name mappings: rb_attr_get, rb_check_hash_type, rb_struct_aset, RB_EXT_RACTOR_SAFE, RUBY_Qnil.
rc=0; "$rb" "$conv" --scanner "$scanner" --name api_misc_names tools/cext2mrbgem/fixtures/api_misc_names/ext/api_misc_names "$work/api_misc_names" > "$work/api_misc_names.log" 2>&1 || rc=$?
check test "$rc" -eq 0
check grep -qF 'mrb_iv_get(mrb, obj, mrb_intern_cstr(mrb, "@x"))' "$work/api_misc_names/src/api_misc_names.c"
check grep -qF 'mrb_check_hash_type(mrb, v)' "$work/api_misc_names/src/api_misc_names.c"
check grep -qF 'mrb_funcall(mrb, s, "[]=", 2, mrb_fixnum_value(0), v)' "$work/api_misc_names/src/api_misc_names.c"
# 2zzz89. #ifdef _WIN32 is inactive on the non-Windows target: a Windows-only call inside it is not refused.
rc=0; "$rb" "$conv" --scanner "$scanner" --name api_win_branch tools/cext2mrbgem/fixtures/api_win_branch/ext/api_win_branch "$work/api_win_branch" > "$work/api_win_branch.log" 2>&1 || rc=$?
check test "$rc" -eq 0
check test ! -e "$work/api_win_branch/REFUSALS.txt" -o "$(grep -c rb_w32 "$work/api_win_branch/REFUSALS.txt" 2>/dev/null)" = 0
check grep -qF '#if 0  /* BC2CPP-MRBGEM: unused macro' "$work/api_macro_nested/src/api_macro_nested.c"
# 2zzz56. rb_intern3(str, len, enc) with expression arguments: the encoding is dropped (a pure encoding getter), the rest converts.
rc=0; "$rb" "$conv" --scanner "$scanner" --name api_intern3 tools/cext2mrbgem/fixtures/api_intern3/ext/api_intern3 "$work/api_intern3" > "$work/api_intern3.log" 2>&1 || rc=$?
check test "$rc" -eq 0
check grep -qF 'mrb_intern(mrb, RSTRING_PTR(v) + 1, ((long)mrb_int(mrb, n)) + 1)' "$work/api_intern3/src/api_intern3.c"
# 2zzz55. Check_Type(v, T_CLASS): a class or singleton class (MRB_TT_CLASS or MRB_TT_SCLASS), TypeError otherwise.
rc=0; "$rb" "$conv" --scanner "$scanner" --name api_check_class tools/cext2mrbgem/fixtures/api_check_class/ext/api_check_class "$work/api_check_class" > "$work/api_check_class.log" 2>&1 || rc=$?
check test "$rc" -eq 0
check grep -qF 'mrb_type(v) == MRB_TT_CLASS || mrb_type(v) == MRB_TT_SCLASS ? (void)0' "$work/api_check_class/src/api_check_class.c"
check grep -qF 'rest = mrb_ary_new_from_values(mrb, nfcx_rn, nfcx_ra);' "$work/api_scan_rest/src/api_scan_rest.c"
# 2zzz52. a cast function-pointer table (VALUE (*)(void *))fn of this file: its callbacks run in global mode, and the table's
# type name (struct ct_funcs) is not a use of the table.
rc=0; "$rb" "$conv" --scanner "$scanner" --name api_cast_table tools/cext2mrbgem/fixtures/api_cast_table/ext/api_cast_table "$work/api_cast_table" > "$work/api_cast_table.log" 2>&1 || rc=$?
check test "$rc" -eq 0
check grep -qF '(mrb_value (*)(void *))ct_secs,' "$work/api_cast_table/src/api_cast_table.c"
# 2zzz47. a callback passed as an argument of a file-scope macro: the macro escapes the pointer only if its body does, and here
# the body passes it to a helper that calls it and keeps nothing; the callback is threaded and the macro call converted.
rc=0; "$rb" "$conv" --scanner "$scanner" --name api_macro_cb tools/cext2mrbgem/fixtures/api_macro_cb/ext/api_macro_cb "$work/api_macro_cb" > "$work/api_macro_cb.log" 2>&1 || rc=$?
check test "$rc" -eq 0
check grep -qF '#define MC_RUN(m, h, c) mc_call(mrb, m, c, h)' "$work/api_macro_cb/src/api_macro_cb.c"
# 2zzz48. a value use of a CRuby setter whose mruby function returns void (rb_hash_aset) is refused; a statement use converts.
rc=0; "$rb" "$conv" --scanner "$scanner" --name api_value_lost tools/cext2mrbgem/fixtures/api_value_lost/ext/api_value_lost "$work/api_value_lost" > "$work/api_value_lost.log" 2>&1 || rc=$?
check test "$rc" -eq 2
check grep -q '  rb_ivar_set  rb_ivar_set returns its value in CRuby' "$work/api_value_lost/REFUSALS.txt"
# 2zzz46. a function defined in both branches of an #ifdef: the active definition is threaded and converted, the inactive one
# stays as written (its #ifdef is false in this build), and the registration on a VALUE parameter is unwrapped.
rc=0; "$rb" "$conv" --scanner "$scanner" --name api_dup_variant tools/cext2mrbgem/fixtures/api_dup_variant/ext/api_dup_variant "$work/api_dup_variant" > "$work/api_dup_variant.log" 2>&1 || rc=$?
check test "$rc" -eq 0
check grep -qF 'mrb_define_module_function(mrb, mrb_class_ptr(m), "hi", dv_hi, MRB_ARGS_NONE());' "$work/api_dup_variant/src/api_dup_variant.c"
check grep -qF 'dv_setup(mrb, mrb_obj_value(mDv));' "$work/api_dup_variant/src/api_dup_variant.c"
# 2zzz45. PRIsVALUE in an rb_sprintf format: %S and %!S (the same conversion as in rb_raise).
rc=0; "$rb" "$conv" --scanner "$scanner" --name api_sprintf_pv tools/cext2mrbgem/fixtures/api_sprintf_pv/ext/api_sprintf_pv "$work/api_sprintf_pv" > "$work/api_sprintf_pv.log" 2>&1 || rc=$?
check test "$rc" -eq 0
check grep -qF 'mrb_format(mrb, "#<%""S"" value=%!""S"">", mrb_obj_value(mrb_obj_class(mrb, v)), v);' "$work/api_sprintf_pv/src/api_sprintf_pv.c"
# 2zzz41. a VALUE comparison in a function without the mruby state is mrb_value_identical (the fork's stateless identity).
rc=0; "$rb" "$conv" --scanner "$scanner" --name api_eq_stateless tools/cext2mrbgem/fixtures/api_eq_stateless/ext/api_eq_stateless "$work/api_eq_stateless" > "$work/api_eq_stateless.log" 2>&1 || rc=$?
check test "$rc" -eq 0
check grep -qF 'return mrb_value_identical(a, b) ? mrb_true_value() : mrb_false_value();' "$work/api_eq_stateless/src/api_eq_stateless.c"
# 2zzz37. a mixed declaration: VALUE, a class declarator (with a call), VALUE. The types change at the commas.
rc=0; "$rb" "$conv" --scanner "$scanner" --name api_decl_mixed tools/cext2mrbgem/fixtures/api_decl_mixed/ext/api_decl_mixed "$work/api_decl_mixed" > "$work/api_decl_mixed.log" 2>&1 || rc=$?
check test "$rc" -eq 0
check grep -qF 'mrb_value a = mrb_nil_value(); struct RClass *eng = mrb_define_class(mrb, "DeclMixed", mrb->object_class); mrb_value b = mrb_nil_value();' "$work/api_decl_mixed/src/api_decl_mixed.c"

# 2l. numeric, symbol, constant, block and type-test calls (api_map.json batch B2). RB_LIKELY and RB_UNLIKELY keep their
# argument as !!(x) (the hint is dropped, the 0 or 1 value kept). RB_TYPE_P of a caveated, unknown or nested form is refused.
rc=0; "$rb" "$conv" --scanner "$scanner" --name api_num_sym_ctl tools/cext2mrbgem/fixtures/api_num_sym_ctl/ext/api_num_sym_ctl "$work/api_num_sym_ctl" > "$work/api_num_sym_ctl.log" 2>&1 || rc=$?
check test "$rc" -eq 0
check test ! -e "$work/api_num_sym_ctl/NOT_BUILDABLE"
check grep -qF 'double d = mrb_to_flo(mrb, x);' "$work/api_num_sym_ctl/src/api_num_sym_ctl.c"
check grep -qF 'mrb_float_value(mrb, d * 2.0)' "$work/api_num_sym_ctl/src/api_num_sym_ctl.c"
check grep -qF 'mrb_fixnum_value(3)' "$work/api_num_sym_ctl/src/api_num_sym_ctl.c"
check grep -qF 'mrb_sym_name(mrb, id)' "$work/api_num_sym_ctl/src/api_num_sym_ctl.c"
check grep -qF 'mrb_symbol_p(name)' "$work/api_num_sym_ctl/src/api_num_sym_ctl.c"
check grep -qF 'if (mrb_const_defined(mrb, mrb_obj_value(cNumSymBase), id))' "$work/api_num_sym_ctl/src/api_num_sym_ctl.c"
check grep -qF 'if ((mrb_type(obj) == MRB_TT_STRING))' "$work/api_num_sym_ctl/src/api_num_sym_ctl.c"
check grep -qF 'if (!!((mrb_type(obj) == MRB_TT_ARRAY)))' "$work/api_num_sym_ctl/src/api_num_sym_ctl.c"
check grep -qF 'if (!!(mrb_nil_p(obj)))' "$work/api_num_sym_ctl/src/api_num_sym_ctl.c"
rc=0; "$rb" "$conv" --scanner "$scanner" --name api_type_refused tools/cext2mrbgem/fixtures/api_type_refused/ext/api_type_refused "$work/api_type_refused" > "$work/api_type_refused.log" 2>&1 || rc=$?
check test "$rc" -eq 2
check test -e "$work/api_type_refused/NOT_BUILDABLE"
# T_DATA and T_FIXNUM are the api_map's caveat forms (type_check "caveat"): converted to their MRB_TT_ tags, not refused
check test "$(grep -c '  RB_TYPE_P  T_DATA has no exact' "$work/api_type_refused/REFUSALS.txt")" -eq 0
check grep -qF 'MRB_TT_DATA' "$work/api_type_refused/src/api_type_refused.c"
check test "$(grep -c '  RB_TYPE_P  T_FIXNUM has no exact' "$work/api_type_refused/REFUSALS.txt")" -eq 0
check grep -qF 'MRB_TT_FIXNUM' "$work/api_type_refused/src/api_type_refused.c"
check grep -q "  RB_TYPE_P  object 'rb_ary_entry(a, 0)' is not a plain local variable" "$work/api_type_refused/REFUSALS.txt"
# T_BIGNUM is the MRB_TT_BIGINT tag now (api_map: the bigint of the fork), not refused
check grep -qF 'MRB_TT_BIGINT' "$work/api_type_refused/src/api_type_refused.c"

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
check grep -qF 'if (mrb_type(v) == MRB_TT_FIXNUM) return mrb_true_value();' "$work/api_sym_type/src/api_sym_type.c"

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
check grep -qF 'mrb_fixnum_value(LN_TWICE(n));' "$work/local_names/src/local_names.c"
check grep -qF 'mrb_value rb_ln_out;' "$work/local_names/src/local_names.c"
check grep -qF 'struct rb_ln_state s;' "$work/local_names/src/local_names.c"
check grep -qF 'return mrb_fixnum_value(LN_ANSWER);' "$work/local_names/src/local_names.c"
rc=0; "$rb" "$conv" --scanner "$scanner" --name local_names_refused tools/cext2mrbgem/fixtures/local_names_refused/ext/local_names_refused "$work/local_names_refused" > "$work/local_names_refused.log" 2>&1 || rc=$?
check test "$rc" -eq 2
check test -e "$work/local_names_refused/NOT_BUILDABLE"
check grep -q '  rb_memcicmp  no entry in api_map.json' "$work/local_names_refused/REFUSALS.txt"
check grep -q '  rb_ln_missing  no entry in api_map.json' "$work/local_names_refused/REFUSALS.txt"
check grep -q '  rb_ln_fallback  no entry in api_map.json' "$work/local_names_refused/REFUSALS.txt"
check grep -q '  rb_lnr_proto  no entry in api_map.json' "$work/local_names_refused/REFUSALS.txt"
check test "$(grep -c '  LNR_CALL  ' "$work/local_names_refused/REFUSALS.txt")" -eq 0

# 2q. includes come from api_map.json ("includes"): ruby/ruby.h maps to its mruby headers, ruby/re.h to the fork's mruby/onigmo.h
# (the Onigmo API on the system oniguruma library), and ruby/encoding.h to the fork's mruby/encoding.h (the pinned fork has it)
rc=0; "$rb" "$conv" --scanner "$scanner" --name includes_map tools/cext2mrbgem/fixtures/includes_map/ext/includes_map "$work/includes_map" > "$work/includes_map.log" 2>&1 || rc=$?
check test "$rc" -eq 0
check grep -qF '#include <mruby/onigmo.h>' "$work/includes_map/src/includes_map.c"
check grep -qF '#include <mruby/numeric.h>' "$work/includes_map/src/includes_map.c"
check grep -qF '#include <mruby/encoding.h>' "$work/includes_map/src/includes_map.c"

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
check grep -qF 'int fix_tag = MRB_TT_FIXNUM;' "$work/api_type_tags/src/api_type_tags.c"

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
check grep -qF 'mrb_check_type(mrb, v, MRB_TT_DATA);' "$work/check_type/src/check_type.c"
check grep -q 'CRuby T_DATA also covers TypedData' "$work/check_type/conversion_log.json"
rc=0; "$rb" "$conv" --scanner "$scanner" --name check_type_refused tools/cext2mrbgem/fixtures/check_type_refused/ext/check_type_refused "$work/check_type_refused" > "$work/check_type_refused.log" 2>&1 || rc=$?
check test "$rc" -eq 2
check test -e "$work/check_type_refused/NOT_BUILDABLE"
check test "$(grep -c '  Check_Type  ' "$work/check_type_refused/REFUSALS.txt")" -eq 1
check test "$(grep -c '  rb_check_type  ' "$work/check_type_refused/REFUSALS.txt")" -eq 2
check grep -qF 'mrb_check_type(mrb, v, MRB_TT_FIXNUM);' "$work/check_type_refused/src/check_type_refused.c"
check grep -q '  rb_check_type  nil and false share' "$work/check_type_refused/REFUSALS.txt"
check grep -q 'MRB_TT_OBJECT does not match' "$work/check_type_refused/REFUSALS.txt"
check grep -q '  rb_check_type  type argument is not a literal T_ constant' "$work/check_type_refused/REFUSALS.txt"
check sh -c "! grep -q 'MRB_TT_OBJECT\|MRB_TT_FALSE' '$work/check_type_refused/src/check_type_refused.c'"

# 2zb. built-in class and exception references (api_map.json batch D1): rb_cHash is mrb->hash_class and rb_eKeyError is
# E_KEY_ERROR; both are expressions, so the lookup stays inline at each use
rc=0; "$rb" "$conv" --scanner "$scanner" --name api_class_exc tools/cext2mrbgem/fixtures/api_class_exc/ext/api_class_exc "$work/api_class_exc" > "$work/api_class_exc.log" 2>&1 || rc=$?
check test "$rc" -eq 0
check test ! -e "$work/api_class_exc/NOT_BUILDABLE"
check grep -qF 'if (mrb_obj_is_kind_of(mrb, obj, mrb->hash_class)) return mrb_true_value();' "$work/api_class_exc/src/api_class_exc.c"
check grep -qF 'if (mrb_obj_is_kind_of(mrb, obj, mrb->string_class)) return mrb_true_value();' "$work/api_class_exc/src/api_class_exc.c"
check grep -qF 'mrb_raisef(mrb, E_KEY_ERROR, "missing key");' "$work/api_class_exc/src/api_class_exc.c"

# 2zc. a private registration (api_map.json batch D2): rb_define_private_method takes the rb_define_method path, so the
# function is wrapped with the mruby signature and registered with mrb_define_private_method
rc=0; "$rb" "$conv" --scanner "$scanner" --name api_private_reg tools/cext2mrbgem/fixtures/api_private_reg/ext/api_private_reg "$work/api_private_reg" > "$work/api_private_reg.log" 2>&1 || rc=$?
check test "$rc" -eq 0
check test ! -e "$work/api_private_reg/NOT_BUILDABLE"
check grep -qF 'mrb_define_method(mrb, cApiPriv, "secret", api_secret, MRB_ARGS_REQ(1));' "$work/api_private_reg/src/api_private_reg.c"

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
check grep -qF 'return nfcx_class_new_instance(mrb, argc, argv, cApiNew);' "$work/api_new_inst/src/api_new_inst.c"

# 2zg. rb_hash_lookup (api_map.json batch N2): mrb_hash_fetch with a nil default appended to the closing parenthesis
rc=0; "$rb" "$conv" --scanner "$scanner" --name api_hash_lookup tools/cext2mrbgem/fixtures/api_hash_lookup/ext/api_hash_lookup "$work/api_hash_lookup" > "$work/api_hash_lookup.log" 2>&1 || rc=$?
check test "$rc" -eq 0
check test ! -e "$work/api_hash_lookup/NOT_BUILDABLE"
check grep -qF 'return mrb_hash_fetch(mrb, h, k, mrb_nil_value());' "$work/api_hash_lookup/src/api_hash_lookup.c"

# 2zh. rb_sym2str (api_map.json batch N3): the Symbol argument is wrapped with mrb_symbol(...), and mrb is passed first
rc=0; "$rb" "$conv" --scanner "$scanner" --name api_sym_str tools/cext2mrbgem/fixtures/api_sym_str/ext/api_sym_str "$work/api_sym_str" > "$work/api_sym_str.log" 2>&1 || rc=$?
check test "$rc" -eq 0
check test ! -e "$work/api_sym_str/NOT_BUILDABLE"
check grep -qF 'return mrb_sym_str(mrb, mrb_symbol(sym));' "$work/api_sym_str/src/api_sym_str.c"

# 2zj. rb_cstr_to_inum (api_map.json batch N5): the C string is wrapped as a String, and mrb_str_to_inum keeps base and badcheck
rc=0; "$rb" "$conv" --scanner "$scanner" --name api_cstr_inum tools/cext2mrbgem/fixtures/api_cstr_inum/ext/api_cstr_inum "$work/api_cstr_inum" > "$work/api_cstr_inum.log" 2>&1 || rc=$?
check test "$rc" -eq 0
check test ! -e "$work/api_cstr_inum/NOT_BUILDABLE"
check grep -qF 'return mrb_str_to_inum(mrb, mrb_str_new_cstr(mrb, "12"), 10, 0);' "$work/api_cstr_inum/src/api_cstr_inum.c"

# 2zk. global variables named by a string literal (api_map.json batch N6): the name is interned with mrb_intern_cstr
rc=0; "$rb" "$conv" --scanner "$scanner" --name api_gv_name tools/cext2mrbgem/fixtures/api_gv_name/ext/api_gv_name "$work/api_gv_name" > "$work/api_gv_name.log" 2>&1 || rc=$?
check test "$rc" -eq 0
check test ! -e "$work/api_gv_name/NOT_BUILDABLE"
check grep -qF 'return mrb_gv_get(mrb, mrb_intern_cstr(mrb, "$api_count"));' "$work/api_gv_name/src/api_gv_name.c"
check grep -qF 'mrb_gv_set(mrb, mrb_intern_cstr(mrb, "$api_count"), v);' "$work/api_gv_name/src/api_gv_name.c"

# 2zl. regexp back-references through the onig gem's API (api_map.json batch N7): rb_reg_nth_match is match[nth] with a nil
# check, rb_backref_get reads $~ (both through a template)
rc=0; "$rb" "$conv" --scanner "$scanner" --name api_regexp tools/cext2mrbgem/fixtures/api_regexp/ext/api_regexp "$work/api_regexp" > "$work/api_regexp.log" 2>&1 || rc=$?
check test "$rc" -eq 0
check test ! -e "$work/api_regexp/NOT_BUILDABLE"
check grep -qF 'return (mrb_nil_p(m) ? mrb_nil_value() : mrb_funcall(mrb, m, "[]", 1, mrb_fixnum_value(1)));' "$work/api_regexp/src/api_regexp.c"
check grep -qF 'return mrb_gv_get(mrb, mrb_intern_lit(mrb, "$~"));' "$work/api_regexp/src/api_regexp.c"

# 2zm. rb_jump_tag re-raises the exception mrb_protect caught (mrb->exc); rb_match_busy is dropped with a warning (api_map.json batch N8)
rc=0; "$rb" "$conv" --scanner "$scanner" --name api_jump_tag tools/cext2mrbgem/fixtures/api_jump_tag/ext/api_jump_tag "$work/api_jump_tag" > "$work/api_jump_tag.log" 2>&1 || rc=$?
check test "$rc" -eq 0
check test ! -e "$work/api_jump_tag/NOT_BUILDABLE"
check grep -qF 'mrb_exc_raise(mrb, mrb_obj_value(mrb->exc));' "$work/api_jump_tag/src/api_jump_tag.c"

# 2zn. RUBY_TYPED_* flags (api_map.json batch N9): mruby has no such flags, so each is 0 (caveated)
rc=0; "$rb" "$conv" --scanner "$scanner" --name api_typed_flags tools/cext2mrbgem/fixtures/api_typed_flags/ext/api_typed_flags "$work/api_typed_flags" > "$work/api_typed_flags.log" 2>&1 || rc=$?
check test "$rc" -eq 0
check test ! -e "$work/api_typed_flags/NOT_BUILDABLE"
check grep -qF 'int flags = 0 | 0;' "$work/api_typed_flags/src/api_typed_flags.c"

# 2zo. a data type's mark and free callbacks are threaded with mrb; the initializer is reordered to {name, dfree, mark};
# rb_gc_mark is valid inside the mark callback (api_map.json batch N10)
rc=0; "$rb" "$conv" --scanner "$scanner" --name api_dtype tools/cext2mrbgem/fixtures/api_dtype/ext/api_dtype "$work/api_dtype" > "$work/api_dtype.log" 2>&1 || rc=$?
check test "$rc" -eq 0
check test ! -e "$work/api_dtype/NOT_BUILDABLE"
check grep -qF 'static void holder_mark(mrb_state *mrb, void *p) {' "$work/api_dtype/src/api_dtype.c"
check grep -qF 'static const mrb_data_type holder_type = { "holder", holder_free, holder_mark };' "$work/api_dtype/src/api_dtype.c"

# a data type whose mark is (RUBY_DATA_FUNC) NULL and whose free is RUBY_TYPED_DEFAULT_FREE (pg's coder types): no refusal
rc=0; "$rb" "$conv" --scanner "$scanner" --name api_dtype_cast_null tools/cext2mrbgem/fixtures/api_dtype_cast_null/ext/api_dtype_cast_null "$work/api_dtype_cast_null" > "$work/api_dtype_cast_null.log" 2>&1 || rc=$?
check test "$rc" -eq 0
check test ! -e "$work/api_dtype_cast_null/NOT_BUILDABLE"
check grep -qF 'mrb_gc_mark_value(mrb, ((holder *)p)->held);' "$work/api_dtype/src/api_dtype.c"

# 2zp. TypedData_ and Data_ macros are unknown names (refused), not silent pass-throughs
rc=0; "$rb" "$conv" --scanner "$scanner" --name api_dtype_refused tools/cext2mrbgem/fixtures/api_dtype_refused/ext/api_dtype_refused "$work/api_dtype_refused" > "$work/api_dtype_refused.log" 2>&1 || rc=$?
check test "$rc" -eq 2
check test -e "$work/api_dtype_refused/NOT_BUILDABLE"
check grep -q "  TypedData_Get_Type  no entry in api_map.json" "$work/api_dtype_refused/REFUSALS.txt"

# 2zp2. a rb_data_type_t .function holding a compaction macro call (ffi's ffi_compact_callback(f)) drops the call and converts;
# a data type with a parent is refused, and its initializer is stubbed with the name kept (no CRuby members left to fail the check)
rc=0; "$rb" "$conv" --scanner "$scanner" --name api_dtype_compact tools/cext2mrbgem/fixtures/api_dtype_compact/ext/api_dtype_compact "$work/api_dtype_compact" > "$work/api_dtype_compact.log" 2>&1 || rc=$?
check test "$rc" -eq 0
check test ! -e "$work/api_dtype_compact/NOT_BUILDABLE"
check grep -qF 'static const mrb_data_type cm_type = { "CmBox", cm_free, cm_mark };' "$work/api_dtype_compact/src/api_dtype_compact.c"
rc=0; "$rb" "$conv" --scanner "$scanner" --name api_dtype_parent tools/cext2mrbgem/fixtures/api_dtype_parent/ext/api_dtype_parent "$work/api_dtype_parent" > "$work/api_dtype_parent.log" 2>&1 || rc=$?
check test "$rc" -eq 2
check test -e "$work/api_dtype_parent/NOT_BUILDABLE"
check grep -qF 'struct mrb_data_type pa_child = { "PaChild", NULL, NULL };' "$work/api_dtype_parent/src/api_dtype_parent.c"
check grep -q "  rb_data_type_t  the parent or the data slot is not 0/NULL" "$work/api_dtype_parent/REFUSALS.txt"

# 2zq. TypedData_Make_Struct and TypedData_Wrap_Struct map to mrb_data_object_alloc; the struct is allocated with mrb_calloc
rc=0; "$rb" "$conv" --scanner "$scanner" --name api_typed_alloc tools/cext2mrbgem/fixtures/api_typed_alloc/ext/api_typed_alloc "$work/api_typed_alloc" > "$work/api_typed_alloc.log" 2>&1 || rc=$?
check test "$rc" -eq 0
check test ! -e "$work/api_typed_alloc/NOT_BUILDABLE"
check grep -qF 'mrb_obj_value(mrb_data_object_alloc(mrb, mProbe, (h = (holder *)mrb_calloc(mrb, 1, sizeof(holder))), &holder_type));' "$work/api_typed_alloc/src/api_typed_alloc.c"

# 2zr. rb_hash_foreach (api_map.json batch N11): the callback is threaded with mrb and its VALUE argument becomes void *; ST_CONTINUE and ST_STOP map to 0 and 1
rc=0; "$rb" "$conv" --scanner "$scanner" --name api_hash_foreach tools/cext2mrbgem/fixtures/api_hash_foreach/ext/api_hash_foreach "$work/api_hash_foreach" > "$work/api_hash_foreach.log" 2>&1 || rc=$?
check test "$rc" -eq 0
check test ! -e "$work/api_hash_foreach/NOT_BUILDABLE"
check grep -qF 'static int count_cb(mrb_state *mrb, mrb_value key, mrb_value val, void *arg) {' "$work/api_hash_foreach/src/api_hash_foreach.c"
check grep -qF 'mrb_hash_foreach(mrb, RHASH(h), count_cb, (void *)&c);' "$work/api_hash_foreach/src/api_hash_foreach.c"
check grep -qF 'return 0;' "$work/api_hash_foreach/src/api_hash_foreach.c"

# 2zs. a non-static rb_hash_foreach callback is refused (another file may call it with a VALUE argument)
rc=0; "$rb" "$conv" --scanner "$scanner" --name api_hash_foreach_refused tools/cext2mrbgem/fixtures/api_hash_foreach_refused/ext/api_hash_foreach_refused "$work/api_hash_foreach_refused" > "$work/api_hash_foreach_refused.log" 2>&1 || rc=$?
check test "$rc" -eq 2
check grep -q '  rb_hash_foreach  not a call of the form' "$work/api_hash_foreach_refused/REFUSALS.txt"

# 2zt. a static inline helper in a header is converted: it takes mrb, and its callers pass it (api_map.json batch N12)
rc=0; "$rb" "$conv" --scanner "$scanner" --name api_header_inline tools/cext2mrbgem/fixtures/api_header_inline/ext/api_header_inline "$work/api_header_inline" > "$work/api_header_inline.log" 2>&1 || rc=$?
check test "$rc" -eq 0
check test ! -e "$work/api_header_inline/NOT_BUILDABLE"
check grep -qF 'static inline int ahi_check(mrb_state *mrb, mrb_value v) {' "$work/api_header_inline/include/helper.h"
check grep -qF 'return mrb_fixnum_value(ahi_check(mrb, v));' "$work/api_header_inline/src/api_header_inline.c"

# 2zu. a CRuby NORETURN(decl); prototype is unwrapped: the declaration is converted as a prototype (api_map.json batch N13)
rc=0; "$rb" "$conv" --scanner "$scanner" --name api_noreturn tools/cext2mrbgem/fixtures/api_noreturn/ext/api_noreturn "$work/api_noreturn" > "$work/api_noreturn.log" 2>&1 || rc=$?
check test "$rc" -eq 0
check test ! -e "$work/api_noreturn/NOT_BUILDABLE"
check grep -qF 'static void anr_fail(mrb_state *mrb, mrb_value v);' "$work/api_noreturn/src/api_noreturn.c"
check sh -c "! grep -q 'NORETURN(static' '$work/api_noreturn/src/api_noreturn.c'"

# 2zv. a struct function-pointer field whose callbacks are threaded takes mrb; its calls pass mrb (api_map.json batch N14)
rc=0; "$rb" "$conv" --scanner "$scanner" --name api_fnptr_field tools/cext2mrbgem/fixtures/api_fnptr_field/ext/api_fnptr_field "$work/api_fnptr_field" > "$work/api_fnptr_field.log" 2>&1 || rc=$?
check test "$rc" -eq 0
check test ! -e "$work/api_fnptr_field/NOT_BUILDABLE"
check grep -qF 'void (*on_value)(mrb_state *mrb, struct afp_parser *p, mrb_value v);' "$work/api_fnptr_field/src/api_fnptr_field.c"
check grep -qF 'p.on_value(mrb, &p, v);' "$work/api_fnptr_field/src/api_fnptr_field.c"

# 2zw. a typedef'd function-pointer table: its callbacks are threaded and its indexed calls pass mrb (api_map.json batch N15)
rc=0; "$rb" "$conv" --scanner "$scanner" --name api_fnptr_table tools/cext2mrbgem/fixtures/api_fnptr_table/ext/api_fnptr_table "$work/api_fnptr_table" > "$work/api_fnptr_table.log" 2>&1 || rc=$?
check test "$rc" -eq 0
check test ! -e "$work/api_fnptr_table/NOT_BUILDABLE"
check grep -qF 'typedef void (*atb_dump_fn)(mrb_state *mrb, mrb_value obj, int depth);' "$work/api_fnptr_table/src/api_fnptr_table.c"
check grep -qF 'atb_table[0](mrb, v, 0);' "$work/api_fnptr_table/src/api_fnptr_table.c"

# 2zx. a static helper defined in two files is renamed per file (NAME__STEM): each copy is threaded on its own (api_map.json batch N16)
rc=0; "$rb" "$conv" --scanner "$scanner" --name api_static_dup tools/cext2mrbgem/fixtures/api_static_dup/ext/api_static_dup "$work/api_static_dup" > "$work/api_static_dup.log" 2>&1 || rc=$?
check test "$rc" -eq 0
check grep -qF 'static int sd_check__other(mrb_value v) {' "$work/api_static_dup/src/other.c"
check grep -qF 'static int sd_check__api_static_dup(mrb_state *mrb, mrb_value v) {' "$work/api_static_dup/src/api_static_dup.c"

# 2zy. batch N17 (api_map.json): rb_ary_pop and rb_str_subseq are direct calls with mrb; rb_intern3 drops its encoding argument;
# rb_deprecate_constant is dropped (no-op in mruby); RB_UNUSED_VAR keeps the name, but a parameter in that form is refused (not a plain VALUE)
rc=0; "$rb" "$conv" --scanner "$scanner" --name api_batch_n17 tools/cext2mrbgem/fixtures/api_batch_n17/ext/api_batch_n17 "$work/api_batch_n17" > "$work/api_batch_n17.log" 2>&1 || rc=$?
check test "$rc" -eq 2
check test -e "$work/api_batch_n17/NOT_BUILDABLE"
check grep -qF 'b_unused  ' "$work/api_batch_n17/REFUSALS.txt"
check grep -qF 'return mrb_ary_pop(mrb, ary);' "$work/api_batch_n17/src/api_batch_n17.c"
check grep -qF 'return mrb_str_substr(mrb, str, 1, 2);' "$work/api_batch_n17/src/api_batch_n17.c"
check grep -qF 'mrb_sym id = mrb_intern(mrb, p, 4);' "$work/api_batch_n17/src/api_batch_n17.c"
check grep -qF 'return 0;' "$work/api_batch_n17/src/api_batch_n17.c"
check grep -qF 'dropped: rb_deprecate_constant' "$work/api_batch_n17/src/api_batch_n17.c"

# 2zz. batch N18 (api_map.json): RSTRING_END is the end pointer of a String (a template over RSTRING_PTR and RSTRING_LEN);
# RARRAY_CONST_PTR maps to the mruby RARRAY_PTR macro
rc=0; "$rb" "$conv" --scanner "$scanner" --name api_batch_n18 tools/cext2mrbgem/fixtures/api_batch_n18/ext/api_batch_n18 "$work/api_batch_n18" > "$work/api_batch_n18.log" 2>&1 || rc=$?
check test "$rc" -eq 0
check test ! -e "$work/api_batch_n18/NOT_BUILDABLE"
check grep -qF 'char *e = (RSTRING_PTR(str) + RSTRING_LEN(str));' "$work/api_batch_n18/src/api_batch_n18.c"
check grep -qF 'const mrb_value *items = RARRAY_PTR(ary);' "$work/api_batch_n18/src/api_batch_n18.c"

# 2zzb. a use inside a body that the build's #if leaves out is dead code, not a file-scope use: the guard is kept and no refusal is recorded
rc=0; "$rb" "$conv" --scanner "$scanner" --name api_gated_body tools/cext2mrbgem/fixtures/api_gated_body/ext/api_gated_body "$work/api_gated_body" > "$work/api_gated_body.log" 2>&1 || rc=$?
check test "$rc" -eq 0
check test ! -e "$work/api_gated_body/NOT_BUILDABLE"
check grep -qF '#ifdef GATED_TEST_METHODS' "$work/api_gated_body/src/api_gated_body.c"
check grep -qE 'NUM2INT|mrb_int\(' "$work/api_gated_body/src/api_gated_body.c"

# 2zzc. TYPE(x) is rb_type (compared with MRB_TT_*); T_STRING is exact; rb_obj_alloc allocates a plain object of the class (mrb_class_ptr)
rc=0; "$rb" "$conv" --scanner "$scanner" --name api_type_alloc tools/cext2mrbgem/fixtures/api_type_alloc/ext/api_type_alloc "$work/api_type_alloc" > "$work/api_type_alloc.log" 2>&1 || rc=$?
check test "$rc" -eq 0
check test ! -e "$work/api_type_alloc/NOT_BUILDABLE"
check grep -qF 'return mrb_type(v) == MRB_TT_STRING ? mrb_true_value() : mrb_false_value();' "$work/api_type_alloc/src/api_type_alloc.c"
check grep -qF 'return mrb_obj_value(mrb_obj_alloc(mrb, MRB_TT_OBJECT, mrb_class_ptr(klass)));' "$work/api_type_alloc/src/api_type_alloc.c"

# 2zzd. a static (not inline) helper in a header is converted with mrb, like a static inline one: it is local to each includer
rc=0; "$rb" "$conv" --scanner "$scanner" --name api_header_static tools/cext2mrbgem/fixtures/api_header_static/ext/api_header_static "$work/api_header_static" > "$work/api_header_static.log" 2>&1 || rc=$?
check test "$rc" -eq 0
check test ! -e "$work/api_header_static/NOT_BUILDABLE"
check grep -qF 'static int hs_check(mrb_state *mrb, mrb_value v) {' "$work/api_header_static/include/helper.h"
check grep -qF 'return mrb_fixnum_value(hs_check(mrb, v));' "$work/api_header_static/src/api_header_static.c"

# 2zze. a struct function-pointer field whose entries are designated initializers at file scope (.func = handler) is threaded
# like an assigned field: the field takes mrb, the handlers take it, and the call through the field passes it
rc=0; "$rb" "$conv" --scanner "$scanner" --name api_fnptr_init tools/cext2mrbgem/fixtures/api_fnptr_init/ext/api_fnptr_init "$work/api_fnptr_init" > "$work/api_fnptr_init.log" 2>&1 || rc=$?
check test "$rc" -eq 0
check test ! -e "$work/api_fnptr_init/NOT_BUILDABLE"
check grep -qF 'mrb_value (*func)(mrb_state *mrb, mrb_value self, mrb_value value);' "$work/api_fnptr_init/src/api_fnptr_init.c"
check grep -qF 'return op->func(mrb, self, value);' "$work/api_fnptr_init/src/api_fnptr_init.c"

# 2zzf. a local named like a helper, used without a call, is that local: the helper converts (a direct call in another function threads mrb)
rc=0; "$rb" "$conv" --scanner "$scanner" --name api_shadow_local tools/cext2mrbgem/fixtures/api_shadow_local/ext/api_shadow_local "$work/api_shadow_local" > "$work/api_shadow_local.log" 2>&1 || rc=$?
check test "$rc" -eq 0
check test ! -e "$work/api_shadow_local/NOT_BUILDABLE"
check grep -qF 'mrb_value sl_check = mrb_false_value();' "$work/api_shadow_local/src/api_shadow_local.c"
check grep -qF 'return sl_check(mrb, v);' "$work/api_shadow_local/src/api_shadow_local.c"

# 2zzg. rb_yield in a registered method's body: the wrapper fetches the block ("o&") and the yield passes it to mrb_yield
rc=0; "$rb" "$conv" --scanner "$scanner" --name api_yield tools/cext2mrbgem/fixtures/api_yield/ext/api_yield "$work/api_yield" > "$work/api_yield.log" 2>&1 || rc=$?
check test "$rc" -eq 0
check test ! -e "$work/api_yield/NOT_BUILDABLE"
check grep -qF 'mrb_get_args(mrb, "o&", &v, &nfcx_block);' "$work/api_yield/src/api_yield.c"
check grep -qF 'return mrb_yield(mrb, nfcx_block, v);' "$work/api_yield/src/api_yield.c"
# 2zzh. rb_yield in a helper is refused: a helper has no block to yield to
rc=0; "$rb" "$conv" --scanner "$scanner" --name api_yield_refused tools/cext2mrbgem/fixtures/api_yield_refused/ext/api_yield_refused "$work/api_yield_refused" > "$work/api_yield_refused.log" 2>&1 || rc=$?
check test "$rc" -eq 0
check test ! -e "$work/api_yield_refused/NOT_BUILDABLE"
check grep -qF 'mrb_yield(mrb, nfcx_block_arg(mrb), v)' "$work/api_yield_refused/src/api_yield_refused.c"
check grep -qF 'mrb_protect(mrb, nfcx_yield_cb, mrb_nil_value(), &state)' "$work/api_yield_refused/src/api_yield_refused.c"

# 2zzi. a helper's function-pointer parameter, RET (*NAME)(PARAMS), is called with the mruby state: the helper takes mrb, the
# callback type takes mrb first, the callbacks passed for it are threaded, and the call through it passes mrb (fnptr_param_recs).
# The regex scanner cannot read a parameter with nested parentheses (DEF_RE), so there the callback stays refused: the
# output is NOT_BUILDABLE with the refusal of fp_cb (the libclang scanner reads the definition).
rc=0; "$rb" "$conv" --scanner "$scanner" --name api_fnptr_param tools/cext2mrbgem/fixtures/api_fnptr_param/ext/api_fnptr_param "$work/api_fnptr_param" > "$work/api_fnptr_param.log" 2>&1 || rc=$?
check test "$rc" -eq 0
check test ! -e "$work/api_fnptr_param/NOT_BUILDABLE"
check grep -qF 'static mrb_value fp_each(mrb_state *mrb, mrb_value (*cb)(mrb_state *mrb, mrb_value, mrb_value), mrb_value v, mrb_value hash) {' "$work/api_fnptr_param/src/api_fnptr_param.c"
check grep -qF 'return cb(mrb, v, hash);' "$work/api_fnptr_param/src/api_fnptr_param.c"
# 2zzz107. --undefine NAME: the #ifdef NAME branches (a definition and its registration) are inactive, and the registration is
# dead code (no refusal) in both scanner legs.
rc=0; "$rb" "$conv" --scanner "$scanner" --name api_undef_build --undefine UB_TEST_ONLY_METHODS tools/cext2mrbgem/fixtures/api_undef_build/ext/api_undef_build "$work/api_undef_build" > "$work/api_undef_build.log" 2>&1 || rc=$?
check test "$rc" -eq 0
check test ! -e "$work/api_undef_build/NOT_BUILDABLE"
# 2zzz108. a function under #ifdef HAVE_OPENSSL_* (mkmf defines it when OpenSSL is in the build) is a stuck point; a registration
# under #if 0 == 1 is dead code (the integer comparison is decided).
rc=0; "$rb" "$conv" --scanner "$scanner" --name api_ssl_guard tools/cext2mrbgem/fixtures/api_ssl_guard/ext/api_ssl_guard "$work/api_ssl_guard" > "$work/api_ssl_guard.log" 2>&1 || rc=$?
check sh -c "! grep -q 'sg_dead' '$work/api_ssl_guard/REFUSALS.txt' 2>/dev/null"
if [ "$scanner" = libclang ]; then
  # the libclang front end excludes the HAVE_OPENSSL_* branch (undefined in this build): stuck. The regex scan keeps the
  # undefined name's branch (mkmf may define it) and converts it as written.
  check test "$rc" -eq 2
  check grep -q 'stuck point (OpenSSL): the function is compiled only when the build has OpenSSL' "$work/api_ssl_guard/REFUSALS.txt"
fi
check grep -qF 'return fp_each(mrb, fp_cb, v, mrb_nil_value());' "$work/api_fnptr_param/src/api_fnptr_param.c"

# 2zzj. a struct function-pointer field filled by a positional initializer (struct TAG var = { h1, h2, ... }): the member index
# gives the field; the helper there is threaded like an assigned field, and calls through the field pass mrb
rc=0; "$rb" "$conv" --scanner "$scanner" --name api_fnptr_positional tools/cext2mrbgem/fixtures/api_fnptr_positional/ext/api_fnptr_positional "$work/api_fnptr_positional" > "$work/api_fnptr_positional.log" 2>&1 || rc=$?
check test "$rc" -eq 0
check test ! -e "$work/api_fnptr_positional/NOT_BUILDABLE"
check grep -qF 'mrb_value (*on_second)(mrb_state *mrb, mrb_value v);' "$work/api_fnptr_positional/src/api_fnptr_positional.c"
check grep -qF 'return ops->on_second(mrb, ops->on_first(mrb, v));' "$work/api_fnptr_positional/src/api_fnptr_positional.c"

# 2zzk. TYPE(v) == T_NIL and TYPE(v) != T_FALSE are value tests: mrb_nil_p and !mrb_false_p (nil and false share MRB_TT_FALSE)
rc=0; "$rb" "$conv" --scanner "$scanner" --name api_type_nil tools/cext2mrbgem/fixtures/api_type_nil/ext/api_type_nil "$work/api_type_nil" > "$work/api_type_nil.log" 2>&1 || rc=$?
check test "$rc" -eq 0
check test ! -e "$work/api_type_nil/NOT_BUILDABLE"
check grep -qF 'return mrb_nil_p(v) ? mrb_true_value() : mrb_false_value();' "$work/api_type_nil/src/api_type_nil.c"
check grep -qF 'return !mrb_false_p(v) ? mrb_true_value() : mrb_false_value();' "$work/api_type_nil/src/api_type_nil.c"

# 2zzl. code under #ifndef NDEBUG is live in the mruby output: ruby.h defines NDEBUG (CRuby drops it), so the scan reads a copy with the guard true
rc=0; "$rb" "$conv" --scanner "$scanner" --name api_ndebug_guard tools/cext2mrbgem/fixtures/api_ndebug_guard/ext/api_ndebug_guard "$work/api_ndebug_guard" > "$work/api_ndebug_guard.log" 2>&1 || rc=$?
check test "$rc" -eq 0
check test ! -e "$work/api_ndebug_guard/NOT_BUILDABLE"
check grep -qF 'static mrb_value ng_guarded(mrb_state *mrb, mrb_value self) {' "$work/api_ndebug_guard/src/api_ndebug_guard.c"
check grep -qF 'mrb_define_module_function(mrb, mNG, "guarded", ng_guarded, MRB_ARGS_REQ(1));' "$work/api_ndebug_guard/src/api_ndebug_guard.c"

# 2zzm. switch (TYPE(v)) with case T_NIL / T_FALSE: nil is routed to case 1000 (a value test), so the false label is MRB_TT_FALSE only
rc=0; "$rb" "$conv" --scanner "$scanner" --name api_switch_type tools/cext2mrbgem/fixtures/api_switch_type/ext/api_switch_type "$work/api_switch_type" > "$work/api_switch_type.log" 2>&1 || rc=$?
check test "$rc" -eq 0
check test ! -e "$work/api_switch_type/NOT_BUILDABLE"
check grep -qF 'switch ((mrb_nil_p(v) ? 1000 : mrb_type(v))) {' "$work/api_switch_type/src/api_switch_type.c"
check grep -qF 'case 1000 /* nil */: return mrb_str_new_cstr(mrb, "nil");' "$work/api_switch_type/src/api_switch_type.c"

# 2zzn. rb_enc_str_new and rb_enc_associate drop their encoding argument (a pure encoding getter is accepted there): mruby strings carry no encoding
rc=0; "$rb" "$conv" --scanner "$scanner" --name api_enc_drop tools/cext2mrbgem/fixtures/api_enc_drop/ext/api_enc_drop "$work/api_enc_drop" > "$work/api_enc_drop.log" 2>&1 || rc=$?
check test "$rc" -eq 0
check test ! -e "$work/api_enc_drop/NOT_BUILDABLE"
check grep -qF 'return mrb_str_new(mrb, p, n);' "$work/api_enc_drop/src/api_enc_drop.c"
check grep -qF 'return rb_enc_associate(s, rb_utf8_encoding());' "$work/api_enc_drop/src/api_enc_drop.c"

# 2zzo. a positional callback table with a NULL entry, and a callback stored by address (x.NAME = &helper;): both are read by the field rule
rc=0; "$rb" "$conv" --scanner "$scanner" --name api_fnptr_null tools/cext2mrbgem/fixtures/api_fnptr_null/ext/api_fnptr_null "$work/api_fnptr_null" > "$work/api_fnptr_null.log" 2>&1 || rc=$?
check test "$rc" -eq 0
check test ! -e "$work/api_fnptr_null/NOT_BUILDABLE"
check grep -qF 'void (*store)(mrb_state *mrb, mrb_value v);' "$work/api_fnptr_null/src/api_fnptr_null.c"
check grep -qF 'ops->store = &fn_store;' "$work/api_fnptr_null/src/api_fnptr_null.c"

# 2zzp. a static helper defined in two files is renamed where it is used as a value too (followed by ';'): a prototype is followed by '(', not ';'
rc=0; "$rb" "$conv" --scanner "$scanner" --name api_static_value tools/cext2mrbgem/fixtures/api_static_value/ext/api_static_value "$work/api_static_value" > "$work/api_static_value.log" 2>&1 || rc=$?
check test "$rc" -eq 0
check test ! -e "$work/api_static_value/NOT_BUILDABLE"
check grep -qF 'sv_table.fn = sv_dup__api_static_value;' "$work/api_static_value/src/api_static_value.c"
check grep -qF 'return sv_dup__other(v);' "$work/api_static_value/src/other.c"

# 2zzq. a struct member of a typedef'd function-pointer type, filled by a positional table of structs (array of struct TAG at file scope):
# the typedef takes mrb and the table entries are threaded; the call through the member passes mrb (fnptr_typed_global members, arrays of structs)
rc=0; "$rb" "$conv" --scanner "$scanner" --name api_typed_table tools/cext2mrbgem/fixtures/api_typed_table/ext/api_typed_table "$work/api_typed_table" > "$work/api_typed_table.log" 2>&1 || rc=$?
check test "$rc" -eq 0
check test ! -e "$work/api_typed_table/NOT_BUILDABLE"
check grep -qF 'return tt_codes[0].handler(mrb, v);' "$work/api_typed_table/src/api_typed_table.c"
check grep -qF '{"first", tt_first},' "$work/api_typed_table/src/api_typed_table.c"

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
check grep -q "ruby_xmalloc2_unmapped  no entry in api_map.json" "$work/lowercase_api_refused/REFUSALS.txt"

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
if [ -n "${NFCX_MRUBY_INCLUDE:-}" ]; then
# with the compile check, the gem's own wrapper.c does not compile here: its crypt_r is defined with struct crypt_data *
# while ow-crypt.h declares it with void * (a C error in the gem, not in the conversion); the refusal says so
check test "$rc" -eq 2
check test -e "$work/bcrypt/NOT_BUILDABLE"
check grep -q 'stuck point (target): the gem defines crypt_r' "$work/bcrypt/REFUSALS.txt"
else
check test "$rc" -eq 0
check test ! -e "$work/bcrypt/NOT_BUILDABLE"
fi
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
check grep -qF 'return mrb_fixnum_value(big);' "$work/api_fetch_num_str/src/api_fetch_num_str.c"
check grep -qF 'unsigned int u = ((unsigned int)mrb_int(mrb, a));' "$work/api_fetch_num_str/src/api_fetch_num_str.c"
check grep -qF 'size_t s = ((size_t)mrb_int(mrb, b));' "$work/api_fetch_num_str/src/api_fetch_num_str.c"
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
check grep -qF 'return mrb_bool_value(mrb_obj_is_kind_of(mrb, obj, cApiKind));' "$work/api_obj_class_int/src/api_obj_class_int.c"
check grep -qF 'return mrb_fixnum_value(mrb_obj_id(obj));' "$work/api_obj_class_int/src/api_obj_class_int.c"
check grep -qF 'mrb_value k = mrb_obj_value(mrb_class(mrb, obj));' "$work/api_obj_class_int/src/api_obj_class_int.c"
check grep -qF 'mrb_include_module(mrb, cApiKind, mApiMix);' "$work/api_obj_class_int/src/api_obj_class_int.c"
check grep -qF 'if (mrb_fixnum_p(v)) return mrb_true_value();' "$work/api_obj_class_int/src/api_obj_class_int.c"
check grep -qF 'mrb_raisef(mrb, E_FROZEN_ERROR, "not an integer");' "$work/api_obj_class_int/src/api_obj_class_int.c"
check sh -c "! grep -q 'mrb_obj_value(cApiKind)\|mrb_obj_value(mApiMix)' '$work/api_obj_class_int/src/api_obj_class_int.c'"

# 5b. names kept refused in batch B1 (no exact mruby equivalent: rb_str_subseq, rb_iv_get, rb_gv_get, rb_sym2str,
# rb_cstr_to_inum, rb_bug, StringValue) stay refused with the no-entry reason, so a later mapping is a deliberate change
rc=0; "$rb" "$conv" --scanner "$scanner" --name api_skipped_refused tools/cext2mrbgem/fixtures/api_skipped_refused/ext/api_skipped_refused "$work/api_skipped_refused" > "$work/api_skipped_refused.log" 2>&1 || rc=$?
check test "$rc" -eq 2
check test -e "$work/api_skipped_refused/NOT_BUILDABLE"
check test "$(grep -c "no entry in api_map.json" "$work/api_skipped_refused/REFUSALS.txt")" -eq 2
check grep -q '  rb_memcicmp  no entry in api_map.json' "$work/api_skipped_refused/REFUSALS.txt"
check grep -q "  rb_iv_get  argument 2 is not a string literal" "$work/api_skipped_refused/REFUSALS.txt"
check grep -q "feature 'x' has no providing gem" "$work/api_skipped_refused/WARNINGS.txt"

# 6. api_map.json batch C1 (RTYPEDDATA_DATA -> DATA_PTR, an lvalue in both): mapped with no refusal, mruby/data.h included
rc=0; "$rb" "$conv" --scanner "$scanner" --name api_typed_ptr tools/cext2mrbgem/fixtures/api_typed_ptr/ext/api_typed_ptr "$work/api_typed_ptr" > "$work/api_typed_ptr.log" 2>&1 || rc=$?
check test "$rc" -eq 0
check test ! -e "$work/api_typed_ptr/NOT_BUILDABLE"
check grep -q 'STATUS: no refusals' "$work/api_typed_ptr/REFUSALS.txt"
check grep -qF '#include <mruby/data.h>' "$work/api_typed_ptr/src/api_typed_ptr.c"
check grep -qF 'void *p = DATA_PTR(obj);' "$work/api_typed_ptr/src/api_typed_ptr.c"
check grep -qF 'DATA_PTR(obj) = NULL;' "$work/api_typed_ptr/src/api_typed_ptr.c"


# 2zzr. CRuby exception and class globals with an mruby lookup (rb_eIOError, rb_cNumeric): mrb_exc_get and mrb_class_get
# with the name as a string; the converted output compiles with -Wall -Werror
rc=0; "$rb" "$conv" --scanner "$scanner" --name api_exc_class tools/cext2mrbgem/fixtures/api_exc_class/ext/api_exc_class "$work/api_exc_class" > "$work/api_exc_class.log" 2>&1 || rc=$?
check test "$rc" -eq 0
check test ! -e "$work/api_exc_class/NOT_BUILDABLE"
check grep -qF 'mrb_class_get(mrb, "Numeric")' "$work/api_exc_class/src/api_exc_class.c"
check grep -qF 'mrb_exc_get(mrb, "IOError")' "$work/api_exc_class/src/api_exc_class.c"
check grep -qF 'mrb_ensure_string_type(mrb, s)' "$work/api_exc_class/src/api_exc_class.c"
check grep -qF 'mrb_write_field(mrb, self, &slot, v);' "$work/api_exc_class/src/api_exc_class.c"

# 2zzs. CRuby address roots (rb_gc_register_address, rb_global_variable: a VALUE the GC must keep through a variable):
# mapped to the fork's mrb_gc_register_address (fork branch claude/gc-address-roots); the output compiles against the fork headers
rc=0; "$rb" "$conv" --scanner "$scanner" --name api_gc_address tools/cext2mrbgem/fixtures/api_gc_address/ext/api_gc_address "$work/api_gc_address" > "$work/api_gc_address.log" 2>&1 || rc=$?
check test "$rc" -eq 0
check test ! -e "$work/api_gc_address/NOT_BUILDABLE"
check grep -qF 'mrb_gc_register_address(mrb, &g_keep);' "$work/api_gc_address/src/api_gc_address.c"

# 2zzt. rb_gc_mark in a helper that only the data type mark callback calls: the helper is in the mark context (mark_context_names),
# so the mark is mrb_gc_mark_value in it; the allocation takes a tracked class variable; the output compiles against the fork's headers
rc=0; "$rb" "$conv" --scanner "$scanner" --name api_mark_helper tools/cext2mrbgem/fixtures/api_mark_helper/ext/api_mark_helper "$work/api_mark_helper" > "$work/api_mark_helper.log" 2>&1 || rc=$?
check test "$rc" -eq 0
check test ! -e "$work/api_mark_helper/NOT_BUILDABLE"
check grep -qF 'mrb_gc_mark_value(mrb, h->a);' "$work/api_mark_helper/src/api_mark_helper.c"
check grep -qF 'mrb_data_object_alloc(mrb, cHolder,' "$work/api_mark_helper/src/api_mark_helper.c"

# 2zzu. rb_str_cat2 / rb_str_cat_cstr append a C string (mrb_str_cat_cstr); rb_undef_alloc_func undefines the class's new
# (tracked class variable); RB_OBJ_WRITTEN is the field write barrier. The output compiles against the fork's headers.
rc=0; "$rb" "$conv" --scanner "$scanner" --name api_str_barrier tools/cext2mrbgem/fixtures/api_str_barrier/ext/api_str_barrier "$work/api_str_barrier" > "$work/api_str_barrier.log" 2>&1 || rc=$?
check test "$rc" -eq 0
check test ! -e "$work/api_str_barrier/NOT_BUILDABLE"
check grep -qF 'mrb_str_cat_cstr(mrb, s, "!");' "$work/api_str_barrier/src/api_str_barrier.c"

# 2zzv. a stateful callback passed down a forwarding chain (fnptr_param_recs with retention): converts, compiles with -Wall -Werror
rc=0; "$rb" "$conv" --scanner "$scanner" --name api_fwd_callback tools/cext2mrbgem/fixtures/api_fwd_callback/ext/api_fwd_callback "$work/api_fwd_callback" > "$work/api_fwd_callback.log" 2>&1 || rc=$?
check test "$rc" -eq 0
check test ! -e "$work/api_fwd_callback/NOT_BUILDABLE"
check grep -qF 'return fwd_outer(mrb, v, fwd_c);' "$work/api_fwd_callback/src/api_fwd_callback.c"

# 2zzw. a stateful callback stored into a global (the callee keeps the pointer): refused, the output is not buildable
rc=0; "$rb" "$conv" --scanner "$scanner" --name api_store_callback_refused tools/cext2mrbgem/fixtures/api_store_callback_refused/ext/api_store_callback_refused "$work/api_store_callback_refused" > "$work/api_store_callback_refused.log" 2>&1 || rc=$?
check test "$rc" -eq 2
check test -e "$work/api_store_callback_refused/NOT_BUILDABLE"
check grep -q '  sr_c  helper needs the mruby state threaded in' "$work/api_store_callback_refused/REFUSALS.txt"

# 2zzx. VALUE == VALUE is identity: mrb_obj_equal(mrb, a, b) (value_equality_pass); the compile check (NFCX_MRUBY_INCLUDE: the
# mruby headers, colon-separated) finds converted sources that do not compile against them and refuses them at their output line.
# Regression for the rewrite itself, on every run; the compile check part runs only when NFCX_MRUBY_INCLUDE is set.
rc=0; "$rb" "$conv" --scanner "$scanner" --name api_value_eq tools/cext2mrbgem/fixtures/api_value_eq/ext/api_value_eq "$work/api_value_eq" > "$work/api_value_eq.log" 2>&1 || rc=$?
check test "$rc" -eq 0
check test ! -e "$work/api_value_eq/NOT_BUILDABLE"
check grep -qF 'mrb_obj_equal(mrb, a, b)' "$work/api_value_eq/src/api_value_eq.c"
check grep -qF 'mrb_obj_equal(mrb, veq_state.v, w)' "$work/api_value_eq/src/api_value_eq.c"

# 2zzz6. FIXNUM_MAX / FIXNUM_MIN keep CRuby's values (LONG_MAX >> 1, LONG_MIN >> 1): the converted code makes CRuby's Fixnum decisions
rc=0; "$rb" "$conv" --scanner "$scanner" --name probe_fx tools/cext2mrbgem/fixtures/api_fixnum_bound/ext/api_fixnum_bound "$work/api_fixnum_bound" > "$work/api_fixnum_bound.log" 2>&1 || rc=$?
check test "$rc" -eq 0
check grep -qF 'if (n > (LONG_MAX >> 1) || n < (LONG_MIN >> 1)) return mrb_false_value();' "$work/api_fixnum_bound/src/api_fixnum_bound.c"

# 2zzz7. gem values through method calls (the rational and struct gems of the fork): Rational(n, d) on the top self, its
# numerator, Struct#[] with an Integer index; the output compiles against the fork's headers when NFCX_MRUBY_INCLUDE is set
rc=0; "$rb" "$conv" --scanner "$scanner" --name api_gem_values tools/cext2mrbgem/fixtures/api_gem_values/ext/api_gem_values "$work/api_gem_values" > "$work/api_gem_values.log" 2>&1 || rc=$?
check test "$rc" -eq 0
check grep -qF 'mrb_funcall_argv(mrb, mrb_top_self(mrb), mrb_intern_cstr(mrb, "Rational"), 2, (mrb_value[]){n, d})' "$work/api_gem_values/src/api_gem_values.c"
check grep -qF 'mrb_intern_cstr(mrb, "[]"), 1, (mrb_value[]){mrb_fixnum_value((mrb_int)(0))})' "$work/api_gem_values/src/api_gem_values.c"

# 2zzz8. the encoding-dropping string helpers (rb_enc_interned_str: the bytes, asciicompat_p as a condition) and the time gem's
# Time.at for rb_time_nano_new (nanoseconds to microseconds); the output compiles against the fork's headers
rc=0; "$rb" "$conv" --scanner "$scanner" --name api_enc_time tools/cext2mrbgem/fixtures/api_enc_time/ext/api_enc_time "$work/api_enc_time" > "$work/api_enc_time.log" 2>&1 || rc=$?
check test "$rc" -eq 0
check grep -qF 'if (1) return r;' "$work/api_enc_time/src/api_enc_time.c"
check grep -qF 'mrb_intern_cstr(mrb, "at"), 2, (mrb_value[]){mrb_fixnum_value((mrb_int)(sec)), mrb_fixnum_value((mrb_int)(nsec) / 1000)})' "$work/api_enc_time/src/api_enc_time.c"

# 2zzz9. Method#arity (the method gem, as an int), Integer#to_s (rb_big2str), the string-to-Integer parse (rb_cstr2inum), the
# fixnum from a st value (ST2FIX), IO#write (rb_io_write); the output compiles against the fork's headers
rc=0; "$rb" "$conv" --scanner "$scanner" --name api_method_str tools/cext2mrbgem/fixtures/api_method_str/ext/api_method_str "$work/api_method_str" > "$work/api_method_str.log" 2>&1 || rc=$?
check test "$rc" -eq 0
check grep -qF 'int ar = ' "$work/api_method_str/src/api_method_str.c"
check grep -qF 'mrb_intern_cstr(mrb, "write"), 1, (mrb_value[]){big})' "$work/api_method_str/src/api_method_str.c"

# 2zzz10. rb_ary_new3(n, values...) -> mrb_ary_new_from_values with the values in an mrb_value array (the count literal; an
# empty array with NULL); the output compiles against the fork's headers
rc=0; "$rb" "$conv" --scanner "$scanner" --name api_ary_new3 tools/cext2mrbgem/fixtures/api_ary_new3/ext/api_ary_new3 "$work/api_ary_new3" > "$work/api_ary_new3.log" 2>&1 || rc=$?
check test "$rc" -eq 0
check grep -qF 'mrb_value a = mrb_ary_new_from_values(mrb, 2, (mrb_value[]){x, y});' "$work/api_ary_new3/src/api_ary_new3.c"
check grep -qF 'mrb_value b = mrb_ary_new_from_values(mrb, 0, NULL);' "$work/api_ary_new3/src/api_ary_new3.c"

# 2zzz11. an enumerator the input defines with a CRuby-looking name (RUBY_TAG_LOCAL): not a CRuby name, not refused
rc=0; "$rb" "$conv" --scanner "$scanner" --name api_enum_local tools/cext2mrbgem/fixtures/api_enum_local/ext/api_enum_local "$work/api_enum_local" > "$work/api_enum_local.log" 2>&1 || rc=$?
check test "$rc" -eq 0
check grep -qF 'if (RUBY_TAG_LOCAL == 3)' "$work/api_enum_local/src/api_enum_local.c"

# 2zzz12. a file-scope variable the input defines (rb_fs_names) is a local name, and rb_to_int converts through to_int
rc=0; "$rb" "$conv" --scanner "$scanner" --name api_file_scope tools/cext2mrbgem/fixtures/api_file_scope/ext/api_file_scope "$work/api_file_scope" > "$work/api_file_scope.log" 2>&1 || rc=$?
check test "$rc" -eq 0
check grep -qF 'mrb_value n = mrb_to_int(mrb, v);' "$work/api_file_scope/src/api_file_scope.c"

# 2zzz13. rb_check_typeddata (mrb_data_get_ptr), rb_int_positive_pow (Integer#**), rb_struct_s_members (Struct.members),
# rb_obj_call_init (initialize with argv): the output compiles against the fork's headers when NFCX_MRUBY_INCLUDE is set
rc=0; "$rb" "$conv" --scanner "$scanner" --name api_meta_misc tools/cext2mrbgem/fixtures/api_meta_misc/ext/api_meta_misc "$work/api_meta_misc" > "$work/api_meta_misc.log" 2>&1 || rc=$?
check test "$rc" -eq 0
check grep -qF 'mrb_data_get_ptr(mrb, obj, &mm_type)' "$work/api_meta_misc/src/api_meta_misc.c"
check grep -qF 'mrb_intern_cstr(mrb, "initialize"), 1, argv)' "$work/api_meta_misc/src/api_meta_misc.c"

# 2zzy. a helper that returns a pointer (Real *) and needs the state: the header keeps the star (decl_scan's return type), and
rc=0; "$rb" "$conv" --scanner "$scanner" --name api_ret_pointer tools/cext2mrbgem/fixtures/api_ret_pointer/ext/api_ret_pointer "$work/api_ret_pointer" > "$work/api_ret_pointer.log" 2>&1 || rc=$?
check test "$rc" -eq 0
check grep -qF 'static Real * rp_ptr(mrb_state *mrb, mrb_value obj) {' "$work/api_ret_pointer/src/api_ret_pointer.c"

# 2zzz2. rb_funcall(recv, rb_intern("lit"), n, args...) -> mrb_funcall_argv with an argv array (the receiver and the arguments
# are converted in place); the integer conversions are mrb_fixnum_value (the Integer tag), not a Float
rc=0; "$rb" "$conv" --scanner "$scanner" --name api_funcall tools/cext2mrbgem/fixtures/api_funcall/ext/api_funcall "$work/api_funcall" > "$work/api_funcall.log" 2>&1 || rc=$?
check test "$rc" -eq 0
check grep -qF 'mrb_value a = mrb_funcall_argv(mrb, v, mrb_intern_cstr(mrb, "to_i"), 0, NULL);' "$work/api_funcall/src/api_funcall.c"
check grep -qF 'mrb_intern_cstr(mrb, "*"), 1, (mrb_value[]){mrb_fixnum_value(-1)});' "$work/api_funcall/src/api_funcall.c"

# 2zzz3. rb_raise with "%"PRIsVALUE: the token becomes "S" (mruby's %S: a VALUE printed with to_s), and the output compiles
rc=0; "$rb" "$conv" --scanner "$scanner" --name api_raise_pv tools/cext2mrbgem/fixtures/api_raise_pv/ext/api_raise_pv "$work/api_raise_pv" > "$work/api_raise_pv.log" 2>&1 || rc=$?
check test "$rc" -eq 0
check grep -qF 'mrb_raisef(mrb, E_ARGUMENT_ERROR, "bad value %""S"" here", v);' "$work/api_raise_pv/src/api_raise_pv.c"
# 2zzz32. "%+"PRIsVALUE (inspect) becomes "%!"S" (the fork's ! flag: inspect, then S).
rc=0; "$rb" "$conv" --scanner "$scanner" --name api_raise_pv_inspect tools/cext2mrbgem/fixtures/api_raise_pv_inspect/ext/api_raise_pv_inspect "$work/api_raise_pv_inspect" > "$work/api_raise_pv_inspect.log" 2>&1 || rc=$?
check test "$rc" -eq 0
check grep -qF 'mrb_raisef(mrb, E_ARGUMENT_ERROR, "bad value %!""S"" here", v);' "$work/api_raise_pv_inspect/src/api_raise_pv_inspect.c"
check grep -qF 'mrb_gc_protect(mrb, box.value);' "$work/api_funcall/src/api_funcall.c"
# 2zzz. a registered method whose return type is VP_EXPORT VALUE, where #define VP_EXPORT static is storage: a registered method
rc=0; "$rb" "$conv" --scanner "$scanner" --name api_storage_macro tools/cext2mrbgem/fixtures/api_storage_macro/ext/api_storage_macro "$work/api_storage_macro" > "$work/api_storage_macro.log" 2>&1 || rc=$?
check test "$rc" -eq 0
check grep -qF 'static mrb_value vp_hello(mrb_state *mrb, mrb_value self) {' "$work/api_storage_macro/src/api_storage_macro.c"

# 2zzz4. a macro whose body returns and calls a threaded helper, expanded in a registered method: the expansion passes the method's
# mrb (no global state, no refusal); the output compiles against the fork's headers when NFCX_MRUBY_INCLUDE is set
rc=0; "$rb" "$conv" --scanner "$scanner" --name api_macro_return tools/cext2mrbgem/fixtures/api_macro_return/ext/api_macro_return "$work/api_macro_return" > "$work/api_macro_return.log" 2>&1 || rc=$?
check test "$rc" -eq 0
check grep -qF 'return mret_make(mrb, s);' "$work/api_macro_return/src/api_macro_return.c"

# 2zzz5. a VALUE function returns a C integer from a helper (return ir_sub(...), in a macro body): refused, CRuby converts it
# implicitly and mruby's mrb_value does not
rc=0; "$rb" "$conv" --scanner "$scanner" --name api_int_return tools/cext2mrbgem/fixtures/api_int_return/ext/api_int_return "$work/api_int_return" > "$work/api_int_return.log" 2>&1 || rc=$?
check test "$rc" -eq 2
check test -e "$work/api_int_return/NOT_BUILDABLE"
check grep -q "stuck point (source bug): returns ir_sub's int from a function that returns VALUE" "$work/api_int_return/REFUSALS.txt"
if [ -n "${NFCX_MRUBY_INCLUDE:-}" ]; then
rc=0; NFCX_MRUBY_INCLUDE="$NFCX_MRUBY_INCLUDE" "$rb" "$conv" --scanner "$scanner" --name api_value_eq_cc tools/cext2mrbgem/fixtures/api_value_eq/ext/api_value_eq "$work/api_value_eq_cc" > "$work/api_value_eq_cc.log" 2>&1 || rc=$?
check test "$rc" -eq 0
fi
check grep -qF 'mrb_undef_class_method(mrb, cBox, "new");' "$work/api_str_barrier/src/api_str_barrier.c"
# 2zzz99. a struct member named like a helper (and reached through a macro's ->x) is a field: the helper is still threaded.
rc=0; "$rb" "$conv" --scanner "$scanner" --name api_field_helper_name tools/cext2mrbgem/fixtures/api_field_helper_name/ext/api_field_helper_name "$work/api_field_helper_name" > "$work/api_field_helper_name.log" 2>&1 || rc=$?
check test "$rc" -eq 0
check test ! -e "$work/api_field_helper_name/NOT_BUILDABLE"
check grep -qF 'static mrb_value sec(mrb_state *mrb, mrb_value f) {' "$work/api_field_helper_name/src/api_field_helper_name.c"
# 2zzz100. "else if (c) {" is a statement: a braceless loop with a yield in it is converted (not dead); a yielding variadic
# method fetches the block with "*&"; SYM2ID of a Symbol value is the method name (mrb_symbol); rb_cmpint is mrb_cmpint.
rc=0; "$rb" "$conv" --scanner "$scanner" --name api_stmt_keywords tools/cext2mrbgem/fixtures/api_stmt_keywords/ext/api_stmt_keywords "$work/api_stmt_keywords" > "$work/api_stmt_keywords.log" 2>&1 || rc=$?
check test "$rc" -eq 0
check test ! -e "$work/api_stmt_keywords/NOT_BUILDABLE"
check grep -qF 'mrb_get_args(mrb, "*&", &argv, &nfcx_argc, &nfcx_block);' "$work/api_stmt_keywords/src/api_stmt_keywords.c"
check grep -qF 'mrb_yield(mrb, nfcx_block, self);' "$work/api_stmt_keywords/src/api_stmt_keywords.c"
check grep -qF 'mrb_funcall_argv(mrb, self, mrb_symbol(sym), 0, NULL)' "$work/api_stmt_keywords/src/api_stmt_keywords.c"
check grep -qF 'mrb_cmpint(mrb, ' "$work/api_stmt_keywords/src/api_stmt_keywords.c"
# a local int c shadows the class variable VALUE c of Init: its comparisons are not wrapped
check grep -qF '    if (c < 0) {' "$work/api_stmt_keywords/src/api_stmt_keywords.c"
# 2zzz101. RETURN_ENUMERATOR in a variadic registered method returns to_enum(:name, *args) when no block is given; a class
# variable is an argument of CLASS_OF and rb_singleton_class (wrapped with mrb_obj_value).
rc=0; "$rb" "$conv" --scanner "$scanner" --name api_enum_classvar tools/cext2mrbgem/fixtures/api_enum_classvar/ext/api_enum_classvar "$work/api_enum_classvar" > "$work/api_enum_classvar.log" 2>&1 || rc=$?
check test "$rc" -eq 0
check test ! -e "$work/api_enum_classvar/NOT_BUILDABLE"
check grep -qF 'mrb_intern_cstr(mrb, "each_n")' "$work/api_enum_classvar/src/api_enum_classvar.c"
check grep -qF 'mrb_intern_cstr(mrb, "to_enum")' "$work/api_enum_classvar/src/api_enum_classvar.c"
check grep -qF 'mrb_obj_value(mrb_class(mrb, mrb_obj_value(cK)))' "$work/api_enum_classvar/src/api_enum_classvar.c"
check grep -qF 'mrb_singleton_class(mrb, mrb_obj_value(cK))' "$work/api_enum_classvar/src/api_enum_classvar.c"
# 2zzz102. a helper whose address is in a file-scope table is accepted when the gem has an Init (which sets the global state).
rc=0; "$rb" "$conv" --scanner "$scanner" --name api_table_init tools/cext2mrbgem/fixtures/api_table_init/ext/api_table_init "$work/api_table_init" > "$work/api_table_init.log" 2>&1 || rc=$?
check test "$rc" -eq 0
check test ! -e "$work/api_table_init/NOT_BUILDABLE"
check grep -qF 'static mrb_value ti_str(mrb_state *mrb, mrb_value self) {' "$work/api_table_init/src/api_table_init.c"
# 2zzz103. the encoding API maps to the mruby-encoding gem's Ruby-level methods and constants (rb_enc_get -> String#encoding,
# rb_enc_associate -> String#force_encoding, rb_utf8_encoding / rb_ascii8bit_encoding -> Encoding::UTF_8 / BINARY).
rc=0; "$rb" "$conv" --scanner "$scanner" --name api_encoding tools/cext2mrbgem/fixtures/api_encoding/ext/api_encoding "$work/api_encoding" > "$work/api_encoding.log" 2>&1 || rc=$?
check test "$rc" -eq 0
check test ! -e "$work/api_encoding/NOT_BUILDABLE"
check grep -qF 'return rb_enc_get(str);' "$work/api_encoding/src/api_encoding.c"
check grep -qF 'return rb_enc_associate(str, rb_ascii8bit_encoding());' "$work/api_encoding/src/api_encoding.c"
# 2zzz104. rb_rescue maps to mrb_rescue; the rescue callback gets the exception from mrb->exc through a file-scope wrapper.
rc=0; "$rb" "$conv" --scanner "$scanner" --name api_rescue tools/cext2mrbgem/fixtures/api_rescue/ext/api_rescue "$work/api_rescue" > "$work/api_rescue.log" 2>&1 || rc=$?
check test "$rc" -eq 0
check test ! -e "$work/api_rescue/NOT_BUILDABLE"
check grep -qF 'return mrb_rescue(mrb, rs_body, proc, nfcx_rescue_rs_recover_' "$work/api_rescue/src/api_rescue.c"
check grep -qF 'rs_recover(mrb, data, mrb_obj_value(mrb->exc))' "$work/api_rescue/src/api_rescue.c"
# 2zzz105. rb_rescue2 maps to mrb_rescue_exceptions with the listed classes as an RClass * array.
rc=0; "$rb" "$conv" --scanner "$scanner" --name api_rescue2 tools/cext2mrbgem/fixtures/api_rescue2/ext/api_rescue2 "$work/api_rescue2" > "$work/api_rescue2.log" 2>&1 || rc=$?
check test "$rc" -eq 0
check test ! -e "$work/api_rescue2/NOT_BUILDABLE"
check grep -qF 'mrb_rescue_exceptions(mrb, rs2_body, proc, nfcx_rescue_rs2_recover_' "$work/api_rescue2/src/api_rescue2.c"
# 2zzz106. a callback stored into a struct field: the parameter, the field and the field's calls all take mrb (field forwarding).
rc=0; "$rb" "$conv" --scanner "$scanner" --name api_store_field tools/cext2mrbgem/fixtures/api_store_field/ext/api_store_field "$work/api_store_field" > "$work/api_store_field.log" 2>&1 || rc=$?
check test "$rc" -eq 0
check test ! -e "$work/api_store_field/NOT_BUILDABLE"
check grep -qF 'mrb_value (*fn)(mrb_state *mrb, const char *str, size_t len);' "$work/api_store_field/src/api_store_field.c"
check grep -qF 'return sf_cur.fn(mrb, str, len);' "$work/api_store_field/src/api_store_field.c"
check grep -qF '(struct RClass *[]){ E_TYPE_ERROR, mrb_exc_get(mrb, "EOFError") }' "$work/api_rescue2/src/api_rescue2.c"
# 2zzz111. a VALUE declaration list in a header (static VALUE a, b, c;) gives each class variable struct RClass *, and
# the first declarator that is not a class (assigned from rb_const_get) stays mrb_value; the uses keep their form.
rc=0; "$rb" "$conv" --scanner "$scanner" --name api_class_decl_list tools/cext2mrbgem/fixtures/api_class_decl_list/ext/api_class_decl_list "$work/api_class_decl_list" > "$work/api_class_decl_list.log" 2>&1 || rc=$?
check test "$rc" -eq 0
check test ! -e "$work/api_class_decl_list/NOT_BUILDABLE"
check grep -qF 'static mrb_value cStandardError; struct RClass *cA, *cB, *mM;' "$work/api_class_decl_list/include/api_class_decl_list.h"
# 2zzz112. a call compared with nil or false (==, !=) is a helper test of its value (nfcx_is_nil, mrb_false_p), once per file;
# the call is evaluated once.
rc=0; "$rb" "$conv" --scanner "$scanner" --name api_q_call_cmp tools/cext2mrbgem/fixtures/api_q_call_cmp/ext/api_q_call_cmp "$work/api_q_call_cmp" > "$work/api_q_call_cmp.log" 2>&1 || rc=$?
check test "$rc" -eq 0
check test ! -e "$work/api_q_call_cmp/NOT_BUILDABLE"
check grep -qF 'static mrb_bool nfcx_is_nil(mrb_value v) { return mrb_nil_p(v); }' "$work/api_q_call_cmp/src/api_q_call_cmp.c"
check grep -qF 'if (nfcx_is_nil(mrb_hash_get(mrb, h, k)' "$work/api_q_call_cmp/src/api_q_call_cmp.c"
check grep -qF 'if (!nfcx_is_false(mrb_hash_get(mrb, h, k)' "$work/api_q_call_cmp/src/api_q_call_cmp.c"
check grep -qF 'static mrb_value sym_key;' "$work/api_q_call_cmp/src/api_q_call_cmp.c"
check grep -qF 'mrb_funcall_argv(mrb, target, mid, 0, NULL)' "$work/api_q_call_cmp/src/api_q_call_cmp.c"
check grep -qF 'nfcx_long2int(mrb, ' "$work/api_q_call_cmp/src/api_q_call_cmp.c"
check grep -qF 'nfcx_check_symbol(mrb, "abc", 3)' "$work/api_q_call_cmp/src/api_q_call_cmp.c"
check grep -qF 'switch (nfcx_q_key(mrb, v))' "$work/api_q_call_cmp/src/api_q_call_cmp.c"
check grep -qF 'nfcx_get_kwargs(mrb, opts, kw_ids, 0, 1, &anchor)' "$work/api_q_call_cmp/src/api_q_call_cmp.c"
check grep -qE 'mrb_funcall_argv\(mrb, shadow_cls, mrb_intern_cstr\(mrb, "members"\)' "$work/api_q_call_cmp/src/api_q_call_cmp.c"
check grep -qF 'case 2: case 3:' "$work/api_q_call_cmp/src/api_q_call_cmp.c"
check grep -qF 'mrb_hash_get(mrb, h, sym_key)' "$work/api_q_call_cmp/src/api_q_call_cmp.c"
check grep -qF 'static mrb_value saved_nil ;' "$work/api_q_call_cmp/src/api_q_call_cmp.c"
check grep -qF 'saved_nil = mrb_nil_value();' "$work/api_q_call_cmp/src/api_q_call_cmp.c"
check grep -qF 'q->t = mrb_false_value();' "$work/api_q_call_cmp/src/api_q_call_cmp.c"
check grep -qE 'mrb_(obj_equal|value_identical)\(.*mrb_false_value\(\)' "$work/api_q_call_cmp/src/api_q_call_cmp.c"
# 2zzz113. a name pasted by a local macro is not a refused CRuby name; RUBY_TYPED_DEFAULT_FREE is mrb_free; a data type's
# mark callback is threaded (its initializer position is the identifier's, so the initializer use is not an escape).
rc=0; "$rb" "$conv" --scanner "$scanner" --name api_dtype_mark tools/cext2mrbgem/fixtures/api_dtype_mark/ext/api_dtype_mark "$work/api_dtype_mark" > "$work/api_dtype_mark.log" 2>&1 || rc=$?
check test "$rc" -eq 0
check test ! -e "$work/api_dtype_mark/NOT_BUILDABLE"
check grep -qF 'static void holder_mark(mrb_state *mrb, void *ptr) {' "$work/api_dtype_mark/src/api_dtype_mark.c"
check grep -qF 'mrb_free' "$work/api_dtype_mark/src/api_dtype_mark.c"
# 2zzz114. a #if of defined() atoms joined by && (defined(_LIBC) is false in a normal build) makes its block inactive: the call in
# it is not refused.
rc=0; "$rb" "$conv" --scanner "$scanner" --name api_defined_cond tools/cext2mrbgem/fixtures/api_defined_cond/ext/api_defined_cond "$work/api_defined_cond" > "$work/api_defined_cond.log" 2>&1 || rc=$?
check test "$rc" -eq 0
check test ! -e "$work/api_defined_cond/NOT_BUILDABLE"
# 2zzz115. rb_hash_foreach with a callback given by address (&cb) and a hash held in a struct field: the callback is the
# hash callback (its occurrence is the identifier after the &), so it is threaded and the call converts.
rc=0; "$rb" "$conv" --scanner "$scanner" --name api_hash_amp tools/cext2mrbgem/fixtures/api_hash_amp/ext/api_hash_amp "$work/api_hash_amp" > "$work/api_hash_amp.log" 2>&1 || rc=$?
check test "$rc" -eq 0
check test ! -e "$work/api_hash_amp/NOT_BUILDABLE"
check grep -qF 'mrb_hash_foreach(mrb, RHASH(h->hash), cb_count, (void *)&count);' "$work/api_hash_amp/src/api_hash_amp.c"
# 2zzz116. a macro whose last statement is `return E;`, expanded by a registered method, converts and compiles in both legs.
# (This fixture does not reach the global-state path, so the restore block is checked by the yajl corpus run, not here.)
rc=0; "$rb" "$conv" --scanner "$scanner" --name api_macro_final_return tools/cext2mrbgem/fixtures/api_macro_final_return/ext/api_macro_final_return "$work/api_macro_final_return" > "$work/api_macro_final_return.log" 2>&1 || rc=$?
check test "$rc" -eq 0
check test ! -e "$work/api_macro_final_return/NOT_BUILDABLE"
# 2zzz117. the coercion protocol (rb_num_coerce_bin, rb_num_coerce_cmp) is a file-scope helper (nfcx_num_coerce_*), placed before
# the macro or function that uses it; the calls convert.
rc=0; "$rb" "$conv" --scanner "$scanner" --name api_coerce tools/cext2mrbgem/fixtures/api_coerce/ext/api_coerce "$work/api_coerce" > "$work/api_coerce.log" 2>&1 || rc=$?
check test "$rc" -eq 0
check test ! -e "$work/api_coerce/NOT_BUILDABLE"
check grep -qF 'static mrb_value nfcx_num_coerce_bin(mrb_state *mrb, mrb_value x, mrb_value y, mrb_sym op) {' "$work/api_coerce/src/api_coerce.c"
check grep -qF 'nfcx_num_coerce_cmp(mrb, self, other, mrb_intern_cstr(mrb, "<=>"))' "$work/api_coerce/src/api_coerce.c"
check grep -qF 'nfcx_opts_exception_p(mrb, opts, 1)' "$work/api_coerce/src/api_coerce.c"
# 2zzz118. rb_ary_new3(__VA_ARGS__) in a variadic macro: each expansion's count and values go to the variadic helper nfcx_ary_new3.
rc=0; "$rb" "$conv" --scanner "$scanner" --name api_ary_new3_va tools/cext2mrbgem/fixtures/api_ary_new3_va/ext/api_ary_new3_va "$work/api_ary_new3_va" > "$work/api_ary_new3_va.log" 2>&1 || rc=$?
check test "$rc" -eq 0
check test ! -e "$work/api_ary_new3_va/NOT_BUILDABLE"
check grep -qF '#define pair_of(...) nfcx_ary_new3(api_ary_new3_va_bc2_mrb, __VA_ARGS__)' "$work/api_ary_new3_va/src/api_ary_new3_va.c"
check grep -qF 'nfcx_funcall_va(' "$work/api_ary_new3_va/src/api_ary_new3_va.c"
# 2zzz119. a Rational test (RB_TYPE_P T_RATIONAL) is a class test against the mruby-rational gem's class, and the generated
# mrbgem depends on that gem (only because such a test is emitted).
rc=0; "$rb" "$conv" --scanner "$scanner" --name api_rational_gem tools/cext2mrbgem/fixtures/api_rational_gem/ext/api_rational_gem "$work/api_rational_gem" > "$work/api_rational_gem.log" 2>&1 || rc=$?
check test "$rc" -eq 0
check test ! -e "$work/api_rational_gem/NOT_BUILDABLE"
check grep -qF 'mrb_class_get(mrb, "Rational")' "$work/api_rational_gem/src/api_rational_gem.c"
check grep -qF "spec.add_dependency 'mruby-rational'" "$work/api_rational_gem/mrbgem.rake"
# 2zzz120. the address of an owned class variable (struct RClass *) given to rb_gc_register_address is refused with its
# reason; the converter does not emit &mrb_obj_value(...), which does not compile.
rc=0; "$rb" "$conv" --scanner "$scanner" --name api_gc_addr_cls tools/cext2mrbgem/fixtures/api_gc_addr_cls/ext/api_gc_addr_cls "$work/api_gc_addr_cls" > "$work/api_gc_addr_cls.log" 2>&1 || rc=$?
check test ! -e "$work/api_gc_addr_cls/NOT_BUILDABLE"
# the registration of an owned class variable goes through the address helper (no GC-root refusal)
check grep -qF 'nfcx_gc_root_addr(mrb, (void *)&err_class, sizeof(err_class));' "$work/api_gc_addr_cls/src/api_gc_addr_cls.c"
check test "$(grep -c 'GC root' "$work/api_gc_addr_cls/REFUSALS.txt")" -eq 0
check bash -c "! grep -rqF '&mrb_obj_value(' '$work/api_gc_addr_cls'"
# 2zzz121. an ID pointer declared in a function body (ID *idp) is an mrb_sym pointer, as an ID variable is (the declaration
# test takes the * with or without spaces).
rc=0; "$rb" "$conv" --scanner "$scanner" --name api_id_ptr tools/cext2mrbgem/fixtures/api_id_ptr/ext/api_id_ptr "$work/api_id_ptr" > "$work/api_id_ptr.log" 2>&1 || rc=$?
check test "$rc" -eq 0
check test ! -e "$work/api_id_ptr/NOT_BUILDABLE"
check grep -qF 'mrb_sym *idp;' "$work/api_id_ptr/src/api_id_ptr.c"
# 2zzz122. a module (rb_mEnumerable) is a class argument of rb_class_inherited_p: it is the module's RClass * (mrb_module_get),
# and the call converts (the class test accepts module lookups as well as class lookups).
rc=0; "$rb" "$conv" --scanner "$scanner" --name api_module_arg tools/cext2mrbgem/fixtures/api_module_arg/ext/api_module_arg "$work/api_module_arg" > "$work/api_module_arg.log" 2>&1 || rc=$?
check test "$rc" -eq 0
check test ! -e "$work/api_module_arg/NOT_BUILDABLE"
check grep -qF 'mrb_class_inherited_p(mrb, mrb_class_ptr(clas), mrb_module_get(mrb, "Enumerable"))' "$work/api_module_arg/src/api_module_arg.c"
# 2zzz123. a VALUE local assigned a class definition and also Qundef is an mrb_value, not a struct RClass * (the class
# definition is wrapped with mrb_obj_value), so the converted function compiles and the Qundef assignment is valid.
rc=0; "$rb" "$conv" --scanner "$scanner" --name api_class_mixed tools/cext2mrbgem/fixtures/api_class_mixed/ext/api_class_mixed "$work/api_class_mixed" > "$work/api_class_mixed.log" 2>&1 || rc=$?
check test "$rc" -eq 0
check test ! -e "$work/api_class_mixed/NOT_BUILDABLE"
check grep -qF 'clas = mrb_obj_value(mrb_define_class_under(' "$work/api_class_mixed/src/api_class_mixed.c"
check grep -qF 'mrb_value clas;' "$work/api_class_mixed/src/api_class_mixed.c"
# 2zzz124. a VALUE cast to a pointer (void *)obj is a stuck point (VALUE as pointer): the fork's VALUE is a struct, so the
# cast has no mruby form, and the file is marked not buildable with that reason.
rc=0; "$rb" "$conv" --scanner "$scanner" --name api_value_ptr tools/cext2mrbgem/fixtures/api_value_ptr/ext/api_value_ptr "$work/api_value_ptr" > "$work/api_value_ptr.log" 2>&1 || rc=$?
check test ! -e "$work/api_value_ptr/NOT_BUILDABLE"
check grep -qF 'void *ctx = (void *)mrb_cptr(obj);' "$work/api_value_ptr/src/api_value_ptr.c"
# 2zzz125. assert(v) on a VALUE is a stuck point (VALUE truth test): the fork's VALUE is a struct, and no exact truth test is
# expressed (the assert is not weakened to a nil test).
rc=0; "$rb" "$conv" --scanner "$scanner" --name api_value_assert tools/cext2mrbgem/fixtures/api_value_assert/ext/api_value_assert "$work/api_value_assert" > "$work/api_value_assert.log" 2>&1 || rc=$?
check test -e "$work/api_value_assert/NOT_BUILDABLE"
check grep -qF 'stuck point (VALUE truth test): assert(obj)' "$work/api_value_assert/REFUSALS.txt"
# 2zzz126. rb_data_typed_object_zalloc is a VALUE (the data object is wrapped with mrb_obj_value), and a cast to ID, (ID)x, is an
# mrb_sym cast.
rc=0; "$rb" "$conv" --scanner "$scanner" --name api_zalloc_idcast tools/cext2mrbgem/fixtures/api_zalloc_idcast/ext/api_zalloc_idcast "$work/api_zalloc_idcast" > "$work/api_zalloc_idcast.log" 2>&1 || rc=$?
check test "$rc" -eq 0
check test ! -e "$work/api_zalloc_idcast/NOT_BUILDABLE"
check grep -qF 'mrb_value obj = mrb_obj_value(mrb_data_object_alloc(mrb, mrb->object_class, mrb_calloc(mrb, 1, sz), &zb_type));' "$work/api_zalloc_idcast/src/api_zalloc_idcast.c"
check grep -qF 'f = (mrb_sym)mrb_intern_cstr(mrb, "a");' "$work/api_zalloc_idcast/src/api_zalloc_idcast.c"
# 2zzz127. CRuby's MEMCPY(p, src, type, n) is memcpy with sizeof(type)*(n), and PRIdVALUE is "ld" (a printf format for a VALUE-sized
# signed value); the call converts with those forms.
rc=0; "$rb" "$conv" --scanner "$scanner" --name api_memcpy_pri tools/cext2mrbgem/fixtures/api_memcpy_pri/ext/api_memcpy_pri "$work/api_memcpy_pri" > "$work/api_memcpy_pri.log" 2>&1 || rc=$?
check test "$rc" -eq 0
check test ! -e "$work/api_memcpy_pri/NOT_BUILDABLE"
check grep -qF 'memcpy(buf, RSTRING_PTR(str), sizeof(char)*(n));' "$work/api_memcpy_pri/src/api_memcpy_pri.c"
# 2zzz128. the dropped encoding argument of rb_enc_str_new may be a pure member read (opt->active_enc has no side effect), as a plain
# name is; the call converts with the bytes kept (mruby strings carry no encoding).
rc=0; "$rb" "$conv" --scanner "$scanner" --name api_enc_member tools/cext2mrbgem/fixtures/api_enc_member/ext/api_enc_member "$work/api_enc_member" > "$work/api_enc_member.log" 2>&1 || rc=$?
check test "$rc" -eq 0
check test ! -e "$work/api_enc_member/NOT_BUILDABLE"
check grep -qF 'mrb_str_new(mrb, H.data, H.size)' "$work/api_enc_member/src/api_enc_member.c"
# 2zzz129. rb_memsearch (the byte offset of a needle in a haystack, or -1) is a prelude helper nfcx_memsearch; its encoding argument
# is dropped (mruby strings carry no encoding), and the call converts.
rc=0; "$rb" "$conv" --scanner "$scanner" --name api_memsearch tools/cext2mrbgem/fixtures/api_memsearch/ext/api_memsearch "$work/api_memsearch" > "$work/api_memsearch.log" 2>&1 || rc=$?
check test "$rc" -eq 0
check test ! -e "$work/api_memsearch/NOT_BUILDABLE"
check grep -qF 'static long nfcx_memsearch(const char *x, long m, const char *y, long n) {' "$work/api_memsearch/src/api_memsearch.c"
check grep -qF 'nfcx_memsearch(RSTRING_PTR(needle), RSTRING_LEN(needle),' "$work/api_memsearch/src/api_memsearch.c"
# 2zzz130. rb_hash_foreach with a pointer cast to VALUE as its data is a stuck point (VALUE as pointer): the VALUE struct cannot hold
# the pointer, so the file is marked not buildable with that reason (not the generic form refusal).
rc=0; "$rb" "$conv" --scanner "$scanner" --name api_hash_ptr_stuck tools/cext2mrbgem/fixtures/api_hash_ptr_stuck/ext/api_hash_ptr_stuck "$work/api_hash_ptr_stuck" > "$work/api_hash_ptr_stuck.log" 2>&1 || rc=$?
check test ! -e "$work/api_hash_ptr_stuck/NOT_BUILDABLE"
check test "$(grep -c 'mrb_hash_foreach(mrb, RHASH(h), count_cb, (void \*)p);' "$work/api_hash_ptr_stuck/src/api_hash_ptr_stuck.c")" -eq 2
# 2zzz131. a struct field declared with the name of a registered method (char to_json;) and member accesses of it are not uses of the
# method: the method converts, and the file is not refused as a direct-called or address-taken function.
rc=0; "$rb" "$conv" --scanner "$scanner" --name api_field_named_fn tools/cext2mrbgem/fixtures/api_field_named_fn/ext/api_field_named_fn "$work/api_field_named_fn" > "$work/api_field_named_fn.log" 2>&1 || rc=$?
check test "$rc" -eq 0
check test ! -e "$work/api_field_named_fn/NOT_BUILDABLE"
check grep -qF 'char to_json;' "$work/api_field_named_fn/src/api_field_named_fn.c"
# 2zzz132. RB_TYPE_P(x, T_STRUCT) is the Struct class test (mrb_obj_is_kind_of, which covers the Struct subclasses CRuby's T_STRUCT
# includes), and the generated mrbgem depends on mruby-struct (only because the test is emitted).
rc=0; "$rb" "$conv" --scanner "$scanner" --name api_struct_type tools/cext2mrbgem/fixtures/api_struct_type/ext/api_struct_type "$work/api_struct_type" > "$work/api_struct_type.log" 2>&1 || rc=$?
check test "$rc" -eq 0
check test ! -e "$work/api_struct_type/NOT_BUILDABLE"
check grep -qF 'mrb_obj_is_kind_of(mrb, obj, mrb_class_get(mrb, "Struct"))' "$work/api_struct_type/src/api_struct_type.c"
check grep -qF "spec.add_dependency 'mruby-struct'" "$work/api_struct_type/mrbgem.rake"
# 2zzz133. rb_scan_args with a NULL output (the argument is discarded) takes a dummy VALUE declared at the start of the function; the
# call converts and the output is the one given.
rc=0; "$rb" "$conv" --scanner "$scanner" --name api_scan_null tools/cext2mrbgem/fixtures/api_scan_null/ext/api_scan_null "$work/api_scan_null" > "$work/api_scan_null.log" 2>&1 || rc=$?
check test "$rc" -eq 0
check test ! -e "$work/api_scan_null/NOT_BUILDABLE"
check grep -qF 'mrb_value nfcx_skip' "$work/api_scan_null/src/api_scan_null.c"
# 2zzz134. a helper prototype wrapped in MAYBE_UNUSED(...) (CRuby's identity wrapper around a declaration) is a prototype like the
# others: it takes the mruby state with the definition, and the call converts.
rc=0; "$rb" "$conv" --scanner "$scanner" --name api_maybe_unused_proto tools/cext2mrbgem/fixtures/api_maybe_unused_proto/ext/api_maybe_unused_proto "$work/api_maybe_unused_proto" > "$work/api_maybe_unused_proto.log" 2>&1 || rc=$?
check test "$rc" -eq 0
check test ! -e "$work/api_maybe_unused_proto/NOT_BUILDABLE"
check grep -qF 'static mrb_value make_pair(mrb_state *mrb, int n);' "$work/api_maybe_unused_proto/src/api_maybe_unused_proto.c"
# 2zzz135. an object-like alias of a threaded helper (#define MakeOne wrap_one) is called as the helper: its call gets the state, and
# the call converts (an alias that names an API entry is not threaded: its mapping decides).
rc=0; "$rb" "$conv" --scanner "$scanner" --name api_alias_thread tools/cext2mrbgem/fixtures/api_alias_thread/ext/api_alias_thread "$work/api_alias_thread" > "$work/api_alias_thread.log" 2>&1 || rc=$?
check test "$rc" -eq 0
check test ! -e "$work/api_alias_thread/NOT_BUILDABLE"
check grep -qF 'return MakeOne(mrb, v);' "$work/api_alias_thread/src/api_alias_thread.c"
# 2zzz136. RB_ALLOCV_N (a temporary buffer) in a pointer declaration is mrb_malloc, and RB_ALLOCV_END of its VALUE is the mrb_free of that
# pointer; the pair converts. A return between them would leak the buffer, so that pair is a stuck point.
rc=0; "$rb" "$conv" --scanner "$scanner" --name api_allocv_pair tools/cext2mrbgem/fixtures/api_allocv_pair/ext/api_allocv_pair "$work/api_allocv_pair" > "$work/api_allocv_pair.log" 2>&1 || rc=$?
check test "$rc" -eq 0
check test ! -e "$work/api_allocv_pair/NOT_BUILDABLE"
check grep -qF 'char *buffer = (char *)mrb_malloc(mrb, sizeof(char) * (len + 1));' "$work/api_allocv_pair/src/api_allocv_pair.c"
check grep -qF 'mrb_free(mrb, buffer);' "$work/api_allocv_pair/src/api_allocv_pair.c"
# 2zzz137. --stored-tag T_NIL=VALUE (the build configuration names T_NIL a stored integer tag) maps the tag's uses to the value; without it the
# tag stays a refusal (the fork cannot tell nil from false by type).
rc=0; "$rb" "$conv" --scanner "$scanner" --name api_stored_tag --stored-tag T_NIL=0xf0 tools/cext2mrbgem/fixtures/api_stored_tag/ext/api_stored_tag "$work/api_stored_tag" > "$work/api_stored_tag.log" 2>&1 || rc=$?
check test "$rc" -eq 0
check test ! -e "$work/api_stored_tag/NOT_BUILDABLE"
check grep -qF 'case 0xf0: return mrb_nil_value();' "$work/api_stored_tag/src/api_stored_tag.c"
check grep -qF 'it.tag = 0xf0;' "$work/api_stored_tag/src/api_stored_tag.c"
# 2zzz138. --method-scope-fn NAME: a helper whose address is stored (a struct function pointer) takes the state from the gem's global, which
# the registered method sets and restores, so its signature is unchanged (the stored pointer's type still matches).
rc=0; "$rb" "$conv" --scanner "$scanner" --name api_method_scope --method-scope-fn note tools/cext2mrbgem/fixtures/api_method_scope/ext/api_method_scope "$work/api_method_scope" > "$work/api_method_scope.log" 2>&1 || rc=$?
check test "$rc" -eq 0
check test ! -e "$work/api_method_scope/NOT_BUILDABLE"
check grep -qF 'last = mrb_str_dup(api_method_scope_bc2_mrb, v);' "$work/api_method_scope/src/api_method_scope.c"
check grep -qF 'api_method_scope_bc2_mrb = mrb;' "$work/api_method_scope/src/api_method_scope.c"
# 2zzz139. rb_class_new_instance(argc expression, argv expression, rb_cX) converts through the order-preserving helper nfcx_class_new_instance
# (the arguments are kept in CRuby's order, and a mapped class constant needs no unwrapping).
rc=0; "$rb" "$conv" --scanner "$scanner" --name api_class_new_expr tools/cext2mrbgem/fixtures/api_class_new_expr/ext/api_class_new_expr "$work/api_class_new_expr" > "$work/api_class_new_expr.log" 2>&1 || rc=$?
check test "$rc" -eq 0
check test ! -e "$work/api_class_new_expr/NOT_BUILDABLE"
check grep -qF 'nfcx_class_new_instance(mrb, (int)(RARRAY_LEN(arr) - 1), RARRAY_PTR(arr) + 1, mrb->range_class)' "$work/api_class_new_expr/src/api_class_new_expr.c"
# 2zzz140. T_STRUCT compared with rb_type of an object (!= and ==) is the Struct class test, as one rewrite: the != is the negation, and
# the mruby-struct gem is a dependency.
rc=0; "$rb" "$conv" --scanner "$scanner" --name api_struct_cmp tools/cext2mrbgem/fixtures/api_struct_cmp/ext/api_struct_cmp "$work/api_struct_cmp" > "$work/api_struct_cmp.log" 2>&1 || rc=$?
check test "$rc" -eq 0
check test ! -e "$work/api_struct_cmp/NOT_BUILDABLE"
check grep -qF 'if (!mrb_obj_is_kind_of(mrb, obj, mrb_class_get(mrb, "Struct"))) {' "$work/api_struct_cmp/src/api_struct_cmp.c"
check grep -qF 'if (mrb_obj_is_kind_of(mrb, obj, mrb_class_get(mrb, "Struct"))) {' "$work/api_struct_cmp/src/api_struct_cmp.c"
check grep -qF "spec.add_dependency 'mruby-struct'" "$work/api_struct_cmp/mrbgem.rake"
# 2zzz141. #include <ruby/st.h> is dropped (its st_retval codes are mapped; no st table is used), so the file converts; a callback returning
# ST_CONTINUE is the mapped 0.
rc=0; "$rb" "$conv" --scanner "$scanner" --name api_st_include tools/cext2mrbgem/fixtures/api_st_include/ext/api_st_include "$work/api_st_include" > "$work/api_st_include.log" 2>&1 || rc=$?
check test "$rc" -eq 0
check test ! -e "$work/api_st_include/NOT_BUILDABLE"
check grep -qF 'return 0;' "$work/api_st_include/src/api_st_include.c"
# 2zzz142. a union member is a field when deciding whether a name is a VALUE field: a name that is a VALUE member of one struct and an integer
# member of a union is not a VALUE field, so the integer assignment (c.value = 0) keeps its integer 0.
rc=0; "$rb" "$conv" --scanner "$scanner" --name api_union_field tools/cext2mrbgem/fixtures/api_union_field/ext/api_union_field "$work/api_union_field" > "$work/api_union_field.log" 2>&1 || rc=$?
check test "$rc" -eq 0
check test ! -e "$work/api_union_field/NOT_BUILDABLE"
check grep -qF 'c.value = 0;' "$work/api_union_field/src/api_union_field.c"
check grep -qF 'h.value = mrb_nil_value();' "$work/api_union_field/src/api_union_field.c"
# 2zzz143. a rb_hash_foreach callback whose data is a VALUE name (not a pointer cast) takes the data by address: the call passes (void *)&proc,
# the callback reads its VALUE copy at its start, and its direct calls (including one with a Q constant) pass the data by address too.
rc=0; "$rb" "$conv" --scanner "$scanner" --name api_hash_value_data tools/cext2mrbgem/fixtures/api_hash_value_data/ext/api_hash_value_data "$work/api_hash_value_data" > "$work/api_hash_value_data.log" 2>&1 || rc=$?
check test "$rc" -eq 0
check test ! -e "$work/api_hash_value_data/NOT_BUILDABLE"
check grep -qF 'mrb_hash_foreach(mrb, RHASH(value), walk, (void *)&proc);' "$work/api_hash_value_data/src/api_hash_value_data.c"
check grep -qF 'mrb_value proc = *(mrb_value *)nfcx_data_proc;' "$work/api_hash_value_data/src/api_hash_value_data.c"
check grep -qF 'walk(mrb, mrb_nil_value(), h, (void *)&(mrb_value[]){mrb_nil_value()});' "$work/api_hash_value_data/src/api_hash_value_data.c"
# 2zzz144. a comparison of two VALUE expressions that are calls (rb_obj_class(a) == rb_obj_class(b)) is mrb_value_identical of the operands
# (the != is its negation), a class constant (rb_cObject) is its VALUE, and a struct field named like a class variable stays a field.
rc=0; "$rb" "$conv" --scanner "$scanner" --name api_value_cmp tools/cext2mrbgem/fixtures/api_value_cmp/ext/api_value_cmp "$work/api_value_cmp" > "$work/api_value_cmp.log" 2>&1 || rc=$?
check test "$rc" -eq 0
check test ! -e "$work/api_value_cmp/NOT_BUILDABLE"
check grep -qF 'if (mrb_value_identical(mrb_obj_value(mrb_obj_class(mrb, a)) ,  mrb_obj_value(mrb_obj_class(mrb, b)))) {' "$work/api_value_cmp/src/api_value_cmp.c"
check grep -qF 'c.json_cls = "x";' "$work/api_value_cmp/src/api_value_cmp.c"
# 2zzz145. rb_hash_lookup(h, key) gets its default (mrb_nil_value()) after the call's own arguments: a key that is itself a call (its
# closing parenthesis is not the call's) keeps its text, and the call compiles.
rc=0; "$rb" "$conv" --scanner "$scanner" --name api_hash_lookup_arg tools/cext2mrbgem/fixtures/api_hash_lookup_arg/ext/api_hash_lookup_arg "$work/api_hash_lookup_arg" > "$work/api_hash_lookup_arg.log" 2>&1 || rc=$?
check test "$rc" -eq 0
check test ! -e "$work/api_hash_lookup_arg/NOT_BUILDABLE"
check grep -qF 'mrb_hash_fetch(mrb, hash, mrb_symbol_value(mrb_intern_cstr(mrb, "lax")), mrb_nil_value())' "$work/api_hash_lookup_arg/src/api_hash_lookup_arg.c"
# 2zzz146. a VALUE call result used as a truth value beside && is mrb_test(...), and a literal 0 compared with a VALUE is mrb_false_value()
# (CRuby's Qfalse); the converted function compiles.
rc=0; "$rb" "$conv" --scanner "$scanner" --name api_truth_zero tools/cext2mrbgem/fixtures/api_truth_zero/ext/api_truth_zero "$work/api_truth_zero" > "$work/api_truth_zero.log" 2>&1 || rc=$?
check test "$rc" -eq 0
check test ! -e "$work/api_truth_zero/NOT_BUILDABLE"
check grep -qF 'mrb_test(' "$work/api_truth_zero/src/api_truth_zero.c"
check grep -qF 'mrb_false_value()' "$work/api_truth_zero/src/api_truth_zero.c"
# 2zzz147. a VALUE passed where a converted function takes an integer key (the word of the VALUE in CRuby) is a stuck point
# (VALUE as integer): the fork's VALUE is a struct with no integer form, so the file is marked not buildable with that reason.
rc=0; "$rb" "$conv" --scanner "$scanner" --name api_value_int tools/cext2mrbgem/fixtures/api_value_int/ext/api_value_int "$work/api_value_int" > "$work/api_value_int.log" 2>&1 || rc=$?
check test -e "$work/api_value_int/NOT_BUILDABLE"
check grep -qF 'stuck point (VALUE as integer): obj is a VALUE' "$work/api_value_int/REFUSALS.txt"
# 2zzz148. if (v) on a VALUE is a stuck point (VALUE truth test): CRuby's nonzero word is true for nil as well, which the fork's
# VALUE struct has no exact test of, so the file is marked not buildable with that reason.
rc=0; "$rb" "$conv" --scanner "$scanner" --name api_value_if tools/cext2mrbgem/fixtures/api_value_if/ext/api_value_if "$work/api_value_if" > "$work/api_value_if.log" 2>&1 || rc=$?
check test ! -e "$work/api_value_if/NOT_BUILDABLE"
check grep -qF 'if (!mrb_false_p(v))' "$work/api_value_if/src/api_value_if.c"
# 2zzz149. if (v) is mapped (no stub): the function keeps its body, and gem_init.c carries no #error.
check test "$(grep -c 'BC2CPP-MRBGEM stub' "$work/api_value_if/src/api_value_if.c")" -eq 0
check test "$(grep -c '#error' "$work/api_value_if/src/gem_init.c")" -eq 0
# 2zzz150. an ID returned from a VALUE function is the symbol value (mrb_symbol_value), and a VALUE call returned from an ID
# function is read as its symbol (mrb_symbol), the fork's symbol carried in a value.
rc=0; "$rb" "$conv" --scanner "$scanner" --name api_id_return tools/cext2mrbgem/fixtures/api_id_return/ext/api_id_return "$work/api_id_return" > "$work/api_id_return.log" 2>&1 || rc=$?
check grep -qF 'return mrb_symbol_value(id);' "$work/api_id_return/src/api_id_return.c"
check grep -qF 'mrb_symbol(' "$work/api_id_return/src/api_id_return.c"
# 2zzz151. a refused statement in Init is dropped as a no-op (the user's decision): the gem loads, so gem_init.c has no #error
# and the statement is recorded as dropped in REFUSALS.txt.
rc=0; "$rb" "$conv" --scanner "$scanner" --name api_init_drop tools/cext2mrbgem/fixtures/api_init_drop/ext/api_init_drop "$work/api_init_drop" > "$work/api_init_drop.log" 2>&1 || rc=$?
check grep -qF 'BC2CPP-MRBGEM dropped in Init (rb_thread_local_aset)' "$work/api_init_drop/src/api_init_drop.c"
check test "$(grep -c '#error' "$work/api_init_drop/src/gem_init.c")" -eq 0
check grep -qF '[dropped in Init' "$work/api_init_drop/REFUSALS.txt"
check grep -qF 'STATUS: STUBBED' "$work/api_init_drop/REFUSALS.txt"
# 2zzz152. --rename OLD=NEW renames the gem's identifier in its sources, and --replace OLD=NEW replaces literal text (the signature
# the header and the definition agree on): the renamed definition takes void *data, and nothing names the old identifier.
rc=0; "$rb" "$conv" --scanner "$scanner" --name api_rename_replace --rename crypt_r=nfcx_crypt_r --replace 'nfcx_crypt_r(const char *key, const char *setting, struct crypt_data *data)=nfcx_crypt_r(const char *key, const char *setting, void *data)' tools/cext2mrbgem/fixtures/api_rename_replace/ext/api_rename_replace "$work/api_rename_replace" > "$work/api_rename_replace.log" 2>&1 || rc=$?
check test "$rc" -eq 0
check test ! -e "$work/api_rename_replace/NOT_BUILDABLE"
check grep -qF 'nfcx_crypt_r(const char *key, const char *setting, void *data)' "$work/api_rename_replace/src/api_rename_replace.c"
check test "$(grep -c 'crypt_r' "$work/api_rename_replace/src/api_rename_replace.c" | head -1)" -ge 1
check test "$(grep -cw 'crypt_r' "$work/api_rename_replace/src/api_rename_replace.c")" -eq 0
# 2zzz153. --exclude FILE leaves a source out of the conversion: extra_only.c's refused thread call never reaches the output.
rc=0; "$rb" "$conv" --scanner "$scanner" --name api_exclude --exclude extra_only.c tools/cext2mrbgem/fixtures/api_exclude/ext/api_exclude "$work/api_exclude" > "$work/api_exclude.log" 2>&1 || rc=$?
check test "$rc" -eq 0
check test ! -e "$work/api_exclude/src/extra_only.c"
check test ! -s "$work/api_exclude/REFUSALS.txt" -o "$(grep -c 'rb_thread_current' "$work/api_exclude/REFUSALS.txt")" = 0
# 2zzz154. a helper called by a pasted name in a macro (CALL_HELPER(xy, v) is xy##_helper(v)) passes the state, as the helper takes
# it: the macro's call is xy##_helper(mrb, v) (the same rule that keeps date's jd_trunc in use).
rc=0; "$rb" "$conv" --scanner "$scanner" --name api_paste_macro tools/cext2mrbgem/fixtures/api_paste_macro/ext/api_paste_macro "$work/api_paste_macro" > "$work/api_paste_macro.log" 2>&1 || rc=$?
check test "$rc" -eq 0
check test ! -e "$work/api_paste_macro/NOT_BUILDABLE"
check grep -qF '##_helper(mrb, v)' "$work/api_paste_macro/src/api_paste_macro.c"
# 2zzz157. a callback field called from a function whose address is taken in a dispatch table (fd_table): that function keeps its C
# signature, so the field and the callback stored in it take no mruby state (a threaded callback with an unthreaded caller was a
# silent mismatch, which the redcarpet render path crashed on)
rc=0; "$rb" "$conv" --scanner "$scanner" --name api_fnptr_dispatch tools/cext2mrbgem/fixtures/api_fnptr_dispatch/ext/api_fnptr_dispatch "$work/api_fnptr_dispatch" > "$work/api_fnptr_dispatch.log" 2>&1 || rc=$?
check test "$rc" -eq 0
check grep -qF 'void (*emit)(struct fd_sink *s, mrb_value v);' "$work/api_fnptr_dispatch/src/api_fnptr_dispatch.c"
check grep -qF 's->emit(s, mrb_fixnum_value((int)n));' "$work/api_fnptr_dispatch/src/api_fnptr_dispatch.c"
check grep -qF 'static void fd_store(struct fd_sink *s, mrb_value v) {' "$work/api_fnptr_dispatch/src/api_fnptr_dispatch.c"
# 2zzz158. the encoding index API: RB_ENCODING_GET and ENCODING_SET read and write a string's index, rb_enc_strlen counts UTF-8
# characters, rb_enc_find_index looks an encoding up by name, and rb_eEncodingError is the fork's EncodingError class.
rc=0; "$rb" "$conv" --scanner "$scanner" --name api_enc_index tools/cext2mrbgem/fixtures/api_enc_index/ext/api_enc_index "$work/api_enc_index" > "$work/api_enc_index.log" 2>&1 || rc=$?
check test "$rc" -eq 0
check test ! -e "$work/api_enc_index/NOT_BUILDABLE"
check grep -qF 'int i = rb_enc_get_index(str);' "$work/api_enc_index/src/api_enc_index.c"
check grep -qF 'rb_enc_strlen(p, p + RSTRING_LEN(str), rb_utf8_encoding())' "$work/api_enc_index/src/api_enc_index.c"
check grep -qF 'rb_enc_set_index(str, rb_usascii_encindex());' "$work/api_enc_index/src/api_enc_index.c"
check grep -qF 'mrb_raisef(mrb, mrb_class_get(mrb, "EncodingError"), "bad encoding");' "$work/api_enc_index/src/api_enc_index.c"
# 2zzz159. CRuby's Onigmo API maps to the fork's mruby/onigmo.h (the system oniguruma library): RB_TYPE_P(v, T_REGEXP) is the
# Regexp test of the mruby-onig-regexp gem, RREGEXP_PTR is its compiled regex, and the region calls are the library's.
rc=0; "$rb" "$conv" --scanner "$scanner" --name api_onig_map tools/cext2mrbgem/fixtures/api_onig_map/ext/api_onig_map "$work/api_onig_map" > "$work/api_onig_map.log" 2>&1 || rc=$?
check test "$rc" -eq 0
check test ! -e "$work/api_onig_map/NOT_BUILDABLE"
check grep -qF 'return mruby_onig_regexp_is(v) ? mrb_true_value() : mrb_false_value();' "$work/api_onig_map/src/api_onig_map.c"
check grep -qF 'onig_region_init(&regs);' "$work/api_onig_map/src/api_onig_map.c"
check grep -qF 'pos = onig_search(RREGEXP_PTR(re),' "$work/api_onig_map/src/api_onig_map.c"
check grep -qF '#include <mruby/onigmo.h>' "$work/api_onig_map/src/api_onig_map.c"
# 2zzz160. rb_require of a literal feature maps to the fork's require, and a gem that provides it (time, stringio) becomes a
# dependency of the converted gem; a non-literal name stays a stuck point. The gem's own gemspec (its runtime dependencies) adds
# the dependency of a built gem (bigdecimal), and a development dependency (rake) is not one.
rc=0; "$rb" "$conv" --scanner "$scanner" --name api_require tools/cext2mrbgem/fixtures/api_require/ext/api_require "$work/api_require" > "$work/api_require.log" 2>&1 || rc=$?
check test "$rc" -eq 2
check grep -qF 'rb_require(mrb, "time");' "$work/api_require/src/api_require.c"
check grep -qF 'rb_require(mrb, "stringio");' "$work/api_require/src/api_require.c"
check grep -q "spec.add_dependency 'mruby-stringio'" "$work/api_require/mrbgem.rake"
check grep -q "spec.add_dependency 'mruby-time'" "$work/api_require/mrbgem.rake"
check grep -q "spec.add_dependency 'bigdecimal'  # runtime dependency bigdecimal (gemspec metadata)" "$work/api_require/mrbgem.rake"
check test "$(grep -c 'rake' "$work/api_require/mrbgem.rake")" -eq 0
check grep -q 'feature name is not a literal' "$work/api_require/REFUSALS.txt"
# 2zzz161. the encoding helpers: rb_enc_codepoint_len and rb_str_conv_enc and rb_enc_from_encoding take the state (the fork's
# functions raise and name the encoding); rb_enc_raise is a rb_raise with the encoding argument dropped.
rc=0; "$rb" "$conv" --scanner "$scanner" --name api_enc_helpers tools/cext2mrbgem/fixtures/api_enc_helpers/ext/api_enc_helpers "$work/api_enc_helpers" > "$work/api_enc_helpers.log" 2>&1 || rc=$?
check test "$rc" -eq 0
check test ! -e "$work/api_enc_helpers/NOT_BUILDABLE"
check grep -qF 'rb_enc_codepoint_len(mrb, p, p + RSTRING_LEN(str), &len, rb_utf8_encoding())' "$work/api_enc_helpers/src/api_enc_helpers.c"
check grep -qF 'rb_str_conv_enc(mrb, str, rb_utf8_encoding(), rb_usascii_encoding())' "$work/api_enc_helpers/src/api_enc_helpers.c"
check grep -qF 'rb_enc_from_encoding(mrb, rb_utf8_encoding())' "$work/api_enc_helpers/src/api_enc_helpers.c"
check grep -qF 'mrb_raisef(mrb, mrb_class_get(mrb, "EncodingError"), "bad: %s", mrb_string_value_cstr(mrb, &msg));' "$work/api_enc_helpers/src/api_enc_helpers.c"
check grep -qF 'return rb_enc_sprintf(mrb, rb_utf8_encoding(), "[%""S""]", v);' "$work/api_enc_helpers/src/api_enc_helpers.c"
# 2zzz162. a relational comparison of two VALUEs orders them by object address (mrb_value_addr), so a table sorted and searched in
# VALUE order converts; the comparison is not a stuck point.
rc=0; "$rb" "$conv" --scanner "$scanner" --name api_value_order tools/cext2mrbgem/fixtures/api_value_order/ext/api_value_order "$work/api_value_order" > "$work/api_value_order.log" 2>&1 || rc=$?
check test "$rc" -eq 0
check test ! -e "$work/api_value_order/NOT_BUILDABLE"
check grep -qF 'return mrb_value_addr(a) < mrb_value_addr(b);' "$work/api_value_order/src/api_value_order.c"
# 2zzz163. Bignum conversions map to the fork's bigint helpers (mrb_bint_as_int64, as_uint64, new_uint64, absint_size, sign,
# bint_cmp); none of them is a stuck point any more.
rc=0; "$rb" "$conv" --scanner "$scanner" --name api_bignum tools/cext2mrbgem/fixtures/api_bignum/ext/api_bignum "$work/api_bignum" > "$work/api_bignum.log" 2>&1 || rc=$?
check test "$rc" -eq 0
check grep -qF 'mrb_bint_as_int64(mrb, ' "$work/api_bignum/src/api_bignum.c"
check grep -qF 'mrb_bint_as_uint64(mrb, ' "$work/api_bignum/src/api_bignum.c"
check grep -qF 'mrb_bint_new_uint64(mrb, (uint64_t)' "$work/api_bignum/src/api_bignum.c"
check grep -qF 'mrb_bint_absint_size(mrb, ' "$work/api_bignum/src/api_bignum.c"
check grep -qF 'mrb_fixnum_value(mrb_bint_cmp(mrb, ' "$work/api_bignum/src/api_bignum.c"
check grep -qF '(mrb_bint_sign(mrb, ' "$work/api_bignum/src/api_bignum.c"
check test "$(grep -c 'stuck point' "$work/api_bignum/REFUSALS.txt" 2>/dev/null)" -eq 0

# 2zzz166. a class variable registered as a GC root (rb_gc_register_address, rb_global_variable): the registration is the
# nfcx_gc_root_addr helper on the variable's address (a class is rooted by its class value once set), not a stuck point.
rc=0; "$rb" "$conv" --scanner "$scanner" --name api_gc_class_root tools/cext2mrbgem/fixtures/api_gc_class_root/ext/api_gc_class_root "$work/api_gc_class_root" > "$work/api_gc_class_root.log" 2>&1 || rc=$?
check test "$rc" -eq 0
check test ! -e "$work/api_gc_class_root/NOT_BUILDABLE"
check grep -qF 'nfcx_gc_root_addr(mrb, (void *)&cWidget, sizeof(cWidget));' "$work/api_gc_class_root/src/api_gc_class_root.c"
check grep -qF 'nfcx_gc_root_addr(mrb, (void *)&cGizmo, sizeof(cGizmo));' "$work/api_gc_class_root/src/api_gc_class_root.c"
check test "$(grep -c 'GC root' "$work/api_gc_class_root/REFUSALS.txt")" -eq 0
# 2zzz164. rb_define_alloc_func: the allocator is a registered function of the state, and the class gets allocate and new
# singleton methods that call it (nfcx_alloc_register, with the prelude in the same file); no per-class-allocator refusal.
rc=0; "$rb" "$conv" --scanner "$scanner" --name api_alloc_class tools/cext2mrbgem/fixtures/api_alloc_class/ext/api_alloc_class "$work/api_alloc_class" > "$work/api_alloc_class.log" 2>&1 || rc=$?
check test "$rc" -eq 0
check test ! -e "$work/api_alloc_class/NOT_BUILDABLE"
check grep -qF 'static mrb_value ac_alloc(mrb_state *mrb, mrb_value klass) {' "$work/api_alloc_class/src/api_alloc_class.c"
check grep -qF 'nfcx_alloc_register(mrb, k, ac_alloc);' "$work/api_alloc_class/src/api_alloc_class.c"
check grep -qF 'mrb_define_class_method(mrb, c, "new", nfcx_alloc_new, MRB_ARGS_ANY());' "$work/api_alloc_class/src/api_alloc_class.c"
check test "$(grep -c 'per-class allocator' "$work/api_alloc_class/REFUSALS.txt")" -eq 0
# 2zzz167. == and != between VALUEs are identity: a VALUE parameter against another VALUE (mrb_obj_equal, the existing pass) and
# a VALUE against a symbol call (mrb_value_identical: the operand is a call the existing pass does not take).
rc=0; "$rb" "$conv" --scanner "$scanner" --name api_value_identity tools/cext2mrbgem/fixtures/api_value_identity/ext/api_value_identity "$work/api_value_identity" > "$work/api_value_identity.log" 2>&1 || rc=$?
check test "$rc" -eq 0
check test ! -e "$work/api_value_identity/NOT_BUILDABLE"
check grep -qF 'return (mrb_obj_equal(mrb, a, b)) ? mrb_true_value() : mrb_false_value();' "$work/api_value_identity/src/api_value_identity.c"
check grep -qF 'mrb_value_identical(k ,  mrb_symbol_value(mrb_intern_cstr(mrb, "ordinal")))' "$work/api_value_identity/src/api_value_identity.c"
# 2zzz168. a mutex (rb_mutex_new, lock, unlock) and the current thread convert to nil and no-ops (one thread in mruby, so the lock
# never contends); no Thread refusal for them.
rc=0; "$rb" "$conv" --scanner "$scanner" --name api_mutex_thread tools/cext2mrbgem/fixtures/api_mutex_thread/ext/api_mutex_thread "$work/api_mutex_thread" > "$work/api_mutex_thread.log" 2>&1 || rc=$?
check test "$rc" -eq 0
check test ! -e "$work/api_mutex_thread/NOT_BUILDABLE"
check grep -qF 'mrb_value mu = mrb_nil_value();' "$work/api_mutex_thread/src/api_mutex_thread.c"
check grep -qF '((void)(mu), mrb_nil_value());' "$work/api_mutex_thread/src/api_mutex_thread.c"
check test "$(grep -c 'Thread' "$work/api_mutex_thread/REFUSALS.txt")" -eq 0
# 2zzz169. rb_struct_define and rb_struct_new of the mruby-struct gem: the variadic helpers (Struct.new of the member symbols, and
# klass.new with the members' count of values); the gem is a dependency.
rc=0; "$rb" "$conv" --scanner "$scanner" --name api_struct_va tools/cext2mrbgem/fixtures/api_struct_va/ext/api_struct_va "$work/api_struct_va" > "$work/api_struct_va.log" 2>&1 || rc=$?
check test "$rc" -eq 0
check test ! -e "$work/api_struct_va/NOT_BUILDABLE"
check grep -qF 'return nfcx_struct_new(mrb, sv_point, x, y);' "$work/api_struct_va/src/api_struct_va.c"
check grep -qF 'sv_point = nfcx_struct_define(mrb, "SvPoint", "x", "y", NULL);' "$work/api_struct_va/src/api_struct_va.c"
check grep -qF "spec.add_dependency 'mruby-struct'" "$work/api_struct_va/mrbgem.rake"
# 2zzz170. a VALUE local CRuby uses only as a C integer (jd = 5, t = f(jd), f((int)t)) is an mrb_int local; a VALUE local that
# holds an object (keep = x) stays a VALUE.
rc=0; "$rb" "$conv" --scanner "$scanner" --name api_int_local tools/cext2mrbgem/fixtures/api_int_local/ext/api_int_local "$work/api_int_local" > "$work/api_int_local.log" 2>&1 || rc=$?
check test "$rc" -eq 0
check test ! -e "$work/api_int_local/NOT_BUILDABLE"
check grep -qF 'mrb_int jd = 5;' "$work/api_int_local/src/api_int_local.c"
check grep -qF 'mrb_int t;' "$work/api_int_local/src/api_int_local.c"
check grep -qF 'mrb_value keep = x;' "$work/api_int_local/src/api_int_local.c"
# 2zzz176. CRuby's thread-local storage (rb_thread_local_aset/aref of a symbol key) is a per-state hash (nfcx_tls_*): no Thread refusal.
rc=0; "$rb" "$conv" --scanner "$scanner" --name api_thread_local tools/cext2mrbgem/fixtures/api_thread_local/ext/api_thread_local "$work/api_thread_local" > "$work/api_thread_local.log" 2>&1 || rc=$?
check test "$rc" -eq 0
check test "$(grep -c 'Thread' "$work/api_thread_local/REFUSALS.txt")" -eq 0
check grep -qF 'nfcx_tls_aset(mrb, mrb_nil_value(), id_mode, v);' "$work/api_thread_local/src/api_thread_local.c"
check grep -qF 'return nfcx_tls_aref(mrb, mrb_nil_value(), id_mode);' "$work/api_thread_local/src/api_thread_local.c"
# 2zzz177. RB_ALLOCV_N assigned to a pointer declared earlier (buf = ALLOCV_N(char, v, n)): mrb_malloc of the element type, freed by
# RB_ALLOCV_END of the same VALUE; no temporary-buffer refusal.
rc=0; "$rb" "$conv" --scanner "$scanner" --name api_allocv_assign tools/cext2mrbgem/fixtures/api_allocv_assign/ext/api_allocv_assign "$work/api_allocv_assign" > "$work/api_allocv_assign.log" 2>&1 || rc=$?
check test "$rc" -eq 0
check test "$(grep -c 'temporary buffer' "$work/api_allocv_assign/REFUSALS.txt")" -eq 0
check grep -qF 'buf = (char *)mrb_malloc(mrb, sizeof(char) * (n + 1));' "$work/api_allocv_assign/src/api_allocv_assign.c"
check grep -qF 'mrb_free(mrb, buf);' "$work/api_allocv_assign/src/api_allocv_assign.c"
# 2zzz180. rb_reg_new is a Regexp: the mruby-onig-regexp gem's OnigRegexp (OnigRegexp.new(source, options)); the converted gem
# depends on mruby-onig-regexp; no Regexp refusal.
rc=0; "$rb" "$conv" --scanner "$scanner" --name api_reg_new tools/cext2mrbgem/fixtures/api_reg_new/ext/api_reg_new "$work/api_reg_new" > "$work/api_reg_new.log" 2>&1 || rc=$?
check test "$rc" -eq 0
check test "$(grep -c 'Regexp' "$work/api_reg_new/REFUSALS.txt")" -eq 0
check grep -qF 'OnigRegexp' "$work/api_reg_new/src/api_reg_new.c"
check grep -qF "spec.add_dependency 'mruby-onig-regexp'" "$work/api_reg_new/mrbgem.rake"
# 2zzz181. a VALUE funcall as the condition of ?: is mrb_test (CRuby tests the word; a boolean result is exact under mrb_test).
rc=0; "$rb" "$conv" --scanner "$scanner" --name api_ternary_truth tools/cext2mrbgem/fixtures/api_ternary_truth/ext/api_ternary_truth "$work/api_ternary_truth" > "$work/api_ternary_truth.log" 2>&1 || rc=$?
check test "$rc" -eq 0
check grep -qF 'mrb_test(tt_ge(mrb, self, n)) ? 19 : 20' "$work/api_ternary_truth/src/api_ternary_truth.c"
# 2zzz182. rb_marshal_load(port) is mrb_marshal_load(mrb, str) of the mruby-marshal gem; the converted gem depends on it; no refusal.
rc=0; "$rb" "$conv" --scanner "$scanner" --name api_marshal_load tools/cext2mrbgem/fixtures/api_marshal_load/ext/api_marshal_load "$work/api_marshal_load" > "$work/api_marshal_load.log" 2>&1 || rc=$?
check test "$rc" -eq 0
check test "$(grep -c 'Marshal' "$work/api_marshal_load/REFUSALS.txt")" -eq 0
check grep -qF 'return mrb_marshal_load(mrb, data);' "$work/api_marshal_load/src/api_marshal_load.c"
# 2zzz183. RB_OBJ_FROZEN_RAW is the fork's frozen bit (MRB_FROZEN_P on a heap object; an immediate is not frozen); no refusal.
rc=0; "$rb" "$conv" --scanner "$scanner" --name api_frozen_raw tools/cext2mrbgem/fixtures/api_frozen_raw/ext/api_frozen_raw "$work/api_frozen_raw" > "$work/api_frozen_raw.log" 2>&1 || rc=$?
check test "$rc" -eq 0
check test "$(grep -c 'stuck point' "$work/api_frozen_raw/REFUSALS.txt")" -eq 0
check grep -qF 'MRB_FROZEN_P(mrb_basic_ptr(str))' "$work/api_frozen_raw/src/api_frozen_raw.c"
# 2zzz184. rb_str_encode is the fork's mruby-encoding rb_str_encode (ASCII-compatible encodings): no refusal; mruby-encoding is a dependency.
rc=0; "$rb" "$conv" --scanner "$scanner" --name api_str_encode tools/cext2mrbgem/fixtures/api_str_encode/ext/api_str_encode "$work/api_str_encode" > "$work/api_str_encode.log" 2>&1 || rc=$?
check test "$rc" -eq 0
check test "$(grep -c 'stuck point' "$work/api_str_encode/REFUSALS.txt")" -eq 0
check grep -qF 'rb_str_encode(mrb, str, enc, 0, mrb_nil_value())' "$work/api_str_encode/src/api_str_encode.c"
# 2zzz185. rb_ensure with a pointer carried in the data VALUE ((VALUE)p, a pointer local): mrb_ensure with mrb_cptr_value of the
# pointer; no pointer-as-VALUE refusal.
rc=0; "$rb" "$conv" --scanner "$scanner" --name api_ensure_pdata tools/cext2mrbgem/fixtures/api_ensure_pdata/ext/api_ensure_pdata "$work/api_ensure_pdata" > "$work/api_ensure_pdata.log" 2>&1 || rc=$?
check test "$rc" -eq 0
check test "$(grep -c 'VALUE as pointer' "$work/api_ensure_pdata/REFUSALS.txt")" -eq 0
check grep -qF 'mrb_ensure(mrb, ep_body, mrb_cptr_value(mrb, p), ep_done, mrb_cptr_value(mrb, p));' "$work/api_ensure_pdata/src/api_ensure_pdata.c"
# 2zzz186. rb_protect with a VALUE array as its data ((VALUE)args): the array is mrb_cptr_value of its address, its element casts
# are mrb_cptr of the element; no VALUE-array refusal.
rc=0; "$rb" "$conv" --scanner "$scanner" --name api_protect_array tools/cext2mrbgem/fixtures/api_protect_array/ext/api_protect_array "$work/api_protect_array" > "$work/api_protect_array.log" 2>&1 || rc=$?
check test "$rc" -eq 0
check test "$(grep -c 'VALUE as pointer' "$work/api_protect_array/REFUSALS.txt")" -eq 0
check grep -qF 'mrb_protect(mrb, pa_cb, mrb_cptr_value(mrb, args), &state);' "$work/api_protect_array/src/api_protect_array.c"
check grep -qF 'struct pa_state *st = (struct pa_state *)mrb_cptr(args[0]);' "$work/api_protect_array/src/api_protect_array.c"
# 2zzz187. switch (TYPE(v)) with a case T_REGEXP label: the switch is on the type key, and a Regexp (the mruby-onig-regexp data
# object) is the label's key; the Regexp refusal of the label is gone and the gem is a dependency.
rc=0; "$rb" "$conv" --scanner "$scanner" --name api_switch_regexp tools/cext2mrbgem/fixtures/api_switch_regexp/ext/api_switch_regexp "$work/api_switch_regexp" > "$work/api_switch_regexp.log" 2>&1 || rc=$?
check test "$rc" -eq 0
check test ! -e "$work/api_switch_regexp/NOT_BUILDABLE"
check test "$(grep -c 'T_REGEXP' "$work/api_switch_regexp/REFUSALS.txt")" -eq 0
check grep -qF 'switch (nfcx_type_key_regexp(mrb, (v))) {' "$work/api_switch_regexp/src/api_switch_regexp.c"
check grep -qF 'case NFCX_TT_REGEXP:' "$work/api_switch_regexp/src/api_switch_regexp.c"
check grep -qF 'mruby_onig_regexp_is(v)' "$work/api_switch_regexp/src/api_switch_regexp.c"
check grep -qF "spec.add_dependency 'mruby-onig-regexp'" "$work/api_switch_regexp/mrbgem.rake"
# 2zzz188. the same switch on rb_type(v) (the subject is the type read the macro TYPE is): the key function is the subject too.
rc=0; "$rb" "$conv" --scanner "$scanner" --name api_switch_rb_type tools/cext2mrbgem/fixtures/api_switch_rb_type/ext/api_switch_rb_type "$work/api_switch_rb_type" > "$work/api_switch_rb_type.log" 2>&1 || rc=$?
check test "$rc" -eq 0
check test ! -e "$work/api_switch_rb_type/NOT_BUILDABLE"
check grep -qF 'switch (nfcx_type_key_regexp(mrb, (v))) {' "$work/api_switch_rb_type/src/api_switch_rb_type.c"
check grep -qF 'case NFCX_TT_REGEXP:' "$work/api_switch_rb_type/src/api_switch_rb_type.c"
# 2zzz189. object-like aliases of rb_gc_mark: #define rb_gc_mark_movable rb_gc_mark (a mapped mark call) is dropped and its uses
# convert through the entry; #define mark_second rb_gc_mark (not an API name) becomes the function-like mark macro with mrb in scope.
rc=0; "$rb" "$conv" --scanner "$scanner" --name api_gc_alias tools/cext2mrbgem/fixtures/api_gc_alias/ext/api_gc_alias "$work/api_gc_alias" > "$work/api_gc_alias.log" 2>&1 || rc=$?
check test "$rc" -eq 0
check test ! -e "$work/api_gc_alias/NOT_BUILDABLE"
check test "$(grep -c 'rb_gc_mark' "$work/api_gc_alias/REFUSALS.txt")" -eq 0
check grep -qF '#define mark_second(x) mrb_gc_mark_value(mrb, x)' "$work/api_gc_alias/src/api_gc_alias.c"
check grep -qF 'static void pair_mark(mrb_state *mrb, void *ptr) {' "$work/api_gc_alias/src/api_gc_alias.c"
check test "$(grep -c 'define rb_gc_mark_movable' "$work/api_gc_alias/src/api_gc_alias.c")" -eq 0
# 2zzz190. a fixnum VALUE cast to an integer inside its FIXNUM_P branch: the fixnum's integer (mrb_fixnum), no VALUE-as-integer refusal.
rc=0; "$rb" "$conv" --scanner "$scanner" --name api_fixnum_cast tools/cext2mrbgem/fixtures/api_fixnum_cast/ext/api_fixnum_cast "$work/api_fixnum_cast" > "$work/api_fixnum_cast.log" 2>&1 || rc=$?
check test "$rc" -eq 0
check test "$(grep -c 'VALUE as integer' "$work/api_fixnum_cast/REFUSALS.txt")" -eq 0
check grep -qF 'h[1] = mrb_fixnum(nth);' "$work/api_fixnum_cast/src/api_fixnum_cast.c"
# 2zzz191. a VALUE passed as an sid_t key: its word through nfcx_value_word (the union's bits); an ID parameter stays refused.
rc=0; "$rb" "$conv" --scanner "$scanner" --name api_sid_key tools/cext2mrbgem/fixtures/api_sid_key/ext/api_sid_key "$work/api_sid_key" > "$work/api_sid_key.log" 2>&1 || rc=$?
check test "$rc" -eq 0
check test "$(grep -c 'VALUE as integer' "$work/api_sid_key/REFUSALS.txt")" -eq 0
check grep -qF 'return sk_lookup(nfcx_value_word(obj))' "$work/api_sid_key/src/api_sid_key.c"
check grep -qF 'static unsigned long long nfcx_value_word(mrb_value v) {' "$work/api_sid_key/src/api_sid_key.c"
# 2zzz192. an integer array declared after another declarator (st_index_t v, h[2];) assigned a VALUE-returning call is a refusal
# (the array is found in a multi-declarator declaration), not a silent compile error.
rc=0; "$rb" "$conv" --scanner "$scanner" --name api_multi_decl tools/cext2mrbgem/fixtures/api_multi_decl/ext/api_multi_decl "$work/api_multi_decl" > "$work/api_multi_decl.log" 2>&1 || rc=$?
check test "$rc" -eq 2
check grep -qF 'h is an integer array (st_index_t), and md_get returns a VALUE' "$work/api_multi_decl/REFUSALS.txt"
# 2zzz194. a VALUE call stored in an array the function hashes (rb_memhash(h, ...)): the VALUE is hashed by value
# (nfcx_value_hash: its integer if a fixnum, else its hash method), with no refusal.
rc=0; "$rb" "$conv" --scanner "$scanner" --name api_hash_value tools/cext2mrbgem/fixtures/api_hash_value/ext/api_hash_value "$work/api_hash_value" > "$work/api_hash_value.log" 2>&1 || rc=$?
check test "$rc" -eq 0
check test "$(grep -c 'VALUE as integer' "$work/api_hash_value/REFUSALS.txt")" -eq 0
check grep -qF 'h[1] = nfcx_value_hash(mrb, hv_sf(mrb, obj));' "$work/api_hash_value/src/api_hash_value.c"
# 2zzz195. a VALUE-returning call that is the whole parenthesised if condition gets one truth test (mrb_test), not two: the
# operand pass (a call next to && or ||) does not take it.
rc=0; "$rb" "$conv" --scanner "$scanner" --name api_truth_twice tools/cext2mrbgem/fixtures/api_truth_twice/ext/api_truth_twice "$work/api_truth_twice" > "$work/api_truth_twice.log" 2>&1 || rc=$?
check test "$rc" -eq 0
check grep -qF 'if (mrb_test(tt_zero(x)))' "$work/api_truth_twice/src/api_truth_twice.c"
check test "$(grep -c 'mrb_test(mrb_test' "$work/api_truth_twice/src/api_truth_twice.c")" -eq 0
# 2zzz196. a later declarator of a declaration (const char *s1, *s2;) is a pointer local in its block: its if (s2) is a pointer
# test, not the VALUE of the function's own s2 (no mrb_false_p on it).
rc=0; "$rb" "$conv" --scanner "$scanner" --name api_decl_comma tools/cext2mrbgem/fixtures/api_decl_comma/ext/api_decl_comma "$work/api_decl_comma" > "$work/api_decl_comma.log" 2>&1 || rc=$?
check test "$rc" -eq 0
check test "$(grep -c 'mrb_false_p(s2)' "$work/api_decl_comma/src/api_decl_comma.c")" -eq 0
check grep -qF '        if (s2) {' "$work/api_decl_comma/src/api_decl_comma.c"
# 2zzz198. ENC_CODERANGE_ASCIIONLY (CRuby's cached coderange: a byte scan here) and ENCODING_GET (the encoding index) map, with no refusal.
rc=0; "$rb" "$conv" --scanner "$scanner" --name api_coderange tools/cext2mrbgem/fixtures/api_coderange/ext/api_coderange "$work/api_coderange" > "$work/api_coderange.log" 2>&1 || rc=$?
check test "$rc" -eq 0
check test "$(grep -c 'CODERANGE\|ENCODING_GET' "$work/api_coderange/REFUSALS.txt")" -eq 0
check grep -qF 'nfcx_str_ascii_only(v)' "$work/api_coderange/src/api_coderange.c"
check grep -qF 'rb_enc_get_index(v) == 0' "$work/api_coderange/src/api_coderange.c"
# 2zzz197. an if on a VALUE member of a nested struct (h->options.hook) is a truth test of the VALUE: the member chain is resolved
# through the base's declared struct type, so the function-pointer member of another struct with the same name does not decide it.
rc=0; "$rb" "$conv" --scanner "$scanner" --name api_field_chain tools/cext2mrbgem/fixtures/api_field_chain/ext/api_field_chain "$work/api_field_chain" > "$work/api_field_chain.log" 2>&1 || rc=$?
check test "$rc" -eq 0
check grep -qF '    if (!mrb_false_p(h->options.hook))' "$work/api_field_chain/src/api_field_chain.c"
# 2zzz193. RB_ENC_INTERNED_STR_NULL_CHECK is a CRuby build flag (1 only for Ruby 3.0.0 to 3.0.5): the port's value is its default 0,
# so the check is the dead branch 0 && ..., with no refusal.
rc=0; "$rb" "$conv" --scanner "$scanner" --name api_enc_null_check tools/cext2mrbgem/fixtures/api_enc_null_check/ext/api_enc_null_check "$work/api_enc_null_check" > "$work/api_enc_null_check.log" 2>&1 || rc=$?
check test "$rc" -eq 0
check test "$(grep -c 'NULL_CHECK' "$work/api_enc_null_check/REFUSALS.txt")" -eq 0
check grep -qF 'if (0 && ((long)mrb_int(mrb, len)) == 0) {' "$work/api_enc_null_check/src/api_enc_null_check.c"
check grep -qF "spec.add_dependency 'mruby-marshal'" "$work/api_marshal_load/mrbgem.rake"
# 2zzz179. rb_time_timespec_new: a fixed UTC offset is mrb_time_at_offset (the fork's mruby-time), CRuby's INT_MAX and INT_MAX-1 are
# local time and UTC; no Time-offset refusal.
rc=0; "$rb" "$conv" --scanner "$scanner" --name api_time_offset tools/cext2mrbgem/fixtures/api_time_offset/ext/api_time_offset "$work/api_time_offset" > "$work/api_time_offset.log" 2>&1 || rc=$?
check test "$rc" -eq 0
check test "$(grep -c 'Time offset' "$work/api_time_offset/REFUSALS.txt")" -eq 0
check grep -qF 'nfcx_time_timespec_new(mrb, &ts, ((int)mrb_int(mrb, off_v)));' "$work/api_time_offset/src/api_time_offset.c"
# 2zzz171. a block-scoped long t and a VALUE t in a later block of one function: the (long)t cast of the long is an integer use,
# no VALUE-as-integer refusal (the lookup is the declaration whose block encloses the use).
rc=0; "$rb" "$conv" --scanner "$scanner" --name api_block_shadow tools/cext2mrbgem/fixtures/api_block_shadow/ext/api_block_shadow "$work/api_block_shadow" > "$work/api_block_shadow.log" 2>&1 || rc=$?
check test "$rc" -eq 0
check test ! -e "$work/api_block_shadow/NOT_BUILDABLE"
check test "$(grep -c 'VALUE as integer' "$work/api_block_shadow/REFUSALS.txt")" -eq 0
# 2zzz172. a VALUE declared in a dead #if 0 branch is not a file-scope name: an int parameter named the same is not a VALUE use.
rc=0; "$rb" "$conv" --scanner "$scanner" --name api_dead_decl tools/cext2mrbgem/fixtures/api_dead_decl/ext/api_dead_decl "$work/api_dead_decl" > "$work/api_dead_decl.log" 2>&1 || rc=$?
check test "$rc" -eq 0
check test "$(grep -c 'VALUE as integer' "$work/api_dead_decl/REFUSALS.txt")" -eq 0
# 2zzz173. a pointer carried in a VALUE: (VALUE)h of a struct pointer local is mrb_cptr_value(mrb, h), and a VALUE cast to a
# struct pointer is read with mrb_cptr; no VALUE-as-pointer refusal for either.
rc=0; "$rb" "$conv" --scanner "$scanner" --name api_cptr_value tools/cext2mrbgem/fixtures/api_cptr_value/ext/api_cptr_value "$work/api_cptr_value" > "$work/api_cptr_value.log" 2>&1 || rc=$?
check test "$rc" -eq 0
check test "$(grep -c 'VALUE as pointer' "$work/api_cptr_value/REFUSALS.txt")" -eq 0
check grep -qF 'mrb_value v = mrb_cptr_value(mrb, h);' "$work/api_cptr_value/src/api_cptr_value.c"
# 2zzz174. the address of a struct carried in a VALUE, (VALUE)&s, is a CPTR value (mrb_cptr_value of the address).
rc=0; "$rb" "$conv" --scanner "$scanner" --name api_cptr_addr tools/cext2mrbgem/fixtures/api_cptr_addr/ext/api_cptr_addr "$work/api_cptr_addr" > "$work/api_cptr_addr.log" 2>&1 || rc=$?
check test "$rc" -eq 0
check test "$(grep -c 'VALUE as pointer' "$work/api_cptr_addr/REFUSALS.txt")" -eq 0
check grep -qF 'return mrb_cptr_value(mrb, &s);' "$work/api_cptr_addr/src/api_cptr_addr.c"
# 2zzz175. a pointer typedef cast of a VALUE ((Ctx)x, Ctx a struct pointer typedef) reads the pointer with mrb_cptr.
rc=0; "$rb" "$conv" --scanner "$scanner" --name api_cptr_typedef tools/cext2mrbgem/fixtures/api_cptr_typedef/ext/api_cptr_typedef "$work/api_cptr_typedef" > "$work/api_cptr_typedef.log" 2>&1 || rc=$?
check test "$rc" -eq 0
check test "$(grep -c 'VALUE as pointer' "$work/api_cptr_typedef/REFUSALS.txt")" -eq 0
check grep -qF 'Ctx c = (Ctx)mrb_cptr(x);' "$work/api_cptr_typedef/src/api_cptr_typedef.c"
check grep -qF 'Holder *h = (Holder *)mrb_cptr(x);' "$work/api_cptr_value/src/api_cptr_value.c"
check test "$(grep -c 'stuck point (Struct)' "$work/api_struct_va/REFUSALS.txt")" -eq 0
# 2zzz155. a struct field of CRuby's rb_encoding * type: the Encoding placeholder type is in the prelude (the declaration compiles),
# and the include of ruby/encoding.h is not a blocking refusal (the placeholder covers it).
# 2zzz162. the <string.h> names (memcpy) come with CRuby's ruby.h: the converted source includes <string.h>
rc=0; "$rb" "$conv" --scanner "$scanner" --name api_string_h tools/cext2mrbgem/fixtures/api_string_h/ext/api_string_h "$work/api_string_h" > "$work/api_string_h.log" 2>&1 || rc=$?
check test "$rc" -eq 0
check grep -qF '#include <string.h>' "$work/api_string_h/src/api_string_h.c"

rc=0; "$rb" "$conv" --scanner "$scanner" --name api_rb_encoding_field tools/cext2mrbgem/fixtures/api_rb_encoding_field/ext/api_rb_encoding_field "$work/api_rb_encoding_field" > "$work/api_rb_encoding_field.log" 2>&1 || rc=$?
check grep -qF 'no refusals' "$work/api_rb_encoding_field/REFUSALS.txt"
check test "$(grep -c '#error' "$work/api_rb_encoding_field/src/gem_init.c")" -eq 0
check grep -qF '    rb_encoding *enc;' "$work/api_rb_encoding_field/src/api_rb_encoding_field.c"
# 2zzz156. !v on a VALUE is a stuck point (VALUE truth test); DECIMAL_SIZE_OF_BITS(n) is its arithmetic ((n * 146 / 485) + 1); a
# symbol VALUE passed to rb_id2name is read with mrb_symbol.
rc=0; "$rb" "$conv" --scanner "$scanner" --name api_value_not_decimal tools/cext2mrbgem/fixtures/api_value_not_decimal/ext/api_value_not_decimal "$work/api_value_not_decimal" > "$work/api_value_not_decimal.log" 2>&1 || rc=$?
check grep -qF 'stuck point (VALUE truth test): !v tests a VALUE' "$work/api_value_not_decimal/REFUSALS.txt"
check grep -qF '((64) * 146 / 485) + 1' "$work/api_value_not_decimal/src/api_value_not_decimal.c"
check grep -qF 'mrb_symbol(sym)' "$work/api_value_not_decimal/src/api_value_not_decimal.c"
# 2zzz157. --thread-sync: the work run without the GVL is a direct call on the calling thread (mruby has no GVL to release); the
# header is the synchronous model, and the gem has no mruby-uv dependency (the rake file has no add_dependency line for it).
rc=0; "$rb" "$conv" --scanner "$scanner" --name api_thread_sync --thread-sync tools/cext2mrbgem/fixtures/api_thread_sync/ext/api_thread_sync "$work/api_thread_sync" > "$work/api_thread_sync.log" 2>&1 || rc=$?
check grep -qF 'return fn(data);' "$work/api_thread_sync/include/nfcx_uv_thread.h"
check test "$(grep -c 'uv\.h\|uv_queue_work\|uv_run' "$work/api_thread_sync/include/nfcx_uv_thread.h")" -eq 0
check test "$(grep -c 'mruby-uv' "$work/api_thread_sync/mrbgem.rake")" -eq 0
# 2zzz158. a C++ extension (.cc) is read as C++: its Init function is found (no gem-level "C++" refusal), the variadic method cast
# (VALUE (*)(...)) is a method function, and the converted source keeps the .cc name (the mruby build compiles it as C++).
rc=0; "$rb" "$conv" --scanner "$scanner" --name api_cxx_source tools/cext2mrbgem/fixtures/api_cxx_source/ext/api_cxx_source "$work/api_cxx_source" > "$work/api_cxx_source.log" 2>&1 || rc=$?
check test -e "$work/api_cxx_source/src/api_cxx_source.cc"
check test "$(grep -c 'C++' "$work/api_cxx_source/REFUSALS.txt")" -eq 0
check grep -qF 'cxx_twice' "$work/api_cxx_source/src/api_cxx_source.cc"
# 2zzz159. a call from Init to a stubbed function is dropped in Init (the stub would raise at load, aborting the gem; oj's Init
# called oj_string_writer_init): the call is gone and recorded as dropped in REFUSALS.txt, the stub stays, gem_init.c has no #error.
rc=0; "$rb" "$conv" --scanner "$scanner" --name api_init_stub_call tools/cext2mrbgem/fixtures/api_init_stub_call/ext/api_init_stub_call "$work/api_init_stub_call" > "$work/api_init_stub_call.log" 2>&1 || rc=$?
check test "$(grep -c 'helper(c)' "$work/api_init_stub_call/src/api_init_stub_call.c")" -eq 0
check grep -qF 'BC2CPP-MRBGEM dropped in Init (helper)' "$work/api_init_stub_call/src/api_init_stub_call.c"
# the transitive case: outer is not refused, but its body calls the stub, so Init's call to outer is dropped too (outer's body stays)
check test "$(grep -c 'outer(c)' "$work/api_init_stub_call/src/api_init_stub_call.c")" -eq 0
check grep -qF 'BC2CPP-MRBGEM dropped in Init (outer): calls a function that reaches a stub' "$work/api_init_stub_call/src/api_init_stub_call.c"
check grep -qF 'return helper(mrb, self);' "$work/api_init_stub_call/src/api_init_stub_call.c"
check grep -qF 'helper(mrb_state *mrb, mrb_value self) { /* BC2CPP-MRBGEM stub: refused code */' "$work/api_init_stub_call/src/api_init_stub_call.c"
check grep -qF '[dropped in Init' "$work/api_init_stub_call/REFUSALS.txt"
check test "$(grep -c '#error' "$work/api_init_stub_call/src/gem_init.c")" -eq 0
# 2zzz110. the public headers of a subdirectory (api/) are inputs at their relative path: the sources' #include "api/x.h"
# resolves in the output (include/api/x.h), and the subdirectory's header is not refused.
rc=0; "$rb" "$conv" --scanner "$scanner" --name api_subdir_hdr tools/cext2mrbgem/fixtures/api_subdir_hdr/ext/api_subdir_hdr "$work/api_subdir_hdr" > "$work/api_subdir_hdr.log" 2>&1 || rc=$?
check test "$rc" -eq 0
check test ! -e "$work/api_subdir_hdr/NOT_BUILDABLE"
check test -f "$work/api_subdir_hdr/include/api/subdir_public.h"
check grep -qF '#include "api/subdir_public.h"' "$work/api_subdir_hdr/src/api_subdir_hdr.c"
# 2zzz109. rb_cstr_to_dbl, rb_check_convert_type (with the T_ tag as MRB_TT_), rb_need_block (LocalJumpError without a block),
# rb_gc_enable / rb_gc_disable (the GC class methods), rb_fatal (mrb_bug, which exits), and rb_define_global_function
# (a module function of mrb->kernel_module), and rb_yield in a helper (the block is read from the current frame by nfcx_block_arg).
rc=0; "$rb" "$conv" --scanner "$scanner" --name api_conv_misc tools/cext2mrbgem/fixtures/api_conv_misc/ext/api_conv_misc "$work/api_conv_misc" > "$work/api_conv_misc.log" 2>&1 || rc=$?
check test "$rc" -eq 0
check test ! -e "$work/api_conv_misc/NOT_BUILDABLE"
check grep -qF 'mrb_float_value(mrb, mrb_cstr_to_dbl(mrb, RSTRING_PTR(str), 1))' "$work/api_conv_misc/src/api_conv_misc.c"
check grep -qF 'mrb_check_convert_type(mrb, val, MRB_TT_STRING, "String", "to_str")' "$work/api_conv_misc/src/api_conv_misc.c"
check grep -qF 'mrb_raise(mrb, E_LOCALJUMP_ERROR, "no block given")' "$work/api_conv_misc/src/api_conv_misc.c"
check grep -qF 'mrb_funcall_argv(mrb, mrb_obj_value(mrb_module_get(mrb, "GC")), mrb_intern_cstr(mrb, "disable"), 0, NULL)' "$work/api_conv_misc/src/api_conv_misc.c"
check grep -qF 'mrb_intern_cstr(mrb, "enable")' "$work/api_conv_misc/src/api_conv_misc.c"
check grep -qF 'mrb_bug(mrb, "boom %d", 1)' "$work/api_conv_misc/src/api_conv_misc.c"
check grep -qF 'mrb_define_module_function(mrb, mrb->kernel_module, "conv_global", m_global, MRB_ARGS_NONE())' "$work/api_conv_misc/src/api_conv_misc.c"
check grep -qF 'return mrb_yield(mrb, nfcx_block_arg(mrb), v);' "$work/api_conv_misc/src/api_conv_misc.c"
check grep -qF 'mrb_get_args(mrb, "&", &nfcx_b);' "$work/api_conv_misc/src/api_conv_misc.c"

# 2zzz110. a function-defining macro invoked at file scope (ffi's NUM_OP(name, ...)): each invocation is expanded, so the
# functions it defines convert and are registered (before, "registered function has no definition"); the #define is then
# unused and wrapped in #if 0
rc=0; "$rb" "$conv" --scanner "$scanner" --name fn_macro tools/cext2mrbgem/fixtures/fn_macro/ext/fn_macro "$work/fn_macro" > "$work/fn_macro.log" 2>&1 || rc=$?
check test "$rc" -eq 0
check test ! -e "$work/fn_macro/NOT_BUILDABLE"
check grep -qF 'static mrb_value fn_get_long(mrb_state *mrb, mrb_value self) {' "$work/fn_macro/src/fn_macro.c"
check grep -qF 'mrb_define_method(mrb, mFn, "get2_long", fn_get2_long, MRB_ARGS_NONE());' "$work/fn_macro/src/fn_macro.c"
check grep -qF '#if 0  /* BC2CPP-MRBGEM: unused macro' "$work/fn_macro/src/fn_macro.c"
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
