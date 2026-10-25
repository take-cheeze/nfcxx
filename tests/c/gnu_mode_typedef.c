// EXPECT: 42
// ELF-ONLY: mode is gcc's; Apple clang does not give these sizes
// GNU mode on a declaration of an integer type (glibc's sys/types.h: typedef int register_t
// __attribute__ ((__mode__ (__word__)))): the integer type of that size and signedness, as gcc lays it out. cproc
// ignored the attribute before, and register_t was 4 bytes. glibc's typedef is spelled out: in nfcxx's C-input mode
// glibc's headers define __attribute__ away (docs/notes/cproc-nfcxx.md).
typedef int register_t __attribute__ ((__mode__ (__word__)));
typedef int word_t __attribute__((__mode__(__word__)));
typedef unsigned int u8m __attribute__((mode(QI)));
__attribute__((mode(HI))) int h;
struct s { int a __attribute__((mode(DI))); int b; };
enum e { A, B } __attribute__((mode(byte)));
_Static_assert(sizeof(register_t) == 8 && sizeof(word_t) == 8 && sizeof(u8m) == 1 && sizeof(h) == 2, "mode");
_Static_assert(sizeof(struct s) == 16 && sizeof(enum e) == 1, "member and enum");
int main(void) {
	u8m c = 255;
	word_t w = -1;
	c++;
	h = 40000;   /* 16 bits */
	return c == 0 && w < 0 && h == 40000 - 65536 ? 42 : 1;
}
