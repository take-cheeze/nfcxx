#!/usr/bin/env bash
# Fetch the ILAssembler the CIL backend (NFCXX_BACKEND=cil) writes its program with, into build/cil/ilasm. The binary is
# the linux-x64 native ilasm from the dotnet/runtime tooling, on NuGet (runtime.linux-x64.microsoft.netcore.ilasm). The
# .NET runtime that runs the program is separate: install the .NET 8 (or later) runtime, `dotnet` on PATH.
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
ver=10.0.13
dest=$root/build/cil
mkdir -p "$dest"
if [ -x "$dest/ilasm" ]; then echo "ok: $dest/ilasm"; exit 0; fi
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
curl -sSfL -o "$tmp/ilasm.nupkg" \
  "https://api.nuget.org/v3-flatcontainer/runtime.linux-x64.microsoft.netcore.ilasm/$ver/runtime.linux-x64.microsoft.netcore.ilasm.$ver.nupkg"
python3 -c "import sys, zipfile; zipfile.ZipFile(sys.argv[1]).extract('runtimes/linux-x64/native/ilasm', sys.argv[2])" \
  "$tmp/ilasm.nupkg" "$tmp"
install -m 755 "$tmp/runtimes/linux-x64/native/ilasm" "$dest/ilasm"
echo "ok: $dest/ilasm ($ver)"
