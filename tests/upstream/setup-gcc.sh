#!/usr/bin/env bash
# Compatibility entry point; all Git suite pins live in git-snapshots.tsv.
set -euo pipefail
root=$(cd "$(dirname "$0")/../.." && pwd)
exec "$root/tests/upstream/setup-git.sh" gcc
