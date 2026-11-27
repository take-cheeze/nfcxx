/* Checks the database of the libc profile (tests/prof/libc.sh): prints the run's allocation totals and each site's counts,
 * and fails unless the totals include the program's own 20 allocations and libc's (FILE, its buffer, strdup copies),
 * alloc_some has exactly its 20 allocations (2000 bytes, 20 frees), main has libc's allocations, and no site is named for a
 * libc function (libc is not instrumented, so its calls belong to the site that made them).
 *
 * libc makes 11 allocations in libc.c: the FILE and its buffer, and the eight strdup copies. They are freed (2 by fclose,
 * 8 by the program), so the frees of the run are at least 20 + 10.
 *
 *   libc_check DB
 */
#include <stdio.h>
#include <string.h>
#include <sqlite3.h>

static int fail(const char *msg) {
  fprintf(stderr, "libc_check: %s\n", msg);
  return 1;
}

int main(int argc, char **argv) {
  sqlite3 *db;
  sqlite3_stmt *st = NULL;
  long long allocs, bytes, frees;
  int main_allocs = -1, alloc_some_allocs = -1, alloc_some_calls = -1, alloc_some_bytes = -1, alloc_some_frees = -1;
  int rc, rows = 0, unnamed;

  if (argc != 2) return fail("usage: libc_check DB");
  if (sqlite3_open_v2(argv[1], &db, SQLITE_OPEN_READONLY, NULL) != SQLITE_OK) return fail("cannot open the database");

  if (sqlite3_prepare_v2(db, "SELECT allocs, alloc_bytes, frees FROM runs ORDER BY run_id DESC LIMIT 1;", -1, &st, NULL) !=
      SQLITE_OK)
    return fail("no runs table");
  if (sqlite3_step(st) != SQLITE_ROW) return fail("no run");
  allocs = sqlite3_column_int64(st, 0);
  bytes = sqlite3_column_int64(st, 1);
  frees = sqlite3_column_int64(st, 2);
  sqlite3_finalize(st);
  printf("run: allocs=%lld alloc_bytes=%lld frees=%lld\n", allocs, bytes, frees);

  /* the last import is this run: its sites are the rows with the largest run_id */
  if (sqlite3_prepare_v2(db,
                         "SELECT name, calls, allocs, alloc_bytes, frees FROM sites"
                         " WHERE run_id = (SELECT MAX(run_id) FROM runs);",
                         -1, &st, NULL) != SQLITE_OK)
    return fail("no sites table");
  while ((rc = sqlite3_step(st)) == SQLITE_ROW) {
    const char *name = (const char *)sqlite3_column_text(st, 0);
    long long calls = sqlite3_column_int64(st, 1), a = sqlite3_column_int64(st, 2);
    long long b = sqlite3_column_int64(st, 3), f = sqlite3_column_int64(st, 4);
    rows++;
    printf("site %s: calls=%lld allocs=%lld alloc_bytes=%lld frees=%lld\n", name, calls, a, b, f);
    /* a static link cannot name its functions (dladdr finds no symbol), so the row is "+0x..." and is told apart by its
     * calls: main is called once, alloc_some twice */
    unnamed = strncmp(name, "+0x", 3) == 0;
    if (strcmp(name, "main") == 0 || (unnamed && calls == 1)) {
      main_allocs = (int)a;
    } else if (strcmp(name, "alloc_some") == 0 || (unnamed && calls == 2)) {
      alloc_some_calls = (int)calls;
      alloc_some_allocs = (int)a;
      alloc_some_bytes = (int)b;
      alloc_some_frees = (int)f;
    } else if (name[0] != '(' && !unnamed) {
      sqlite3_finalize(st);
      sqlite3_close(db);
      fprintf(stderr, "libc_check: unexpected site %s (libc is not instrumented)\n", name);
      return 1;
    }
  }
  sqlite3_finalize(st);
  sqlite3_close(db);
  if (rc != SQLITE_DONE) return fail("reading the sites failed");
  if (rows == 0) return fail("no sites");

  if (allocs < 20 + 11) return fail("the run's totals miss the program's 20 allocations and libc's 11");
  if (frees < 20 + 10) return fail("the run's totals miss the frees of the program and of libc's allocations");
  if (main_allocs < 11) return fail("main should count libc's 11 allocations in its own site");
  if (alloc_some_calls != 2) return fail("alloc_some should be called twice");
  if (alloc_some_allocs != 20 || alloc_some_bytes != 2000) return fail("alloc_some should have 20 allocations of 2000 bytes");
  if (alloc_some_frees != 20) return fail("alloc_some should free its 20 blocks");
  printf("PASS libc allocation counts\n");
  return 0;
}
