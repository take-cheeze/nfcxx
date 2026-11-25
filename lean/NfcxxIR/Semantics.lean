import NfcxxIR.Syntax

/-!
Executable semantics of a subset of the mid-level IR (docs/notes/pathb-stage2.md, sections 3, 4 and 6).

The subset is what an integer-only function body needs: integer types, registers, constants, the wrapping,
checked and bitwise arithmetic, comparisons, `iconv`, and the structured statements (`let`, `set`, `if`,
`loop`, `block`, `break`, `continue`, `return`, `unreachable`, `trap`). Everything else is reported as
`stuck` with the reason, never silently skipped: memory, slots, calls, floats, exceptions, `goto`, and
`switch`. Those are the next steps.

Values are mathematical integers, kept in the range of their type by `wrapTo` after every operation. A
boolean is 0 or 1. The semantics is fuel-bounded: running out of fuel is `stuck`, so a result that is
`value` or `trap` is always a real outcome of the program.

The definitions are plain functions on `Except` and `Nat` fuel, so the examples and lemmas below can be
checked by kernel reduction (`decide`) and the executable `nfcxx_ir run` gives the same answers on real
compiler output.
-/

namespace Nfcxx.IR.Sem

/-- The head of a statement, as the text form writes it: used in the stuck messages. -/
def stmtName : Stmt → String
  | Stmt.letS .. => "let" | Stmt.setS .. => "set" | Stmt.storeS .. => "store" | Stmt.copyS .. => "copy"
  | Stmt.zeroFill .. => "zero-fill" | Stmt.bfstore .. => "bfstore" | Stmt.vlaalloc .. => "vlaalloc"
  | Stmt.evalS .. => "eval" | Stmt.bounds .. => "bounds" | Stmt.nonnull .. => "nonnull" | Stmt.ifS .. => "if"
  | Stmt.loop .. => "loop" | Stmt.switchS .. => "switch" | Stmt.caseS .. => "case" | Stmt.dflt => "default"
  | Stmt.brk => "break" | Stmt.goto .. => "goto" | Stmt.labelS .. => "label" | Stmt.ret .. => "return"
  | Stmt.unreachable => "unreachable" | Stmt.block .. => "block" | Stmt.barrier => "barrier"
  | Stmt.fence => "fence" | Stmt.trap => "trap" | Stmt.ehState .. => "eh-state" | Stmt.vastart .. => "vastart"
  | Stmt.cont => "continue" | Stmt.asmBlock .. => "asm-block" | Stmt.ehPad .. => "eh-pad"
  | Stmt.ehResume .. => "eh-resume" | Stmt.unsupported .. => "unsupported" | Stmt.loc .. => "loc"
  | Stmt.likely => "likely" | Stmt.unlikely => "unlikely"

/-- The head of a value-producing form, for the stuck messages. -/
def rvalueName : RValue → String
  | RValue.operand _ => "operand" | RValue.rdtsc => "rdtsc" | RValue.load .. => "load"
  | RValue.offset .. => "offset" | RValue.index .. => "index" | RValue.pdiff .. => "pdiff"
  | RValue.bfload .. => "bfload" | RValue.binop .. => "binop" | RValue.unop .. => "unop"
  | RValue.cmp .. => "cmp" | RValue.ehExc => "eh-exc" | RValue.ehSel => "eh-sel" | RValue.conv .. => "conv"
  | RValue.call .. => "call" | RValue.alloca .. => "alloca" | RValue.vaarg .. => "vaarg"

/-- The kind of an operand, for the stuck messages. -/
def operandName : Operand → String
  | Operand.reg n => s!"%{n}" | Operand.localVar x => s!"$\"{x}\"" | Operand.global x => s!"@\"{x}\""
  | Operand.fnRef x => s!"&\"{x}\"" | Operand.constant .. => "constant" | Operand.null .. => "null"
  | Operand.wrapped w .. => w | Operand.ehTid _ => "eh-tid"

/-- Bit width and signedness of an integer type name. `bool` is one unsigned bit: its values are 0 and 1. -/
def intInfo? : String → Option (Nat × Bool)
  | "bool" => some (1, false)
  | "char" | "signed_char" => some (8, true)
  | "unsigned_char" => some (8, false)
  | "short" => some (16, true)
  | "unsigned_short" => some (16, false)
  | "int" => some (32, true)
  | "unsigned_int" => some (32, false)
  | "long" | "long_long" => some (64, true)
  | "unsigned_long" | "unsigned_long_long" => some (64, false)
  | _ => none

/-- The name of a primitive type, when the type is one. -/
def primName : Ty → Option String
  | Ty.prim s => some s
  | _ => none

/-- An integer literal as the text form writes it: decimal, `0x` hexadecimal, or a leading `0` octal. -/
def parseIntLit (v : String) : Option Int :=
  if v.startsWith "0x" then do
    let ds ← (v.drop 2).toList.mapM hexVal
    return Int.ofNat (ds.foldl (fun acc d => acc * 16 + d) 0)
  else v.toInt?
where
  hexVal (c : Char) : Option Nat :=
    if c.isDigit then some (c.toNat - '0'.toNat)
    else if 'a' ≤ c && c ≤ 'f' then some (c.toNat - 'a'.toNat + 10)
    else if 'A' ≤ c && c ≤ 'F' then some (c.toNat - 'A'.toNat + 10)
    else none

/-- The name of a type for messages. -/
def tyText (t : Ty) : String := (primName t).getD "non-primitive type"

/-- The width and signedness of an operand type, when it is an integer type. -/
def infoOf (t : Ty) : Option (Nat × Bool) := do
  let s ← primName t
  intInfo? s

/-- Reduces an integer into the range of a type with `bits` bits: two's complement, the signed range when
`signed`. -/
def wrapTo (bits : Nat) (signed : Bool) (x : Int) : Int :=
  let m : Int := 2 ^ bits
  let r := x % m
  if signed && decide (r ≥ m / 2) then r - m else r

/-- The smallest value of a signed type with `bits` bits. -/
def minOf (bits : Nat) : Int := -(2 ^ (bits - 1))

/-- Whether an integer is in the range of the type. -/
def inRange (bits : Nat) (signed : Bool) (x : Int) : Bool :=
  if signed then decide (minOf bits ≤ x) && decide (x < 2 ^ (bits - 1))
  else decide (0 ≤ x) && decide (x < 2 ^ bits)

/-- Division truncating toward zero, as in C++. -/
def tdiv (a b : Int) : Int :=
  if decide (0 ≤ a * b) then (a.natAbs / b.natAbs : Nat) else -((a.natAbs / b.natAbs : Nat) : Int)

/-- What a run ends with: a value (for `return`, or the end of the body), a trap that the program raises
(division by zero, a shift out of range, `unreachable`, `trap`), or `stuck` for a form outside the subset. -/
inductive Outcome where
  | value : Option Int → Outcome
  | trap : String → Outcome
  | stuck : String → Outcome
  deriving Repr

/-- A cell of the state: a register, or a stack slot named as in the text form (`$"x"`). -/
inductive Cell where
  | reg : Nat → Cell
  | slot : String → Cell
  deriving BEq

/-- The values of the cells, the newest first. A read is the first entry for its cell. -/
abbrev Env := List (Cell × Int)

def Env.get (e : Env) (c : Cell) : Option Int :=
  match e.find? (fun p => p.1 == c) with
  | some p => some p.2
  | none => none

def Env.set (e : Env) (c : Cell) (v : Int) : Env := (c, v) :: e

/-- How a statement list ends: falling off the end, leaving a loop, continuing it, or returning. -/
inductive Flow where
  | normal
  | brk
  | cont
  | ret : Option Int → Flow
  deriving Repr

def evalOperand (env : Env) : Operand → Except Outcome Int
  | Operand.reg n =>
    match env.get (.reg n) with
    | some v => .ok v
    | none => .error (.stuck s!"register %{n} is read before it is set")
  | Operand.constant t v =>
    match infoOf t, parseIntLit v with
    | some (b, s), some k => .ok (wrapTo b s k)
    | _, _ => .error (.stuck s!"constant of type {tyText t} is not an integer literal: {v}")
  | Operand.localVar x => .error (.stuck s!"the address of $\"{x}\" is used as a value; only loads and stores of it are modelled")
  | o => .error (.stuck s!"operand {operandName o} not modelled")

/-- The integer binary operators on a type. Checked forms trap; wrapping forms reduce into the type. -/
def evalBin (op : BinOp) (t : Ty) (a b : Int) : Except Outcome Int :=
  match infoOf t with
  | none => .error (.stuck s!"arithmetic on a non-integer type {tyText t}")
  | some (bits, signed) =>
    let minI := minOf bits
    let trapOf (msg : String) : Except Outcome Int := .error (.trap msg)
    let checked (r : Int) : Except Outcome Int :=
      if inRange bits signed r then .ok r else trapOf "signed overflow"
    match op with
    | .wadd => .ok (wrapTo bits signed (a + b))
    | .wsub => .ok (wrapTo bits signed (a - b))
    | .wmul => .ok (wrapTo bits signed (a * b))
    | .cadd => checked (a + b)
    | .csub => checked (a - b)
    | .cmul => checked (a * b)
    | .cdiv =>
      if b == 0 then trapOf "division by zero"
      else if signed && a == minI && b == -1 then trapOf "division overflow"
      else .ok (wrapTo bits signed (tdiv a b))
    | .crem =>
      if b == 0 then trapOf "remainder by zero"
      else if signed && a == minI && b == -1 then trapOf "remainder overflow"
      else .ok (wrapTo bits signed (a - b * tdiv a b))
    | .cshl =>
      if b < 0 || b ≥ (bits : Int) then trapOf "shift count out of range"
      else .ok (wrapTo bits signed (a * 2 ^ b.toNat))
    | .cshr =>
      if b < 0 || b ≥ (bits : Int) then trapOf "shift count out of range"
      else .ok (wrapTo bits signed (a / 2 ^ b.toNat))
    | .band | .bor | .bxor =>
      -- two's complement bit patterns, combined as naturals, then reduced into the type
      let ua : Nat := (wrapTo bits false a).toNat
      let ub : Nat := (wrapTo bits false b).toNat
      let r : Nat :=
        if op matches .band then ua &&& ub
        else if op matches .bor then ua ||| ub
        else ua ^^^ ub
      .ok (wrapTo bits signed (Int.ofNat r))
    | .fadd | .fsub | .fmul | .fdiv => .error (.stuck "floating-point arithmetic is not modelled")

def evalUn (op : UnOp) (t : Ty) (a : Int) : Except Outcome Int :=
  match infoOf t with
  | none => .error (.stuck s!"unary operator on a non-integer type {tyText t}")
  | some (bits, signed) =>
    match op with
    | .wneg => .ok (wrapTo bits signed (-a))
    | .cneg =>
      if signed && a == minOf bits then .error (.trap "negation overflow")
      else .ok (-a)
    | .bnot => .ok (wrapTo bits signed (-a - 1))
    | .fneg => .error (.stuck "floating-point negation is not modelled")

def evalCmp (op : CmpOp) (a b : Int) : Except Outcome Int :=
  let bool01 (p : Bool) : Int := if p then 1 else 0
  match op with
  | .eq => .ok (bool01 (a == b))
  | .ne => .ok (bool01 (a != b))
  | .lts | .ltu => .ok (bool01 (decide (a < b)))
  | .les | .leu => .ok (bool01 (decide (a ≤ b)))
  | .ltf | .lef => .error (.stuck "floating-point comparison is not modelled")

/-- A value-producing form, in the subset. -/
def evalRValue (env : Env) : RValue → Except Outcome Int
  | RValue.operand o => evalOperand env o
  | RValue.load _ t (Operand.localVar x) => do
    match infoOf t, env.get (.slot x) with
    | some _, some v => .ok v
    | some _, none => .error (.stuck s!"slot $\"{x}\" is read before it is written")
    | none, _ => .error (.stuck s!"load of a non-integer type {tyText t}")
  | RValue.binop op t a b => do
    evalBin op t (← evalOperand env a) (← evalOperand env b)
  | RValue.unop op t a => do
    evalUn op t (← evalOperand env a)
  | RValue.cmp op _ a b => do
    evalCmp op (← evalOperand env a) (← evalOperand env b)
  | RValue.conv ConvOp.iconv t a => do
    match infoOf t with
    | some (bits, signed) => return wrapTo bits signed (← evalOperand env a)
    | none => throw (.stuck s!"iconv to a non-integer type {tyText t}")
  | rv => .error (.stuck s!"value form {rvalueName rv} not modelled")

-- Statements and statement lists with their fuel: each level of nesting uses one unit, and each loop
-- iteration runs its body with the same fuel. Out of fuel is `stuck`.
mutual

def execStmt : Nat → Env → Stmt → Except Outcome (Env × Flow)
  | 0, _, _ => .error (.stuck "out of fuel")
  | n + 1, env, s =>
    match s with
    | Stmt.letS r _ rv => do
      let v ← evalRValue env rv
      return (env.set (.reg r) v, .normal)
    | Stmt.setS r o => do
      let v ← evalOperand env o
      return (env.set (.reg r) v, .normal)
    | Stmt.storeS _ t (Operand.localVar x) val => do
      let v ← evalOperand env val
      match infoOf t with
      | some (bits, signed) => return (env.set (.slot x) (wrapTo bits signed v), .normal)
      | none => .error (.stuck s!"store of a non-integer type {tyText t}")
    | Stmt.ifS c th el => do
      let v ← evalOperand env c
      if v != 0 then execList n env th
      else match el with
        | none => return (env, .normal)
        | some es => execList n env es
    | Stmt.loop body step => execLoop n n env body step
    | Stmt.block ss => execList n env ss
    | Stmt.brk => return (env, .brk)
    | Stmt.cont => return (env, .cont)
    | Stmt.ret none => return (env, .ret none)
    | Stmt.ret (some o) => do
      let v ← evalOperand env o
      return (env, .ret (some v))
    | Stmt.unreachable => .error (.trap "unreachable")
    | Stmt.trap => .error (.trap "trap")
    | Stmt.loc _ _ | Stmt.likely | Stmt.unlikely => return (env, .normal)
    | st => .error (.stuck s!"statement {stmtName st} not modelled")

def execList : Nat → Env → List Stmt → Except Outcome (Env × Flow)
  | 0, _, _ => .error (.stuck "out of fuel")
  | _ + 1, env, [] => return (env, .normal)
  | n + 1, env, s :: ss => do
    let (env', fl) ← execStmt n env s
    match fl with
    | .normal => execList n env' ss
    | _ => return (env', fl)

/-- A loop: run the body; `break` leaves it; `continue` or the end of the body runs the step, then the body
again. The first argument counts the iterations left, so the loop always ends. -/
def execLoop : Nat → Nat → Env → List Stmt → List Stmt → Except Outcome (Env × Flow)
  | 0, _, _, _, _ => .error (.stuck "out of fuel")
  | k + 1, n, env, body, step => do
    let (env1, fl) ← execList n env body
    match fl with
    | .brk => return (env1, .normal)
    | .ret v => return (env1, .ret v)
    | _ => do
      let (env2, fl2) ← execList n env1 step
      match fl2 with
      | .normal => execLoop k n env2 body step
      | .brk => return (env2, .normal)
      | _ => return (env2, fl2)

end

/-- Runs a function without parameters: its body from the empty registers. Falling off the end gives
`value none`. -/
def runFunc (fuel : Nat) (fn : Func) : Outcome :=
  if !fn.params.isEmpty then .stuck "functions with parameters are not modelled"
  else
    match execList fuel [] fn.body with
    | .error o => o
    | .ok (_, .ret v) => .value v
    | .ok (_, .normal) => .value none
    | .ok (_, _) => .stuck "break or continue outside a loop"

/-! ### Lemmas -/

/-- Unsigned reduction is reduction modulo `2^bits`. -/
theorem wrapTo_unsigned_eq (bits : Nat) (x : Int) :
    wrapTo bits false x = x % 2 ^ bits := by
  unfold wrapTo
  simp

/-- The unsigned reduction lands in `[0, 2^bits)`. -/
theorem wrapTo_unsigned_range (bits : Nat) (x : Int) :
    0 ≤ wrapTo bits false x ∧ wrapTo bits false x < 2 ^ bits := by
  have hm : (0 : Int) < 2 ^ bits := by exact_mod_cast Nat.two_pow_pos bits
  have hne : (2 : Int) ^ bits ≠ 0 := fun h0 => by
    rw [h0] at hm
    exact Int.lt_irrefl 0 hm
  rw [wrapTo_unsigned_eq]
  exact ⟨Int.emod_nonneg _ hne, Int.emod_lt_of_pos _ hm⟩

/-- Reducing an unsigned value twice is reducing it once. -/
theorem wrapTo_unsigned_idem (bits : Nat) (x : Int) :
    wrapTo bits false (wrapTo bits false x) = wrapTo bits false x := by
  rw [wrapTo_unsigned_eq, wrapTo_unsigned_eq]
  simp

/-! ### Checks by evaluation

These are kernel-checked: `decide` reduces the definitions. -/

example : wrapTo 32 true 2147483648 = -2147483648 := by decide
example : wrapTo 8 false (-1) = 255 := by decide
example : tdiv (-7) 2 = -3 := by decide

end Nfcxx.IR.Sem
