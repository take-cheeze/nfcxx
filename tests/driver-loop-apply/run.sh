#!/bin/bash
# scripts/nfcxx-loop.rb --shell must leave the driver's variables as the bash apply loop of nfcxx does (oracle.sh, verbatim), and
# refuse or stop the same way: the same variables, the same stderr and status, for each argument list.   bash tests/driver-loop-apply/run.sh
here=$(cd "$(dirname "$0")" && pwd -P); repo=$(cd "$here/../.." && pwd -P)
pass=0; fail=0
setup='set -euo pipefail; srcs=(); files=(); cflags=(); cfiles=(); cu_inputs=(); cpp2_inputs=(); ppflags=(); pie_opts=(); preinc=(); sysdirs=(); isa=(); diag_opts=(); asanopts=(); std=--c++23; out=a.out; outset=0; compile_only=0; ncpp=0; nobj=0'
cases=(
  "-c m.cpp -o x.o -std=c++17 -I inc"
  "-c a.cpp b.cpp -DX=1 -DY -UZ -Wall"
  "m.cpp -o prog -O2 -g -fPIC -shared"
  "-std=gnu++20 -include pre.h -isystem /usr/inc -c m.cpp"
  "-c m.cpp -o m.o -fsanitize=address -fno-omit-frame-pointer"
  "-c m.cpp --dialect=clang --backend=gcc"
  "-c m.cpp -fuse-ld=nosuch -Wl,--as-needed"
  "-c m.cpp -fuse-ld=lld -o m.o"
  "-c m.cpp -o"
  "-c m.cpp -fsanitize=undefined,bounds -fno-sanitize=all"
  "-c m.cpp --no-such-option"
  "-c m.cpp -I"
  "-c m.cpp --instantiate=used"
  "-x c++ -c m.cpp"
  "-c m.cpp -MD -MF deps.d"
  "-E m.cpp"
  "-c m.cpp -fexceptions -fno-exceptions -frtti"
  "-c m.cpp -march=native -mtune=generic -O0"
  "-c m.cpp -ggdb3 -gdwarf-4 -fvisibility=hidden"
  "-c m.cpp -D'A=1 2' -I'dir with space'"
)
for cmd in "${cases[@]}"; do
  eval "args=($cmd)"
  recs=$(mktemp); ruby "$repo/scripts/nfcxx-loop.rb" --records --ld-available= -- "${args[@]}" > "$recs"
  # the names the loop may set: the driver's arrays and scalars named by the records (their values are compared)
  names=$(tr '\0' '\n' < "$recs" | sed -n 's/^[sa]\([A-Za-z_0-9]*\)=.*/\1/p' | sort -u | tr '\n' ' ')
  dump="for v in $names; do declare -p \"\$v\" 2>/dev/null; done"
  want_out=$(env -i PATH="$PATH" bash -c "$setup; source '$here/oracle.sh'; RECORDS_FILE='$recs' apply_records; s=\$?; $dump; exit \$s" 2>"$here/.w.err"); wrc=$?
  got_out=$(env -i PATH="$PATH" bash -c "$setup; source '$here/oracle.sh'; sh=\$(ruby '$repo/scripts/nfcxx-loop.rb' --shell --ld-available= -- \"\$@\") || exit \$?; eval \"\$sh\"; s=\$?; $dump; exit \$s" _ "${args[@]}" 2>"$here/.g.err"); grc=$?
  rm -f "$recs"
  # the bash's own error text carries the line of the statement it ran in: compared without the line number
  werr=$(sed 's/line [0-9]*: //' "$here/.w.err"); gerr=$(sed 's/line [0-9]*: //' "$here/.g.err")
  if [ "$wrc" = "$grc" ] && [ "$want_out" = "$got_out" ] && [ "$werr" = "$gerr" ]; then pass=$((pass + 1)); else
    fail=$((fail + 1)); echo "FAIL [$cmd] status $wrc vs $grc"; diff <(echo "$want_out") <(echo "$got_out") | head -6; diff "$here/.w.err" "$here/.g.err" | head -4; fi
done
rm -f "$here/.w.err" "$here/.g.err"
echo "driver-loop-apply: $pass passed, $fail failed"
[ $fail = 0 ]
