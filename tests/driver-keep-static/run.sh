#!/bin/bash
# Differential test of nfcxx's keep_static choice: the two bash lines verbatim (from the frozen driver,
# tests/driver-body/nfcxx-bash) against scripts/nfcxx-keep-static.rb plan, with stub compilers: gcc, clang, one that fails,
# one that prints nothing, one that names clang only on its second line, a missing name, and the default cc (NFCXX_GCC unset).
#   bash tests/driver-keep-static/run.sh
set -u
here=$(cd "$(dirname "$0")" && pwd -P)
repo=$(cd "$here/../.." && pwd -P)
work=$(mktemp -d); trap 'rm -rf "$work"' EXIT
pass=0; fail=0
sed -n '/^keep_static=(--c_to_obj_option -fkeep-static-functions)$/,/grep -qi clang && keep_static=()$/p' \
  "$repo/tests/driver-body/nfcxx-bash" > "$work/bash.sh"
[ "$(wc -l < "$work/bash.sh")" = 2 ] || { echo "driver-keep-static: the two lines are not in the frozen driver" >&2; exit 2; }
ruby_bin=$(command -v ruby)

bin=$work/bin; mkdir -p "$bin"
printf '#!/bin/sh\necho "gcc (GCC) 13.3.0"\n' > "$bin/gcc-stub"
printf '#!/bin/sh\necho "clang version 18.1.3"\n' > "$bin/clang-stub"
printf '#!/bin/sh\nexit 1\n' > "$bin/failing-stub"
printf '#!/bin/sh\nexit 0\n' > "$bin/silent-stub"
printf '#!/bin/sh\necho "gcc 13"; echo "clang is not my first line"\n' > "$bin/second-line-stub"
chmod +x "$bin"/*-stub

# case_ NAME VALUE_OR_UNSET: NFCXX_GCC is VALUE (or unset when the value is the word UNSET); the default cc is the clang stub
# or the gcc stub, per the name (the default cases link cc)
case_() {
  local name=$1 value=$2 b t
  local env_cmd=(env PATH="$bin:$PATH")
  [ "$value" = UNSET ] && env_cmd+=(-u NFCXX_GCC) || env_cmd+=(NFCXX_GCC="$value")
  b=$("${env_cmd[@]}" bash -c 'set -u; source "$1"; printf "%s\n" "${keep_static[@]}"' _ "$work/bash.sh" 2>&1)
  t=$("${env_cmd[@]}" bash -c 'set -u; eval "$(ruby "$1" plan)"; printf "%s\n" "${keep_static[@]}"' _ "$repo/scripts/nfcxx-keep-static.rb" 2>&1)
  if [ "$b" = "$t" ]; then pass=$((pass + 1)); echo "ok   $name ($(printf '%s' "$t" | tr '\n' ' '))"
  else fail=$((fail + 1)); echo "FAIL $name"; echo "  bash: $b"; echo "  port: $t"; fi
}

case_ "gcc" "$bin/gcc-stub"
case_ "clang" "$bin/clang-stub"
case_ "fails: keep" "$bin/failing-stub"
case_ "prints nothing: keep" "$bin/silent-stub"
case_ "clang only on the second line: keep" "$bin/second-line-stub"
case_ "a missing compiler: keep" "$work/no-such-cc"
case_ "a value with a space is one program name: keep" "$bin/clang-stub --x"
mkdir -p "$work/defaults"; ln -sf "$bin/clang-stub" "$work/defaults/cc"
env_default() { env PATH="$work/defaults:$PATH" "$@"; }
b=$(env_default env -u NFCXX_GCC bash -c 'set -u; source "$1"; printf "%s\n" "${keep_static[@]}"' _ "$work/bash.sh")
t=$(env_default env -u NFCXX_GCC bash -c 'set -u; eval "$(ruby "$1" plan)"; printf "%s\n" "${keep_static[@]}"' _ "$repo/scripts/nfcxx-keep-static.rb")
if [ "$b" = "$t" ] && [ -z "$t" ]; then pass=$((pass + 1)); echo "ok   default cc is clang: no option"
else fail=$((fail + 1)); echo "FAIL default cc is clang"; echo "  bash: $b"; echo "  port: $t"; fi

echo "driver-keep-static: $pass passed, $fail failed"
[ "$fail" = 0 ]
