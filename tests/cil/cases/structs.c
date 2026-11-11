// EXPECT: 0
#include <stdio.h>
struct vec { double x, y, z; };
struct rec { char tag; short s; int i; long l; unsigned char bytes[5]; };
static struct vec add(struct vec a, struct vec b) { struct vec r = { a.x + b.x, a.y + b.y, a.z + b.z }; return r; }
static struct rec make(int k) { struct rec r; r.tag = 'a' + k; r.s = -k; r.i = k * 1000; r.l = (long)k << 40; for (int j = 0; j < 5; j++) r.bytes[j] = j * k; return r; }
int main(void) {
    struct vec v = add((struct vec){1, 2, 3}, (struct vec){0.5, 0.25, 0.125});
    struct rec r = make(3), copy = r;
    copy.bytes[4] = 200;
    printf("%.3f %.3f %.3f\n", v.x, v.y, v.z);
    printf("%c %d %d %ld %d %d\n", copy.tag, copy.s, copy.i, copy.l, copy.bytes[3], copy.bytes[4]);
    return (r.i + copy.bytes[4]) & 0x7f;
}
