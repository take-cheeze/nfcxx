#!/bin/bash
# scripts/nfcxx-gnu-opts.rb plan must give the gnu_opts the bash block of nfcxx gives (copied verbatim below), for each dialect,
# GNU version and clang probe answer. The root's host-sys.rb is a stub that answers the clang version (or nothing).
#   bash tests/driver-gnu-opts/run.sh
here=$(cd "$(dirname "$0")" && pwd -P); repo=$(cd "$here/../.." && pwd -P)
t=$(mktemp -d); trap 'rm -rf "$t"' EXIT
pass=0; fail=0
bash_block() {
  gnu_opts=()
  if [ "$dialect" = clang ]; then
    cv=$("${RUBY:-ruby}" "$root/scripts/host-sys.rb" host_clang_version); [ -n "$cv" ] && gnu_opts=(--clang_version="$cv")
  elif [ -n "$gnu" ]; then
    gnu_opts=(--gnu_version="$gnu")
  fi
}
for answer in "" "18" "17.0.6"; do
  mkdir -p "$t/$answer/scripts"
  printf 'if ARGV[0] == "host_clang_version"\n  print %s\nend\n' "'$answer'" > "$t/$answer/scripts/host-sys.rb"
  for dialect in g++ clang; do for gnu in "" 130000; do
    root="$t/$answer"
    want=$(bash_block; printf '%s|' "${gnu_opts[@]+"${gnu_opts[@]}"}")
    eval "$(ruby "$repo/scripts/nfcxx-gnu-opts.rb" plan dialect="$dialect" gnu="$gnu" root="$root")"
    got=$(printf '%s|' "${gnu_opts[@]+"${gnu_opts[@]}"}")
    if [ "$want" = "$got" ]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL answer=[$answer] dialect=$dialect gnu=[$gnu]: bash [$want] ruby [$got]"; fi
  done; done
done
echo "driver-gnu-opts: $pass passed, $fail failed"
[ $fail = 0 ]
