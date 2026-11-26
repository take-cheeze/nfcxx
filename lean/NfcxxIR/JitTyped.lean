/-!
The typed code of the x86-64 JIT (lib/ast/nfcast_jit.cpp), modelled in Lean, and proved to compute what the
interpreter computes. This extends `JitInt` (which is unchanged) from integers to two value kinds: an integer
(`int`) and a float (`flt`, an IEEE double). Each local has one kind for the whole loop; the entry guard checks
it, and the body keeps it.

The arithmetic mirrors `arith_numbers` in lib/ast/nfcast_ops.cpp:
- on two integers, `+ - *` give an integer, `//` and `%` give an integer (floor division and modulo, `Int.fdiv`
  and `Int.fmod`, which are the interpreter's `int_floordiv` and `int_mod`), and `/` and `^` give a float;
- with a float operand, every operator gives a float, and an integer operand is converted to a double first;
- an integer `//` or `%` by zero is the error (`Err.divZero`); a float one gives `inf` or `nan`, and so does an
  integer `/` by zero (converted to doubles first), so only integer `//` and `%` can fail.

Shared definitions. The primitive operations are definitions that both sides use (as `Op.apply` is in JitInt),
so their agreement with the C++ is not proved here: the float operations are Lean core's `Float` operations
(`+ - * /`, `Float.floor`, `Float.pow`, `Float.ofInt`), which are the C double operations; `fmod`, which the
interpreter calls for float `%`, is an `opaque` constant (Lean has none), and no property of it is used; the
integer operations are `Int.fdiv` and `Int.fmod`. Integers are unbounded `Int`: the 64-bit wrap of the C++ is not
modelled (as in JitInt). The interpreter's `flt_pow` special case (`a * a` for an exponent of 2) is not modelled
either; `^` is `Float.pow` on both sides.

Typing. `Expr.ty Γ` is the static kind of an expression under the kinds `Γ` of the locals: it is total, since
every operator has a result kind for every pair of kinds. `Stmt.typed Γ` says that every assignment stores a value
of its local's kind (`e.ty Γ = Γ x`), so no local changes kind. `Guard Γ ρ` is the entry check: every local holds
a value of its kind. The model takes every local slot, not only the live-ins, so the guard here is stronger than
the C++ check, so the theorems assume more than the C++ check guarantees; they are not proved for the live-in check alone.

Theorems: `apply_ty` and `apply_ok_of_flt` (the result kinds), `expr_eval_typed` (an expression under the guard
evaluates to a value of its static kind, and fails only with a zero integer divisor), `expr_correct`,
`repeat_correct`, `stmt_correct` and `jit_correct` (the untyped shape of JitInt, on the typed machine),
`stmt_typed` and `repeat_typed` (type stability: a body that types keeps the guard after each iteration, proved
for `Code.repeat` by induction on the count), and `jit_guard_correct` (under the guard the compiled code computes
the interpreter's result, deoptimizes exactly when the interpreter errors, and leaves the guard valid).

No Mathlib, no `sorry`, and no axioms beyond Lean's core ones (`propext`, and `Quot.sound` through the function
extensionality that `simp` uses on environments); the `opaque` constant `fmod` is not a proposition.
-/

namespace Nfcxx.JitTyped

/-- The kinds of values: an integer, or a float. -/
inductive Ty where
  | int
  | flt
  deriving DecidableEq, Repr

/-- The values. -/
inductive Val where
  | int (n : Int)
  | flt (x : Float)

/-- The kind of a value. -/
def Val.ty : Val → Ty
  | .int _ => .int
  | .flt _ => .flt

/-- A value as a float: an integer converts to a double, as the interpreter does. -/
def Val.toFloat : Val → Float
  | .int n => Float.ofInt n
  | .flt x => x

/-- The binary operators of the JIT's typed subset. -/
inductive Op where
  | add
  | sub
  | mul
  | div
  | idiv
  | mod
  | pow
  deriving DecidableEq, Repr

/-- The kind of a result. `/` and `^` always give a float. The other operators give an integer on two integers, and
a float when an operand is a float. -/
def Op.resTy : Op → Ty → Ty → Ty
  | .div, _, _ => .flt
  | .pow, _, _ => .flt
  | _, .int, .int => .int
  | _, _, _ => .flt

/-- C's `fmod`, which the interpreter calls for a float `%`. Lean has none. It is a shared definition: the proofs
never unfold it, so they use nothing about it. -/
opaque fmod : Float → Float → Float

/-- The float operations, on floats: `//` is `floor (a / b)` and `%` is `fmod`, as the interpreter's `arith_numbers`. -/
def Op.applyFlt : Op → Float → Float → Float
  | .add, a, b => a + b
  | .sub, a, b => a - b
  | .mul, a, b => a * b
  | .div, a, b => a / b
  | .idiv, a, b => Float.floor (a / b)
  | .mod, a, b => fmod a b
  | .pow, a, b => Float.pow a b

/-- The errors: an integer division or modulo by zero (the only error an operator raises), and a malformed machine
state (a stack that is too short for an operator or a store: never raised by compiled code). -/
inductive Err where
  | divZero
  | badCode
  deriving DecidableEq, Repr

/-- The operators on two integers. An integer `//` or `%` by zero is the error. `/` and `^` give a float, with no
error (a zero divisor gives `inf` or `nan`). -/
def Op.applyInt : Op → Int → Int → Except Err Val
  | .add, a, b => .ok (.int (a + b))
  | .sub, a, b => .ok (.int (a - b))
  | .mul, a, b => .ok (.int (a * b))
  | .idiv, a, b => if b = 0 then .error .divZero else .ok (.int (a.fdiv b))
  | .mod, a, b => if b = 0 then .error .divZero else .ok (.int (a.fmod b))
  | .div, a, b => .ok (.flt (Op.applyFlt .div (Float.ofInt a) (Float.ofInt b)))
  | .pow, a, b => .ok (.flt (Op.applyFlt .pow (Float.ofInt a) (Float.ofInt b)))

/-- The operator on two values: two integers take the integer rules; otherwise both are converted to floats. -/
def Op.apply (op : Op) : Val → Val → Except Err Val
  | .int a, .int b => op.applyInt a b
  | x, y => .ok (.flt (Op.applyFlt op x.toFloat y.toFloat))

/-- The expressions: values (literals), locals (by slot number), and binary operators. -/
inductive Expr where
  | lit (v : Val)
  | var (x : Nat)
  | bin (op : Op) (a b : Expr)

/-- The locals: slot number to value. Every slot holds a value. -/
abbrev Env := Nat → Val

/-- Sets one local. -/
def Env.set (ρ : Env) (x : Nat) (v : Val) : Env := fun y => if y = x then v else ρ y

/-- The interpreter's evaluation of an expression. An error is the failure of an operator. -/
def Expr.eval (ρ : Env) : Expr → Except Err Val
  | .lit v => .ok v
  | .var x => .ok (ρ x)
  | .bin op a b => (a.eval ρ).bind (fun va => (b.eval ρ).bind (fun vb => op.apply va vb))

/-- The statements: assign a local, run two statements in order, run a body a fixed number of times. -/
inductive Stmt where
  | assign (x : Nat) (e : Expr)
  | seq (s t : Stmt)
  | forN (k : Nat) (body : Stmt)

/-- Runs `f` `k` times, each time on the environment the previous run left. -/
def iter (f : Env → Except Err Env) : Nat → Env → Except Err Env
  | 0, ρ => .ok ρ
  | k + 1, ρ => (f ρ).bind (fun ρ' => iter f k ρ')

/-- The interpreter's execution of a statement. -/
def Stmt.eval : Stmt → Env → Except Err Env
  | .assign x e, ρ => (e.eval ρ).map (fun v => ρ.set x v)
  | .seq s t, ρ => (s.eval ρ).bind (fun ρ' => t.eval ρ')
  | .forN k body, ρ => iter (fun r => body.eval r) k ρ

/-- The static kind of an expression, under the kinds `Γ` of the locals. -/
def Expr.ty (Γ : Nat → Ty) : Expr → Ty
  | .lit v => v.ty
  | .var x => Γ x
  | .bin op a b => op.resTy (a.ty Γ) (b.ty Γ)

/-- A statement types under `Γ` when every assignment stores a value of its local's kind, so that no local changes
kind. -/
def Stmt.typed (Γ : Nat → Ty) : Stmt → Bool
  | .assign x e => decide (e.ty Γ = Γ x)
  | .seq s t => s.typed Γ && t.typed Γ
  | .forN _ body => body.typed Γ

/-- The entry guard: every local holds a value of the kind the loop was compiled for. -/
def Guard (Γ : Nat → Ty) (ρ : Env) : Prop := ∀ x, (ρ x).ty = Γ x

/-- The machine instructions: push a value, push a local, apply a binary operator to the two top values, pop the top
value into a local. -/
inductive Instr where
  | push (v : Val)
  | load (x : Nat)
  | apply (op : Op)
  | store (x : Nat)

/-- The machine state: the locals and the operand stack (top first). -/
abbrev Machine := Env × List Val

/-- Code is a list of instructions. -/
abbrev Code := List Instr

/-- One instruction. An error is a deoptimization (a zero integer divisor), or, never for compiled code, a malformed
stack. -/
def Instr.step : Instr → Machine → Except Err Machine
  | .push v, (ρ, st) => .ok (ρ, v :: st)
  | .load x, (ρ, st) => .ok (ρ, ρ x :: st)
  | .apply op, (ρ, b :: a :: st) => (op.apply a b).map (fun v => (ρ, v :: st))
  | .apply _, _ => .error .badCode
  | .store x, (ρ, v :: st) => .ok (ρ.set x v, st)
  | .store _, _ => .error .badCode

/-- Runs code on a machine state. -/
def exec : Code → Machine → Except Err Machine
  | [], m => .ok m
  | i :: is, m => (i.step m).bind (fun m' => exec is m')

/-- The code of an expression: operands first (left, then right), then the operator. -/
def Expr.compile : Expr → Code
  | .lit v => [.push v]
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

/-! ### Except: the reduction lemmas used by the proofs -/

@[simp] theorem bind_ok {ε α β : Type} (a : α) (f : α → Except ε β) :
    (Except.ok a : Except ε α).bind f = f a := rfl

@[simp] theorem bind_error {ε α β : Type} (e : ε) (f : α → Except ε β) :
    (Except.error e : Except ε α).bind f = .error e := rfl

@[simp] theorem map_ok {ε α β : Type} (a : α) (f : α → β) :
    (Except.ok a : Except ε α).map f = .ok (f a) := rfl

@[simp] theorem map_error {ε α β : Type} (e : ε) (f : α → β) :
    (Except.error e : Except ε α).map f = .error e := rfl

/-- The evaluation of a binary expression: the left operand, then the right, then the operator. -/
theorem eval_bin (ρ : Env) (op : Op) (a b : Expr) :
    (Expr.bin op a b).eval ρ = (a.eval ρ).bind (fun va => (b.eval ρ).bind (fun vb => op.apply va vb)) := rfl

/-! ### Result kinds -/

/-- The kind of an operator's result is the kind the typing rules give. -/
theorem applyInt_ty (op : Op) (a b : Int) (v : Val) (h : op.applyInt a b = .ok v) :
    v.ty = op.resTy .int .int := by
  cases op <;> simp only [Op.applyInt] at h <;> (try split at h) <;> cases h <;> rfl

/-- On any two values the operator gives a value of the kind the typing rules give. -/
theorem apply_ty (op : Op) (x y v : Val) (h : op.apply x y = .ok v) :
    v.ty = op.resTy x.ty y.ty := by
  cases x with
  | int a =>
    cases y with
    | int b => exact applyInt_ty op a b v h
    | flt _ =>
      simp only [Op.apply, Except.ok.injEq] at h
      subst h
      cases op <;> rfl
  | flt _ =>
    cases y with
    | int _ =>
      simp only [Op.apply, Except.ok.injEq] at h
      subst h
      cases op <;> rfl
    | flt _ =>
      simp only [Op.apply, Except.ok.injEq] at h
      subst h
      cases op <;> rfl

/-- An operator on two values with a float among them never fails. -/
theorem apply_ok_of_flt (op : Op) (x y : Val) (h : x.ty = .flt ∨ y.ty = .flt) :
    ∃ v, op.apply x y = .ok v := by
  cases x with
  | int a =>
    cases y with
    | int b => simp [Val.ty] at h
    | flt _ => exact ⟨_, rfl⟩
  | flt _ =>
    cases y with
    | int _ => exact ⟨_, rfl⟩
    | flt _ => exact ⟨_, rfl⟩

/-- The only error an operator raises is the zero integer divisor. -/
theorem apply_err (op : Op) (x y : Val) (s : Err) (h : op.apply x y = .error s) : s = .divZero := by
  cases x with
  | int a =>
    cases y with
    | int b =>
      cases op <;> simp only [Op.apply, Op.applyInt] at h <;> (try split at h) <;> simp_all
    | flt _ => simp [Op.apply] at h
  | flt _ => cases y <;> simp [Op.apply] at h

/-! ### Theorem 1: an expression under the guard evaluates to a value of its static kind -/

/-- Under the guard, an expression that evaluates to a value gives a value of its static kind, and its only error
is a zero integer divisor. -/
theorem expr_eval_typed (Γ : Nat → Ty) (ρ : Env) (hρ : Guard Γ ρ) (e : Expr) :
    (∀ v, e.eval ρ = .ok v → v.ty = e.ty Γ) ∧ (∀ s, e.eval ρ = .error s → s = .divZero) := by
  induction e with
  | lit v =>
    refine ⟨fun w h => ?_, fun s h => ?_⟩
    · simp only [Expr.eval, Except.ok.injEq] at h
      subst h
      rfl
    · simp [Expr.eval] at h
  | var x =>
    refine ⟨fun w h => ?_, fun s h => ?_⟩
    · simp only [Expr.eval, Except.ok.injEq] at h
      subst h
      exact hρ x
    · simp [Expr.eval] at h
  | bin op a b iha ihb =>
    constructor
    · intro v h
      rw [eval_bin] at h
      cases ha : a.eval ρ with
      | error s => rw [ha] at h; cases h
      | ok va =>
        rw [ha] at h
        cases hb : b.eval ρ with
        | error s => rw [hb] at h; cases h
        | ok vb =>
          rw [hb] at h
          have hk := apply_ty op va vb v h
          simp only [Expr.ty, hk, iha.1 va ha, ihb.1 vb hb]
    · intro s h
      rw [eval_bin] at h
      cases ha : a.eval ρ with
      | error s' =>
        rw [ha] at h
        cases h
        exact iha.2 _ ha
      | ok va =>
        rw [ha] at h
        cases hb : b.eval ρ with
        | error s' =>
          rw [hb] at h
          cases h
          exact ihb.2 _ hb
        | ok vb =>
          rw [hb] at h
          exact apply_err op va vb s h

/-! ### The machine: composition, and the expression and statement code -/

theorem exec_append (c₁ c₂ : Code) (m : Machine) :
    exec (c₁ ++ c₂) m = (exec c₁ m).bind (fun m' => exec c₂ m') := by
  induction c₁ generalizing m with
  | nil => simp [exec]
  | cons i is ih =>
    simp only [List.cons_append, exec]
    cases h : i.step m with
    | error e => simp
    | ok m' => simp [ih]

/-- The compiled expression leaves its value on top of the operand stack, and fails exactly when the interpreter does,
with the same error. -/
theorem expr_correct (e : Expr) (ρ : Env) (st : List Val) :
    exec e.compile (ρ, st) = (e.eval ρ).map (fun v => (ρ, v :: st)) := by
  induction e generalizing st with
  | lit v => simp [Expr.compile, exec, Instr.step, Expr.eval]
  | var x => simp [Expr.compile, exec, Instr.step, Expr.eval]
  | bin op a b iha ihb =>
    have hsplit : (Expr.bin op a b).compile = a.compile ++ (b.compile ++ [Instr.apply op]) := by
      simp [Expr.compile, List.append_assoc]
    rw [hsplit, exec_append, iha, eval_bin]
    cases ha : a.eval ρ with
    | error s => simp
    | ok va =>
      simp only [map_ok, bind_ok]
      rw [exec_append, ihb]
      cases hb : b.eval ρ with
      | error s => simp
      | ok vb =>
        simp only [map_ok, bind_ok]
        cases hop : op.apply va vb with
        | error s => simp [exec, Instr.step, hop]
        | ok v => simp [exec, Instr.step, hop]

/-- The repeated code runs the body `k` times, as the interpreter does. -/
theorem repeat_correct (body : Stmt)
    (ih : ∀ (ρ : Env) (st : List Val), exec body.compile (ρ, st) = (body.eval ρ).map (fun r => (r, st)))
    (k : Nat) : ∀ (ρ : Env) (st : List Val),
    exec (Code.repeat k body.compile) (ρ, st) = (iter (fun r => body.eval r) k ρ).map (fun r => (r, st)) := by
  induction k with
  | zero => intro ρ st; simp [Code.repeat, exec, iter, Except.map]
  | succ k ihk =>
    intro ρ st
    simp only [Code.repeat, exec_append, ih, iter]
    cases h : body.eval ρ with
    | error e => simp [Except.map, Except.bind]
    | ok ρ' => simp [Except.map, Except.bind, ihk]

/-- The compiled statement computes the interpreter's environment, and leaves the operand stack as it was. -/
theorem stmt_correct (s : Stmt) : ∀ (ρ : Env) (st : List Val),
    exec s.compile (ρ, st) = (s.eval ρ).map (fun r => (r, st)) := by
  induction s with
  | assign x e =>
    intro ρ st
    simp only [Stmt.compile, exec_append, expr_correct]
    cases h : e.eval ρ with
    | error s => simp [Stmt.eval, h]
    | ok v => simp [Stmt.eval, h, exec, Instr.step]
  | seq s t ihs iht =>
    intro ρ st
    simp only [Stmt.compile, Stmt.eval, exec_append, ihs]
    cases h : s.eval ρ with
    | error e => simp
    | ok ρ' => simp [iht]
  | forN k body ih =>
    intro ρ st
    simp only [Stmt.compile, Stmt.eval]
    exact repeat_correct body ih k ρ st

/-- The JIT's code and the interpreter agree on every statement: the same locals when the interpreter finishes, and
a deoptimization with the same error exactly when the interpreter raises it. -/
theorem jit_correct (s : Stmt) (ρ : Env) :
    (exec s.compile (ρ, [])).map (fun m => m.1) = s.eval ρ ∧
    (∀ e, exec s.compile (ρ, []) = .error e ↔ s.eval ρ = .error e) := by
  rw [stmt_correct]
  constructor
  · cases h : s.eval ρ <;> simp [Except.map]
  · intro e
    cases h : s.eval ρ <;> simp [Except.map]

/-! ### Theorem 2: type stability of the interpreter and of the loop's code -/

/-- An assignment of a value of the local's kind keeps the guard. -/
theorem guard_set (Γ : Nat → Ty) (ρ : Env) (x : Nat) (v : Val) (hρ : Guard Γ ρ) (hv : v.ty = Γ x) :
    Guard Γ (ρ.set x v) := by
  intro y
  by_cases h : y = x
  · subst h
    simp [Env.set, hv]
  · simp [Env.set, h, hρ y]

/-- A run of `f`, which keeps the guard, `k` times keeps it. -/
theorem iter_guard (Γ : Nat → Ty) (f : Env → Except Err Env)
    (hf : ∀ ρ ρ', Guard Γ ρ → f ρ = .ok ρ' → Guard Γ ρ') :
    ∀ (k : Nat) (ρ ρ' : Env), Guard Γ ρ → iter f k ρ = .ok ρ' → Guard Γ ρ' := by
  intro k
  induction k with
  | zero =>
    intro ρ ρ' hg h
    simp only [iter, Except.ok.injEq] at h
    subst h
    exact hg
  | succ k ih =>
    intro ρ ρ' hg h
    simp only [iter] at h
    cases hf1 : f ρ with
    | error e => simp [hf1, Except.bind] at h
    | ok ρ1 =>
      simp only [hf1, Except.bind] at h
      exact ih ρ1 ρ' (hf ρ ρ1 hg hf1) h

/-- A statement that types under `Γ` keeps the guard: after it runs on an environment that satisfies the guard, the
environment satisfies it. -/
theorem stmt_typed (Γ : Nat → Ty) : ∀ (s : Stmt), s.typed Γ = true →
    ∀ (ρ ρ' : Env), Guard Γ ρ → s.eval ρ = .ok ρ' → Guard Γ ρ' := by
  intro s
  induction s with
  | assign x e =>
    intro hs ρ ρ' hg h
    have hk : e.ty Γ = Γ x := by simpa [Stmt.typed] using hs
    cases he : e.eval ρ with
    | error s' => simp [Stmt.eval, he, Except.map] at h
    | ok v =>
      simp only [Stmt.eval, he, Except.map, Except.ok.injEq] at h
      subst h
      exact guard_set Γ ρ x v hg ((expr_eval_typed Γ ρ hg e).1 v he |>.trans hk)
  | seq s t ihs iht =>
    intro hs ρ ρ' hg h
    simp only [Stmt.typed, Bool.and_eq_true] at hs
    cases hs1 : s.eval ρ with
    | error s' => simp [Stmt.eval, hs1, Except.bind] at h
    | ok ρ1 =>
      simp only [Stmt.eval, hs1, Except.bind] at h
      exact iht hs.2 ρ1 ρ' (ihs hs.1 ρ ρ1 hg hs1) h
  | forN k body ih =>
    intro hs ρ ρ' hg h
    simp only [Stmt.typed] at hs
    exact iter_guard Γ (fun r => body.eval r) (fun r r' hr hr' => ih hs r r' hr hr') k ρ ρ' hg h

/-- Type stability of the compiled loop body: when the body types under `Γ`, each run of its code, from an
environment that satisfies the guard, leaves an environment that satisfies it, and the operand stack as it was. By
induction on the count, so the guard holds at every iteration of the repeated code. -/
theorem repeat_typed (Γ : Nat → Ty) (body : Stmt) (hb : body.typed Γ = true) (k : Nat) :
    ∀ (ρ ρ' : Env) (st st' : List Val), Guard Γ ρ →
      exec (Code.repeat k body.compile) (ρ, st) = .ok (ρ', st') → Guard Γ ρ' ∧ st' = st := by
  induction k with
  | zero =>
    intro ρ ρ' st st' hg h
    simp only [Code.repeat, exec, Except.ok.injEq, Prod.mk.injEq] at h
    obtain ⟨rfl, rfl⟩ := h
    exact ⟨hg, rfl⟩
  | succ k ihk =>
    intro ρ ρ' st st' hg h
    simp only [Code.repeat] at h
    rw [exec_append, stmt_correct] at h
    cases hb1 : body.eval ρ with
    | error e => simp [hb1, Except.map, Except.bind] at h
    | ok ρ1 =>
      simp only [hb1, Except.map, Except.bind] at h
      exact ihk ρ1 ρ' st st' (stmt_typed Γ body hb ρ ρ1 hg hb1) h

/-! ### Theorem 3: the guard theorem -/

/-- Under the entry guard, for a statement that types under the loop's kinds, the compiled code computes the
interpreter's result (the same environment, or the same error), deoptimizes exactly when the interpreter errors, and
leaves the guard valid: the next takeover of the loop passes the check. -/
theorem jit_guard_correct (Γ : Nat → Ty) (s : Stmt) (hs : s.typed Γ = true) (ρ : Env) (hρ : Guard Γ ρ) :
    (exec s.compile (ρ, [])).map (fun m => m.1) = s.eval ρ ∧
    (∀ e, exec s.compile (ρ, []) = .error e ↔ s.eval ρ = .error e) ∧
    (∀ ρ', s.eval ρ = .ok ρ' → Guard Γ ρ') :=
  ⟨(jit_correct s ρ).1, (jit_correct s ρ).2, fun ρ' h => stmt_typed Γ s hs ρ ρ' hρ h⟩

/-- The loop with a known count, as compiled, keeps the guard: its code run from a guarded environment leaves a guarded
environment, with the operand stack as it was. -/
theorem loop_guard (Γ : Nat → Ty) (k : Nat) (body : Stmt) (hb : body.typed Γ = true) (ρ ρ' : Env) (st st' : List Val)
    (hg : Guard Γ ρ) (h : exec (Stmt.compile (.forN k body)) (ρ, st) = .ok (ρ', st')) :
    Guard Γ ρ' ∧ st' = st :=
  repeat_typed Γ body hb k ρ ρ' st st' hg h

/-! ### Examples: the result kinds and the errors -/

/-- `/` on two integers is a float, and a zero divisor gives no error. -/
theorem div_int_flt (a b : Int) : ∃ x, Op.apply .div (.int a) (.int b) = .ok (.flt x) := ⟨_, rfl⟩

/-- An integer `//` by zero is the error. -/
example (a : Int) : Op.apply .idiv (.int a) (.int 0) = .error .divZero := by
  simp [Op.apply, Op.applyInt]

/-- Integer floor division and modulo: `7 // -2 = -4` and `7 % -2 = -1` (the sign of the divisor), as the
interpreter's `int_floordiv` and `int_mod`. -/
example : Op.apply .idiv (.int 7) (.int (-2)) = .ok (.int (-4)) := rfl
example : Op.apply .mod (.int 7) (.int (-2)) = .ok (.int (-1)) := rfl

/-- Integer addition gives an integer. -/
example : (Op.apply .add (.int 1) (.int 2)).map Val.ty = .ok .int := rfl

end Nfcxx.JitTyped
