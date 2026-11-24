/* SHAVE latency probe: each word runs one dependent chain x = x*3 + 7, NR_ITER steps. NR_ITER and NR_ELEMENTS are injected. */
typedef unsigned int u32;
typedef unsigned char u8;
static u32 pword(const u8 *p) { return (u32)p[0] | ((u32)p[1] << 8) | ((u32)p[2] << 16) | ((u32)p[3] << 24); }
void nr_probe_kernel(const u8 *params) {
    const u32 *in = (const u32 *)pword(params);
    u32 *out = (u32 *)pword(params + 80);
    const int words = NR_ELEMENTS / 2;
    int i, k;
    for (i = 0; i < words; ++i) {
        u32 x = in[i];
        for (k = 0; k < NR_ITER; ++k) x = x * 3u + 7u;
        out[i] = x;
    }
}
