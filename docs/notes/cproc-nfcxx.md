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

## Known gaps (still refused)

- Global and local register variables (`register long x asm("rsp")`): a C variable bound to a physical register, which
  QBE cannot express. The kernel's `current_stack_pointer` and several `uaccess`/`irq_stack` macros use them.
- The C23 `nullptr` constant miscompiles under `-c` (a pre-existing cproc codegen gap); harmless before C23, where
  `nullptr` is an identifier.

## Testing

`tests/c/run.sh` (both backends) and `tests/run.sh` (the C++ cases). The inline-asm tests are `tests/c/inline_asm_*.c`.
