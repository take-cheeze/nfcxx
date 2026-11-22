#!/bin/bash
# The pinned copy (pinned-port-modules.txt) was taken from the driver at commit 1aa750d8b52163609481ea3cb4ad631389529a7b, before the B8 switch.
# Differential test of nfcxx's C++ module options (docs/notes/modules.md): the module block verbatim from the bash that computed
# modopts itself (pinned-oracle-modules.txt, the frozen body's lines before the planner took them) against the block verbatim from
# the pinned pre-switch driver (pinned-port-modules.txt, which calls
# scripts/nfcxx-modopts.rb plan). Each case runs both in a fresh directory with the real module scanner: the module directory,
# the options, the status and messages of the block, and the directory tree it leaves. Output that names the case directory is
# normalized to @W; @D in a value is replaced by the case directory.
#   bash tests/driver-modopts/run.sh
set -u
here=$(cd "$(dirname "$0")" && pwd -P)
repo=$(cd "$here/../.." && pwd -P)
work=$(cd "$(mktemp -d)" && pwd -P); trap 'rm -rf "$work"' EXIT
pass=0; fail=0

# the blocks, copied from the two drivers: from the mdir line to the last line of the module options
# The frozen body's block moved to scripts/nfcxx-modules-plan.rb (it no longer has these lines), so the oracle is the block as the
# body had it (pinned-oracle-modules.txt, taken from the body before the move)
cp "$here/pinned-oracle-modules.txt" "$work/oracle.sh"
sed -n '/^  mdir=\${moddir:-\$(dirname "\$out")}; mkdir -p/,/^  eval "\$modopts_sh"$/p' "$here/pinned-port-modules.txt" > "$work/port.sh"
[ "$(wc -l < "$work/oracle.sh")" = 4 ] || { echo "driver-modopts: the frozen driver's module block is not as expected" >&2; exit 2; }
[ "$(wc -l < "$work/port.sh")" = 3 ] || { echo "driver-modopts: nfcxx's module block is not as expected" >&2; exit 2; }

# the fixtures of every case: a module interface, an import-only source, a dotted module name, a directory, a directory link,
# and a file in the way of a directory
fixtures() {
  printf 'export module geom;\nint x;\n' > geom.cppm
  printf 'export import base;\n' > plain.cppm
  printf 'export module a.b;\n' > dotted.cppm
  mkdir -p mods real; ln -s real link; printf x > blocker
}

# run BLOCK CASEDIR OUT MODDIR SRC: the block with the case's values, run in CASEDIR; prints its modopts and status, the messages
# and the tree it leaves
run() {
  local block=$1 d=$2 out=$3 moddir=$4 src=$5
  ( cd "$d" && fixtures && bash -c '
      set -euo pipefail
      root=$1; out=$2; moddir=$3; srcs=("$4"); modopts=(); source "$5"
      printf "mdir=[%s]\n" "$mdir"; printf "modopts"; printf " [%s]" "${modopts[@]}"; printf "\n"
    ' _ "$repo" "$out" "$moddir" "$src" "$block" 2>&1; echo "status=$?"
    find . -mindepth 1 | LC_ALL=C sort | sed 's/^/tree /' )
}

# case_ NAME OUT MODDIR SRC: the same values in the oracle's directory and the port's, the two results compared
case_() {
  local name=$1 out=$2 moddir=$3 src=$4 o p
  mkdir -p "$work/oracle/$name" "$work/port/$name"
  o=$(run "$work/oracle.sh" "$work/oracle/$name" "${out//@D/$work/oracle/$name}" "${moddir//@D/$work/oracle/$name}" "$src" | sed "s#$work/oracle/$name#@W#g")
  p=$(run "$work/port.sh" "$work/port/$name" "${out//@D/$work/port/$name}" "${moddir//@D/$work/port/$name}" "$src" | sed "s#$work/port/$name#@W#g")
  if [ "$o" = "$p" ]; then pass=$((pass + 1)); echo "ok   $name ($(printf '%s' "$p" | head -2 | tr '\n' ' '))"
  else fail=$((fail + 1)); echo "FAIL $name"; echo "  oracle:"; printf '%s\n' "$o" | sed 's/^/    /'; echo "  port:"; printf '%s\n' "$p" | sed 's/^/    /'; fi
}

case_ "empty moddir: the output's directory, module declared" a.out "" geom.cppm
case_ "empty moddir: no module declared (import only)" a.out "" plain.cppm
case_ "empty moddir: dotted module name" a.out "" dotted.cppm
case_ "relative moddir, existing" a.out mods geom.cppm
case_ "relative moddir, created with its parent" a.out new/deep geom.cppm
case_ "absolute moddir, created" a.out @D/abs/mods geom.cppm
case_ "relative moddir through a symlink" a.out link geom.cppm
case_ "absolute moddir through a symlink" a.out @D/link geom.cppm
case_ "output in a directory that does not exist (created)" made/sub/a.out "" geom.cppm
case_ "output in a dotted directory (created)" ./x/a.out "" dotted.cppm
case_ "moddir with a space" a.out "my mods" geom.cppm
case_ "moddir with a single quote" a.out "it's here" geom.cppm
case_ "output directory with a space and a quote (created)" "o'k dir/a.out" "" geom.cppm
case_ "moddir without a module declaration, created" a.out new2 plain.cppm
case_ "moddir that cannot be created (a file in the way): mkdir's status and message" a.out blocker/x geom.cppm
case_ "output directory that cannot be created: mkdir's status and message" blocker/a.out "" geom.cppm

echo "driver-modopts: $pass passed, $fail failed"
[ "$fail" = 0 ]
