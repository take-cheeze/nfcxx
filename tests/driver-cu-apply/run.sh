#!/bin/bash
# scripts/nfcxx-cu-apply.rb plan must leave srcs, files, cflags, cuda_opts and preinc as the bash apply of cu_prepare (verbatim
# below) leaves them, for each reply (groups, copies, refusals, a missing end marker) and array state.
#   bash tests/driver-cu-apply/run.sh
here=$(cd "$(dirname "$0")" && pwd -P); repo=$(cd "$here/../.." && pwd -P)
t=$(mktemp -d); trap 'rm -rf "$t"' EXIT
# each reply is a file of NUL-terminated records (a bash string would lose the NULs): the records are the arguments
mkreply() { local f="$t/reply.$1"; shift; : > "$f"; for r in "$@"; do printf '%s\0' "$r" >> "$f"; done; echo "$f"; }
replies=(
  "$(mkreply a kcopies vb.cu z)"
  "$(mkreply b ksdirs /x/a /y/b kcopies /tmp/a.copy /tmp/b.copy kcuda -DQ=1 kpreinc inc.h z)"
  "$(mkreply c ksdirs /x kcopies /c.cu z)"
  "$(mkreply d kcopies c1 kcopies c2 z)"
  "$(mkreply e "xNo good: input" z)"
  "$(mkreply f kcopies vb.cu)"
  "$(mkreply g ksdirs /d kcopies vz.cu kcuda -O2 -O3 z)"
  "$(mkreply h zz)"
)
inputs_sets=("a.cu" "a.cu b.cu" "a.cu")
srcs_sets=("a.cu x.cpp" "a.cu a.cu" "")
files_sets=("a.cu -c" "a.cu b.cu a.cu" "")
pass=0; fail=0
for r in "${replies[@]}"; do for k in 0 1 2; do
  inputs=${inputs_sets[$k]}; srcs_s=${srcs_sets[$k]}; files_s=${files_sets[$k]}
  # the bash, verbatim: the apply loop of cu_prepare with its arrays set from the case
  want=$( cu_inputs=($inputs); srcs=($srcs_s); files=($files_s); cflags=(-O); cuda_opts=(); preinc=()
    cu_sdirs=(); cu_copies=(); cu_cuda=(); cu_pre=(); done=0
    outf=$r
    while IFS= read -r -d '' rec; do
      case $rec in
        k*) group=${rec:1} ;;
        v*)
          case $group in
            sdirs) cu_sdirs+=("${rec:1}") ;;
            copies) cu_copies+=("${rec:1}") ;;
            cuda) cu_cuda+=("${rec:1}") ;;
            preinc) cu_pre+=("${rec:1}") ;;
          esac ;;
        x*) printf '%s\n' "${rec:1}" >&2; exit 2 ;;
        z) done=1 ;;
      esac
    done < "$outf"
    [ $done = 1 ] || { echo "nfcxx: scripts/nfcxx-cuda-device.rb stopped before its end (the .cu inputs are incomplete)" >&2; exit 1; }
    for idx in "${!cu_inputs[@]}"; do
      src=${cu_inputs[$idx]}; copy=${cu_copies[$idx]}
      cflags+=("-I${cu_sdirs[$idx]}"); files+=("-I${cu_sdirs[$idx]}")
      for i in "${!srcs[@]}"; do if [ "${srcs[$i]}" = "$src" ]; then srcs[$i]=$copy; fi; done
      for i in "${!files[@]}"; do if [ "${files[$i]}" = "$src" ]; then files[$i]=$copy; fi; done
    done
    cuda_opts=(${cu_cuda[@]+"${cu_cuda[@]}"}); preinc=(${cu_pre[@]+"${cu_pre[@]}"})
    printf 'srcs=(%s)\nfiles=(%s)\ncflags=(%s)\ncuda_opts=(%s)\npreinc=(%s)\n' "${srcs[*]-}" "${files[*]-}" "${cflags[*]-}" "${cuda_opts[*]-}" "${preinc[*]-}" )
  wrc=$?
  got=$( inputs_arr=($inputs); srcs_arr=($srcs_s); files_arr=($files_s)
    j_in=$(IFS=$'\x1f'; echo "${inputs_arr[*]-}"); j_src=$(IFS=$'\x1f'; echo "${srcs_arr[*]-}"); j_files=$(IFS=$'\x1f'; echo "${files_arr[*]-}")
    cu_sh=$(ruby "$repo/scripts/nfcxx-cu-apply.rb" plan inputs="$j_in" srcs="$j_src" files="$j_files" cflags=-O < "$r" 2>"$t/g.err"); s=$?
    [ $s = 0 ] && { eval "$cu_sh"; printf 'srcs=(%s)\nfiles=(%s)\ncflags=(%s)\ncuda_opts=(%s)\npreinc=(%s)\n' "${srcs[*]-}" "${files[*]-}" "${cflags[*]-}" "${cuda_opts[*]-}" "${preinc[*]-}"; }; exit $s )
  grc=$?
  if [ "$want" = "$got" ] && [ "$wrc" = "$grc" ]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL reply=$(basename "$r") case=$k"; echo "  bash ($wrc): $want"; echo "  ruby ($grc): $got"; fi
done; done
echo "driver-cu-apply: $pass passed, $fail failed"
[ $fail = 0 ]
