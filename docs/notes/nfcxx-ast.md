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

## Not covered yet

- `scripts/bc2cpp/main_ast.rb` / `tools/bc2cpp/main_roots.rb` (the user's main program: it reads many more node kinds,
  literals and name lookups) and `native_rom_extract.rb`'s `*_rom_entries` table extraction (it reads file-scope `VarDecl` initializers, which the dump does not carry yet; only its `defined_functions` is covered). They still read clang.
- C++ method bodies and calls (`CXXMemberCallExpr`, `CXXMethodDecl`): not emitted; only namespace-level functions.
- A bool constant in C++ is a `CXXBoolLiteralExpr` even when clang has an implicit cast of an integer literal.
