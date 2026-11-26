# lean/: Lean 4 side of the nfcxx IR

`nfcxx_ir` reads the text form of the Path B mid-level IR (`tests/pathb-ir/*.ir`, written by
`be/nfcxx_ir.c`; format in `docs/notes/pathb-stage2.md`). This is stage 4 of the Path B plan
(`docs/DESIGN.md`): the first piece is the parser and the checks on the text, before any semantics.

- `NfcxxIR/SExp.lean`: s-expression reader and printer. Atoms keep their source text.
- `NfcxxIR/Top.lean`: string-literal decoding; the `ir-module`, `global`, and `function` forms.
- `Main.lean`: `nfcxx_ir check FILE...` and `nfcxx_ir print FILE`.

Build and test (Lean 4 via elan; the toolchain is pinned in `lean-toolchain`):

    cd lean && lake build nfcxx_ir
    ../tests/lean/run.sh   # skips with a message when lake is not installed

Status: builds with Lean 4.14.0 (lake 5.0.0) and passes `tests/lean/run.sh`: the 94 goldens in `tests/pathb-ir`
(11,786 top-level forms) parse, round-trip, and decode to the typed AST; the 4 malformed inputs in `lean/tests/bad` are
refused; and the functions in `lean/tests/sem` give their expected outcomes.

`NfcxxIR/Semantics.lean` is the executable semantics of a subset of the IR: integer types, registers,
constants, the wrapping, checked and bitwise integer operators, comparisons, `iconv`, same-width `bitcast`,
`eval` of a value, and the structured statements (`let`, `set`, `if`, `loop`, `block`, `switch` with its
top-level `case` and `default` labels, `break`, `continue`, `return`, `unreachable`, `trap`). A form outside
the subset gives `stuck` with its reason, naming the form; it is never skipped. Stack slots of integer type
(`load` and `store` of a local) are modelled. Calls of functions of the same module are modelled: the
arguments are bound to the parameters of a fresh environment, and the callee's return value is the value of
the call. Calls of functions outside the module, pointers and memory beyond slots, floats, exceptions,
`goto` and labels nested inside a switch arm are the next steps. Values are integers reduced into
their type after each operation; the run is fuel-bounded, and so is the nesting of calls.

    nfcxx_ir run FILE FUNCTION   # run a function without parameters: value, trap or stuck
                                 # (FUNCTION may be main; the functions of FILE are available to its calls)
    tests/lean/run.sh            # also runs the IR functions in lean/tests/sem with their known outcomes

## Y1.lean: the Y1-SIMT toy GPU

`Y1.lean` is the toy GPU of the Theoric note "Building Virtual Hardware for Real Performance", as a Lean model: four lanes
in lockstep, 64 vector registers, flat VRAM, and three instructions (`load4`, `write4`, `fdot4`). A register index is a
`Fin 64`, so an out-of-range register is a compile error. Values are `Int`, not FP32, so the results are exact.

The 4x4 matrix multiply of the note runs as a 16-instruction program and its result is checked against the product, a
mutant with a wrong accumulator is shown to differ, and out-of-range loads and stores are shown to be errors. The checks
are `example`s, evaluated when `lake build Y1` runs (also in `tests/lean/run.sh`).

Not modelled: floating point and rounding, the virtual profiler, and any program beyond the 4x4 demo.
