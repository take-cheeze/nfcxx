/* SHAVE float latency probe: each word (as float32) runs one dependent chain x = x*0.75f + 0.5f, NR_ITER steps. */
typedef unsigned int u32;
typedef unsigned char u8;
static u32 pword(const u8 *p) { return (u32)p[0] | ((u32)p[1] << 8) | ((u32)p[2] << 16) | ((u32)p[3] << 24); }
void nr_probe_kernel(const u8 *params) {
    const float *in = (const float *)pword(params);
    float *out = (float *)pword(params + 80);
    const int words = NR_ELEMENTS / 2;
    int i, k;
    for (i = 0; i < words; ++i) {
        float x = in[i];
        for (k = 0; k < NR_ITER; ++k) x = x * 0.75f + 0.5f;
        out[i] = x;
    }
}
