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

Status: written but not yet compiled. The toolchain could not be installed in the session that
wrote it, so the first step is `lake build` and fixing whatever it reports. The grammar was checked
separately with a Python mirror of the lexer and parser: all 94 goldens in `tests/pathb-ir`
(11,786 top-level forms) parse with balanced parens and round-trip.

`NfcxxIR/Semantics.lean` is the executable semantics of a subset of the IR: integer types, registers,
constants, the wrapping, checked and bitwise integer operators, comparisons, `iconv`, same-width `bitcast`,
`eval` of a value, and the structured statements (`let`, `set`, `if`, `loop`, `block`, `switch` with its
top-level `case` and `default` labels, `break`, `continue`, `return`, `unreachable`, `trap`). A form outside
the subset gives `stuck` with its reason, naming the form; it is never skipped. Stack slots of integer type
(`load` and `store` of a local) are modelled. Pointers and memory beyond slots, calls, floats, exceptions,
`goto` and labels nested inside a switch arm are the next steps. Values are integers reduced into
their type after each operation; the run is fuel-bounded.

    nfcxx_ir run FILE FUNCTION   # run a function without parameters: value, trap or stuck
    tests/lean/run.sh            # also runs the IR functions in lean/tests/sem with their known outcomes
