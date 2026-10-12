#!/usr/bin/env bash
# Build the Go interpreter that lib/poly (nfcpoly_go.cpp) embeds into build/poly-go/:
#   libnfcgo.so   yaegi (a Go interpreter written in Go) and the bridge of lib/poly/go, as a cgo c-shared library (~30 MB)
#   libnfcgo.h    the header cgo generated; scripts check that it declares the functions of lib/poly/go/nfcgo.h
# The host program is linked with -L build/poly-go -lnfcgo -Wl,-rpath,<that directory>. One library serves both back ends:
# it is Go code behind a plain C interface, and the C++ host (nfcxx, qbe or gcc) only calls into it.
# Needs Go (>= 1.24: weak pointers make the collector exact, from $GO, PATH or /usr/local/go/bin) and a C compiler for cgo, and the module proxy for the first build
# (yaegi is pinned in lib/poly/go/go.mod and go.sum; the module cache serves later builds offline).
#   FORCE=1   rebuild even if the library is newer than its sources
#   POLY_GO_DIR=DIR   build into DIR instead of build/poly-go (a private copy: build/ may be shared between checkouts)
# Exit status: 0 built (or up to date); 3 cannot be built here (no Go, Go too old, no C compiler, module proxy unreachable):
# tests/poly/run.sh reports that as a SKIP; 1 the build failed.
self=$(realpath "$0")
cd "$(dirname "$0")/.."
root=$PWD; work=${POLY_GO_DIR:-$root/build/poly-go}; src=$root/lib/poly/go
lib=$work/libnfcgo.so
skip() { echo "setup-poly-go: $*" >&2; exit 3; }
fresh() {
  [ -f "$lib" ] && [ -f "$work/libnfcgo.h" ] && [ "$lib" -nt "$self" ] && [ "$lib" -nt "$src/go.mod" ] && [ "$lib" -nt "$src/go.sum" ] &&
    [ -z "$(find "$src" -name '*.go' -newer "$lib" -print -quit)" ] && [ "$lib" -nt "$src/nfcgo.h" ]
}
[ -z "${FORCE:-}" ] && fresh && exit 0

gobin=${GO:-}
if [ -n "$gobin" ]; then
  command -v "$gobin" >/dev/null || skip "GO=$gobin is not an executable"
else
  gobin=$(command -v go) || gobin=
  [ -n "$gobin" ] || { [ -x /usr/local/go/bin/go ] && gobin=/usr/local/go/bin/go; }
  [ -n "$gobin" ] || skip "Go not found (install Go >= 1.24 or set GO=/path/to/go)"
fi
ver=$("$gobin" env GOVERSION 2>/dev/null | sed 's/^go//') || ver=
case $ver in
  1.2[4-9]*|1.[3-9][0-9]*|[2-9].*) ;;
  *) skip "Go >= 1.24 is needed, found '${ver:-unknown}' ($gobin)" ;;
esac
cc=${CC:-gcc}
command -v "$cc" >/dev/null || skip "no C compiler ($cc) for cgo"

mkdir -p "$work"
[ -n "${HOME:-}" ] || { export HOME=$work/home; mkdir -p "$HOME"; }   # go needs a place for its build cache
exec 9>"$work/.lock"; flock 9
[ -z "${FORCE:-}" ] && fresh && exit 0

log=$work/build.log; : > "$log"
tmp=$work/new.$$; rm -rf "$tmp"; mkdir -p "$tmp"; trap 'rm -rf "$tmp"' EXIT
# GOTOOLCHAIN=local: never download another toolchain. go.sum is committed and must match.
if ! (cd "$src" && GOTOOLCHAIN=local CGO_ENABLED=1 CC=$cc "$gobin" build -trimpath -buildmode=c-shared -o "$tmp/libnfcgo.so" .) >>"$log" 2>&1; then
  if grep -qiE 'proxy\.golang\.org|dial tcp|no such host|i/o timeout|connection refused|TLS handshake|network is unreachable|server misbehaving|Temporary failure|403 Forbidden|reading https?://' "$log"; then
    tail -5 "$log" >&2
    skip "cannot download the Go modules (yaegi): the module proxy is unreachable; build once with network access (log: $log)"
  fi
  tail -30 "$log" >&2
  echo "setup-poly-go: build failed (full log: $log)" >&2
  exit 1
fi
[ -f "$tmp/libnfcgo.h" ] || { echo "setup-poly-go: cgo produced no header" >&2; exit 1; }
# The hand-written header must declare exactly the functions the library exports.
want=$(grep -oE 'nfcgo_[a-z_]+\(' "$tmp/libnfcgo.h" | sort -u | tr '\n' ' ')
have=$(grep -E '^[a-z]' "$src/nfcgo.h" | grep -oE 'nfcgo_[a-z_]+\(' | sort -u | tr '\n' ' ')
if [ "$want" != "$have" ]; then
  echo "setup-poly-go: lib/poly/go/nfcgo.h and the cgo header disagree: cgo exports [$want], nfcgo.h declares [$have]" >&2
  exit 1
fi
mv "$tmp/libnfcgo.h" "$work/libnfcgo.h"
mv "$tmp/libnfcgo.so" "$lib"
echo "setup-poly-go: built $lib ($("$gobin" env GOVERSION), yaegi $(grep -o 'traefik/yaegi v[0-9.]*' "$src/go.mod" | cut -d' ' -f2))" >&2
