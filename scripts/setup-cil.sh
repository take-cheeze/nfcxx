#!/usr/bin/env bash
# Fetch the ILAssembler the CIL backend (NFCXX_BACKEND=cil) writes its program with, into build/cil/ilasm. The binary is
# the native ilasm from the dotnet/runtime tooling, on NuGet: runtime.linux-x64.microsoft.netcore.ilasm for x86-64 and
# runtime.linux-arm64.microsoft.netcore.ilasm for aarch64 (same version, same layout in the package). The .NET runtime
# that runs the program is separate: install the .NET 8 (or later) runtime, `dotnet` on PATH.
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
ver=10.0.13
dest=$root/build/cil
mkdir -p "$dest"
if [ -x "$dest/ilasm" ]; then echo "ok: $dest/ilasm"; exit 0; fi
case $(uname -m) in
  x86_64|amd64) rid=linux-x64 ;;
  aarch64|arm64) rid=linux-arm64 ;;
  *) echo "setup-cil: no ilasm package for $(uname -m)" >&2; exit 1 ;;
esac
[ "$(uname -s)" = Linux ] || { echo "setup-cil: the ilasm package is a Linux binary ($(uname -s) host)" >&2; exit 1; }
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
pkg=runtime.$rid.microsoft.netcore.ilasm
curl -sSfL -o "$tmp/ilasm.nupkg" \
  "https://api.nuget.org/v3-flatcontainer/$pkg/$ver/$pkg.$ver.nupkg"
python3 -c "import sys, zipfile; zipfile.ZipFile(sys.argv[1]).extract('runtimes/$rid/native/ilasm', sys.argv[2])" \
  "$tmp/ilasm.nupkg" "$tmp"
install -m 755 "$tmp/runtimes/$rid/native/ilasm" "$dest/ilasm"
echo "ok: $dest/ilasm ($pkg $ver)"
