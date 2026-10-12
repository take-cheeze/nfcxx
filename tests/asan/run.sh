#!/usr/bin/env bash
# AddressSanitizer (nfcxx -fsanitize=address; docs/notes/asan.md, asan-plan.md). The backend is $ASAN_BACKEND (gcc, the
# default, or qbe: cproc's checks of every load and store). Path B and other sanitizers are refused.
#
#   tests/asan/cases/*.cpp  with a `// ASAN: text` line (`// ASAN-QBE: text` replaces it on qbe): the program must be killed by asan (exit 1 from the runtime's
#                           default abort_on_error=0) and the report on stderr must contain `text`;
#                           with `// CLEAN`: the program must exit 0 with no report.
#                           `// ASAN-OPTIONS: opts` sets ASAN_OPTIONS for that program (LeakSanitizer is off by default
#                           here: ptrace-restricted containers cannot run it, so leak.cpp turns it on and reports SKIP
#                           when LeakSanitizer itself says it cannot work).
#   Without -fsanitize=address the same erroneous programs must not report anything (the flag is what switches it on).
cd "$(dirname "$0")/../.."
root=$PWD; nfcxx=$root/nfcxx
B=${ASAN_BACKEND:-gcc}
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
pass=0; fail=0; skip=0
ok() { echo "ok   $1"; pass=$((pass + 1)); }
bad() { echo "FAIL $1: $2"; fail=$((fail + 1)); }

for f in tests/asan/cases/*.cpp; do
  n=$(basename "$f" .cpp)
  want=$(sed -n 's,^// ASAN: *\(.*\),\1,p' "$f" | head -1)
  # qbe may word the same error differently (its redzones are poisoned by __asan_poison_memory_region)
  [ "$B" = qbe ] && alt=$(sed -n 's,^// ASAN-QBE: *\([^ ]*\).*,\1,p' "$f" | head -1) && [ -n "$alt" ] && want=$alt
  opts=$(sed -n 's,^// ASAN-OPTIONS: *\(.*\),\1,p' "$f" | head -1)
  only=$(sed -n 's,^// ASAN-ONLY: *\([a-z]*\).*,\1,p' "$f" | head -1)
  if [ -n "$only" ] && [ "$only" != "$B" ]; then echo "SKIP $n (needs the $only backend)"; skip=$((skip + 1)); continue; fi
  if ! "$nfcxx" --backend=$B -fsanitize=address -g "$f" -o "$tmp/$n" 2>"$tmp/err"; then bad "$n" "compile: $(head -3 "$tmp/err" | tr '\n' ' ')"; continue; fi
  ASAN_OPTIONS="detect_leaks=0:${opts}" "$tmp/$n" >"$tmp/out" 2>"$tmp/rep"; rc=$?
  if [ -n "$want" ]; then
    if grep -q "LeakSanitizer has encountered a fatal error\|LeakSanitizer does not work under ptrace" "$tmp/rep"; then
      echo "SKIP $n (LeakSanitizer cannot run here)"; skip=$((skip + 1)); continue
    fi
    if [ $rc -eq 0 ]; then bad "$n" "ran to completion, asan reported nothing"
    elif ! grep -q "AddressSanitizer\|LeakSanitizer" "$tmp/rep"; then bad "$n" "exit $rc without an asan report: $(head -2 "$tmp/rep" | tr '\n' ' ')"
    elif ! grep -qF -- "$want" "$tmp/rep"; then bad "$n" "report lacks '$want': $(grep -m1 'ERROR' "$tmp/rep")"
    else ok "$n"; fi
  else
    if [ $rc -ne 0 ] || grep -q Sanitizer "$tmp/rep"; then bad "$n" "exit $rc: $(head -3 "$tmp/rep" | tr '\n' ' ')"; else ok "$n"; fi
  fi
done

# The report names the source line of the faulting access (gcc: EDG's #line directives; qbe has no line info yet, asan-plan.md 5).
if [ "$B" = gcc ]; then
  "$nfcxx" --backend=gcc -fsanitize=address -g tests/asan/cases/heap_overflow.cpp -o "$tmp/h" 2>/dev/null
  "$tmp/h" 2>"$tmp/rep" >/dev/null
  if grep -q "heap_overflow.cpp:5" "$tmp/rep"; then ok "report has the C++ source line"; else bad "report has the C++ source line" "$(grep -m3 '#[0-9]' "$tmp/rep" | tr '\n' ' ')"; fi
fi

# Same program without the flag: nothing is reported (the read is of valid-looking heap memory)
"$nfcxx" --backend=$B tests/asan/cases/heap_overflow.cpp -o "$tmp/plain" 2>/dev/null
"$tmp/plain" >/dev/null 2>"$tmp/rep"; if ! grep -q Sanitizer "$tmp/rep"; then ok "no report without the flag"; else bad "no report without the flag" "$(head -2 "$tmp/rep")"; fi

# -fno-sanitize=address after -fsanitize=address turns it off
"$nfcxx" -fsanitize=address -fno-sanitize=address --backend=$B tests/asan/cases/heap_overflow.cpp -o "$tmp/off" 2>/dev/null
"$tmp/off" >/dev/null 2>"$tmp/rep"; if ! grep -q Sanitizer "$tmp/rep"; then ok "-fno-sanitize=address"; else bad "-fno-sanitize=address" "still instrumented"; fi

# Backend selection: with no --backend the default (qbe) is instrumented too; a qbe run with --backend=qbe is the same.
# Path B and other sanitizers are refused.
if env -u NFCXX_BACKEND "$nfcxx" -fsanitize=address tests/asan/cases/heap_overflow.cpp -o "$tmp/sw" 2>/dev/null \
   && ! "$tmp/sw" >/dev/null 2>"$tmp/rep" && grep -q AddressSanitizer "$tmp/rep"; then ok "default backend is instrumented"
else bad "default backend is instrumented" "no report"; fi
if env -u NFCXX_BACKEND "$nfcxx" -fsanitize=address --backend=pathb tests/asan/cases/clean.cpp -o "$tmp/x" 2>"$tmp/err"; then bad "--backend=pathb refused" "compiled"
elif grep -q "Path B" "$tmp/err"; then ok "--backend=pathb refused"; else bad "--backend=pathb refused" "$(head -2 "$tmp/err")"; fi
if NFCXX_PATH=b "$nfcxx" -fsanitize=address tests/asan/cases/clean.cpp -o "$tmp/x" 2>"$tmp/err"; then bad "Path B refused" "compiled"
elif grep -q "Path B" "$tmp/err"; then ok "Path B refused"; else bad "Path B refused" "$(head -2 "$tmp/err")"; fi
if "$nfcxx" -fsanitize=undefined tests/asan/cases/clean.cpp -o "$tmp/x" 2>"$tmp/err"; then bad "-fsanitize=undefined refused" "compiled"
elif grep -q "not supported" "$tmp/err"; then ok "-fsanitize=undefined refused"; else bad "-fsanitize=undefined refused" "$(head -2 "$tmp/err")"; fi

# Separate compilation: instrumented objects linked by a second command
"$nfcxx" --backend=$B -fsanitize=address -c tests/asan/cases/heap_overflow.cpp -o "$tmp/g.o" 2>/dev/null \
  && "$nfcxx" --backend=$B -fsanitize=address "$tmp/g.o" -o "$tmp/g" 2>"$tmp/err" && ! "$tmp/g" >/dev/null 2>"$tmp/rep" && grep -q heap-buffer-overflow "$tmp/rep" \
  && ok "-c then link" || bad "-c then link" "$(head -3 "$tmp/err" "$tmp/rep" 2>/dev/null | tr '\n' ' ')"

# A C input compiled with the C++ sources is instrumented as well
printf 'int cget(int *p, int i) { return p[i]; }\n' > "$tmp/c.c"
printf 'extern "C" int cget(int *, int);\n#include <cstdlib>\nint main(int argc, char **) { int *a = (int *)malloc(3 * sizeof(int)); return cget(a, 3 + argc); }\n' > "$tmp/m.cpp"
"$nfcxx" --backend=$B -fsanitize=address "$tmp/m.cpp" "$tmp/c.c" -o "$tmp/cm" 2>"$tmp/err" && ! "$tmp/cm" >/dev/null 2>"$tmp/rep" && grep -q "heap-buffer-overflow" "$tmp/rep" \
  && ok "C input instrumented" || bad "C input instrumented" "$(head -3 "$tmp/err" "$tmp/rep" 2>/dev/null | tr '\n' ' ')"

echo "asan: $pass passed, $fail failed, $skip skipped"
[ $fail = 0 ]
