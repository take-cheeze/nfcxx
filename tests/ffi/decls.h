#include <stddef.h>
typedef struct { double x, y; } Vec2;
typedef struct Pair { int a; long b; } Pair;
enum Color { RED, GREEN };
int add(int a, int b);
double scale(double v, double k);
const char *name(const char *s, unsigned long n);
Vec2 vec_add(Vec2 a, Vec2 b);
Pair pair_make(int a);
void sort(void *base, size_t n, size_t sz, int (*cmp)(const void *, const void *));
int printf_like(const char *fmt, ...);
int noargs(void);
enum Color pick(enum Color c);
int takes_array(int xs[4], char *const p);
void *alloc(size_t n);
int call_back(int (*f)(int), int v);
_Bool flag(_Bool b);
