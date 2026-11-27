/* nfcxx profiler runtime (docs/notes/profiler.md). Prototype format version 1, see the header comment below.
 *
 * File layout (host byte order; the byte-order marker lets a reader reject a file from another byte order):
 *   header:  char magic[8] = "NFCPROF1"; uint32 version = 1; uint32 byte_order = 0x01020304
 *   chunks:  repeated { uint32 tid; uint32 count; ... }
 *            tid != 0 and not reserved: count records, each { uint32 site; uint32 kind (0 enter, 1 exit); uint64 ts_ns (CLOCK_MONOTONIC) }
 *            tid == 0: the string table, written once at exit; count entries, each { uint32 site; uint32 len; char name[len] }
 *            tid == 0xFFFFFFFE: the machine description, count bytes of text (nfcxx_machine_format)
 *            tid == 0xFFFFFFFD: the run's allocation totals, count bytes of "allocs=N alloc_bytes=B frees=F" text
 *            tid == 0xFFFFFFFC: allocation counts of one thread by site, count bytes = 28 * rows; each row is
 *                               { uint32 site @0; uint64 allocs @4; uint64 bytes @12; uint64 frees @20 } (host byte order)
 *                               and a site may appear in several chunks (one per thread), so a reader adds them up.
 *                               Sites 0xFFFFFFFF (outside: no open call) and 0xFFFFFFFE (overflow: the thread has no row
 *                               left for the site) are not offsets of code.
 *
 * A site is the offset of the function from the start of the executable image (see nfcxx_prof_cyg.c). Its name is the
 * exported symbol that contains it (dladdr), or "+0x<offset>" when there is none. A site gets its name the first time a
 * flush sees it, so a site from a thread still running at exit may have no name.
 *
 * Each thread buffers up to PROF_CHUNK_RECORDS records and writes them as one chunk. A chunk's records are in the order
 * the thread produced them, so a thread's enters and exits nest as its calls nest. Chunks of different threads may
 * interleave in the file; the tid says which thread a chunk belongs to.
 *
 * Allocations: each thread keeps a row of counts per site (a fixed table of PROF_SITE_SLOTS rows, allocated at its first
 * event). A call's site is the one of the innermost open call of the thread; the wrappers in nfcxx_alloc.c add to that row
 * through nfcxx_alloc_cur, so they never allocate. A thread's rows are written at its exit.
 *
 * Threads: a thread's buffer is flushed when it exits (a pthread key destructor) and, for the thread that calls exit(),
 * at exit. Other threads still running when the process exits lose their unflushed records and counts.
 */
#define _GNU_SOURCE 1
#define _POSIX_C_SOURCE 200809L

#include "nfcxx_prof.h"
#include "nfcxx_machine.h"
#include "nfcxx_alloc.h"

/* weak, so a build that does not link nfcxx_alloc.c (the wrappers) still links; the counts are then zero */
extern void nfcxx_alloc_counts(uint64_t *allocs, uint64_t *bytes, uint64_t *frees) __attribute__((weak));

#include <dlfcn.h>
#include <errno.h>
#include <fcntl.h>
#include <pthread.h>
#include <stddef.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

#define PROF_VERSION 1u
#define PROF_BYTE_ORDER 0x01020304u
#define PROF_CHUNK_RECORDS 4096u
#define PROF_KIND_ENTER 0u
#define PROF_KIND_EXIT 1u
/* a chunk with this tid holds the machine description: count bytes of text (nfcxx_machine_format) */
#define PROF_TID_MACHINE 0xFFFFFFFEu
/* a chunk with this tid holds the run's allocation totals: count bytes of "key=value" text */
#define PROF_TID_COUNTERS 0xFFFFFFFDu
/* a chunk with this tid holds one thread's allocation counts by site: count bytes, PROF_ALLOC_ROW_BYTES per row */
#define PROF_TID_SITE_ALLOCS 0xFFFFFFFCu
#define PROF_ALLOC_ROW_BYTES 28u
#define PROF_ALLOC_BATCH 64u
/* per thread: rows of allocation counts (open addressing by site); at most PROF_SITE_LIMIT sites get a row, the rest of
 * the calls count in the overflow row. The limit keeps a free row in the table, so a lookup always ends. */
#define PROF_SITE_SLOTS 1024u
#define PROF_SITE_LIMIT 768u
#define PROF_SITE_OUTSIDE 0xFFFFFFFFu
#define PROF_SITE_OVERFLOW 0xFFFFFFFEu
/* the rows of a thread in the order flush_counts walks them: outside, overflow, then the site rows */
#define PROF_ROWS (PROF_SITE_SLOTS + 2u)

/* the first byte of the executable image; weak, so a build without it still links */
extern char __executable_start[] __attribute__((weak));

typedef struct {
  uint32_t site;
  uint32_t kind;
  uint64_t ts_ns;
} prof_rec;

typedef struct {
  uint32_t tid;
  uint32_t count;
} prof_chunk;

typedef struct {
  char magic[8];
  uint32_t version;
  uint32_t byte_order;
} prof_header;

typedef struct {
  prof_rec *buf;
  uint32_t n;
  uint32_t tid;
  int failed;
  nfcxx_site_count *counts;  /* PROF_SITE_SLOTS rows; NULL when they could not be allocated (calls then use overflow) */
  uint32_t nsites;           /* rows of counts in use */
  nfcxx_site_count outside;  /* allocations with no open call */
  nfcxx_site_count overflow; /* allocations of calls whose site has no row */
  nfcxx_site_count **saved;  /* the nfcxx_alloc_cur of each enclosing call, the innermost last */
  size_t sdepth, scap;
  size_t lost;               /* calls entered without a saved entry (the stack could not grow); their exits are skipped */
} prof_tls;

/* the sites seen so far, with their names: an open-addressing table keyed by site (capacity a power of two) */
typedef struct {
  uint32_t site;
  char *name;
  int used;
} name_slot;

static int g_enabled = 0;
static int g_fd = -1;
static pthread_mutex_t g_lock = PTHREAD_MUTEX_INITIALIZER; /* guards g_fd, the name table and g_next_tid */
static pthread_key_t g_key;
static uint32_t g_next_tid = 1;
static __thread prof_tls tls;
/* the row the calling thread's allocations are counted in (declared in nfcxx_alloc.h, used by nfcxx_alloc.c) */
__thread nfcxx_site_count *nfcxx_alloc_cur __attribute__((tls_model("initial-exec"))) = NULL;
static char *g_machine_text = NULL; /* the machine description, written at exit */
static size_t g_machine_len = 0;
static name_slot *g_slots = NULL;
static size_t g_cap = 0;
static size_t g_count = 0;

/* Timestamps. A record's ts_ns is nanoseconds from the start of the profile. On x86 with an invariant TSC the clock
 * is rdtsc, calibrated against CLOCK_MONOTONIC when the profile starts (about 5 ms); otherwise, or with
 * NFCXX_PROFILE_CLOCK=monotonic, it is CLOCK_MONOTONIC. The file's counters chunk says which one was used. */
/* NFCXX_PROF_NO_TSC (the driver's Path B build of this file, scripts/nfcxx-pathb.rb) takes the monotonic clock: the Path B
 * SSA route does not model __builtin_ia32_rdtsc. */
#if (defined(__x86_64__) || defined(__i386__)) && !defined(NFCXX_PROF_NO_TSC)
#include <cpuid.h>
#define PROF_HAVE_TSC 1
#endif

static uint64_t mono_ns(void) {
  struct timespec ts;
  clock_gettime(CLOCK_MONOTONIC, &ts);
  return (uint64_t)ts.tv_sec * 1000000000u + (uint64_t)ts.tv_nsec;
}

static int g_use_tsc = 0;
#ifdef PROF_HAVE_TSC
static uint64_t g_tsc0 = 0;
#endif
static uint64_t g_mono0 = 0;
#ifdef PROF_HAVE_TSC
static double g_ns_per_tick = 1.0;
#endif

#ifdef PROF_HAVE_TSC
static int tsc_invariant(void) {
  unsigned a = 0, b = 0, c = 0, d = 0;
  if (!__get_cpuid(0x80000000u, &a, &b, &c, &d) || a < 0x80000007u) return 0;
  __get_cpuid(0x80000007u, &a, &b, &c, &d);
  return (int)((d >> 8) & 1u);
}

/* busy-waits 5 ms against the monotonic clock to measure the TSC rate */
static void calibrate_tsc(void) {
  uint64_t m0 = mono_ns(), m1, t0, t1;
  t0 = __builtin_ia32_rdtsc();
  do {
    m1 = mono_ns();
  } while (m1 - m0 < 5000000u);
  t1 = __builtin_ia32_rdtsc();
  if (t1 > t0 && m1 > m0) {
    g_ns_per_tick = (double)(m1 - m0) / (double)(t1 - t0);
    g_tsc0 = t0;
    g_use_tsc = 1;
  }
}
#endif

static void start_clock(void) {
  const char *mode = getenv("NFCXX_PROFILE_CLOCK");
  g_mono0 = mono_ns();
#ifdef PROF_HAVE_TSC
  if ((mode == NULL || strcmp(mode, "monotonic") != 0) && tsc_invariant()) calibrate_tsc();
#else
  (void)mode;
#endif
}

static uint64_t now_ns(void) {
  if (g_use_tsc) {
#ifdef PROF_HAVE_TSC
    return (uint64_t)((double)(__builtin_ia32_rdtsc() - g_tsc0) * g_ns_per_tick);
#endif
  }
  return mono_ns() - g_mono0;
}

static void write_all(const void *p, size_t n) {
  const char *c = (const char *)p;
  while (n > 0) {
    ssize_t w = write(g_fd, c, n);
    if (w < 0) {
      if (errno == EINTR) continue;
      g_enabled = 0; /* the file is unusable: stop recording rather than lose data silently */
      return;
    }
    c += w;
    n -= (size_t)w;
  }
}

/* ---- the site table ---- */

static size_t slot_start(uint32_t site, size_t cap) { return (size_t)((site * 2654435761u) & (uint32_t)(cap - 1)); }

static void table_grow(void) {
  size_t ncap = g_cap ? g_cap * 2 : 1024, i;
  name_slot *ns = (name_slot *)calloc(ncap, sizeof(name_slot));
  if (ns == NULL) return; /* keep the old table: lookups still work, new sites are not added */
  for (i = 0; i < g_cap; i++) {
    size_t j;
    if (!g_slots[i].used) continue;
    j = slot_start(g_slots[i].site, ncap);
    while (ns[j].used) j = (j + 1) & (ncap - 1);
    ns[j] = g_slots[i];
  }
  free(g_slots);
  g_slots = ns;
  g_cap = ncap;
}

/* the slot of SITE, or NULL; with CREATE, a new slot when there is none (NULL if the table cannot grow) */
static name_slot *slot_of(uint32_t site, int create) {
  size_t j;
  if (g_cap == 0) {
    if (!create) return NULL;
    table_grow();
    if (g_cap == 0) return NULL;
  }
  j = slot_start(site, g_cap);
  while (g_slots[j].used) {
    if (g_slots[j].site == site) return &g_slots[j];
    j = (j + 1) & (g_cap - 1);
  }
  if (!create) return NULL;
  if ((g_count + 1) * 2 > g_cap) {
    table_grow();
    return slot_of(site, create);
  }
  g_slots[j].used = 1;
  g_slots[j].site = site;
  g_slots[j].name = NULL;
  g_count++;
  return &g_slots[j];
}

/* the name of SITE: the symbol that contains it, or "+0x<offset>" */
static char *resolve_name(uint32_t site) {
  Dl_info info;
  char buf[32];
  uintptr_t base = (uintptr_t)__executable_start;
  if (base != 0 && dladdr((void *)(base + site), &info) && info.dli_sname != NULL) {
    return strdup(info.dli_sname);
  }
  snprintf(buf, sizeof buf, "+0x%x", (unsigned)site);
  return strdup(buf);
}

/* called with g_lock held: names every site of RECS that has no name yet */
static void name_sites(const prof_rec *recs, uint32_t n) {
  uint32_t i;
  for (i = 0; i < n; i++) {
    name_slot *s = slot_of(recs[i].site, 1);
    if (s != NULL && s->name == NULL) s->name = resolve_name(recs[i].site);
  }
}

/* ---- the per-thread allocation rows ---- */

/* The row of SITE in this thread: its own row, a new one, or the overflow row when the table has no room. */
static nfcxx_site_count *site_row(uint32_t site) {
  uint32_t j;
  nfcxx_site_count *c;
  if (tls.counts == NULL) return &tls.overflow;
  j = (site * 2654435761u) & (PROF_SITE_SLOTS - 1);
  for (;;) {
    c = &tls.counts[j];
    if (!c->used) break;
    if (c->site == site) return c;
    j = (j + 1) & (PROF_SITE_SLOTS - 1);
  }
  if (tls.nsites >= PROF_SITE_LIMIT) return &tls.overflow;
  c->used = 1;
  c->site = site;
  tls.nsites++;
  return c;
}

/* Saves the current row for the call being entered. Returns 0 when the stack cannot grow. */
static int saved_push(void) {
  if (tls.sdepth == tls.scap) {
    size_t ncap = tls.scap ? tls.scap * 2 : 64;
    nfcxx_site_count **ns = (nfcxx_site_count **)realloc(tls.saved, ncap * sizeof *ns);
    if (ns == NULL) return 0;
    tls.saved = ns;
    tls.scap = ncap;
  }
  tls.saved[tls.sdepth++] = nfcxx_alloc_cur;
  return 1;
}

static int row_used(const nfcxx_site_count *c) { return c->allocs != 0 || c->bytes != 0 || c->frees != 0; }

/* row K of this thread in the flush order, or NULL */
static const nfcxx_site_count *row_at(uint32_t k) {
  if (k == 0) return &tls.outside;
  if (k == 1) return &tls.overflow;
  return tls.counts != NULL ? &tls.counts[k - 2] : NULL;
}

static void put_row(unsigned char *p, const nfcxx_site_count *c) {
  memcpy(p, &c->site, 4);
  memcpy(p + 4, &c->allocs, 8);
  memcpy(p + 12, &c->bytes, 8);
  memcpy(p + 20, &c->frees, 8);
}

/* ---- output ---- */

static void flush_tls(void) {
  prof_chunk ch;
  if (tls.buf == NULL || tls.n == 0) return;
  ch.tid = tls.tid;
  ch.count = tls.n;
  pthread_mutex_lock(&g_lock);
  name_sites(tls.buf, tls.n);
  if (g_fd >= 0) {
    write_all(&ch, sizeof ch);
    write_all(tls.buf, (size_t)tls.n * sizeof(prof_rec));
  }
  pthread_mutex_unlock(&g_lock);
  tls.n = 0;
}

/* this thread's nonzero allocation rows as one PROF_TID_SITE_ALLOCS chunk. Only the owning thread calls it, and it
 * allocates nothing, so the rows do not change while they are written. */
static void flush_counts(void) {
  unsigned char batch[PROF_ALLOC_BATCH * PROF_ALLOC_ROW_BYTES];
  uint32_t rows = 0, k, nb = 0;
  uint32_t hdr[2];
  for (k = 0; k < PROF_ROWS; k++) {
    const nfcxx_site_count *c = row_at(k);
    if (c != NULL && row_used(c)) rows++;
  }
  if (rows == 0) return;
  pthread_mutex_lock(&g_lock);
  if (g_fd >= 0) {
    hdr[0] = PROF_TID_SITE_ALLOCS;
    hdr[1] = rows * PROF_ALLOC_ROW_BYTES;
    write_all(hdr, sizeof hdr);
    for (k = 0; k < PROF_ROWS; k++) {
      const nfcxx_site_count *c = row_at(k);
      if (c == NULL || !row_used(c)) continue;
      put_row(batch + (size_t)nb * PROF_ALLOC_ROW_BYTES, c);
      if (++nb == PROF_ALLOC_BATCH) {
        write_all(batch, sizeof batch);
        nb = 0;
      }
    }
    if (nb > 0) write_all(batch, (size_t)nb * PROF_ALLOC_ROW_BYTES);
  }
  pthread_mutex_unlock(&g_lock);
}

/* called with g_lock held: the string table as one chunk with tid 0 */
static void write_names(void) {
  prof_chunk ch;
  size_t i;
  uint32_t named = 0;
  for (i = 0; i < g_cap; i++)
    if (g_slots[i].used && g_slots[i].name != NULL) named++;
  if (g_fd < 0 || named == 0) return;
  ch.tid = 0;
  ch.count = named;
  write_all(&ch, sizeof ch);
  for (i = 0; i < g_cap; i++) {
    uint32_t hdr[2];
    size_t len;
    if (!g_slots[i].used || g_slots[i].name == NULL) continue;
    len = strlen(g_slots[i].name);
    hdr[0] = g_slots[i].site;
    hdr[1] = (uint32_t)len;
    write_all(hdr, sizeof hdr);
    write_all(g_slots[i].name, len);
  }
}

/* called with g_lock held: the allocation totals as one chunk with tid PROF_TID_COUNTERS, text "key=value" pairs */
static void write_counters(void) {
  char text[128];
  uint64_t a, b, f;
  uint32_t hdr[2];
  int n;
  if (g_fd < 0) return;
  a = b = f = 0;
  if (nfcxx_alloc_counts != NULL) nfcxx_alloc_counts(&a, &b, &f); /* weak: zero when nfcxx_alloc.c is not linked */
  n = snprintf(text, sizeof text, "allocs=%llu alloc_bytes=%llu frees=%llu clock=%s\n", (unsigned long long)a,
               (unsigned long long)b, (unsigned long long)f, g_use_tsc ? "tsc" : "monotonic");
  if (n <= 0 || (size_t)n >= sizeof text) return;
  hdr[0] = PROF_TID_COUNTERS;
  hdr[1] = (uint32_t)n;
  write_all(hdr, sizeof hdr);
  write_all(text, (size_t)n);
}

/* called with g_lock held: the machine description as one chunk with tid PROF_TID_MACHINE */
static void write_machine(void) {
  uint32_t hdr[2];
  if (g_fd < 0 || g_machine_text == NULL) return;
  hdr[0] = PROF_TID_MACHINE;
  hdr[1] = (uint32_t)g_machine_len;
  write_all(hdr, sizeof hdr);
  write_all(g_machine_text, g_machine_len);
}

static void tls_destroy(void *v) {
  (void)v;
  flush_tls();
  flush_counts();
  nfcxx_alloc_cur = NULL; /* allocations from here on count in the run's totals only */
  free(tls.counts);
  tls.counts = NULL;
  free(tls.saved);
  tls.saved = NULL;
  tls.sdepth = tls.scap = tls.lost = 0;
  free(tls.buf);
  tls.buf = NULL;
}

/* First event of a thread: allocate its buffer and its rows, take a thread id and register the destructor. */
static int tls_init(void) {
  if (tls.failed) return 0;
  tls.buf = (prof_rec *)malloc(sizeof(prof_rec) * PROF_CHUNK_RECORDS);
  if (tls.buf == NULL) {
    tls.failed = 1;
    return 0;
  }
  tls.counts = (nfcxx_site_count *)calloc(PROF_SITE_SLOTS, sizeof *tls.counts); /* NULL: calls count in the overflow row */
  tls.nsites = 0;
  memset(&tls.outside, 0, sizeof tls.outside);
  tls.outside.site = PROF_SITE_OUTSIDE;
  tls.outside.used = 1;
  memset(&tls.overflow, 0, sizeof tls.overflow);
  tls.overflow.site = PROF_SITE_OVERFLOW;
  tls.overflow.used = 1;
  tls.sdepth = tls.lost = 0;
  pthread_mutex_lock(&g_lock);
  tls.tid = g_next_tid++;
  pthread_mutex_unlock(&g_lock);
  tls.n = 0;
  if (pthread_setspecific(g_key, &tls) != 0) {
    free(tls.buf);
    tls.buf = NULL;
    free(tls.counts);
    tls.counts = NULL;
    tls.failed = 1;
    return 0;
  }
  nfcxx_alloc_cur = &tls.outside;
  return 1;
}

static void record(uint32_t site, uint32_t kind) {
  prof_rec *r;
  if (tls.buf == NULL && !tls_init()) return;
  if (tls.n == PROF_CHUNK_RECORDS) flush_tls();
  r = &tls.buf[tls.n++];
  r->site = site;
  r->kind = kind;
  r->ts_ns = now_ns();
}

void __nfcxx_prof_enter(uint32_t site) {
  if (!g_enabled) return;
  if (tls.buf == NULL && !tls_init()) return;
  if (tls.lost > 0 || !saved_push()) {
    tls.lost++;
    record(site, PROF_KIND_ENTER);
    return;
  }
  record(site, PROF_KIND_ENTER);
  nfcxx_alloc_cur = site_row(site);
}

void __nfcxx_prof_exit(uint32_t site) {
  if (!g_enabled) return;
  if (tls.buf == NULL && !tls_init()) return;
  record(site, PROF_KIND_EXIT);
  if (tls.lost > 0) tls.lost--;
  else if (tls.sdepth > 0) nfcxx_alloc_cur = tls.saved[--tls.sdepth];
}

int __nfcxx_prof_enabled(void) { return g_enabled; }

static void flush_at_exit(void) {
  flush_tls();
  flush_counts();
  pthread_mutex_lock(&g_lock);
  write_machine();
  write_counters();
  write_names();
  if (g_fd >= 0) close(g_fd);
  g_fd = -1;
  pthread_mutex_unlock(&g_lock);
  g_enabled = 0;
}

/* Runs before main when the program is linked with this file: reads NFCXX_PROFILE and starts the profile. */
__attribute__((constructor)) static void nfcxx_prof_start(void) {
  const char *path = getenv("NFCXX_PROFILE");
  prof_header h;
  if (path == NULL || *path == '\0') return;
  start_clock();
  g_fd = open(path, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0644);
  if (g_fd < 0) {
    fprintf(stderr, "nfcxx prof: cannot open %s: %s\n", path, strerror(errno));
    return;
  }
  memcpy(h.magic, "NFCPROF1", 8);
  h.version = PROF_VERSION;
  h.byte_order = PROF_BYTE_ORDER;
  write_all(&h, sizeof h);
  {
    /* the machine: quick (sysfs and cpuid only) unless NFCXX_PROFILE_BENCH is set, which adds the timed measurements */
    nfcxx_machine m;
    unsigned flags = getenv("NFCXX_PROFILE_BENCH") != NULL ? 0u : (NFCXX_MACHINE_SKIP_CLOCK | NFCXX_MACHINE_SKIP_BW);
    if (nfcxx_machine_probe_ex(&m, flags) == 0) {
      size_t need = nfcxx_machine_format(&m, NULL, 0);
      g_machine_text = (char *)malloc(need + 1);
      if (g_machine_text != NULL) {
        nfcxx_machine_format(&m, g_machine_text, need + 1);
        g_machine_len = need;
      }
    }
  }
  if (pthread_key_create(&g_key, tls_destroy) != 0) {
    close(g_fd);
    g_fd = -1;
    return;
  }
  g_enabled = 1;
  atexit(flush_at_exit);
}
