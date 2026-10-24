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
# ASTRO_GEN=mruby runs ASTroGen under the repo's mruby (scripts/astrogen-mruby, scripts/mruby-astrogen.rb) instead of CRuby; if
# CRuby is also present every generated file is compared with CRuby's, byte for byte. CRuby is still used below for Prism's
# templates and the node.def patches (baruby_precise, koruby_precise); without it only calc and luastro run.
exec 3>&2
have_ruby=1; command -v ruby >/dev/null || have_ruby=0
if [ "${ASTRO_GEN:-ruby}" = mruby ]; then
  gen_mruby=1
  [ -x "$root/build/mruby-tool/bin/mruby" ] || "$root/scripts/setup-mruby.sh" >/dev/null || { echo "SKIP astro: no mruby"; exit 0; }
else
  gen_mruby=0
  [ $have_ruby = 1 ] || { echo "SKIP astro: no ruby (ASTroGen is a Ruby program; ASTRO_GEN=mruby uses the repo's mruby)"; exit 0; }
fi
# astrogen ARGS: ASTroGen as `ruby ARGS` (-I dir, -r lib, -e code) in the current directory, with CRuby or mruby.
astrogen() {
  if [ $gen_mruby = 0 ]; then ruby "$@"; return; fi
  "$root/scripts/astrogen-mruby" "$@" || return
  [ $have_ruby = 1 ] || return 0
  local keep f; keep=$(mktemp -d)
  for f in node_*.c node_head.h; do cp "$f" "$keep/"; done
  ruby "$@" || { rm -rf "$keep"; return 1; }
  for f in node_*.c node_head.h; do
    cmp -s "$f" "$keep/$f" || { echo "astro: mruby and CRuby generated different $f in $PWD"; rm -f node_head.h; rm -rf "$keep"; return 1; }
  done
  [ "$(ls node_*.c node_head.h | wc -l)" = "$(ls "$keep" | wc -l)" ] || { echo "astro: mruby and CRuby generated different file sets in $PWD"; rm -f node_head.h; rm -rf "$keep"; return 1; }
  rm -rf "$keep"; echo "ok   astro ASTroGen under mruby: $(basename "$PWD") output identical to CRuby's ($(ls node_*.c node_head.h | wc -l) files)" >&3
}

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
  if ! out=$(cd "$d" && astrogen -I ../../lib -r astrogen -e 'ASTroGen.start []' 2>&1 | grep -v 'warning:' ); then :; fi
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
  if ! out=$(cd "$d" && astrogen -I ../../lib -I . -r astrogen -r lua_gen -e 'ASTroGen.start([], node_def_class: LuaNodeDef)' 2>&1 | grep -v 'warning:'); then :; fi
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

[ $have_ruby = 1 ] || { echo "SKIP astro baruby_precise, koruby_precise: CRuby is needed for Prism's templates and the patches"; exit $fail; }
# ---- baruby_precise: Ruby subset on a precise GC, needs Prism (the Ruby parser, C). ----
# libprism at the commit sample/naruby pins (baruby_precise's prism is a symlink to naruby's), built by nfcc on both
# backends, then baruby_precise on both. Its UNWRAP and WITH_CHILD_CHAIN macros are GNU statement expressions ({ ... }), which
# cproc has since the pin 9f706f5; the one _Atomic(int) of astro_jit.c is patched out on qbe (docs/notes/astro.md).
ppin=09d9ac3d6cc93a049144ad057b0feb3013081690   # ruby/prism, what ko1/astro pins for sample/naruby
psrc=$work/prism-09d9ac3
if [ ! -d "$psrc/.git" ]; then
  mkdir -p "$psrc" && git -C "$psrc" init -q && git -C "$psrc" remote add origin https://github.com/ruby/prism || exit 1
fi
if [ "$(git -C "$psrc" rev-parse -q --verify "$ppin^{commit}" 2>/dev/null)" != "$ppin" ]; then
  git -C "$psrc" fetch -q --depth 1 origin "$ppin" || { echo "SKIP astro prism: fetch failed"; exit $fail; }
fi
git -C "$psrc" checkout -q "$ppin" || { echo "FAIL astro prism: checkout $ppin failed"; exit 1; }
# The templates (include/prism/ast.h, src/node.c, ...) are generated from templates/*.erb; rake only calls this.
if ! out=$(cd "$psrc" && ruby -e 'require "./templates/template.rb"; Prism::Template::TEMPLATES.each { |f| Prism::Template.render(f) }' 2>&1); then
  echo "FAIL astro prism: template generation: $(head -1 <<<"$out")"; exit 1
fi
for b in $backends; do
  export NFCXX_BACKEND=$b   # the first loop left the last backend exported
  pl=$tmp/prism-$b; mkdir -p "$pl/build"
  if ! out=$(cd "$psrc" && NFCXX_BACKEND=$b "$root/nfcc" -shared -fPIC -Iinclude -DPRISM_EXPORT_SYMBOLS \
        -o "$pl/build/libprism.so" src/*.c src/util/*.c 2>&1); then
    echo "FAIL $b astro prism: libprism build blocked: $(grep -m1 -E 'error|undefined' <<<"$out" || head -1 <<<"$out")"; fail=1; continue
  fi
  printf '#include <prism.h>\n#include <stdio.h>\nint main(void){puts(pm_version());return 0;}\n' > "$pl/v.c"
  got=$(NFCXX_BACKEND=$b "$root/nfcc" -I"$psrc/include" "$pl/v.c" -L"$pl/build" -Wl,-rpath="$pl/build" -lprism -o "$pl/v" 2>&1 && "$pl/v" 2>&1)
  if ! [[ $got =~ ^[0-9]+\.[0-9]+\.[0-9]+ ]]; then echo "FAIL $b astro prism: libprism built, pm_version() gave '$got'"; fail=1; continue; fi
  echo "ok   $b astro prism: libprism $got built by nfcc and loaded"
  t=$tmp/bp-$b; mkdir -p "$t/sample"; cp -r "$src/lib" "$src/runtime" "$t/"; cp -r "$src/sample/baruby_precise" "$t/sample/"
  d=$t/sample/baruby_precise; rm -f "$d/prism"; mkdir -p "$d/prism"; ln -s "$psrc/include" "$d/prism/include"; ln -s "$pl/build" "$d/prism/build"
  if [ $b = qbe ]; then
    # cproc has no _Atomic (cproc's own error). astro_jit.c has one _Atomic(int) field and reads and writes it only through
    # atomic_load_explicit / atomic_store_explicit, so those become the sized builtins of cproc's atomic support.
    sed -i -e 's|#include <stdatomic.h>|#define memory_order_acquire __ATOMIC_ACQUIRE\n#define memory_order_release __ATOMIC_RELEASE\n#define atomic_load_explicit(p, mo) __atomic_load_n((p), (mo))\n#define atomic_store_explicit(p, v, mo) __atomic_store_n((p), (v), (mo))|' \
           -e 's|_Atomic(int) stop_flag;|int stop_flag;|' "$d/astro_jit.c"
    grep -q '_Atomic' "$d/astro_jit.c" && { echo "FAIL $b astro baruby_precise: the _Atomic patch no longer applies (astro_jit.c changed)"; fail=1; continue; }
  fi
  sed -i -E 's/\bit\./_1./g; s/#\{it\}/#{_1}/g' "$t/lib/astrogen.rb" "$d/baruby_gen.rb"
  sed -i 's/build_allocator_decl}\.join(";\\n")/build_allocator_decl}.join("\\n")/' "$t/lib/astrogen.rb"
  out=$(cd "$d" && astrogen -I ../../lib -r ./baruby_gen -e 'ASTroGen.start([], node_def_class: BaRubyNodeDef)' 2>&1 | grep -v 'warning:')
  [ -f "$d/node_head.h" ] || { echo "FAIL $b astro baruby_precise: ASTroGen: $(head -1 <<<"$out")"; fail=1; continue; }
  r=$t/runtime
  if ! out=$(cd "$d" && "$root/nfcc" -I./prism/include -I. -I"$r" -rdynamic -DBARUBY_GC=5 -DBARUBY_PRECISE_DIR="\"$d\"" \
        -DASTRO_RUNTIME_DIR="\"$r\"" -DASTRO_PRISM_INC_DIR="\"$d/prism/include\"" -L./prism/build -Wl,-rpath="$pl/build" \
        -o baruby_precise main.c node.c node_slowpath.c baruby_parse.c astro_jit.c "$r/precise_gc/gc_common.c" "$r/precise_gc/gc_copy.c" \
        -lprism -ldl 2>&1); then
    echo "FAIL $b astro baruby_precise: build blocked: $(grep -m1 -E 'error|undefined' <<<"$out" || head -1 <<<"$out")"; fail=1; continue
  fi
  got=$(cd "$d" && ./baruby_precise --plain test_ary.ba.rb 2>&1 | head -2 | tr '\n' ' ')
  [ "$got" = "[1, 2, 3] 3 " ] || { echo "FAIL $b astro baruby_precise: --plain test_ary gave '$got'"; fail=1; continue; }
  # The bake: --aot-compile specializes, the code store's makefile compiles the SD_*.c with $(CC) = nfcc (which must take
  # the store's --param=early-inlining-insns=100), and the run loads all.so.
  echo 'def fib(n); if n < 2 then n else fib(n-1) + fib(n-2) end; end; p fib(30)' > "$d/fib.ba.rb"
  got=$(cd "$d" && CC="$root/nfcc" timeout 600 ./baruby_precise --aot-compile --run fib.ba.rb 2>&1 | head -3 | tr '\n' ' ')
  if [[ $got != 832040* ]] || [ ! -f "$d/code_store/all.so" ]; then
    echo "FAIL $b astro baruby_precise: AOT through nfcc: '$got' all.so=$([ -f "$d/code_store/all.so" ] && echo yes || echo no)"; fail=1; continue
  fi
  echo "ok   $b astro baruby_precise: built; --plain right, --aot-compile compiled SD_*.c through nfcc and ran fib(30)=832040 from all.so"
done

# ---- koruby_precise: ASTro's CRuby-compatible Ruby (26,000-line runtime, Prism, zlib, libyaml, a regex engine in astrogre). ----
# BIGNUM=wrap (no GMP); its Prism is the commit sample/koruby_precise pins (not sample/naruby's). The regex engine is
# sample/astrogre as two shared objects (libastrogre.so, koruby_regex.so) that koruby loads at run time: AVX2, built with the
# gcc backend for both (x86-64 only). Both backends build the interpreter and run tests/realworld/koruby_test.rb, whose
# output must equal CRuby's (koruby_test.expected). The AOT bake is not run here: it compiles hundreds of SD_*.c files
# (about 8 minutes on qbe).
patch_once() {  # patch_once FILE OLD NEW: replace the one occurrence of OLD in FILE, or stop
  ruby -e 'f, o, n = ARGV; s = File.read(f); unless s.scan(o).size == 1 then warn "patch: #{o.inspect} not found once in #{f}"; exit 1 end; File.write(f, s.sub(o) { n })' -- "$@"
}
if [ "$(uname -m)" != x86_64 ]; then echo "SKIP astro koruby_precise: astrogre is AVX2 (x86-64 only)"; exit $fail; fi
kpin=13325f5c3995017bd2594ff7d76053d9c7ac08d5   # ruby/prism, what ko1/astro pins for sample/koruby_precise
ksrc=$work/prism-13325f5
if [ ! -d "$ksrc/.git" ]; then
  mkdir -p "$ksrc" && git -C "$ksrc" init -q && git -C "$ksrc" remote add origin https://github.com/ruby/prism || exit 1
fi
if [ "$(git -C "$ksrc" rev-parse -q --verify "$kpin^{commit}" 2>/dev/null)" != "$kpin" ]; then
  git -C "$ksrc" fetch -q --depth 1 origin "$kpin" || { echo "SKIP astro koruby_precise: prism fetch failed"; exit $fail; }
fi
git -C "$ksrc" checkout -q "$kpin" || { echo "FAIL astro koruby_precise: checkout $kpin failed"; exit 1; }
if ! out=$(cd "$ksrc" && ruby -e 'require "./templates/template.rb"; Prism::Template::TEMPLATES.each { |f| Prism::Template.render(f) }' 2>&1); then
  echo "FAIL astro koruby_precise: prism templates: $(head -1 <<<"$out")"; exit 1
fi
mkdir -p "$tmp/ag"; cp -r "$src/lib" "$src/runtime" "$tmp/ag/"; mkdir -p "$tmp/ag/sample"; cp -r "$src/sample/astrogre" "$src/sample/koruby_precise" "$tmp/ag/sample/"
sed -i -E 's/\bit\./_1./g; s/#\{it\}/#{_1}/g' "$tmp/ag/lib/astrogen.rb"
sed -i 's/build_allocator_decl}\.join(";\\n")/build_allocator_decl}.join("\\n")/' "$tmp/ag/lib/astrogen.rb"
export NFCXX_BACKEND=gcc
ag=$tmp/ag/sample/astrogre; kd=$tmp/ag/sample/koruby_precise
(cd "$ag" && astrogen -I ../../lib -r astrogen -e 'ASTroGen.start []' 2>&1 | grep -v 'warning:')
if ! out=$(cd "$ag" && "$root/nfcc" -I. -I../../runtime -O2 -mavx2 -fPIC -shared -Wl,--version-script=libastrogre.map -o libastrogre.so \
      node.c parse.c match.c backend_astrogre.c aho_corasick.c unicode_prop.c unicode_tables.c libastrogre_option.c -ldl 2>&1) ||
   ! out=$(cd "$kd" && "$root/nfcc" -shared -fPIC -O2 -mavx2 -I../astrogre -I../../runtime regex_bridge.c -L../astrogre -lastrogre \
      -Wl,-rpath,"$ag" -o koruby_regex.so 2>&1); then
  echo "FAIL astro koruby_precise: the regex engine (astrogre) build blocked: $(grep -m1 -E 'error|undefined' <<<"$out" || head -1 <<<"$out")"; exit 1
fi
for b in $backends; do
  export NFCXX_BACKEND=$b
  t=$tmp/kp-$b; mkdir -p "$t/sample"; cp -r "$tmp/ag/lib" "$tmp/ag/runtime" "$t/"; cp -r "$tmp/ag/sample/astrogre" "$tmp/ag/sample/koruby_precise" "$t/sample/"
  d=$t/sample/koruby_precise; r=$t/runtime
  rm -rf "$d/prism"; mkdir -p "$d/prism/build/obj"; ln -s "$ksrc/include" "$d/prism/include"
  sed -i -E 's/\bit\./_1./g; s/#\{it\}/#{_1}/g' "$d/koruby_gen.rb"
  # ASTRO_LAZY_ARGS(x) reads x->head.dispatcher even when x is NULL (a def without an entry). gcc drops the dead load after inlining,
  # QBE keeps it and the program crashes in DISPATCH_node_def.
  patch_once "$t/lib/astrogen.rb" '#define ASTRO_LAZY_ARGS(x) (x)->head.dispatcher' '#define ASTRO_LAZY_ARGS(x) ((x) ? (x)->head.dispatcher : NULL)' || { fail=1; continue; }
  cflags=(-I. -I./prism/include -I"$r" -DBARUBY_GC=5 -DASTRO_DEBUG=0 -DKORUBY_SRC_DIR="\"$d\"" -DASTRO_RUNTIME_DIR="\"$r\""
          -DASTRO_PRISM_INC_DIR="\"$d/prism/include\"" -DKORB_BIGNUM=2 -DKORUBY_GC_SRC="\"$r/precise_gc/gc_copy.c\"" -DPATH_MAX=4096)
  [ -e /usr/include/zlib.h ] && cflags+=(-DKORB_HAVE_ZLIB) && libz=-lz || libz=
  [ -e /usr/include/yaml.h ] && cflags+=(-DKORB_HAVE_YAML) && liby=-lyaml || liby=
  if [ $b = qbe ]; then
    # cproc has no inline assembly: node.def's korb_sdi_klass has a portable form under KORB_SD_SHARE_KL (the asm after its
    # early return is still parsed), so the asm goes into the #else. parse.c's static array is initialised from Prism's
    # `static const uint8_t` constants, which gcc accepts as a constant and ISO C does not. __builtin_return_address is only
    # used to bind call sites in AOT code (astro_ld_patch_call); null leaves them unbound.
    patch_once "$d/node.def" $'    return korb_sdi_klass_slow(vm, r);\n#endif\n' $'    return korb_sdi_klass_slow(vm, r);\n#else\n' || { fail=1; continue; }
    patch_once "$d/node.def" $'    return k;\n}\n/* NFN = how many builtins' $'    return k;\n#endif\n}\n/* NFN = how many builtins' || { fail=1; continue; }
    patch_once "$d/parse.c" 'static const uint8_t flag[5] = { PM_OPTIONS_SCOPE_FORWARDING_POSITIONALS' 'const uint8_t flag[5] = { PM_OPTIONS_SCOPE_FORWARDING_POSITIONALS' || { fail=1; continue; }
    sed -i 's/__builtin_return_address(0)/((const void *)0)/' "$d/korb_runtime.c"
    # In context.h, not on the command line: the code store compiles the generated SD_*.c with its own flags, and they include it.
    sed -i '1i #define KORB_SD_SHARE_KL 1' "$d/context.h"
    # The code store's loader path ("patch" objects) is built on inline assembly (loader/arch_x86_64.h: the holes are
    # relocations), which cproc cannot compile. ASTRO_ARCH_FORCE_NONE is ASTro's switch for a machine without a loader backend:
    # the store then builds the pool-mode objects, plain C. korb_runtime.c calls astro_ld_patch_call and astro_ld_call_reset
    # without a guard, which that mode does not define, so they get stubs.
    cflags+=(-DASTRO_ARCH_FORCE_NONE)
    patch_once "$r/astro_code_store.c" $'unsigned astro_ld_patch_imm(uintptr_t key, uintptr_t value) { (void)key; (void)value; return 0; }' \
      $'unsigned astro_ld_patch_imm(uintptr_t key, uintptr_t value) { (void)key; (void)value; return 0; }\nbool astro_ld_patch_call(const void *ret, uintptr_t target, uintptr_t expect) { (void)ret; (void)target; (void)expect; return false; }\nbool astro_ld_call_reset(const void *ret, uintptr_t host) { (void)ret; (void)host; return false; }' || { fail=1; continue; }
  fi
  (cd "$d" && astrogen -I ../../lib -r ./koruby_gen -e 'ASTroGen.start([], node_def_class: KorubyNodeDef)' 2>&1 | grep -v 'warning:')
  [ -f "$d/node_head.h" ] || { echo "FAIL $b astro koruby_precise: ASTroGen"; fail=1; continue; }
  pfail=0
  for f in "$ksrc"/src/*.c "$ksrc"/src/util/*.c; do
    [ -f "$f" ] || continue
    (cd "$ksrc" && "$root/nfcc" -Iinclude -DPRISM_EXPORT_SYMBOLS -c "$f" -o "$d/prism/build/obj/$(basename "$f" .c).o" >"$tmp/prism-$b.log" 2>&1) || { pfail=1; break; }
  done
  [ $pfail = 0 ] || { echo "FAIL $b astro koruby_precise: libprism build: $(grep -m1 error "$tmp/prism-$b.log")"; fail=1; continue; }
  ar rcs "$d/prism/build/libprism.a" "$d/prism/build/obj"/*.o
  # the translation units in parallel: the runtime alone is 26,000 lines
  units=(main node parse korb_runtime); pids=()
  for u in "${units[@]}"; do (cd "$d" && "$root/nfcc" "${cflags[@]}" -c "$u.c" -o "$u.o" >"$tmp/kp-$b-$u.log" 2>&1) & pids+=($!); done
  for u in gc_common gc_copy; do (cd "$d" && "$root/nfcc" "${cflags[@]}" -c "$r/precise_gc/$u.c" -o "$u.o" >"$tmp/kp-$b-$u.log" 2>&1) & pids+=($!); done
  cfail=0; for p in "${pids[@]}"; do wait "$p" || cfail=1; done
  if [ $cfail = 1 ]; then
    echo "FAIL $b astro koruby_precise: compile: $(cat "$tmp"/kp-$b-*.log | grep -m1 -E 'error')"; fail=1; continue
  fi
  if ! out=$(cd "$d" && "$root/nfcc" -rdynamic -o koruby_precise main.o node.o korb_runtime.o parse.o gc_common.o gc_copy.o prism/build/libprism.a -ldl -lm -lcrypt $libz $liby 2>&1); then
    echo "FAIL $b astro koruby_precise: link: $(grep -m1 -E 'error|undefined' <<<"$out" || head -1 <<<"$out")"; fail=1; continue
  fi
  cp "$kd/koruby_regex.so" "$d/"
  got=$(cd "$d" && timeout 300 ./koruby_precise "$root/tests/realworld/koruby_test.rb" 2>&1); rc=$?
  if [ $rc -ne 0 ] || [ "$got" != "$(cat "$root/tests/realworld/koruby_test.expected")" ]; then
    echo "FAIL $b astro koruby_precise: built, but koruby_test.rb gave rc=$rc and differs from CRuby's output:"; diff <(echo "$got") "$root/tests/realworld/koruby_test.expected" | head -6; fail=1; continue
  fi
  echo "ok   $b astro koruby_precise: built (BIGNUM=wrap); koruby_test.rb prints what CRuby prints"
done
exit $fail
