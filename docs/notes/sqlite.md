# SQLite build and `lib/sqlcache`

`scripts/setup-sqlite.sh` builds SQLite 3.54.1 (the amalgamation, from the sqlite.org release zip) with `nfcc`, the project's C compiler, into `build/sqlite/<backend>/libsqlite3.a` with `sqlite3.h` beside it. The default backend is qbe; `NFCXX_BACKEND=gcc` builds the gcc one. The zip and `sqlite3.c` are checked against SHA-256 pins in the script before use (the zip's published SHA3-256 matches too). `SQLITE_THREADSAFE=1` and `SQLITE_DQS=0` are the only compile options set. The script needs `unzip`.

`lib/sqlcache/sqlcache.{hpp,cpp}` is a string-keyed cache in one SQLite file: `get`, `put` (with an optional TTL), `erase`
and `prune`. The file is in WAL mode with a 5 s busy timeout. Values are bytes (BLOBs), so a value may contain NUL.
Build it with the library and the SQLite archive:

```
scripts/setup-sqlite.sh
./nfcxx app.cpp lib/sqlcache/sqlcache.cpp build/sqlite/qbe/libsqlite3.a -o app
```

`tests/sqlite/run.sh` builds `tests/sqlite/cache_test.cpp` on both backends and runs it: round trips, binary values, TTL
expiry with prune, erase, reopening the file, and a failed open.

Not covered: the driver's own compile cache (`NFCXX_CACHE`, `docs/notes/cxx-driver.md`) and `lib/eval`'s snippet cache
are still file-based. `lib/eval` documents that it needs only libc, libstdc++ and libdl, so it does not take SQLite;
the shell driver has no SQLite client. Neither is moved to `lib/sqlcache` yet.
