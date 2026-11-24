import NfcxxIR.Syntax

/-!
Printer from the typed syntax back to s-expressions. With the decoder, it gives a round trip: decoding a
function and printing it again must give its text (up to whitespace), which checks the decoder reads every
field and drops none.
-/

namespace Nfcxx.IR

open SExp

/-- A quoted name, as the printer writes it. -/
def quoteStr (s : String) : String := "\"" ++ s ++ "\""

def quoteName (s : String) : SExp := atom (quoteStr s)

partial def encTy : Ty → SExp
  | Ty.prim n => atom n
  | Ty.ptr t => list [atom "ptr", encTy t]
  | Ty.named k n => list [atom k, quoteName n]
  | Ty.array none t => list [atom "array", atom "?", encTy t]
  | Ty.array (some n) t => list [atom "array", atom (toString n), encTy t]
  | Ty.fn r ps => list [atom "fn", encTy r, list (ps.map encTy)]
  | Ty.qual q t => list [atom q, encTy t]

def encOperand : Operand → SExp
  | Operand.reg n => atom ("%" ++ toString n)
  | Operand.localVar n => atom ("$" ++ quoteStr n)
  | Operand.global n => atom ("@" ++ quoteStr n)
  | Operand.fnRef n => atom ("&" ++ quoteStr n)
  | Operand.constant t v => list [atom "const", encTy t, atom v]
  | Operand.null t => list [atom "null", encTy t]
  | Operand.wrapped w t o => list [atom w, encTy t, encOperand o]
  | Operand.ehTid n => list [atom "eh-tid", atom (toString n)]

def encSize : SizeArg → SExp
  | SizeArg.num n => atom (toString n)
  | SizeArg.reg n => atom ("%" ++ toString n)

/-- A head with the volatile suffix when the form is volatile. -/
def volHead (h : String) (vol : Bool) : String := if vol then h ++ ".v" else h

def binName : BinOp → String
  | .wadd => "wadd" | .wsub => "wsub" | .wmul => "wmul"
  | .cadd => "cadd" | .csub => "csub" | .cmul => "cmul" | .cdiv => "cdiv" | .crem => "crem"
  | .cshl => "cshl" | .cshr => "cshr"
  | .fadd => "fadd" | .fsub => "fsub" | .fmul => "fmul" | .fdiv => "fdiv"
  | .band => "and" | .bor => "or" | .bxor => "xor"

def unName : UnOp → String
  | .wneg => "wneg" | .cneg => "cneg" | .fneg => "fneg" | .bnot => "not"

def cmpName : CmpOp → String
  | .eq => "eq" | .ne => "ne" | .lts => "lt.s" | .ltu => "lt.u" | .ltf => "lt.f"
  | .les => "le.s" | .leu => "le.u" | .lef => "le.f"

def convName : ConvOp → String
  | .iconv => "iconv" | .bitcast => "bitcast" | .i2p => "i2p" | .p2i => "p2i"
  | .cf2i => "cf2i" | .i2f => "i2f" | .u2f => "u2f" | .fconv => "fconv"

def encRValue : RValue → SExp
  | RValue.operand o => encOperand o
  | RValue.rdtsc => list [atom "rdtsc"]
  | RValue.load vol t a => list [atom (volHead "load" vol), encTy t, encOperand a]
  | RValue.offset a n => list [atom "offset", encOperand a, atom (toString n)]
  | RValue.index b i s => list [atom "index", encOperand b, encOperand i, encSize s]
  | RValue.pdiff a b s => list [atom "pdiff", encOperand a, encOperand b, encSize s]
  | RValue.bfload vol t u a bo w =>
      list [atom (volHead "bfload" vol), encTy t, atom (toString u), encOperand a, atom (toString bo), atom (toString w)]
  | RValue.binop o t a b => list [atom (binName o), encTy t, encOperand a, encOperand b]
  | RValue.unop o t a => list [atom (unName o), encTy t, encOperand a]
  | RValue.cmp o t a b => list [atom (cmpName o), encTy t, encOperand a, encOperand b]
  | RValue.conv o t a => list [atom (convName o), encTy t, encOperand a]
  | RValue.call t c variadic args =>
      list ([atom "call", encTy t, encOperand c]
        ++ (match variadic with | some n => [list [atom "variadic", atom (toString n)]] | none => [])
        ++ args.map encOperand)
  | RValue.alloca s => list [atom "alloca", encSize s]
  | RValue.vaarg t a => list [atom "vaarg", encTy t, encOperand a]
  | RValue.ehExc => list [atom "eh-exc"]
  | RValue.ehSel => list [atom "eh-sel"]

mutual

partial def encStmt : Stmt → SExp
  | Stmt.letS d t rv => list [atom "let", atom ("%" ++ toString d), encTy t, encRValue rv]
  | Stmt.setS d o => list [atom "set", atom ("%" ++ toString d), encOperand o]
  | Stmt.storeS vol t a v => list [atom (volHead "store" vol), encTy t, encOperand a, encOperand v]
  | Stmt.copyS b d s => list [atom "copy", encSize b, encOperand d, encOperand s]
  | Stmt.zeroFill b d => list [atom "zero-fill", encSize b, encOperand d]
  | Stmt.bfstore vol t u a bo w v =>
      list [atom (volHead "bfstore" vol), encTy t, atom (toString u), encOperand a, atom (toString bo), atom (toString w), encOperand v]
  | Stmt.vlaalloc s o => list [atom "vlaalloc", atom ("$" ++ quoteStr s), encOperand o]
  | Stmt.evalS rv => list [atom "eval", encRValue rv]
  | Stmt.bounds o n => list [atom "bounds", encOperand o, encSize n]
  | Stmt.nonnull o => list [atom "nonnull", encOperand o]
  | Stmt.ifS c t e =>
      list ([atom "if", encOperand c, list (atom "then" :: encStmts t)]
        ++ (match e with | none => [] | some es => [list (atom "else" :: encStmts es)]))
  | Stmt.loop b s => list [atom "loop", list (atom "body" :: encStmts b), list (atom "step" :: encStmts s)]
  | Stmt.switchS o b => list [atom "switch", encOperand o, list (atom "body" :: encStmts b)]
  | Stmt.caseS o => list [atom "case", encOperand o]
  | Stmt.dflt => list [atom "default"]
  | Stmt.brk => list [atom "break"]
  | Stmt.goto l => list [atom "goto", quoteName l]
  | Stmt.labelS l => list [atom "label", quoteName l]
  | Stmt.ret none => list [atom "return"]
  | Stmt.ret (some o) => list [atom "return", encOperand o]
  | Stmt.unreachable => list [atom "unreachable"]
  | Stmt.block b => list (atom "block" :: encStmts b)
  | Stmt.barrier => list [atom "barrier"]
  | Stmt.fence => list [atom "fence"]
  | Stmt.trap => list [atom "trap"]
  | Stmt.ehState n => list [atom "eh-state", atom (toString n)]
  | Stmt.vastart o => list [atom "vastart", encOperand o]
  | Stmt.cont => list [atom "continue"]
  | Stmt.asmBlock t ops => list ([atom "asm-block", quoteName t] ++ ops)
  | Stmt.ehPad n cl tys b =>
      list ([atom "eh-pad", atom (toString n), atom (toString cl), list (tys.map (fun t => atom (toString t)))]
        ++ encStmts b)
  | Stmt.ehResume o => list [atom "eh-resume", encOperand o]
  | Stmt.unsupported k nm => list [atom "unsupported", atom k, atom nm]
  | Stmt.loc f l => list [atom "loc", quoteName f, atom (toString l)]
  | Stmt.likely => list [atom "likely"]
  | Stmt.unlikely => list [atom "unlikely"]

partial def encStmts (ss : List Stmt) : List SExp := ss.map encStmt

end

end Nfcxx.IR

namespace Nfcxx.IR

open SExp

def encParam : Param → SExp
  | Param.sret n t => list [atom "sret", atom ("%" ++ toString n), encTy t]
  | Param.named n nm t => list [atom "param", atom ("%" ++ toString n), quoteName nm, encTy t]
  | Param.byval n nm t => list [atom "param", atom ("%" ++ toString n), quoteName nm, list [atom "byval", encTy t]]
  | Param.ellipsis => list [atom "ellipsis"]

def encSlot (s : Slot) : SExp :=
  list [atom "slot", quoteName s.name, encTy s.ty, atom (toString s.bytes), atom (toString s.align)]

/-- A function, in the printer's order: the linkage, the return type, the parameters, the attribute forms, the
slots, and the statements. -/
def encFunc (f : Func) : SExp :=
  list ([atom "function", quoteName f.linkage, list [atom "ret", encTy f.ret],
         list (atom "params" :: f.params.map encParam)]
    ++ f.attrs ++ f.slots.map encSlot ++ encStmts f.body)

end Nfcxx.IR
