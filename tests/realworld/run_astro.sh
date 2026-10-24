#!/usr/bin/env bash
# Real-world check: ASTro (https://github.com/ko1/astro), a framework that generates an AST interpreter from a node.def
# with ASTroGen (Ruby) and specializes it into C compiled at run time with $(CC). The source is cloned into
# build/realworld at a pinned commit, not vendored. docs/notes/astro.md.
#   NFCXX_BACKEND=gcc|qbe   (default: both)
# Per backend, with nfcc as the C compiler:
#   - sample/calc and sample/luastro built from the generated C (the interpreters themselves);
#   - calc run with its Code Store compiling the specialized SD_*.c files through nfcc (CC=nfcc): the result is
#     right and the specialized function is loaded;
#   - luastro run on hello.lua, fib.lua and its own test/*.lua; the qbe build's output must equal the gcc build's.
# Two patches are applied to a copy of the tree (the clone stays pinned and clean):
#   - lib/astrogen.rb and sample/luastro/lua_gen.rb use Ruby 3.4's implicit block parameter `it`; _1 is the same
#     thing on Ruby >= 2.7 (the host here may have 3.3);
#   - lib/astrogen.rb emits "NODE *ALLOC_x(...);;" (an empty declaration at file scope, which ISO C forbids and gcc
#     accepts); cproc rejects it. The patch joins the declarations with "\n".
cd "$(dirname "$0")/../.."
root=$PWD; work=$root/build/realworld
pin=68f15d81b8cc378053c78c2a087b691851bdc2ac   # ko1/astro main, 2026-10-24
src=$work/astro
if [ ! -d "$src/.git" ]; then
  mkdir -p "$src" && git -C "$src" init -q &&
    git -C "$src" remote add origin https://github.com/ko1/astro || exit 1
fi
if [ "$(git -C "$src" rev-parse -q --verify "$pin^{commit}" 2>/dev/null)" != "$pin" ]; then
  git -C "$src" fetch -q --depth 1 origin "$pin" || { echo "SKIP astro: fetch failed"; exit 0; }
fi
git -C "$src" checkout -q "$pin" || { echo "FAIL astro: checkout $pin failed"; exit 1; }
command -v ruby >/dev/null || { echo "SKIP astro: no ruby (ASTroGen is a Ruby program)"; exit 0; }

export LC_ALL=C.UTF-8   # node.def holds non-ASCII text; the generator reads it as UTF-8
backends=${NFCXX_BACKEND:-"gcc qbe"}
fail=0; tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT

# One patched copy per backend: the generated files and the code store live in it.
for b in $backends; do
  t=$tmp/$b; mkdir -p "$t/sample"
  cp -r "$src/lib" "$src/runtime" "$t/"
  cp -r "$src/sample/calc" "$src/sample/luastro" "$t/sample/"
  sed -i -E 's/\bit\./_1./g; s/#\{it\}/#{_1}/g' "$t/lib/astrogen.rb" "$t/sample/luastro/lua_gen.rb"
  sed -i 's/build_allocator_decl}\.join(";\\n")/build_allocator_decl}.join("\\n")/' "$t/lib/astrogen.rb"
  if ! grep -q 'build_allocator_decl}.join("\\n")' "$t/lib/astrogen.rb"; then
    echo "FAIL $b astro: the ;; patch no longer applies (astrogen.rb changed); move the pin and the patch together"; fail=1; continue
  fi
  export NFCXX_BACKEND=$b
  cc="$root/nfcc -I. -I../../runtime"

  # calc
  d=$t/sample/calc
  if ! out=$(cd "$d" && ruby -I ../../lib -r astrogen -e 'ASTroGen.start []' 2>&1 | grep -v 'warning:' ); then :; fi
  [ -f "$d/node_head.h" ] || { echo "FAIL $b astro calc: ASTroGen: $(head -1 <<<"$out")"; fail=1; continue; }
  if ! out=$(cd "$d" && $cc -DCALC_SRC_DIR="\"$d\"" -DASTRO_RUNTIME_DIR="\"$t/runtime\"" -o calc main.c parse.c node.c -ldl 2>&1); then
    echo "FAIL $b astro calc: build blocked: $(grep -m1 -E 'error|undefined' <<<"$out" || head -1 <<<"$out")"; fail=1; continue
  fi
  got=$(cd "$d" && ./calc --plain -q -e '1 + 2 * 3' 2>&1)
  [ "$got" = 7 ] || { echo "FAIL $b astro calc: --plain gave '$got', want 7"; fail=1; continue; }
  # The Code Store writes SD_*.c, compiles them with $(CC) (nfcc here) into all.so and loads it.
  got=$(cd "$d" && CC="$root/nfcc" timeout 300 ./calc -q --disasm -e '(4 + 5) * 6' 2>&1)
  if ! grep -q '<SD_' <<<"$got" || [ "$(tail -1 <<<"$got")" != 54 ] || [ ! -f "$d/code_store/all.so" ]; then
    echo "FAIL $b astro calc: specialization through nfcc: $(tail -3 <<<"$got" | tr '\n' ' ')"; fail=1; continue
  fi
  echo "ok   $b astro calc: built; --plain and specialized (SD_* compiled by nfcc, loaded from code_store/all.so) give 7 and 54"

  # luastro
  d=$t/sample/luastro
  if ! out=$(cd "$d" && ruby -I ../../lib -I . -r astrogen -r lua_gen -e 'ASTroGen.start([], node_def_class: LuaNodeDef)' 2>&1 | grep -v 'warning:'); then :; fi
  [ -f "$d/node_head.h" ] || { echo "FAIL $b astro luastro: ASTroGen: $(head -1 <<<"$out")"; fail=1; continue; }
  if ! out=$(cd "$d" && $cc -rdynamic -o luastro main.c node.c -ldl -lm -lpthread 2>&1); then
    echo "FAIL $b astro luastro: build blocked: $(grep -m1 -E 'error|undefined' <<<"$out" || head -1 <<<"$out")"; fail=1; continue
  fi
  got=$(cd "$d" && ./luastro examples/hello.lua 2>&1 | head -1)
  [ "$got" = "hello, luastro" ] || { echo "FAIL $b astro luastro: hello.lua gave '$got'"; fail=1; continue; }
  got=$(cd "$d" && ./luastro examples/fib.lua 2>&1)
  [ "$got" = 832040 ] || { echo "FAIL $b astro luastro: fib(30) gave '$got'"; fail=1; continue; }
  ok=1; : > "$tmp/lua-$b.out"
  for f in "$d"/test/test_*.lua; do
    out=$(cd "$d" && timeout 120 ./luastro "$f" 2>&1); rc=$?
    printf '%s rc=%s\n%s\n' "$(basename "$f")" "$rc" "$out" >> "$tmp/lua-$b.out"
    [ $rc -eq 0 ] || { echo "FAIL $b astro luastro: $(basename "$f") exited $rc"; ok=0; fail=1; }
  done
  [ $ok = 1 ] && echo "ok   $b astro luastro: built; hello.lua, fib(30)=832040 and $(ls "$d"/test/test_*.lua | wc -l) test scripts ran"
done

# luastro's tests have no .expected files (its runner uses a system lua5.4); the two builds must agree instead.
if [ -s "$tmp/lua-gcc.out" ] && [ -s "$tmp/lua-qbe.out" ]; then
  if cmp -s "$tmp/lua-gcc.out" "$tmp/lua-qbe.out"; then echo "ok   astro luastro: gcc and qbe builds print the same for every test script"
  else echo "FAIL astro luastro: gcc and qbe builds differ:"; diff "$tmp/lua-gcc.out" "$tmp/lua-qbe.out" | head -10; fail=1; fi
fi
exit $fail
