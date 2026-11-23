/-!
S-expression reader and printer for the text form of the nfcxx mid-level IR.

Every construct of the IR text is an s-expression (see `be/nfcxx_ir.c` and
`docs/notes/pathb-stage2.md`). Atoms keep their source text: a quoted string keeps its quotes
and escapes, so printing a parsed file reproduces the same tokens. Decoding a string literal is
a separate step (`NfcxxIR.Top`).

The text has no comments; `;` only occurs inside string literals.
-/

namespace Nfcxx.IR

inductive SExp where
  /-- An atom as written: a symbol, a number, `%N`, `$"x"`, `@"x"`, `&"x"`, or a quoted string. -/
  | atom : String → SExp
  | list : List SExp → SExp
  deriving Repr, Inhabited

inductive Tok where
  | lparen : Nat → Tok
  | rparen : Nat → Tok
  | atom : String → Nat → Tok
  deriving Repr, Inhabited

def isSpace (c : Char) : Bool :=
  c == ' ' || c == '\n' || c == '\t' || c == '\r'

/-- Reads the rest of a string literal. `acc` holds the text read so far, starting with the
opening quote. Returns the literal (quotes included), the remaining input and the line count. -/
partial def lexString (cs : List Char) (line : Nat) (acc : String) :
    Except String (String × List Char × Nat) :=
  match cs with
  | [] => .error s!"line {line}: unterminated string literal"
  | '\\' :: c :: rest =>
    lexString rest (if c == '\n' then line + 1 else line) ((acc.push '\\').push c)
  | '"' :: rest => .ok (acc.push '"', rest, line)
  | '\n' :: rest => lexString rest (line + 1) (acc.push '\n')
  | c :: rest => lexString rest line (acc.push c)

/-- Reads one atom. A quoted string may follow a prefix inside the same atom (`$"tmp.3"`). -/
partial def lexAtom (cs : List Char) (line : Nat) (acc : String) :
    Except String (String × List Char × Nat) :=
  match cs with
  | [] => .ok (acc, [], line)
  | c :: rest =>
    if c == '"' then do
      let (lit, rest', line') ← lexString rest line "\""
      lexAtom rest' line' (acc ++ lit)
    else if isSpace c || c == '(' || c == ')' then
      .ok (acc, cs, line)
    else
      lexAtom rest line (acc.push c)

partial def tokenize (cs : List Char) (line : Nat) (acc : Array Tok) :
    Except String (Array Tok) :=
  match cs with
  | [] => .ok acc
  | '\n' :: rest => tokenize rest (line + 1) acc
  | '(' :: rest => tokenize rest line (acc.push (Tok.lparen line))
  | ')' :: rest => tokenize rest line (acc.push (Tok.rparen line))
  | c :: rest =>
    if isSpace c then
      tokenize rest line acc
    else do
      let (s, rest', line') ← lexAtom cs line ""
      tokenize rest' line' (acc.push (Tok.atom s line))

mutual
  partial def parseExpr (toks : Array Tok) (i : Nat) : Except String (SExp × Nat) :=
    match toks[i]? with
    | none => .error "unexpected end of input"
    | some (Tok.atom s _) => .ok (SExp.atom s, i + 1)
    | some (Tok.lparen _) => parseItems toks (i + 1) #[]
    | some (Tok.rparen l) => .error s!"line {l}: unexpected ')'"

  partial def parseItems (toks : Array Tok) (i : Nat) (acc : Array SExp) :
      Except String (SExp × Nat) :=
    match toks[i]? with
    | none => .error "unexpected end of input: missing ')'"
    | some (Tok.rparen _) => .ok (SExp.list acc.toList, i + 1)
    | _ => do
      let (e, j) ← parseExpr toks i
      parseItems toks j (acc.push e)
end

partial def parseAll (toks : Array Tok) (i : Nat) (acc : Array SExp) :
    Except String (Array SExp) :=
  if i >= toks.size then
    .ok acc
  else do
    let (e, j) ← parseExpr toks i
    parseAll toks j (acc.push e)

/-- Parses a whole IR file into its top-level s-expressions. -/
def parseFile (src : String) : Except String (Array SExp) := do
  let toks ← tokenize src.toList 1 #[]
  parseAll toks 0 #[]

/-- Prints an s-expression on one line, with single spaces. -/
partial def SExp.render : SExp → String
  | SExp.atom s => s
  | SExp.list xs => "(" ++ String.intercalate " " (xs.map SExp.render) ++ ")"

end Nfcxx.IR
