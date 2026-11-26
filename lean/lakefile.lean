import Lake
open Lake DSL

package nfcxx_lean where
  -- Lean side of nfcxx: the mid-level IR (docs/notes/pathb-stage2.md) read from its text form.

@[default_target]
lean_lib NfcxxIR where
  roots := #[`NfcxxIR]

lean_exe nfcxx_ir where
  root := `Main

-- The Y1-SIMT toy GPU of the Theoric note (Y1.lean): its checks are evaluated when this library builds.
lean_lib Y1 where
  roots := #[`Y1]
