#!/usr/bin/env bash
# <immintrin.h> compiles through the driver: the AVX10.2 headers are skipped (see nfcxx, hosted mode).
cd "$(dirname "$0")"
root=$(cd ../.. && pwd)
out=$(mktemp -d); trap "rm -rf \"$out\"" EXIT
if NFCXX_BACKEND=gcc "$root/nfcxx" -c avx10_guard.cpp -o "$out/a.o" > "$out/log" 2>&1; then echo "avx10 guard (gcc): ok"; else cat "$out/log"; echo "avx10 guard (gcc): FAIL"; exit 1; fi
