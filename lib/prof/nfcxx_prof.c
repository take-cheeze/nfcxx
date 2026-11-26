/* nfcxx profiler runtime (docs/notes/profiler.md). Prototype format version 1, see the header comment below.
 *
 * File layout (host byte order; the byte-order marker lets a reader reject a file from another byte order):
 *   header:  char magic[8] = "NFCPROF1"; uint32 version = 1; uint32 byte_order = 0x01020304
 *   chunks:  repeated { uint32 tid; uint32 count; record[count] }
 *   record:  uint32 site; uint32 kind (0 enter, 1 exit); uint64 ts_ns (CLOCK_MONOTONIC)
 *
 * Each thread buffers up to PROF_CHUNK_RECORDS records and writes them as one chunk. A chunk's records are in the order
 * the thread produced them, so a thread's enters and exits alternate as its calls nest. Chunks of different threads may
 * interleave in the file; the tid says which thread a chunk belongs to.
 *
 * Threads: a thread's buffer is flushed when it exits (a pthread key destructor) and, for the thread that calls exit(),
 * at exit. Other threads still running when the process exits lose their unflushed records.
 */
#define _POSIX_C_SOURCE 200809L

#include "nfcxx_prof.h"

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

static int g_enabled = 0;
static int g_fd = -1;
static pthread_mutex_t g_lock = PTHREAD_MUTEX_INITIALIZER; /* guards g_fd writes and g_next_tid */
static pthread_key_t g_key;
static uint32_t g_next_tid = 1;
static __thread prof_tls tls;

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

static void flush_tls(void) {
  prof_chunk ch;
  if (tls.buf == NULL || tls.n == 0) return;
  ch.tid = tls.tid;
  ch.count = tls.n;
  pthread_mutex_lock(&g_lock);
  if (g_fd >= 0) {
    write_all(&ch, sizeof ch);
    write_all(tls.buf, (size_t)tls.n * sizeof(prof_rec));
  }
  pthread_mutex_unlock(&g_lock);
  tls.n = 0;
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
