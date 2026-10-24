# GNU extended inline assembly (qbe backend)

QBE has no inline-assembly construct, so the IL cannot carry a `__asm__` block the way GCC's or LLVM's IR can. cproc
lowers each statement-level `__asm__` the way Cranelift's rustc backend (`rustc_codegen_cranelift`) does: the asm becomes
an **out-of-line thunk** emitted as assembly text, and the call site passes a pointer to a stack slot carrying the
operand values. The thunk owns register allocation — it loads the inputs from the slot into the registers the
constraints ask for, runs the template, and stores the outputs back — so the QBE IL only ever sees an ordinary call.

This is the `funcasm` function in cproc's `qbe.c` (a commit of the fork, `3rd/cproc`).
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
	pushq %rbx               # a callee-saved register holds the slot pointer; %rsp is 16-aligned again
	movq  %rdi, %rbx
	movq  0(%rbx), %rax      # load fed operands
	movq  8(%rbx), %rcx
	addq %rcx, %rax          # the template, operands substituted
	movq  %rax, 0(%rbx)      # store outputs back
	popq  %rbx
	ret
```

The slot pointer lives in a callee-saved register (rbx, then r12–r15) so the template may clobber anything caller-saved;
the call already tells QBE that caller-saved registers and memory are clobbered. A callee-saved register the asm clobbers
(or a callee-saved fixed operand) is push/popped in the thunk, and with an even number of pushes 8 bytes more keep %rsp
16-aligned for a call in the template. An operand the constraint leaves to the compiler takes a caller-saved register,
or, when the asm clobbers them all (the kernel's `call_on_stack()`, which calls a function from the template), a
callee-saved one the thunk preserves. Early-clobber (`&`) is automatically satisfied, since every operand has its own
register and the values round-trip through the slot.

## Supported (x86_64 only)

- `__asm__` / `asm`, with or without `volatile` (every lowered asm is a call, which QBE never reorders or removes).
- Output constraints `=r`, `+r`; input `r`; tied operands (`"0"`–`"9"`).
- Fixed general registers: `a` `b` `c` `d` `S` `D` (rax, rbx, rcx, rdx, rsi, rdi).
- Immediate inputs `i` / `n` (integer constant expressions).
- Symbolic operands `%[name]`; operand modifiers `%b %w %k %q` (byte/word/long/quad register names), `%c`/`%n`
  (bare / negated immediate), and `%=` (a unique number per expansion).
- Clobbers: `"memory"` and `"cc"` (no-ops — the call is already a full barrier), and named general registers.
- Scalar operands up to 8 bytes in registers; a tied input wider than its output is loaded whole (the kernel's
  `put_user` ties a pointer to an `int` output).
- Memory operands `m`, `o`, `V`: the slot carries the object's address, the thunk loads it into a register, and `%N`
  is `(reg)`, so the asm reads and writes the object itself (an array is the array, not its decayed pointer; a large
  struct is fine: only the address moves). Nothing is copied back.
- Multiple alternatives in one operand (`rm`, `ir`, `qm`, `g`, `Ir`, `er`, ...): the first `,` alternative, and within
  it the choice gcc makes -- an immediate when the operand is a constant that one of the immediate letters accepts
  (the ranges of `I J K L M N e Z` are checked), otherwise a register when a register letter is present, otherwise
  memory.
- Symbol addresses as immediates: `"i"(&x)`, `"i"(func)`, `"i"(&s.member)`, `"i"(&a[2])` expand to `$sym+off`
  (`%c`/`%P`: `sym+off`; `%a`: `sym+off(%rip)`, as gcc writes it). Under `cproc -p` a static symbol named only by an
  asm operand is kept alive by a `# nfcxx:ref $sym` comment in the IL of the function holding the asm.
- Address operands `p` (the kernel's `this_cpu_read_stable`: `"p"(&pcpu_hot.current_task)` with `%a`): a constant
  address is a symbol immediate as above, any other address goes in a register, and `%a` of a register is `(%reg)`.
- Flag outputs `=@cc<cond>` (`=@ccz`, `=@ccnz`, ...): `set<cond>` and `movzbl` in the thunk, after the template.
- Register variables (`register long x asm("r11")`) as operands take their register; `%rsp` (the kernel's
  `ASM_CALL_CONSTRAINT "+r"(current_stack_pointer)`) is named in the template but never moved.

## asm goto

`asm goto("..." : outputs : inputs : clobbers : labels)` keeps the thunk model. `%l[name]` and `%lN` (labels numbered
after the operands) name a stub inside the thunk; the stub writes the label's number (from 1) into a cell of the slot
and leaves through the thunk's normal exit, which stores the outputs; falling through writes 0. At the call site the
outputs are stored, then the cell is compared with each label's number and control goes to that C label. The
kernel's static branches put a 5-byte nop in the template and record it and the label in `__jump_table`; when the
kernel patches the nop into a `jmp`, the jump lands on the stub, so the patched branch goes where gcc's would.

## File-scope asm

A basic `__asm__("text");` at file scope (the kernel's `EXPORT_SYMBOL`, which writes a `.export_symbol` entry) goes to
the side file as it is, after `.text` (the section an assembly file starts in) and marked to survive pruning. The
kernel's uses switch sections themselves and switch back. Ordinary nfcc C still runs qbe-prep.rb, which refuses
file-scope asm other than its `.globl`/`.set` forms; kernel mode does not run it.

## Refusals in dropped functions (`cproc -p`)

The kernel's headers define `always_inline` helpers whose asm is satisfiable only after inlining: `bitops.h` asks for
`"i"(1 << (nr & 7))` with `nr` a parameter. A file that never calls the helper is still valid C to gcc, which drops the
function unseen. Under `-p` (pruning, which kernel mode uses) a refusal inside a function body is therefore deferred:
`error()` jumps back to `funcasm`, the message is written into the function's IL as `# nfcxx:error MSG`, and it is
reported only if pruning keeps the function. Each thunk is written to the side file after a `#nfcxx:owner NAME` line
naming its function, and the thunks of dropped functions are removed with them -- their text can name symbols the
program does not have (`call __put_user_4`).

## Asm that cannot be reached

Each thunk, its symbol operands and a deferred refusal are kept with the block of the asm statement, and the function
writes out only those of the blocks reachable from its start. A constant `switch` or `if` condition jumps straight to
its target, so the kernel's `cmpxchg`, which switches on `sizeof(*ptr)`, has no thunk for its `cmpxchgb` case when the
operand is 8 bytes wide (it would not even assemble: `%rsi` with a `b` suffix); asm after a `return` or `break` is
dropped. QBE removes the unreachable blocks, and with them the calls of the thunks left out.

## Not yet supported (refused, never miscompiled)

Each of these raises a compile error rather than quietly producing wrong code:

- Any target other than x86_64; the CIL backend and Mach-O (`qbe-cc` withholds `-a` there).
- SSE/floating operands (`x`, `v`, `Yz`, …).
- Operands in a file-scope `asm`.
- More register operands than the free registers hold (one callee-saved register stays for the slot pointer).

## Testing

`tests/c/inline_asm_*.c` (run by `tests/c/run.sh`) cover the basic forms, fixed registers, clobber preservation, and
(`inline_asm_mem.c`) the kernel's memory-operand shapes: `"+m"` atomics, `"Ir"` bit numbers, `xchg`, `cmpxchg` with
`"+a"` and `"=qm"`, `"rm"`/`"g"` alternatives, `"i"(&symbol)`, and `"m"` on arrays and large structs.
They run on both backends: the gcc backend compiles the asm with the host GCC (a reference), the qbe backend exercises
`funcasm`. They are marked `// X86-ONLY` since the instructions are x86.
