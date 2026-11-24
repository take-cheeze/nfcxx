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
