/* The gcc half of float16_abi_gcc.c. run.sh compiles this file with the host gcc (its "// GCC:" line), not with
   nfcxx's backend, so every _Float16 that crosses between the two halves follows gcc's SysV convention. */
typedef _Float16 f16;

/* the QBE half (float16_abi_gcc.c) */
f16 c_twice(f16 x);
long c_mix(int a, f16 h, double d, f16 k, long l, f16 m);
f16 c_nine(f16 a, f16 b, f16 c, f16 d, f16 e, f16 f, f16 g, f16 h, f16 i);
unsigned c_bits(f16 x);

/* called by the QBE half */
f16 g_add(f16 a, f16 b) { return a + b; }
f16 g_ident(f16 x) { return x; }
long g_mix(int a, f16 h, double d, f16 k, long l, f16 m)
{
	return a + 10 * (long)h + 100 * (long)d + 1000 * (long)k + 10000 * l + 100000 * (long)m;
}
f16 g_nine(f16 a, f16 b, f16 c, f16 d, f16 e, f16 f, f16 g, f16 h, f16 i)
{
	return a + b + c + d + e + f + g + h + i;
}

/* calls the QBE half */
f16 g_callback(f16 x) { return c_twice(x) + 1; }
long g_call_mix(void) { return c_mix(1, 3.0, 4.0, 5.0, 6, 7.0); }
f16 g_call_nine(void) { return c_nine(1, 2, 3, 4, 5, 6, 7, 8, 9); }

/* a result whose upper 16 bits (of the 32-bit lane that holds the float) are not zero: 0xffff3c00 is 1.0 in
   binary16 and the upper half is garbage, so a caller must take the low 16 bits only */
__attribute__((noinline)) f16 g_dirty(void)
{
	f16 r;
	__asm__("movl $0xffff3c00, %%eax\n\tmovd %%eax, %0" : "=x"(r) : : "eax");
	return r;
}
unsigned g_dirty_to_qbe(void) { return c_bits(g_dirty()); }
