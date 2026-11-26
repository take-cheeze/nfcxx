import NfcxxIR.SExp

/-!
Typed syntax of the mid-level IR, for function bodies (docs/notes/pathb-stage2.md, section 6, the grammar
as printed). Names are the decoded text of the quoted names; numbers are the decoded text of the number
atoms. Module-level forms other than functions are not modelled here (see `NfcxxIR.Top`).

Values of constants (`(const T V)`) are kept as written: the semantics that reads them (a later step)
decides the range.
-/
namespace Nfcxx.IR

/-- A type: a primitive name (`int`, `unsigned_long`, `void`, ...), a pointer, an aggregate named by its
kind (`struct`, `class`, `union`), an array (the length is unknown for `(array ? T)`), or a function type. -/
inductive Ty where
  | prim : String → Ty
  | ptr : Ty → Ty
  | named : String → String → Ty
  | array : Option Nat → Ty → Ty
  | fn : Ty → List Ty → Ty
  /-- A qualified type: `(const T)` or `(volatile T)`, printed inside pointee and object types. -/
  | qual : String → Ty → Ty

/-- An operand: a register `%N`, a local `$"x"`, a global `@"x"`, a function `&"f"`, a constant `(const T V)`,
or a null pointer `(null T)`. -/
inductive Operand where
  | reg : Nat → Operand
  | localVar : String → Operand
  | global : String → Operand
  | fnRef : String → Operand
  | constant : Ty → String → Operand
  | null : Ty → Operand
  /-- An argument passed by a wrapper: `(sret T OP)` (the hidden result pointer) or `(byval T OP)` (an aggregate in memory). -/
  | wrapped : String → Ty → Operand → Operand
  /-- `(eh-tid N)`: the type id of an exception type, the value a catch clause compares with. -/
  | ehTid : Nat → Operand

/-- A byte count or element size: a number, or a register of type unsigned_long. -/
inductive SizeArg where
  | num : Nat → SizeArg
  | reg : Nat → SizeArg

/-- The wrapping, checked and floating arithmetic, and the bitwise operators. The checked forms trap on a
zero divisor or an out-of-range shift (docs/notes/pathb-stage2.md, section 4). -/
inductive BinOp where
  | wadd | wsub | wmul
  | cadd | csub | cmul | cdiv | crem | cshl | cshr
  | fadd | fsub | fmul | fdiv
  | band | bor | bxor

inductive UnOp where
  | wneg | cneg | fneg | bnot

/-- Comparisons (the result is a bool). The suffix is the signedness or the kind of the operands. -/
inductive CmpOp where
  | eq | ne
  | lts | ltu | ltf
  | les | leu | lef

inductive ConvOp where
  | iconv | bitcast | i2p | p2i | cf2i | i2f | u2f | fconv

/-- A value-producing form. `volatile` marks the `.v` loads. -/
inductive RValue where
  | operand : Operand → RValue
  | rdtsc
  | load : Bool → Ty → Operand → RValue
  | offset : Operand → Nat → RValue
  | index : Operand → Operand → SizeArg → RValue
  | pdiff : Operand → Operand → SizeArg → RValue
  | bfload : Bool → Ty → Nat → Operand → Nat → Nat → RValue
  | binop : BinOp → Ty → Operand → Operand → RValue
  | unop : UnOp → Ty → Operand → RValue
  | cmp : CmpOp → Ty → Operand → Operand → RValue
  /-- `(eh-exc)` and `(eh-sel)`: the exception object and the selector a landing pad starts with. -/
  | ehExc
  | ehSel
  | conv : ConvOp → Ty → Operand → RValue
  /-- A call: the result type, the callee, the number of leading arguments that match named parameters
  (for a variadic callee), and the arguments. -/
  | call : Ty → Operand → Option Nat → List Operand → RValue
  | alloca : SizeArg → RValue
  | vaarg : Ty → Operand → RValue

/-- A statement. -/
inductive Stmt where
  | letS : Nat → Ty → RValue → Stmt
  | setS : Nat → Operand → Stmt
  | storeS : Bool → Ty → Operand → Operand → Stmt
  | copyS : SizeArg → Operand → Operand → Stmt
  | zeroFill : SizeArg → Operand → Stmt
  | bfstore : Bool → Ty → Nat → Operand → Nat → Nat → Operand → Stmt
  | vlaalloc : String → Operand → Stmt
  | evalS : RValue → Stmt
  | bounds : Operand → SizeArg → Stmt
  | nonnull : Operand → Stmt
  /-- `(if C (then ...) [(else ...)])`: the else branch is absent or present (possibly empty). -/
  | ifS : Operand → List Stmt → Option (List Stmt) → Stmt
  | loop : List Stmt → List Stmt → Stmt
  | switchS : Operand → List Stmt → Stmt
  | caseS : Operand → Stmt
  | dflt
  | brk
  | goto : String → Stmt
  | labelS : String → Stmt
  | ret : Option Operand → Stmt
  | unreachable
  | block : List Stmt → Stmt
  | barrier
  | fence
  | trap
  /-- `(eh-state N)`: the EH state the following code runs in; `N` is a landing pad (be/nfcxx_ir_eh.h). -/
  | ehState : Nat → Stmt
  /-- `(vastart ADDR)`: the start of a va_list at ADDR. -/
  | vastart : Operand → Stmt
  /-- `(continue)`: the end of a loop body (the step runs next). -/
  | cont
  /-- `(asm-block "HEX" OPERAND...)`: inline assembly. The payload is kept as written: its operands and
  clobbers have a grammar of their own, not yet typed. -/
  | asmBlock : String → List SExp → Stmt
  /-- `(eh-pad N CLEANUP (TYPE-IDS) STMT...)`: landing pad N, with its cleanup flag and the type ids it catches. -/
  | ehPad : Nat → Nat → List Nat → List Stmt → Stmt
  /-- `(eh-resume OPERAND)`: resume unwinding with the exception object. -/
  | ehResume : Operand → Stmt
  /-- `(unsupported KIND NAME)`: a node the printer could not lower; the compile refuses such a unit. -/
  | unsupported : String → String → Stmt
  /-- `(loc "FILE" LINE)`, `(likely)`, `(unlikely)`: statements that generate no code. -/
  | loc : String → Nat → Stmt
  | likely
  | unlikely

/-- A parameter: the hidden `sret` pointer, a named parameter, a `byval` aggregate, or `...`. -/
inductive Param where
  | sret : Nat → Ty → Param
  | named : Nat → String → Ty → Param
  | byval : Nat → String → Ty → Param
  | ellipsis

/-- A stack slot `(slot "NAME" TYPE BYTES ALIGN)`. -/
structure Slot where
  name : String
  ty : Ty
  bytes : Nat
  align : Nat

/-- One item of a global's initializer that the semantics writes: `(scalar OFF TYPE (const TYPE V))` is the integer
literal V of TYPE at byte OFF, and `(zero OFF N)` is N zero bytes at OFF. The other items (`bytes`, `addr`, and the
scalars that are not integers) are not kept, so their bytes stay unwritten. -/
inductive InitItem where
  | scalar : Nat → Ty → String → InitItem
  | zero : Nat → Nat → InitItem

/-- A global variable `(global "NAME" TYPE SIZE ALIGN ATTRS...)`: its byte size, whether it has no definition in the
module (`(extern)`), and the items of its `(init ...)` attribute when it has one. The type is not kept: a load or a
store through the global takes its width from its own type. -/
structure Global where
  name : String
  size : Nat
  isExtern : Bool
  initItems : Option (List InitItem)

/-- A function. `attrs` are the linkage and start-up forms (`(static)`, `(weak)`, `(constructor PRIO)`, ...),
kept as written until they get their own types. -/
structure Func where
  linkage : String
  ret : Ty
  params : List Param
  attrs : List SExp
  slots : List Slot
  body : List Stmt

end Nfcxx.IR
