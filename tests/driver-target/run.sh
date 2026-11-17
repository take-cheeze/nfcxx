#!/bin/bash
# scripts/nfcxx-target.rb plan must leave gnu_opts and EDG_CPFE_DEFAULT_OPTIONS as the bash --target block of nfcxx does (verbatim
# below), or the same refusal, for each target, freestanding and emit setting, EDG table, gnu_opts and prior export.
#   bash tests/driver-target/run.sh
here=$(cd "$(dirname "$0")" && pwd -P); repo=$(cd "$here/../.." && pwd -P)
t=$(mktemp -d); trap 'rm -rf "$t"' EXIT
export LC_ALL=C
root="$t/root"; mkdir -p "$root/build/edg-base/lib_linux_x86_64" "$root/build/edg-base/lib_linux_aarch64" "$t/root/scripts"
mkdir -p "$t/nolib/lib_linux_x86_64"
bash_block() {   # the driver's block, verbatim (the gnu_opts array and the target set by the caller)
if [ -n "$target" ] && [ "$target" != linux_k1om ]; then
  [ $freestanding = 1 ] || { echo "nfcxx: --target needs --freestanding (the host's library headers are the host target's)" >&2; exit 2; }
  [ $emit_c = 1 ] || { echo "nfcxx: --target needs --emit-c (the generated C is for the target; compile it with a cross compiler)" >&2; exit 2; }
  tbase=${EDG_BASE:-$root/build/edg-base}
  [ -d "$tbase/lib_$target" ] || { echo "nfcxx: no EDG target '$target' in $tbase (lib_* tables: $(cd "$tbase" && ls -d lib_* | sed 's/^lib_//' | tr '\n' ' '))" >&2; exit 2; }
  gnu_opts+=(--target "$target")
  case $target in linux_aarch64|linux_armv7|linux_riscv32|linux_riscv64) gnu_opts+=(--unsigned_chars) ;; esac
fi
[ ${#gnu_opts[@]} -gt 0 ] && export EDG_CPFE_DEFAULT_OPTIONS="${gnu_opts[*]} ${EDG_CPFE_DEFAULT_OPTIONS:-}"
}
# the state after the block (in the same shell, so the exports are seen), or the refusal's status
state() {   # state ENGINE: ENGINE bash runs the block; ruby evals the plan
  local out rc
  if [ "$1" = bash ]; then
    # the block's last line returns 1 when there is no target (the driver does not test it): only a refusal (exit 2) ends the state
    out=$( bash_block 2>"$t/err"; s=$?; [ $s -eq 2 ] && exit 2; printf 'gnu=[%s] export=[%s]' "${gnu_opts[*]-}" "$(printenv EDG_CPFE_DEFAULT_OPTIONS || true)" ); rc=$?
  else
    out=$( p=$(ruby "$repo/scripts/nfcxx-target.rb" plan target="$target" freestanding="$freestanding" emit_c="$emit_c" root="$root" gnu_opts="$(IFS=$'\x1f'; echo "${gnu_opts[*]-}")" 2>"$t/err") && { [ -z "$p" ] || eval "$p"; } && printf 'gnu=[%s] export=[%s]' "${gnu_opts[*]-}" "$(printenv EDG_CPFE_DEFAULT_OPTIONS || true)" ); rc=$?
  fi
  printf 'status=%s %s | %s\n' "$rc" "$out" "$(cat "$t/err")"
}
pass=0; fail=0
for target in "" linux_aarch64 bogus linux_k1om; do for freestanding in 0 1; do for emit_c in 0 1; do for table in yes no; do for pre in "" "--gnu_version=130000"; do for prior in unset "-old"; do
  if [ $table = yes ]; then export EDG_BASE="$root/build/edg-base"; else export EDG_BASE="$t/nolib"; fi
  if [ $prior = unset ]; then unset EDG_CPFE_DEFAULT_OPTIONS; else export EDG_CPFE_DEFAULT_OPTIONS="$prior"; fi
  want=$( gnu_opts=(); [ -n "$pre" ] && gnu_opts=("$pre"); state bash )
  got=$( gnu_opts=(); [ -n "$pre" ] && gnu_opts=("$pre"); state ruby )
  if [ "$want" = "$got" ]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL target=[$target] fs=$freestanding emit=$emit_c table=$table pre=[$pre] prior=$prior"; echo "  bash: $want"; echo "  ruby: $got"; fi
done; done; done; done; done; done
echo "driver-target: $pass passed, $fail failed"
[ $fail = 0 ]
