# Native Microsoft STL suite: run in an x64 Visual Studio Preview developer shell.
$ErrorActionPreference = 'Stop'
$root = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
$source = Join-Path $root 'build/testsuite-snapshots/microsoft-stl'
if (-not $IsWindows) { throw 'Native Microsoft STL requires Windows, MSVC Preview and the Windows SDK; see its pinned README.' }
if (-not (Get-Command cl.exe -ErrorAction SilentlyContinue)) { throw 'Open an x64 MSVC Preview developer shell first.' }
Push-Location $source
try {
    $manifest = Import-Csv (Join-Path $PSScriptRoot 'git-snapshots.tsv') -Delimiter "`t"
    $pin = ($manifest | Where-Object suite -eq 'microsoft-stl').commit
    $actual = git rev-parse HEAD
    if ($LASTEXITCODE -or $actual -ne $pin) { throw 'Microsoft STL checkout does not match the committed snapshot pin' }
    # Gitlinks in the pinned parent determine dependency commits.
    git submodule update --init --depth 1 llvm-project boost-math
    if ($LASTEXITCODE) { throw 'STL dependency setup failed' }
    cmake --preset x64
    if ($LASTEXITCODE) { throw 'STL configure failed; check pinned toolchain prerequisites' }
    cmake --build --preset x64 --parallel 8
    if ($LASTEXITCODE) { throw 'STL build failed' }
    $output = Join-Path $root 'build/testsuite-snapshots/microsoft-stl-native'
    New-Item -ItemType Directory -Force $output | Out-Null
    python out/x64/tests/utils/stl-lit/stl-lit.py -v -j 8 -Dnotags=ASAN --timeout 120 `
        --output "$output/results.json" llvm-project/libcxx/test tests/std tests/tr1
    if ($LASTEXITCODE) { throw "STL tests failed; results: $output/results.json" }
} finally { Pop-Location }
