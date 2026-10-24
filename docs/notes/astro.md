# ASTro built with nfcc

[ASTro](https://github.com/ko1/astro) (ko1) is an AST-interpreter framework. A `node.def` file defines node types as C
functions; ASTroGen (`lib/astrogen.rb`, Ruby) generates the evaluator, dispatchers, allocators, a Merkle hash of every
subtree and a partial evaluator. The partial evaluator writes one C function per distinct subtree (`SD_<hash>`); the Code
Store (`runtime/astro_code_store.c`) compiles them with `$(CC)` into `all.so` and `dlopen`s it, swapping the node's
dispatcher. So ASTro's compiler back end is whatever C compiler it is given, and `nfcc` can be that compiler.

`tests/realworld/run_astro.sh` (a step of `realworld.yml`) clones a pinned commit into `build/realworld/astro` and, on
each backend, builds two of its samples with nfcc:

| Sample | What it is | Checked |
| --- | --- | --- |
| `sample/calc` | the 6-node tutorial calculator | `--plain` gives 7; a normal run compiles `SD_*.c` through nfcc (`CC=nfcc`), loads `code_store/all.so`, and gives 54 for `(4 + 5) * 6` |
| `sample/luastro` | a Lua subset (74 nodes) | `hello.lua`, `fib(30)` = 832040, and its 8 `test/test_*.lua` scripts exit 0; the qbe and gcc builds print the same for every script (the upstream runner compares with a system `lua5.4`, which CI does not have) |

| `sample/baruby_precise` | a Ruby subset on a precise copying GC, parsed by Prism | `--plain` prints the right array; `--aot-compile --run` compiles the `SD_*.c` through nfcc, writes `code_store/all.so` and runs `fib(30)` = 832040 |
| Prism (`ruby/prism`, the Ruby parser; C) | the library baruby_precise links | `libprism.so` built by nfcc on both backends and loaded by a small program calling `pm_version()` |

```
tests/realworld/run_astro.sh                   # both backends, about 45 s once the clones exist
NFCXX_BACKEND=qbe tests/realworld/run_astro.sh
```

Needs `ruby` for ASTroGen. The script runs the generator and nfcc directly, not ASTro's makefiles. It prints `SKIP` when
the clone cannot be fetched or ruby is missing.

## Two patches, applied to a copy

The clone stays at the pin; each run copies `lib`, `runtime` and the two samples and patches the copy.

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

## What the two backends do with the specialized code

For `1 + 2 * 3`, `calc --disasm` shows the whole tree turned into one function, `SD_dfb75fdabb0d5ef6`:

- **gcc backend** (`-O2`): the function is `mov $7,%eax; ret`. gcc inlines the chain of evaluators into the dispatcher
  and folds the constants, which is the point of partial evaluation.
- **qbe backend**: the function loads its children and calls `EVAL_node_add`. QBE has no inliner, so the generated
  code is correct but keeps the call structure of the interpreter, and the specialization buys little.

A rough timing of `luastro examples/fib.lua` (`fib(30)`, one run, interpreter as built): 0.075 s on the gcc backend and
0.27 s on the qbe backend.

## Not done

- The other 26 samples. `koruby_precise` (Prism at a different commit, GMP, zlib, libyaml, the sibling `astrogre`) is the
  largest C workload; it uses the same statement-expression macros, so cproc has what it needs there.
- `astro_build.c`'s `--build` (standalone executables) and the tiered JIT daemon.
- Running ASTroGen under the repo's mruby instead of CRuby (`lib/astrogen.rb` needs only `optparse`).
- Feeding ASTro's hashing and specialization into `lib/ast` (`ast.md`), the idea this note started from.
