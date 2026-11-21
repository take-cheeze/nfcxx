#include <stdio.h>
int ext_throw(int x) { if (x > 0) throw x; return -x; }
void ext_call(void (*f)(int), int x) { try { f(x); printf("ext_call: returned\n"); } catch (int e) { printf("ext_call: caught %d\n", e); } }
