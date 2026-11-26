/* The collector's test (tests/mrbbc/runtime/run.sh): objects that die in a loop are swept and the count drops after a
 * collection; with the threshold at 1 the count stays small; and the live objects survive (an array's elements, a hash's
 * values, an instance's instance variables). It runs under mrbbc_run, as the program does. */
#include <stdio.h>
#include <stdlib.h>

#include "mrbrt.h"

static int failures = 0;

static void check(int ok, const char *what, long got) {
  if (!ok) {
    fprintf(stderr, "gc_test: FAILED: %s (got %ld)\n", what, got);
    failures++;
  }
}

/* dst = a new string "item<i>" */
static void item_str(MV *dst, long i) {
  char buf[32];
  int n = snprintf(buf, sizeof buf, "item%ld", i);
  mrbbc_str_new(dst, buf, n);
}

/* The lowered module defines the program's methods. This test has none, so a call of one is an error. */
void mrbbc_user_call(int id, MV *ret, MV *argv, MV *blk, long argc) {
  (void)id;
  (void)ret;
  (void)argv;
  (void)blk;
  (void)argc;
  mrbbc_raise("NotImplementedError", "gc_test has no program methods");
}

/* The test's values are the registers of a frame of its own, registered with the collector as a lowered function's are
 * (precise roots, mrbrt.h; the conservative scan finds them too). */
#define s fr[0]
#define a fr[1]
#define t fr[2]
#define h fr[3]
#define k fr[4]
#define v fr[5]
#define got fr[6]
#define eq fr[7]
#define cls fr[8]
#define o fr[9]

static void body(MV *ret) {
  MV fr[10];
  MrbbcGCFrame gf;
  long i, before, after, peak = 0;

  (void)ret;
  mrbbc_gc_enter(&gf, fr, 10);
  /* 1. The garbage of a loop is counted until a collection, and the collection sweeps it. The last string and array stay
   * reachable from the locals. */
  mrbbc_gc_set_threshold(1L << 30);
  for (i = 0; i < 1000; i++) {
    item_str(&s, i);
    mrbbc_ary_new(&a, 2);
    mrbbc_ary_push(&a, &s);
  }
  before = mrbbc_gc_count();
  mrbbc_gc_collect();
  after = mrbbc_gc_count();
  check(before >= 2000, "the loop's objects are counted before a collection", before);
  check(after <= 10, "a collection sweeps the loop's garbage", after);

  /* 2. With the threshold forced to 1, every allocation collects first, so the count stays small through the loop. */
  mrbbc_gc_set_threshold(1);
  for (i = 0; i < 1000; i++) {
    item_str(&s, i);
    mrbbc_ary_new(&a, 2);
    mrbbc_ary_push(&a, &s);
    if (mrbbc_gc_count() > peak) peak = mrbbc_gc_count();
  }
  check(peak <= 10, "with the threshold at 1 the count stays small", peak);

  /* 3. Live objects survive collections that run while they are reachable only from other live objects: an array of 200
   * strings, a hash with a symbol key, and an instance with an instance variable. */
  mrbbc_ary_new(&a, 0);
  for (i = 0; i < 200; i++) {
    item_str(&t, i);
    mrbbc_ary_push(&a, &t);
  }
  mrbbc_hash_new(&h, 0);
  mrbbc_sym(&k, "name");
  item_str(&v, 999);
  mrbbc_hash_set(&h, &k, &v);
  mrbbc_object_class(&cls);
  mrbbc_alloc(&o, &cls);
  item_str(&v, 7);
  mrbbc_setiv(&o, "@v", &v);
  for (i = 0; i < 300; i++) item_str(&t, i); /* garbage, so collections run while the containers are live */
  mrbbc_gc_collect();

  check(mrbbc_ary_len(&a) == 200, "the array kept its 200 elements", mrbbc_ary_len(&a));
  for (i = 0; i < 200; i++) {
    mrbbc_ary_elt(&got, &a, i);
    item_str(&t, i);
    mrbbc_binop(MRBBC_OP_EQ, &eq, &got, &t);
    check(mrbbc_tag(&eq) == MRBBC_TRUE, "an element of the array survived", i);
  }
  mrbbc_karg(&got, &h, "name");
  item_str(&t, 999);
  mrbbc_binop(MRBBC_OP_EQ, &eq, &got, &t);
  check(mrbbc_tag(&eq) == MRBBC_TRUE, "the hash value survived", 0);
  check(mrbbc_kw_flag(&h) == 2, "the hash lost its key", 0);
  mrbbc_getiv(&got, &o, "@v");
  item_str(&t, 7);
  mrbbc_binop(MRBBC_OP_EQ, &eq, &got, &t);
  check(mrbbc_tag(&eq) == MRBBC_TRUE, "the instance variable survived", 0);

  mrbbc_gc_set_threshold(0);
  mrbbc_gc_leave(&gf);
}

int main(void) {
  MV ret = {0}; /* nil in every layout */
  mrbbc_progname = "gc_test";
  mrbbc_run(body, &ret);
  if (failures != 0) return 1;
  puts("gc_test: ok");
  return 0;
}
