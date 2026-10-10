#!/usr/bin/env bash
# Real-world check: {fmt} (MIT) at a pinned upstream release, built with nfcxx on the hosted path (not
# --freestanding). tests/realworld/fmt_main.cpp (one translation unit) formats with width/precision/fill/bases,
# named and positional arguments, format_to / format_to_n / memory_buffer, fmt::print to stdout, user-defined
# formatters, ranges, FMT_STRING / FMT_COMPILE compile-time checked formats and format errors. Whole output is
# compared byte for byte with the host g++ build of the same program. The source is cloned into build/realworld,
# not vendored.
# Two library modes, each a single translation unit:
#   header   FMT_HEADER_ONLY
#   compiled the library sources src/format.cc and src/os.cc are #included at the end of the program
#            (-DFMT_COMPILED_UNITY), so the non-header-only configuration (extern templates, explicit
#            instantiations, fmt::output_file on POSIX) is built without a second translation unit.
#   NFCXX_BACKEND=gcc|qbe   (default: gcc)
#   FMT_MODES="header compiled"   (default: both)
# Decision: {fmt} is checked on the gcc backend only. Its floating-point formatting needs `unsigned __int128`
# (dragonbox / Grisu) and `long double`, neither of which cproc/QBE has (docs/notes/realworld.md), so asking for
# qbe prints a skip with that reason. FMT_QBE=1 tries it anyway.
cd "$(dirname "$0")/../.."
root=$PWD; work=$root/build/realworld
pin=1be298e1bd68957e4cd352e1f676f00e07dcfb57   # fmtlib/fmt tag 12.2.0
src=$work/fmt
if [ ! -d "$src/.git" ]; then
  mkdir -p "$src" && git -C "$src" init -q &&
    git -C "$src" remote add origin https://github.com/fmtlib/fmt || exit 1
fi
if [ "$(git -C "$src" rev-parse -q --verify "$pin^{commit}" 2>/dev/null)" != "$pin" ]; then
  git -C "$src" fetch -q --depth 1 origin "$pin" || { echo "SKIP fmt: fetch failed"; exit 0; }
fi
git -C "$src" checkout -q "$pin" || { echo "FAIL fmt: checkout $pin failed"; exit 1; }

backends=${NFCXX_BACKEND:-gcc}
modes=${FMT_MODES:-"header compiled"}
main=$root/tests/realworld/fmt_main.cpp
fail=0; tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
host=${NFCXX_CXX:-g++}
for m in $modes; do
  defs=(); [ "$m" = compiled ] && defs=(-DFMT_COMPILED_UNITY)
  if ! "$host" -std=c++20 "${defs[@]}" -I"$src/include" -I"$src/src" "$main" -o "$tmp/host-$m" 2>"$tmp/host.err"; then
    echo "FAIL fmt $m: host $host build"; grep error "$tmp/host.err" | head -5; fail=1; continue
  fi
  TMPDIR=$tmp "$tmp/host-$m" > "$tmp/host-$m.out" 2>&1 || { echo "FAIL fmt $m: host run exit $?"; fail=1; continue; }
  for b in $backends; do
    if [ "$b" = qbe ] && [ -z "${FMT_QBE:-}" ]; then
      echo "skip qbe fmt $m: {fmt} is gcc-only (it needs unsigned __int128 and long double, which cproc/QBE cannot compile; docs/notes/realworld.md)"
      continue
    fi
    if ! out=$(NFCXX_BACKEND=$b "$root/nfcxx" "${defs[@]}" -I"$src/include" -I"$src/src" "$main" -o "$tmp/f-$b-$m" 2>&1); then
      echo "FAIL $b fmt $m (build)"; grep -E "error|undefined reference" <<<"$out" | head -5; fail=1; continue
    fi
    TMPDIR=$tmp "$tmp/f-$b-$m" > "$tmp/run-$b-$m.out" 2>&1; got=$?
    if [ $got -ne 0 ]; then echo "FAIL $b fmt $m: exit $got"; tail -3 "$tmp/run-$b-$m.out"; fail=1; continue; fi
    if cmp -s "$tmp/host-$m.out" "$tmp/run-$b-$m.out"; then
      echo "ok   $b fmt $m ($(wc -l < "$tmp/host-$m.out") lines match host $host)"
    else echo "FAIL $b fmt $m: output differs from host"; diff "$tmp/host-$m.out" "$tmp/run-$b-$m.out" | head -10; fail=1; fi
  done
done
exit $fail
