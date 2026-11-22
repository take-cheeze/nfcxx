/* SHAVE float throughput probe: the same per-word float chains as chain_fserial.c, four words advanced together. */
typedef unsigned int u32;
typedef unsigned char u8;
static u32 pword(const u8 *p) { return (u32)p[0] | ((u32)p[1] << 8) | ((u32)p[2] << 16) | ((u32)p[3] << 24); }
void nr_probe_kernel(const u8 *params) {
    const float *in = (const float *)pword(params);
    float *out = (float *)pword(params + 80);
    const int words = NR_ELEMENTS / 2;
    int g, k;
    for (g = 0; g < words / 4; ++g) {
        float a = in[4 * g], b = in[4 * g + 1], c = in[4 * g + 2], d = in[4 * g + 3];
        for (k = 0; k < NR_ITER; ++k) {
            a = a * 0.75f + 0.5f;
            b = b * 0.75f + 0.5f;
            c = c * 0.75f + 0.5f;
            d = d * 0.75f + 0.5f;
        }
        out[4 * g] = a; out[4 * g + 1] = b; out[4 * g + 2] = c; out[4 * g + 3] = d;
    }
}
