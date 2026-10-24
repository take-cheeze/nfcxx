/* The C source tests/ffi/host.cpp compiles at run time (nfcffi). Each function is called through a C++ signature in the host. */
#include <string.h>

typedef struct { double x, y; } Vec2;      /* two SSE eightbytes: returned and passed in xmm registers */
typedef struct { long a, b, c; } Big;      /* 24 bytes: returned through a hidden pointer */
typedef struct { int n; char tag; } Small; /* 8 bytes, one integer register */

int add_int(int a, int b) { return a + b; }
double scale(double v, double k) { return v * k; }
float halve(float x) { return x / 2; }
double mixed(float a, int b, double c, char d) { return a + b + c + d; }
Vec2 vec_add(Vec2 a, Vec2 b) { Vec2 r = {a.x + b.x, a.y + b.y}; return r; }
Big big_make(long v) { Big r = {v, 2 * v, 3 * v}; return r; }
Small small_make(int n) { Small r = {n, 'z'}; return r; }
unsigned long count_bytes(const char *s) { return strlen(s); }
int call_back(int (*f)(int), int v) { return f(v); }
