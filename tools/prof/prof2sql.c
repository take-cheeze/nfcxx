/* prof2sql: imports a profile written by lib/prof (format version 1) into a SQLite database.
 *
 *   prof2sql PROFILE DB [CALLGRIND_OUT]
 *
 * Each import adds one row to `runs` and one row per site to `sites`. The per-site figures come from walking each thread's
 * calls: calls is the number of enters, inclusive_ns the time between an enter and its exit, and exclusive_ns the same time
 * less the time of the calls made inside it (self time). A call still open when the profile ends (a thread still running at
 * exit) is counted in runs.open_calls and left out of the sites.
 *
 * With CALLGRIND_OUT (a file from `valgrind --tool=callgrind --dump-instr=yes`), each site also gets self_instructions: the
 * Ir (instructions executed) of its function, without the instructions of the functions it calls. That is the compute
 * count of a C site (docs/notes/profiler.md, "Compute counts"). See cg_* below for how a site is matched to a callgrind
 * function, and tests/prof/callgrind.sh for the cross-check. Without it the column is NULL.
 *
 * Schema (docs/notes/profiler-model.md):
 *   runs(run_id, source, imported_at, format_version, events, threads, open_calls, ...)
 *   sites(run_id, site, name, calls, inclusive_ns, exclusive_ns, self_instructions), primary key (run_id, site)
 */
#define _POSIX_C_SOURCE 200809L /* getline, strdup */

#include <errno.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sqlite3.h>

#define MAX_DEPTH 65536

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
  char *name;
  int used;
  int has_self; /* self_instructions is known (a callgrind function matched the site) */
  uint64_t self_ir;
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

/* ---- callgrind: the self instructions of each site (optional third argument) ----
 *
 * The file must come from `valgrind --tool=callgrind --dump-instr=yes` (positions: instr line, events: Ir). Each function
 * of the file is keyed by its name without callgrind's recursion suffix, so fib and fib'2 (the recursive levels) are one
 * function. For each function we keep:
 *   self:  the sum of the Ir of its cost lines, leaving out the call lines (the cost on a call line is the callee's
 *          inclusive cost, not this function's own);
 *   entry: the target address of the first call to it, which is its first instruction. Callgrind writes addresses as
 *          link-time addresses of the object, so the entry is comparable with a site's offset up to a constant base.
 * A site named by its symbol matches the function of that name. A site named +0x<offset> is a static function (no
 * dynamic symbol); it matches the function whose entry is base + offset, where base is found from a site with a symbol
 * name: base = entry(that function) - site(that site). Where there is no such site, the +0x sites are left NULL.
 */
typedef struct {
  char *name;
  uint64_t self;
  uint64_t entry;
  int has_entry;
} cg_fn;

typedef struct {
  cg_fn *slots; /* open addressing by name; a slot is used when name is not NULL */
  size_t cap, count;
  char **ids;   /* callgrind's name compression: ids[k] is the function key of the name with id k, or NULL */
  size_t nids;
} cg_table;

static uint64_t hash_name(const char *s) {
  uint64_t h = 1469598103934665603u;
  while (*s) {
    h ^= (unsigned char)*s++;
    h *= 1099511628211u;
  }
  return h;
}

static void cg_grow(cg_table *t) {
  size_t ncap = t->cap ? t->cap * 2 : 1024, i;
  cg_fn *ns = (cg_fn *)calloc(ncap, sizeof(cg_fn));
  if (ns == NULL) return; /* keep the old table; cg_lookup then refuses new names */
  for (i = 0; i < t->cap; i++) {
    size_t j;
    if (t->slots[i].name == NULL) continue;
    j = hash_name(t->slots[i].name) & (ncap - 1);
    while (ns[j].name != NULL) j = (j + 1) & (ncap - 1);
    ns[j] = t->slots[i];
  }
  free(t->slots);
  t->slots = ns;
  t->cap = ncap;
}

/* the function of NAME; with CREATE, a new one when there is none (NULL if the table cannot grow) */
static cg_fn *cg_lookup(cg_table *t, const char *name, int create) {
  size_t j;
  if (create && (t->cap == 0 || (t->count + 1) * 2 > t->cap)) cg_grow(t);
  if (t->cap == 0) return NULL;
  j = hash_name(name) & (t->cap - 1);
  while (t->slots[j].name != NULL) {
    if (strcmp(t->slots[j].name, name) == 0) return &t->slots[j];
    j = (j + 1) & (t->cap - 1);
  }
  if (!create || (t->count + 1) * 2 > t->cap) return NULL;
  t->slots[j].name = strdup(name);
  if (t->slots[j].name == NULL) return NULL;
  t->count++;
  return &t->slots[j];
}

/* the function whose entry is ADDR, or NULL */
static cg_fn *cg_by_entry(cg_table *t, uint64_t addr) {
  size_t i;
  for (i = 0; i < t->cap; i++)
    if (t->slots[i].name != NULL && t->slots[i].has_entry && t->slots[i].entry == addr) return &t->slots[i];
  return NULL;
}

/* the function key of a name: the name without a trailing recursion suffix "'<digits>" (callgrind's fib'2) */
static char *cg_key(const char *name) {
  size_t n = strlen(name), i = n;
  char *k;
  while (i > 0 && name[i - 1] >= '0' && name[i - 1] <= '9') i--;
  if (i > 1 && i < n && name[i - 1] == '\'') n = i - 1;
  k = (char *)malloc(n + 1);
  if (k == NULL) return NULL;
  memcpy(k, name, n);
  k[n] = '\0';
  return k;
}

/* a name field of callgrind: "(id) name" defines the id, "(id)" refers to it. Returns the key, or NULL on a bad name. */
static const char *cg_name_ref(cg_table *t, const char *s) {
  char *end;
  unsigned long id;
  const char *name;
  if (*s != '(') return NULL;
  id = strtoul(s + 1, &end, 10);
  if (*end != ')') return NULL;
  name = end + 1;
  while (*name == ' ') name++;
  if (*name != '\0') {
    char *k;
    if (id >= t->nids) {
      size_t nn = (size_t)id + 1024, i;
      char **nids = (char **)realloc(t->ids, nn * sizeof(char *));
      if (nids == NULL) return NULL;
      for (i = t->nids; i < nn; i++) nids[i] = NULL;
      t->ids = nids;
      t->nids = nn;
    }
    k = cg_key(name);
    if (k == NULL) return NULL;
    free(t->ids[id]);
    t->ids[id] = k;
  }
  if (id >= t->nids) return NULL;
  return t->ids[id];
}

/* the address of a position field: "0x..." is absolute, "+n" and "-n" are relative to LAST, "*" is LAST */
static uint64_t cg_pos(const char *tok, uint64_t last) {
  if (tok[0] == '*') return last;
  if (tok[0] == '+' || tok[0] == '-') return (uint64_t)((int64_t)last + strtoll(tok, NULL, 10));
  if (tok[0] == '0' && (tok[1] == 'x' || tok[1] == 'X')) return strtoull(tok, NULL, 16);
  return strtoull(tok, NULL, 10);
}

static int read_callgrind(FILE *f, cg_table *t) {
  char *line = NULL;
  size_t cap = 0;
  ssize_t n;
  cg_fn *cur = NULL, *callee = NULL;
  uint64_t ipos = 0, lpos = 0;
  int skip = 0; /* the next cost line is the cost of a call, not self */
  int saw_positions = 0;
  while ((n = getline(&line, &cap, f)) != -1) {
    char *s = line;
    if (n > 0 && s[n - 1] == '\n') s[n - 1] = '\0';
    if (strncmp(s, "positions:", 10) == 0) {
      const char *want = " instr line";
      if (strcmp(s + 10, want) != 0) {
        free(line);
        return die("callgrind output needs --dump-instr=yes (positions: instr line)");
      }
      saw_positions = 1;
    } else if (strncmp(s, "events:", 7) == 0) {
      if (strncmp(s + 7, " Ir", 3) != 0 || (s[10] != '\0' && s[10] != ' ')) {
        free(line);
        return die("callgrind output must count Ir first");
      }
    } else if (strncmp(s, "fn=", 3) == 0) {
      const char *key = cg_name_ref(t, s + 3);
      cur = key ? cg_lookup(t, key, 1) : NULL;
      if (key == NULL || cur == NULL) {
        free(line);
        return die("cannot read a function name in the callgrind output");
      }
    } else if (strncmp(s, "cfn=", 4) == 0) {
      const char *key = cg_name_ref(t, s + 4);
      callee = key ? cg_lookup(t, key, 1) : NULL;
      if (key == NULL || callee == NULL) {
        free(line);
        return die("cannot read a called function name in the callgrind output");
      }
    } else if (strncmp(s, "calls=", 6) == 0) {
      char a[64], b[64];
      uint64_t target;
      if (sscanf(s + 6, "%*u %63s %63s", a, b) != 2) {
        free(line);
        return die("bad calls line in the callgrind output");
      }
      target = cg_pos(a, ipos);
      lpos = cg_pos(b, lpos);
      ipos = target;
      if (callee != NULL && !callee->has_entry) {
        callee->entry = target;
        callee->has_entry = 1;
      }
      skip = 1;
    } else if (s[0] == '*' || s[0] == '+' || s[0] == '-' || (s[0] >= '0' && s[0] <= '9')) {
      char a[64], b[64];
      unsigned long long cost;
      if (sscanf(s, "%63s %63s %llu", a, b, &cost) != 3) {
        free(line);
        return die("bad cost line in the callgrind output");
      }
      ipos = cg_pos(a, ipos);
      lpos = cg_pos(b, lpos);
      if (skip) {
        skip = 0;
      } else if (cur != NULL) {
        cur->self += cost;
      }
    }
    /* other lines (fl=, fi=, fe=, ob=, cob=, cfi=, summary:, totals:, ...) do not change the counts */
  }
  free(line);
  if (ferror(f)) return die("read error in the callgrind output");
  if (!saw_positions) return die("not a callgrind output file (no positions line)");
  return 0;
}

/* sets has_self and self_ir of each site it can match. A symbol-named site matches by name; a +0x<offset> site matches
 * by entry through the base of the first symbol-named site that has an entry in callgrind. */
static void map_callgrind(importer *im, cg_table *t) {
  uint64_t base = 0;
  int have_base = 0;
  size_t i;
  for (i = 0; i < im->sites.cap; i++) {
    const site_stat *s = &im->sites.slots[i];
    cg_fn *f;
    if (!s->used || s->name == NULL || strncmp(s->name, "+0x", 3) == 0) continue;
    f = cg_lookup(t, s->name, 0);
    if (f == NULL || !f->has_entry) continue;
    if (!have_base) {
      base = f->entry - s->site;
      have_base = 1;
    } else if (base != f->entry - s->site) {
      fprintf(stderr, "prof2sql: warning: %s disagrees with the other symbols about the base address\n", s->name);
    }
  }
  for (i = 0; i < im->sites.cap; i++) {
    site_stat *s = &im->sites.slots[i];
    cg_fn *f = NULL;
    if (!s->used) continue;
    if (s->name == NULL) continue;
    if (strncmp(s->name, "+0x", 3) == 0) {
      if (have_base) f = cg_by_entry(t, base + strtoull(s->name + 3, NULL, 16));
    } else {
      f = cg_lookup(t, s->name, 0);
    }
    if (f == NULL) {
      fprintf(stderr, "prof2sql: warning: no callgrind function for site %s; its self_instructions is NULL\n", s->name);
      continue;
    }
    s->has_self = 1;
    s->self_ir = f->self;
  }
}

static void free_callgrind(cg_table *t) {
  size_t i;
  for (i = 0; i < t->cap; i++) free(t->slots[i].name);
  free(t->slots);
  for (i = 0; i < t->nids; i++) free(t->ids[i]);
  free(t->ids);
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

/* the sites table of an older database has no self_instructions column: add it, so the importer works on it */
static int ensure_self_column(sqlite3 *db) {
  sqlite3_stmt *st = NULL;
  int have = 0;
  if (sqlite3_prepare_v2(db, "SELECT 1 FROM pragma_table_info('sites') WHERE name = 'self_instructions';", -1, &st, NULL) != SQLITE_OK)
    return 1;
  if (sqlite3_step(st) == SQLITE_ROW) have = 1;
  sqlite3_finalize(st);
  if (have) return 0;
  return exec(db, "ALTER TABLE sites ADD COLUMN self_instructions INTEGER;");
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
               " self_instructions INTEGER, PRIMARY KEY (run_id, site));") != 0)
    return 1;
  if (ensure_self_column(db) != 0) return 1;
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
                         "INSERT INTO sites(run_id, site, name, calls, inclusive_ns, exclusive_ns, self_instructions)"
                         " VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7);",
                         -1, &ins_site, NULL) != SQLITE_OK)
    goto out;
  for (i = 0; i < im->sites.cap; i++) {
    const site_stat *s = &im->sites.slots[i];
    if (!s->used) continue;
    sqlite3_reset(ins_site);
    sqlite3_bind_int64(ins_site, 1, run_id);
    sqlite3_bind_int64(ins_site, 2, (sqlite3_int64)s->site);
    sqlite3_bind_text(ins_site, 3, s->name ? s->name : "", -1, SQLITE_STATIC);
    sqlite3_bind_int64(ins_site, 4, (sqlite3_int64)s->calls);
    sqlite3_bind_int64(ins_site, 5, (sqlite3_int64)s->inclusive_ns);
    sqlite3_bind_int64(ins_site, 6, (sqlite3_int64)s->exclusive_ns);
    if (s->has_self) sqlite3_bind_int64(ins_site, 7, (sqlite3_int64)s->self_ir);
    else sqlite3_bind_null(ins_site, 7);
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
  if (argc != 3 && argc != 4) return die("usage: prof2sql PROFILE DB [CALLGRIND_OUT]");
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
  if (argc == 4) {
    cg_table cg;
    FILE *cf = fopen(argv[3], "rb");
    if (cf == NULL) {
      fprintf(stderr, "prof2sql: cannot open %s: %s\n", argv[3], strerror(errno));
      free_importer(&im);
      return 1;
    }
    memset(&cg, 0, sizeof cg);
    rc = read_callgrind(cf, &cg);
    fclose(cf);
    if (rc == 0) map_callgrind(&im, &cg);
    free_callgrind(&cg);
    if (rc != 0) {
      free_importer(&im);
      return rc;
    }
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
