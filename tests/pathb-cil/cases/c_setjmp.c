// EXPECT-REFUSED: setjmp is not supported
#include <setjmp.h>
static jmp_buf jb;
int main(void) { if (setjmp(jb) == 0) longjmp(jb, 1); return 3; }
