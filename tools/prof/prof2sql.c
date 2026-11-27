/* prof2sql: imports a profile written by lib/prof (format version 1) into a SQLite database.
 *
 *   prof2sql PROFILE DB
 *
 * Each import adds one row to `runs` and one row per site to `sites`. The per-site figures come from walking each thread's
 * calls: calls is the number of enters, inclusive_ns the time between an enter and its exit, and exclusive_ns the same time
 * less the time of the calls made inside it (self time). A call still open when the profile ends (a thread still running at
 * exit) is counted in runs.open_calls and left out of the sites.
 *
 * The allocation counts of each thread (chunk tid 0xFFFFFFFC, docs/notes/profile-format.md) are added to the sites: allocs,
 * alloc_bytes and frees of the site. The sites 0xFFFFFFFF (outside: no open call) and 0xFFFFFFFE (overflow) are stored as
 * the rows "(outside)" and "(overflow)" with calls 0.
 *
 * Schema (docs/notes/profiler-model.md):
 *   runs(run_id, source, imported_at, format_version, events, threads, open_calls, machine, allocs, alloc_bytes, frees)
 *   sites(run_id, site, name, calls, inclusive_ns, exclusive_ns, allocs, alloc_bytes, frees), primary key (run_id, site)
 */
#include <errno.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sqlite3.h>

#define MAX_DEPTH 65536
#define ALLOC_ROW_BYTES 28
#define SITE_OUTSIDE 0xFFFFFFFFu
#define SITE_OVERFLOW 0xFFFFFFFEu

typedef struct {
  uint32_t site;
  uint32_t kind;
  uint64_t ts_ns;
} rec;

typedef struct {
  uint32_t tid;
  uint32_t count;
} chunk;

typedef struct {
  uint32_t site;
  uint64_t enter_ts;
  uint64_t child_ns;
} frame;

typedef struct {
  uint32_t tid;
  frame *stack;
  size_t depth;
  size_t cap;
} thread_state;

typedef struct {
  uint32_t site;
  uint64_t calls;
  uint64_t inclusive_ns;
  uint64_t exclusive_ns;
  uint64_t allocs, alloc_bytes, frees;
  char *name;
  int used;
} site_stat;

typedef struct {
  site_stat *slots;
  size_t cap;
  size_t count;
} site_table;

typedef struct {
  thread_state *threads;
  size_t nthreads, capthreads;
  site_table sites;
  uint64_t events;
  uint64_t open_calls;
  char *machine; /* the machine description of the run (the text nfcxx_machine_format wrote), or NULL */
  uint64_t allocs, alloc_bytes, frees; /* the run's allocation totals (0 when the program was not wrapped) */
} importer;

static int die(const char *msg) {
  fprintf(stderr, "prof2sql: %s\n", msg);
  return 1;
}

static size_t start_of(uint32_t site, size_t cap) { return (size_t)((site * 2654435761u) & (uint32_t)(cap - 1)); }

static void table_grow(site_table *t) {
  size_t ncap = t->cap ? t->cap * 2 : 256, i;
  site_stat *ns = (site_stat *)calloc(ncap, sizeof(site_stat));
  if (ns == NULL) return;
  for (i = 0; i < t->cap; i++) {
    size_t j;
    if (!t->slots[i].used) continue;
    j = start_of(t->slots[i].site, ncap);
    while (ns[j].used) j = (j + 1) & (ncap - 1);
    ns[j] = t->slots[i];
  }
  free(t->slots);
  t->slots = ns;
  t->cap = ncap;
}

static site_stat *site_of(site_table *t, uint32_t site) {
  size_t j;
  if (t->cap == 0 || (t->count + 1) * 2 > t->cap) table_grow(t);
  if (t->cap == 0) return NULL;
  j = start_of(site, t->cap);
  while (t->slots[j].used) {
    if (t->slots[j].site == site) return &t->slots[j];
    j = (j + 1) & (t->cap - 1);
  }
  t->slots[j].used = 1;
  t->slots[j].site = site;
  t->count++;
  return &t->slots[j];
}

static thread_state *thread_of(importer *im, uint32_t tid) {
  size_t i;
  for (i = 0; i < im->nthreads; i++)
    if (im->threads[i].tid == tid) return &im->threads[i];
  if (im->nthreads == im->capthreads) {
    size_t ncap = im->capthreads ? im->capthreads * 2 : 8;
    thread_state *nt = (thread_state *)realloc(im->threads, ncap * sizeof(thread_state));
    if (nt == NULL) return NULL;
    im->threads = nt;
    im->capthreads = ncap;
  }
  im->threads[im->nthreads].tid = tid;
  im->threads[im->nthreads].stack = NULL;
  im->threads[im->nthreads].depth = 0;
  im->threads[im->nthreads].cap = 0;
  return &im->threads[im->nthreads++];
}

/* one event of a thread: an enter pushes a frame, an exit pops it and credits the site */
static int event(importer *im, uint32_t tid, const rec *r) {
  thread_state *t = thread_of(im, tid);
  site_stat *s;
  if (t == NULL) return die("out of memory");
  if (r->kind == 0) {
    if (t->depth == t->cap) {
      size_t ncap = t->cap ? t->cap * 2 : 64;
      frame *nf;
      if (ncap > MAX_DEPTH) return die("call depth too large");
      nf = (frame *)realloc(t->stack, ncap * sizeof(frame));
      if (nf == NULL) return die("out of memory");
      t->stack = nf;
      t->cap = ncap;
    }
    t->stack[t->depth].site = r->site;
    t->stack[t->depth].enter_ts = r->ts_ns;
    t->stack[t->depth].child_ns = 0;
    t->depth++;
    return 0;
  }
  if (t->depth == 0) return die("exit without an enter");
  {
    frame *f = &t->stack[t->depth - 1];
    uint64_t dur;
    if (f->site != r->site) return die("exit does not match the open enter");
    dur = r->ts_ns >= f->enter_ts ? r->ts_ns - f->enter_ts : 0;
    s = site_of(&im->sites, r->site);
    if (s == NULL) return die("out of memory");
    s->calls++;
    s->inclusive_ns += dur;
    s->exclusive_ns += dur >= f->child_ns ? dur - f->child_ns : 0;
    t->depth--;
    if (t->depth > 0) t->stack[t->depth - 1].child_ns += dur;
  }
  return 0;
}

static int read_profile(FILE *f, importer *im, uint32_t *version) {
  char magic[8];
  uint32_t order;
  uint32_t i;
  chunk ch;
  rec *buf;
  size_t cap_names = 0, nnames = 0;
  struct {
    uint32_t site;
    char *name;
  } *names = NULL;
  if (fread(magic, 1, 8, f) != 8 || memcmp(magic, "NFCPROF1", 8) != 0) return die("not a profile (bad magic)");
  if (fread(version, sizeof *version, 1, f) != 1 || *version != 1) return die("unsupported profile version");
  if (fread(&order, sizeof order, 1, f) != 1 || order != 0x01020304u) return die("profile from another byte order");
  buf = (rec *)malloc(sizeof(rec) * 4096);
  if (buf == NULL) return die("out of memory");
  while (fread(&ch, sizeof ch, 1, f) == 1) {
    if (ch.tid == 0) {
      /* the string table: count entries of { site, len, name } */
      for (i = 0; i < ch.count; i++) {
        uint32_t hdr[2];
        char *name;
        if (fread(hdr, sizeof hdr[0], 2, f) != 2) return die("truncated string table");
        name = (char *)malloc(hdr[1] + 1);
        if (name == NULL) return die("out of memory");
        if (fread(name, 1, hdr[1], f) != hdr[1]) return die("truncated string table");
        name[hdr[1]] = '\0';
        if (nnames == cap_names) {
          size_t ncap = cap_names ? cap_names * 2 : 256;
          void *nn = realloc(names, ncap * sizeof *names);
          if (nn == NULL) return die("out of memory");
          names = nn;
          cap_names = ncap;
        }
        names[nnames].site = hdr[0];
        names[nnames].name = name;
        nnames++;
      }
      continue;
    }
    if (ch.tid == 0xFFFFFFFCu) {
      /* one thread's allocation counts by site: count bytes, ALLOC_ROW_BYTES per row (site, allocs, bytes, frees) */
      uint32_t r;
      if (ch.count % ALLOC_ROW_BYTES != 0) return die("bad allocation chunk size");
      for (r = 0; r < ch.count / ALLOC_ROW_BYTES; r++) {
        unsigned char row[ALLOC_ROW_BYTES];
        uint32_t site;
        uint64_t allocs, bytes, frees;
        site_stat *s;
        if (fread(row, 1, sizeof row, f) != sizeof row) return die("truncated allocation chunk");
        memcpy(&site, row, 4);
        memcpy(&allocs, row + 4, 8);
        memcpy(&bytes, row + 12, 8);
        memcpy(&frees, row + 20, 8);
        s = site_of(&im->sites, site);
        if (s == NULL) return die("out of memory");
        s->allocs += allocs;
        s->alloc_bytes += bytes;
        s->frees += frees;
      }
      continue;
    }
    if (ch.tid == 0xFFFFFFFEu || ch.tid == 0xFFFFFFFDu) {
      /* the machine description (0xFFFFFFFE) or the allocation counters (0xFFFFFFFD): count bytes of text */
      char *text = (char *)malloc(ch.count + 1u);
      if (text == NULL) return die("out of memory");
      if (fread(text, 1, ch.count, f) != ch.count) return die("truncated machine description");
      text[ch.count] = '\0';
      if (ch.tid == 0xFFFFFFFDu) {
        unsigned long long a = 0, b = 0, fr = 0;
        if (sscanf(text, "allocs=%llu alloc_bytes=%llu frees=%llu", &a, &b, &fr) == 3) {
          im->allocs = a;
          im->alloc_bytes = b;
          im->frees = fr;
        }
        free(text);
      } else {
        free(im->machine);
        im->machine = text;
      }
      continue;
    }
    if (ch.count == 0 || ch.count > 4096) return die("bad chunk size");
    if (fread(buf, sizeof(rec), ch.count, f) != ch.count) return die("truncated chunk");
    for (i = 0; i < ch.count; i++) {
      if (buf[i].kind > 1) return die("bad event kind");
      if (event(im, ch.tid, &buf[i]) != 0) return 1;
      im->events++;
    }
  }
  if (!feof(f)) return die("read error");
  free(buf);
  /* names: the string table comes last in the file, so they are attached after the events */
  {
    size_t k;
    for (k = 0; k < nnames; k++) {
      site_stat *s = NULL;
      size_t j;
      if (im->sites.cap == 0) continue;
      j = start_of(names[k].site, im->sites.cap);
      while (im->sites.slots[j].used) {
        if (im->sites.slots[j].site == names[k].site) {
          s = &im->sites.slots[j];
          break;
        }
        j = (j + 1) & (im->sites.cap - 1);
      }
      if (s != NULL) {
        free(s->name);
        s->name = names[k].name;
        names[k].name = NULL;
      }
    }
    for (k = 0; k < nnames; k++) free(names[k].name);
    free(names);
  }
  {
    size_t t;
    for (t = 0; t < im->nthreads; t++) im->open_calls += im->threads[t].depth;
  }
  return 0;
}

static int exec(sqlite3 *db, const char *sql) {
  char *err = NULL;
  if (sqlite3_exec(db, sql, NULL, NULL, &err) != SQLITE_OK) {
    fprintf(stderr, "prof2sql: %s\n", err ? err : "sqlite error");
    sqlite3_free(err);
    return 1;
  }
  return 0;
}

static int store(sqlite3 *db, const char *source, const importer *im, uint32_t version) {
  sqlite3_stmt *ins_run = NULL, *ins_site = NULL;
  sqlite3_int64 run_id;
  size_t i;
  int rc = 1;
  if (exec(db, "CREATE TABLE IF NOT EXISTS runs(run_id INTEGER PRIMARY KEY AUTOINCREMENT, source TEXT NOT NULL,"
               " imported_at TEXT NOT NULL DEFAULT (datetime('now')), format_version INTEGER NOT NULL,"
               " events INTEGER NOT NULL, threads INTEGER NOT NULL, open_calls INTEGER NOT NULL, machine TEXT,"
               " allocs INTEGER NOT NULL, alloc_bytes INTEGER NOT NULL, frees INTEGER NOT NULL);") != 0)
    return 1;
  if (exec(db, "CREATE TABLE IF NOT EXISTS sites(run_id INTEGER NOT NULL REFERENCES runs(run_id), site INTEGER NOT NULL,"
               " name TEXT NOT NULL, calls INTEGER NOT NULL, inclusive_ns INTEGER NOT NULL, exclusive_ns INTEGER NOT NULL,"
               " allocs INTEGER NOT NULL, alloc_bytes INTEGER NOT NULL, frees INTEGER NOT NULL,"
               " PRIMARY KEY (run_id, site));") != 0)
    return 1;
  if (exec(db, "BEGIN;") != 0) return 1;
  if (sqlite3_prepare_v2(db,
                         "INSERT INTO runs(source, format_version, events, threads, open_calls, machine, allocs, alloc_bytes, frees)"
                         " VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9);",
                         -1, &ins_run, NULL) != SQLITE_OK)
    goto out;
  sqlite3_bind_text(ins_run, 1, source, -1, SQLITE_STATIC);
  sqlite3_bind_int64(ins_run, 2, (sqlite3_int64)version);
  sqlite3_bind_int64(ins_run, 3, (sqlite3_int64)im->events);
  sqlite3_bind_int64(ins_run, 4, (sqlite3_int64)im->nthreads);
  sqlite3_bind_int64(ins_run, 5, (sqlite3_int64)im->open_calls);
  if (im->machine != NULL) sqlite3_bind_text(ins_run, 6, im->machine, -1, SQLITE_STATIC);
  else sqlite3_bind_null(ins_run, 6);
  sqlite3_bind_int64(ins_run, 7, (sqlite3_int64)im->allocs);
  sqlite3_bind_int64(ins_run, 8, (sqlite3_int64)im->alloc_bytes);
  sqlite3_bind_int64(ins_run, 9, (sqlite3_int64)im->frees);
  if (sqlite3_step(ins_run) != SQLITE_DONE) goto out;
  run_id = sqlite3_last_insert_rowid(db);
  if (sqlite3_prepare_v2(db,
                         "INSERT INTO sites(run_id, site, name, calls, inclusive_ns, exclusive_ns, allocs, alloc_bytes, frees)"
                         " VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9);",
                         -1, &ins_site, NULL) != SQLITE_OK)
    goto out;
  for (i = 0; i < im->sites.cap; i++) {
    const site_stat *s = &im->sites.slots[i];
    const char *name;
    if (!s->used) continue;
    if (s->site == SITE_OUTSIDE) name = "(outside)";
    else if (s->site == SITE_OVERFLOW) name = "(overflow)";
    else name = s->name ? s->name : "";
    sqlite3_reset(ins_site);
    sqlite3_bind_int64(ins_site, 1, run_id);
    sqlite3_bind_int64(ins_site, 2, (sqlite3_int64)s->site);
    sqlite3_bind_text(ins_site, 3, name, -1, SQLITE_STATIC);
    sqlite3_bind_int64(ins_site, 4, (sqlite3_int64)s->calls);
    sqlite3_bind_int64(ins_site, 5, (sqlite3_int64)s->inclusive_ns);
    sqlite3_bind_int64(ins_site, 6, (sqlite3_int64)s->exclusive_ns);
    sqlite3_bind_int64(ins_site, 7, (sqlite3_int64)s->allocs);
    sqlite3_bind_int64(ins_site, 8, (sqlite3_int64)s->alloc_bytes);
    sqlite3_bind_int64(ins_site, 9, (sqlite3_int64)s->frees);
    if (sqlite3_step(ins_site) != SQLITE_DONE) goto out;
  }
  rc = 0;
out:
  sqlite3_finalize(ins_run);
  sqlite3_finalize(ins_site);
  if (rc != 0) {
    fprintf(stderr, "prof2sql: %s\n", sqlite3_errmsg(db));
    exec(db, "ROLLBACK;");
    return 1;
  }
  return exec(db, "COMMIT;");
}

static void free_importer(importer *im) {
  size_t i;
  for (i = 0; i < im->nthreads; i++) free(im->threads[i].stack);
  free(im->threads);
  for (i = 0; i < im->sites.cap; i++) free(im->sites.slots[i].name);
  free(im->sites.slots);
  free(im->machine);
}

int main(int argc, char **argv) {
  FILE *f;
  sqlite3 *db = NULL;
  importer im;
  uint32_t version = 0;
  int rc;
  if (argc != 3) return die("usage: prof2sql PROFILE DB");
  f = fopen(argv[1], "rb");
  if (f == NULL) {
    fprintf(stderr, "prof2sql: cannot open %s: %s\n", argv[1], strerror(errno));
    return 1;
  }
  memset(&im, 0, sizeof im);
  rc = read_profile(f, &im, &version);
  fclose(f);
  if (rc != 0) {
    free_importer(&im);
    return rc;
  }
  if (sqlite3_open(argv[2], &db) != SQLITE_OK) {
    fprintf(stderr, "prof2sql: cannot open %s: %s\n", argv[2], sqlite3_errmsg(db));
    sqlite3_close(db);
    free_importer(&im);
    return 1;
  }
  rc = store(db, argv[1], &im, version);
  sqlite3_close(db);
  free_importer(&im);
  return rc;
}
