/* marshal_test: mrbbc_marshal_dump on values built with the runtime's API, printed as hex (one case per line). The cases are
 * the same values as tests/mrbbc/runtime/marshal_cases.rb, which CRuby's Marshal.dump checks. Build with
 * -DMRBBC_GC_CONSERVATIVE=1 (the locals of a case are roots the C stack scan finds). Each dump is loaded back and dumped
 * again: the two must match. */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "mrbrt.h"

static void hex_print(const char *label, const MV *s) {
  const char *p;
  long n, k;
  if (!mrbbc_str_view(s, &p, &n)) { printf("%s: not a string\n", label); return; }
  printf("%s ", label);
  for (k = 0; k < n; k++) printf("%02x", (unsigned char)p[k]);
  printf("\n");
}

static void make_str(MV *dst, const char *s) { mrbbc_str_new(dst, s, (long)strlen(s)); }

static void build(int which, MV *v) {
  MV a, b, k, x;
  switch (which) {
    case 0: mrbbc_set_nil(v); break;
    case 1: mrbbc_set_bool(v, 1); break;
    case 2: mrbbc_set_bool(v, 0); break;
    case 3: mrbbc_int_new(v, 0); break;
    case 4: mrbbc_int_new(v, 1); break;
    case 5: mrbbc_int_new(v, 122); break;
    case 6: mrbbc_int_new(v, 123); break;
    case 7: mrbbc_int_new(v, -1); break;
    case 8: mrbbc_int_new(v, -123); break;
    case 9: mrbbc_int_new(v, -124); break;
    case 10: mrbbc_int_new(v, 300); break;
    case 11: mrbbc_int_new(v, -300); break;
    case 12: mrbbc_int_new(v, (1LL << 30) - 1); break;
    case 13: mrbbc_int_new(v, 1LL << 30); break;
    case 14: mrbbc_int_new(v, -(1LL << 30)); break;
    case 15: mrbbc_int_new(v, 1LL << 40); break;
    case 16: mrbbc_int_new(v, -(1LL << 40)); break;
    case 17: mrbbc_int_new(v, 1LL << 62); break;
    case 18: make_str(v, ""); break;
    case 19: make_str(v, "hi"); break;
    case 20: make_str(v, "h\xc3\xa9llo"); break;
    case 21: mrbbc_sym(v, "a"); break;
    case 22: mrbbc_sym(v, "abc"); break;
    case 23: mrbbc_ary_new(v, 2); make_str(&a, "a"); mrbbc_int_new(&x, 1); mrbbc_ary_push(v, &x); mrbbc_ary_push(v, &a); break;
    case 24: mrbbc_ary_new(v, 2); mrbbc_sym(&a, "a"); mrbbc_ary_push(v, &a); mrbbc_ary_push(v, &a); break;
    case 25: mrbbc_ary_new(v, 2); make_str(&a, "x"); mrbbc_ary_push(v, &a); mrbbc_ary_push(v, &a); break;
    case 26: mrbbc_hash_new(v, 1); make_str(&k, "k"); mrbbc_int_new(&x, 2); mrbbc_hash_set(v, &k, &x); break;
    case 27: /* {"topic_id"=>42, "tags"=>["ruby", "mruby"], "score"=>2.5-less: 1, "closed"=>false, "note"=>nil} */
      mrbbc_hash_new(v, 4);
      make_str(&k, "topic_id"); mrbbc_int_new(&x, 42); mrbbc_hash_set(v, &k, &x);
      make_str(&k, "tags"); mrbbc_ary_new(&a, 2); make_str(&b, "ruby"); mrbbc_ary_push(&a, &b); make_str(&b, "mruby"); mrbbc_ary_push(&a, &b);
      mrbbc_hash_set(v, &k, &a);
      make_str(&k, "closed"); mrbbc_set_bool(&x, 0); mrbbc_hash_set(v, &k, &x);
      make_str(&k, "note"); mrbbc_set_nil(&x); mrbbc_hash_set(v, &k, &x);
      break;
    default: mrbbc_set_nil(v); break;
  }
}

/* the lowered program supplies these; the test calls no program method */
void mrbbc_user_call(int id, MV *ret, MV *argv, MV *blk, long argc) { (void)id; (void)ret; (void)argv; (void)blk; (void)argc; abort(); }
void mrbbc_user_yield(MV *ret, const MV *blk, MV *argv, long argc) { (void)ret; (void)blk; (void)argv; (void)argc; abort(); }

#define CASES 28

static void entry(MV *ret) {
  int i;
  for (i = 0; i < CASES; i++) {
    MV v, d, back, d2;
    char label[32];
    build(i, &v);
    mrbbc_marshal_dump(&d, &v);
    snprintf(label, sizeof label, "%d", i);
    hex_print(label, &d);
    /* load the dump back and dump it again: the same bytes */
    mrbbc_marshal_load(&back, &d);
    mrbbc_marshal_dump(&d2, &back);
    {
      const char *p1, *p2;
      long n1, n2;
      mrbbc_str_view(&d, &p1, &n1);
      mrbbc_str_view(&d2, &p2, &n2);
      if (n1 != n2 || memcmp(p1, p2, (size_t)n1) != 0) printf("%d: round trip differs\n", i);
    }
  }
  mrbbc_set_nil(ret);
}

int main(int argc, char **argv) {
  MV ret = {0};
  (void)argc;
  mrbbc_progname = argv[0];
  mrbbc_run(entry, &ret);
  return 0;
}
