# Differential harness for a shell script and its Ruby port. Sourced by tests/rb-migration/<name>/run.sh, which sets
# NAME (the script's basename) and defines populate DIR, writing the fixture into the tree DIR (the tree's scripts/
# directory holds the two scripts and any stubs the fixture needs; populate runs for both trees).
#
# rb_case LABEL SETUP ARGS...: runs scripts/NAME.sh (the original, read from git at ORIG_REV, so the test still runs
# after the .sh is removed) and scripts/NAME.rb in two identical trees, from the tree's root, with the same ARGS.
# SETUP is shell run in each tree's root first ("" for none). The two runs must agree on stdout, stderr, exit status
# and the files they leave in the tree (scripts/ excluded). The one allowed difference: the bash side's NAME.sh in
# diagnostics and generated text is read as NAME.rb, since the Ruby port's name is the one that stays.
#
# Stubs for external commands go in $RB_WORK/bin (on PATH) or in the tree's scripts/ when the script runs them by path.

ORIG_REV=${ORIG_REV:-aba0ee24a91b8df777c38501ec80b4489dc13f00}
RB_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
RB_WORK=$(mktemp -d)
trap 'rm -rf "$RB_WORK"' EXIT
RB_N=0; RB_PASS=0; RB_FAIL=0
mkdir -p "$RB_WORK/bin"
export PATH="$RB_WORK/bin:$PATH"
if ! git -C "$RB_ROOT" show "$ORIG_REV:scripts/$NAME.sh" > "$RB_WORK/orig-$NAME.sh" 2>/dev/null; then
  echo "$NAME: cannot read scripts/$NAME.sh at $ORIG_REV" >&2
  exit 1
fi

# rb_stub NAME BODY: an executable stub in $RB_WORK/bin.
rb_stub() {
  printf '%s\n' "#!/usr/bin/env bash" "$2" > "$RB_WORK/bin/$1"
  chmod +x "$RB_WORK/bin/$1"
}

# rb_tree DIR IMPL: a tree with scripts/NAME.{sh,rb} and the fixture.
rb_tree() {
  mkdir -p "$1/scripts"
  if [ "$2" = sh ]; then cp "$RB_WORK/orig-$NAME.sh" "$1/scripts/$NAME.sh"
  else cp "$RB_ROOT/scripts/$NAME.rb" "$1/scripts/$NAME.rb"; fi
  chmod +x "$1/scripts/$NAME.$2"
  populate "$1"
}

# rb_files DIR: the files the run left in the tree, with their contents (scripts/ excluded).
rb_files() {
  (cd "$1" && find . -path ./scripts -prune -o -type f -print | LC_ALL=C sort | while IFS= read -r f; do
    echo "== $f"; cat "$f"; done)
}

rb_case() {
  local label=$1 setup=$2
  shift 2
  RB_N=$((RB_N + 1))
  local d="$RB_WORK/case$RB_N" a b sa sb
  a="$d/sh"; b="$d/rb"
  rb_tree "$a" sh
  rb_tree "$b" rb
  if [ -n "$setup" ]; then
    (cd "$a" && eval "$setup")
    (cd "$b" && eval "$setup")
  fi
  (cd "$a" && "$a/scripts/$NAME.sh" "$@") > "$d.sh.out" 2> "$d.sh.err"; sa=$?
  (cd "$b" && "$b/scripts/$NAME.rb" "$@") > "$d.rb.out" 2> "$d.rb.err"; sb=$?
  # Normalise the trees' paths, and the bash side's script name.
  sed -e "s|$a|TREE|g" -e "s|$NAME\.sh|$NAME.rb|g" "$d.sh.out" > "$d.sh.out.n"
  sed -e "s|$a|TREE|g" -e "s|$NAME\.sh|$NAME.rb|g" "$d.sh.err" > "$d.sh.err.n"
  sed -e "s|$b|TREE|g" "$d.rb.out" > "$d.rb.out.n"
  sed -e "s|$b|TREE|g" "$d.rb.err" > "$d.rb.err.n"
  rb_files "$a" | sed -e "s|$a|TREE|g" -e "s|$NAME\.sh|$NAME.rb|g" > "$d.sh.files"
  rb_files "$b" | sed -e "s|$b|TREE|g" > "$d.rb.files"
  if [ -n "${RB_VERBOSE:-}" ]; then
    echo "case $RB_N $label: status $sa/$sb, stdout $(head -c 120 "$d.rb.out" | tr '\n' '|'), stderr $(head -c 120 "$d.rb.err" | tr '\n' '|')"
  fi
  local bad=""
  cmp -s "$d.sh.out.n" "$d.rb.out.n" || bad="$bad stdout"
  # RB_IGNORE_STDERR=1 for a case whose stderr is the shell's own diagnostic (e.g. "command not found").
  [ -n "${RB_IGNORE_STDERR:-}" ] || cmp -s "$d.sh.err.n" "$d.rb.err.n" || bad="$bad stderr"
  [ "$sa" = "$sb" ] || bad="$bad status($sa/$sb)"
  cmp -s "$d.sh.files" "$d.rb.files" || bad="$bad files"
  if [ -z "$bad" ]; then
    RB_PASS=$((RB_PASS + 1))
  else
    RB_FAIL=$((RB_FAIL + 1))
    echo "FAIL $label:$bad"
    for k in out err; do
      [ "$k" = err ] && [ -n "${RB_IGNORE_STDERR:-}" ] && continue
      if ! cmp -s "$d.sh.$k.n" "$d.rb.$k.n"; then
        echo "  $k (bash < ruby >):"; diff "$d.sh.$k.n" "$d.rb.$k.n" | sed 's/^/    /' | head -20
      fi
    done
    [ "$sa" = "$sb" ] || echo "  status: bash $sa, ruby $sb"
    if ! cmp -s "$d.sh.files" "$d.rb.files"; then
      diff "$d.sh.files" "$d.rb.files" | sed 's/^/    /' | head -20
    fi
  fi
}

rb_done() {
  echo "$NAME: $RB_N cases, $RB_PASS passed, $RB_FAIL failed"
  [ "$RB_FAIL" -eq 0 ]
}
