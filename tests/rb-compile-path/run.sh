#!/bin/bash
# Differential test of the Ruby ports of the compile-path scripts (scripts/<name>.rb) against their bash originals.
#
# The oracle is the bash original, kept as tests/rb-compile-path/<name>/oracle.sh. Each case of tests/rb-compile-path/<name>/cases.txt
# runs twice, once per variant, in a fresh sandbox: the sandbox has the script under test as scripts/<name> (the oracle) or
# scripts/<base>.rb (the port, base = name without .sh), the symbol lists of scripts/sret-*.txt, and stubs (stub.sh, linked
# under the command names in the sandbox's bin directory and as scripts/mrb, scripts/pathb-cil and nfcxx). Nothing real is
# compiled, linked or run except the scripts, the shell and the real text tools. The sandbox's work directory holds the
# sources and fragments the cases name (see setup below); build/, be/ and lib/ are where the scripts keep their files.
#
# A case is a line "SETUP :: COMMAND" (SETUP may be empty: "COMMAND" alone). SETUP runs in the sandbox before the command, in its
# root; COMMAND runs in the work directory with $S (the script under test), $SB (the sandbox), and the environment the case
# sets (env -i: nothing else of the caller's). The two variants must agree on the stdout, the stderr, the exit status, the
# stub log (every command the script ran, in order, with its arguments, and NFCXX_CIL where the stubs record it), and the
# files the run left (names and first bytes). Paths of the sandbox are written as ROOT.
#
#   bash tests/rb-compile-path/run.sh [NAME...]     (default: every directory of tests/rb-compile-path that has a cases.txt)
set -u
here=$(cd "$(dirname "$0")" && pwd -P)
repo=$(cd "$here/../.." && pwd -P)
pass=0; fail=0
if [ $# -gt 0 ]; then names=("$@"); else names=(); for d in "$here"/*/; do [ -f "$d/cases.txt" ] && names+=("$(basename "$d")"); done; fi

# sandbox DIR VARIANT NAME: the sandbox, with the script under test (VARIANT oracle or port) and the stubs
sandbox() {
  local sb=$1 variant=$2 name=$3 base=${3%.sh}
  mkdir -p "$sb"/{scripts,bin,work,tmp,build,be,lib/ehshim}
  cp "$repo/scripts/sret-linux-symbols.txt" "$repo/scripts/sret-darwin-symbols.txt" "$repo/scripts/host-sys.sh" "$sb/scripts/"
  if [ "$variant" = oracle ]; then
    cp "$here/$name/oracle.sh" "$sb/scripts/$name"; chmod +x "$sb/scripts/$name"; S=$sb/scripts/$name
  else
    cp "$repo/scripts/$base.rb" "$sb/scripts/$base.rb"; chmod +x "$sb/scripts/$base.rb"; S=$sb/scripts/$base.rb
  fi
  # the symbol lists as the library tables of the cases: the Darwin SDK's export table (sdk; sdk-short lacks the first name),
  # and the nm output of libstdc++ (nm.txt; nm-short.txt lacks the first name)
  local dn ln
  dn=$(grep -v '^#' "$sb/scripts/sret-darwin-symbols.txt" | grep -v '^$')
  ln=$(grep -v '^#' "$sb/scripts/sret-linux-symbols.txt" | grep -v '^$')
  mkdir -p "$sb/sdk/usr/lib" "$sb/sdk-short/usr/lib"
  printf '%s\n' $dn | sed 's/^/_/' > "$sb/sdk/usr/lib/libc++.1.tbd"
  printf '%s\n' $dn | tail -n +2 | sed 's/^/_/' > "$sb/sdk-short/usr/lib/libc++.1.tbd"
  printf '%s\n' $ln | awk '{ print "0000000000000000 T " $1 "@@GLIBCXX_3.4" }' > "$sb/nm.txt"
  printf '%s\n' $ln | tail -n +2 | awk '{ print "0000000000000000 T " $1 "@@GLIBCXX_3.4" }' > "$sb/nm-short.txt"
  for c in cc gcc g++ ar llvm-ar llvm-mc mktemp uname nm realpath xcrun; do ln -s "$here/stub.sh" "$sb/bin/$c"; done
  for c in scripts/mrb scripts/pathb-cil nfcxx; do ln -s "$here/stub.sh" "$sb/$c"; done
  # the sources the scripts read: their mtimes are old, so an object or archive made by a case is newer
  : > "$sb/be/nfcxx_ldrt.c"; : > "$sb/lib/ehshim/nfcxx_eh_shim.cpp"; touch -d 2000-01-01 "$sb/be/nfcxx_ldrt.c" "$sb/lib/ehshim/nfcxx_eh_shim.cpp"
  local f
  for f in a.c b.cc x.cpp s.cxx; do : > "$sb/work/$f"; done
  printf 'notes\n' > "$sb/work/notes.txt"
  printf '{\n' > "$sb/work/f1.o"; printf '{\n' > "$sb/work/f2.o"
  printf 'junk\n' > "$sb/work/bad.o"; : > "$sb/work/empty.o"
  mkdir -p "$sb/work/inc"
  # the fake k1om GCC: prints its name and arguments, one per line
  mkdir -p "$sb/k1om/bin"
  printf '#!/bin/bash\nprintf "%%s\\n" "$0" "$@"\n' > "$sb/k1om/bin/k1om-mpss-linux-gcc"; chmod +x "$sb/k1om/bin/k1om-mpss-linux-gcc"
}

# run_case WORK VARIANT NAME SETUP CMD: one variant of a case, in the sandbox WORK/sb; its records go to WORK/res
run_case() {
  local w=$1 variant=$2 name=$3 setup=$4 cmd=$5 sb res f r
  sb=$w/sb; res=$w/res
  mkdir -p "$res"
  sandbox "$sb" "$variant" "$name"
  [ -z "$setup" ] || (cd "$sb" && env -i PATH=/usr/local/bin:/usr/bin:/bin LANG=C SB="$sb" S="$S" bash -c "$setup") > /dev/null 2>&1
  : > "$sb/log"
  (cd "$sb/work" && env -i PATH="$sb/bin:/usr/local/bin:/usr/bin:/bin" LANG=C HOME="$sb" \
     NFCXX_STUB_LOG="$sb/log" NFCXX_STUB_TMP="$sb/tmp" SB="$sb" S="$S" bash -c "$cmd") > "$res/out" 2> "$res/err"
  echo $? > "$res/status"
  cp "$sb/log" "$res/log"
  (cd "$sb" && find . \( -path ./scripts -o -path ./bin -o -path ./k1om \) -prune -o -print | sort | while read -r f; do
     echo "== $f"; if [ -f "$f" ]; then head -c 400 "$f"; echo; fi; done) > "$res/files"
  # the sandbox's own path is written as ROOT in every record
  for r in out err status log files; do sed -i "s|$sb|ROOT|g" "$res/$r"; done
}

for name in "${names[@]}"; do
  base=${name%.sh}
  echo "== $name"
  if [ ! -f "$here/$name/oracle.sh" ] || [ ! -f "$repo/scripts/$base.rb" ]; then
    echo "FAIL $name: needs $here/$name/oracle.sh and scripts/$base.rb"; fail=$((fail + 1)); continue
  fi
  n=0
  while IFS= read -r line || [ -n "$line" ]; do
    case $line in ''|'#'*) continue ;; esac
    n=$((n + 1))
    if [[ $line == *" :: "* ]]; then setup=${line%% :: *}; cmd=${line#* :: }; else setup=""; cmd=$line; fi
    # a case ending in " @nostderr" is compared without its stderr: a missing program is bash's message, not the Ruby one's
    recs="out err status log files"
    if [[ $cmd == *" @nostderr" ]]; then cmd=${cmd% @nostderr}; recs="out status log files"; fi
    wo=$(mktemp -d); wp=$(mktemp -d)
    run_case "$wo" oracle "$name" "$setup" "$cmd"
    run_case "$wp" port "$name" "$setup" "$cmd"
    bad=""
    for r in $recs; do
      cmp -s "$wo/res/$r" "$wp/res/$r" || bad="$bad $r"
    done
    if [ -z "$bad" ]; then
      pass=$((pass + 1))
    else
      fail=$((fail + 1))
      echo "FAIL $name case $n: $cmd   (differs:$bad)"
      for r in $bad; do diff "$wo/res/$r" "$wp/res/$r" | head -10 | sed 's/^/    /'; done
    fi
    rm -rf "$wo" "$wp"
  done < "$here/$name/cases.txt"
  echo "   $n cases"
done
echo "pass=$pass fail=$fail"
[ "$fail" = 0 ]
