// EXPECT: 42
// Static initializers gcc takes as constants: a range designator's converted negative constant (the kernel's
// xstate_offsets[] = { [0 ... N - 1] = -1 }), and an address cast to unsigned long plus and minus constants
// (TOP_OF_INIT_STACK, (unsigned long)&init_stack + sizeof(init_stack) - padding)
static unsigned int offsets[6] = { [0 ... 5] = -1 };
static unsigned char stack[64];
struct hot { unsigned long top; void *cur; } hot = { .top = (unsigned long)&stack + sizeof(stack) - 0, .cur = 0 };
unsigned long below = (unsigned long)&stack + sizeof(stack) - 8;
unsigned long past = (unsigned long)stack + 4 + 4;
int main(void) {
	for (int i = 0; i < 6; ++i)
		if (offsets[i] != 0xffffffffu) return 1;
	if (hot.top != (unsigned long)(stack + 64) || below != (unsigned long)(stack + 56) || past != (unsigned long)(stack + 8)) return 2;
	return 42;
}
