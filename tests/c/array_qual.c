/* EXPECT: 42 */
/* A qualifier on an array typedef belongs to the elements (C11 6.7.3p9): `const S *` is a pointer to an array
   of const bytes, the type a `const unsigned char (*)[12]` parameter takes. EDG's generated C has this shape
   (ifc_map_functions_val: get_storage() against copy_from_node_field), and cproc rejected it. */
typedef unsigned char S[12];
struct holder { S storage; };

static const S *get(const struct holder *h) { return &h->storage; }

static int sum(const unsigned char (*p)[12]) {
    int t = 0;
    for (int i = 0; i < 12; i++)
        t += (*p)[i];
    return t;
}

int main(void) {
    struct holder h;
    for (int i = 0; i < 12; i++)
        h.storage[i] = (unsigned char)i;             /* 0 + 1 + ... + 11 = 66 */
    const S *p = get(&h);                            /* const S * from const struct holder * */
    const S *q;
    q = &h.storage;                                  /* adds const to the pointee */
    const unsigned char (*r)[12] = &h.storage;
    if (sum(p) != 66 || sum(q) != 66 || sum(r) != 66)
        return 1;
    return sum(p) - 24;                              /* 66 - 24 = 42 */
}
