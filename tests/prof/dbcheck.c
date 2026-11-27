/* Checks the database that tools/prof/prof2sql wrote from two imports of the cprog profile (tests/prof/sqlite.sh).
 * For each run: 2 sites (main and fib), main named, main called once, fib called 177 times, no open calls, and the
 * exclusive times of all sites add up to main's inclusive time (the time of one thread's top-level calls). Without a
 * callgrind file, self_instructions is NULL for every site. callgrind.sh checks the values when one is given.
 */
#include <stdio.h>
#include <string.h>
#include <sqlite3.h>

static int fail(const char *msg) {
  fprintf(stderr, "dbcheck: %s\n", msg);
  return 1;
}

static int check_run(sqlite3 *db, sqlite3_int64 run) {
  sqlite3_stmt *st = NULL;
  long long sites = 0, fib_calls = -1, main_calls = -1, main_incl = -1, sum_excl = 0, open_calls = -1;
  int main_named = 0;

  if (sqlite3_prepare_v2(db, "SELECT name, calls, inclusive_ns, exclusive_ns FROM sites WHERE run_id = ?1;", -1, &st, NULL) != SQLITE_OK)
    return fail("prepare");
  sqlite3_bind_int64(st, 1, run);
  while (sqlite3_step(st) == SQLITE_ROW) {
    const char *name = (const char *)sqlite3_column_text(st, 0);
    long long calls = sqlite3_column_int64(st, 1);
    long long incl = sqlite3_column_int64(st, 2);
    long long excl = sqlite3_column_int64(st, 3);
    sites++;
    sum_excl += excl;
    if (strcmp(name, "main") == 0) {
      main_named = 1;
      main_calls = calls;
      main_incl = incl;
    } else {
      fib_calls = calls;
    }
  }
  sqlite3_finalize(st);

  if (sqlite3_prepare_v2(db, "SELECT open_calls FROM runs WHERE run_id = ?1;", -1, &st, NULL) != SQLITE_OK) return fail("prepare");
  sqlite3_bind_int64(st, 1, run);
  if (sqlite3_step(st) == SQLITE_ROW) open_calls = sqlite3_column_int64(st, 0);
  sqlite3_finalize(st);

  if (sqlite3_prepare_v2(db, "SELECT allocs, alloc_bytes, frees FROM runs WHERE run_id = ?1;", -1, &st, NULL) != SQLITE_OK)
    return fail("prepare");
  sqlite3_bind_int64(st, 1, run);
  if (sqlite3_step(st) == SQLITE_ROW) {
    long long allocs = sqlite3_column_int64(st, 0), bytes = sqlite3_column_int64(st, 1), frees = sqlite3_column_int64(st, 2);
    sqlite3_finalize(st);
    if (allocs < 10 || bytes < 1000 || frees < 10) return fail("allocation counts are below the program's own allocations");
  } else {
    sqlite3_finalize(st);
    return fail("no run row");
  }

  if (sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM sites WHERE run_id = ?1 AND self_instructions IS NOT NULL;", -1, &st, NULL) != SQLITE_OK)
    return fail("prepare");
  sqlite3_bind_int64(st, 1, run);
  if (sqlite3_step(st) == SQLITE_ROW && sqlite3_column_int64(st, 0) != 0) {
    sqlite3_finalize(st);
    return fail("self_instructions is set, but no callgrind file was given");
  }
  sqlite3_finalize(st);

  if (sites != 2) return fail("expected 2 sites in a run");
  if (!main_named) return fail("main is not named");
  if (main_calls != 1) return fail("main should be called once");
  if (fib_calls != 177) return fail("fib should be called 177 times");
  if (open_calls != 0) return fail("a call was left open");
  if (sum_excl != main_incl) return fail("exclusive times do not add up to main's inclusive time");
  {
    /* the machine description of the run was stored with it */
    sqlite3_stmt *m = NULL;
    int ok = 0;
    if (sqlite3_prepare_v2(db, "SELECT machine FROM runs WHERE run_id = ?1;", -1, &m, NULL) != SQLITE_OK) return fail("prepare");
    sqlite3_bind_int64(m, 1, run);
    if (sqlite3_step(m) == SQLITE_ROW) {
      const char *text = (const char *)sqlite3_column_text(m, 0);
      ok = text != NULL && strstr(text, "cpu model") != NULL && strstr(text, "page size") != NULL;
    }
    sqlite3_finalize(m);
    if (!ok) return fail("the machine description is not stored with the run");
  }
  return 0;
}

int main(int argc, char **argv) {
  sqlite3 *db = NULL;
  sqlite3_stmt *st = NULL;
  long long runs = 0;
  if (argc != 2) return fail("usage: dbcheck DB");
  if (sqlite3_open_v2(argv[1], &db, SQLITE_OPEN_READONLY, NULL) != SQLITE_OK) return fail("cannot open the database");
  if (sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM runs;", -1, &st, NULL) != SQLITE_OK) return fail("no runs table");
  if (sqlite3_step(st) == SQLITE_ROW) runs = sqlite3_column_int64(st, 0);
  sqlite3_finalize(st);
  if (runs != 2) return fail("expected two runs (two imports)");

  {
    sqlite3_int64 run;
    for (run = 1; run <= 2; run++)
      if (check_run(db, run) != 0) return 1;
  }
  sqlite3_close(db);
  printf("dbcheck: ok (2 runs)\n");
  return 0;
}
