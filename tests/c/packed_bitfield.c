// EXPECT: 42
// GNU packed on a struct with bit-fields, where packing moves nothing (the kernel's desc_struct, and its orc_entry,
// whose bit-fields cproc moves to narrower units so no access reaches past the 6 bytes): the layout (size, alignment,
// field positions), reads and writes of every field and initializers, as gcc lays it out

typedef unsigned short u16;
struct desc {
	u16 limit0;
	u16 base0;
	u16 base1: 8, type: 4, s: 1, dpl: 2, p: 1;
	u16 limit1: 4, avl: 1, l: 1, d: 1, g: 1, base2: 8;
} __attribute__((packed));
struct tail { unsigned int a; unsigned char flags: 3, mode: 5; } __attribute__((packed));
_Static_assert(sizeof(struct desc) == 8 && _Alignof(struct desc) == 1, "desc layout");
_Static_assert(sizeof(struct tail) == 5 && _Alignof(struct tail) == 1, "tail layout");
struct outer { char c; struct desc d; } __attribute__((packed));
typedef short s16;
struct orc_entry { s16 sp_offset; s16 bp_offset; unsigned sp_reg:4; unsigned bp_reg:4; unsigned type:3; unsigned signal:1; } __attribute__((packed));
struct wide { unsigned char a; unsigned x: 12; unsigned y: 4; int z:7; } __attribute__((packed));
struct full { unsigned short a; unsigned x: 8; } __attribute__((packed));
_Static_assert(sizeof(struct orc_entry) == 6 && sizeof(struct wide) == 4 && sizeof(struct full) == 3, "narrowed units");
_Static_assert(sizeof(struct outer) == 9, "nested");
int main(void) {
	struct desc d;
	unsigned char raw[8];
	__builtin_memset(&d, 0, sizeof d);
	d.limit0 = 0xffff; d.base1 = 0x12; d.type = 0xb; d.s = 1; d.dpl = 3; d.p = 1;
	d.limit1 = 0xf; d.g = 1; d.l = 1; d.base2 = 0xab;
	__builtin_memcpy(raw, &d, 8);
	if (raw[0] != 0xff || raw[1] != 0xff || raw[4] != 0x12 || raw[5] != 0xfb || raw[6] != 0xaf || raw[7] != 0xab) return 1;
	if (d.type != 0xb || d.dpl != 3 || d.base2 != 0xab || d.avl != 0) return 2;
	struct tail t = { 7, 5, 31 };
	if (t.flags != 5 || t.mode != 31 || ((unsigned char *)&t)[4] != (5 | 31 << 3)) return 3;
	struct outer o; __builtin_memset(&o, 0, sizeof o); o.d.dpl = 2;
	if (((unsigned char *)&o)[6] != 0x40) return 4;
	struct orc_entry oe[2]; unsigned char *b = (unsigned char *)oe;
	for (int i = 0; i < 12; i++) b[i] = 0xa5;
	oe[0].sp_reg = 3; oe[0].bp_reg = 12; oe[0].type = 5; oe[0].signal = 0;
	if (b[4] != 0xc3 || b[5] != (0xa5 & ~0xf | 5) || b[6] != 0xa5 || oe[0].type != 5 || oe[1].sp_offset != (s16)0xa5a5) return 5;
	struct wide w; unsigned char *c = (unsigned char *)&w;
	__builtin_memset(&w, 0, sizeof w);
	w.a = 0xff; w.x = 0xabc; w.y = 9; w.z = -3;
	if (c[0] != 0xff || c[1] != 0xbc || c[2] != (0x0a | 9 << 4) || c[3] != 0x7d || w.z != -3 || w.x + 1 != 0xabd) return 6;
	if (w.z * 2 != -6 || (w.x << 20) != (int)(0xabcu << 20)) return 7;
	struct full f = { 1, 200 }; if (f.x + 100 != 300 || ((unsigned char *)&f)[2] != 200) return 8;
	struct orc_entry init = { 1, 2, 7, 1, 6, 1 }; unsigned char *ib = (unsigned char *)&init;
	if (ib[4] != 0x17 || ib[5] != 0xe) return 9;
	return 42;
}
