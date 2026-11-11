// EXPECT: 42
// Register pressure across a loop: QBE moves spilled values between stack slots, through %xmm15 normally and through
// %rax under qbe -n (the kernel mode's -mno-sse; tests/c/cc-mode.sh compiles this file there too). The value is gcc's.
unsigned long mix(unsigned long seed, int iters) {
	unsigned long v0 = seed * 3 + 0;
	unsigned long v1 = seed * 4 + 1;
	unsigned long v2 = seed * 5 + 2;
	unsigned long v3 = seed * 6 + 3;
	unsigned long v4 = seed * 7 + 4;
	unsigned long v5 = seed * 8 + 5;
	unsigned long v6 = seed * 9 + 6;
	unsigned long v7 = seed * 10 + 7;
	unsigned long v8 = seed * 11 + 8;
	unsigned long v9 = seed * 12 + 9;
	unsigned long v10 = seed * 13 + 10;
	unsigned long v11 = seed * 14 + 11;
	unsigned long v12 = seed * 15 + 12;
	unsigned long v13 = seed * 16 + 13;
	unsigned long v14 = seed * 17 + 14;
	unsigned long v15 = seed * 18 + 15;
	unsigned long v16 = seed * 19 + 16;
	unsigned long v17 = seed * 20 + 17;
	unsigned long v18 = seed * 21 + 18;
	unsigned long v19 = seed * 22 + 19;
	unsigned long v20 = seed * 23 + 20;
	unsigned long v21 = seed * 24 + 21;
	unsigned long v22 = seed * 25 + 22;
	unsigned long v23 = seed * 26 + 23;
	unsigned int w0 = seed, w1 = seed >> 3;
	for (int k = 0; k < iters; k++) {
		unsigned long t = v0;
		v0 = v1 + (v5 >> 1);
		v1 = v2 + (v6 >> 2);
		v2 = v3 + (v7 >> 3);
		v3 = v4 + (v8 >> 4);
		v4 = v5 + (v9 >> 5);
		v5 = v6 + (v10 >> 6);
		v6 = v7 + (v11 >> 7);
		v7 = v8 + (v12 >> 1);
		v8 = v9 + (v13 >> 2);
		v9 = v10 + (v14 >> 3);
		v10 = v11 + (v15 >> 4);
		v11 = v12 + (v16 >> 5);
		v12 = v13 + (v17 >> 6);
		v13 = v14 + (v18 >> 7);
		v14 = v15 + (v19 >> 1);
		v15 = v16 + (v20 >> 2);
		v16 = v17 + (v21 >> 3);
		v17 = v18 + (v22 >> 4);
		v18 = v19 + (v23 >> 5);
		v19 = v20 + (v0 >> 6);
		v20 = v21 + (v1 >> 7);
		v21 = v22 + (v2 >> 1);
		v22 = v23 + (v3 >> 2);
		v23 = t ^ k;
		unsigned int tw = w0; w0 = w1 + k; w1 = tw;
		if (v3 & 1) { unsigned long u = v7; v7 = v11; v11 = u; }
	}
	return v0 ^ v1 ^ v2 ^ v3 ^ v4 ^ v5 ^ v6 ^ v7 ^ v8 ^ v9 ^ v10 ^ v11 ^ v12 ^ v13 ^ v14 ^ v15 ^ v16 ^ v17 ^ v18 ^ v19 ^ v20 ^ v21 ^ v22 ^ v23 ^ w0 ^ w1;
}
unsigned long (*volatile mixp)(unsigned long, int) = mix;
int main(void) { return mixp(12345, 1000) == 2037161969011868470UL ? 42 : 1; }
