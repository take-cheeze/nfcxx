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
# ELF linkers take --gc-sections and -z now; Apple's ld takes -dead_strip (and has no -z now).
if [ "$(uname -s)" = Darwin ]; then wl_flags="-Wl,-dead_strip"; else wl_flags="-Wl,--gc-sections -Wl,-z,now"; fi
check "linker section GC and eager binding flags (C++ link)" \
  "$nfcxx" $wl_flags "$tmp/src/wl.cpp" "$tmp/src/a.cpp" -o "$tmp/wl_ok"
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

# 11. A quoted include resolves -I DIR before the host system directories, as GCC does. The source is outside
# DIR and includes "error.h", which /usr/include also provides (glibc). The -I copy must win: EXPECT 42, the
# same as host g++ (ifc_modules_templ.c in EDG's probe failed here when the -I came after --sys_include).
mkdir -p "$tmp/quote/inc" "$tmp/quote/src"
printf '#ifndef QUOTE_ERROR_H\n#define QUOTE_ERROR_H\ninline int quote_value(void) { return 42; }\n#endif\n' > "$tmp/quote/inc/error.h"
printf '#include "error.h"\nint main() { return quote_value(); }\n' > "$tmp/quote/src/quote_main.cpp"
g++ -I "$tmp/quote/inc" "$tmp/quote/src/quote_main.cpp" -o "$tmp/quote_gxx" && "$tmp/quote_gxx"; want=$?
[ "$want" -eq 42 ] || bad "quoted include: host g++ EXPECT 42" "got $want"
check "-I DIR wins over the host header for a quoted include" \
  "$nfcxx" -I "$tmp/quote/inc" -c "$tmp/quote/src/quote_main.cpp" -o "$tmp/quote.o"
if [ -x "$tmp/quote_gxx" ] && "$nfcxx" -I "$tmp/quote/inc" "$tmp/quote/src/quote_main.cpp" -o "$tmp/quote_nfcxx" 2>/dev/null; then
  "$tmp/quote_nfcxx"; got=$?
  [ "$got" -eq "$want" ] && ok "quoted include: nfcxx exit $got matches host g++" \
    || bad "quoted include: nfcxx matches host g++" "nfcxx $got, g++ $want"
else
  bad "quoted include: nfcxx links and runs" "compile or link failed"
fi

# 12. Intermediates: a compile and link leaves no .ii, .ti or .o in its directory; NFCXX_KEEP_INTERMEDIATES=1 keeps the
# records in the directory the driver names on stderr. The sources use a template, so the prelinker writes records.
mkdir -p "$tmp/cwd" && printf 'template <class T> T twice(T x) { return x + x; }\n' > "$tmp/cwd/common.h"
printf '#include "common.h"\nint fx(int v) { return twice(v); }\n' > "$tmp/cwd/x.cpp"
printf 'int fx(int);\nint main() { return fx(2) == 4 ? 0 : 1; }\n' > "$tmp/cwd/main.cpp"
(cd "$tmp/cwd" && "$nfcxx" -o prog x.cpp main.cpp >/dev/null 2>&1 && ./prog); got=$?
if [ "$got" -eq 0 ] && [ -z "$(ls -A "$tmp/cwd" | grep -E '\.(ii|ti|o)$')" ]; then
  ok "compile and link leave no .ii, .ti or .o in the directory"
else
  bad "compile and link leave no .ii, .ti or .o in the directory" "exit $got, $(ls -A "$tmp/cwd" | tr '\n' ' ')"
fi
keep_msg=$(cd "$tmp/cwd" && NFCXX_KEEP_INTERMEDIATES=1 "$nfcxx" -o prog2 x.cpp main.cpp 2>&1 >/dev/null | grep 'intermediates kept in' | sed 's/.*kept in \([^ ]*\).*/\1/')
if [ -n "$keep_msg" ] && [ -f "$keep_msg/x.ti" ] && [ -z "$(ls -A "$tmp/cwd" | grep -E '\.(ii|ti|o)$')" ]; then
  ok "NFCXX_KEEP_INTERMEDIATES=1 keeps the records in the named directory"
else
  bad "NFCXX_KEEP_INTERMEDIATES=1 keeps the records" "named '$keep_msg'"
fi
[ -n "$keep_msg" ] && rm -rf "$keep_msg"

# 13. -c recompile clears the records of the object it compiles. Link x.o alone (writes x.ii), compile y.o and link it
# alone (writes y.ii), recompile x.o, then link both: the stale x.ii must not make an instance assigned to two objects.
mkdir -p "$tmp/rec" && cp "$tmp/cwd/common.h" "$tmp/rec/"
printf '#include "common.h"\nint fy(int v) { return twice(v); }\n' > "$tmp/rec/y.cpp"
printf 'int fx(int);\nint main() { return fx(1) == 2 ? 0 : 1; }\n' > "$tmp/rec/mx.cpp"
printf 'int fy(int);\nint main() { return fy(2) == 4 ? 0 : 1; }\n' > "$tmp/rec/my.cpp"
cp "$tmp/cwd/x.cpp" "$tmp/cwd/main.cpp" "$tmp/rec/"
(cd "$tmp/rec" && "$nfcxx" -c x.cpp -o x.o && "$nfcxx" -o p1 x.o mx.cpp \
  && "$nfcxx" -c y.cpp -o y.o && "$nfcxx" -o p2 y.o my.cpp \
  && "$nfcxx" -c x.cpp -o x.o && "$nfcxx" -o p3 x.o y.o main.cpp) >"$tmp/rec.log" 2>&1
if [ $? -eq 0 ] && (cd "$tmp/rec" && ./p3); then
  ok "-c recompile clears the object's records (no instance assigned to two objects)"
else
  bad "-c recompile clears the object's records" "$(grep -m2 'prelinker: error' "$tmp/rec.log")"
fi

# 14. A link leaves no records beside its objects. Link x.o alone and y.o alone (each assigns twice<int> to its object),
# then link both without recompiling either: the earlier links' assignments must not make an instance assigned to two objects.
mkdir -p "$tmp/rel" && cp "$tmp/rec/common.h" "$tmp/rec/y.cpp" "$tmp/rec/x.cpp" "$tmp/rec/mx.cpp" "$tmp/rec/my.cpp" "$tmp/rel/"
printf 'int fx(int);\nint fy(int);\nint main() { return fx(2) == 4 && fy(2) == 4 ? 0 : 1; }\n' > "$tmp/rel/main.cpp"
(cd "$tmp/rel" && "$nfcxx" -c x.cpp -o x.o && "$nfcxx" -o p1 x.o mx.cpp && ./p1 \
  && "$nfcxx" -c y.cpp -o y.o && "$nfcxx" -o p2 y.o my.cpp && ./p2 \
  && "$nfcxx" -o p3 x.o y.o main.cpp && ./p3) >"$tmp/rel.log" 2>&1
if [ $? -eq 0 ]; then
  ok "link of objects that earlier links used (no recompile) has no instance assigned to two objects"
else
  bad "link of objects that earlier links used (no recompile)" "$(grep -m2 'prelinker: error' "$tmp/rel.log")"
  echo "--- test 14 log (tail of all three builds' stdout and stderr) ---"; tail -40 "$tmp/rel.log"; echo "---"
  # the twice<int> symbol in each object of the final link (nm -m on Mach-O shows weak and strong marks too)
  nm_cmd="nm"; [ "$(uname -s)" != Darwin ] || nm_cmd="nm -m"
  for o in x.o y.o; do echo "--- test 14 $o:"; (cd "$tmp/rel" && $nm_cmd "$o" 2>&1 | grep -i twice); done
  echo "--- test 14 files in $tmp/rel:"; ls -la "$tmp/rel"
fi

# 15. NFCXX_CACHE (docs/notes/cxx-driver.md): a -c compile is kept, and a later identical compile takes the copy. The template
# instance comes from the prelinker's records, so the restored .ti must come back with the object for the link to find it;
# a changed header is compiled again, and reverting it takes the first copy.
c15=$tmp/cache15; mkdir -p "$c15/o"
printf '#define BIAS 1\ntemplate <class T> T twice(T x) { return x + x; }\n' > "$c15/tpl.h"
printf '#include "tpl.h"\nint run_tpl(void) { return twice(20) + BIAS; }\n' > "$c15/tpl.cpp"
printf 'int run_tpl(void);\nint main(void) { return run_tpl() - 41; }\n' > "$c15/main.cpp"
export NFCXX_CACHE=$c15/cache
c15_entries() { ls "$c15/cache/objects" 2>/dev/null | wc -l | tr -d ' '; }
check "cache: a compile is stored" "$nfcxx" -c -I "$c15" "$c15/tpl.cpp" -o "$c15/o/tpl.o"
check "cache: a restored object links with its records" sh -c "
  rm -f '$c15/o/tpl.o' '$c15/o/tpl.ti' '$c15/o/tpl.ii' &&
  '$nfcxx' -c -I '$c15' '$c15/tpl.cpp' -o '$c15/o/tpl.o' && test -f '$c15/o/tpl.ti' &&
  env -u NFCXX_CACHE '$nfcxx' -c '$c15/main.cpp' -o '$c15/o/main.o' &&'$nfcxx' '$c15/o/main.o' '$c15/o/tpl.o' -o '$c15/prog' && '$c15/prog'"
[ "$(c15_entries)" = 1 ] && ok "cache: one entry for one compile" || bad "cache: one entry for one compile" "$(c15_entries) entries"
printf '#define BIAS 2\ntemplate <class T> T twice(T x) { return x + x; }\n' > "$c15/tpl.h"
check "cache: a changed header is compiled again" "$nfcxx" -c -I "$c15" "$c15/tpl.cpp" -o "$c15/o/tpl.o"
[ "$(c15_entries)" = 2 ] && ok "cache: changed header gives a second entry" || bad "cache: changed header gives a second entry" "$(c15_entries) entries"
printf '#define BIAS 1\ntemplate <class T> T twice(T x) { return x + x; }\n' > "$c15/tpl.h"
check "cache: reverting the header takes the first copy" "$nfcxx" -c -I "$c15" "$c15/tpl.cpp" -o "$c15/o/tpl.o"
[ "$(c15_entries)" = 2 ] && ok "cache: reverted header adds no entry" || bad "cache: reverted header adds no entry" "$(c15_entries) entries"
unset NFCXX_CACHE

echo "pass $pass fail $fail"
[ $fail -eq 0 ]
