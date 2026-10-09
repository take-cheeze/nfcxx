#!/usr/bin/env bash
# Real-world check: build doctest (MIT, single header) at a pinned upstream release with nfcxx on the
# hosted path (not --freestanding) and run a small driver (tests/realworld/doctest_main.cpp, whose header
# says EXPECT exit code 2). The source is cloned into build/realworld, not vendored.
#   NFCXX_BACKEND=gcc|qbe   (default: gcc)
# Decision: doctest is checked on the gcc backend only. Its toString(long double) needs a type QBE cannot
# represent (docs/notes/realworld.md), so asking for qbe reports a SKIP with that reason.
cd "$(dirname "$0")/../.."
root=$PWD; work=$root/build/realworld
pin=1da23a3e8119ec5cce4f9388e91b065e20bf06f5   # doctest/doctest tag v2.4.12, 2025-04-28
src=$work/doctest
if [ ! -d "$src/.git" ]; then
  mkdir -p "$src" && git -C "$src" init -q &&
    git -C "$src" remote add origin https://github.com/doctest/doctest || exit 1
fi
if [ "$(git -C "$src" rev-parse -q --verify "$pin^{commit}" 2>/dev/null)" != "$pin" ]; then
  git -C "$src" fetch -q --depth 1 origin "$pin" || { echo "SKIP doctest: fetch failed"; exit 0; }
fi
git -C "$src" checkout -q "$pin" || { echo "FAIL doctest: checkout $pin failed"; exit 1; }

backends=${NFCXX_BACKEND:-gcc}
fail=0; tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
for b in $backends; do
  if [ "$b" = qbe ]; then
    echo "skip qbe doctest: doctest is gcc-only (it needs long double, which QBE cannot represent; docs/notes/realworld.md)"
    continue
  fi
  if ! out=$(NFCXX_BACKEND=$b "$root/nfcxx" -I"$src" "$root/tests/realworld/doctest_main.cpp" \
             -o "$tmp/d-$b" 2>&1); then
    echo "FAIL $b doctest (build)"; grep -E "error|undefined reference" <<<"$out" | head -5; fail=1; continue
  fi
  "$tmp/d-$b" > "$tmp/run-$b" 2>&1; got=$?
  if [ $got -eq 2 ]; then echo "ok   $b doctest"; else
    echo "FAIL $b doctest: want 2 got $got"; tail -5 "$tmp/run-$b"; fail=1; fi
done
exit $fail
