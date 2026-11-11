/* The header of the Library test (tests/ffi/host.cpp): Ffi::load includes it before dyn_impl.c. */
typedef struct { double x, y; } Vec2;
typedef struct { long a, b, c; } Big;

int add_int(int a, int b);
double scale(double v, double k);
float halve(float x);
double mixed(float a, int b, double c, char d);
Vec2 vec_add(Vec2 a, Vec2 b);
Big big_make(long v);
unsigned long count_bytes(const char *s);
int call_back(int (*f)(int), int v);
int sum_all(int n, ...);
