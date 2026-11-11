#!/usr/bin/env bash
# Optional matching Ubuntu LLVM 21 tool, extracted locally without installation.
set -euo pipefail
cd "$(dirname "$0")/../.."
base=$PWD/build/testsuite-snapshots
file=clang-tidy-21_1%3a21.1.8-6ubuntu1_amd64.deb
mkdir -p "$base/clang-tidy-packages"
if [ ! -f "$base/clang-tidy-packages/$file" ]; then
  (cd "$base/clang-tidy-packages" && apt-get download clang-tidy-21=1:21.1.8-6ubuntu1)
fi
printf '%s  %s\n' c588adbf82e18cdaa7cb34adf7c68773f234eea49052bf8db064eec7d06aa465 \
  "$base/clang-tidy-packages/$file" | sha256sum -c -
dpkg-deb -x "$base/clang-tidy-packages/$file" "$base/clang-tidy"
"$base/clang-tidy/usr/lib/llvm-21/bin/clang-tidy" --version
