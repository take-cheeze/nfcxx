/* SHAVE throughput probe: the same per-word chains as chain_serial.c, but four words are advanced together
 * so the four chains are independent. NR_ITER and NR_ELEMENTS are injected. */
typedef unsigned int u32;
typedef unsigned char u8;
static u32 pword(const u8 *p) { return (u32)p[0] | ((u32)p[1] << 8) | ((u32)p[2] << 16) | ((u32)p[3] << 24); }
void nr_probe_kernel(const u8 *params) {
    const u32 *in = (const u32 *)pword(params);
    u32 *out = (u32 *)pword(params + 80);
    const int words = NR_ELEMENTS / 2;
    int g, k;
    for (g = 0; g < words / 4; ++g) {
        u32 a = in[4 * g], b = in[4 * g + 1], c = in[4 * g + 2], d = in[4 * g + 3];
        for (k = 0; k < NR_ITER; ++k) {
            a = a * 3u + 7u;
            b = b * 3u + 7u;
            c = c * 3u + 7u;
            d = d * 3u + 7u;
        }
        out[4 * g] = a; out[4 * g + 1] = b; out[4 * g + 2] = c; out[4 * g + 3] = d;
    }
}
