#!/usr/bin/env bash
# Build SQLite (the amalgamation, sqlite3.c) with the project's C compiler into build/sqlite/<backend>/libsqlite3.a,
# with sqlite3.h beside it. nfcc compiles it: qbe (cproc -> QBE, the default) or gcc (NFCXX_BACKEND=gcc).
#
# The amalgamation is SQLite 3.54.1, the release zip from sqlite.org. Its published SHA3-256 is
# 92281c86e2957f9b9305890f9ac04204caa7b677cc868dc326d942689df28e30; the SHA-256 pins below are checked before use, and
# a mismatch stops the build. Move the pins together when the version changes.
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
zip_url=https://sqlite.org/2026/sqlite-amalgamation-3540100.zip
zip_sha256=0a9c8e34352dad46006aa82836d5383bff9dc6bc9ce5a60553c05aa30e6ad1f9
c_sha256=0c657666d819f261cc4007526ad57e1669de9949df7a8ea847aa284a2bf0ee52
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
  curl -fsSL "$zip_url" -o "$tmp/amalgamation.zip"
  check "$tmp/amalgamation.zip" "$zip_sha256"
  unzip -q "$tmp/amalgamation.zip" -d "$tmp"
  check "$tmp/sqlite-amalgamation-3540100/sqlite3.c" "$c_sha256"
  mv "$tmp/sqlite-amalgamation-3540100/sqlite3.c" "$tmp/sqlite-amalgamation-3540100/sqlite3.h" "$src/"
fi

# SQLITE_THREADSAFE=1: the serialized mode, safe to share one connection set across threads. SQLITE_DQS=0: a double-quoted
# word is an identifier, never a string literal (the SQL standard's reading).
rm -rf "$dest"; mkdir -p "$dest"
cp "$src/sqlite3.h" "$dest/"
NFCXX_BACKEND=$backend "$root/nfcc" -c "$src/sqlite3.c" -o "$dest/sqlite3.o" -DSQLITE_THREADSAFE=1 -DSQLITE_DQS=0
ar rcs "$dest/libsqlite3.a" "$dest/sqlite3.o"
echo "built $dest/libsqlite3.a (SQLite $(sed -n 's/^#define SQLITE_VERSION *"\(.*\)"/\1/p' "$dest/sqlite3.h"))"
