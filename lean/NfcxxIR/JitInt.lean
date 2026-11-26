/-!
The integer code of the x86-64 JIT (lib/ast/nfcast_jit.cpp), modelled in Lean, and proved to compute what the
interpreter computes.

The interpreter runs a statement over integer locals. The JIT compiles the same statement to machine code: a
stack machine whose operands are pushed, whose binary operators pop two values and push one, and whose stores
write a local. A division or modulo by zero has no result: the interpreter raises an error there, and the
compiled code deoptimizes at that point (the interpreter then raises the error).

The loop of a numeric `for` with a known count `k` is compiled as the body's code repeated `k` times. The real
loop has a back edge and a counter that the encoder emits; they are not part of this model, and the
differential tests in tests/ast check the encoder against the interpreter.

The proofs are about the code's shape and control: for every statement, environment and operand stack, the
compiled code yields the interpreter's locals (and leaves the stack as it was), and it deoptimizes exactly when
the interpreter fails. The primitive operations (`Op.apply`) are the same definition on both sides, so their
correctness is not part of these theorems.

No Mathlib, no `sorry`, no axioms beyond Lean's core ones.
-/

namespace Nfcxx.JitInt

/-- The binary integer operators of the JIT's subset. -/
inductive Op where
  | add
  | sub
  | mul
  | div
  | mod
  deriving DecidableEq, Repr

/-- The primitive operations. `none` is the error (a zero divisor): the interpreter raises it, the JIT deoptimizes. -/
def Op.apply : Op → Int → Int → Option Int
  | .add, a, b => some (a + b)
  | .sub, a, b => some (a - b)
  | .mul, a, b => some (a * b)
  | .div, a, b => if b = 0 then none else some (a / b)
  | .mod, a, b => if b = 0 then none else some (a % b)

/-- The expressions: integer literals, integer locals (by slot number), and binary operators. -/
inductive Expr where
  | lit (n : Int)
  | var (x : Nat)
  | bin (op : Op) (a b : Expr)
  deriving Repr

/-- The locals: slot number to value. -/
abbrev Env := Nat → Int

/-- Sets one local. -/
def Env.set (ρ : Env) (x : Nat) (v : Int) : Env := fun y => if y = x then v else ρ y

/-- The interpreter's evaluation of an expression. `none` is the error (a zero divisor somewhere in it). -/
def Expr.eval (ρ : Env) : Expr → Option Int
  | .lit n => some n
  | .var x => some (ρ x)
  | .bin op a b => do
      let va ← a.eval ρ
      let vb ← b.eval ρ
      op.apply va vb

/-- The statements: assign a local, run two statements in order, run a body a fixed number of times. -/
inductive Stmt where
  | assign (x : Nat) (e : Expr)
  | seq (s t : Stmt)
  | forN (k : Nat) (body : Stmt)
  deriving Repr

/-- Runs `f` `k` times, each time on the environment the previous run left. -/
def iter (f : Env → Option Env) : Nat → Env → Option Env
  | 0, ρ => some ρ
  | k + 1, ρ => (f ρ).bind (fun ρ' => iter f k ρ')

/-- The interpreter's execution of a statement. `none` is the error. -/
def Stmt.eval : Stmt → Env → Option Env
  | .assign x e, ρ => (e.eval ρ).map (fun v => ρ.set x v)
  | .seq s t, ρ => (s.eval ρ).bind (fun ρ' => t.eval ρ')
  | .forN k body, ρ => iter (fun r => body.eval r) k ρ

/-- The machine instructions: push a literal, push a local, apply a binary operator to the two top values,
pop the top value into a local. -/
inductive Instr where
  | push (n : Int)
  | load (x : Nat)
  | apply (op : Op)
  | store (x : Nat)
  deriving Repr

/-- The machine state: the locals and the operand stack (top first). -/
abbrev Machine := Env × List Int

/-- Code is a list of instructions. -/
abbrev Code := List Instr

/-- One instruction. `none` is a deoptimization (a zero divisor), or, never for compiled code, a stack underflow. -/
def Instr.step : Instr → Machine → Option Machine
  | .push n, (ρ, st) => some (ρ, n :: st)
  | .load x, (ρ, st) => some (ρ, ρ x :: st)
  | .apply op, (ρ, b :: a :: st) => (op.apply a b).map (fun v => (ρ, v :: st))
  | .apply _, _ => none
  | .store x, (ρ, v :: st) => some (ρ.set x v, st)
  | .store _, _ => none

/-- Runs code on a machine state. -/
def exec : Code → Machine → Option Machine
  | [], m => some m
  | i :: is, m => (i.step m).bind (fun m' => exec is m')

/-- The code of an expression: operands first (left, then right), then the operator. -/
def Expr.compile : Expr → Code
  | .lit n => [.push n]
  | .var x => [.load x]
  | .bin op a b => a.compile ++ b.compile ++ [.apply op]

/-- The code of `k` copies of a code: the body of a loop with a known count. -/
def Code.repeat : Nat → Code → Code
  | 0, _ => []
  | k + 1, c => c ++ Code.repeat k c

/-- The code of a statement. An assignment computes its value and stores it; a loop is its body's code repeated. -/
def Stmt.compile : Stmt → Code
  | .assign x e => e.compile ++ [.store x]
  | .seq s t => s.compile ++ t.compile
  | .forN k body => Code.repeat k body.compile

theorem exec_append (c₁ c₂ : Code) (m : Machine) :
    exec (c₁ ++ c₂) m = (exec c₁ m).bind (fun m' => exec c₂ m') := by
  induction c₁ generalizing m with
  | nil => simp [exec]
  | cons i is ih =>
    simp only [List.cons_append, exec]
    cases h : i.step m with
    | none => simp
    | some m' => simp [ih]

/-- The compiled expression leaves its value on top of the operand stack, and deoptimizes exactly when the
interpreter fails. -/
theorem expr_correct (e : Expr) (ρ : Env) (st : List Int) :
    exec e.compile (ρ, st) = (e.eval ρ).map (fun v => (ρ, v :: st)) := by
  induction e generalizing st with
  | lit n => simp [Expr.compile, exec, Instr.step, Expr.eval]
  | var x => simp [Expr.compile, exec, Instr.step, Expr.eval]
  | bin op a b iha ihb =>
    have hsplit : (Expr.bin op a b).compile = a.compile ++ (b.compile ++ [Instr.apply op]) := by
      simp [Expr.compile, List.append_assoc]
    rw [hsplit, exec_append, iha]
    cases ha : a.eval ρ with
    | none => simp [Expr.eval, ha]
    | some va =>
      show exec (b.compile ++ [Instr.apply op]) (ρ, va :: st) =
        Option.map (fun v => (ρ, v :: st)) (Expr.eval ρ (Expr.bin op a b))
      rw [exec_append, ihb]
      cases hb : b.eval ρ with
      | none => simp [Expr.eval, ha, hb]
      | some vb =>
        rcases hop : op.apply va vb with _ | v <;>
          simp [Expr.eval, ha, hb, hop, exec, Instr.step, Option.bind, Option.map]

/-- The repeated code runs the body `k` times, as the interpreter does. -/
theorem repeat_correct (body : Stmt)
    (ih : ∀ (ρ : Env) (st : List Int), exec body.compile (ρ, st) = (body.eval ρ).map (fun r => (r, st)))
    (k : Nat) : ∀ (ρ : Env) (st : List Int),
    exec (Code.repeat k body.compile) (ρ, st) = (iter (fun r => body.eval r) k ρ).map (fun r => (r, st)) := by
  induction k with
  | zero => intro ρ st; simp [Code.repeat, exec, iter]
  | succ k ihk =>
    intro ρ st
    simp only [Code.repeat, exec_append, ih, iter]
    cases h : body.eval ρ with
    | none => simp
    | some ρ' => simp [ihk]

/-- The compiled statement computes the interpreter's environment, and leaves the operand stack as it was. -/
theorem stmt_correct (s : Stmt) : ∀ (ρ : Env) (st : List Int),
    exec s.compile (ρ, st) = (s.eval ρ).map (fun r => (r, st)) := by
  induction s with
  | assign x e =>
    intro ρ st
    simp only [Stmt.compile, Stmt.eval, exec_append, expr_correct, Option.bind_map]
    cases h : e.eval ρ with
    | none => simp
    | some v => simp [exec, Instr.step]
  | seq s t ihs iht =>
    intro ρ st
    simp only [Stmt.compile, Stmt.eval, exec_append, ihs]
    cases h : s.eval ρ with
    | none => simp
    | some ρ' => simp [iht]
  | forN k body ih =>
    intro ρ st
    simp only [Stmt.compile, Stmt.eval]
    exact repeat_correct body ih k ρ st

/-- The JIT's code and the interpreter agree on every statement: the same locals when the interpreter finishes,
and a deoptimization exactly when the interpreter raises its error. -/
theorem jit_correct (s : Stmt) (ρ : Env) :
    (exec s.compile (ρ, [])).map (fun m => m.1) = s.eval ρ ∧
    (exec s.compile (ρ, [])).isNone = (s.eval ρ).isNone := by
  rw [stmt_correct]
  constructor
  · cases h : s.eval ρ <;> simp
  · cases h : s.eval ρ <;> simp

end Nfcxx.JitInt
