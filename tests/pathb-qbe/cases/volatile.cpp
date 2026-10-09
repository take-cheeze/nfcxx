// Path B: volatile objects (docs/notes/pathb-stage3.md, "volatile"). Every access to a volatile object must be a real
// load or store that QBE cannot remove, merge or reorder: a loop flag set by another thread, a volatile sum, volatile
// struct members, a volatile global, a pointer to volatile, a volatile parameter, a volatile array.
// EXPECT: 0
// ASM-COUNT: vol_twice __pathb_vld_ 2
// ASM-COUNT: vol_unused_read __pathb_vld_ 1
// ASM-COUNT: vol_two_stores __pathb_vst_ 2
// ASM-COUNT: vol_local __pathb_v 4
// ASM-COUNT: plain_twice __pathb_v 0
// (The ASM-COUNT lines are checked by tests/pathb-qbe/run.sh: the named function of the assembly QBE produced must
// contain exactly that many calls whose callee starts with the given prefix. plain_twice is the control: the same
// code without volatile calls no helper, so the check can tell the two apart.)
extern "C" {
int pthread_create(unsigned long *, const void *, void *(*)(void *), void *);
int pthread_join(unsigned long, void **);
int sched_yield(void);
}

volatile int g_flag;
volatile int g_count;
volatile unsigned char g_byte;
volatile long g_long = 7;
volatile double g_dbl = 1.5;
volatile bool g_bool;
int *volatile g_ptr;               // a volatile pointer to a plain int
const volatile int g_ro = 41;       // const volatile

struct Dev {
  volatile int status;
  volatile unsigned short data;
  int plain;
};
Dev g_dev;

extern "C" void *setter(void *) {
  sched_yield();
  g_flag = 1;                       // a store the spinning thread has to see
  return 0;
}

// Reads the flag twice: two loads, not one (a plain int could be merged).
int twice(volatile int *p) {
  int a = *p;
  int b = *p;
  return a + b;
}

int sum_loop(int n) {
  volatile int s = 0;               // a volatile local: lives in memory
  for (int i = 1; i <= n; i++) s = s + i;
  return s;
}

int by_param(volatile int x) {      // a volatile parameter
  x = x + 1;
  x = x + 1;
  return x;
}

void bump(volatile Dev *d) {
  d->status = d->status + 1;
  d->data = (unsigned short)(d->data + 2);
  d->plain = d->plain + 3;
}

int sum_array() {
  volatile int a[4];
  for (int i = 0; i < 4; i++) a[i] = i * 10;
  int t = 0;
  for (int i = 0; i < 4; i++) t += a[i];
  return t;                         // 60
}

extern "C" {
int vol_twice(volatile int *p) { return *p + *p; }       // two loads: a plain int would be merged into one
void vol_unused_read(volatile int *p) { (void)*p; }       // a read whose value is dropped is still performed
void vol_two_stores(volatile int *p) { *p = 1; *p = 2; }  // two stores: the first is not dead
int vol_local() { volatile int v = 3; v = v + 1; return v; }   // init store, load, store, load
int plain_twice(int *p) { return *p + *p; }
}

int main() {
  int bad = 0;
  unsigned long th;
  pthread_create(&th, 0, setter, 0);
  while (!g_flag) { }               // must not be hoisted out of the loop
  pthread_join(th, 0);
  if (g_flag != 1) bad |= 1;

  if (sum_loop(10) != 55) bad |= 2;
  if (by_param(5) != 7) bad |= 4;

  g_dev.status = 1; g_dev.data = 65535; g_dev.plain = 1;
  bump(&g_dev);
  if (g_dev.status != 2 || g_dev.data != 1 || g_dev.plain != 4) bad |= 8;   // data wraps at 16 bits

  if (sum_array() != 60) bad |= 16;

  g_count = 0;
  for (int i = 0; i < 100; i++) g_count++;                 // ++ on a volatile: a load and a store
  g_count += 5;
  if (g_count != 105) bad |= 32;

  g_byte = 250; g_byte = (unsigned char)(g_byte + 10);
  if (g_byte != 4) bad |= 64;
  g_long = g_long * 3; g_dbl = g_dbl * 2.0;
  if (g_long != 21 || g_dbl != 3.0) bad |= 128;
  g_bool = true;
  if (!g_bool) bad |= 256;
  int x = 9; g_ptr = &x; *g_ptr = *g_ptr + 1;
  if (x != 10) bad |= 512;
  int y = 5;
  if (twice(&y) != 10) bad |= 1024;
  if (g_ro != 41) bad |= 2048;
  y = 7;
  if (vol_twice(&y) != 14 || vol_local() != 4 || plain_twice(&y) != 14) bad |= 4096;
  vol_two_stores(&y); vol_unused_read(&y);
  if (y != 2) bad |= 8192;
  (void)g_count;                    // a discarded volatile read is still a read
  return bad;
}
