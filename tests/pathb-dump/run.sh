#!/bin/bash
# scripts/pathb-dump.rb (the Ruby port) must print what scripts/pathb-dump (bash, tests/pathb-dump/oracle.sh) prints: for each
# case, the same stdout and exit status. The front end is the built harness (build/pathb, scripts/setup-pathb.sh).
#   bash tests/pathb-dump/run.sh
repo=$(cd "$(dirname "$0")/../.." && pwd)
work=$(mktemp -d); trap 'rm -rf "$work"' EXIT
# the oracle's sandbox: the repository's scripts (its host-sys.sh is the bash original, tests/host-sys/oracle.sh), with the built harness
sb=$work/sb; mkdir -p "$sb/scripts"
for f in "$repo"/scripts/*; do ln -s "$f" "$sb/scripts/"; done
rm -f "$sb/scripts/pathb-dump.rb"; cp "$repo/tests/pathb-dump/oracle.sh" "$sb/scripts/pathb-dump"; chmod +x "$sb/scripts/pathb-dump"
rm -f "$sb/scripts/host-sys.sh"; cp "$repo/tests/host-sys/oracle.sh" "$sb/scripts/host-sys.sh"   # the bash original (the oracle sources it)
ln -s "$repo/build" "$sb/build"; ln -s "$repo/tools" "$sb/tools"; ln -s "$repo/lib" "$sb/lib"
cd "$work" || exit 1
printf 'int f(int x) { return x * 3 + 1; }\n' > plain.cc
printf 'template <class T> T id(T x) { return x; }\nint g() { return id(3); }\n' > tmpl.cc
printf 'int h(void) { return 4; }\n' > c.c
mkdir -p inc sys; printf 'int from_inc(int);\n#define SYSVAL 7\n' > inc/mine.h; printf 'int from_sys(int);\n' > sys/s.h
printf '#include "mine.h"\nint use() { return from_inc(SYSVAL); }\n' > inc_user.cc
printf '#include <stddef.h>\nint sz() { return (int)sizeof(size_t); }\n' > host.cc
printf 'int uc(void) { char c = 200; return c; }\n' > uchar.c

cases=(
  "plain:plain.cc"
  "template-tused:tmpl.cc"
  "c-file:c.c"
  "ir-mode:--ir tmpl.cc"
  "std-and-defs:-std=c++17 -DX=2 -Iinc plain.cc"
  "include-user:-Iinc inc_user.cc"
  "nostdinc-isystem:-nostdinc -isystem sys host.cc"
  "unsigned-char:-funsigned-char uchar.c"
  "freestanding:--freestanding -ffreestanding plain.cc"
  "c17-explicit:-std=c17 c.c"
  "missing-file:nope.cc"
  "no-input:-std=c++20"
  "bad-std:-std=c++99 plain.cc"
)
pass=0; fail=0
for c in "${cases[@]}"; do
  name=${c%%:*}; args=${c#*:}
  bash "$sb/scripts/pathb-dump" $args > "$work/$name.bash.out" 2> "$work/$name.bash.err"; bs=$?
  ruby "$repo/scripts/pathb-dump.rb" $args > "$work/$name.ruby.out" 2> "$work/$name.ruby.err"; rs=$?
  if [ "$bs" = "$rs" ] && cmp -s "$work/$name.bash.out" "$work/$name.ruby.out"; then
    pass=$((pass + 1)); echo "pass $name (status $bs, $(wc -c < "$work/$name.bash.out") bytes)"
  else
    fail=$((fail + 1)); echo "FAIL $name: status bash=$bs ruby=$rs"
    diff "$work/$name.bash.out" "$work/$name.ruby.out" | head -5
  fi
done
echo "passed $pass, failed $fail"
[ "$fail" = 0 ]
