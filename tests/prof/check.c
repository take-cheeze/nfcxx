/* Reads a profile written by lib/prof (format version 1) and checks it for tests/prof/run.sh.
 * Expects N = 1000 enter/exit pairs at site 7 on one thread and at site 9 on two threads, and that each thread's
 * events alternate enter, exit, with timestamps that never go backwards.
 */
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define N 1000
#define MAX_TIDS 16

typedef struct {
  uint32_t site;
  uint32_t kind;
  uint64_t ts_ns;
} rec;

typedef struct {
  uint32_t tid;
  uint32_t count;
} chunk;

static int fail(const char *msg) {
  fprintf(stderr, "check: %s\n", msg);
  return 1;
}

int main(int argc, char **argv) {
  FILE *f;
  char magic[8];
  uint32_t version, order;
  uint32_t tids[MAX_TIDS];
  int ntids = 0;
  uint64_t last_ts[MAX_TIDS];
  int last_kind[MAX_TIDS]; /* -1 none, 0 enter, 1 exit */
  long enters7 = 0, exits7 = 0, enters9 = 0, exits9 = 0;
  chunk ch;
  rec *buf;
  int i, k;

  if (argc != 2) return fail("usage: check PROFILE");
  f = fopen(argv[1], "rb");
  if (f == NULL) return fail("cannot open profile");
  if (fread(magic, 1, 8, f) != 8 || memcmp(magic, "NFCPROF1", 8) != 0) return fail("bad magic");
  if (fread(&version, sizeof version, 1, f) != 1 || version != 1) return fail("bad version");
  if (fread(&order, sizeof order, 1, f) != 1 || order != 0x01020304u) return fail("bad byte order");

  buf = (rec *)malloc(sizeof(rec) * 4096);
  if (buf == NULL) return fail("out of memory");

  while (fread(&ch, sizeof ch, 1, f) == 1) {
    uint32_t j;
    int slot = -1;
    if (ch.count == 0 || ch.count > 4096) return fail("bad chunk size");
    if (fread(buf, sizeof(rec), ch.count, f) != ch.count) return fail("truncated chunk");
    for (k = 0; k < ntids; k++)
      if (tids[k] == ch.tid) slot = k;
    if (slot < 0) {
      if (ntids == MAX_TIDS) return fail("too many threads");
      slot = ntids++;
      tids[slot] = ch.tid;
      last_kind[slot] = -1;
      last_ts[slot] = 0;
    }
    for (j = 0; j < ch.count; j++) {
      rec *r = &buf[j];
      if (r->kind > 1) return fail("bad event kind");
      if (r->ts_ns < last_ts[slot]) return fail("timestamps go backwards in a thread");
      last_ts[slot] = r->ts_ns;
      if (last_kind[slot] == (int)r->kind) return fail("enter and exit do not alternate");
      last_kind[slot] = (int)r->kind;
      if (r->site == 7) {
        if (r->kind == 0) enters7++; else exits7++;
      } else if (r->site == 9) {
        if (r->kind == 0) enters9++; else exits9++;
      } else {
        return fail("unexpected site");
      }
    }
  }
  if (!feof(f)) return fail("read error");
  fclose(f);
  free(buf);

  if (enters7 != N || exits7 != N) return fail("site 7 counts are wrong");
  if (enters9 != 2 * N || exits9 != 2 * N) return fail("site 9 counts are wrong");
  if (ntids != 3) return fail("expected three threads (main and two workers)");
  for (i = 0; i < ntids; i++)
    if (last_kind[i] != 1) return fail("a thread ended inside a call");
  printf("check: ok (site 7: %ld pairs, site 9: %ld pairs over 2 threads)\n", enters7, enters9);
  return 0;
}
