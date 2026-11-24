#!/bin/bash
# scripts/pathb-cc.rb (the Ruby port) must produce the objects scripts/pathb-cc (bash, tests/pathb-cc/oracle.sh: the committed script of this branch, which runs scripts/pathb-dump.rb) produces: for
# each case, the same exit status, and for an object the same symbols (nm) and disassembly (objdump). The oracle's sandbox has
# the repository's scripts (its front end is scripts/pathb-dump.rb, both versions run the same one) and the built QBE and harness.
#   bash tests/pathb-cc/run.sh
repo=$(cd "$(dirname "$0")/../.." && pwd)
work=$(mktemp -d); trap 'rm -rf "$work"' EXIT
sb=$work/sb; mkdir -p "$sb/scripts"
for f in "$repo"/scripts/*; do ln -s "$f" "$sb/scripts/"; done
rm -f "$sb/scripts/pathb-cc.rb"; cp "$repo/tests/pathb-cc/oracle.sh" "$sb/scripts/pathb-cc"; chmod +x "$sb/scripts/pathb-cc"
rm -f "$sb/scripts/host-sys.sh"; cp "$repo/tests/host-sys/oracle.sh" "$sb/scripts/host-sys.sh"   # the bash original (the oracle sources it)
ln -s "$repo/build" "$sb/build"; ln -s "$repo/tools" "$sb/tools"; ln -s "$repo/lib" "$sb/lib"
cd "$work" || exit 1
printf 'int f(int x) { return x * 3 + 1; }\n' > plain.cc
printf 'template <class T> T id(T x) { return x; }\nint g(int *p, int n) { int s = 0; for (int i = 0; i < n; i++) s += id(p[i]); return s; }\n' > tmpl.cc
printf 'struct S { int a; long b; };\nint h(S s) { int v[4] = {1, 2, 3, 4}; return s.a + v[s.a & 3]; }\n' > agg.cc
printf 'int uc(void) { char c = 200; return c; }\n' > uchar.cc
printf 'int bad( {\n' > broken.cc

# one case: NAME, the environment (VAR=value ... or none) and the arguments
cases=(
  "plain:|-c plain.cc -o out.o"
  "template:|-c tmpl.cc -o out.o"
  "aggregate:|-c agg.cc -o out.o"
  "no-ir-opt:|--ir-opt=none -c tmpl.cc -o out.o"
  "ir-opt-inline-explicit:|--ir-opt=inline -c tmpl.cc -o out.o"
  "asan:|--asan -c plain.cc -o out.o"
  "safe-pointers:|--safe-pointers -c plain.cc -o out.o"
  "unsigned-char:|-funsigned-char -c uchar.cc -o out.o"
  "timeout-zero:|--timeout=0 -c plain.cc -o out.o"
  "pic:|--pic -c plain.cc -o out.o"
  "no-fp-trap:|--no-fp -c plain.cc -o out.o"
  "default-out-name:|-c plain.cc"
  "std-and-defs:|-std=c++17 -DX=2 -c plain.cc -o out.o"
  "bad-source:|-c broken.cc -o out.o"
  "no-input:|-c -o out.o"
)
pass=0; fail=0
for c in "${cases[@]}"; do
  name=${c%%:*}; rest=${c#*:}; envs=${rest%%|*}; args=${rest#*|}
  for side in bash ruby; do
    d=$work/$name-$side; mkdir -p "$d"; cp plain.cc tmpl.cc agg.cc uchar.cc broken.cc "$d/"
    if [ "$side" = bash ]; then prog="$sb/scripts/pathb-cc"; else prog="$repo/scripts/pathb-cc.rb"; fi
    if [ "$side" = bash ]; then runner=bash; else runner=ruby; fi
    (cd "$d" && env -i PATH="$PATH" HOME="$HOME" $envs $runner "$prog" $args > "$d.out" 2> "$d.err"); eval "st_$side=\$?"
  done
  if [ "$st_bash" != "$st_ruby" ]; then fail=$((fail + 1)); echo "FAIL $name: status bash=$st_bash ruby=$st_ruby"; continue; fi
  if [ "$st_bash" != 0 ]; then pass=$((pass + 1)); echo "pass $name (both fail with status $st_bash)"; continue; fi
  objs_b=$(cd "$work/$name-bash" && ls *.o 2>/dev/null | tr '\n' ' '); objs_r=$(cd "$work/$name-ruby" && ls *.o 2>/dev/null | tr '\n' ' ')
  if [ "$objs_b" != "$objs_r" ]; then fail=$((fail + 1)); echo "FAIL $name: objects bash [$objs_b] ruby [$objs_r]"; continue; fi
  same=1
  for o in $objs_b; do
    if [ "$(nm -a "$work/$name-bash/$o")" != "$(nm -a "$work/$name-ruby/$o")" ] || \
       [ "$(objdump -dr "$work/$name-bash/$o" | tail -n +4)" != "$(objdump -dr "$work/$name-ruby/$o" | tail -n +4)" ]; then
      same=0; echo "FAIL $name: $o differs"
    fi
  done
  if [ $same = 1 ]; then pass=$((pass + 1)); echo "pass $name ($objs_b)"; else fail=$((fail + 1)); fi
done
echo "passed $pass, failed $fail"
[ "$fail" = 0 ]
