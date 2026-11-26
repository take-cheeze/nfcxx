import NfcxxIR.SExp
import NfcxxIR.Top
import NfcxxIR.Syntax

/-!
Decoder from s-expressions to the typed syntax (`NfcxxIR.Syntax`). Each function returns an error that names
the form it could not read, so a form the grammar has but the decoder does not is reported, not skipped.
-/

namespace Nfcxx.IR

/-- The name of a sigil-prefixed quoted atom: `$"x"`, `@"x"`, `&"f"`. -/
def sigilName (c : Char) (s : String) : Except String String :=
  if s.startsWith c.toString then decodeString (s.drop 1)
  else .error s!"expected a {c}\"...\" name, got {s}"

/-- A register `%N`. -/
def regNum (s : SExp) : Except String Nat :=
  match s with
  | SExp.atom a =>
    if a.startsWith "%" then
      match (a.drop 1).toNat? with
      | some n => .ok n
      | none => .error s!"bad register {a}"
    else .error s!"expected a register, got {a}"
  | e => .error s!"expected a register, got {e.render}"

/-- A plain number atom. -/
def natAtom (s : SExp) : Except String Nat :=
  match s with
  | SExp.atom a =>
    match a.toNat? with
    | some n => .ok n
    | none => .error s!"expected a number, got {a}"
  | e => .error s!"expected a number, got {e.render}"

/-- A byte count or element size: a number or a register. -/
def sizeArg (s : SExp) : Except String SizeArg :=
  match s with
  | SExp.atom a =>
    if a.startsWith "%" then SizeArg.reg <$> regNum s else SizeArg.num <$> natAtom s
  | e => .error s!"expected a size, got {e.render}"

/-- A quoted string atom, such as a label. -/
def quoted (s : SExp) : Except String String :=
  match s with
  | SExp.atom a => decodeString a
  | e => .error s!"expected a quoted string, got {e.render}"

partial def decodeTy : SExp → Except String Ty
  | SExp.atom s => .ok (Ty.prim s)
  | SExp.list [SExp.atom "ptr", t] => Ty.ptr <$> decodeTy t
  | SExp.list [SExp.atom "struct", n] => Ty.named "struct" <$> quoted n
  | SExp.list [SExp.atom "class", n] => Ty.named "class" <$> quoted n
  | SExp.list [SExp.atom "union", n] => Ty.named "union" <$> quoted n
  | SExp.list [SExp.atom "array", SExp.atom "?", t] => Ty.array none <$> decodeTy t
  | SExp.list [SExp.atom "array", n, t] => do
      let k ← natAtom n
      Ty.array (some k) <$> decodeTy t
  | SExp.list [SExp.atom "fn", r, SExp.list ps] => do
      let ret ← decodeTy r
      let params ← ps.mapM decodeTy
      .ok (Ty.fn ret params)
  | SExp.list [SExp.atom q, t] =>
      if q == "const" || q == "volatile" then Ty.qual q <$> decodeTy t
      else .error s!"unknown type {SExp.list [SExp.atom q, t] |>.render}"
  | e => .error s!"unknown type {e.render}"

/-- An operand. Constants and null pointers are lists; names are sigil-prefixed atoms. -/
partial def decodeOperand : SExp → Except String Operand
  | SExp.atom s =>
    if s.startsWith "%" then Operand.reg <$> regNum (SExp.atom s)
    else if s.startsWith "$" then Operand.localVar <$> sigilName '$' s
    else if s.startsWith "@" then Operand.global <$> sigilName '@' s
    else if s.startsWith "&" then Operand.fnRef <$> sigilName '&' s
    else .error s!"not an operand: {s}"
  | SExp.list [SExp.atom "const", t, SExp.atom v] => do
      let ty ← decodeTy t
      .ok (Operand.constant ty v)
  | SExp.list [SExp.atom "null", t] => Operand.null <$> decodeTy t
  | SExp.list [SExp.atom "eh-tid", n] => Operand.ehTid <$> natAtom n
  | SExp.list [SExp.atom w, t, o] =>
      if w == "sret" || w == "byval" then do
        let ty ← decodeTy t
        .ok (Operand.wrapped w ty (← decodeOperand o))
      else .error s!"not an operand: {SExp.list [SExp.atom w, t, o] |>.render}"
  | e => .error s!"not an operand: {e.render}"

/-- `store.v` and `load.v`: the head with its volatile suffix. -/
def splitVol (h : String) : String × Bool :=
  if h.endsWith ".v" then (h.dropRight 2, true) else (h, false)

def binOp? : String → Option BinOp
  | "wadd" => some .wadd | "wsub" => some .wsub | "wmul" => some .wmul
  | "cadd" => some .cadd | "csub" => some .csub | "cmul" => some .cmul
  | "cdiv" => some .cdiv | "crem" => some .crem | "cshl" => some .cshl | "cshr" => some .cshr
  | "fadd" => some .fadd | "fsub" => some .fsub | "fmul" => some .fmul | "fdiv" => some .fdiv
  | "and" => some .band | "or" => some .bor | "xor" => some .bxor
  | _ => none

def unOp? : String → Option UnOp
  | "wneg" => some .wneg | "cneg" => some .cneg | "fneg" => some .fneg | "not" => some .bnot
  | _ => none

def cmpOp? : String → Option CmpOp
  | "eq" => some .eq | "ne" => some .ne
  | "lt.s" => some .lts | "lt.u" => some .ltu | "lt.f" => some .ltf
  | "le.s" => some .les | "le.u" => some .leu | "le.f" => some .lef
  | _ => none

def convOp? : String → Option ConvOp
  | "iconv" => some .iconv | "bitcast" => some .bitcast | "i2p" => some .i2p | "p2i" => some .p2i
  | "cf2i" => some .cf2i | "i2f" => some .i2f | "u2f" => some .u2f | "fconv" => some .fconv
  | _ => none

/-- The arguments of a call after its callee: `(variadic N)` first, when the callee is variadic. -/
def callRest : List SExp → Except String (Option Nat × List SExp)
  | SExp.list [SExp.atom "variadic", n] :: rest => do
      let k ← natAtom n
      .ok (some k, rest)
  | rest => .ok (none, rest)

/-- The atom of a form that must be one (a sigil name in the `vlaalloc` form). -/
def atomOf (s : SExp) : Except String String :=
  match s with
  | SExp.atom a => .ok a
  | e => .error s!"expected a name, got {e.render}"

mutual

/-- A value-producing form, given its head and operands. -/
partial def decodeRValue : SExp → Except String RValue
  | SExp.list (SExp.atom h :: args) => decodeCompound h args
  | e => RValue.operand <$> decodeOperand e

partial def decodeCompound (h : String) (args : List SExp) : Except String RValue := do
  let (base, vol) := splitVol h
  if base == "const" || base == "null" then
    return RValue.operand (← decodeOperand (SExp.list (SExp.atom h :: args)))
  if base == "rdtsc" then
    if args.isEmpty then return RValue.rdtsc
    throw s!"rdtsc takes no operands, got {args.length}"
  match base, args with
  | "load", [t, a] => return RValue.load vol (← decodeTy t) (← decodeOperand a)
  | "offset", [a, n] => return RValue.offset (← decodeOperand a) (← natAtom n)
  | "index", [b, i, s] => return RValue.index (← decodeOperand b) (← decodeOperand i) (← sizeArg s)
  | "pdiff", [a, b, s] => return RValue.pdiff (← decodeOperand a) (← decodeOperand b) (← sizeArg s)
  | "bfload", [t, u, a, bo, w] =>
      return RValue.bfload vol (← decodeTy t) (← natAtom u) (← decodeOperand a) (← natAtom bo) (← natAtom w)
  | "alloca", [s] => return RValue.alloca (← sizeArg s)
  | "vaarg", [t, a] => return RValue.vaarg (← decodeTy t) (← decodeOperand a)
  | "eh-exc", [] => return RValue.ehExc
  | "eh-sel", [] => return RValue.ehSel
  | "call", t :: c :: rest => do
      let ty ← decodeTy t
      let callee ← decodeOperand c
      let (variadic, argForms) ← callRest rest
      let argOps ← argForms.mapM decodeOperand
      return RValue.call ty callee variadic argOps
  | _, [t, a] =>
      if let some c := convOp? base then return RValue.conv c (← decodeTy t) (← decodeOperand a)
      else if let some u := unOp? base then return RValue.unop u (← decodeTy t) (← decodeOperand a)
      else throw s!"unknown form ({h} with 2 operands)"
  | _, [t, a, b] =>
      if let some o := binOp? base then
        return RValue.binop o (← decodeTy t) (← decodeOperand a) (← decodeOperand b)
      else if let some c := cmpOp? base then
        return RValue.cmp c (← decodeTy t) (← decodeOperand a) (← decodeOperand b)
      else throw s!"unknown form ({h} with 3 operands)"
  | _, _ => throw s!"unknown form ({h} with {args.length} operands)"

/-- A statement. -/
partial def decodeStmt : SExp → Except String Stmt
  | SExp.list (SExp.atom h :: args) => decodeStmtHead h args
  | e => .error s!"not a statement: {e.render}"

partial def decodeStmts (xs : List SExp) : Except String (List Stmt) :=
  xs.mapM decodeStmt

partial def decodeStmtHead (h : String) (args : List SExp) : Except String Stmt := do
  let (base, vol) := splitVol h
  match base, args with
  | "let", [d, t, rv] => return Stmt.letS (← regNum d) (← decodeTy t) (← decodeRValue rv)
  | "set", [d, o] => return Stmt.setS (← regNum d) (← decodeOperand o)
  | "store", [t, a, v] => return Stmt.storeS vol (← decodeTy t) (← decodeOperand a) (← decodeOperand v)
  | "copy", [b, d, s] => return Stmt.copyS (← sizeArg b) (← decodeOperand d) (← decodeOperand s)
  | "zero-fill", [b, d] => return Stmt.zeroFill (← sizeArg b) (← decodeOperand d)
  | "bfstore", [t, u, a, bo, w, v] =>
      return Stmt.bfstore vol (← decodeTy t) (← natAtom u) (← decodeOperand a) (← natAtom bo) (← natAtom w)
        (← decodeOperand v)
  | "vlaalloc", [s, o] => return Stmt.vlaalloc (← sigilName '$' (← atomOf s)) (← decodeOperand o)
  | "eval", [rv] => return Stmt.evalS (← decodeRValue rv)
  | "bounds", [o, n] => return Stmt.bounds (← decodeOperand o) (← sizeArg n)
  | "nonnull", [o] => return Stmt.nonnull (← decodeOperand o)
  | "if", c :: SExp.list (SExp.atom "then" :: ts) :: rest => do
      let cond ← decodeOperand c
      let thenB ← decodeStmts ts
      let elseB ← match rest with
        | [] => pure none
        | [SExp.list (SExp.atom "else" :: es)] => some <$> decodeStmts es
        | _ => throw "if: malformed else branch"
      return Stmt.ifS cond thenB elseB
  | "loop", [SExp.list (SExp.atom "body" :: b), SExp.list (SExp.atom "step" :: s)] =>
      return Stmt.loop (← decodeStmts b) (← decodeStmts s)
  | "switch", [o, SExp.list (SExp.atom "body" :: b)] =>
      return Stmt.switchS (← decodeOperand o) (← decodeStmts b)
  | "case", [c] => return Stmt.caseS (← decodeOperand c)
  | "default", [] => return Stmt.dflt
  | "break", [] => return Stmt.brk
  | "goto", [l] => return Stmt.goto (← quoted l)
  | "label", [l] => return Stmt.labelS (← quoted l)
  | "return", [] => return Stmt.ret none
  | "return", [o] => return Stmt.ret (some (← decodeOperand o))
  | "unreachable", [] => return Stmt.unreachable
  | "block", ss => return Stmt.block (← decodeStmts ss)
  | "barrier", [] => return Stmt.barrier
  | "fence", [] => return Stmt.fence
  | "trap", [] => return Stmt.trap
  | "eh-state", [n] => return Stmt.ehState (← natAtom n)
  | "vastart", [o] => return Stmt.vastart (← decodeOperand o)
  | "continue", [] => return Stmt.cont
  | "eh-pad", n :: cl :: SExp.list tys :: body => do
      let tyIds ← tys.mapM natAtom
      return Stmt.ehPad (← natAtom n) (← natAtom cl) tyIds (← decodeStmts body)
  | "loc", [f, l] => return Stmt.loc (← quoted f) (← natAtom l)
  | "likely", [] => return Stmt.likely
  | "unlikely", [] => return Stmt.unlikely
  | "eh-resume", [o] => return Stmt.ehResume (← decodeOperand o)
  | "unsupported", [k, nm] => return Stmt.unsupported (← atomOf k) (← atomOf nm)
  | "asm-block", hex :: operands => do
      let template ← quoted hex
      return Stmt.asmBlock template operands
  | _, _ => throw s!"unknown statement ({h} with {args.length} operands)"

end

def decodeSlot : List SExp → Except String Slot
  | [n, t, b, a] => do
      let name ← quoted n
      let ty ← decodeTy t
      let bytes ← natAtom b
      let align ← natAtom a
      .ok { name, ty, bytes, align }
  | _ => .error "slot: expected (slot NAME TYPE BYTES ALIGN)"

def decodeParam : SExp → Except String Param
  | SExp.list [SExp.atom "sret", n, t] => do
      .ok (Param.sret (← regNum n) (← decodeTy t))
  | SExp.list [SExp.atom "param", n, nm, SExp.list [SExp.atom "byval", t]] => do
      .ok (Param.byval (← regNum n) (← quoted nm) (← decodeTy t))
  | SExp.list [SExp.atom "param", n, nm, t] => do
      .ok (Param.named (← regNum n) (← quoted nm) (← decodeTy t))
  | SExp.list [SExp.atom "ellipsis"] => .ok Param.ellipsis
  | e => .error s!"unknown parameter {e.render}"

/-- An item of a global's initializer that the semantics writes; none for the others (see `InitItem`). -/
def decodeInitItem : SExp → Option InitItem
  | SExp.list [SExp.atom "scalar", o, t, SExp.list [SExp.atom "const", _, SExp.atom v]] => do
      let off ← (natAtom o).toOption
      let ty ← (decodeTy t).toOption
      return InitItem.scalar off ty v
  | SExp.list [SExp.atom "zero", o, n] => do
      return InitItem.zero (← (natAtom o).toOption) (← (natAtom n).toOption)
  | _ => none

/-- A `(global "NAME" TYPE SIZE ALIGN ATTRS...)` form (see `Global`). Its type is not read. -/
def decodeGlobal : SExp → Except String Global
  | SExp.list (SExp.atom "global" :: n :: _ :: sz :: _ :: attrs) => do
      let name ← quoted n
      let size ← natAtom sz
      let isExtern := attrs.any (fun a => match a with
        | SExp.list (SExp.atom "extern" :: _) => true
        | _ => false)
      let initItems := attrs.findSome? (fun a => match a with
        | SExp.list (SExp.atom "init" :: items) => some (items.filterMap decodeInitItem)
        | _ => none)
      .ok { name, size, isExtern, initItems }
  | e => .error s!"not a global: {e.render}"

/-- The forms that come between the signature and the body and are not statements. -/
def isAttrHead (h : String) : Bool :=
  h == "static" || h == "weak" || h == "constructor" || h == "destructor" || h == "eh-noexcept" || h == "eh-types"
    || h == "eh-spec"

/-- A function's body: its attribute forms, its slots, and its statements, in that order. -/
def splitBody (xs : List SExp) : Except String (List SExp × List Slot × List Stmt) := do
  let mut attrs : List SExp := []
  let mut slots : List Slot := []
  let mut body : List Stmt := []
  for x in xs do
    match x with
    | SExp.list (SExp.atom "slot" :: rest) => slots := slots ++ [← decodeSlot rest]
    | SExp.list (SExp.atom h :: _) =>
        if isAttrHead h then attrs := attrs ++ [x]
        else body := body ++ [← decodeStmt x]
    | e => throw s!"not a function form: {e.render}"
  return (attrs, slots, body)

/-- A `(function ...)` form. -/
def decodeFunc : SExp → Except String Func
  | SExp.list (SExp.atom "function" :: l :: SExp.list [SExp.atom "ret", r] ::
      SExp.list (SExp.atom "params" :: ps) :: rest) => do
      let linkage ← quoted l
      let ret ← decodeTy r
      let params ← ps.mapM decodeParam
      let (attrs, slots, body) ← splitBody rest
      .ok { linkage, ret, params, attrs, slots, body }
  | e => .error s!"not a function: {e.render}"

end Nfcxx.IR
