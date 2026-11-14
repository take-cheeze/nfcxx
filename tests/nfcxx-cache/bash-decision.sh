#!/usr/bin/env bash
# The bash side of tests/nfcxx-cache/run.sh: nfcxx's compile cache as nfcxx runs it, with the commands it runs printed.
# The harness is nfcxx's own setup and argument loop (as tests/nfcxx/option-state.sh runs them), then nfcxx's lines from the
# pre-compile removal to the store, with the one-step build replaced by eccp_stub. Printed: CP (cp), RUN (rm, mv, mkdir,
# python3 for the remote helper, and the build), EXIT 0 when the bash exits after a hit. The build writes the object and the
# records named in CACHE_TEST_RECORDS beside it. The remote helper answers hit (CACHE_TEST_REMOTE=hit) or miss (the default).
# The cache log is left as the bash writes it (NFCXX_CACHE_LOG).
#   tests/nfcxx-cache/bash-decision.sh ARG...   run from the directory holding the source
root=$(cd "$(dirname "$0")/../.." && pwd)
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT

first=$(grep -n -F -x 'if [ $compile_only = 1 ] && [ $ncpp -gt 0 ]; then' "$root/nfcxx" | head -1 | cut -d: -f1)
end=$(grep -n -F -x 'if [ -n "$depmode" ]; then' "$root/nfcxx" | cut -d: -f1 | awk -v s="$first" '$1 > s { print; exit }')

harness() {
  cat <<'EOF'
_out() { local s=$1 x; shift; for x in "$@"; do s+=" $x"; done; printf '%s\n' "$s"; }
run_stub() { _out RUN "$@"; return 0; }
exec_stub() { _out EXEC "$@"; exit 0; }
ensure_tool() { return 0; }
cp() { _out CP "$@"; command cp "$@"; }
mv() { _out RUN mv "$@"; command mv "$@"; }
rm() { _out RUN rm "$@"; command rm "$@"; }
mkdir() { case ${*: -1} in *.lock) command mkdir "$@"; return ;; esac; _out RUN mkdir "$@"; command mkdir "$@"; }
python3() {
  _out RUN python3 "$@"
  case $3 in
    get) [ "${CACHE_TEST_REMOTE:-miss}" = hit ] || return 1; command mkdir -p "$5"; printf 'OBJECT remote\n' > "$5/obj" ;;
  esac
  return 0
}
eccp_stub() {
  _out RUN build "$out"
  printf 'OBJECT %s\n' "$out" > "$out"
  local x
  for x in ${CACHE_TEST_RECORDS:-}; do printf 'RECORD %s\n' "$x" > "${out%.*}.$x"; done
  return 0
}
pathbcc_stub() {  # the Path B compile of one file (scripts/pathb-cc): the object named after -o
  local o= prev= x
  for x in "$@"; do [ "$prev" != -o ] || o=$x; prev=$x; done
  _out RUN build "$o"
  printf 'OBJECT %s\n' "$o" > "$o"
  return 0
}
EOF
  # nfcxx's setup and argument loop, and the setup after it, up to the cache block (the build step stubbed, nfcxx's root).
  # The Path B compile of a file is stubbed too (the Path B -c block is in this part), and its cache hit is marked as the exit it is.
  head -n "$((first - 1))" "$root/nfcxx" |
    sed -e "s|^root=\$(cd \"\$(dirname \"\$0\")\" && pwd)|root=$root|" -e 's/^ensure_tool() {/ensure_tool_real() {/' \
        -e 's|exec "\$0" |exec_stub nfcxx |g' -e 's|"\$0" |run_stub nfcxx |g' \
        -e 's|"\$root/scripts/pathb-cc" |pathbcc_stub |g' \
        -e 's|cp "\$pb_entry/obj" "\$out"; exit 0|cp "$pb_entry/obj" "$out"; _out EXIT 0; exit 0|'
  # the cache block: from the pre-compile removal to the line before the -MD block
  sed -n "${first},$((end - 1))p" "$root/nfcxx" |
    sed -e 's/"\$eccp_bin" /eccp_stub /' -e 's/^\( *\)exit 0$/\1_out EXIT 0; exit 0/'
}
harness > "$tmp/harness.sh"
bash "$tmp/harness.sh" "$@"
