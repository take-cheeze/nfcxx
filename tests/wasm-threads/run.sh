#!/usr/bin/env bash
# Threads for the wasm emitter (scripts/pathb-wasm-emit.rb --threads): counter.cpp is lowered to IR, emitted with a shared
# memory, and run by tests/wasm-threads/host.cjs with N worker threads (each its own instance over the one memory). The
# totals must be exact: the atomic adds lose no update. Node is needed (worker_threads).
set -u
cd "$(dirname "$0")/../.."
root=$PWD
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
node=${NODE:-node}
command -v "$node" >/dev/null 2>&1 || { echo "wasm-threads: no node" >&2; exit 2; }
N=${WASM_THREADS:-4}; ITER=${WASM_THREAD_ITER:-2000000}

scripts/pathb-dump --ir tests/wasm-threads/counter.cpp > "$tmp/counter.ir" 2> "$tmp/fe" || { echo "FAIL front end: $(head -1 "$tmp/fe")"; exit 1; }
if ! ruby "$root/scripts/pathb-wasm-emit.rb" --threads "$tmp/counter.ir" > "$tmp/counter.wasm" 2> "$tmp/emit"; then
  echo "FAIL emit: $(head -1 "$tmp/emit")"; exit 1
fi
if ! out=$("$node" "$root/tests/wasm-threads/host.cjs" "$tmp/counter.wasm" "$N" "$ITER" 2>&1); then
  echo "FAIL host: $(echo "$out" | tail -3 | tr '\n' ' ')"; exit 1
fi
echo "$out" | sed 's/^/  /'
echo "$out" | tail -1 | grep -q '^threads: ok$' && echo "ok   wasm-threads ($N workers, $ITER adds each)" || { echo "FAIL wasm-threads"; exit 1; }
