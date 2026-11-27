/* nfcx_st_test.c: a C99 test of the st_table shim (nfcx_st.c). Built and run by tests/cext2mrbgem/run.sh with gcc. */
#include <stdio.h>
#include <string.h>
#include "nfcx_st.h"

static int failures = 0;
#define CHECK(c) do { if (!(c)) { printf("FAIL line %d: %s\n", __LINE__, #c); failures++; } } while (0)

static int seen_count, seen_sum;
static st_data_t last_key;

static int
count_cb(st_data_t key, st_data_t value, st_data_t arg)
{
    (void)arg;
    seen_count++;
    seen_sum += (int)value;
    last_key = key;
    return ST_CONTINUE;
}

static int
delete_odd_cb(st_data_t key, st_data_t value, st_data_t arg)
{
    (void)key; (void)arg;
    return (value % 2) ? ST_DELETE : ST_CONTINUE;
}

static int
stop_at_cb(st_data_t key, st_data_t value, st_data_t arg)
{
    (void)key; (void)value;
    seen_count++;
    return (seen_count == (int)arg) ? ST_STOP : ST_CONTINUE;
}

static int
order_cb(st_data_t key, st_data_t value, st_data_t arg)
{
    (void)value; (void)arg;
    if (seen_count < 4) ((int *)arg)[seen_count] = (int)key;
    seen_count++;
    return ST_CONTINUE;
}

static void
test_numtable(void)
{
    st_table *t = st_init_numtable();
    st_data_t v = 0;
    int i, found;
    int order[4];
    CHECK(t != NULL);
    CHECK(t->num_entries == 0);
    CHECK(st_insert(t, 10, 100) == 0);
    CHECK(st_insert(t, 20, 200) == 0);
    CHECK(st_insert(t, 10, 111) == 1);          /* existing key: value replaced */
    CHECK(t->num_entries == 2);
    CHECK(st_lookup(t, 10, &v) == 1 && v == 111);
    CHECK(st_lookup(t, 30, &v) == 0);
    CHECK(st_lookup(t, 20, NULL) == 1);
    /* pointers compare by value */
    st_add_direct(t, (st_data_t)&order[0], 7);
    CHECK(st_lookup(t, (st_data_t)&order[0], &v) == 1 && v == 7);
    CHECK(st_lookup(t, (st_data_t)&order[1], NULL) == 0);
    CHECK(st_delete(t, &(st_data_t){(st_data_t)&order[0]}, NULL) == 1);
    /* growth: many entries, all found, insertion order kept */
    for (i = 1000; i < 1000 + 500; i++) st_add_direct(t, (st_data_t)i, (st_data_t)(i * 2));
    CHECK(t->num_entries == 502);
    found = 1;
    for (i = 1000; i < 1500; i++) if (!st_lookup(t, (st_data_t)i, &v) || v != (st_data_t)(i * 2)) found = 0;
    CHECK(found);
    /* delete by key: the key and the value come back */
    {
        st_data_t k = 1234, val = 0;
        CHECK(st_delete(t, &k, &val) == 1);
        CHECK(k == 1234 && val == 2468);
        CHECK(st_lookup(t, 1234, NULL) == 0);
        k = 1234;
        CHECK(st_delete(t, &k, &val) == 0 && val == 0);
    }
    CHECK(t->num_entries == 501);
    /* iterate: count and sum of the values */
    seen_count = 0; seen_sum = 0;
    CHECK(st_foreach(t, count_cb, 0) == 0);
    CHECK(seen_count == 501);
    CHECK(seen_sum == 111 + 200 + 2 * (500 * (1000 + 1499) / 2) - 2468);
    /* insertion order: the first two are the keys 10 and 20 */
    seen_count = 0;
    st_foreach(t, order_cb, (st_data_t)order);
    CHECK(order[0] == 10 && order[1] == 20);
    st_free_table(t);
}

static void
test_foreach_delete_stop(void)
{
    st_table *t = st_init_numtable_with_size(4);
    int i;
    for (i = 0; i < 10; i++) st_add_direct(t, (st_data_t)i, (st_data_t)i);
    CHECK(st_foreach(t, delete_odd_cb, 0) == 0);     /* ST_DELETE removes the odd values */
    CHECK(t->num_entries == 5);
    CHECK(st_lookup(t, 3, NULL) == 0 && st_lookup(t, 4, NULL) == 1 && st_lookup(t, 8, NULL) == 1);
    seen_count = 0;
    st_foreach(t, stop_at_cb, 2);                    /* ST_STOP after the second entry */
    CHECK(seen_count == 2);
    st_free_table(t);
}

static void
test_strtable(void)
{
    st_table *t = st_init_strtable();
    char a[] = "alpha", b[] = "alpha", c[] = "beta";
    st_data_t v = 0;
    CHECK(st_insert(t, (st_data_t)a, 1) == 0);
    CHECK(st_insert(t, (st_data_t)b, 2) == 1);  /* same content, another pointer: the same key */
    CHECK(t->num_entries == 1);
    CHECK(st_lookup(t, (st_data_t)c, &v) == 0);
    CHECK(st_insert(t, (st_data_t)c, 3) == 0);
    CHECK(st_lookup(t, (st_data_t)b, &v) == 1 && v == 2);
    CHECK(st_lookup(t, (st_data_t)"ALPHA", &v) == 0);  /* case-sensitive */
    st_free_table(t);
}

static void
test_strcasetable(void)
{
    st_table *t = st_init_strcasetable_with_size(16);
    char a[] = "Content-Type", b[] = "content-type", c[] = "CONTENT-LENGTH";
    st_data_t v = 0;
    CHECK(st_insert(t, (st_data_t)a, 1) == 0);
    CHECK(st_insert(t, (st_data_t)b, 2) == 1);
    CHECK(t->num_entries == 1);
    CHECK(st_lookup(t, (st_data_t)"CONTENT-TYPE", &v) == 1 && v == 2);
    CHECK(st_lookup(t, (st_data_t)c, &v) == 0);
    CHECK(st_strcasecmp("Form", "fORM") == 0);
    CHECK(st_strcasecmp("abc", "abd") < 0);
    CHECK(st_strcasecmp("b", "A") > 0);
    CHECK(st_strcasecmp("ab", "abc") < 0);
    CHECK(st_strncasecmp("SVG-x", "svg", 3) == 0);
    CHECK(st_strncasecmp("svgx", "svgy", 3) == 0);
    CHECK(st_strncasecmp("sv", "svg", 3) < 0);
    CHECK(st_strncasecmp("abc", "xyz", 0) == 0);
    st_free_table(t);
}

static int cmp_mod(st_data_t a, st_data_t b) { return (int)(a % 10) != (int)(b % 10); }
static st_index_t hash_mod(st_data_t a) { return (st_index_t)(a % 10); }

static void
test_generic_type(void)
{
    /* a table with a caller-defined hash type: keys compared by their last digit */
    static const struct st_hash_type ty = { cmp_mod, hash_mod };
    st_data_t v = 0;
    st_table *t = st_init_table(&ty);
    CHECK(st_insert(t, 13, 1) == 0);
    CHECK(st_insert(t, 23, 2) == 1);           /* 23 and 13 are equal under this type */
    CHECK(st_lookup(t, 3, &v) == 1 && v == 2);
    st_free_table(t);
}

int
main(void)
{
    test_numtable();
    test_foreach_delete_stop();
    test_strtable();
    test_strcasetable();
    test_generic_type();
    if (failures) {
        printf("nfcx_st test: %d failure(s)\n", failures);
        return 1;
    }
    printf("nfcx_st test: OK\n");
    return 0;
}
