#!/usr/bin/env bash
# Run an mruby script with nfcxx's standalone interpreter: scripts/mrb script.rb [args...]
# Builds it first with scripts/setup-mruby.sh when build/mruby-tool/bin/mruby is missing.
root=$(cd "$(dirname "$0")/.." && pwd)
exe=${MRB:-$root/build/mruby-tool/bin/mruby}
if [ ! -x "$exe" ]; then
  [ -z "${MRB:-}" ] || { echo "mrb: $MRB is not executable" >&2; exit 1; }
  "$root/scripts/setup-mruby.sh" >&2 || exit 1
fi
exec "$exe" "$@"
