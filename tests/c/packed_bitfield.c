// EXPECT: 42
// GNU packed on a struct with bit-fields, where packing moves nothing (the kernel's desc_struct): the layout (size,
// alignment, field positions) and reads and writes of every field, as gcc lays it out

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
	return 42;
}
