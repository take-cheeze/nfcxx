/* Checks a profile of any program (tests/prof/run.sh, the --profile case): the header, that each thread's enters and exits
 * alternate with timestamps that do not go backwards, and that every thread ends outside a call. Prints the number of
 * sites, of enter/exit pairs and of threads, for the test to compare.
 */
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define MAX_TIDS 64
#define MAX_SITES 4096

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
  fprintf(stderr, "check_any: %s\n", msg);
  return 1;
}

int main(int argc, char **argv) {
  FILE *f;
  char magic[8];
  uint32_t version, order, sites[MAX_SITES];
  uint32_t tids[MAX_TIDS];
  int ntids = 0, nsites = 0, k, i;
  uint64_t last_ts[MAX_TIDS];
  long depth[MAX_TIDS];
  long enters = 0, exits = 0, names = 0;
  const char *want;
  int found = 0;
  chunk ch;
  rec *buf;

  if (argc != 2 && argc != 3) return fail("usage: check_any PROFILE [NAME]");
  want = argc == 3 ? argv[2] : NULL;
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
    if (ch.tid == 0) { /* the string table: count entries of { site, len, name } */
      uint32_t e;
      for (e = 0; e < ch.count; e++) {
        uint32_t hdr[2];
        char *name;
        if (fread(hdr, sizeof hdr[0], 2, f) != 2) return fail("truncated name table");
        name = (char *)malloc(hdr[1] + 1);
        if (name == NULL) return fail("out of memory");
        if (fread(name, 1, hdr[1], f) != hdr[1]) return fail("truncated name table");
        name[hdr[1]] = '\0';
        names++;
        if (want != NULL && strcmp(name, want) == 0) found = 1;
        free(name);
      }
      continue;
    }
    if (ch.tid == 0xFFFFFFFEu || ch.tid == 0xFFFFFFFDu) { /* the machine description or the counters: count bytes of text */
      if (fseek(f, (long)ch.count, SEEK_CUR) != 0) return fail("truncated machine description");
      continue;
    }
    if (ch.count == 0 || ch.count > 4096) return fail("bad chunk size");
    if (fread(buf, sizeof(rec), ch.count, f) != ch.count) return fail("truncated chunk");
    for (k = 0; k < ntids; k++)
      if (tids[k] == ch.tid) slot = k;
    if (slot < 0) {
      if (ntids == MAX_TIDS) return fail("too many threads");
      slot = ntids++;
      tids[slot] = ch.tid;
      last_ts[slot] = 0;
      depth[slot] = 0;
    }
    for (j = 0; j < ch.count; j++) {
      rec *r = &buf[j];
      int seen = 0;
      if (r->kind > 1) return fail("bad event kind");
      if (r->ts_ns < last_ts[slot]) return fail("timestamps go backwards in a thread");
      last_ts[slot] = r->ts_ns;
      /* nested calls give runs of enters, so the check is balance: the depth never goes below zero */
      if (r->kind == 0) depth[slot]++;
      else if (depth[slot]-- == 0) return fail("exit without a matching enter");
      for (k = 0; k < nsites; k++)
        if (sites[k] == r->site) seen = 1;
      if (!seen) {
        if (nsites == MAX_SITES) return fail("too many sites");
        sites[nsites++] = r->site;
      }
      if (r->kind == 0) enters++; else exits++;
    }
  }
  if (!feof(f)) return fail("read error");
  fclose(f);
  free(buf);
  if (enters != exits) return fail("enters and exits differ");
  for (i = 0; i < ntids; i++)
    if (depth[i] != 0) return fail("a thread ended inside a call");
  if (want != NULL && !found) return fail("the name is not in the name table");
  printf("sites=%d pairs=%ld threads=%d names=%ld\n", nsites, enters, ntids, names);
  return 0;
}
