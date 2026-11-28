/* the fork's mruby-marshal (3rd/mruby/mrbgems/mruby-marshal/src/marshal.cpp), compiled against the compatibility layer and linked
 * with the mrbbc runtime: mrb_marshal_dump and mrb_marshal_load on the 28 values of marshal_test.c. The dumps must be CRuby's
 * Marshal.dump bytes (marshal_cases.rb), and each dump must load and dump back to the same bytes. */
#include <stdio.h>
#include <string.h>
#include "../mruby.h"

/* the fork's entry points (3rd/mruby/mrbgems/mruby-marshal/include/mruby/marshal.h) */
extern "C" mrb_value mrb_marshal_dump(mrb_state *M, mrb_value obj, mrb_value io);
extern "C" mrb_value mrb_marshal_load(mrb_state *M, mrb_value obj);
extern "C" void mrb_mruby_marshal_gem_init(mrb_state *M);

extern "C" {
/* a lowered program supplies these; this test calls no program method */
void mrbbc_user_call(int, MV *, MV *, MV *, long) { abort(); }
void mrbbc_user_yield(MV *, const MV *, MV *, long) { abort(); }
}

static mrb_state M;

static void make_str(mrb_value *dst, const char *s) { *dst = mrb_str_new(&M, s, (mrb_int)strlen(s)); }

static mrb_value build(int which) {
  mrb_value a, b, k, x;
  switch (which) {
    case 0: return mrb_nil_value();
    case 1: return mrb_true_value();
    case 2: return mrb_false_value();
    case 3: return mrb_fixnum_value(0);
    case 4: return mrb_fixnum_value(1);
    case 5: return mrb_fixnum_value(122);
    case 6: return mrb_fixnum_value(123);
    case 7: return mrb_fixnum_value(-1);
    case 8: return mrb_fixnum_value(-123);
    case 9: return mrb_fixnum_value(-124);
    case 10: return mrb_fixnum_value(300);
    case 11: return mrb_fixnum_value(-300);
    case 12: return mrb_fixnum_value((1LL << 30) - 1);
    case 13: return mrb_fixnum_value(1LL << 30);
    case 14: return mrb_fixnum_value(-(1LL << 30));
    case 15: return mrb_fixnum_value(1LL << 40);
    case 16: return mrb_fixnum_value(-(1LL << 40));
    case 17: return mrb_fixnum_value(1LL << 62);
    case 18: make_str(&a, ""); return a;
    case 19: make_str(&a, "hi"); return a;
    case 20: make_str(&a, "h\xc3\xa9llo"); return a;
    case 21: return mrb_symbol_value(mrb_intern_cstr(&M, "a"));
    case 22: return mrb_symbol_value(mrb_intern_cstr(&M, "abc"));
    case 23: a = mrb_ary_new(&M); make_str(&b, "a"); x = mrb_fixnum_value(1); mrb_ary_push(&M, a, x); mrb_ary_push(&M, a, b); return a;
    case 24: a = mrb_ary_new(&M); b = mrb_symbol_value(mrb_intern_cstr(&M, "a")); mrb_ary_push(&M, a, b); mrb_ary_push(&M, a, b); return a;
    case 25: a = mrb_ary_new(&M); make_str(&b, "x"); mrb_ary_push(&M, a, b); mrb_ary_push(&M, a, b); return a;
    case 26: a = mrb_hash_new_capa(&M, 1); make_str(&k, "k"); x = mrb_fixnum_value(2); mrb_hash_set(&M, a, k, x); return a;
    case 27: {
      a = mrb_hash_new_capa(&M, 4);
      make_str(&k, "topic_id"); x = mrb_fixnum_value(42); mrb_hash_set(&M, a, k, x);
      make_str(&k, "tags"); b = mrb_ary_new(&M);
      { mrb_value s1; make_str(&s1, "ruby"); mrb_ary_push(&M, b, s1); make_str(&s1, "mruby"); mrb_ary_push(&M, b, s1); }
      mrb_hash_set(&M, a, k, b);
      make_str(&k, "closed"); x = mrb_false_value(); mrb_hash_set(&M, a, k, x);
      make_str(&k, "note"); x = mrb_nil_value(); mrb_hash_set(&M, a, k, x);
      return a;
    }
  }
  return mrb_nil_value();
}

static void hex(const mrb_value s) {
  const char *p = RSTRING_PTR(s);
  mrb_int n = RSTRING_LEN(s), k;
  for (k = 0; k < n; k++) printf("%02x", (unsigned char)p[k]);
}

static void entry(MV *ret) {
  int i;
  for (i = 0; i < 28; i++) {
    mrb_value v = build(i);
    mrb_value dumped = mrb_marshal_dump(&M, v, mrb_nil_value());
    mrb_value back = mrb_marshal_load(&M, dumped);
    mrb_value again = mrb_marshal_dump(&M, back, mrb_nil_value());
    printf("%d ", i);
    hex(dumped);
    printf("\n");
    if (RSTRING_LEN(dumped) != RSTRING_LEN(again) || memcmp(RSTRING_PTR(dumped), RSTRING_PTR(again), (size_t)RSTRING_LEN(dumped)) != 0)
      printf("%d: round trip differs\n", i);
  }
  *ret = mrb_nil_value();
}

int main(int argc, char **argv) {
  MV ret = {0};
  (void)argc;
  mrbbc_progname = argv[0];
  nfcx_state_init(&M);
  mrb_mruby_marshal_gem_init(&M);  /* defines Marshal::MAJOR_VERSION and MINOR_VERSION, which the writer reads */
  mrbbc_run(entry, &ret);
  return 0;
}
