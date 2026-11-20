/* Benchmark kernel B: the same arithmetic as bench_lanes.c, written as one 4-lane vector operation.
 * NR_ELEMENTS is injected by the runner. */
typedef unsigned int u32;
typedef unsigned char u8;
typedef u32 uint4v __attribute__((ext_vector_type(4)));
static u32 pword(const u8 *p) { return (u32)p[0] | ((u32)p[1] << 8) | ((u32)p[2] << 16) | ((u32)p[3] << 24); }
void nr_probe_kernel(const u8 *params) {
    const u32 *in = (const u32 *)pword(params);
    u32 *out = (u32 *)pword(params + 80);
    const int words = NR_ELEMENTS / 2;
    int g, rep;
    for (rep = 0; rep < NR_REPEAT; ++rep)
    for (g = 0; g < words / 4; ++g) {
        uint4v a = {in[4 * g], in[4 * g + 1], in[4 * g + 2], in[4 * g + 3]};
        uint4v r = a * 3u + 7u;
        out[4 * g] = r[0];
        out[4 * g + 1] = r[1];
        out[4 * g + 2] = r[2];
        out[4 * g + 3] = r[3];
    }
}
