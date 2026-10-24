# nfcxx's cproc changes

cproc (the C front end of the qbe backend, `3rd/cproc`, a fork of michaelforney/cproc) carries nfcxx-specific changes
as commits of the fork, on its branch `nfcxx-linux-kernel` (the pin): make a change as a commit there, push it, and move
the submodule pin. The changes exist to let through the C that real-world gnu11 code -- the Linux kernel's headers in
particular -- relies on. The fork's own tests (`make check` in a copy of `3rd/cproc`) pass as they do upstream.

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
  and prunes it at the end: an item is live when it is exported, is `used` (`# nfcxx:keep`), or is referenced
  (`$name`) by a live item; a section alone does not keep it (gcc drops an unreferenced static `__init` function).
  Type definitions and other top-level lines are kept. An internal function that is only called, and only from
  functions in one init section, goes to that section, where gcc's inlined copy would be (the kernel's
  `always_inline` `memblock_alloc`, which calls `__init` code).

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

- **`__builtin_object_size(p, type)`**: the answer for a size the compiler cannot tell, `(size_t)-1` for types 0 and
  1 and 0 for types 2 and 3 (gcc's at `-O0` for most pointers), `p` not evaluated. The kernel's fortify and
  copy-size checks then check nothing at compile time, as with an unknown size under gcc.

- **`asm goto`** (docs/notes/inline-asm.md), and `__restrict`/`__restrict__`.

- **`__builtin_return_address(0)`, `__builtin_frame_address(0)`** (the kernel's `_RET_IP_`): a call of a helper in the
  inline-asm side file that reads its caller's `8(%rbp)` or `%rbp`; QBE gives every function that calls something a
  frame pointer. Other levels are refused.

- **`__builtin_offsetof` with an index that is not constant** (`container_of(node, T, node[idx])`): the constant
  offset plus the scaled index.

- **Volatile aggregates of 1, 2, 4 and 8 bytes** under `-V` (the kernel's `pte_t` through `WRITE_ONCE`/`READ_ONCE`):
  one helper call of that size each; a load copies the bytes into a temporary. Under `-V` any other volatile load
  (a bit-field, a larger aggregate) is refused rather than left a plain load.

- **`transparent_union`** on a typedef of a union (the kernel's `release_pages_arg`): an argument of any member's type
  converts to that member and is passed as the first member is, and the function defined with such a parameter
  receives it so -- gcc's convention, checked against gcc-compiled callers and callees. The members must be pointers
  or integers of the first one's size.

- **More GNU leniencies**: a struct or union object initialized from a compound literal of its type (the kernel's
  `DEFINE_RAW_SPINLOCK`, a static object), a member after a struct that ends in a flexible array member, pointers
  to integer types that differ only in signedness (`unsigned int *` for `int *`, gcc's `-Wpointer-sign`), basic asm
  (no operands) taken as literal text, and an input tied to an output by name (`"[sum]"`).

- **`gnu_inline`** (the kernel defines `inline` with it): `extern inline` defines no symbol, and its body, emitted
  under a local name, serves the direct calls that follow (C leaves it unspecified whether a call uses the inline
  or the external definition; gcc's `always_inline` ones are always inlined, so its objects name no external
  symbol either); taking the address names the external symbol. A plain `inline` defines the external symbol, the
  reverse of C99.

- **Other calling conventions** (`ms_abi`, `sysv_abi`, `regparm`, ...; the kernel's `__efiapi`, also before a
  pointer in a parenthesized declarator): the function type is marked, and a call or definition of it is refused
  (under `-p` only when a kept function makes it); declarations pass.

- **GNU initializers and casts**: range designators `[lo ... hi] = value` (the element's initializers repeated, a
  constant value only, since gcc evaluates it once), an empty `{}` for an array of unknown size (no elements), and a
  cast to a union type (`(union u)x`, the member of `x`'s type). `sizeof` of a zero-length array (`int a[0]`) is the
  constant 0; cproc took any array of size 0 for a variable-length one.

- **`aligned` below a member's alignment** is ignored unless the struct is packed, as gcc does.

- **More GNU C**: local labels (`__label__`), `packed` before a struct body (laid out as one after it, bit-fields
  included), `__builtin_isdigit` (C locale, folded as gcc does), `__builtin_prefetch` (the address evaluated), the
  `\e` escape, the `__attribute` and `__alignof` spellings, `%P` on a memory operand, and pointer `==`/`!=` between
  distinct pointer types or `void *` and a function pointer (compared as addresses; gcc warns).

- **Constant-argument clones of `always_inline` functions** (under `-p`). gcc inlines them, and an asm operand that
  must be an immediate is constant only in the inlined copy (the kernel's `_static_cpu_has(u16 bit)` asks for
  `"i"(1 << (bit & 7))`; `static_cpu_has(X86_FEATURE_...)` calls it with a constant). cproc records the tokens of an
  `always_inline` body (pp.c `tokrecord`); when a body has a refusal (deferred under `-p`), a call with integer
  constant arguments gets a local clone `NAME.constN`, the recorded body parsed again (`tokreplay`) with each such
  parameter an enumeration-like constant of its type -- the inlined copy's semantics -- and the call goes to it. A
  caller whose own call could not be cloned is marked the same way, so chains of such functions are cloned too. A
  body that does not compile so keeps the call on the function, and a body with a static local is not cloned
  (gcc's inlined copies share it). Calls with other arguments stay refused.

- **Constant conditions** (`if`, `while`, `&&`, `||`, `?:`) that `eval` folds are a jump: the other way is
  unreachable, so neither its asm thunks nor (QBE drops unreachable blocks) its calls remain -- the kernel's
  `udelay(10)` expands to `if ((10) / 20000 >= 1) __bad_udelay();`, a call gcc never emits and no object defines.

- **`-G`: GNU C's `cleanup` attribute** (qbe-cc passes it for hand-written C and kernel mode; the kernel's
  `guard()`/`scoped_guard()`). `f(&object)` runs when the object leaves its scope -- at the end of the block, and at
  a `return` (after its value), `break`, `continue`, `goto` or `asm goto` that leaves it -- the last declared first,
  as gcc runs them without `-fexceptions` (no unwind tables or landing pads). A goto jumps to a block of its own
  whose cleanups are made after the body, once the label's live objects are known. A jump into the scope of such an
  object, and such an object directly in a statement expression (whose value cproc evaluates after its
  statements), are refused. Without `-G` the attribute keeps nfcxx's meaning for EDG-made C: the cleanups run only
  when a throw unwinds the function. Before `-G`, hand-written C got that meaning too, and a cleanup never ran at
  the end of its scope.

- **`weak`, `alias("target")`, `visibility("...")`** on globals (the kernel's `__weak`, the `SYSCALL_DEFINE` stubs
  that alias a static `__do_sys_*`): directives in the inline-asm side file -- `.weak`/`.hidden` for a symbol a live
  item defines or names (under `-p`, an unused weak declaration leaves no weak undefined symbol), and `.set` with the
  binding and `.type` gcc gives an alias, its target kept by a `# nfcxx:ref` line. tests/c/cc-mode.sh compares the
  symbol table with gcc's.

- **`#pragma` under `-G`**: GNU C written by hand must not lose a pragma that changes what the program means, as
  cproc's reading for EDG-made C (every pragma ignored) would. `GCC visibility push/pop` is honoured (the
  visibility of the external declarations that follow, `visibility` attributes aside), and so is `pack` --
  `pack(N)`, `pack()`, `pack(push[, N])`, `pack(pop)`: a struct member defined under it gets at most N's
  alignment (the kernel's ACPI tables are laid out under `pack(1)`; a bit-field or an `aligned` member it would
  limit is refused). Diagnostics and hints (`GCC diagnostic`, `once`, `STDC`, `GCC unroll`, ...) are ignored, and
  any other pragma (`weak`, `redefine_extname`, ...) is refused. Before, 31 kernel files that include the ACPI
  headers were compiled with those tables laid out as if there were no pragma.

- **Calls of a function whose body is `{ return C; }`** (C an integer constant), under `-p` (the kernel mode; elsewhere
  a call stays a call and no constant expression), are C when the arguments have no side effects: gcc inlines such a function and folds what depends on it -- the kernel's `pmd_trans_huge()` is 0
  without transparent huge pages, and the call it guards names a function this configuration does not have. The
  call has no effect to keep (the body only returns C); an argument with a side effect keeps the call. Likewise a
  call of a function whose body is `{}` is nothing (`__apply_fineibt()` without CFI; `noinline` too, as gcc finds
  such a function const and drops the call), and `x & 0` is 0 when `x` has no effect (`S_DAX`,
  `ARCH_PAGE_TABLE_SYNC_MASK`). A weak function is not folded (the link may take another definition), nor a
  `noipa` one (qbe-prep.rb's `__nfcxx_keep(&x)`, whose call keeps a volatile local in memory).

- **Dead code names nothing** under `-p`: a block cproc's own constant folding leaves unreachable is marked
  (`# nfcxx:dead` after its label) and what only it names is not referenced, as QBE drops the block -- a static
  function called only there is not emitted (`create_huge_pmd()`). The `.hidden`/`.weak` directive of a symbol
  the unit only declares stays only if the final assembly names it (`#nfcxx:ifused`, qbe-cc): gas would otherwise
  make an undefined symbol of a declaration whose last use QBE dropped (`if (0 && ...)` under
  `#pragma GCC visibility`).

- **Flexible array member initializers** of a static object, the outermost struct's last member (the kernel's
  `init_mm.cpu_bitmap`): the object is sizeof the struct plus the array's initializers, byte for byte gcc's.
  Refused for an automatic object (gcc too) and for a compound literal.

- **`aligned` as gcc reads it**: on an object it is the object's alignment even below the type's
  (`DEFINE_PER_CPU_PAGE_ALIGNED` of the 16 KiB-aligned `struct irq_stack`; `_Alignas` cannot weaken it), and
  `__alignof__` of an object is the object's; on a function, up to 16 on x86-64, where QBE aligns every function
  (`__function_aligned`); its argument is looked up in the declaration's scope (a block-scope enum constant).

- **Static initializers gcc takes as constants**: an address cast to a 64-bit integer plus and minus constants
  (`TOP_OF_INIT_STACK`), and a converted negative constant under a range designator.

- **`__builtin_extract_return_addr`**: the identity, on x86-64 only (pointer authentication can make it differ on
  aarch64).

- **GNU attributes that change what a declaration means** are taken or refused, never ignored as the hints and
  diagnostics are: `mode` on an enum (QI/byte, HI, SI, DI/word/pointer: the integer type of that size, as gcc
  gives the kernel's 1-byte trace enums) is taken; `vector_size`, `naked`, `interrupt`,
  `no_caller_saved_registers`, `weakref`, `ifunc`, `target_clones`, `symver`, `tls_model`,
  `scalar_storage_order`, other modes, and `mode` on anything but an enum are refused. Before, the trace enums
  were 4 bytes.

- **File-scope basic asm** (`__asm__("text");`), written to the inline-asm side file.

- **Lazy refusals under `-p`**: a refusal inside a function body (an asm operand only inlining could satisfy) is
  reported only if pruning keeps the function, and the dropped functions' asm thunks leave the side file with them
  (docs/notes/inline-asm.md). `error()` jumps to `errorjmp` when it is set (token.c).

## Known gaps (still refused)

- SSE operands; an `"i"` operand only inlining makes constant from a variable argument.
- Bit-fields in a packed struct where packing would move a member, and under a leading `packed`.
- Volatile bit-fields and volatile aggregates other than of 1, 2, 4 and 8 bytes.
- Global register variables other than `%rsp`.
- The C23 `nullptr` constant miscompiles under `-c` (a pre-existing cproc codegen gap); harmless before C23, where
  `nullptr` is an identifier.

## Testing

`tests/c/run.sh` (both backends) and `tests/run.sh` (the C++ cases). The inline-asm tests are `tests/c/inline_asm_*.c`.
