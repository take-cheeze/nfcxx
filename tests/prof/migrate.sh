#!/usr/bin/env bash
# Tests the schema migration of tools/prof/prof2sql.c. A database written by the first layout of prof2sql (runs without
# machine and the allocation totals, sites without self_instructions and the allocation counts; the CREATE statements of
# commit 188e7da03) gets one run and two sites. The current prof2sql then opens it, adds the missing columns, keeps the old
# rows (new columns 0 or NULL), and imports a cprog profile, twice. The checks then read the database: the columns exist,
# PRAGMA user_version is 2, the old rows are unchanged, and the new rows are filled.
# PROF2SQL_SRC names another prof2sql.c to test, e.g. origin/main's, to show the failure before the change.
set -eu
cd "$(dirname "$0")/../.."
out=build/prof/migrate
mkdir -p "$out"
cc=${CC:-gcc}
src=${PROF2SQL_SRC:-tools/prof/prof2sql.c}
db=$out/old.db
$cc -std=c11 -O2 -Wall -Wextra -Werror "$src" -lsqlite3 -o "$out/prof2sql"
./nfcxx --profile tests/prof/cprog.c -o "$out/cprog" > "$out/cprog.build.log" 2>&1
NFCXX_PROFILE="$PWD/$out/cprog.prof" "$out/cprog" > /dev/null

# the old database: the first layout's CREATE statements, one run and two sites, no user_version
rm -f "$db"
python3 - "$db" <<'PY'
import sqlite3, sys
db = sqlite3.connect(sys.argv[1])
db.executescript("""
CREATE TABLE IF NOT EXISTS runs(run_id INTEGER PRIMARY KEY AUTOINCREMENT, source TEXT NOT NULL,
  imported_at TEXT NOT NULL DEFAULT (datetime('now')), format_version INTEGER NOT NULL,
  events INTEGER NOT NULL, threads INTEGER NOT NULL, open_calls INTEGER NOT NULL);
CREATE TABLE IF NOT EXISTS sites(run_id INTEGER NOT NULL REFERENCES runs(run_id), site INTEGER NOT NULL,
  name TEXT NOT NULL, calls INTEGER NOT NULL, inclusive_ns INTEGER NOT NULL, exclusive_ns INTEGER NOT NULL,
  PRIMARY KEY (run_id, site));
INSERT INTO runs(source, format_version, events, threads, open_calls) VALUES ('old.prof', 1, 5, 1, 0);
INSERT INTO sites(run_id, site, name, calls, inclusive_ns, exclusive_ns) VALUES (1, 7, 'main', 1, 100, 60), (1, 8, 'fib', 3, 40, 40);
""")
db.commit()
PY

# importing into it: the old database must be migrated first (before the change, the INSERT into runs fails)
if ! "$out/prof2sql" "$out/cprog.prof" "$db"; then
  echo "FAIL: importing a profile into the old-schema database failed"
  exit 1
fi
"$out/prof2sql" "$out/cprog.prof" "$db"

python3 - "$db" <<'PY'
import sqlite3, sys
db = sqlite3.connect(sys.argv[1])

def fail(msg):
    print("FAIL: " + msg)
    sys.exit(1)

def columns(table):
    return {row[1]: row for row in db.execute("PRAGMA table_info(%s)" % table)}

# 1. the missing columns exist, with NOT NULL DEFAULT 0 where the schema says so
for table, names in (("runs", ["machine", "allocs", "alloc_bytes", "frees"]),
                     ("sites", ["self_instructions", "allocs", "alloc_bytes", "frees"])):
    cols = columns(table)
    for name in names:
        if name not in cols:
            fail("%s has no column %s after the migration" % (table, name))
for table, name in (("runs", "allocs"), ("runs", "alloc_bytes"), ("runs", "frees"),
                    ("sites", "allocs"), ("sites", "alloc_bytes"), ("sites", "frees")):
    row = columns(table)[name]
    if row[2].upper() != "INTEGER" or row[3] != 1 or str(row[4]) != "0":
        fail("%s.%s should be INTEGER NOT NULL DEFAULT 0" % (table, name))
if columns("runs")["machine"][3] != 0 or columns("sites")["self_instructions"][3] != 0:
    fail("machine and self_instructions should allow NULL")

# 2. the schema version is recorded
version = db.execute("PRAGMA user_version").fetchone()[0]
if version != 2:
    fail("PRAGMA user_version is %d, expected 2" % version)

# 3. the old rows are unchanged, and the new columns hold 0 or NULL
old_run = db.execute("SELECT run_id, source, format_version, events, threads, open_calls, machine, allocs, alloc_bytes, frees"
                     " FROM runs WHERE run_id = 1").fetchall()
if old_run != [(1, "old.prof", 1, 5, 1, 0, None, 0, 0, 0)]:
    fail("the old run row changed or was not defaulted: %r" % (old_run,))
old_sites = db.execute("SELECT site, name, calls, inclusive_ns, exclusive_ns, self_instructions, allocs, alloc_bytes, frees"
                       " FROM sites WHERE run_id = 1 ORDER BY site").fetchall()
if old_sites != [(7, "main", 1, 100, 60, None, 0, 0, 0), (8, "fib", 3, 40, 40, None, 0, 0, 0)]:
    fail("the old site rows changed or were not defaulted: %r" % (old_sites,))

# 4. the imported runs are filled: the first import (run 2) and the second import (run 3) of the same profile
runs = db.execute("SELECT run_id, machine, allocs, alloc_bytes, frees FROM runs WHERE run_id > 1 ORDER BY run_id").fetchall()
if [r[0] for r in runs] != [2, 3]:
    fail("expected the imported runs 2 and 3, got %r" % (runs,))
for run_id, machine, allocs, nbytes, frees in runs:
    if machine is None or "cpu model" not in machine:
        fail("run %d has no machine description" % run_id)
    if allocs < 10 or nbytes <= 0 or frees < 10:
        fail("run %d has no allocation totals: allocs=%d frees=%d" % (run_id, allocs, frees))
    main = db.execute("SELECT calls, allocs, frees, self_instructions FROM sites WHERE run_id = ? AND name = 'main'",
                      (run_id,)).fetchall()
    if len(main) != 1 or main[0][0] != 1 or main[0][1] < 10 or main[0][2] != 10 or main[0][3] is not None:
        fail("run %d: main should be called once with its allocations and no self_instructions (no callgrind): %r"
             % (run_id, main))

# 5. the migration is idempotent: the version is 2 and the old row is still there
if db.execute("SELECT COUNT(*) FROM runs").fetchone()[0] != 3:
    fail("expected three runs in the database")
print("PASS tests/prof migrate")
PY
