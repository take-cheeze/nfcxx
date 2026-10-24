# GNU extended inline assembly (qbe backend)

QBE has no inline-assembly construct, so the IL cannot carry a `__asm__` block the way GCC's or LLVM's IR can. cproc
lowers each statement-level `__asm__` the way Cranelift's rustc backend (`rustc_codegen_cranelift`) does: the asm becomes
an **out-of-line thunk** emitted as assembly text, and the call site passes a pointer to a stack slot carrying the
operand values. The thunk owns register allocation — it loads the inputs from the slot into the registers the
constraints ask for, runs the template, and stores the outputs back — so the QBE IL only ever sees an ordinary call.

This is the `funcasm` function in cproc's `qbe.c` (applied to the build copy by `scripts/cproc-inline-asm.patch`).
`scripts/qbe-cc` passes `-a FILE`; cproc writes the thunks there and the script appends them to the assembly, after the
weak-symbol pass, as local functions.

## Pipeline

```
C with __asm__  ->  cproc  ->  QBE IL (a call to nfcxx_asm_thunk.N)  +  thunk.s (the thunk body)
                                   |                                        |
                                 qbe                                        |
                                   v                                        v
                                out.s  <------------------ appended -------- +   ->  cc -c
```

A statement `asm("addq %2, %0" : "=r"(r) : "0"(a), "r"(b))` becomes, at the call site:

```
%slot =l alloc8 16          # one 8-byte cell per register operand
storel %a, %slot            # tied input seeds the output's cell
%p =l add %slot, 8
storel %b, %p
call $nfcxx_asm_thunk.0(l %slot)
%r =l loadl %slot           # read the output back
```

and the thunk:

```
nfcxx_asm_thunk.0:
	pushq %rbx               # a callee-saved register holds the slot pointer
	subq  $8, %rsp           # keep %rsp 16-aligned for any call in the template
	movq  %rdi, %rbx
	movq  0(%rbx), %rax      # load fed operands
	movq  8(%rbx), %rcx
	addq %rcx, %rax          # the template, operands substituted
	movq  %rax, 0(%rbx)      # store outputs back
	addq  $8, %rsp
	popq  %rbx
	ret
```

The slot pointer lives in a callee-saved register (rbx, then r12–r15) so the template may clobber anything caller-saved;
the call already tells QBE that caller-saved registers and memory are clobbered. A callee-saved register the asm clobbers
(or a callee-saved fixed operand) is push/popped in the thunk. Early-clobber (`&`) is automatically satisfied, since every
operand has its own register and the values round-trip through the slot.

## Supported (x86_64 only)

- `__asm__` / `asm`, with or without `volatile` (every lowered asm is a call, which QBE never reorders or removes).
- Output constraints `=r`, `+r`; input `r`; tied operands (`"0"`–`"9"`).
- Fixed general registers: `a` `b` `c` `d` `S` `D` (rax, rbx, rcx, rdx, rsi, rdi).
- Immediate inputs `i` / `n` (integer constant expressions).
- Symbolic operands `%[name]`; operand modifiers `%b %w %k %q` (byte/word/long/quad register names), `%c`/`%n`
  (bare / negated immediate), and `%=` (a unique number per expansion).
- Clobbers: `"memory"` and `"cc"` (no-ops — the call is already a full barrier), and named general registers.
- Scalar operands up to 8 bytes.

## Not yet supported (refused, never miscompiled)

Each of these raises a compile error rather than quietly producing wrong code:

- Any target other than x86_64; the CIL backend and Mach-O (`qbe-cc` withholds `-a` there).
- Memory operands (`m`, `o`, `V`, `g`), and multiple-alternative constraints (`rm`, `ri`).
- SSE/floating operands (`x`, `v`, `Yz`, …).
- `asm goto`, flag outputs (`=@cc…`), and file-scope (top-level) `asm`.
- More register operands than the caller-saved pool holds.

## Testing

`tests/c/inline_asm_*.c` (run by `tests/c/run.sh`) cover the basic forms, fixed registers, and clobber preservation.
They run on both backends: the gcc backend compiles the asm with the host GCC (a reference), the qbe backend exercises
`funcasm`. They are marked `// X86-ONLY` since the instructions are x86.
