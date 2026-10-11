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
# -I DIR, -D NAME as separate arguments (mrustc's Makefile), with -MMD: the dependency pass must see the -I too
mkdir -p "$tmp/inc" && printf '#define SEP_N 3\n' > "$tmp/inc/sepdef.h"
printf '#include "sepdef.h"\nint sep_val(void) { return SEP_N; }\n' > "$tmp/src/sep.cpp"
check "-I DIR -MMD -MF (separate argument, dependency pass)" \
  "$nfcxx" -I "$tmp/inc" -c "$tmp/src/sep.cpp" -o "$tmp/sep.o" -MMD -MF "$tmp/sep.d"
grep -q "inc/sepdef.h" "$tmp/sep.d" 2>/dev/null && ok "-I DIR: dependency file lists the header" \
  || bad "-I DIR: dependency file lists the header" "$(cat "$tmp/sep.d" 2>/dev/null)"
check "-D NAME (separate argument)" \
  "$nfcxx" -D SEP_OVERRIDE=1 -U NOTDEFINED -c "$tmp/src/a.cpp" -o "$tmp/sep2.o"
# -Wl,* reaches the host link (order-independent options); the order-dependent ones are refused (eccp puts
# its link options before every object, so --whole-archive would apply to the wrong archive)
printf 'int add(int, int);\nint main() { return add(1, 2) == 3 ? 0 : 1; }\n' > "$tmp/src/wl.cpp"
check "-Wl,--gc-sections -Wl,-z,now (C++ link)" \
  "$nfcxx" -Wl,--gc-sections -Wl,-z,now "$tmp/src/wl.cpp" "$tmp/src/a.cpp" -o "$tmp/wl_ok"
if "$nfcxx" "$tmp/src/wl.cpp" "$tmp/src/a.cpp" -Wl,--whole-archive -o "$tmp/wl_refused" >/dev/null 2>&1; then
  bad "-Wl,--whole-archive is refused" "the link succeeded"
else
  ok "-Wl,--whole-archive is refused"
fi
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

# 6. -fPIE -pie (CMake's POSITION_INDEPENDENT_CODE on an executable): links and runs
printf 'int main() { return 3; }\n' > "$tmp/src/hi.cpp"
check "-fPIE -pie link" "$nfcxx" -fPIE -pie "$tmp/src/hi.cpp" -o "$tmp/pie"
if [ -x "$tmp/pie" ]; then "$tmp/pie"; [ $? -eq 3 ] && ok "-fPIE -pie program runs" || bad "-fPIE -pie program runs" "wrong exit"; fi

# 7. -lm after the sources: libm is found by the host linker (eccp's own -l search does not look in /usr/lib/<multiarch>)
printf '#include <cmath>\nint main() { return (int)std::sqrt(16.0); }\n' > "$tmp/src/sq.cpp"
check "-lm link" "$nfcxx" "$tmp/src/sq.cpp" -o "$tmp/sq" -lm
if [ -x "$tmp/sq" ]; then "$tmp/sq"; [ $? -eq 4 ] && ok "-lm program runs" || bad "-lm program runs" "wrong exit"; fi

# 8. -fvisibility (ng-log, lvgl and effekseer use it): accepted and ignored, as nfcc does
check "-fvisibility=hidden -fvisibility-inlines-hidden" \
  "$nfcxx" -fvisibility=hidden -fvisibility-inlines-hidden -c "$tmp/src/a.cpp" -o "$tmp/vis.o"

# 8a. -pipe (ninja's configure.py passes it): accepted and ignored
check "-pipe" "$nfcxx" -pipe -c "$tmp/src/a.cpp" -o "$tmp/pipe.o"

# 8b. -include FILE (EGL/egl.h in Effekseer): the header is found through -isystem and its macros are visible
printf '#define PRE_VALUE 42\n' > "$tmp/sys/pre.h"
printf 'int main() { return PRE_VALUE; }\n' > "$tmp/src/pre_main.cpp"
check "-include FILE" "$nfcxx" -isystem "$tmp/sys" -include pre.h "$tmp/src/pre_main.cpp" -o "$tmp/premain"
if [ -x "$tmp/premain" ]; then "$tmp/premain"; [ $? -eq 42 ] && ok "-include header is used (exit 42)" || bad "-include header is used" "wrong exit"; fi

# 9. CMake's compiler probe: a source on stdin preprocessed with -E -x c++ -
check "-E -x c++ - (stdin)" sh -c "printf 'int probe_marker;\n' | '$nfcxx' -E -x c++ - | grep -q probe_marker"

# 10. Options that would change the meaning of the code are still refused, loudly
if "$nfcxx" -fno-rtti -c "$tmp/src/a.cpp" -o "$tmp/r.o" 2>/dev/null; then
  bad "-fno-rtti refused" "compiled"
else
  ok "-fno-rtti refused"
fi

echo "pass $pass fail $fail"
[ $fail -eq 0 ]
