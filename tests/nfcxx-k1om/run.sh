#!/bin/bash
# Compares scripts/nfcxx-k1om.rb (the port of nfcxx's --target=linux_k1om build) with nfcxx's bash, for each argument list of
# cases.txt.
#
# The oracle is the bash: a copy of nfcxx in a sandbox, run to its end, with the commands it could reach stubbed (stub.sh):
# gcc, cc, g++ (probes: GCC 13), cp, ninja, eccp and cpfe are logged, mktemp makes a directory. The k1om GCC is a script
# that logs its arguments. Everything else (rm, ls, sed, ...) runs for real. The bash runs under env -i with NFCXX_K1OM_ROOT
# set to the sandbox's k1om toolchain. The log is normalised: the sandbox's repository is ROOT, its work directory WORK,
# its k1om toolchain K1OM, its temporary directories TMP; the port's output is normalised the same way.
#
# The state of each case is set from its leading !TOKENS (cases.txt): the k1om GCC is removed (!nogcc), the k1om runtime
# (build/k1om/libC.a, !nolibc), the EDG driver (!noeccp) and the EDG runtime's per-thread EH marker (!ehtls). The port gets
# the same state as facts (FILE of scripts/nfcxx-k1om.rb).
#
# A case the port leaves unported (exit 3) is listed with its reason and not compared, except that the bash must not refuse
# it (status 2): a refusal the port missed is a failure. Every other case must print the same log lines and exit status as
# the bash (the stderr text is not compared). A refusal prints the lines the bash ran before it, then "STATUS 2".
#
#   bash tests/nfcxx-k1om/run.sh [CASES]     CASES defaults to tests/nfcxx-k1om/cases.txt
set -u
here=$(cd "$(dirname "$0")" && pwd -P)
repo=$(cd "$here/../.." && pwd -P)
cases=${1:-$here/cases.txt}
sb=$(mktemp -d)
trap 'rm -rf "$sb"' EXIT
root=$sb/root; work=$sb/work; bin=$sb/bin; tmp=$sb/tmp; k1om=$sb/k1om
mkdir -p "$root/build/edg/bin" "$root/build/edg-base/lib_linux_aarch64" "$root/build/edg-base/lib_win64" \
  "$root/build/k1om" "$bin" "$work" "$tmp" "$k1om/bin"
cp -r "$repo/scripts" "$root/scripts"
# the copy of nfcxx, unchanged
cp "$repo/nfcxx" "$root/nfcxx"
chmod +x "$root/nfcxx"
for c in gcc cc g++ cp mktemp ninja; do ln -s "$here/stub.sh" "$bin/$c"; done
ln -s "$here/stub.sh" "$bin/ld.mold"
# the repository's tool is built (ensure_tool finds it fresh: no ninja run); the sandbox has no tool sources
: > "$root/build/cuda-rewrite"; chmod +x "$root/build/cuda-rewrite"
ln -s "$here/stub.sh" "$root/build/edg/bin/eccp"
ln -s "$here/stub.sh" "$root/build/edg/bin/cpfe"
# the sources the cases name (empty: the gate reads no source)
for f in a.cc b.o c.c libq.a a.s; do : > "$work/$f"; done
# directories: inc and out exist; sy holds the oneAPI kernel header (the SYCL test of -c finds it, the source does not include sycl/)
mkdir -p "$work/inc" "$work/out" "$work/sy/sycl/detail"
: > "$work/sy/sycl/detail/kernel_desc.hpp"

# set_state TOKENS...: the files the case's tokens remove or restore
set_state() {
  local t
  for t in "$@"; do
    case $t in nogcc|nolibc|noeccp|ehtls) ;; *) echo "run.sh: unknown token !$t" >&2; exit 1 ;; esac
  done
  # the k1om GCC logs its arguments (NFCXX_STUB_LOG is inherited from the bash, through scripts/k1om-cc)
  if has nogcc; then rm -f "$k1om/bin/k1om-mpss-linux-gcc"; else
    printf '#!/bin/sh\necho "RUN k1om-gcc $*" >> "$NFCXX_STUB_LOG"\n' > "$k1om/bin/k1om-mpss-linux-gcc"; chmod +x "$k1om/bin/k1om-mpss-linux-gcc"; fi
  if has nolibc; then rm -f "$root/build/k1om/libC.a"; else : > "$root/build/k1om/libC.a"; fi
  if has noeccp; then rm -f "$root/build/edg/bin/eccp"; else ln -sf "$here/stub.sh" "$root/build/edg/bin/eccp"; fi
  if has ehtls; then : > "$root/build/edg/eh-tls"; else rm -f "$root/build/edg/eh-tls"; fi
}
# norm: the sandbox's names as placeholders (the log and the port's output)
norm() { sed -e "s#$tmp/[^/]*#TMP#g" -e "s#$work#WORK#g" -e "s#$root#ROOT#g" -e "s#$k1om#K1OM#g"; }
TOKENS=()
has() { case " ${TOKENS[*]} " in *" $1 "*) return 0 ;; esac; return 1; }

# write_facts: the facts the bash tests, read from the sandbox
write_facts() {
  {
    echo "root $root"; echo "cwd $work"; echo "k1om-root $k1om"
    if [ -x "$root/build/edg/bin/eccp" ]; then echo "eccp 1"; else echo "eccp 0"; fi
    if [ -x "$k1om/bin/k1om-mpss-linux-gcc" ]; then echo "k1om-gcc 1"; else echo "k1om-gcc 0"; fi
    if [ -f "$root/build/k1om/libC.a" ]; then echo "k1om-libc 1"; else echo "k1om-libc 0"; fi
    if [ -f "$root/build/edg/eh-tls" ]; then echo "eh-tls 1"; else echo "eh-tls 0"; fi
    for d in "$root"/build/edg-base/lib_*; do [ -d "$d" ] && echo "edg-table ${d##*/lib_}"; done
    # the directories under the work directory (abs_path resolves those that exist)
    while IFS= read -r d; do echo "dir ${d#./}"; done < <(cd "$work" && find . -mindepth 1 -type d)
    # the SYCL test's header, by its directory (the bash tests DIR/sycl/detail/kernel_desc.hpp with -f)
    while IFS= read -r f; do echo "sycl-header ${f%/sycl/detail/kernel_desc.hpp}"; done \
      < <(find "$work" -path '*/sycl/detail/kernel_desc.hpp' -type f)
    # the host probes: host_gnu_version and host_sys_includes of scripts/host-sys.sh, run as the bash runs them (the stub g++)
    hg=$(env -i PATH="$bin:/usr/bin:/bin" bash -c 'source "$1"; host_gnu_version' _ "$root/scripts/host-sys.sh" 2>/dev/null)
    echo "host-gnu $hg"
    env -i PATH="$bin:/usr/bin:/bin" bash -c 'source "$1"; host_sys_includes' _ "$root/scripts/host-sys.sh" 2>/dev/null |
      while IFS= read -r d; do [ -n "$d" ] && echo "host-include $d"; done
  } > "$sb/facts"
}

pass=0; fail=0; unp=0; unported_list=""; failed_list=""
while IFS= read -r line; do
  case $line in ""|"#"*) continue ;; esac
  read -r -a words <<< "$line"
  TOKENS=()
  while [ ${#words[@]} -gt 0 ] && [[ ${words[0]} == !* ]]; do
    TOKENS+=("${words[0]#!}"); words=("${words[@]:1}")
  done
  args=("${words[@]}")
  set_state "${TOKENS[@]}"
  write_facts
  port_raw=$(ruby "$repo/scripts/nfcxx-k1om.rb" --facts="$sb/facts" "${args[@]}" 2>"$sb/perr"); rc=$?
  port_out=$(printf '%s\n' "$port_raw" | norm)
  : > "$sb/stublog"
  (cd "$work" && env -i PATH="$bin:/usr/bin:/bin" NFCXX_STUB_LOG="$sb/stublog" NFCXX_STUB_TMP="$tmp" \
     NFCXX_K1OM_ROOT="$k1om" bash "$root/nfcxx" "${args[@]}" >/dev/null 2>"$sb/oerr"); orc=$?
  if [ $rc = 3 ]; then
    # not compared, but a refusal the bash makes (status 2) that the port left unported is a failure
    if [ $orc = 2 ]; then
      fail=$((fail + 1)); failed_list+="== $line
--- port
unported: $(head -1 "$sb/perr")
--- bash
STATUS 2 (a refusal the port does not make)
--- bash stderr
$(head -3 "$sb/oerr")
"
    else
      unp=$((unp + 1)); unported_list+="  $line
      $(head -1 "$sb/perr")
"
    fi
    continue
  fi
  oracle_out=$({ norm < "$sb/stublog"; echo "STATUS $orc"; })
  if [ "$port_out" = "$oracle_out" ]; then
    pass=$((pass + 1))
  else
    fail=$((fail + 1)); failed_list+="== $line
--- port
$port_out
--- bash
$oracle_out
--- bash stderr
$(head -3 "$sb/oerr")
"
  fi
done < "$cases"

[ -z "$failed_list" ] || printf '%s' "$failed_list"
echo "passed $pass, failed $fail, unported $unp"
[ -z "$unported_list" ] || { echo "unported (reason from the port):"; printf '%s' "$unported_list"; }
[ "$fail" = 0 ]
