/* Benchmark kernel A: out = in*3 + 7 on each 32-bit word, written with per-lane loops over small arrays
 * (the style of the NR_V4_OP helpers in npu-render's frame_core.h). NR_ELEMENTS is injected by the runner. */
typedef unsigned int u32;
typedef unsigned char u8;
static u32 pword(const u8 *p) { return (u32)p[0] | ((u32)p[1] << 8) | ((u32)p[2] << 16) | ((u32)p[3] << 24); }
typedef struct { u32 v[4]; } lanes4;
static lanes4 madd4(lanes4 a, u32 m, u32 b) {
    lanes4 r;
    int i;
    for (i = 0; i < 4; ++i) r.v[i] = a.v[i] * m + b;
    return r;
}
void nr_probe_kernel(const u8 *params) {
    const u32 *in = (const u32 *)pword(params);
    u32 *out = (u32 *)pword(params + 80);
    const int words = NR_ELEMENTS / 2;   /* FP16: two elements per 32-bit word */
    int g, rep;
    for (rep = 0; rep < NR_REPEAT; ++rep)
    for (g = 0; g < words / 4; ++g) {
        lanes4 a, r;
        int i;
        for (i = 0; i < 4; ++i) a.v[i] = in[4 * g + i];
        r = madd4(a, 3u, 7u);
        for (i = 0; i < 4; ++i) out[4 * g + i] = r.v[i];
    }
}
