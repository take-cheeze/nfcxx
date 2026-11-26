/* nfcxx profiler runtime (docs/notes/profiler.md). Prototype format version 1, see the header comment below.
 *
 * File layout (host byte order; the byte-order marker lets a reader reject a file from another byte order):
 *   header:  char magic[8] = "NFCPROF1"; uint32 version = 1; uint32 byte_order = 0x01020304
 *   chunks:  repeated { uint32 tid; uint32 count; ... }
 *            tid != 0: count records, each { uint32 site; uint32 kind (0 enter, 1 exit); uint64 ts_ns (CLOCK_MONOTONIC) }
 *            tid == 0: the string table, written once at exit; count entries, each { uint32 site; uint32 len; char name[len] }
 *
 * A site is the offset of the function from the start of the executable image (see nfcxx_prof_cyg.c). Its name is the
 * exported symbol that contains it (dladdr), or "+0x<offset>" when there is none. A site gets its name the first time a
 * flush sees it, so a site from a thread still running at exit may have no name.
 *
 * Each thread buffers up to PROF_CHUNK_RECORDS records and writes them as one chunk. A chunk's records are in the order
 * the thread produced them, so a thread's enters and exits nest as its calls nest. Chunks of different threads may
 * interleave in the file; the tid says which thread a chunk belongs to.
 *
 * Threads: a thread's buffer is flushed when it exits (a pthread key destructor) and, for the thread that calls exit(),
 * at exit. Other threads still running when the process exits lose their unflushed records.
 */
#define _GNU_SOURCE 1
#define _POSIX_C_SOURCE 200809L

#include "nfcxx_prof.h"

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
static name_slot *g_slots = NULL;
static size_t g_cap = 0;
static size_t g_count = 0;

static uint64_t now_ns(void) {
  struct timespec ts;
  clock_gettime(CLOCK_MONOTONIC, &ts);
  return (uint64_t)ts.tv_sec * 1000000000u + (uint64_t)ts.tv_nsec;
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

static void tls_destroy(void *v) {
  (void)v;
  flush_tls();
  free(tls.buf);
  tls.buf = NULL;
}

/* First event of a thread: allocate its buffer, take a thread id and register the destructor. */
static int tls_init(void) {
  if (tls.failed) return 0;
  tls.buf = (prof_rec *)malloc(sizeof(prof_rec) * PROF_CHUNK_RECORDS);
  if (tls.buf == NULL) {
    tls.failed = 1;
    return 0;
  }
  pthread_mutex_lock(&g_lock);
  tls.tid = g_next_tid++;
  pthread_mutex_unlock(&g_lock);
  tls.n = 0;
  if (pthread_setspecific(g_key, &tls) != 0) {
    free(tls.buf);
    tls.buf = NULL;
    tls.failed = 1;
    return 0;
  }
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
  record(site, PROF_KIND_ENTER);
}

void __nfcxx_prof_exit(uint32_t site) {
  if (!g_enabled) return;
  record(site, PROF_KIND_EXIT);
}

int __nfcxx_prof_enabled(void) { return g_enabled; }

static void flush_at_exit(void) {
  flush_tls();
  pthread_mutex_lock(&g_lock);
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
  g_fd = open(path, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0644);
  if (g_fd < 0) {
    fprintf(stderr, "nfcxx prof: cannot open %s: %s\n", path, strerror(errno));
    return;
  }
  memcpy(h.magic, "NFCPROF1", 8);
  h.version = PROF_VERSION;
  h.byte_order = PROF_BYTE_ORDER;
  write_all(&h, sizeof h);
  if (pthread_key_create(&g_key, tls_destroy) != 0) {
    close(g_fd);
    g_fd = -1;
    return;
  }
  g_enabled = 1;
  atexit(flush_at_exit);
}
