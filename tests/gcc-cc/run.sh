#!/bin/bash
# scripts/gcc-cc.rb (the Ruby port) must compile what scripts/gcc-cc (the bash original, tests/gcc-cc/oracle.sh) compiles:
# for each case, the same exit status, and the same symbols (nm) and disassembly (objdump) of the object. The sandbox
# has the oracle as scripts/gcc-cc, with the repository's weak-symbols, sret.sh and the same sources. The object's file
# name is not compared (the temporary directories differ); NFCXX_CCACHE=0 so that ccache is out of both runs.
#   bash tests/gcc-cc/run.sh
repo=$(cd "$(dirname "$0")/../.." && pwd)
work=$(mktemp -d); trap 'rm -rf "$work"' EXIT
pass=0; fail=0

mk() {  # mk DIR: the sources of the cases in DIR
  local d=$1; mkdir -p "$d"
  cat > "$d/plain.c" <<'SRC'
int f(int x) { return x * 3 + 1; }
SRC
  cat > "$d/pragma.c" <<'SRC'
int g(int *p, int n) {
#pragma GCC unroll 4
  for (int i = 0; i < n; i++) p[i] += i;
  return n;
}
SRC
  cat > "$d/dtor.c" <<'SRC'
extern __inline__ __attribute__((visibility("default"))) void _ZN3fooD1Ev(void) { }
int h(void) { return 2; }
SRC
  cat > "$d/comdat.c" <<'SRC'
__attribute__((__weak__)) /* COMDAT group: k */ int k(int x) { return x + 5; }
int m(void) { return k(1); }
SRC
  cat > "$d/tls.c" <<'SRC'
static __thread int tv;
int t(void) { return tv; }
SRC
  cat > "$d/bad.c" <<'SRC'
int broken( {
SRC
  echo 'int other(void) { return 9; }' > "$d/other.c"
  cc -c -o "$d/other.o" "$d/other.c"
}

# one case: NAME, then the arguments (run in the case's directory)
cases=(
  "plain:-c plain.c -o out.o"
  "no-o:-c plain.c"
  "std-given:-c plain.c -o out.o -std=c11"
  "pragma:-c pragma.c -o out.o"
  "dtor:-c dtor.c -o out.o"
  "comdat:-c comdat.c -o out.o"
  "tls:-c tls.c -o out.o"
  "two-sources:-c plain.c -c other.c -o out.o"
  "link:other.o -o prog"
  "missing-source:-c nope.c -o out.o"
  "bad-source:-c bad.c -o out.o"
)

for c in "${cases[@]}"; do
  name=${c%%:*}; args=${c#*:}
  b=$work/$name-bash; r=$work/$name-ruby
  mk "$b"; mk "$r"
  sb=$work/$name-sandbox; mkdir -p "$sb/scripts"
  for f in "$repo"/scripts/*; do ln -sf "$f" "$sb/scripts/"; done
  ln -sfn "$repo/tools" "$sb/tools"; ln -sfn "$repo/build" "$sb/build"
  rm -f "$sb/scripts/gcc-cc"; cp "$repo/tests/gcc-cc/oracle.sh" "$sb/scripts/gcc-cc"; chmod +x "$sb/scripts/gcc-cc"
  (cd "$b" && NFCXX_CCACHE=0 bash "$sb/scripts/gcc-cc" $args >"$b.out" 2>"$b.err"); bs=$?
  (cd "$r" && NFCXX_CCACHE=0 ruby "$repo/scripts/gcc-cc.rb" $args >"$r.out" 2>"$r.err"); rs=$?
  if [ "$bs" != "$rs" ]; then fail=$((fail + 1)); echo "FAIL $name: status bash=$bs ruby=$rs"; continue; fi
  if [ "$bs" != 0 ]; then pass=$((pass + 1)); echo "pass $name (both fail with status $bs)"; continue; fi
  objs_b=$(cd "$b" && ls *.o 2>/dev/null | tr '\n' ' '); objs_r=$(cd "$r" && ls *.o 2>/dev/null | tr '\n' ' ')
  if [ "$objs_b" != "$objs_r" ]; then fail=$((fail + 1)); echo "FAIL $name: objects bash [$objs_b] ruby [$objs_r]"; continue; fi
  same=1
  for o in $objs_b; do
    if [ "$(nm -a "$b/$o" 2>/dev/null)" != "$(nm -a "$r/$o" 2>/dev/null)" ] || \
       [ "$(objdump -dr "$b/$o" 2>/dev/null | tail -n +4)" != "$(objdump -dr "$r/$o" 2>/dev/null | tail -n +4)" ]; then
      same=0; echo "FAIL $name: $o differs"
    fi
  done
  if [ $same = 1 ]; then pass=$((pass + 1)); echo "pass $name ($objs_b)"; else fail=$((fail + 1)); fi
done
echo "passed $pass, failed $fail"
[ "$fail" = 0 ]
