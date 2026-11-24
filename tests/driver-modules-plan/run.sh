#!/bin/bash
# Golden tests of nfcxx's C++ modules block (docs/notes/modules.md), planned by scripts/nfcxx-modules-plan.rb.
#
# Part 1: each case of cases.txt runs ./nfcxx in a fresh directory holding the fixtures below, and its stdout, stderr and status
# are compared with golden/NAME.{out,err,status}. The goldens of part 1 were recorded from origin/main, before the block moved
# to the planner, and the same goldens must match after it.
#
# Part 2: the planner's own answers. The state is written by the body's own state_put and modules_plan_input (extracted from the
# body, so the records are the bash's encoding), the planner runs on it, and its reply is decoded. A link runs the module build,
# which here is a stub (its log and its status are the test's), so the build's status comes back in the reply. The goldens of
# part 2 (golden/plan/) were recorded from the planner; they are new, so they are checked by hand when they are recorded.
#
#   bash tests/driver-modules-plan/run.sh           compare with the goldens
#   bash tests/driver-modules-plan/run.sh record    write the goldens (only when the output is known to be right)
set -u
here=$(cd "$(dirname "$0")" && pwd -P)
repo=$(cd "$here/../.." && pwd -P)
mode=${1:-check}
golden=$here/golden
work=$(mktemp -d); trap 'rm -rf "$work"' EXIT
mkdir -p "$work/tmp" "$golden/plan"
# EDG: a stub eccp, so the driver's EDG check passes whether or not the repository has an EDG build (the goldens assume it passes)
mkdir -p "$work/edg/bin" && printf '#!/bin/sh\nexit 1\n' > "$work/edg/bin/eccp" && chmod +x "$work/edg/bin/eccp"
pass=0; fail=0

# fixtures DIR: the sources the cases name
fixtures() {
  local d=$1
  printf 'export module geom;\nexport int twice(int x) { return 2 * x; }\n' > "$d/geom.cppm"
  printf 'import geom;\nint main() { return twice(21) == 42 ? 0 : 1; }\n' > "$d/main.cpp"
  printf 'export module a;\nexport int fa() { return 1; }\n' > "$d/a.cppm"
  printf 'export module b;\nexport int fb() { return 2; }\n' > "$d/b.cppm"
  printf 'export module geom:part;\n' > "$d/part.cppm"
  printf 'import <vector>;\nint main() { return 0; }\n' > "$d/hdr.cpp"
  printf 'import std;\nint main() { return 0; }\n' > "$d/std.cpp"
  printf 'int c(void) { return 0; }\n' > "$d/c.c"
  printf 'export import base;\n' > "$d/reexport.cppm"
  printf 'int main() { return 0; }\n' > "$d/plain.cpp"
}

# normalize FILE: the work directory and the repository as placeholders
normalize() { sed -e "s#$work#WORK#g" -e "s#$repo#ROOT#g" "$1"; }

# compare_or_record KIND NAME: the normalized files of a case (KIND: the table's, or the plan's) against their goldens
compare_or_record() {
  local kind=$1 name=$2 dir ext ok=1 why=""
  dir=$golden; [ "$kind" = plan ] && dir=$golden/plan
  for ext in out err status; do normalize "$work/$kind-$name.$ext" > "$work/$kind-$name.$ext.n"; done
  if [ "$mode" = record ]; then
    for ext in out err status; do cp "$work/$kind-$name.$ext.n" "$dir/$name.$ext"; done
    echo "recorded $kind $name (status $(cat "$dir/$name.status"))"
    return 0
  fi
  for ext in out err status; do
    cmp -s "$dir/$name.$ext" "$work/$kind-$name.$ext.n" || { ok=0; why+=" $ext"; }
  done
  if [ $ok = 1 ]; then pass=$((pass + 1)); echo "ok   $kind $name (status $(cat "$dir/$name.status"))"
  else
    fail=$((fail + 1)); echo "FAIL $kind $name ($why )"
    for ext in out err status; do diff "$dir/$name.$ext" "$work/$kind-$name.$ext.n" | sed "s/^/    $ext: /" | head -20; done
  fi
}

# ---- part 1: ./nfcxx on the argument lists of cases.txt
while IFS=$'\t' read -r name args; do
  case $name in ""|\#*) continue ;; esac
  d=$work/run/$name; mkdir -p "$d"; fixtures "$d"
  # the environment is the driver's own: PATH and HOME, with a temporary directory of the test's own
  (cd "$d" && env -i PATH="$PATH" HOME="$HOME" TMPDIR="$work/tmp" EDG_BUILD="$work/edg" "$repo/nfcxx" $args >"$work/table-$name.out" 2>"$work/table-$name.err"; echo $? > "$work/table-$name.status")
  compare_or_record table "$name"
done < "$here/cases.txt"

# ---- part 2: the planner on the body's state
# the body's state encoding and the state writer, extracted from the body (they are not separate files)
state_fns=$(sed -n '/^state_put() {/,/^}/p; /^modules_plan_input() {/,/^}/p' "$repo/tests/driver-body/nfcxx-bash")
[ -n "$state_fns" ] || { echo "driver-modules-plan: the body has no state_put or modules_plan_input" >&2; exit 2; }

# a stub root: its nfcxx-modules.rb logs its arguments and exits with the status in $stub/status; the scanner is the repository's
stub=$work/stub; mkdir -p "$stub/scripts"
ln -s "$repo/scripts/nfcxx-modscan.rb" "$stub/scripts/nfcxx-modscan.rb"
cat > "$stub/scripts/nfcxx-modules.rb" <<'STUB'
#!/usr/bin/env ruby
# the build's stand-in: logs its argument list, exits with the status the test gave
File.open(File.join(__dir__, "..", "log"), "a") { |f| f.puts ARGV.inspect }
exit File.read(File.join(__dir__, "..", "status")).to_i
STUB

# plan NAME DIR [root=ROOT] ...: the caller's variables (root, out, moddir, std, emit_c, compile_only, cfiles, srcs, nfcxx_argv)
# are written as the state, the planner runs in DIR, and its status, stdout, stderr and reply (decoded) are the case's files
plan() {
  local name=$1 dir=$2 f=$work/plan-$1
  rm -f "$f.reply" "$stub/log"
  (
    cd "$dir" && eval "$state_fns" && (root=$repo; modules_plan_input) > "$f.state" || exit 1   # the state step runs from the repository (its formatter is scripts/nfcxx-modules-state.rb); the planner keeps the case's root
    env -i PATH="$PATH" HOME="$HOME" TMPDIR="$work/tmp" ruby "$repo/scripts/nfcxx-modules-plan.rb" \
      "$f.state" "$f.reply" >"$f.stdout" 2>"$f.err"
    echo $? > "$f.status"
  )
  # the case's stdout: the reply decoded (its groups, one record per line), then the build stub's log, then the planner's stdout
  { [ -f "$f.reply" ] && tr '\0' '\n' < "$f.reply"; [ -f "$stub/log" ] && cat "$stub/log"; cat "$f.stdout"; } > "$f.out"
  [ -f "$f.status" ] || echo "no status" > "$f.status"
  compare_or_record plan "$name"
}
# case_dir NAME: a fresh directory with the fixtures, for one planner case (each case sets every variable the state reads)
case_dir() { local d=$work/plan-cases/$1; mkdir -p "$d"; fixtures "$d"; echo "$d"; }

d=$(case_dir compile-module)
root=$repo out=build/geom.o moddir= std=--c++23 emit_c=0 compile_only=1 cfiles=() srcs=(geom.cppm) nfcxx_argv=(-c geom.cppm -o build/geom.o)
plan compile-module "$d"
d=$(case_dir compile-importer)
root=$repo out=p.o moddir= std=--c++23 emit_c=0 compile_only=1 cfiles=() srcs=(main.cpp) nfcxx_argv=(-c main.cpp -o p.o)
plan compile-importer "$d"
d=$(case_dir compile-no-module)
root=$repo out=p.o moddir= std=--c++23 emit_c=0 compile_only=1 cfiles=() srcs=(plain.cpp) nfcxx_argv=(-c plain.cpp -o p.o)
plan compile-no-module "$d"
d=$(case_dir compile-moddir)
root=$repo out=build/geom.o moddir=mods std=--c++23 emit_c=0 compile_only=1 cfiles=() srcs=(geom.cppm) nfcxx_argv=(-c --module-dir=mods geom.cppm -o build/geom.o)
plan compile-moddir "$d"
d=$(case_dir compile-reexport)
root=$repo out=r.o moddir= std=--c++23 emit_c=0 compile_only=1 cfiles=() srcs=(reexport.cppm) nfcxx_argv=(-c reexport.cppm -o r.o)
plan compile-reexport "$d"
d=$(case_dir compile-mkdir-fails)
root=$repo out=x.o moddir=/proc/nfcxx-no-such/mods std=--c++23 emit_c=0 compile_only=1 cfiles=() srcs=(geom.cppm) nfcxx_argv=(-c geom.cppm -o x.o)
plan compile-mkdir-fails "$d"
d=$(case_dir refuse-std)
root=$repo out=g.o moddir= std=--c++17 emit_c=0 compile_only=1 cfiles=() srcs=(geom.cppm) nfcxx_argv=(-std=c++17 -c geom.cppm -o g.o)
plan refuse-std "$d"
d=$(case_dir refuse-emit-c)
root=$repo out=g.o moddir= std=--c++23 emit_c=1 compile_only=1 cfiles=() srcs=(geom.cppm) nfcxx_argv=(--emit-c -c geom.cppm -o g.o)
plan refuse-emit-c "$d"
d=$(case_dir refuse-c-source)
root=$repo out=prog moddir= std=--c++23 emit_c=0 compile_only=0 cfiles=(c.c) srcs=(geom.cppm c.c) nfcxx_argv=(geom.cppm c.c -o prog)
plan refuse-c-source "$d"
d=$(case_dir refuse-two-sources)
root=$repo out=x.o moddir= std=--c++23 emit_c=0 compile_only=1 cfiles=() srcs=(a.cppm b.cppm) nfcxx_argv=(-c a.cppm b.cppm -o x.o)
plan refuse-two-sources "$d"
d=$(case_dir refuse-partition)
root=$repo out=p.o moddir= std=--c++23 emit_c=0 compile_only=1 cfiles=() srcs=(part.cppm) nfcxx_argv=(-c part.cppm -o p.o)
plan refuse-partition "$d"
d=$(case_dir link-no-module)
root=$repo out=prog moddir= std=--c++23 emit_c=0 compile_only=0 cfiles=() srcs=(plain.cpp) nfcxx_argv=(plain.cpp -o prog)
plan link-no-module "$d"
# the link: the stub build's answer is the reply's built group (0, then 7); its arguments are the build's
d=$(case_dir link-build-ok)
echo 0 > "$stub/status"
root=$stub out=prog moddir= std=--c++23 emit_c=0 compile_only=0 cfiles=() srcs=(geom.cppm main.cpp) nfcxx_argv=(geom.cppm main.cpp -o prog)
plan link-build-ok "$d"
d=$(case_dir link-build-fails)
echo 7 > "$stub/status"
root=$stub out=prog moddir= std=--c++23 emit_c=0 compile_only=0 cfiles=() srcs=(geom.cppm main.cpp) nfcxx_argv=(geom.cppm main.cpp -o prog)
plan link-build-fails "$d"
# an argument with a space and an empty argument reach the build as they were given (the state keeps them)
d=$(case_dir link-build-args)
echo 0 > "$stub/status"
root=$stub out=prog moddir=mods std=--c++23 emit_c=0 compile_only=0 cfiles=() srcs=(geom.cppm) nfcxx_argv=(-DNAME=a\ b "" geom.cppm -o prog)
plan link-build-args "$d"

if [ "$mode" = record ]; then echo "recorded the goldens"; exit 0; fi
echo "driver-modules-plan: $pass passed, $fail failed"
[ "$fail" = 0 ]
