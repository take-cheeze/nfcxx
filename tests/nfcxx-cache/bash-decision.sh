#!/usr/bin/env bash
# The cache block of a driver run by tests/nfcxx-cache/run.sh: the setup and argument loop of nfcxx (as
# tests/nfcxx/option-state.sh runs them), then the lines from the pre-compile removal to the store, with the one-step build
# replaced by eccp_stub. The file operations of the block (cp, mv, mkdir, rm) print CP and RUN lines. The Ruby helpers run for
# real: scripts/nfcxx-cache.rb does its own copies, so run.sh compares the sandbox after the run. The remote helper
# (scripts/nfcxx-cache-io.rb remote-get and remote-put) is a stub that answers hit (CACHE_TEST_REMOTE=hit) or miss (the default).
# EXIT 0 is printed when the driver exits after a hit. The build writes the object and the records named in CACHE_TEST_RECORDS.
#   tests/nfcxx-cache/bash-decision.sh FILE ARG...   FILE is the driver to run: nfcxx, or the frozen copy nfcxx-bash
file=$1; shift
here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../.." && pwd)
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT

first=$(grep -n -F -x 'if [ $compile_only = 1 ] && [ $ncpp -gt 0 ]; then' "$file" | head -1 | cut -d: -f1)
end=$(grep -n -F -x 'if [ -n "$depmode" ]; then' "$file" | cut -d: -f1 | awk -v s="$first" '$1 > s { print; exit }')

harness() {
  cat <<'EOT'
_out() { local s=$1 x; shift; for x in "$@"; do s+=" $x"; done; printf '%s\n' "$s"; }
RUBY=ruby   # the driver runs the Ruby helpers as "${RUBY:-ruby}": the ruby stub below records the remote helper's runs
run_stub() { _out RUN "$@"; return 0; }
exec_stub() { _out EXEC "$@"; exit 0; }
ensure_tool() { return 0; }
cp() { _out CP "$@"; command cp "$@"; }
mv() { _out RUN mv "$@"; command mv "$@"; }
rm() { _out RUN rm "$@"; command rm "$@"; }
mkdir() { case ${*: -1} in *.lock) command mkdir "$@"; return ;; esac; _out RUN mkdir "$@"; command mkdir "$@"; }
ruby() {  # the cache's Ruby helpers: nfcxx-cache.rb runs for real; the remote helper of nfcxx-cache-io.rb is the stub below
  case $1 in *nfcxx-cache-io.rb) ;; *) command ruby "$@"; return ;; esac
  case $2 in log) command ruby "$@"; return ;; esac
  _out RUN ruby "$@"
  case $2 in
    remote-get) [ "${CACHE_TEST_REMOTE:-miss}" = hit ] || return 1
                [ -e "$4" ] || { command mkdir -p "$(dirname "$4")"; command mkdir -p "$4"; printf 'OBJECT remote\n' > "$4/obj"; } ;;
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
pathbcc_stub() {  # the Path B compile of one file (scripts/pathb-cc.rb): the object named after -o
  local o= prev= x
  for x in "$@"; do [ "$prev" != -o ] || o=$x; prev=$x; done
  _out RUN build "$o"
  printf 'OBJECT %s\n' "$o" > "$o"
  return 0
}
EOT
  # the setup and argument loop, up to the cache block (the build step stubbed, the root and the exec of the driver replaced)
  head -n "$((first - 1))" "$file" |
    sed -e "s|^root=\$(cd \"\$(dirname \"\$0\")\" && pwd)|root=$root|" -e 's/^ensure_tool() {/ensure_tool_real() {/' \
        -e 's|exec "\$0" |exec_stub nfcxx |g' -e 's|"\$0" |run_stub nfcxx |g' \
        -e 's|"\$root/scripts/pathb-cc.rb" |pathbcc_stub |g' \
        -e 's|cp "\$pb_entry/obj" "\$out"; exit 0|cp "$pb_entry/obj" "$out"; _out EXIT 0; exit 0|' \
        -e '/^cache_check() {/,/^}/ s/^\( *\)exit 0$/\1_out EXIT 0; exit 0/' \
        -e '/^cache_check() {/,/^}/ s/&& exit 0$/\&\& { _out EXIT 0; exit 0; }/'
  # the cache block: from the pre-compile removal to the line before the -MD block
  sed -n "${first},$((end - 1))p" "$file" |
    sed -e 's/"\$eccp_bin" /eccp_stub /' -e 's|"\$root/scripts/pathb-cc.rb" |pathbcc_stub |g' \
        -e 's/^\( *\)exit 0$/\1_out EXIT 0; exit 0/' -e 's/&& exit 0$/\&\& { _out EXIT 0; exit 0; }/'
}
harness > "$tmp/harness.sh"
bash "$tmp/harness.sh" "$@"
