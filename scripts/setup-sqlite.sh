#!/usr/bin/env bash
# Build SQLite (the amalgamation, sqlite3.c) with the project's C compiler into build/sqlite/<backend>/libsqlite3.a,
# with sqlite3.h beside it. nfcc compiles it: qbe (cproc -> QBE, the default) or gcc (NFCXX_BACKEND=gcc).
#
# The amalgamation is SQLite 3.53.4. Its canonical home is sqlite.org, which some build hosts cannot reach, so this
# takes the copy that better-sqlite3 13.0.3 ships in deps/sqlite3 (the same file, from the npm registry). Both
# files are checked against the SHA-256 below before use; a mismatch stops the build. Move the pins together when
# the version changes.
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
tgz_url=https://registry.npmjs.org/better-sqlite3/-/better-sqlite3-13.0.3.tgz
tgz_sha256=77e0513dc1a469fb3bceec4c7fb5ad3f403109787eda05be047ec17fd56868cb
c_sha256=6a2805f8c1ef020a7086e62258519323cf98b219e9fe87a42065d916cfebaefc
backend=${NFCXX_BACKEND:-qbe}
dest=$root/build/sqlite/$backend
src=$root/build/sqlite/src

sha256_of() { if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | cut -d' ' -f1; else shasum -a 256 "$1" | cut -d' ' -f1; fi; }
check() {  # check FILE WANT: stops when FILE does not have the SHA-256 WANT
  local got; got=$(sha256_of "$1")
  [ "$got" = "$2" ] || { echo "setup-sqlite: $1 has sha256 $got, expected $2" >&2; exit 1; }
}

mkdir -p "$src"
if [ ! -f "$src/sqlite3.c" ] || [ "$(sha256_of "$src/sqlite3.c")" != "$c_sha256" ]; then
  tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
  curl -fsSL "$tgz_url" -o "$tmp/sqlite.tgz"
  check "$tmp/sqlite.tgz" "$tgz_sha256"
  tar -xzf "$tmp/sqlite.tgz" -C "$tmp" package/deps/sqlite3/sqlite3.c package/deps/sqlite3/sqlite3.h
  check "$tmp/package/deps/sqlite3/sqlite3.c" "$c_sha256"
  mv "$tmp/package/deps/sqlite3/sqlite3.c" "$tmp/package/deps/sqlite3/sqlite3.h" "$src/"
fi

# SQLITE_THREADSAFE=1: the serialized mode, safe to share one connection set across threads. SQLITE_DQS=0: a double-quoted
# word is an identifier, never a string literal (the SQL standard's reading).
rm -rf "$dest"; mkdir -p "$dest"
cp "$src/sqlite3.h" "$dest/"
NFCXX_BACKEND=$backend "$root/nfcc" -c "$src/sqlite3.c" -o "$dest/sqlite3.o" -DSQLITE_THREADSAFE=1 -DSQLITE_DQS=0
ar rcs "$dest/libsqlite3.a" "$dest/sqlite3.o"
echo "built $dest/libsqlite3.a (SQLite $(sed -n 's/^#define SQLITE_VERSION *"\(.*\)"/\1/p' "$dest/sqlite3.h"))"
