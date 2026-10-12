#!/usr/bin/env bash
# AddressSanitizer (nfcxx -fsanitize=address; docs/notes/asan.md). The instrumentation is gcc's, so these programs run on
# the gcc backend; the qbe default must switch to it, and Path B / an explicit qbe backend must refuse.
#
#   tests/asan/cases/*.cpp  with a `// ASAN: text` line: the program must be killed by asan (exit 1 from the runtime's
#                           default abort_on_error=0) and the report on stderr must contain `text`;
#                           with `// CLEAN`: the program must exit 0 with no report.
#                           `// ASAN-OPTIONS: opts` sets ASAN_OPTIONS for that program (LeakSanitizer is off by default
#                           here: ptrace-restricted containers cannot run it, so leak.cpp turns it on and reports SKIP
#                           when LeakSanitizer itself says it cannot work).
#   Without -fsanitize=address the same erroneous programs must not report anything (the flag is what switches it on).
cd "$(dirname "$0")/../.."
root=$PWD; nfcxx=$root/nfcxx
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
pass=0; fail=0; skip=0
ok() { echo "ok   $1"; pass=$((pass + 1)); }
bad() { echo "FAIL $1: $2"; fail=$((fail + 1)); }

for f in tests/asan/cases/*.cpp; do
  n=$(basename "$f" .cpp)
  want=$(sed -n 's,^// ASAN: *\(.*\),\1,p' "$f" | head -1)
  opts=$(sed -n 's,^// ASAN-OPTIONS: *\(.*\),\1,p' "$f" | head -1)
  if ! "$nfcxx" -fsanitize=address -g "$f" -o "$tmp/$n" 2>"$tmp/err"; then bad "$n" "compile: $(head -3 "$tmp/err" | tr '\n' ' ')"; continue; fi
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

# The report names the source line of the faulting access (the -g line tables survive the C round trip? EDG emits #line).
"$nfcxx" -fsanitize=address -g tests/asan/cases/heap_overflow.cpp -o "$tmp/h" 2>/dev/null
"$tmp/h" 2>"$tmp/rep" >/dev/null
if grep -q "heap_overflow.cpp:5" "$tmp/rep"; then ok "report has the C++ source line"; else bad "report has the C++ source line" "$(grep -m3 '#[0-9]' "$tmp/rep" | tr '\n' ' ')"; fi

# Same program without the flag: nothing is reported (the read is of valid-looking heap memory)
"$nfcxx" --backend=gcc tests/asan/cases/heap_overflow.cpp -o "$tmp/plain" 2>/dev/null
"$tmp/plain" >/dev/null 2>"$tmp/rep"; if ! grep -q Sanitizer "$tmp/rep"; then ok "no report without the flag"; else bad "no report without the flag" "$(head -2 "$tmp/rep")"; fi

# -fno-sanitize=address after -fsanitize=address turns it off
"$nfcxx" -fsanitize=address -fno-sanitize=address --backend=gcc tests/asan/cases/heap_overflow.cpp -o "$tmp/off" 2>/dev/null
"$tmp/off" >/dev/null 2>"$tmp/rep"; if ! grep -q Sanitizer "$tmp/rep"; then ok "-fno-sanitize=address"; else bad "-fno-sanitize=address" "still instrumented"; fi

# Backend selection: the default (qbe) becomes gcc; an explicit qbe, Path B and other sanitizers are refused.
for b in default; do
  env -u NFCXX_BACKEND "$nfcxx" -fsanitize=address tests/asan/cases/heap_overflow.cpp -o "$tmp/sw" 2>/dev/null \
    && ! "$tmp/sw" >/dev/null 2>"$tmp/rep" && grep -q AddressSanitizer "$tmp/rep" && ok "default backend switches to gcc" || bad "default backend switches to gcc" "no report"
done
if env -u NFCXX_BACKEND "$nfcxx" -fsanitize=address --backend=qbe tests/asan/cases/clean.cpp -o "$tmp/x" 2>"$tmp/err"; then bad "explicit --backend=qbe refused" "compiled"
elif grep -q "needs --backend=gcc" "$tmp/err"; then ok "explicit --backend=qbe refused"; else bad "explicit --backend=qbe refused" "$(head -2 "$tmp/err")"; fi
if NFCXX_PATH=b "$nfcxx" -fsanitize=address tests/asan/cases/clean.cpp -o "$tmp/x" 2>"$tmp/err"; then bad "Path B refused" "compiled"
elif grep -q "Path B" "$tmp/err"; then ok "Path B refused"; else bad "Path B refused" "$(head -2 "$tmp/err")"; fi
if "$nfcxx" -fsanitize=undefined tests/asan/cases/clean.cpp -o "$tmp/x" 2>"$tmp/err"; then bad "-fsanitize=undefined refused" "compiled"
elif grep -q "not supported" "$tmp/err"; then ok "-fsanitize=undefined refused"; else bad "-fsanitize=undefined refused" "$(head -2 "$tmp/err")"; fi

# Separate compilation: instrumented objects linked by a second command
"$nfcxx" -fsanitize=address -c tests/asan/cases/global_overflow.cpp -o "$tmp/g.o" 2>/dev/null \
  && "$nfcxx" -fsanitize=address "$tmp/g.o" -o "$tmp/g" 2>"$tmp/err" && ! "$tmp/g" >/dev/null 2>"$tmp/rep" && grep -q global-buffer-overflow "$tmp/rep" \
  && ok "-c then link" || bad "-c then link" "$(head -3 "$tmp/err" "$tmp/rep" 2>/dev/null | tr '\n' ' ')"

# A C input compiled with the C++ sources is instrumented as well
printf 'int cget(int *p, int i) { return p[i]; }\n' > "$tmp/c.c"
printf 'extern "C" int cget(int *, int);\nint main(int argc, char **) { int a[3] = {1,2,3}; return cget(a, 3 + argc); }\n' > "$tmp/m.cpp"
"$nfcxx" -fsanitize=address "$tmp/m.cpp" "$tmp/c.c" -o "$tmp/cm" 2>"$tmp/err" && ! "$tmp/cm" >/dev/null 2>"$tmp/rep" && grep -q "stack-buffer-overflow" "$tmp/rep" \
  && ok "C input instrumented" || bad "C input instrumented" "$(head -3 "$tmp/err" "$tmp/rep" 2>/dev/null | tr '\n' ' ')"

echo "asan: $pass passed, $fail failed, $skip skipped"
[ $fail = 0 ]
