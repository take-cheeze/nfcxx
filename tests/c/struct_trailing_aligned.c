/* EXPECT: 0 */
/* A GNU aligned attribute after a struct or union body raises its alignment (the SDK's mach/arm/_structs.h uses this form). */
struct s16 { char c; } __attribute__((aligned(16)));
union u32 { char c; short s; } __attribute__((aligned(32)));
struct plain { char c; };

int main(void) {
	if (_Alignof(struct s16) != 16 || sizeof(struct s16) != 16) return 1;
	if (_Alignof(union u32) != 32 || sizeof(union u32) != 32) return 2;
	if (_Alignof(struct plain) != 1) return 3;
	return 0;
}
