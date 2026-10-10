#!/usr/bin/env bash
# nfcxx as the C++ compiler of a build system: the compiler-driver options CMake, ninja and mruby's rake build pass
# (-std=gnu++NN, -pthread, -fexceptions, -W*, -isystem DIR, -MD/-MF/-MT, -E -P). See docs/notes/cxx-driver.md.
#   NFCXX_BACKEND=qbe|gcc   (default: gcc here; the option handling does not depend on the backend)
cd "$(dirname "$0")/../.."
root=$PWD; nfcxx=$root/nfcxx
export NFCXX_BACKEND=${NFCXX_BACKEND:-gcc}
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
pass=0; fail=0
ok() { echo "ok   $1"; pass=$((pass + 1)); }
bad() { echo "FAIL $1: $2"; fail=$((fail + 1)); }

mkdir -p "$tmp/sys" "$tmp/src"
printf 'inline int from_sys(void) { return 7; }\n' > "$tmp/sys/sysonly.h"
cat > "$tmp/src/main.cpp" <<'EOF'
#include <sysonly.h>
#include <cstdio>
int main() { return from_sys() + 35; }
EOF
printf 'int add(int a, int b) { return a + b; }\n' > "$tmp/src/a.cpp"

# check NAME CMD...: CMD succeeds
check() { local n=$1; shift; if out=$("$@" 2>&1); then ok "$n"; else bad "$n" "$(head -3 <<<"$out" | tr '\n' ' ')"; fi; }

# 1. CMake's compile line: C++ standard in GNU mode, warnings, pthread, exceptions, PIC, optimisation and defines
check "compile with build-system flags" \
  "$nfcxx" -std=gnu++17 -O2 -g -DNDEBUG -pthread -fPIC -fexceptions -Wall -Wextra -c "$tmp/src/a.cpp" -o "$tmp/a.o"

# 2. -isystem DIR as two arguments: the header in DIR is found
check "-isystem DIR (separate argument)" \
  "$nfcxx" -isystem "$tmp/sys" "$tmp/src/main.cpp" -o "$tmp/main"
if [ -x "$tmp/main" ]; then
  "$tmp/main"; got=$?
  [ "$got" -eq 42 ] && ok "-isystem header is used (exit 42)" || bad "-isystem header is used" "exit $got, want 42"
fi

# 3. -MD -MT -MF: a dependency file that names the object and the source
check "-MD -MT -MF writes a dependency file" \
  "$nfcxx" -c "$tmp/src/a.cpp" -o "$tmp/d.o" -MD -MT d.o -MF "$tmp/d.d"
if [ -s "$tmp/d.d" ] && grep -q "^d.o:" "$tmp/d.d" && grep -q "a.cpp" "$tmp/d.d"; then
  ok "dependency file content"
else
  bad "dependency file content" "$(cat "$tmp/d.d" 2>/dev/null)"
fi

# 4. -E -P: preprocess only, to a file (mruby's presym step does this with the C++ compiler)
check "-E -P preprocesses to -o" "$nfcxx" -E -P "$tmp/src/a.cpp" -o "$tmp/a.pi"
grep -q "int add(int a, int b)" "$tmp/a.pi" 2>/dev/null && ok "-E output has the source" || bad "-E output has the source" "$(head -2 "$tmp/a.pi" 2>/dev/null)"

# 5. -pthread at link time: the program links and runs
printf '#include <thread>\nint main() { int x = 0; std::thread t([&] { x = 1; }); t.join(); return x; }\n' > "$tmp/src/thr.cpp"
check "-pthread link" "$nfcxx" -pthread "$tmp/src/thr.cpp" -o "$tmp/thr"
if [ -x "$tmp/thr" ]; then "$tmp/thr"; [ $? -eq 1 ] && ok "-pthread program runs" || bad "-pthread program runs" "wrong exit"; fi

# 6. Options that would change the meaning of the code are still refused, loudly
if "$nfcxx" -fno-rtti -c "$tmp/src/a.cpp" -o "$tmp/r.o" 2>/dev/null; then
  bad "-fno-rtti refused" "compiled"
else
  ok "-fno-rtti refused"
fi

echo "pass $pass fail $fail"
[ $fail -eq 0 ]
