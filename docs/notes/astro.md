# ASTro built with nfcc

[ASTro](https://github.com/ko1/astro) (ko1) is an AST-interpreter framework. A `node.def` file defines node types as C
functions; ASTroGen (`lib/astrogen.rb`, Ruby) generates the evaluator, dispatchers, allocators, a Merkle hash of every
subtree and a partial evaluator. The partial evaluator writes one C function per distinct subtree (`SD_<hash>`); the Code
Store (`runtime/astro_code_store.c`) compiles them with `$(CC)` into `all.so` and `dlopen`s it, swapping the node's
dispatcher. So ASTro's compiler back end is whatever C compiler it is given, and `nfcc` can be that compiler.

`tests/realworld/run_astro.sh` (a step of `realworld.yml`) clones a pinned commit into `build/realworld/astro` and, on
each backend, builds some of its samples with nfcc:

| Sample | What it is | Checked |
| --- | --- | --- |
| `sample/calc` | the 6-node tutorial calculator | `--plain` gives 7; a normal run compiles `SD_*.c` through nfcc (`CC=nfcc`), loads `code_store/all.so`, and gives 54 for `(4 + 5) * 6` |
| `sample/luastro` | a Lua subset (74 nodes) | `hello.lua`, `fib(30)` = 832040, and its 8 `test/test_*.lua` scripts exit 0; the qbe and gcc builds print the same for every script (the upstream runner compares with a system `lua5.4`, which CI does not have) |

| `sample/baruby_precise` | a Ruby subset on a precise copying GC, parsed by Prism | `--plain` prints the right array; `--aot-compile --run` compiles the `SD_*.c` through nfcc, writes `code_store/all.so` and runs `fib(30)` = 832040 |
| `sample/koruby_precise` | ASTro's flagship: a CRuby-compatible Ruby (26,000-line runtime, 119 node types, Prism, zlib, libyaml, a regex engine from `sample/astrogre`) | built with `BIGNUM=wrap` (no GMP); `tests/realworld/koruby_test.rb` (21 lines of output: recursion, blocks, classes, `Comparable`, exceptions, regexps, `format`, `Struct`) prints what CRuby prints, on both backends |
| Prism (`ruby/prism`, the Ruby parser; C) | the library baruby_precise links | `libprism.so` built by nfcc on both backends and loaded by a small program calling `pm_version()` |

```
tests/realworld/run_astro.sh                   # both backends, about 45 s once the clones exist
NFCXX_BACKEND=qbe tests/realworld/run_astro.sh
```

Needs `ruby` for ASTroGen. The script runs the generator and nfcc directly, not ASTro's makefiles. It prints `SKIP` when
the clone cannot be fetched or ruby is missing.

## Two patches, applied to a copy

The clone stays at the pin; each run copies `lib`, `runtime` and the samples and patches the copy.

1. **Ruby 3.4's `it`.** `lib/astrogen.rb` and `sample/luastro/lua_gen.rb` use the implicit block parameter `it`, which
   exists from Ruby 3.4. On 3.3 (the host here, and the Ruby of many distributions) the generator stops with
   `undefined local variable or method 'it'`. `_1` is the same parameter and works on Ruby 2.7 and later, so
   `s/\bit\./_1./` and `s/#{it}/#{_1}/` are applied.
2. **`;;` at file scope.** `build_allocator_decl` returns `"NODE *ALLOC_x(...);"` and the caller joins the results with
   `";\n"`, so `node_head.h` holds `NODE *ALLOC_node_num(int32_t num);;`. An empty declaration at file scope is not
   ISO C (gcc accepts it, as an extension). cproc stops with `unexpected ';' at top-level`. The patch joins with `"\n"`.
   This is a bug in ASTro, worth sending upstream together with the `it` change.

Also: the generator reads `node.def` as UTF-8, so the script exports `LC_ALL=C.UTF-8`; under the C locale Ruby stops with
`invalid byte sequence in US-ASCII`.

## Prism and baruby_precise

`baruby_precise` links libprism. `sample/baruby_precise/prism` is a symlink to `sample/naruby/prism`, a submodule, so the
script fetches that commit (`09d9ac3`, not the `13325f5` that `koruby_precise` pins; the newer headers do not compile
against baruby_precise) into `build/realworld/prism-09d9ac3`. Prism's C sources need generated files (`include/prism/ast.h`,
`src/node.c`, ...); `rake templates` only calls `Prism::Template.render` on each of `Prism::Template::TEMPLATES`, so the
script does that directly with ruby and needs neither rake nor bundler. libprism builds with nfcc on both backends.

**Statement expressions in cproc.** baruby_precise did not build on the qbe backend: its `UNWRAP(r)` macro (`context.h`) and
`WITH_CHILD_CHAIN` (`baruby_parse.c`) are GNU statement expressions, `({ RESULT _r = (r); if (...) return _r; _r.value; })`.
They return from the enclosing function in the middle of an expression, which cannot be written another way without
rewriting every node, and cproc stopped with `error: expected primary expression`. cproc now has them (the fork's branch
`nfcxx-stmt-expr`, the pin of `3rd/cproc`): the body is parsed into a chain of blocks of its own, and the chain is linked
into the function where the expression is evaluated, so the body runs inside the branch of `?:`, `&&` and `||` or a loop
condition that holds it, not where it is parsed. `return`, `goto` and `break` out of a body are ordinary jumps. The value is
that of the last expression statement; with none the expression is void. `tests/c/stmt_expr.c` checks all of this on both
backends against gcc's answers; cproc's own `test/stmt-expr.c` compares the IL.

Two smaller things were needed after that:

- **`_Atomic`.** `astro_jit.c` has one `_Atomic(int)` field, read and written only through `atomic_load_explicit` and
  `atomic_store_explicit`. cproc has no `_Atomic` and nfcc does not drop a qualifier silently, so on qbe the script patches the
  copy: the field becomes `int` and the two macros become `__atomic_load_n` / `__atomic_store_n`, which cproc supports.
- **Weak definitions in hand-written C.** `gc_common.c` defines `aro_gc_realloc_in_place` and three more as
  `__attribute__((weak))` defaults that a GC backend overrides, and the link stopped with `multiple definition`. nfcc marks
  weak symbols in the assembly from the preprocessed text (`scripts/weak-symbols.rb`), but for hand-written C that text has
  no attributes: without `__GNUC__` glibc's `<sys/cdefs.h>` defines `__attribute__` away. `qbe-cc` now also preprocesses the
  source plainly and gives that text to `weak-symbols.rb` (which learned `__attribute__((weak))`, besides EDG's `__weak__`)
  when it holds a weak attribute. `tests/c/cc-mode.sh` has a strong-over-weak link in both orders.

On qbe the main program is slow and deep: `ackermann.ba.rb` (`bench/`) needs a stack above the default 8 MiB (a frame is larger
without an optimiser; 64 MiB works) and runs 38 s against 9 s on the gcc backend. The AOT bake works there too and `fib(30)`
is right, but it does not make it faster (38 s for `ackermann` either way): QBE does not inline the evaluator calls the
specialization leaves in place.

**nfcc needed `--param`.** The Code Store's makefile passes `--param=early-inlining-insns=100` to every compile, and nfcc
stopped with `unsupported option`. `--param name=value` and `--param=name=value` are gcc's optimiser tuning knobs and change
no meaning, so `nfcc` now gives them to gcc on the gcc backend and ignores them on qbe, like `-march` (`tests/c/cc-mode.sh`).

With that, `ackermann.ba.rb` (`bench/`) goes from 9.8 s with `--plain` to 2.2 s after `--aot-compile --run` through nfcc on
the gcc backend (one run each, this machine).

## koruby_precise

ASTro's largest sample (`sample/koruby_precise`: a 26,000-line runtime, `parse.c`, 119 node types) is built with `BIGNUM=wrap`,
so no GMP, and zlib and libyaml when their headers are there. Its Prism is the commit it pins (`13325f5`), not `sample/naruby`'s;
libprism is built as a static archive. The regex engine is `sample/astrogre`, loaded at run time as `libastrogre.so` and
`koruby_regex.so` (without them even the prelude fails on its first `=~`). It uses AVX2 intrinsics, so those two are built with the
gcc backend for both runs, and the whole check is x86-64 only. Compile time of the runtime unit: 1 min 50 s on the gcc backend,
28 s on qbe.

On the gcc backend it needs one flag: `-DPATH_MAX=4096` (bug 7 below). The qbe backend needed these changes, each applied to the
copy by `run_astro.sh`:

- **Inline assembly in `node.def`.** `korb_sdi_klass` selects a class with three `cmov` sequences (`__asm__`). Under
  `#ifdef KORB_SD_SHARE_KL` it has a plain-C form that returns early; the asm after it is still parsed, so cproc stops. The patch
  moves the asm into the `#else` and defines `KORB_SD_SHARE_KL` at the top of `context.h`. (It must be in `context.h`: the code
  store compiles the generated `SD_*.c` with its own flags, and they include it.) That form has a branch per receiver kind where
  the asm has none, so the generated code is slower; it is the form ASTro itself offers.
- **The code store's loader path.** The store builds two kinds of object: the "patch" objects, whose holes are relocations written
  with inline asm (`loader/arch_x86_64.h`), and the pool objects, plain C. On qbe the patch objects cannot be built and, with
  them failing, the store ends up with no compiled code at all (the program falls back to the interpreter without a message). `-DASTRO_ARCH_FORCE_NONE` is ASTro's switch
  for a machine with no loader backend; the store then builds the pool objects. That mode is missing two stubs (bug 8), which the
  patch adds.
- **`__builtin_return_address(0)`** in `korb_entry_call`, which binds call sites in loader-patched code. It becomes a null
  pointer, which `astro_ld_call_site` already rejects, so the sites stay unbound (this is the pool mode's behaviour anyway).
- **A null `entry` read by `ASTRO_LAZY_ARGS`** (bug 5): the first `def` of the prelude crashed in `DISPATCH_node_def`.
- **`static const` in a constant initializer** (bug 6).

The AOT bake (`--aot-compile --run` of `def fib(n) = n < 2 ? n : fib(n-1) + fib(n-2); puts fib(30)`) is where the qbe path runs out of
patience, and it is not in the test: the program is right (832040, from the interpreter), but the store compiles thousands of
generated files (233 in `code_store`, 2793 in the pool mode's `preload_store`) and it did not finish in 25 minutes (82 CPU-minutes).
The next section says where the time goes.

## Why the bake is slow on qbe

One `SD_*.c` is a few lines (the specialized function) after `#include`s of `node_eval.c` and `node_dispatch.c`. After
`cc -E -P` that is a 0.8 MB translation unit (11,800 lines, 233,000 tokens) in which only the
last function is new; every file repeats the same 0.8 MB. Nothing in the pipeline is slow per byte: a file takes about two
seconds, and the time is the number of files times the same prefix. The 82 CPU-minutes are 2793 files at about 1.8 s.

One small SD file (`nfcc -c`, `NFCXX_BACKEND=qbe`, `-O3 -fPIC ...` as the store's makefile passes them; `NFCXX_TRACE`; seconds, a
shared 4-core machine, ranges of 3 to 4 runs). The gcc backend on the same file is 0.77 s for everything.

| stage | before | after (default) | after, `NFCXX_QBE_DCE=1` |
| --- | --- | --- | --- |
| `cc -E` | 0.10-0.14 | 0.09-0.13 | 0.09-0.10 |
| `qbe-prep.rb` (mruby) | 1.0-1.45 | 0.49-0.59 | 0.53-0.71 |
| cproc | 0.10-0.12 | 0.09-0.10 | 0.04-0.05 |
| qbe | 0.30-0.35 | 0.30-0.37 | 0.05 |
| `weak-symbols.rb` (mruby, with its second `cc -E`) | 0.19-0.25 | 0.14-0.23 | 0.09-0.10 |
| assemble | 0.02-0.14 | 0.02-0.14 | 0.01-0.04 |
| total | 1.8-2.3 | 1.2-1.4 | 0.9-1.1 |

Lua's `lvm.c` (59 KB, `-O2`): `cc -E` 0.07-0.10, `qbe-prep.rb` 0.26-0.29 (now 0.17-0.18), cproc 0.03-0.04, qbe 0.21-0.23,
`weak-symbols.rb` 0.09-0.13 (now 0.07-0.11), total 0.74-0.82 s (now 0.64-0.74). The biggest file of the pool store (1.5 MB
of `SD_*.c`, 3.4 MB after `cc -E`) takes 7.0 s (`qbe-prep.rb` 4.8-5.1) before and 4.0-4.1 s after.

So the suspects come out as: (1) the two mruby scripts were half of the time (`qbe-prep.rb` alone 50 to 60 %), not minutes: the
mruby start is 7 ms and its bytecode compile is nothing; the scan is linear (0.3 s per MB to tokenize) and was paying for a
walk over every token by three passes that could only matter in a few places. (2) cproc and qbe were a quarter of the time,
and most of what they emit is dead: an SD object is 306 KB with 752 local functions for a function of a few instructions (52 KB and
184 with `NFCXX_QBE_DCE=1`), since neither compiler drops an unused `static` function. (3) the interpreter's bytecode compile did not show.

What was changed:

- `qbe-prep.rb`: `bare_return_edits` looks for the tokens `return ;` first and, for each, finds its enclosing file-scope function
  backwards, instead of walking every function body and calling `match_fwd` for each (it was 0.37 s of 1.1); `volatile_locals`
  returns at once when no `volatile` token is inside braces (0.30 s); `void_typedefs` and `weak_function_names` only look at the
  tokens they can start from; the main loop skips the tokens that start no rewrite with direct array reads; the tokenizer keeps
  the brace and parenthesis depth as one running value. The fast paths need balanced braces (the tokenizer says so); otherwise the
  old walks run. `qbe-prep.rb` is 2 times faster on SD files and 1.5 times on `lvm.c`, with the same output.
- `weak-symbols.rb`: attribute groups are scanned by bytes and looked at only when they contain `weak`; the assembly's labels are
  read without a string per line. 2 times faster.
- `NFCXX_QBE_DCE=1` (opt-in; `qbe-prep.rb --dce`): the definitions of `static` functions that no live code mentions are removed
  before cproc, as gcc does by not emitting them. Roots are everything that is not such a definition, and anything with an
  attribute, inline asm or a `used`/`constructor`/`alias`/`weak`/`section` word; the strings of inline asm count as mentions.
  Prototypes of static functions mention nothing. The result is the same program with a smaller object (the SD file above: 1.25 MB
  of assembly becomes 0.22 MB, the object 306 KB becomes 52 KB), so it is not the same assembly and stays off by default; ASTro's bake, which compiles the same
  header thousands of times, is what it is for. 79 pool files (every 35th) compiled with four jobs: 35.1 s before, 23.9 s with
  the changes above, 15.2 s with `NFCXX_QBE_DCE=1` (gcc: 6.6 s). For the 2793 files that is about 21 minutes, 14 and 9 of wall
  time at `-j4` on this machine.

What did not help: reading the source as an array of bytes in the tokenizer (`String#bytes`, then `bs[i]` instead of `getbyte`)
did not change the time. The second `cc -E` that `qbe-cc` runs to find hand-written `__attribute__((weak))` costs 0.07 s and
was left. The part that remains is the shared prefix itself, read, tokenized and (without DCE) compiled in every file; avoiding
it needs the evaluator compiled once, which is a change in ASTro's code store, not in nfcc. Equivalence: `tests/mruby/qbe-asm.sh`
compares `nfcc -S` with the oracle ports of the two scripts on `tests/c`, Lua and (with `QBE_ASM_EXTRA`) SD files, and
`tests/mruby/qbe-prep.sh` compares the script with its oracle on its edge cases, including the new fast-path ones.

nfcc and cproc changes it led to: `qbe-cc` defines `__uint128_t` and `__int128_t` on every target (the code needed `__uint128_t`
for a 53-bit random-float product; cproc's `unsigned __int128` multiply and shift match gcc's, `tests/c/int128_typedefs.c`), and
`nfcc` accepts `-fno-jump-tables` and `-fno-crossjumping`, which the code store passes (gcc gets them, qbe ignores them).

## What the two backends do with the specialized code

For `1 + 2 * 3`, `calc --disasm` shows the whole tree turned into one function, `SD_dfb75fdabb0d5ef6`:

- **gcc backend** (`-O2`): the function is `mov $7,%eax; ret`. gcc inlines the chain of evaluators into the dispatcher
  and folds the constants, which is the point of partial evaluation.
- **qbe backend**: the function loads its children and calls `EVAL_node_add`. QBE has no inliner, so the generated
  code is correct but keeps the call structure of the interpreter, and the specialization buys little.

A rough timing of `luastro examples/fib.lua` (`fib(30)`, one run, interpreter as built): 0.075 s on the gcc backend and
0.27 s on the qbe backend.

## Bugs in ASTro, for upstream

Found while building the samples above. Not reported yet; each has a short fix. `run_astro.sh` works around 1, 2, 3 (it sets
`LC_ALL=C.UTF-8`), 5, 6, 7 (`-DPATH_MAX=4096`) and 8 on the copy; 4 is not hit by any build here.

1. **`node_head.h` has `;;` at file scope** (`lib/astrogen.rb`, `build_head`). `build_allocator_decl` returns
   `"NODE *ALLOC_x(...);"` and the caller joins the results with `";\n"`, so the header holds `NODE *ALLOC_node_num(int32_t num);;`.
   An empty declaration at file scope is not ISO C (gcc accepts it as an extension, `-Wpedantic` warns); cproc stops with
   `unexpected ';' at top-level`. Fix: join with `"\n"`.
2. **The generators need Ruby 3.4.** `lib/astrogen.rb`, `sample/luastro/lua_gen.rb`, `sample/baruby_precise/baruby_gen.rb` and
   `sample/koruby_precise/koruby_gen.rb` use the implicit block parameter `it`; on Ruby 3.3 they stop with `undefined local
   variable or method 'it'`. `_1` is the same parameter and works from Ruby 2.7.
3. **`node.def` is read in the locale's encoding.** Under `LANG=C`, `astrogen.rb:1175` raises `invalid byte sequence in
   US-ASCII` on `sample/luastro/node.def`. Read it as UTF-8.
4. **`--output-dir` raises `NameError`.** `parse_opt` (`astrogen.rb`, the `--output-dir` handler) assigns `output_file`, which is not
   a variable there; it means `output_dir`.
5. **`ASTRO_LAZY_ARGS(x)` dereferences a child that can be NULL** (the macro is emitted into `node_eval.c`: `#define
   ASTRO_LAZY_ARGS(x) (x)->head.dispatcher`). `node_def` has `NODE *entry`, which is NULL for some definitions, and
   `DISPATCH_node_def` passes `ASTRO_LAZY_ARGS(n->u.node_def.entry)` unconditionally. gcc deletes the load once the evaluator is
   inlined and the value is unused, so nothing happens; a compiler that keeps the load (QBE) crashes at the first `def` of the
   prelude. Fix: `((x) ? (x)->head.dispatcher : NULL)`.
6. **A `static const` object is used as a constant initializer** (`sample/koruby_precise/parse.c`: `static const uint8_t flag[5] = {
   PM_OPTIONS_SCOPE_FORWARDING_POSITIONALS, ... }`, where Prism declares `static const uint8_t PM_OPTIONS_SCOPE_FORWARDING_* = 0x2;`).
   A const object is not a constant expression in C before C23, so cproc rejects it. Drop the `static` on the array.
7. **`korb_runtime.c` uses `PATH_MAX` without `<limits.h>`.** It gets it from some other header on the author's system; with glibc
   2.39 and gcc 13 it is undeclared. Include `<limits.h>`.
8. **`koruby_precise` does not link where the loader is unsupported.** `korb_runtime.c` calls `astro_ld_patch_call` and
   `astro_ld_call_reset` unconditionally, while `astro_code_store.c` defines stubs only for `astro_ld_patch_imm` when
   `ASTRO_LOADER_SUPPORTED` is 0 (no `__linux__`, no architecture backend, or `-DASTRO_ARCH_FORCE_NONE`). Add the two stubs
   (return `false`) to that branch.

## Not done

- The other 25 samples.
- `koruby_precise` with GMP (`BIGNUM=gmp`, the default; `libgmp-dev` is not installed here), its AOT bake on qbe (above), the
  `--build` standalone executable, and the rubyspec suite.
- Compiling `sample/astrogre`'s AVX2 code on qbe: cproc cannot compile the intrinsics, so the regex engine is a gcc-backend
  shared object in both runs.
- `astro_build.c`'s `--build` (standalone executables) and the tiered JIT daemon.
- Running ASTroGen under the repo's mruby instead of CRuby (`lib/astrogen.rb` needs only `optparse`).
- Feeding ASTro's hashing and specialization into `lib/ast` (`ast.md`), the idea this note started from.
