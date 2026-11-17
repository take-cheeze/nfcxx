#!/bin/bash
# scripts/nfcxx-cu-apply.rb plan kind=cpp2 must leave srcs, files and cflags as the bash apply of cpp2_prepare (verbatim below)
# leaves them: each input's -I directory, the copies in place of the inputs, and the cppfront include last. Replies are files of
# NUL-terminated records; the refusal and the missing end marker end with their statuses.   bash tests/driver-cpp2-apply/run.sh
here=$(cd "$(dirname "$0")" && pwd -P); repo=$(cd "$here/../.." && pwd -P)
t=$(mktemp -d); trap 'rm -rf "$t"' EXIT
mkreply() { local f="$t/reply.$1"; shift; : > "$f"; for r in "$@"; do printf '%s\0' "$r" >> "$f"; done; echo "$f"; }
replies=(
  "$(mkreply a ksdirs /s/a kcopies /t/a.cpp z)"
  "$(mkreply b ksdirs /s kcopies /t/b.cpp ksdirs /s2 kcopies /t/c.cpp z)"
  "$(mkreply c kcopies /t/q.cpp z)"
  "$(mkreply d "xcpp2 failed" z)"
  "$(mkreply e ksdirs /s kcopies /t/a.cpp)"
)
inputs_sets=("a.cpp2" "a.cpp2 b.cpp2" "a.cpp2")
srcs_sets=("a.cpp2 x.cpp" "a.cpp2 a.cpp2" "")
files_sets=("a.cpp2 -c" "a.cpp2 b.cpp2" "")
pass=0; fail=0
for r in "${replies[@]}"; do for k in 0 1 2; do
  inputs=${inputs_sets[$k]}; srcs_s=${srcs_sets[$k]}; files_s=${files_sets[$k]}
  want=$( cpp2_inputs=($inputs); srcs=($srcs_s); files=($files_s); cflags=(-O)
    cppfront=/cf; cpp2_sdirs=(); cpp2_copies=(); done=0; outf=$r
    while IFS= read -r -d '' rec; do
      case $rec in
        k*) group=${rec:1} ;;
        v*)
          case $group in
            sdirs) cpp2_sdirs+=("${rec:1}") ;;
            copies) cpp2_copies+=("${rec:1}") ;;
          esac ;;
        x*) printf '%s\n' "${rec:1}" >&2; exit 2 ;;
        z) done=1 ;;
      esac
    done < "$outf"
    [ $done = 1 ] || { echo "nfcxx: scripts/nfcxx-cpp2.rb stopped before its end (the translations are incomplete)" >&2; exit 1; }
    for idx in "${!cpp2_inputs[@]}"; do
      src=${cpp2_inputs[$idx]}; copy=${cpp2_copies[$idx]}
      cflags+=("-I${cpp2_sdirs[$idx]}"); files+=("-I${cpp2_sdirs[$idx]}")
      for i in "${!srcs[@]}"; do if [ "${srcs[$i]}" = "$src" ]; then srcs[$i]=$copy; fi; done
      for i in "${!files[@]}"; do if [ "${files[$i]}" = "$src" ]; then files[$i]=$copy; fi; done
    done
    cflags+=("-I$cppfront/include"); files+=("-I$cppfront/include")
    printf 'srcs=(%s)\nfiles=(%s)\ncflags=(%s)\n' "${srcs[*]-}" "${files[*]-}" "${cflags[*]-}" ); wrc=$?
  got=$( inputs_arr=($inputs); srcs_arr=($srcs_s); files_arr=($files_s)
    j_in=$(IFS=$'\x1f'; echo "${inputs_arr[*]-}"); j_src=$(IFS=$'\x1f'; echo "${srcs_arr[*]-}"); j_files=$(IFS=$'\x1f'; echo "${files_arr[*]-}")
    cu_sh=$(ruby "$repo/scripts/nfcxx-cu-apply.rb" plan kind=cpp2 cppfront=/cf inputs="$j_in" srcs="$j_src" files="$j_files" cflags=-O < "$r" 2>"$t/g.err"); s=$?
    [ $s = 0 ] && { eval "$cu_sh"; printf 'srcs=(%s)\nfiles=(%s)\ncflags=(%s)\n' "${srcs[*]-}" "${files[*]-}" "${cflags[*]-}"; }; exit $s )
  grc=$?
  if [ "$want" = "$got" ] && [ "$wrc" = "$grc" ]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL reply=$(basename "$r") case=$k"; echo "  bash ($wrc): $want"; echo "  ruby ($grc): $got"; fi
done; done
echo "driver-cpp2-apply: $pass passed, $fail failed"
[ $fail = 0 ]
