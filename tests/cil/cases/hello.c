// EXPECT: 140
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

struct point { int x, y; };
static struct point origin = { 3, 4 };
static const char *names[] = { "zero", "one", "two" };

static int dist2(struct point *p) { return p->x * p->x + p->y * p->y; }

int main(int argc, char **argv) {
    struct point pts[4];
    int i;
    for (i = 0; i < 4; i++) { pts[i].x = i; pts[i].y = 2 * i; }
    int *heap = malloc(sizeof(int) * 8);
    for (i = 0; i < 8; i++) heap[i] = i * i;
    int total = 0;
    for (i = 0; i < 8; i++) total += heap[i];
    free(heap);
    printf("argc=%d name=%s total=%d dist=%d %s\n", argc, names[1], total, dist2(&origin), strlen(argv[0]) > 0 ? "ok" : "no");
    printf("pt3=(%d,%d) third=%.4f\n", pts[3].x, pts[3].y, 1.0 / 3.0);
    return total % 256;
}
