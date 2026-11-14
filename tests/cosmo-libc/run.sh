#!/bin/bash
# scripts/cosmo-libc.rb (the Ruby port) must build the same cosmo runtime as scripts/cosmo-libc.sh (bash, tests/cosmo-libc/oracle.sh):
# the same archive members, and each object with the same symbols (nm) and disassembly (objdump). Cosmo is not installed
# here, so the test makes a stand-in cosmo tree in a temporary directory: cosmocc does nothing, and the cosmo gcc is the
# host gcc with the cosmo-only flags dropped, with the host's headers in its system include directory. It needs the EDG
# build (build/edg, scripts/setup-edg.sh) and takes several minutes; it is not run in CI.
#   bash tests/cosmo-libc/run.sh
repo=$(cd "$(dirname "$0")/../.." && pwd)
work=$(mktemp -d); trap 'rm -rf "$work"' EXIT
fake=$work/cosmo; mkdir -p "$fake/bin" "$fake/include"
cat > "$fake/bin/x86_64-linux-cosmo-gcc" <<'GCC'
#!/bin/sh
args=""; skip=0
for a in "$@"; do
  if [ $skip = 1 ]; then skip=0; continue; fi
  case $a in
    -isystem) skip=1 ;;
    -nostdinc|-mno-red-zone|-mlong-double-64|-fno-pie|-D__COSMOPOLITAN__|-D__COSMOCC__|-D__FATCOSMOCC__) ;;
    *) args="$args
$a" ;;
  esac
done
set -- $(printf '%s\n' "$args" | sed '/^$/d')
exec gcc "$@"
GCC
printf '#!/bin/sh\nexit 0\n' > "$fake/bin/cosmocc"; chmod +x "$fake/bin/x86_64-linux-cosmo-gcc" "$fake/bin/cosmocc"
for d in /usr/include /usr/include/x86_64-linux-gnu /usr/lib/gcc/x86_64-linux-gnu/13/include; do
  for e in "$d"/*; do n=$(basename "$e"); [ "$n" = libc ] || [ -e "$fake/include/$n" ] || ln -s "$e" "$fake/include/$n"; done
done
mkdir -p "$fake/include/libc/integral"; : > "$fake/include/libc/integral/normalize.inc"
# the oracle's sandbox: the repository's scripts (the bash cosmo-libc is the oracle, and the bash gcc-cc of origin/main is
# its C compiler), with tools, 3rd and build as the repository's
sb=$work/sb; mkdir -p "$sb/scripts"
for f in "$repo"/scripts/*; do ln -s "$f" "$sb/scripts/"; done
rm -f "$sb/scripts/cosmo-libc.rb"; cp "$repo/tests/cosmo-libc/oracle.sh" "$sb/scripts/cosmo-libc.sh"; chmod +x "$sb/scripts/cosmo-libc.sh"
rm -f "$sb/scripts/gcc-cc.rb"
git -C "$repo" show origin/main:scripts/gcc-cc > "$sb/scripts/gcc-cc" && chmod +x "$sb/scripts/gcc-cc"
ln -s "$repo/tools" "$sb/tools"; ln -s "$repo/3rd" "$sb/3rd"; ln -s "$repo/build" "$sb/build"

NFCXX_COSMOCC=$fake/bin/cosmocc COSMO_LIBC_OUT=$work/bash bash "$sb/scripts/cosmo-libc.sh" > "$work/bash.log" 2>&1 || { echo "FAIL: bash build"; tail -3 "$work/bash.log"; exit 1; }
NFCXX_COSMOCC=$fake/bin/cosmocc COSMO_LIBC_OUT=$work/ruby ruby "$repo/scripts/cosmo-libc.rb" > "$work/ruby.log" 2>&1 || { echo "FAIL: ruby build"; tail -3 "$work/ruby.log"; exit 1; }
pass=0; fail=0
if diff <(ar t "$work/bash/libC.a") <(ar t "$work/ruby/libC.a") > /dev/null; then pass=$((pass + 1)); echo "pass members"; else fail=$((fail + 1)); echo "FAIL members"; fi
for o in $(ls "$work/bash/obj"); do
  if [ "$(nm -a "$work/bash/obj/$o")" = "$(nm -a "$work/ruby/obj/$o")" ] && \
     [ "$(objdump -d "$work/bash/obj/$o" | tail -n +4)" = "$(objdump -d "$work/ruby/obj/$o" | tail -n +4)" ]; then
    pass=$((pass + 1))
  else
    fail=$((fail + 1)); echo "FAIL object $o"
  fi
done
echo "passed $pass, failed $fail"
[ "$fail" = 0 ]
