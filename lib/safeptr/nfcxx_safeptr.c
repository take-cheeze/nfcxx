/* nfcxx -fsafe-pointers runtime (docs/notes/safe-pointers.md): a table of the program's live and freed objects, and
   the two checks Path B code calls before it uses a pointer.

   __nfcxx_sp_check(p, n, file, line)          before a load, store or block access of n bytes at p
   __nfcxx_sp_derive(base, res, file, line)    after pointer arithmetic: res = base + something

   An object is a heap block (malloc and friends, interposed here, so libstdc++'s and libC.a's operator new are covered),
   a global of an instrumented translation unit (registered by its constructor, __nfcxx_sp_globals) or an escaping stack
   slot of an instrumented function (__nfcxx_sp_frame at entry, __nfcxx_sp_leave at every return). Every object is
   allocated one byte longer than its size, so the address one past its end is never the start of another object, and a
   pointer's object is the one whose [lo, hi] holds it: the provenance of the pointer, which pointer arithmetic must
   stay within (C++ allows one past the end, not more). An access must lie in [lo, hi) of a live object.

   Memory that is in no object (libc's data, thread-local objects, stacks of uninstrumented code) is not checked: the
   checks are Fil-C's, the guarantee is not, since the program shares memory with code built without them.

   free() does not give a block back at once: it stays in the table as dead (a use is "use after free") until the
   quarantine (QUAR_MAX blocks, QUAR_BYTES bytes) pushes it out. Stack slots below the current stack pointer belong to
   frames that returned: a pointer to one is "use after return". */
#define _GNU_SOURCE
#include <errno.h>
#include <pthread.h>
#include <stdarg.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <unistd.h>

extern void *__libc_malloc(size_t);
extern void __libc_free(void *);
extern void *__libc_calloc(size_t, size_t);
extern void *__libc_memalign(size_t, size_t);

enum { K_OOB = 0, K_ARITH, K_UAF, K_RETURN, K_DFREE, K_BADFREE };
static const char *const sp_msg[] = {
  "out-of-bounds access",
  "pointer arithmetic leaves its object",
  "use after free",
  "use of a stack object after its function returned",
  "double free",
  "free of a pointer that is not the start of a heap block",
};

static void sp_fail(int kind, const void *p, const char *file, int line)
{
  fflush(stdout);
  fprintf(stderr, "%s:%d: safety error: %s (address %p)\n", file ? file : "?", line, sp_msg[kind], p);
  abort();
}

/* ---- the object table: heap blocks and globals. A hash of 256-byte granules to the objects that overlap them; an object
   of more than BIG bytes goes to a separate list instead of into every granule. Memory for the table comes from mmap,
   never malloc, so malloc can update it. One lock for all of it. */
enum { OBJ_LIVE = 1, OBJ_DEAD = 2 };
enum { KIND_HEAP = 1, KIND_GLOBAL = 2 };
struct obj {
  uintptr_t lo, hi;      /* [lo, hi): the object; hi is allowed as a pointer, the byte at hi is padding */
  unsigned char state, kind;
  void *raw;             /* the block to give to __libc_free (heap) */
  struct obj *qnext;     /* quarantine order */
  struct obj *bnext;     /* big list */
  struct obj *fnext;     /* free list of records */
};
struct node {            /* one granule of one object */
  uintptr_t g;
  struct obj *o;
  struct node *next;
};

#define GSHIFT 8
#define BIG (64u * 1024u)
#define NBUCKET (1u << 20)
#define QUAR_MAX 4096
#define QUAR_BYTES (64u << 20)

static pthread_mutex_t sp_lock = PTHREAD_MUTEX_INITIALIZER;
static struct node **buckets;
static struct obj *bigs;
static struct obj *ofree;
static struct node *nfree;
static struct obj *qhead, *qtail;
static size_t qcount, qbytes;
/* Bumped (under the lock) whenever an object dies or leaves the table. Each thread keeps the last live object it found,
   with the generation it found it in, and uses it without the lock while the generation is the same. */
static volatile unsigned long sp_gen;
static __thread uintptr_t c_lo, c_hi;
static __thread unsigned long c_gen = ~0ul;

static void *sp_mmap(size_t n)
{
  void *p = mmap(NULL, n, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS | MAP_NORESERVE, -1, 0);
  if (p == MAP_FAILED) {
    static const char m[] = "nfcxx safe-pointers: out of memory for the object table\n";
    (void)!write(2, m, sizeof m - 1);
    abort();
  }
  return p;
}

static void sp_init_locked(void)
{
  if (!buckets) buckets = sp_mmap(NBUCKET * sizeof *buckets);
}

static struct obj *obj_new(void)
{
  if (!ofree) {
    size_t n = (1u << 20) / sizeof(struct obj);
    struct obj *a = sp_mmap(n * sizeof *a);
    for (size_t i = 0; i < n; i++) { a[i].fnext = ofree; ofree = &a[i]; }
  }
  struct obj *o = ofree;
  ofree = o->fnext;
  memset(o, 0, sizeof *o);
  return o;
}

static struct node *node_new(void)
{
  if (!nfree) {
    size_t n = (1u << 20) / sizeof(struct node);
    struct node *a = sp_mmap(n * sizeof *a);
    for (size_t i = 0; i < n; i++) { a[i].next = nfree; nfree = &a[i]; }
  }
  struct node *x = nfree;
  nfree = x->next;
  return x;
}

static size_t bucket_of(uintptr_t g) { return (size_t)((g * 0x9E3779B97F4A7C15ull) >> 44) & (NBUCKET - 1); }

/* The granules of an object: [lo, hi] (hi included, one-past-the-end pointers must find it). */
static void obj_insert(struct obj *o)
{
  if (o->hi - o->lo > BIG) { o->bnext = bigs; bigs = o; return; }
  for (uintptr_t g = o->lo >> GSHIFT; g <= o->hi >> GSHIFT; g++) {
    struct node *x = node_new();
    size_t b = bucket_of(g);
    x->g = g; x->o = o; x->next = buckets[b]; buckets[b] = x;
  }
}

static void obj_remove(struct obj *o)
{
  if (o->hi - o->lo > BIG) {
    for (struct obj **pp = &bigs; *pp; pp = &(*pp)->bnext)
      if (*pp == o) { *pp = o->bnext; break; }
    return;
  }
  for (uintptr_t g = o->lo >> GSHIFT; g <= o->hi >> GSHIFT; g++) {
    for (struct node **pp = &buckets[bucket_of(g)]; *pp; pp = &(*pp)->next)
      if ((*pp)->g == g && (*pp)->o == o) { struct node *x = *pp; *pp = x->next; x->next = nfree; nfree = x; break; }
  }
}

/* The object with lo <= a < hi, else the one with hi == a (one past its end), else NULL. Padding makes the answer
   unique. A dead object is returned too. */
static struct obj *obj_find(uintptr_t a)
{
  struct obj *past = NULL;
  if (!buckets) return NULL;
  for (struct node *x = buckets[bucket_of(a >> GSHIFT)]; x; x = x->next) {
    if (x->g != a >> GSHIFT) continue;
    if (x->o->lo <= a && a < x->o->hi) return x->o;
    if (x->o->hi == a) past = x->o;
  }
  for (struct obj *o = bigs; o; o = o->bnext) {
    if (o->lo <= a && a < o->hi) return o;
    if (o->hi == a) past = o;
  }
  return past;
}

/* ---- stack objects: per thread, the escaping slots of the live instrumented frames, sorted by address from the highest
   down (a frame's slots are sorted at entry; frames nest, each callee below its caller, so the order holds across frames),
   and a stack of frames, each its slots' extent and where its slots start. Frames left by longjmp (EDG's exceptions) are
   popped by the next frame entry below them or by the return of a frame above them. */
struct srec { uintptr_t lo, hi; };
struct sframe { uintptr_t lo, hi; size_t start; };
static __thread struct srec *sstack;
static __thread size_t sdepth, scap;
static __thread struct sframe *frames;
static __thread size_t fdepth, fcap;
static __thread uintptr_t stk_lo, stk_hi;   /* this thread's stack, from pthread_getattr_np (0: not known yet) */
static __thread int stk_known;

static void stack_bounds(void)
{
  pthread_attr_t at;
  void *addr;
  size_t size;
  stk_known = 1;
  if (pthread_getattr_np(pthread_self(), &at) != 0) return;
  if (pthread_attr_getstack(&at, &addr, &size) == 0) { stk_lo = (uintptr_t)addr; stk_hi = (uintptr_t)addr + size; }
  pthread_attr_destroy(&at);
}

static void *grow(void *old, size_t used, size_t *cap, size_t elt)
{
  size_t ncap = *cap ? *cap * 2 : 1024;
  void *n = sp_mmap(ncap * elt);
  if (old) { memcpy(n, old, used * elt); munmap(old, *cap * elt); }
  *cap = ncap;
  return n;
}

/* __nfcxx_sp_frame(N, p1, size1, ..., pN, sizeN): the escaping slots of a function that was just entered. */
void __nfcxx_sp_frame(int n, ...)
{
  va_list ap;
  uintptr_t lo = UINTPTR_MAX, hi = 0;
  struct srec r[64];
  int m = n < 64 ? n : 64;   /* the slots after 64 are not registered: accesses to them are not checked */
  va_start(ap, n);
  for (int i = 0; i < n; i++) {
    uintptr_t a = va_arg(ap, uintptr_t), z = va_arg(ap, uintptr_t);
    if (i < m) { r[i].lo = a; r[i].hi = a + z; }
    if (a < lo) lo = a;
    if (a + z > hi) hi = a + z;
  }
  va_end(ap);
  /* Frames below this frame's top are gone (left by longjmp). */
  while (fdepth > 0 && frames[fdepth - 1].lo < hi) sdepth = frames[--fdepth].start;
  if (fdepth == fcap) frames = grow(frames, fdepth, &fcap, sizeof *frames);
  frames[fdepth].lo = lo; frames[fdepth].hi = hi; frames[fdepth].start = sdepth;
  fdepth++;
  for (int i = 1; i < m; i++)   /* insertion sort, highest address first */
    for (int j = i; j > 0 && r[j].lo > r[j - 1].lo; j--) { struct srec t = r[j]; r[j] = r[j - 1]; r[j - 1] = t; }
  while (sdepth + m > scap) sstack = grow(sstack, sdepth, &scap, sizeof *sstack);
  memcpy(&sstack[sdepth], r, m * sizeof *r);
  sdepth += m;
}

/* __nfcxx_sp_leave(p): the function whose slot p is returns; pop its frame (and anything stale above it). */
void __nfcxx_sp_leave(void *p)
{
  uintptr_t a = (uintptr_t)p;
  for (size_t i = fdepth; i > 0; i--)
    if (frames[i - 1].lo <= a && a < frames[i - 1].hi) { sdepth = frames[i - 1].start; fdepth = i - 1; return; }
}

static int in_dead_stack(uintptr_t a, uintptr_t sp)
{
  if (!stk_known) stack_bounds();
  return stk_lo <= a && a < sp;
}

/* The stack record holding a ([lo, hi]), or NULL. sp: the current stack pointer, records below it are of dead frames. */
static struct srec *srec_find(uintptr_t a, uintptr_t sp)
{
  if (!stk_known) stack_bounds();
  if (a < sp || (stk_hi && a > stk_hi) || sdepth == 0) return NULL;   /* not in the live part of this thread's stack */
  /* the first record (highest address first) with lo <= a */
  size_t l = 0, h = sdepth;
  while (l < h) {
    size_t mid = l + (h - l) / 2;
    if (sstack[mid].lo <= a) h = mid; else l = mid + 1;
  }
  if (l < sdepth && a < sstack[l].hi) return &sstack[l];
  /* one past the end: the record ending at a starts below a */
  for (size_t i = l; i < sdepth && i < l + 2; i++)
    if (sstack[i].hi == a) return &sstack[i];
  return NULL;
}

/* ---- the checks */
void __nfcxx_sp_check(void *p, size_t n, const char *file, int line)
{
  uintptr_t a = (uintptr_t)p;
  uintptr_t sp = (uintptr_t)__builtin_frame_address(0);
  if (a == 0) return;   /* null dereferences are the nonnull check's */
  if (c_gen == sp_gen && c_lo <= a && a < c_hi && n <= c_hi - a) return;
  struct srec *r = srec_find(a, sp);
  if (r) {
    if (a >= r->hi || n > r->hi - a) sp_fail(K_OOB, p, file, line);
    return;
  }
  if (in_dead_stack(a, sp)) sp_fail(K_RETURN, p, file, line);
  pthread_mutex_lock(&sp_lock);
  struct obj *o = obj_find(a);
  int kind = -1;
  if (o) {
    if (o->state == OBJ_DEAD) kind = K_UAF;
    else if (a >= o->hi || n > o->hi - a) kind = K_OOB;
    else { c_lo = o->lo; c_hi = o->hi; c_gen = sp_gen; }
  }
  pthread_mutex_unlock(&sp_lock);
  if (kind >= 0) sp_fail(kind, p, file, line);
}

void *__nfcxx_sp_derive(void *base, void *res, const char *file, int line)
{
  uintptr_t b = (uintptr_t)base, r = (uintptr_t)res;
  uintptr_t sp = (uintptr_t)__builtin_frame_address(0);
  if (b == 0 || b == r) return res;
  if (c_gen == sp_gen && c_lo <= b && b <= c_hi && c_lo <= r && r <= c_hi) return res;
  struct srec *s = srec_find(b, sp);
  if (s) {
    if (r < s->lo || r > s->hi) sp_fail(K_ARITH, res, file, line);
    return res;
  }
  if (in_dead_stack(b, sp)) sp_fail(K_RETURN, base, file, line);
  pthread_mutex_lock(&sp_lock);
  struct obj *o = obj_find(b);
  int kind = -1;
  if (o) {
    if (o->state == OBJ_DEAD) kind = K_UAF;
    else if (r < o->lo || r > o->hi) kind = K_ARITH;
    else { c_lo = o->lo; c_hi = o->hi; c_gen = sp_gen; }
  }
  pthread_mutex_unlock(&sp_lock);
  if (kind >= 0) sp_fail(kind, kind == K_UAF ? base : res, file, line);
  return res;
}

/* __nfcxx_sp_globals(table, n): n pairs (address, size) of the globals of one translation unit, from its constructor.
   A COMDAT global defined by several units is registered once. */
void __nfcxx_sp_globals(const uintptr_t *t, long n)
{
  pthread_mutex_lock(&sp_lock);
  sp_init_locked();
  for (long i = 0; i < n; i++) {
    uintptr_t lo = t[2 * i], sz = t[2 * i + 1];
    struct obj *f = obj_find(lo);
    if (f && f->lo == lo) continue;
    struct obj *o = obj_new();
    o->lo = lo; o->hi = lo + sz; o->state = OBJ_LIVE; o->kind = KIND_GLOBAL;
    obj_insert(o);
  }
  pthread_mutex_unlock(&sp_lock);
}

/* ---- the heap: malloc and friends over glibc's, one padding byte per block */
static void *heap_track(void *raw, void *p, size_t n)
{
  if (!p) return NULL;
  pthread_mutex_lock(&sp_lock);
  sp_init_locked();
  struct obj *o = obj_new();
  o->lo = (uintptr_t)p; o->hi = (uintptr_t)p + n; o->state = OBJ_LIVE; o->kind = KIND_HEAP; o->raw = raw;
  obj_insert(o);
  pthread_mutex_unlock(&sp_lock);
  return p;
}

void *malloc(size_t n)
{
  if (n + 1 < n) { errno = ENOMEM; return NULL; }
  void *p = __libc_malloc(n + 1);
  return heap_track(p, p, n);
}

void *calloc(size_t a, size_t b)
{
  size_t n;
  if (__builtin_mul_overflow(a, b, &n) || n + 1 < n) { errno = ENOMEM; return NULL; }
  void *p = __libc_calloc(1, n + 1);
  return heap_track(p, p, n);
}

void *memalign(size_t al, size_t n)
{
  if (n + 1 < n) { errno = ENOMEM; return NULL; }
  void *p = __libc_memalign(al, n + 1);
  return heap_track(p, p, n);
}

void *aligned_alloc(size_t al, size_t n) { return memalign(al, n); }
void *valloc(size_t n) { return memalign((size_t)sysconf(_SC_PAGESIZE), n); }
void *pvalloc(size_t n)
{
  size_t pg = (size_t)sysconf(_SC_PAGESIZE);
  return memalign(pg, (n + pg - 1) & ~(pg - 1));
}

int posix_memalign(void **out, size_t al, size_t n)
{
  if (al < sizeof(void *) || (al & (al - 1))) return EINVAL;
  void *p = memalign(al, n);
  if (!p) return ENOMEM;
  *out = p;
  return 0;
}

/* The live heap object starting at p, under the lock; fails on a dead or interior pointer. NULL: not ours. */
static struct obj *heap_lookup_locked(void *p, int *kind)
{
  struct obj *o = obj_find((uintptr_t)p);
  *kind = -1;
  if (!o || o->kind != KIND_HEAP) return NULL;
  if (o->state == OBJ_DEAD && o->lo == (uintptr_t)p) { *kind = K_DFREE; return NULL; }
  if (o->lo != (uintptr_t)p) { *kind = K_BADFREE; return NULL; }
  return o;
}

void free(void *p)
{
  int kind;
  if (!p) return;
  pthread_mutex_lock(&sp_lock);
  struct obj *o = heap_lookup_locked(p, &kind);
  if (kind >= 0) { pthread_mutex_unlock(&sp_lock); sp_fail(kind, p, "free", 0); }
  if (!o) { pthread_mutex_unlock(&sp_lock); __libc_free(p); return; }   /* allocated before us, or not by malloc */
  o->state = OBJ_DEAD;
  sp_gen++;
  o->qnext = NULL;
  if (qtail) qtail->qnext = o; else qhead = o;
  qtail = o;
  qcount++; qbytes += o->hi - o->lo;
  void *give[16];
  int ng = 0;
  while (qhead && (qcount > QUAR_MAX || qbytes > QUAR_BYTES) && ng < 16) {
    struct obj *v = qhead;
    qhead = v->qnext;
    if (!qhead) qtail = NULL;
    qcount--; qbytes -= v->hi - v->lo;
    obj_remove(v);
    give[ng++] = v->raw;
    v->fnext = ofree; ofree = v;
  }
  pthread_mutex_unlock(&sp_lock);
  for (int i = 0; i < ng; i++) __libc_free(give[i]);
}

void cfree(void *p) { free(p); }

void *realloc(void *p, size_t n)
{
  int kind;
  if (!p) return malloc(n);
  if (n == 0) { free(p); return NULL; }
  pthread_mutex_lock(&sp_lock);
  struct obj *o = heap_lookup_locked(p, &kind);
  size_t old = o ? o->hi - o->lo : 0;
  pthread_mutex_unlock(&sp_lock);
  if (kind >= 0) sp_fail(kind == K_DFREE ? K_UAF : kind, p, "realloc", 0);
  if (!o) {
    /* a block from before the runtime: glibc's realloc knows it, but then the result would be untracked; copy instead */
    extern void *__libc_realloc(void *, size_t);
    return __libc_realloc(p, n);
  }
  void *q = malloc(n);
  if (!q) return NULL;
  memcpy(q, p, old < n ? old : n);
  free(p);
  return q;
}

void *reallocarray(void *p, size_t a, size_t b)
{
  size_t n;
  if (__builtin_mul_overflow(a, b, &n)) { errno = ENOMEM; return NULL; }
  return realloc(p, n);
}

size_t malloc_usable_size(void *p)
{
  int kind;
  if (!p) return 0;
  pthread_mutex_lock(&sp_lock);
  struct obj *o = heap_lookup_locked(p, &kind);
  size_t n = o ? o->hi - o->lo : 0;
  pthread_mutex_unlock(&sp_lock);
  return n;
}
