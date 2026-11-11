// EXPECT: 42
// GNU C the kernel's headers rely on: a static object initialized from a compound literal of its type (DEFINE_RAW_SPINLOCK),
// a member after a struct ending in a flexible array member (tty_bufhead), and pointer arguments differing only in
// the signedness of their integer pointees (-Wpointer-sign)
typedef struct { int lock; int owner; } raw_spinlock_t;
#define DEFINE_RAW_SPINLOCK(x) raw_spinlock_t x = (raw_spinlock_t){ .lock = 1, .owner = 7 }
DEFINE_RAW_SPINLOCK(conf_lock);
struct holder { char tag; raw_spinlock_t l; } h = { 'h', (raw_spinlock_t){ 3, 4 } };
struct buf { int used; unsigned long data[]; };
struct head { struct buf *first; struct buf sentinel; int after; };
static int get(int *p) { return *p; }
int main(void) {
	unsigned int u = 0;
	if (get(&u) != 0) return 2;
	raw_spinlock_t local = (raw_spinlock_t){ 5 };
	struct head hd = { 0 }; hd.after = 9;
	_Static_assert(sizeof(struct head) == 24, "head");
	return conf_lock.lock == 1 && conf_lock.owner == 7 && h.l.owner == 4 && h.tag == 'h' && local.lock == 5 && local.owner == 0 && hd.after == 9 ? 42 : 1;
}
