#!/bin/bash
# Differential test of the Ruby ports of the helper launchers (scripts/mrb.rb, scripts/weak-symbols.rb,
# scripts/spirv-emit.rb, scripts/pathb-cil.rb, and their library scripts/tool-ensure.rb) against the bash originals
# (tests/helpers/oracle/*.sh). Each case builds two identical scratch trees, runs the bash original in one and the Ruby
# port in the other, with the same environment and fake tools on PATH: a fake command (the compiler, mruby, pathb-dump)
# that logs its arguments and prints its argv, a fake ninja that logs and builds the binary, and a fake setup-mruby.sh.
# Compared: stdout, stderr, the exit status, the commands the fakes recorded, and the files the run left behind.
# The only normalizations: the scratch tree's path, the mktemp directory names that head shows for the manifests, the
# shell's "FILE: line N: " prefix on the bash side's own diagnostics, and the bash usage line's "scripts/pathb-cil" (the
# Ruby name is scripts/pathb-cil.rb).
#
#   bash tests/helpers/run.sh
set -u
here=$(cd "$(dirname "$0")" && pwd -P)
repo=$(cd "$here/../.." && pwd -P)
oracle=$here/oracle
REAL_RUBY=$(command -v ruby) || { echo "helpers: ruby is not installed"; exit 1; }
work=$(mktemp -d); trap '[ -n "${HELPERS_KEEP:-}" ] || rm -rf "$work"' EXIT
fake=$work/fake; sys=$work/sys; bin=$work/bin; nobin=$work/bin-noninja
mkdir -p "$fake" "$sys" "$bin" "$nobin" "$work/t" "$work/res"

# the system tools the scripts use; ninja and ruby are not among them (the fakes below are)
for t in bash env cat cp cmp find mktemp head sed basename dirname flock sleep rm rmdir mkdir tr awk touch uname ls cut sort wc mv chmod true false; do
  p=$(command -v "$t") && ln -s "$p" "$sys/$t"
done

cat > "$fake/toolbin" <<'EOF'
#!/bin/bash
# A fake command: logs "NAME ARGS" to FAKE_LOG (a --manifest= file shows as MAN), prints "module ARGS", writes its
# manifest, and writes the two files the launchers read back (a pathb-cil-emit.rb fragment, a cil-link.rb output).
# pathb-dump.rb fails on a missing input. FAKE_FAIL_NAME=NAME exits FAKE_FAIL_RC (default 1), FAKE_ERR is printed on
# stderr, and FAKE_DIFF=stdout|err makes the C++ emitter's output differ.
name=$(basename "$0")
shown=() man=
for a in "$@"; do
  case $a in
    --manifest=*) man=${a#--manifest=}; shown+=("--manifest=MAN") ;;
    *) shown+=("$a") ;;
  esac
done
printf '%s %s\n' "$name" "${shown[*]}" >> "$FAKE_LOG"
# the output: an interpreter's script argument is not part of what the program prints
printed=("${shown[@]}")
case $1 in *.rb) printed=("${shown[@]:1}") ;; esac
if [ "$name" = pathb-dump.rb ] && [ $# -gt 0 ]; then
  f=${!#}
  [ -e "$f" ] || { echo "pathb-dump: cannot open $f" >&2; exit 1; }
fi
[ -z "$man" ] || printf 'manifest %s\n' "${printed[*]}" > "$man"
case $1 in
  *pathb-cil-emit.rb) [ $# -ge 3 ] && printf 'FRAGMENT\n' > "$3" ;;
  *cil-link.rb) prev=; for a in "$@"; do [ "$prev" = -o ] && { printf 'EXE\n' > "$a"; break; }; prev=$a; done ;;
esac
[ -z "${FAKE_ERR:-}" ] || printf '%s\n' "$FAKE_ERR" >&2
if [ "$name" = pathb-spirv-emit ] && [ "${FAKE_DIFF:-}" = stdout ]; then echo "differing module"
else echo "module ${printed[*]}"; fi
[ "$name" = pathb-spirv-emit ] && [ "${FAKE_DIFF:-}" = err ] && echo "cxx warning" >&2
[ "$name" = "${FAKE_FAIL_NAME:-}" ] && exit "${FAKE_FAIL_RC:-1}"
exit 0
EOF

cat > "$bin/ninja" <<'EOF'
#!/bin/bash
# A fake ninja: logs its arguments, then builds build/NAME (NAME: the last directory of -C) as a copy of the fake
# command, unless FAKE_NINJA_RC is set (it exits with that status) or FAKE_NINJA_NOBIN is 1 (it builds nothing).
echo "ninja $*" >> "$FAKE_LOG"
[ -z "${FAKE_NINJA_RC:-}" ] || exit "$FAKE_NINJA_RC"
[ "${FAKE_NINJA_NOBIN:-}" = 1 ] && exit 0
dir=$2
root=$(dirname "$(dirname "$dir")")
mkdir -p "$root/build"
cp "$FAKE_TOOLBIN" "$root/build/$(basename "$dir")" && chmod +x "$root/build/$(basename "$dir")"
EOF

cat > "$fake/setup-mruby.sh" <<'EOF'
#!/bin/bash
# A fake scripts/setup-mruby.sh: logs the call. FAKE_SETUP_RC exits with that status; FAKE_SETUP_NOCREATE=1 succeeds
# without the interpreter; otherwise it builds build/mruby-tool/bin/mruby (a copy of the fake command).
echo "setup-mruby.sh" >> "$FAKE_LOG"
[ -z "${FAKE_SETUP_RC:-}" ] || exit "$FAKE_SETUP_RC"
[ "${FAKE_SETUP_NOCREATE:-}" = 1 ] && exit 0
root=$(cd "$(dirname "$0")/.." && pwd)
mkdir -p "$root/build/mruby-tool/bin"
cp "$FAKE_TOOLBIN" "$root/build/mruby-tool/bin/mruby" && chmod +x "$root/build/mruby-tool/bin/mruby"
EOF
chmod +x "$fake/toolbin" "$bin/ninja" "$fake/setup-mruby.sh"
cp "$fake/toolbin" "$fake/mruby"; chmod +x "$fake/mruby"
# the fake ruby: pathb-spirv-emit.rb runs as the fake command; every other script (the launchers, through their shebang) runs
# with the real interpreter
cat > "$fake/ruby" <<'EOF'
#!/bin/bash
case $1 in
  *pathb-spirv-emit.rb) exec "$FAKE_TOOLBIN" "$@" ;;
  *) exec "$FAKE_REAL_RUBY" "$@" ;;
esac
EOF
for d in "$bin" "$nobin"; do cp "$fake/ruby" "$d/ruby"; done
chmod +x "$fake/ruby" "$bin/ruby" "$nobin/ruby"

# make_tree DIR SPEC: a scratch tree with both kinds of scripts, the sources, and the state SPEC names (@cxx-fresh,
# @cxx-stale, @mruby, @weak, @notexec; the other tokens are environment settings, see run_side)
make_tree() {
  local d=$1 spec=$2 tok n
  mkdir -p "$d"/scripts "$d"/build "$d"/out "$d"/work "$d"/tools/pathb-spirv-emit "$d"/tools/weak-symbols
  cp "$oracle/mrb.sh" "$d/scripts/mrb"
  cp "$oracle/weak-symbols.sh" "$d/scripts/weak-symbols"
  cp "$oracle/spirv-emit.sh" "$d/scripts/spirv-emit"
  cp "$oracle/pathb-cil.sh" "$d/scripts/pathb-cil"
  cp "$oracle/tool-ensure.sh" "$d/scripts/tool-ensure.sh"
  for n in mrb weak-symbols spirv-emit pathb-cil; do cp "$repo/scripts/$n.rb" "$d/scripts/$n.rb"; done
  cp "$repo/scripts/tool-ensure.rb" "$d/scripts/tool-ensure.rb"
  cp "$fake/toolbin" "$d/scripts/pathb-dump.rb"
  cp "$fake/setup-mruby.sh" "$d/scripts/setup-mruby.sh"
  chmod +x "$d"/scripts/mrb "$d"/scripts/weak-symbols "$d"/scripts/spirv-emit "$d"/scripts/pathb-cil \
    "$d"/scripts/mrb.rb "$d"/scripts/weak-symbols.rb "$d"/scripts/spirv-emit.rb "$d"/scripts/pathb-cil.rb \
    "$d"/scripts/pathb-dump.rb "$d"/scripts/setup-mruby.sh
  : > "$d/work/a.cpp"; : > "$d/work/b.c"; : > "$d/work/my file+x.cpp"
  : > "$d/tools/pathb-spirv-emit/emit.cpp"; touch -d @946684800 "$d/tools/pathb-spirv-emit/emit.cpp"
  for tok in $spec; do
    case $tok in
      @cxx-fresh|@cxx-stale)
        cp "$fake/toolbin" "$d/build/pathb-spirv-emit"; chmod +x "$d/build/pathb-spirv-emit"
        touch -d @1000000000 "$d/build/pathb-spirv-emit"
        [ "$tok" = @cxx-stale ] && touch -d @1100000000 "$d/tools/pathb-spirv-emit/emit.cpp" ;;
      @mruby) mkdir -p "$d/build/mruby-tool/bin"; cp "$fake/toolbin" "$d/build/mruby-tool/bin/mruby"
              chmod +x "$d/build/mruby-tool/bin/mruby" ;;
      @weak) cp "$fake/toolbin" "$d/build/weak-symbols"; chmod +x "$d/build/weak-symbols" ;;
      @notexec) : > "$d/notexec"; chmod 644 "$d/notexec" ;;
    esac
  done
}

# normalize FILE TREE SIDE: the scratch tree's path becomes @ROOT@; the mktemp names of head's headers; and on the bash
# side, the shell's "FILE: line N: " prefix and the usage line's name
normalize() {
  local f=$1 tree=$2 side=$3
  [ -f "$f" ] || return 0
  sed -i -e "s#$tree#@ROOT@#g" -e 's#/tmp/[^ /]*/#@TMP@/#g' -e 's#/[^ :]*/\(rb\|cx\)\.\(err\|spv\|man\)#\1.\2#g' "$f"
  if [ "$side" = bash ]; then
    sed -i -e 's/^[^ ]*: line [0-9][0-9]*: //' -e 's#usage: scripts/pathb-cil #usage: scripts/pathb-cil.rb #' "$f"
  fi
}

# run_side SIDE NAME TOOL SPEC ARGS...: one run of bash or Ruby in its own tree, recorded under $work/res/NAME-SIDE
run_side() {
  local side=$1 name=$2 tool=$3 spec=$4; shift 4
  local tree=$work/t/$name-$side res=$work/res/$name-$side
  rm -rf "$tree" "$res"; mkdir -p "$tree" "$res"; : > "$res/log"
  make_tree "$tree" "$spec"
  local envs=() path=$sys:$bin tok v a cmd=() args=()
  case " $spec " in *" @noninja "*) path=$sys:$nobin ;; esac
  for tok in $spec; do
    case $tok in
      @*) ;;
      *=*) v=${tok#*=}; v=${v//@TREE@/$tree}; v=${v//@FAKE@/$fake}; envs+=("${tok%%=*}=$v") ;;
    esac
  done
  for a in "$@"; do a=${a//@TREE@/$tree}; args+=("$a"); done
  if [ "$side" = bash ]; then cmd=("$tree/scripts/$tool"); else cmd=("$REAL_RUBY" "$tree/scripts/$tool.rb"); fi
  (cd "$tree" && env -i PATH="$path" HOME="$work" FAKE_LOG="$res/log" FAKE_TOOLBIN="$fake/toolbin" FAKE_REAL_RUBY="$REAL_RUBY" \
     ${envs[@]+"${envs[@]}"} "${cmd[@]}" ${args[@]+"${args[@]}"}) > "$res/out" 2> "$res/err"
  echo $? > "$res/status"
  (cd "$tree" && find . -type f ! -path './scripts/*' ! -path './tools/*' ! -path './work/*' | sort) > "$res/files"
  (cd "$tree" && for f in $(find . -type f ! -path './scripts/*' ! -path './tools/*' ! -path './work/*' | sort); do
     echo "== $f"; cat "$f"; done) > "$res/outputs" 2>&1
  for f in out err status log outputs files; do normalize "$res/$f" "$tree" "$side"; done
}

pass=0; fail=0
# case NAME TOOL SPEC ARGS...: the bash original and the Ruby port must agree on everything run_side records
case_() {
  local name=$1 tool=$2 spec=$3 r ok=1; shift 3
  run_side bash "$name" "$tool" "$spec" "$@"
  run_side ruby "$name" "$tool" "$spec" "$@"
  for r in out err status log outputs files; do
    cmp -s "$work/res/$name-bash/$r" "$work/res/$name-ruby/$r" || ok=0
  done
  if [ $ok = 1 ]; then
    pass=$((pass + 1))
  else
    fail=$((fail + 1))
    echo "FAIL $name ($tool)"
    for r in status out err log outputs files; do
      cmp -s "$work/res/$name-bash/$r" "$work/res/$name-ruby/$r" || {
        echo "  $r differs:"
        diff "$work/res/$name-bash/$r" "$work/res/$name-ruby/$r" | head -12 | sed 's/^/    /'; }
    done
  fi
}

# the syntax of every file of the change
for f in "$oracle"/*.sh; do bash -n "$f" || { echo "FAIL syntax $f"; fail=$((fail + 1)); }; done
for f in "$repo"/scripts/mrb.rb "$repo"/scripts/weak-symbols.rb "$repo"/scripts/spirv-emit.rb \
         "$repo"/scripts/pathb-cil.rb "$repo"/scripts/tool-ensure.rb; do
  "$REAL_RUBY" -c "$f" > /dev/null || { echo "FAIL syntax $f"; fail=$((fail + 1)); }
done

# mrb: the interpreter (MRB), the build of it when it is missing, and the refusals
case_ mrb-exec mrb "MRB=@FAKE@/mruby" "scripts/x.rb" "a b" "" "--flag"
case_ mrb-noargs mrb "MRB=@FAKE@/mruby"
case_ mrb-built mrb "@mruby" "-e" "1"
case_ mrb-empty-env mrb "MRB= @mruby" "x.rb"
case_ mrb-setup mrb "" "x.rb"
case_ mrb-setup-fails mrb "FAKE_SETUP_RC=3" "x.rb"
case_ mrb-setup-no-binary mrb "FAKE_SETUP_NOCREATE=1" "x.rb"
case_ mrb-not-exec mrb "MRB=@TREE@/notexec @notexec" "x.rb"

# weak-symbols: the build of build/weak-symbols through tool-ensure, and the NFCXX_WEAK_SYMBOLS_RB route
case_ weak-built weak-symbols "@weak" "in.c" "out.s"
case_ weak-noargs weak-symbols "@weak"
case_ weak-build weak-symbols "" "a.c" "b.s"
case_ weak-ninja-fails weak-symbols "FAKE_NINJA_RC=5" "a.c"
case_ weak-ninja-missing weak-symbols "@noninja" "a.c"
case_ weak-no-binary weak-symbols "FAKE_NINJA_NOBIN=1" "a.c"
case_ weak-rb-route weak-symbols "NFCXX_WEAK_SYMBOLS_RB=@TREE@/x.rb MRB=@FAKE@/mruby @weak" "--c-input" "a.c"

# spirv-emit: the default choice, each emitter, the rebuild of the C++ emitter, and the check mode
case_ spv-default-cxx spirv-emit "@cxx-fresh" "--kernel-cl" "--manifest=@TREE@/out/a.man" "in.ir"
case_ spv-default-ruby spirv-emit "@noninja" "--manifest=@TREE@/out/b.man" "in.ir"
case_ spv-ruby-default spirv-emit "NFCXX_SPIRV_EMITTER=ruby" "in.ir"
case_ spv-ruby spirv-emit "NFCXX_SPIRV_EMITTER=ruby NFCXX_SPIRV_RUBY=@FAKE@/toolbin" "in.ir"
case_ spv-ruby-status spirv-emit "NFCXX_SPIRV_EMITTER=ruby NFCXX_SPIRV_RUBY=@FAKE@/toolbin FAKE_FAIL_NAME=toolbin FAKE_FAIL_RC=4" "in.ir"
case_ spv-ruby-missing spirv-emit "NFCXX_SPIRV_EMITTER=ruby NFCXX_SPIRV_RUBY=@TREE@/nope" "in.ir"
case_ spv-cxx-fresh spirv-emit "NFCXX_SPIRV_EMITTER=cxx @cxx-fresh" "in.ir"
case_ spv-cxx-build spirv-emit "NFCXX_SPIRV_EMITTER=cxx" "in.ir"
case_ spv-cxx-stale spirv-emit "NFCXX_SPIRV_EMITTER=cxx @cxx-stale" "in.ir"
case_ spv-cxx-noninja spirv-emit "NFCXX_SPIRV_EMITTER=cxx @noninja" "in.ir"
case_ spv-cxx-ninja-fails spirv-emit "NFCXX_SPIRV_EMITTER=cxx FAKE_NINJA_RC=2" "in.ir"
case_ spv-check-same spirv-emit "NFCXX_SPIRV_EMITTER=check NFCXX_SPIRV_RUBY=@FAKE@/toolbin @cxx-fresh" "--manifest=@TREE@/out/c.man" "in.ir"
case_ spv-check-diff-stdout spirv-emit "NFCXX_SPIRV_EMITTER=check NFCXX_SPIRV_RUBY=@FAKE@/toolbin @cxx-fresh FAKE_DIFF=stdout" "in.ir"
case_ spv-check-diff-err spirv-emit "NFCXX_SPIRV_EMITTER=check NFCXX_SPIRV_RUBY=@FAKE@/toolbin @cxx-fresh FAKE_DIFF=err FAKE_ERR=shared-warning" "--manifest=@TREE@/out/d.man" "in.ir"
case_ spv-check-exit spirv-emit "NFCXX_SPIRV_EMITTER=check NFCXX_SPIRV_RUBY=@FAKE@/toolbin @cxx-fresh FAKE_FAIL_NAME=pathb-spirv-emit FAKE_FAIL_RC=7" "in.ir"
case_ spv-bad-mode spirv-emit "NFCXX_SPIRV_EMITTER=turbo" "in.ir"
case_ spv-noargs spirv-emit "@cxx-fresh"

# pathb-cil: usage, -c (one fragment), the link and its settings, the C dialect, and the failures of each step
PC="MRB=@FAKE@/mruby"
case_ pc-usage pathb-cil "$PC"
case_ pc-c-one pathb-cil "$PC" -c -o "@TREE@/out/a.json" work/a.cpp
case_ pc-c-two pathb-cil "$PC" -c work/a.cpp work/b.c
case_ pc-link pathb-cil "$PC" -o "@TREE@/out/prog" -std=c++17 -Iinc -DX=1 -Uy work/a.cpp work/b.c
case_ pc-link-env pathb-cil "$PC ILASM=/opt/ilasm CC=clang NFCXX_KEEP_IL=1" work/a.cpp
case_ pc-link-defaults pathb-cil "$PC ILASM= CC= NFCXX_KEEP_IL=" work/a.cpp
case_ pc-c-std pathb-cil "$PC" -std=c17 work/b.c
case_ pc-name pathb-cil "$PC" -c -o "@TREE@/out/n.json" "work/my file+x.cpp"
case_ pc-missing-input pathb-cil "$PC" work/none.cpp
case_ pc-dump-fails pathb-cil "$PC FAKE_FAIL_NAME=pathb-dump.rb FAKE_FAIL_RC=1 FAKE_ERR=dump-broke" work/a.cpp
case_ pc-emit-fails pathb-cil "$PC FAKE_FAIL_NAME=mruby FAKE_FAIL_RC=3" work/a.cpp
case_ pc-setup pathb-cil "" -c -o "@TREE@/out/s.json" work/a.cpp
case_ pc-setup-fails pathb-cil "FAKE_SETUP_RC=9" -c -o "@TREE@/out/t.json" work/a.cpp
case_ pc-dash-o pathb-cil "$PC" work/a.cpp -o

echo "helpers: $pass passed, $fail failed"
[ $fail = 0 ]
