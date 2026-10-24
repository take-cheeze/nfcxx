# nfcxx's cproc changes

cproc (the C front end of the qbe backend, `3rd/cproc`, a fork of michaelforney/cproc) carries nfcxx-specific changes
that are not yet commits of the fork. `scripts/setup-qbe.sh` applies them to the build copy as `scripts/cproc-nfcxx.patch`;
regenerate the patch with a `diff -u` of `3rd/cproc` against `build/cproc` after editing the copy. The changes exist to
let through the C that real-world gnu11 code -- the Linux kernel's headers in particular -- relies on.

## Changes

- **`__extension__`** is accepted and dropped by the scanner (a pedantry marker). The kernel's headers put it in front
  of every 64-bit typedef.

- **GNU extended inline assembly**, lowered to out-of-line thunks. x86_64 only. See `docs/notes/inline-asm.md` for the
  full design; `qbe-cc` passes `-a FILE` so cproc writes the thunks to a side file appended to the assembly.

- **`true` / `false` / `nullptr` / `bool` are ordinary identifiers before C23.** They are C23 keyword constants/types,
  but in C11/C17 and the gnu* dialects they are not keywords -- `<stdbool.h>`/`<stddef.h>` provide them as macros, or a
  program declares its own (the kernel's `include/linux/stddef.h` has `enum { false, true }` and `include/linux/types.h`
  has `typedef _Bool bool`). cproc now reads them as identifiers; `cproc -c` restores the C23 keyword meaning, and
  `qbe-cc` passes `-c` when the effective `-std` is c23/c2x/gnu23/gnu2x. `_Bool` stays a keyword always (it is `TBOOL`;
  lowercase `bool` is an alias enabled only under `-c`). The predicate is `iscident()` in `token.c`.

- **The `aligned` attribute on a typedef** raises the alignment of a copy of the type, e.g.
  `typedef __signed__ __int128 __s128 __attribute__((aligned(16)))` from `include/uapi/linux/types.h`. Previously cproc
  rejected any alignment on a typedef.

- **GNU attributes between a pointer and the declarator name** are consumed, e.g.
  `void * __attribute__((__warn_unused_result__)) ERR_PTR(long)` (the kernel's `__must_check`, `__user`, `__force`).
  They appertain to the declared entity; `aligned` among them raises its alignment, the rest are parsed and ignored as
  before.

- **GNU `section` and `used`** are applied wherever they appear in a declaration (specifiers, after a pointer, after the
  declarator; adjacent string literals concatenate, as in the kernel's `".initcall" "6" ".init"`). A function goes to
  `section "NAME" "ax"`, an object to `"a"` when const and `"aw"` otherwise, as gcc chooses.

- **Kernel options** (for nfcc's `NFCXX_QBE_KERNEL`, docs/notes/linux-kernel.md): `-u` makes plain `char` unsigned
  (`-funsigned-char`), `-W` makes wide literals `unsigned short` (`-fshort-wchar`), `-z` zeroes automatic objects that
  have no initializer (`-ftrivial-auto-var-init=zero`).

- **`-p`: drop unreferenced internal functions and data**, as gcc does at `-O`. cproc writes its IL to a temporary file
  and prunes it at the end: an item is live when it is exported, has a section, is `used` (`# nfcxx:keep`), or is
  referenced (`$name`) by a live item. Type definitions and other top-level lines are kept.

- **GNU statement expressions** `({ ... })`. cproc emits statements as it parses them but evaluates expressions later,
  from trees, so the statements are parsed into a chain of blocks that is not part of the function yet (`funcdetach`),
  and `funcexpr` links the chain in where the expression is evaluated (`EXPRSTMT`). The statements therefore run only
  where and when the expression does: in the operand of `&&`, `||` or `?:` that is taken, and not at all under `sizeof`
  or `typeof`. The value is the last expression statement's tree, evaluated at the end of the chain.

- **GNU case ranges** `case LO ... HI:`. Each case node of the dispatch tree has a high end; a range test is
  `v - lo <= hi - lo` (unsigned), and a signed range across zero is split in two. Overlapping labels are an error.

- **`__builtin_choose_expr`**: the chosen operand itself (its type, an lvalue if it is one); the other is parsed and not
  evaluated.

- **`packed` and `aligned` wherever gcc takes them**: `packed` after a struct or union body re-lays the members out with
  alignment 1, keeping each member's own `aligned` (struct `member.align`); `packed` on a member gives that member
  alignment 1; a packed enum takes the smallest integer type that holds its values; `aligned` after an array declarator
  or among the declaration specifiers raises the declared object's or typedef's alignment. A packed struct's size is
  still rounded up to its alignment, which a member's `aligned` can raise. `tests/c/attr_layout.c` checks the layouts
  against gcc's.

- **GNU register variables**: `register T x asm("REG")`. At file scope a global register variable; only `%rsp` is
  supported (the kernel's `current_stack_pointer`): a read is a call to a local helper that returns the caller's stack
  pointer. In a block an ordinary object that inline asm operands take in REG. As an asm operand `%rsp` is named in the
  template but never moved (the kernel's `ASM_CALL_CONSTRAINT`).

- **Inline asm** (docs/notes/inline-asm.md): memory operands (`m`, `o`, `V`; the slot carries the object's address and
  `%N` is `(reg)`), multiple alternatives in one operand (the first `,` alternative, choosing immediate, register or
  memory as gcc does, with the ranges of `I J K L M N e Z` checked), and symbol addresses as immediates (`"i"(&x)`).

- **`-g`**: the GNU keyword `asm`. **`-V`**: volatile scalar accesses go through opaque helpers in the inline-asm side
  file (`nfcxx_vload4`: `movl (%rdi), %eax`), one call per access. QBE has no volatile, and its load optimization
  forwards and merges plain loads (a polling loop's load can leave the loop); a call is something it never forwards,
  merges or removes. Without `-V` volatile loads stay plain loads and volatile stores are refused, as before.

- **Bit-counting built-ins** `__builtin_clz`, `ctz`, `popcount`, `parity`, `ffs` and their `l`/`ll` forms:
  constant-folded (the kernel's headers use them in constant expressions and `_Static_assert`s), otherwise lowered
  branch-free to a population count by halves; clz and ctz of zero give the width. qbe-prep.rb no longer rewrites them.

- **Inline asm `p` operands and `%a`** (docs/notes/inline-asm.md), and symbol immediates with an offset (`&s.member`).

- **`packed` after a struct body with bit-fields**, when packing moves nothing (the kernel's `desc_struct` and
  `orc_entry`): every member is where gcc's packed layout puts it, so only the alignment and tail padding change. cproc
  reads and writes a bit-field through a unit of its type's size, gcc only the bytes it spans; a bit-field whose unit
  would reach past the packed struct or into a member that is not a bit-field moves to the smallest integer unit of
  its signedness that holds its bits (`unsigned sp_reg:4` in a byte). Its value converts and promotes alike, since
  cproc promotes a bit-field by its width. Other packed bit-fields are still refused.

- **GNU leniencies the kernel relies on**: a keyword as an attribute name (`__attribute__((const))`), an empty member
  declaration (`T *lock; ;` in cleanup.h's guards), a `;` at file scope, `return f();` with `f` void in a void function
  (a non-void value is still an error), and `__builtin_memset`, `__builtin_memcpy`, `__builtin_str{cpy,ncpy,cat,ncat,
  cmp,ncmp}` as calls of the library functions.

- **Unreachable asm**: thunks are written only for blocks reachable from the function's start, and a constant
  `switch`/`if` condition is a plain jump (docs/notes/inline-asm.md).

- **File-scope basic asm** (`__asm__("text");`), written to the inline-asm side file.

- **Lazy refusals under `-p`**: a refusal inside a function body (an asm operand only inlining could satisfy) is
  reported only if pruning keeps the function, and the dropped functions' asm thunks leave the side file with them
  (docs/notes/inline-asm.md). `error()` jumps to `errorjmp` when it is set (token.c).

## Known gaps (still refused)

- `asm goto`, SSE operands.
- Bit-fields in a packed struct where packing would move a member, and under a leading `packed`.
- Volatile bit-fields and volatile aggregate copies (`-V` covers scalars of 1, 2, 4 and 8 bytes).
- Global register variables other than `%rsp`.
- The C23 `nullptr` constant miscompiles under `-c` (a pre-existing cproc codegen gap); harmless before C23, where
  `nullptr` is an identifier.

## Testing

`tests/c/run.sh` (both backends) and `tests/run.sh` (the C++ cases). The inline-asm tests are `tests/c/inline_asm_*.c`.
