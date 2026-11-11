#!/usr/bin/env bash
# Internal parallel worker; deliberately never executes unreviewed examples.
set -euo pipefail
task=$1; out=$2; routes=$3; limit=$4
IFS=$'\t' read -r suite id page std source < "$task"
dir="$out/$id"; mkdir -p "$dir"
rm -f "$dir/result.tsv.tmp"
for route in host $routes; do
  compiler=$SURVEY_ROOT/nfcxx; flags=("--backend=$route" -c)
  if [ "$route" = host ]; then compiler=${HOST_CXX:-g++}; flags=(-fsyntax-only); fi
  if [ -n "${SURVEY_INCLUDE:-}" ]; then flags+=(-I "$SURVEY_INCLUDE"); fi
  rc=0
  env NFCXX_PATH=a NFCXX_BACKEND=qbe timeout -k 2 "$limit" "$compiler" "${flags[@]}" \
    "-std=$std" -pthread "$source" -o "$dir/$route.o" > "$dir/$route.log" 2>&1 || rc=$?
  status=accepted
  case $rc in
    0) ;;
    124|137) status=timeout ;;
    125|126|127) status=infrastructure-error ;;
    *) if [ "$rc" -gt 128 ]; then status=crash; else status=rejected; fi ;;
  esac
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$suite" "$id" "$page" "$std" "$route" "$status" "$rc" >> "$dir/result.tsv.tmp"
done
mv "$dir/result.tsv.tmp" "$dir/result.tsv"
rm -f "$dir/"*.o "$dir/"*.ii "$dir/"*.ti
