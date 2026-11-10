# nfcxx AST dump: the front end's replacement for `clang -ast-dump=json` in bc2cpp

bc2cpp reads a translation unit's AST to compute facts about native (C/C++) functions. It used clang's JSON AST dump.
`scripts/nfcxx-ast-dump` produces the same facts' input from the nfcxx front end (EDG): one JSON document per file with
the function definitions, complete record definitions and file-scope variables, and every function body's statements and
expressions. `BC2CPP_AST_PRODUCER=nfcxx` selects it; the default stays `clang` until the comparison below has been
run on the full closed world (`tools/bc2cpp/native_ast_source.rb`).

## What the consumers need (the information model)

`tools/bc2cpp/native_ast_returns.rb` (return kind of each function), `native_core_candidates.rb` (frame-free verdict,
static / defined, with `native_rom_extract.rb`'s `defined_functions`) read only this:

| Fact | Nodes and fields |
| --- | --- |
| Translation unit | `TranslationUnitDecl.inner` (also under `NamespaceDecl`, `LinkageSpecDecl`) |
| Function definition | `FunctionDecl` with `name`, `storageClass` (`static`), `type.qualType`, `loc.file` (the physical file: a function belongs to the source when it is defined in it), children `ParmVarDecl{id,name,type}` and a `CompoundStmt` body |
| Records | `RecordDecl` / `CXXRecordDecl` with `name`, `id`, `completeDefinition`, children `FieldDecl{id,name}` in order; file-scope `VarDecl` `type.qualType` (`struct N` in C, `N` in C++) |
| Statements | `CompoundStmt`, `IfStmt[cond, then, else?]`, `ReturnStmt[value?]`, `DeclStmt[VarDecl{id,name,type,inner:[init]}]`, loops / `SwitchStmt` / `CaseStmt` / labels (walked generically) |
| Values | `ImplicitCastExpr`, `ParenExpr`, `CStyleCastExpr`, `ExprWithCleanups` (transparent); `ConditionalOperator[c,a,b]`; `CallExpr[callee, args...]` with the callee a `DeclRefExpr{referencedDecl:{kind:FunctionDecl,name,type}}` under casts; `DeclRefExpr{referencedDecl:{id,kind:VarDecl\|ParmVarDecl\|EnumConstantDecl,name}}`; `MemberExpr{name,referencedMemberDecl}`; `BinaryOperator{opcode}` (`=`, `==`, `&&`), `UnaryOperator{opcode}` (`!`, `&`), `InitListExpr`, `CXXBoolLiteralExpr`, `CXXConstructExpr` |
| Identity | `id` strings tie a `DeclRefExpr` to its `VarDecl` / `ParmVarDecl`, a `MemberExpr` to its `FieldDecl`, a record to its fields |

The dump is exactly that subset with clang's names, so the analyses did not change. Anything else is `Unknown*` (visible
as such, never silently dropped).

## Producer

`be/nfcxx_ast.c` is a second output of the declaration back end (`be/nfcxx_decl.c`): with `NFCXX_DECL_AST=1`,
`back_end()` calls `nfcxx_ast_dump()`. It reads EDG's un-lowered IL (the libclang-edg configuration, which has no IL
lowering), so macros are expanded, enumerators keep their names (a folded constant is traced back through its `expr`),
and a local's initializer, a separate `stmk_init` in the IL, is merged into its `DeclStmt`. IL artifacts that clang does
not have are removed: the function-scope block around the body, compiler-generated blocks around `if` / loops, class copy
constructor calls (a `return` of a class value is its source expression). It ships with the libclang-edg build
(`scripts/setup-libclang-edg.sh`; `LIBCLANG_EDG_IN_PROCESS=0` is enough).

`scripts/nfcxx-ast-dump [clang options] FILE...` runs that `cpfe` in EDG's gcc / g++ dialect with the host's library headers
and clang's option spelling (`-x`, `-std=gnuNN`, `-I`, `-isystem`, `-D`, `-U`, `-include`). `tools/bc2cpp/native_ast_source.rb`
(`NativeAstSource.dump`) is the one place bc2cpp asks for an AST; `base_rbs_native.rb` uses it.

## Verifying against clang

    scripts/setup-libclang-edg.sh                    # builds the front end (3rd/edg: git submodule update --init --depth 1 3rd/edg)
    ruby bc2cpp/scripts/bc2cpp/native_ast_returns_check.rb       # the fixture, both producers
    BC2CPP_WORLD_ROOT=.../rpg-maker-clone LANG=C.UTF-8 ruby bc2cpp/scripts/bc2cpp/native_ast_producers_diff.rb --closed=CLOSED_BUILD --world

`native_ast_producers_diff.rb` runs both producers on every source the closed world reads and compares the return kinds
(single-kind and optional modes), the frame-free verdicts and the candidate rows; it exits 1 on any difference. A
closed build's `analysis/include` (`scripts/bc2cpp/analysis_headers.rb`) supplies the presym ids.

Result on the pinned mruby and the repo's gems (clang 18.1.3 as the oracle, 89 sources, 79 parsed by both): 2609
functions, 492 with a proven kind, 569 candidate rows, 0 differences. The other 10 sources fail in both producers
(checkout without the quickjs, lvgl, stb, uni-algo submodules; `symbol.c` needs the generated `presym/table.h`).

## C++ and the main program (main_ast.rb), ROM tables

The dump also carries what `scripts/bc2cpp/main_ast.rb` / `tools/bc2cpp/main_roots.rb` read from the user's host program
(`BC2CPP_AST_PRODUCER=nfcxx scripts/bc2cpp/main_ast.rb ...` runs the front end in place of `clang++ -ast-dump=json`; the host
preprocess by `BC2CPP_HOST_CXX` and the manifest format are unchanged, and `scripts/nfcxx-ast-dump -MD -MF f` writes the
header list the manifest's dependencies need):

| Construct | Emitted as |
| --- | --- |
| Member functions, constructors, destructors | `CXXMethodDecl` / `CXXConstructorDecl` / `CXXDestructorDecl` inside the record, `virtual`, `storageClass: static` for a static member, `mangledName` with `_GLOBAL__N_` in an unnamed namespace; a mem-initializer is a `CXXCtorInitializer` child; a default member initializer is the `FieldDecl`'s child |
| Calls | `CXXMemberCallExpr[MemberExpr[object], args]`; a static member call is a `CallExpr` over a `CXXMethodDecl` reference; a call whose callee depends on a template parameter is `CallExpr[UnresolvedLookupExpr]` (EDG keeps the template pattern, so main_roots' "an unknown function may be called" test sees what it sees in clang) |
| Lambdas | `LambdaExpr[CXXRecordDecl[CXXMethodDecl operator()]]`; a captured variable inside is a `DeclRefExpr` of the variable, as in clang |
| Casts | `ImplicitCastExpr` with clang's `castKind` (`LValueToRValue` is synthesized where an lvalue is read as a value, `ArrayToPointerDecay`, `FunctionToPointerDecay`, `IntegralCast`, `NoOp`, ...); main_roots reads those to tell a read from an escape |
| Constants | `StringLiteral` has `value` in C escapes; an enumerator keeps its name and the enumeration's type, a folded conversion is the `IntegralCast`; `true` is a `CXXBoolLiteralExpr`, `bool b = 1` is `IntegralToBoolean` over the literal (the front end records whether a bool constant came from a conversion) |
| Statements | range-for (`CXXForRangeStmt`), `if constexpr`, `try` / `catch`, a condition declaration, `new` / `delete` / `throw`, `static_assert` (with its message) |
| Declarations | default arguments are the `ParmVarDecl`'s child, also for a function declared without a body; file-scope `VarDecl` carries its initializer (a constant aggregate is an `InitListExpr` of `InitListExpr`s) |

The `*_rom_entries` tables of `native_rom_extract.rb` are those file-scope initializers. Checked with
`native_ast_producers_diff.rb`, which now also compares each table's entries (function, symbol, defined): 62 tables, 732
entries over the closed world, identical in clang and nfcxx. (`native_rom_extract.rb SOURCE FLAGS...` and
`native_core_candidates.rb SOURCE --run FLAGS...` run the producer named by `BC2CPP_AST_PRODUCER` themselves.)

Main-program check. The pinned `src/main.cxx` and `mruby-rgss/src/lib.cxx` cannot be parsed in a checkout without the
SDL2, lvgl, gflags, ng-log, uni-algo and stb submodules (clang fails the same way), so the manifests were compared on a
synthetic host `main` that exercises the constructs above (and `native_ast_returns_check.rb` has the same fixture) with
the real `--unit` sources that do parse (`mruby-rgss/src/{sixel,tts,input_bridge,default_font,audio}.cxx`,
`mruby-rpg2k/src/rgss_ext.cxx`, flags: world include dirs and the analysis presym header). Result: the `refusals` are
identical, and the `names` differ only by libstdc++ internals: `""` (a `__builtin_nanf("")` that EDG folds), and the
`__throw_length_error("vector::_M_range_insert")` literals of member-template patterns EDG does not keep. No name that
comes from the program's own source differs. `functions` differs in implicit and template-injected names (`Base`,
`_Iter_negate<_Predicate>`, ...): `main_reachability.rb` reads it only for `*_impl` names, and those agree. So the
manifest is not byte-identical to clang's (the STL internals are the reason), and `clang` stays the default.

## Not covered yet / stays on clang

- `scripts/bc2cpp/tagged_fixnum_check.rb`'s 32-bit probe stays on `g++ -m32` / `clang++ --target=i386-linux-gnu`: nfcxx's
  `--target=linux_i686` is only for `--freestanding --emit-c` (the driver refuses `--target` without `--freestanding`:
  "the host's library headers are the host target's"), and in freestanding mode `mruby.h` does not parse (`stdarg.h` is
  not found), so the probe's `mruby.h` / `static_assert(sizeof(void*) == 4)` cannot be compiled by nfcxx.
- `tests/bc2cpp/run_llvm_to_pathb.sh` stays on `clang-18 -S -emit-llvm`: its inputs are LLVM IR text, the input language
  of the translator under test (`scripts/llvm-to-pathb.rb`, docs/notes/pathb-llvm.md). nfcxx's own pipeline produces Path B IR
  (`scripts/pathb-*`) or QBE IL directly from the EDG IL and has no LLVM IR emitter, so replacing the front step would
  skip the translator it exists to test; the `// OPT: 1` cases and the TinyGo / wasm-explorer `.ll` files are LLVM optimizer
  and TinyGo output that nfcxx cannot produce at all. (`tests/llvm-pathb/run.sh` also compares against the clang-18 binary.)
- A bool constant in C++ whose source was a conversion of a folded integer expression (not a literal) is the
  `IntegralToBoolean` over an `IntegerLiteral` of the folded value, not over the original expression.
- Calls EDG folds at compile time (`__builtin_nanf("")`, `sizeof`) lose their arguments; `static_assert` at namespace
  scope (not in a class or a function) is not emitted.
