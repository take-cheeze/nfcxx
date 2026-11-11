#!/usr/bin/env bash
# Cpp2 inputs (experimental, docs/notes/cpp2.md): nfcxx translates a .cpp2 file with cppfront (build/cppfront, from
# scripts/setup-cppfront.sh) and compiles the translation through the usual pipeline. Needs that build first.
#   NFCXX_BACKEND=qbe|gcc   (default: qbe)
cd "$(dirname "$0")/../.."
root=$PWD; nfcxx=$root/nfcxx
export NFCXX_BACKEND=${NFCXX_BACKEND:-qbe}
[ -x "$root/build/cppfront" ] || { echo "FAIL: build/cppfront is missing; run scripts/setup-cppfront.sh" >&2; exit 1; }
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
pass=0; fail=0
ok() { echo "ok   $1"; pass=$((pass + 1)); }
bad() { echo "FAIL $1: $2"; fail=$((fail + 1)); }

# 1. A Cpp2 program: functions with in/inout parameters and a string local
cat > "$tmp/hello.cpp2" <<'EOF'
main: () -> int = {
    std::cout << "Hello " << name() << "\n";
}

name: () -> std::string = {
    s: std::string = "world";
    decorate(s);
    return s;
}

decorate: (inout s: std::string) = {
    s = "[" + s + "]";
}
EOF
out=$("$nfcxx" "$tmp/hello.cpp2" -o "$tmp/hello" 2>&1) && got=$("$tmp/hello") && [ "$got" = "Hello [world]" ] \
  && ok "Cpp2 hello: builds and prints" || bad "Cpp2 hello" "$(head -3 <<<"${out:-}" | tr '\n' ' ') ${got:-}"

# 2. Separate compilation: -c keeps the translation for the link (the prelinker re-reads it), then link the object
if out=$("$nfcxx" -c "$tmp/hello.cpp2" -o "$tmp/hello.o" 2>&1) && out=$("$nfcxx" "$tmp/hello.o" -o "$tmp/hello-linked" 2>&1) \
   && [ "$("$tmp/hello-linked")" = "Hello [world]" ]; then
  ok "Cpp2 -c then link"
else
  bad "Cpp2 -c then link" "$(head -3 <<<"${out:-}" | tr '\n' ' ')"
fi

# 3. A .cpp and a .cpp2 in one command: the C++ file and the translation are linked together (the .cpp2 calls a
# function declared in a header, as Cpp2 has no declaration without a body)
printf 'int add(int a, int b);\n' > "$tmp/add.h"
printf '#include "add.h"\nint add(int a, int b) { return a + b; }\n' > "$tmp/add.cpp"
cat > "$tmp/main.cpp2" <<'EOF2'
#include "add.h"
main: () -> int = {
    return add(2, 3) + add(1, 1) - 7;
}
EOF2
out=$("$nfcxx" "$tmp/main.cpp2" "$tmp/add.cpp" -o "$tmp/mixed" 2>&1); rc=$?
[ $rc = 0 ] && "$tmp/mixed"; rc=$?
[ $rc = 0 ] && ok "a .cpp2 and a .cpp in one command" || bad "a .cpp2 and a .cpp in one command" "exit $rc: $(head -3 <<<"$out" | tr '\n' ' ')"

# 4. A quoted include next to the .cpp2 file is found through its directory (the translation is elsewhere)
mkdir -p "$tmp/inc"
printf 'inline int twice(int x) { return 2 * x; }\n' > "$tmp/inc/twice.h"
cat > "$tmp/inc/prog.cpp2" <<'EOF'
#include "twice.h"
main: () -> int = {
    return twice(21) - 42;
}
EOF
out=$("$nfcxx" "$tmp/inc/prog.cpp2" -o "$tmp/inc/prog" 2>&1); rc=$?
[ $rc = 0 ] && "$tmp/inc/prog"; rc=$?
[ $rc = 0 ] && ok "quoted include relative to the .cpp2 file" || bad "quoted include relative to the .cpp2 file" "exit $rc: $(head -3 <<<"$out" | tr '\n' ' ')"

# 5. A Cpp2 syntax error fails the build, and the message names the .cpp2 file
printf 'main: () -> int = {\n    x := ;\n    return 0;\n}\n' > "$tmp/broken.cpp2"
out=$("$nfcxx" "$tmp/broken.cpp2" -o "$tmp/broken" 2>&1); rc=$?
if [ $rc != 0 ] && grep -q 'broken.cpp2' <<<"$out"; then ok "Cpp2 syntax error: fails and names the file"
else bad "Cpp2 syntax error" "exit $rc: $(head -3 <<<"$out" | tr '\n' ' ')"; fi

echo "pass $pass fail $fail"
[ $fail = 0 ]
