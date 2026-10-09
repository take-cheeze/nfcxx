#!/usr/bin/env bash
# Real-world check: build doctest (MIT, single header) at a pinned upstream release with nfcxx on the
# hosted path (not --freestanding) and run a small driver (tests/realworld/doctest_main.cpp, whose header
# says EXPECT exit code 2). The source is cloned into build/realworld, not vendored.
#   NFCXX_BACKEND=gcc|qbe   (default: both)
# A backend failure is reported as a FAIL unless it matches a known, documented gap (xfail below).
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

backends=${NFCXX_BACKEND:-"gcc qbe"}
fail=0; tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
for b in $backends; do
  if ! out=$(NFCXX_BACKEND=$b "$root/nfcxx" -I"$src" "$root/tests/realworld/doctest_main.cpp" \
             -o "$tmp/d-$b" 2>&1); then
    # xfail: cproc rejects the GNU aligned attribute EDG emits for libstdc++'s __aligned_membuf, which
    # std::map and friends use (docs/notes/realworld.md, doctest section).
    if [ "$b" = qbe ] && grep -q "GNU attribute 'aligned' is not supported here" <<<"$out"; then
      echo "xfail qbe doctest: cproc rejects aligned attribute on libstdc++ __aligned_membuf (docs/notes/realworld.md)"
      continue
    fi
    echo "FAIL $b doctest (build)"; grep -E "error|undefined reference" <<<"$out" | head -5; fail=1; continue
  fi
  "$tmp/d-$b" > "$tmp/run-$b" 2>&1; got=$?
  if [ $got -eq 2 ]; then echo "ok   $b doctest"; else
    echo "FAIL $b doctest: want 2 got $got"; tail -5 "$tmp/run-$b"; fail=1; fi
done
exit $fail
