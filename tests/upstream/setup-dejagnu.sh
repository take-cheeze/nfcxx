#!/usr/bin/env bash
# Local Ubuntu amd64 packages only: no apt install and no root mutation.
set -euo pipefail
cd "$(dirname "$0")/../.."
root=$PWD
out=$root/build/testsuite-snapshots
mkdir -p "$out/dejagnu-packages" "$out/dejagnu"
while IFS=$'\t' read -r package version filename sha; do
  [ "$package" = package ] && continue
  if [ ! -f "$out/dejagnu-packages/$filename" ]; then
    (cd "$out/dejagnu-packages" && apt-get download "$package=$version")
  fi
  printf '%s  %s\n' "$sha" "$out/dejagnu-packages/$filename" | sha256sum -c -
  dpkg-deb -x "$out/dejagnu-packages/$filename" "$out/dejagnu"
done < tests/upstream/dejagnu-packages.tsv
env PATH="$out/dejagnu/usr/bin:/usr/bin:/bin" \
  LD_LIBRARY_PATH="$out/dejagnu/usr/lib/x86_64-linux-gnu:/usr/lib/x86_64-linux-gnu" \
  "$out/dejagnu/usr/bin/runtest" --version
