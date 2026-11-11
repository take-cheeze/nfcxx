// EXPECT: 42
// GNU range designators [lo ... hi] (the kernel's hashtable and cpumask initializers: scalar and braced elements, a later
// designator overriding one, the array continuing after the range), and an array of unknown size with {}
struct hlist_head { void *first; };
#define HLIST_HEAD_INIT { .first = 0 }
static struct hlist_head table[8] = { [0 ... 7] = HLIST_HEAD_INIT };
static unsigned long mask[4] = { [0 ... 2] = ~0UL, 5 };
static int bases[6] = { [0 ... 5] = 9, [2] = 1 };
static const char *names[] = { [1 ... 3] = "x", [5] = "y" };
struct pt { int x, y; };
static struct pt pts[5] = { [1 ... 3] = { 4, 5 } };
int empty[] = {};
int main(void) {
	int local[5] = { [0 ... 4] = 7 };
	int sum = 0;
	for (int i = 0; i < 8; i++) if (table[i].first) return 1;
	if (mask[0] != ~0UL || mask[2] != ~0UL || mask[3] != 5) return 2;
	if (bases[0] != 9 || bases[2] != 1 || bases[5] != 9) return 3;
	if (sizeof names / sizeof names[0] != 6 || names[0] || !names[3] || names[3][0] != 'x' || names[4]) return 4;
	if (pts[0].x || pts[2].y != 5 || pts[3].x != 4 || pts[4].x) return 5;
	for (int i = 0; i < 5; i++) sum += local[i];
	if (sizeof empty != 0) return 6;
	return sum == 35 ? 42 : 7;
}
