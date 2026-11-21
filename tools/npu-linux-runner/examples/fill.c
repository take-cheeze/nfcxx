/* Example kernel for run_kernel.py: write FP16 1.5 (0x3e00) to every output element, ignoring the input.
 * The output descriptor is the third 40-byte tensor record that the carrier passes to the kernel. */
typedef unsigned int u32;
typedef unsigned char u8;
static u32 pword(const u8 *p) { return (u32)p[0] | ((u32)p[1] << 8) | ((u32)p[2] << 16) | ((u32)p[3] << 24); }
void nr_probe_kernel(const u8 *params) {
    u8 *out = (u8 *)pword(params + 80);
    int i;
    for (i = 0; i < 8; ++i) { out[2 * i] = 0x00; out[2 * i + 1] = 0x3e; }
}
