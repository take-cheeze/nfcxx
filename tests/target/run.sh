#!/usr/bin/env bash
# Freestanding cross targets (docs/notes/freestanding.md, "Targets"). For each tests/target/*.cpp:
#   1. nfcxx --freestanding --target=<EDG target> --emit-c: EDG accepts the file, so its static_asserts hold for the
#      target's tables (sizes, char signedness, predefined macros);
#   2. clang --target=<triple> compiles the generated C to an object: the C is valid for the target's compiler;
#   3. the same file is refused without --target when `// HOST-REJECTS: yes` (the host's layout differs).
# Header line: `// TARGET: <EDG target> <clang triple>`. Then the refusals: --target without --freestanding, without --emit-c,
# and an unknown target name must each exit non-zero.
cd "$(dirname "$0")/../.."
fail=0; tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
command -v clang >/dev/null || { echo "skip: clang not found (needed to compile the generated C for the target)"; exit 0; }
for f in tests/target/*.cpp; do
  name=$(basename "$f" .cpp)
  read -r _ target triple < <(sed -n 's,^// TARGET: *,TARGET ,p' "$f" | head -1)
  if [ -z "${target:-}" ]; then echo "FAIL  $name: no '// TARGET:' line"; fail=1; continue; fi
  if grep -q '^// NEEDS: mingw' "$f" && ! command -v x86_64-w64-mingw32-gcc >/dev/null; then
    echo "skip  $name: needs MinGW-w64 (x86_64-w64-mingw32-gcc) at EDG setup for the win64 table"; continue
  fi
  if ./nfcxx --freestanding --emit-c --target="$target" "$f" > "$tmp/$name.c" 2> "$tmp/$name.err"; then
    if clang --target="$triple" -ffreestanding -w -std=gnu11 -c "$tmp/$name.c" -o "$tmp/$name.o" 2> "$tmp/$name.cc"; then
      echo "ok    $name ($target, $triple)"
    else
      echo "FAIL  $name: clang --target=$triple rejected the generated C"; head -4 "$tmp/$name.cc"; fail=1
    fi
    # `// RUN-WINE: N`: the generated C built by MinGW-w64's gcc and run under wine must exit N.
    if want=$(sed -n 's,^// RUN-WINE: *,,p' "$f" | head -1) && [ -n "$want" ]; then
      if command -v x86_64-w64-mingw32-gcc >/dev/null && command -v wine >/dev/null; then
        if x86_64-w64-mingw32-gcc -O2 -fwrapv -fno-strict-aliasing -w "$tmp/$name.c" -o "$tmp/$name.exe" 2> "$tmp/$name.ld" &&
           WINEDEBUG=-all timeout 300 wine "$tmp/$name.exe" > /dev/null 2>&1; then got=0; else got=$?; fi
        if [ "$got" -eq "$want" ]; then echo "ok    $name: wine exit $got"
        else echo "FAIL  $name: wine exit $got, want $want"; head -4 "$tmp/$name.ld"; fail=1; fi
      else
        echo "skip  $name: running needs x86_64-w64-mingw32-gcc and wine"
      fi
    fi
  else
    echo "FAIL  $name: EDG refused it for $target"; head -4 "$tmp/$name.err"; fail=1
  fi
  if grep -q '^// HOST-REJECTS: yes' "$f"; then
    if ./nfcxx --freestanding --emit-c "$f" > /dev/null 2> "$tmp/$name.host"; then
      echo "FAIL  $name: the host target accepted the $target facts (the test proves nothing)"; fail=1
    else
      echo "ok    $name: the host target refuses the $target facts"
    fi
  fi
done
# The freestanding library tests (tests/lib) through each target: EDG emits the C, clang compiles it for the triple.
# This is the library's own coverage on the other ABIs, not only the layout probes above.
for tt in "linux_aarch64 aarch64-linux-gnu" "linux_riscv64 riscv64-linux-gnu" "linux_armv7 arm-linux-gnueabihf"; do
  read -r target triple <<< "$tt"; n=0; bad=""
  for f in tests/lib/*.cpp; do
    name=$(basename "$f" .cpp)
    if ./nfcxx --freestanding --emit-c --target="$target" "$f" > "$tmp/lib-$target-$name.c" 2> "$tmp/lib-$target-$name.err" &&
       clang --target="$triple" -ffreestanding -w -std=gnu11 -c "$tmp/lib-$target-$name.c" -o "$tmp/lib-$target-$name.o" 2> "$tmp/lib-$target-$name.cc"; then
      n=$((n + 1))
    else
      bad="$bad $name"
    fi
  done
  if [ -z "$bad" ]; then echo "ok    tests/lib through $target: $n programs emitted and compiled by clang"
  else echo "FAIL  tests/lib through $target:$bad"; fail=1; fi
done
expect_refused() {  # expect_refused LABEL CMD...: the command must exit non-zero
  local label=$1; shift
  if "$@" > /dev/null 2> "$tmp/refuse.err"; then echo "FAIL  refuse $label: accepted"; fail=1
  else echo "ok    refuse $label: $(head -1 "$tmp/refuse.err")"; fi
}
probe=tests/target/aarch64_layout.cpp
expect_refused "without --freestanding" ./nfcxx --emit-c --target=linux_aarch64 "$probe"
expect_refused "without --emit-c" ./nfcxx --freestanding --target=linux_aarch64 -c "$probe" -o "$tmp/x.o"
expect_refused "unknown target" ./nfcxx --freestanding --emit-c --target=bogus "$probe"
exit $fail
