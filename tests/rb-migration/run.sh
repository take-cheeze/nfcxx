#!/bin/bash
# Differential test of the Ruby ports of the setup scripts: scripts/<name>.rb against tests/rb-migration/<name>/oracle.sh (the bash
# original, a copy of scripts/<name>.sh made before the port).
#   bash tests/rb-migration/run.sh [NAME...]
# Per script: fixture.sh (optional) builds the sandbox's base tree, cases.sh lists the cases as  c NAME "ENV=VALUE ..." "ARGS" "SETUP".
# Each case runs twice, the oracle and the port, each in a fresh sandbox with the same fixture and the same SETUP (bash, in the
# sandbox's root). The sandbox's PATH is its bin directory (stub.sh under each stubbed name, see stub.sh) and its real directory
# (links to the coreutils and tools that run for real). The commands with effects outside the tree (git, curl, tar, ruby, ninja,
# make, rake, go, ar, cmake, gcc, g++, cc, nm, objcopy, and the compilers nfcc and nfcxx) are stubs. nproc is a stub that prints 1,
# so parallel steps run in their input order.
# A case environment may name the sandbox as @SB@. Compared: stdout, stderr, exit status, the stub log, and the tree after the run (type and path of each entry, sha1 of files).
# Normalized before the comparison: the sandbox's path (SB), the PID in new.PID, and the script's name (setup-X.sh and setup-X.rb).
set -u
here=$(cd "$(dirname "$0")" && pwd -P)
repo=$(cd "$here/../.." && pwd -P)
bash_bin=$(command -v bash); ruby_bin=$(command -v ruby)
stubs="ruby git curl tar rake ninja make gcc g++ cc ar go cmake nm objcopy nfcc nfcxx"
real="bash basename cat chmod cmp cp cut dirname env find flock gzip grep head ln mkdir mv python3 realpath rm sed sha1sum sha256sum sort tail tr touch wc xargs awk"

sandbox() {   # sandbox DIR: the bin and real directories
  local sb=$1 n p
  mkdir -p "$sb/bin" "$sb/real" "$sb/stubs" "$sb/home" "$sb/root/scripts" "$sb/root/build/edg/bin"
  for n in $stubs; do ln -s "$here/stub.sh" "$sb/bin/$n"; done
  ln -s "$here/stub.sh" "$sb/bin/nproc"
  printf 'echo 1\n' > "$sb/stubs/nproc"
  for n in $real; do p=$(command -v "$n") && ln -s "$p" "$sb/real/$n"; done
  ln -s "$here/stub.sh" "$sb/root/nfcc"; ln -s "$here/stub.sh" "$sb/root/nfcxx"; ln -s "$here/stub.sh" "$sb/root/build/edg/bin/eccp"
  cp "$repo/scripts/mruby-rt-config.rb" "$sb/root/scripts/"
}
envrun() {    # envrun SB ENVWORDS...: the environment of a command in the sandbox (bash's env -i, then the variables)
  local sb=$1; shift
  env -i PATH="$sb/bin:$sb/real" HOME="$sb/home" LANG=C NFCX_STUB_LOG="$sb/log" NFCX_STUBDIR="$sb/stubs" SB="$sb" "$@"
}
tree() {      # tree SB NAME: the entries under the root (not the script or the stub links) and the sha1 of the files (paths normalized)
  local sb=$1 name=$2
  (cd "$sb/root" && find . -mindepth 1 ! -path "./scripts/$name.*" ! -path ./nfcc ! -path ./nfcxx ! -path ./build/edg/bin/eccp \
     -printf '%y %p\n' | sort; \
   find . -type f ! -path "./scripts/$name.*" | sort | while read -r f; do
     printf '%s %s\n' "$(sed "s#$sb#SB#g" "$f" | sha1sum | cut -d' ' -f1)" "$f"; done)
}
norm() {      # norm SB FILE: the sandbox path, the PID and the script's name made the same
  sed -e "s#$1#SB#g" -e 's/new\.[0-9][0-9]*/new.PID/g' -e 's/setup-\([a-z-]*\)\.\(sh\|rb\)/setup-\1.X/g' "$2"
}

pass_total=0; fail_total=0; summary=""
names=("$@")
[ ${#names[@]} -gt 0 ] || names=($(cd "$here" && for d in */; do [ -f "$d/cases.sh" ] && echo "${d%/}"; done))
for name in "${names[@]}"; do
  dir=$here/$name
  [ -f "$dir/cases.sh" ] || { echo "no cases for $name" >&2; exit 1; }
  CN=(); CE=(); CA=(); CS=()
  c() { CN+=("$1"); CE+=("$2"); CA+=("$3"); CS+=("$4"); }
  . "$dir/cases.sh"
  pass=0; fail=0
  for i in "${!CN[@]}"; do
    cname=${CN[$i]}; cenv=${CE[$i]}; cargs=${CA[$i]}; csetup=${CS[$i]}
    eval "set -- $cargs"; argv=("$@")
    results=()
    for side in oracle port; do
      sb=$(mktemp -d); sandbox "$sb"
      if [ $side = oracle ]; then cp "$dir/oracle.sh" "$sb/root/scripts/$name.sh"; runner=$bash_bin; script=$sb/root/scripts/$name.sh
      else cp "$repo/scripts/$name.rb" "$sb/root/scripts/$name.rb"; runner=$ruby_bin; script=$sb/root/scripts/$name.rb; fi
      chmod +x "$sb/root/scripts/$name".*
      [ -f "$dir/fixture.sh" ] && (cd "$sb/root" && envrun "$sb" bash "$dir/fixture.sh") >/dev/null 2>&1
      (cd "$sb/root" && envrun "$sb" bash -c "$csetup") >/dev/null 2>&1
      : > "$sb/log"
      cenv_s=${cenv//@SB@/$sb}
      (cd "$sb/root" && envrun "$sb" $cenv_s "$runner" "$script" "${argv[@]}" >"$sb/out" 2>"$sb/err")
      st=$?
      {
        echo "STATUS $st"; norm "$sb" "$sb/out"; echo "--stderr"; norm "$sb" "$sb/err"
        echo "--log"; norm "$sb" "$sb/log"; echo "--tree"; tree "$sb" "$name"
      } > "$sb.res"
      results+=("$sb.res")
      rm -rf "$sb"
    done
    if cmp -s "${results[0]}" "${results[1]}"; then
      pass=$((pass + 1)); rm -f "${results[@]}"
    else
      fail=$((fail + 1))
      echo "FAIL $name [$cname] args: $cargs"
      diff "${results[0]}" "${results[1]}" | head -40
    fi
  done
  echo "$name: $pass passed, $fail failed"
  pass_total=$((pass_total + pass)); fail_total=$((fail_total + fail))
done
echo "total: $pass_total passed, $fail_total failed"
[ $fail_total = 0 ]
