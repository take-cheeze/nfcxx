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

```
tests/realworld/run_astro.sh                   # both backends, about 15 s once the clone exists
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

## What the two backends do with the specialized code

For `1 + 2 * 3`, `calc --disasm` shows the whole tree turned into one function, `SD_dfb75fdabb0d5ef6`:

- **gcc backend** (`-O2`): the function is `mov $7,%eax; ret`. gcc inlines the chain of evaluators into the dispatcher
  and folds the constants, which is the point of partial evaluation.
- **qbe backend**: the function loads its children and calls `EVAL_node_add`. QBE has no inliner, so the generated
  code is correct but keeps the call structure of the interpreter, and the specialization buys little.

A rough timing of `luastro examples/fib.lua` (`fib(30)`, one run, interpreter as built): 0.075 s on the gcc backend and
0.27 s on the qbe backend.

## Not done

- The other 27 samples. Most need libraries (Prism, GMP, Boehm GC, readline) or CRuby; `koruby_precise` and
  `baruby_precise` are the larger C workloads worth trying next.
- `astro_build.c`'s `--build` (standalone executables) and the tiered JIT daemon.
- Running ASTroGen under the repo's mruby instead of CRuby (`lib/astrogen.rb` needs only `optparse`).
- Feeding ASTro's hashing and specialization into `lib/ast` (`ast.md`), the idea this note started from.
