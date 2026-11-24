import NfcxxIR

/-!
`nfcxx_ir` reads the text form of the nfcxx mid-level IR.

  nfcxx_ir check FILE...   parse each file, decode its top-level forms, and check that printing
                           and re-parsing gives the same forms; prints one line per file
  nfcxx_ir print FILE      print each top-level form on its own line, as canonical s-expressions

Exit status is 0 when every file passes, 1 otherwise, and 2 for a usage error.
-/

open Nfcxx.IR

/-- Parses, decodes and round-trips one file. Returns a summary line, or an error. -/
def checkOne (path : String) : IO (Except String String) := do
  let src ← IO.FS.readFile path
  match parseFile src with
  | .error e => return .error e
  | .ok forms =>
    match decodeFile forms with
    | .error e => return .error e
    | .ok (module, counts) =>
      let printed := forms.toList.map SExp.render
      match parseFile (" ".intercalate printed) with
      | .error e => return .error s!"re-parse of printed form failed: {e}"
      | .ok again =>
        if again.toList.map SExp.render == printed then
          return .ok s!"ok {module}: {counts.functions} functions, {counts.globals} globals, {counts.others} other forms"
        else
          return .error "printing and re-parsing changed the forms"

def printOne (path : String) : IO (Except String Unit) := do
  let src ← IO.FS.readFile path
  match parseFile src with
  | .error e => return .error e
  | .ok forms =>
    for f in forms do
      IO.println f.render
    return .ok ()

/-- The number of statements in a list, counting the nested ones. -/
partial def countStmts (ss : List Stmt) : Nat :=
  ss.foldl (fun n s => n + 1 + inner s) 0
where
  inner : Stmt → Nat
    | Stmt.ifS _ t e => countStmts t + (match e with | none => 0 | some es => countStmts es)
    | Stmt.loop b st => countStmts b + countStmts st
    | Stmt.switchS _ b => countStmts b
    | Stmt.block b => countStmts b
    | _ => 0

/-- Decodes every function of one file into the typed syntax. -/
def astOne (path : String) : IO (Except String String) := do
  let src ← IO.FS.readFile path
  match parseFile src with
  | .error e => return .error e
  | .ok forms =>
    let mut funcs := 0
    let mut stmts := 0
    for f in forms do
      match f with
      | SExp.list (SExp.atom "function" :: _) =>
        match decodeFunc f with
        | .error e => return .error e
        | .ok fn =>
          funcs := funcs + 1
          stmts := stmts + countStmts fn.body
      | _ => pure ()
    return .ok s!"ok {funcs} functions, {stmts} statements"

/-- Decodes each function and prints it again; counts the functions whose text differs from the input. -/
def roundtripOne (path : String) : IO (Except String String) := do
  let src ← IO.FS.readFile path
  match parseFile src with
  | .error e => return .error e
  | .ok forms =>
    let mut total := 0
    let mut bad := 0
    let mut firstBad : Option String := none
    for f in forms do
      match f with
      | SExp.list (SExp.atom "function" :: _) =>
        total := total + 1
        match decodeFunc f with
        | .error e => return .error e
        | .ok fn =>
          let again := (encFunc fn).render
          if again != f.render then
            bad := bad + 1
            if firstBad.isNone then firstBad := some (f.render ++ "\n  ==> " ++ again)
      | _ => pure ()
    match firstBad with
    | none => return .ok s!"round trip ok: {total} functions"
    | some a => return .error s!"round trip differs in {bad} of {total} functions; first (original, reprinted): {a}"

def main (args : List String) : IO UInt32 := do
  match args with
  | "roundtrip" :: files =>
    let mut failed := false
    for f in files do
      match ← roundtripOne f with
      | .ok line => IO.println s!"{f}: {line}"
      | .error e =>
        IO.eprintln s!"{f}: {e}"
        failed := true
    return if failed then 1 else 0
  | "ast" :: files =>
    if files.isEmpty then
      IO.eprintln "usage: nfcxx_ir ast FILE..."
      return 2
    let mut failed := false
    for f in files do
      match ← astOne f with
      | .ok line => IO.println s!"{f}: {line}"
      | .error e =>
        IO.eprintln s!"{f}: {e}"
        failed := true
    return if failed then 1 else 0
  | "check" :: files =>
    if files.isEmpty then
      IO.eprintln "usage: nfcxx_ir check FILE..."
      return 2
    let mut failed := false
    for f in files do
      match ← checkOne f with
      | .ok line => IO.println s!"{f}: {line}"
      | .error e =>
        IO.eprintln s!"{f}: {e}"
        failed := true
    return if failed then 1 else 0
  | ["print", f] => do
    match ← printOne f with
    | .ok () => return 0
    | .error e => do
      IO.eprintln s!"{f}: {e}"
      return 1
  | _ =>
    IO.eprintln "usage: nfcxx_ir check FILE... | nfcxx_ir print FILE"
    return 2
