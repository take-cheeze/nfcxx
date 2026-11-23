import NfcxxIR.SExp

/-!
Top-level forms of an IR file: the `ir-module` header, `global` and `function` declarations.
Their bodies stay s-expressions for now; the typed IR (statements and expressions) comes next.
-/

namespace Nfcxx.IR

/-- The octal digit value of `c`, if it is one. -/
def octalVal (c : Char) : Option Nat :=
  if c.toNat ≥ 48 && c.toNat ≤ 55 then some (c.toNat - 48) else none

/-- Decodes the escapes the IR writer emits in string literals: `\n`, `\\`, `\"`, and octal `\NNN`.
Any other escape is an error, so an unknown form is reported rather than silently mangled. -/
partial def unescape (cs : List Char) (acc : String) : Except String String :=
  match cs with
  | [] => .ok acc
  | '\\' :: 'n' :: rest => unescape rest (acc.push '\n')
  | '\\' :: '\\' :: rest => unescape rest (acc.push '\\')
  | '\\' :: '"' :: rest => unescape rest (acc.push '"')
  | '\\' :: d1 :: d2 :: d3 :: rest =>
    (match octalVal d1, octalVal d2, octalVal d3 with
     | some a, some b, some c =>
       unescape rest (acc.push (Char.ofNat (a * 64 + b * 8 + c)))
     | _, _, _ => .error s!"bad escape \\{d1}{d2}{d3}")
  | '\\' :: e :: _ => .error s!"unsupported escape \\{e}"
  | c :: rest => unescape rest (acc.push c)

/-- The text of a quoted string atom, with its escapes decoded. -/
def decodeString (raw : String) : Except String String :=
  match raw.toList with
  | '"' :: rest =>
    (match rest.reverse with
     | '"' :: inner => unescape inner.reverse ""
     | _ => .error s!"unterminated string {raw}")
  | _ => .error s!"not a string literal: {raw}"

inductive Top where
  /-- `(ir-module "source.cpp" ...)`: the source file the module was lowered from. -/
  | module (source : String) (fields : List SExp)
  /-- `(global "name" ...)`. -/
  | global (name : String) (form : SExp)
  /-- `(function "name" ...)`. -/
  | function (name : String) (form : SExp)
  /-- Any other top-level form, kept as written. -/
  | other (form : SExp)
  deriving Inhabited

/-- Classifies one top-level s-expression. -/
def decodeTop (e : SExp) : Except String Top :=
  match e with
  | SExp.list (SExp.atom "ir-module" :: SExp.atom src :: fields) => do
    let s ← decodeString src
    .ok (Top.module s fields)
  | SExp.list (SExp.atom "global" :: SExp.atom n :: _) => do
    let s ← decodeString n
    .ok (Top.global s e)
  | SExp.list (SExp.atom "function" :: SExp.atom n :: _) => do
    let s ← decodeString n
    .ok (Top.function s e)
  | _ => .ok (Top.other e)

/-- Counts of each kind of top-level form. -/
structure Counts where
  globals : Nat := 0
  functions : Nat := 0
  others : Nat := 0
  deriving Repr

def Counts.add (c : Counts) : Top → Counts
  | Top.global _ _ => { c with globals := c.globals + 1 }
  | Top.function _ _ => { c with functions := c.functions + 1 }
  | Top.other _ => { c with others := c.others + 1 }
  | Top.module _ _ => c

/-- Decodes a whole IR file: its first form must be the `ir-module` header. Returns the module
source name and the counts of the other forms. -/
def decodeFile (forms : Array SExp) : Except String (String × Counts) := do
  let tops ← forms.toList.mapM decodeTop
  match tops with
  | Top.module src _ :: rest => .ok (src, rest.foldl Counts.add {})
  | _ => .error "the first form is not (ir-module ...)"

end Nfcxx.IR
