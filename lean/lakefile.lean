import Lake
open Lake DSL

package nfcxx_lean where
  -- Lean side of nfcxx: the mid-level IR (docs/notes/pathb-stage2.md) read from its text form.

@[default_target]
lean_lib NfcxxIR where
  roots := #[`NfcxxIR]

lean_exe nfcxx_ir where
  root := `Main
