# The bash helpers as nfcxx had them before they became calls of scripts/nfcxx-cache-io.rb: the frozen reference that
# tests/nfcxx-cache-io/run.sh compares the Ruby against. Copied from nfcxx at commit 70f19b04 (cache_log, cache_remote_get,
# cache_remote_put); it does not change with nfcxx. The functions are the bodies as nfcxx had them, with the root they use.
cache_log() {  # cache_log TEXT: appends TEXT as one write to NFCXX_CACHE_LOG when --cache-log (NFCXX_CACHE_LOG) is set (a diagnostic; no effect on the key).
  # Parallel compiles share the file, so each append takes a lock (mkdir, which is portable) and is a single printf.
  [ -n "$cache_log_file" ] || return 0
  while ! mkdir "$cache_log_file.lock" 2>/dev/null; do sleep 0.05; done
  printf '%s\n' "$*" >> "$cache_log_file"
  rmdir "$cache_log_file.lock"
}
cache_remote_get() {  # cache_remote_get KEY ENTRY: fills ENTRY (a directory) from the remote cache; fails on a miss or an error
  local tmp=$2.remote.$$ rc=0
  rm -rf "$tmp"
  "${RUBY:-ruby}" "$root/scripts/nfcxx-cache-gha.rb" get "$1" "$tmp" || rc=$?
  if [ $rc = 0 ] && [ -f "$tmp/obj" ]; then
    mkdir -p "$(dirname "$2")"; [ -e "$2" ] || mv "$tmp" "$2" 2>/dev/null || true
  else rc=1; fi
  rm -rf "$tmp"
  return $rc
}
cache_remote_put() {  # cache_remote_put KEY ENTRY: stores the files of the local entry ENTRY remotely
  local names=(obj) x
  for x in ti ii; do [ ! -f "$2/$x" ] || names+=("$x"); done
  "${RUBY:-ruby}" "$root/scripts/nfcxx-cache-gha.rb" put "$1" "$2" "${names[@]}" \
    || echo "nfcxx: remote cache: could not store $1 (the build continues)" >&2
}
