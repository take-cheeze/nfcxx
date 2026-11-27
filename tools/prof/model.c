/* model: a roofline estimate per site from a profile database (docs/notes/profiler-model.md, "Models", 1).
 *
 *   model DB [RUN]
 *
 * For each site of RUN (default: the latest run) it estimates whether the site is compute- or memory-bound. These are
 * PROXIES, not measurements (no hardware counters exist here):
 *   work     = self_instructions, the instructions of the site's own code (callgrind, see prof2sql)
 *   traffic  = alloc_bytes, the bytes the site requested from the heap (a stand-in for memory traffic)
 *   peak     = the core clock in GHz x 1 instruction per cycle (the machine record's clock)
 *   bandwidth = the machine record's streaming bandwidth (GB/s)
 * With these, intensity = work / traffic (instructions per byte), balance = peak / bandwidth, and the roofline bound is
 *   attainable = min(peak, bandwidth x intensity)
 * A site is compute-bound when intensity >= balance, memory-bound otherwise. efficiency = achieved / attainable, where
 * achieved = work / exclusive_ns. Sites without self_instructions, or with no machine record, print n/a.
 *
 * The machine record must come from a run with NFCXX_PROFILE_BENCH=1 (the clock and bandwidth are measured then).
 */
#define _POSIX_C_SOURCE 200809L

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sqlite3.h>

static int fail(const char *msg) {
  fprintf(stderr, "model: %s\n", msg);
  return 1;
}

/* the first number after "label" in the machine text, or -1 when absent or zero */
static double machine_value(const char *text, const char *label) {
  const char *p = text ? strstr(text, label) : NULL;
  if (p == NULL) return -1;
  p = strchr(p, ':');
  if (p == NULL) return -1;
  {
    double v = strtod(p + 1, NULL);
    return v > 0 ? v : -1;
  }
}

int main(int argc, char **argv) {
  sqlite3 *db = NULL;
  sqlite3_stmt *st = NULL;
  sqlite3_int64 run = 0;
  const char *machine = NULL;
  char *machine_copy = NULL;
  double clock_ghz, bw_gbs, peak, balance;
  int rc;

  if (argc != 2 && argc != 3) return fail("usage: model DB [RUN]");
  if (sqlite3_open_v2(argv[1], &db, SQLITE_OPEN_READONLY, NULL) != SQLITE_OK) return fail("cannot open the database");
  if (argc == 3) {
    run = (sqlite3_int64)strtoll(argv[2], NULL, 10);
  } else {
    if (sqlite3_prepare_v2(db, "SELECT MAX(run_id) FROM runs;", -1, &st, NULL) != SQLITE_OK) return fail("no runs table");
    if (sqlite3_step(st) == SQLITE_ROW) run = sqlite3_column_int64(st, 0);
    sqlite3_finalize(st);
  }
  if (run <= 0) return fail("no run");

  if (sqlite3_prepare_v2(db, "SELECT machine FROM runs WHERE run_id = ?1;", -1, &st, NULL) != SQLITE_OK) return fail("prepare");
  sqlite3_bind_int64(st, 1, run);
  if (sqlite3_step(st) == SQLITE_ROW && sqlite3_column_text(st, 0) != NULL) {
    machine_copy = strdup((const char *)sqlite3_column_text(st, 0));
    machine = machine_copy;
  }
  sqlite3_finalize(st);
  clock_ghz = machine_value(machine, "clock");
  bw_gbs = machine_value(machine, "mem bandwidth");
  if (clock_ghz < 0 || bw_gbs < 0) {
    printf("run %lld: no clock or bandwidth in the machine record (profile with NFCXX_PROFILE_BENCH=1)\n", (long long)run);
    free(machine_copy);
    sqlite3_close(db);
    return 0;
  }
  peak = clock_ghz;           /* G instructions per second at 1 instruction per cycle */
  balance = peak / bw_gbs;    /* instructions per byte at which the two roofs meet */

  printf("run %lld: PROXY roofline (work = self instructions, traffic = allocated bytes)\n", (long long)run);
  printf("  peak %.2f G instr/s (clock x 1 IPC), bandwidth %.2f GB/s, balance %.3f instr/byte\n", peak, bw_gbs, balance);
  printf("%-20s %12s %12s %12s %12s %8s %s\n", "site", "work(Ir)", "traffic(B)", "intensity", "attainable", "eff", "bound");

  if (sqlite3_prepare_v2(db,
        "SELECT name, self_instructions, alloc_bytes, exclusive_ns FROM sites WHERE run_id = ?1 AND name NOT LIKE '(%' "
        "ORDER BY site;", -1, &st, NULL) != SQLITE_OK)
    return fail("prepare");
  sqlite3_bind_int64(st, 1, run);
  while ((rc = sqlite3_step(st)) == SQLITE_ROW) {
    const char *name = (const char *)sqlite3_column_text(st, 0);
    int ir_null = sqlite3_column_type(st, 1) == SQLITE_NULL;
    double work = (double)sqlite3_column_int64(st, 1);
    double traffic = (double)sqlite3_column_int64(st, 2);
    double excl_ns = (double)sqlite3_column_int64(st, 3);
    if (ir_null || excl_ns <= 0) {
      printf("%-20s %12s %12s %12s %12s %8s %s\n", name, ir_null ? "n/a" : "", "", "", "", "", "n/a");
      continue;
    }
    if (traffic <= 0) {
      /* no heap traffic: the site is compute-bound by this model; its attainable rate is the peak */
      double achieved = work / excl_ns;
      printf("%-20s %12.0f %12.0f %12s %12.2f %7.1f%% %s\n", name, work, traffic, "inf", peak, 100.0 * achieved / peak,
             "compute");
      continue;
    } else {
      double intensity = work / traffic;
      double mem_roof = bw_gbs * intensity;
      double attainable = intensity >= balance ? peak : mem_roof;
      double achieved = work / excl_ns;
      printf("%-20s %12.0f %12.0f %12.4f %12.2f %7.1f%% %s\n", name, work, traffic, intensity, attainable,
             100.0 * achieved / attainable, intensity >= balance ? "compute" : "memory");
    }
  }
  sqlite3_finalize(st);
  free(machine_copy);
  sqlite3_close(db);
  return rc == SQLITE_DONE ? 0 : fail("read error");
}
