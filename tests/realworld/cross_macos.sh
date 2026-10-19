#!/usr/bin/env bash
# cross_macos.sh NAME: cross-compile one real-world project for macOS arm64 on a Linux host, link it against the
# clean-room stubs (tests/macos-sysroot/lib), and write the executable under build/<NAME>-macos/. Needs
# scripts/setup-cross-macos.sh first (build/cross-macos.env). Nothing is run here: copy the executable to a Mac and run it
# there. The expected results are printed after the build and are the ones the project's own check uses.
#   NAME=lua       Lua 5.4 (run_lua.sh's pin): the interpreter. Expect print(1+1) -> 2 and lua_test.lua -> lua-ok line.
#   NAME=doctest   doctest v2.4.12 (run_doctest.sh's pin) with tests/realworld/doctest_main.cpp. Expect exit code 2.
#   NAME=json      nlohmann/json v3.12.0 (run_json.sh's pin) with tests/realworld/json_main.cpp. Expect the output of the
#                  same program built natively (run_json.sh's host build), byte for byte.
set -euo pipefail
cd "$(dirname "$0")/../.."
root=$PWD
name=${1:?usage: cross_macos.sh lua|doctest|json}
envf=$root/build/cross-macos.env
[ -f "$envf" ] || { echo "cross_macos: $envf is missing; run scripts/setup-cross-macos.sh first" >&2; exit 2; }
. "$envf"
work=$root/build/realworld
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT

# fetch URL PIN DIR: a shallow clone of one pinned commit (the same pattern as run_*.sh)
fetch() {
  local url=$1 pin=$2 src=$3
  if [ ! -d "$src/.git" ]; then mkdir -p "$src" && git -C "$src" init -q && git -C "$src" remote add origin "$url"; fi
  if [ "$(git -C "$src" rev-parse -q --verify "$pin^{commit}" 2>/dev/null)" != "$pin" ]; then
    git -C "$src" fetch -q --depth 1 origin "$pin" || { echo "cross_macos: fetch $url failed" >&2; exit 1; }
  fi
  git -C "$src" checkout -q "$pin"
}

# link OUT OBJ...: the Mach-O arm64 executable against libSystem (and libc++ when C++), with nfcxx's runtime helpers
link() {
  local out=$1; shift
  clang --target=arm64-apple-darwin -O2 -nostdinc -isystem "$NFCXX_MACOS_CLEANROOM/include" \
    -isystem "$(clang -print-resource-dir)/include" -c be/nfcxx_ldrt.c -o "$W/ldrt.o"
  mkdir -p "$(dirname "$out")"
  # the sret thunks (sret.sh, cross mode) and the source-built runtime and libc++ archives, when present, before -lSystem and -lc++
  local rt=(); for a in build/sret-cross/sret-macos.a build/macos-rt/libnfcxx-darwin-rt.a build/macos-rt/libc++-darwin.a; do [ -f "$a" ] && rt+=("$a"); done
  ld64.lld --error-limit=0 -arch arm64 -platform_version macos 11.0 11.0 -o "$out" "$@" "$W/ldrt.o" ${NFCXX_MACOS_LIBC:+"$NFCXX_MACOS_LIBC"} \
    "${rt[@]}" -L tests/macos-sysroot/lib -lSystem "${LINK_EXTRA[@]}"
  local hdr; hdr=$(llvm-objdump --macho --private-headers "$out")
  grep -q EXECUTE <<<"$hdr" && grep -q ARM64 <<<"$hdr" || { echo "cross_macos: $out is not a Mach-O arm64 executable" >&2; exit 1; }
  echo "built: $out (sha256 $(sha256sum "$out" | cut -c1-16))"
}

case $name in
lua)
  pin=312b9efaa1061c2c4cad08554dbc1351c3270eef   # lua/lua tag v5.4.9, as run_lua.sh
  src=$work/lua; out=$root/build/lua-macos/lua
  fetch https://github.com/lua/lua "$pin" "$src"
  res=$(clang -print-resource-dir)/include
  clang --target=arm64-apple-darwin -O2 -nostdinc -isystem "$NFCXX_MACOS_CLEANROOM/include" -isystem "$res" \
    -c be/nfcxx_ldrt.c -o "$W/ldrt.o"
  objs=()
  # every interpreter file: luac.c (the compiler), ltests.c (test hooks) and onelua.c (amalgamation) are not part of it
  for f in "$src"/l*.c; do
    case $(basename "$f") in luac.c|ltests.c|onelua.c) continue ;; esac
    b=$(basename "$f" .c)
    NFCXX_C_INPUT=1 scripts/qbe-cc -S "$f" -o "$W/$b.s" >/dev/null
    llvm-mc -triple=arm64-apple-darwin -filetype=obj "$W/$b.s" -o "$W/$b.o"
    objs+=("$W/$b.o")
  done
  LINK_EXTRA=(); link "$out" "${objs[@]}"
  echo "expected on the Mac: print(1+1) -> 2; lua_test.lua -> lua-ok<TAB>27<TAB>6765<TAB>Lua 5.4; exit 0"
  ;;
doctest)
  pin=1da23a3e8119ec5cce4f9388e91b065e20bf06f5   # doctest/doctest tag v2.4.12, as run_doctest.sh
  src=$work/doctest; out=$root/build/doctest-macos/doctest
  fetch https://github.com/doctest/doctest "$pin" "$src"
  # The Darwin branch of doctest's debugger check reads the kinfo_proc layout (sys/sysctl.h). doctest's own
  # DOCTEST_IS_DEBUGGER_ACTIVE() override replaces that whole check; it is defined here as "not under a debugger", for
  # the cross build only.
  # The prelinker step (scripts/macos-cxx-link.sh, as in #363): doctest's toString<float> and toString<long double> are
  # template instances, which the prelinker compiles through the Darwin path. The include path and the override are
  # nfcxx options, passed to both steps.
  # DOCTEST_CONFIG_USE_STD_HEADERS: doctest otherwise forward-declares std types itself, including its own size_t, which
  # clashes with the libc++ headers. The cross build uses the real standard headers.
  scripts/macos-cxx-link.sh tests/realworld/doctest_main.cpp "$out" "-I$src" "-DDOCTEST_IS_DEBUGGER_ACTIVE()=false" "-DDOCTEST_CONFIG_USE_STD_HEADERS"
  echo "expected on the Mac: exit code 2 (two deliberate CHECK failures); doctest prints its summary"
  ;;
json)
  pin=55f93686c01528224f448c19128836e7df245f72   # nlohmann/json tag v3.12.0, as run_json.sh
  src=$work/json; out=$root/build/json-macos/json
  fetch https://github.com/nlohmann/json "$pin" "$src"
  if ! NFCXX_CXX_FLAGS="-I$src/single_include" scripts/macos-cxx-check.sh tests/realworld/json_main.cpp "$W/json.s" >/dev/null; then
    echo "cross_macos: json is blocked, not built: the front end or the libc++ headers did not compile json_main.cpp for arm64 Darwin" >&2
    exit 3
  fi
  llvm-mc -triple=arm64-apple-darwin -filetype=obj "$W/json.s" -o "$W/json.o"
  LINK_EXTRA=(-L tests/macos-sysroot/lib -lc++); link "$out" "$W/json.o"
  echo "expected on the Mac: the output of json_main.cpp built natively on the Mac with clang++ -std=c++17 -I<json>/single_include (exit 0)"
  ;;
mruby)
  pin=831da26b9021de0369d17b71b5667e2941a1a32d   # mruby/mruby tag 4.0.0, as run_mruby.sh
  src=$work/mruby; out=$root/build/mruby-macos/mruby
  fetch https://github.com/mruby/mruby "$pin" "$src"
  # mruby writes a .lock file next to its config, so the config is copied out of the repository first (as run_mruby.sh)
  cp "$root/tests/realworld/mruby_cross_build_config.rb" "$W/build_config.rb"
  if command -v rake >/dev/null; then rake=(rake); else rake=(ruby -rrake -e 'Rake.application.run(ARGV)' --); fi
  if ! (cd "$src" && MRUBY_CROSS_ROOT=$root MRUBY_CROSS_CC=$root/tests/realworld/mruby_cross_cc.sh \
        MRUBY_CROSS_LD=$root/tests/realworld/mruby_cross_cc.sh MRUBY_CROSS_AR=llvm-ar MRUBY_CONFIG=$W/build_config.rb \
        MRUBY_BUILD_DIR=$W/mruby-build "${rake[@]}" -j"$(nproc)" all >"$W/rake.log" 2>&1); then
    echo "cross_macos: mruby build blocked; first error:" >&2
    grep -m3 -E 'error|undefined|fatal' "$W/rake.log" >&2 || tail -5 "$W/rake.log" >&2
    exit 3
  fi
  exe=$W/mruby-build/arm64-macos/bin/mruby
  hdr=$(llvm-objdump --macho --private-headers "$exe")
  grep -q EXECUTE <<<"$hdr" && grep -q ARM64 <<<"$hdr" || { echo "cross_macos: $exe is not a Mach-O arm64 executable" >&2; exit 1; }
  mkdir -p "$(dirname "$out")"; cp "$exe" "$out"
  echo "built: $out (sha256 $(sha256sum "$out" | cut -c1-16))"
  echo "expected on the Mac: -e 'puts 1+1' -> 2; mruby_test.rb -> mruby-ok mruby 3 [1, 3, 5, 8] 6765; exit 0"
  ;;
*) echo "cross_macos: unknown NAME '$name' (lua|doctest|json|mruby)" >&2; exit 2 ;;
esac
