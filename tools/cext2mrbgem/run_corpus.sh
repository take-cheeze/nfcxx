#!/bin/bash
# Converts every gem of the CRuby C-extension corpus and reports, per gem, the refusals that are not classified as stuck
# (OPEN) and those that are (STUCK). usage: run_corpus.sh CORPUS_SRC OUT_DIR
#   CORPUS_SRC: a directory holding one extension per gem, as src/<gem>-<version>/ext/<gem>/extconf.rb
#   OUT_DIR:    where each gem's converted output goes (OUT_DIR/<gem>; a gem with several extensions goes to OUT_DIR/<gem>-<extension>,
#               e.g. json-parser and json-generator)
# The per-gem options are in corpus_flags.json next to this script.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$HERE/../.." && pwd)
SRC=${1:?usage: run_corpus.sh CORPUS_SRC OUT_DIR}
OUT=${2:?usage: run_corpus.sh CORPUS_SRC OUT_DIR}
# the mruby headers of the repo's own 3rd/mruby fork tree (the include dirs its source has; overridable by env)
export NFCX_MRUBY_INCLUDE=${NFCX_MRUBY_INCLUDE:-$REPO/3rd/mruby/include:$REPO/3rd/mruby/mrbgems/mruby-encoding/include:$REPO/3rd/mruby/mrbgems/mruby-time/include:$REPO/3rd/mruby/mrbgems/mruby-marshal/include:$REPO/3rd/mruby/mrbgems/mruby-require/include}
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
to=0; ts=0
for extconf in $(find "$SRC" -type f -name extconf.rb -not -path '*/test/*' | sort); do
  ext=$(dirname "$extconf")
  # the gem name comes from its versioned root directory (name-VERSION, the nearest ancestor of the extension with a version suffix)
  groot=$ext
  while [ "$groot" != / ] && ! basename "$groot" | grep -q -- '-[0-9][0-9.]*$'; do groot=$(dirname "$groot"); done
  if [ "$groot" = / ]; then groot=$(dirname "$(dirname "$ext")"); fi
  n=$(basename "$groot" | sed 's/-[0-9][0-9.]*$//')
  # a gem with several extensions (json's parser and generator) names each by its extension directory, one output each
  if [ "$(find "$groot" -type f -name extconf.rb -not -path '*/test/*' | wc -l)" -gt 1 ]; then
    n="$n-$(basename "$ext")"
  fi
  # per-gem options, read from corpus_flags.json (none for a gem not listed)
  flags=()
  while IFS= read -r f; do [ -n "$f" ] && flags+=("$f"); done < <(python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print("\n".join(d.get(sys.argv[2], [])))' "$HERE/corpus_flags.json" "$n")
  if [ "$n" = oj ]; then
    # oj: trace.c's static fill_indent is renamed in a copy (a name clash with dump.h's inline fill_indent)
    root=$(dirname "$(dirname "$ext")")
    mkdir -p "$WORK/oj-src" && cp -r "$root/." "$WORK/oj-src/"
    sed -i 's/\bfill_indent\b/trace_fill_indent/g' "$WORK/oj-src/ext/oj/trace.c"
    ext="$WORK/oj-src/ext/oj"
  fi
  o="$OUT/$n"; rm -rf "$o"
  ruby "$REPO/tools/cext2mrbgem/convert_mrbgem.rb" --name "$n" --scanner auto "${flags[@]}" "$ext" "$o" >/dev/null 2>&1
  if [ ! -f "$o/REFUSALS.txt" ]; then
    # the converter did not finish (no REFUSALS.txt): a crash is an open problem, not a clean gem
    printf '%-14s CRASHED (no REFUSALS.txt)\n' "$n"; to=$((to+1)); continue
  fi
  all=$(grep -E '^[^ ]+:[0-9]+ ' "$o/REFUSALS.txt" 2>/dev/null)
  open=$(printf '%s\n' "$all" | grep -v '^$' | grep -cv 'stuck')
  stk=$(printf '%s\n' "$all" | grep -v '^$' | grep -c 'stuck')
  printf '%-14s open %-5s stuck %s\n' "$n" "$open" "$stk"
  to=$((to+open)); ts=$((ts+stk))
done
echo "OPEN $to STUCK $ts"
