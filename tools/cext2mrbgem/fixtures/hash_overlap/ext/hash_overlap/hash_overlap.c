#include <ruby.h>

/* the gem's static fallback of rb_hash_bulk_insert (json's TruffleRuby fallback) is active when HAVE_RB_HASH_BULK_INSERT is not
 * defined, and the gem's helper of that name needs the mruby state (rb_hash_aset). Its call is the API mapping's whole call and the
 * state argument of the helper, which cannot both be applied: the call is refused (REFUSALS.txt), not a crash. */
#ifndef HAVE_RB_HASH_BULK_INSERT
static void
rb_hash_bulk_insert(long count, const VALUE *pairs, VALUE hash)
{
    long index = 0;
    while (index < count) {
        VALUE name = pairs[index++];
        VALUE value = pairs[index++];
        rb_hash_aset(hash, name, value);
    }
}
#endif

static VALUE hash_overlap_fill(VALUE self, VALUE hash) {
    VALUE pairs[2];
    pairs[0] = self;
    pairs[1] = self;
    rb_hash_bulk_insert(2, pairs, hash);
    return hash;
}

void Init_hash_overlap(void) {
    VALUE mHo = rb_define_module("HashOverlap");
    rb_define_module_function(mHo, "fill", hash_overlap_fill, 1);
}
