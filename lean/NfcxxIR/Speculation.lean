/-!
A miniature of the speculation correctness claim of SafeJIT (arXiv:2611.28436): a speculating evaluator with
type guards and deoptimization gives the same outcome as the generic evaluator, for every expression, every
environment and every speculation profile, and it never gets stuck.

The language is integer and boolean expressions: integer literals, variables from an environment, the
binary `+ - *` and unary `neg` on integers (the arithmetic nodes, each with a node id that indexes the
profile), `<` and `==` on same-typed values, and `if`. Values are typed (`int` or `bool`); an operator applied
to operands of the wrong type is a named stuck state, `typeMismatch`, and so is an unbound variable.

The speculating evaluator is driven by a profile: `p id` is the type the node `id` speculated on. For an
arithmetic node that speculated `int`, the evaluator checks the guard (both operands are integers). If the
guard holds it runs the specialized integer path, which works on the unboxed integers. If the guard fails it
deoptimizes: it applies the generic operation to the operand values it has already computed, so the
evaluation resumes in the generic code with the same values and the generic outcome. A node that speculated
`bool` has no specialized path and runs the generic operation.

Everything here is a plain structural recursion, so the definitions reduce by the kernel (`rfl`) and the
theorems are by structural induction over `Expr`. No Mathlib, no `sorry`, no axioms.
-/

namespace Nfcxx.Spec

/-- The speculated types. -/
inductive Ty where
  | int
  | bool
  deriving DecidableEq, Repr

/-- The values: integers and booleans, never mixed. -/
inductive Val where
  | int (n : Int)
  | bool (b : Bool)
  deriving DecidableEq, Repr

/-- The named stuck states: an operator applied to operands of the wrong type, or an unbound variable. -/
inductive Stuck where
  | typeMismatch (op : String)
  | unbound (x : String)
  deriving DecidableEq, Repr

/-- The outcome of an evaluation: a value, or a named stuck state. -/
abbrev Result := Except Stuck Val

/-- The integer operators. -/
inductive BinOp where
  | add
  | sub
  | mul
  deriving DecidableEq, Repr

/-- The expressions. Each arithmetic node carries a node id, which indexes the speculation profile. -/
inductive Expr where
  | lit (n : Int)
  | var (x : String)
  | arith (id : Nat) (op : BinOp) (a b : Expr)
  | neg (id : Nat) (a : Expr)
  | lt (a b : Expr)
  | eq (a b : Expr)
  | ifE (c t e : Expr)

/-- The environment: a variable name to its value. -/
abbrev Env := String → Option Val

/-- The speculation profile: the type each node id speculated on. -/
abbrev Profile := Nat → Ty

/-- The integer meaning of an operator. -/
def intOp : BinOp → Int → Int → Int
  | .add, m, n => m + n
  | .sub, m, n => m - n
  | .mul, m, n => m * n

/-- The name of an operator, for the stuck state. -/
def opName : BinOp → String
  | .add => "+"
  | .sub => "-"
  | .mul => "*"

/-! ### The generic operations: full type checks -/

/-- The generic binary operator: both operands must be integers. -/
def binGeneric (op : BinOp) : Val → Val → Result
  | .int m, .int n => .ok (.int (intOp op m n))
  | _, _ => .error (.typeMismatch (opName op))

/-- The generic negation: the operand must be an integer. -/
def negGeneric : Val → Result
  | .int m => .ok (.int (-m))
  | .bool _ => .error (.typeMismatch "neg")

/-- The generic `<`: both operands must be integers. -/
def ltGeneric : Val → Val → Result
  | .int m, .int n => .ok (.bool (decide (m < n)))
  | _, _ => .error (.typeMismatch "<")

/-- The generic `==`: both operands must be integers, or both booleans. -/
def eqGeneric : Val → Val → Result
  | .int m, .int n => .ok (.bool (decide (m = n)))
  | .bool a, .bool b => .ok (.bool (a == b))
  | _, _ => .error (.typeMismatch "==")

/-- The generic evaluator: every operation is type checked. -/
def eval (ρ : Env) : Expr → Result
  | .lit n => .ok (.int n)
  | .var x => match ρ x with
    | some v => .ok v
    | none => .error (.unbound x)
  | .arith _ op a b => do
    let x ← eval ρ a
    let y ← eval ρ b
    binGeneric op x y
  | .neg _ a => do
    let x ← eval ρ a
    negGeneric x
  | .lt a b => do
    let x ← eval ρ a
    let y ← eval ρ b
    ltGeneric x y
  | .eq a b => do
    let x ← eval ρ a
    let y ← eval ρ b
    eqGeneric x y
  | .ifE c t e => do
    let v ← eval ρ c
    match v with
    | .bool true => eval ρ t
    | .bool false => eval ρ e
    | .int _ => .error (.typeMismatch "if")

/-! ### The speculating operations: a guard, a specialized path, and a deoptimization -/

/-- The guard of a speculated integer operation: both operands are integers. It yields their integers. -/
def guardInt : Val → Val → Option (Int × Int)
  | .int m, .int n => some (m, n)
  | _, _ => none

/-- The guard of a speculated integer negation: the operand is an integer. It yields the integer. -/
def guardNeg : Val → Option Int
  | .int m => some m
  | .bool _ => none

/-- The specialized integer path of a binary operator: it works on unboxed integers, with no type test. -/
def specInt (op : BinOp) (m n : Int) : Val := .int (intOp op m n)

/-- The specialized integer path of a negation. -/
def specNeg (m : Int) : Val := .int (-m)

/-- A binary arithmetic node with node id `id`. If the profile says it speculated `int` and the guard holds,
it takes the specialized path. If the guard fails, it deoptimizes: the generic operation on the operands
already computed. A node that speculated `bool` runs the generic operation. -/
def arithSpec (p : Profile) (id : Nat) (op : BinOp) (x y : Val) : Result :=
  match p id with
  | .int =>
    match guardInt x y with
    | some (m, n) => .ok (specInt op m n)
    | none => binGeneric op x y
  | .bool => binGeneric op x y

/-- A negation node with node id `id`, with the same guard, specialized path and deoptimization. -/
def negSpec (p : Profile) (id : Nat) (x : Val) : Result :=
  match p id with
  | .int =>
    match guardNeg x with
    | some m => .ok (specNeg m)
    | none => negGeneric x
  | .bool => negGeneric x

/-- The speculating evaluator. The comparisons and `if` are not speculated: they run the generic operation
on the values of their operands. -/
def specEval (p : Profile) (ρ : Env) : Expr → Result
  | .lit n => .ok (.int n)
  | .var x => match ρ x with
    | some v => .ok v
    | none => .error (.unbound x)
  | .arith id op a b => do
    let x ← specEval p ρ a
    let y ← specEval p ρ b
    arithSpec p id op x y
  | .neg id a => do
    let x ← specEval p ρ a
    negSpec p id x
  | .lt a b => do
    let x ← specEval p ρ a
    let y ← specEval p ρ b
    ltGeneric x y
  | .eq a b => do
    let x ← specEval p ρ a
    let y ← specEval p ρ b
    eqGeneric x y
  | .ifE c t e => do
    let v ← specEval p ρ c
    match v with
    | .bool true => specEval p ρ t
    | .bool false => specEval p ρ e
    | .int _ => .error (.typeMismatch "if")

/-! ### Theorem 1: guard soundness -/

/-- When the guard of a binary operation holds, the specialized integer path gives the generic result. -/
theorem guard_sound (op : BinOp) (x y : Val) (m n : Int) (h : guardInt x y = some (m, n)) :
    binGeneric op x y = .ok (specInt op m n) := by
  cases x with
  | int a =>
    cases y with
    | int b =>
      simp only [guardInt, Option.some.injEq, Prod.mk.injEq] at h
      obtain ⟨rfl, rfl⟩ := h
      rfl
    | bool _ => simp [guardInt] at h
  | bool _ => simp [guardInt] at h

/-- When the guard of a negation holds, the specialized path gives the generic result. -/
theorem guard_sound_neg (x : Val) (m : Int) (h : guardNeg x = some m) :
    negGeneric x = .ok (specNeg m) := by
  cases x with
  | int a =>
    simp only [guardNeg, Option.some.injEq] at h
    subst h
    rfl
  | bool _ => simp [guardNeg] at h

/-- The speculated node, on any operands, gives the generic result. This covers both the guard holding
(by `guard_sound`) and the guard failing (where the node deoptimizes to the generic operation). -/
theorem arithSpec_eq (p : Profile) (id : Nat) (op : BinOp) (x y : Val) :
    arithSpec p id op x y = binGeneric op x y := by
  unfold arithSpec
  cases p id with
  | int =>
    cases hg : guardInt x y with
    | none => rfl
    | some mn =>
      obtain ⟨m, n⟩ := mn
      exact (guard_sound op x y m n hg).symm
  | bool => rfl

theorem negSpec_eq (p : Profile) (id : Nat) (x : Val) :
    negSpec p id x = negGeneric x := by
  unfold negSpec
  cases p id with
  | int =>
    cases hg : guardNeg x with
    | none => rfl
    | some m => exact (guard_sound_neg x m hg).symm
  | bool => rfl

/-! ### Theorem 2: equivalence with the generic evaluator -/

/-- For every expression, environment and speculation profile, the speculating evaluator's outcome is the
generic evaluator's outcome: the same value, or the same named stuck state (type error or unbound variable). -/
theorem spec_eq_generic (p : Profile) (ρ : Env) (e : Expr) :
    specEval p ρ e = eval ρ e := by
  induction e with
  | lit n => simp [specEval, eval]
  | var x => simp [specEval, eval]
  | arith id op a b iha ihb =>
    simp only [specEval, eval, iha, ihb, arithSpec_eq]
  | neg id a iha =>
    simp only [specEval, eval, iha, negSpec_eq]
  | lt a b iha ihb =>
    simp only [specEval, eval, iha, ihb]
  | eq a b iha ihb =>
    simp only [specEval, eval, iha, ihb]
  | ifE c t e ihc iht ihe =>
    simp only [specEval, eval, ihc, iht, ihe]

/-! ### Theorem 3: the speculating evaluator never gets stuck -/

/-- The speculating evaluator always returns a value or a named stuck state. Its result type is total: there is
no third outcome. Under `spec_eq_generic`, each stuck state it reaches is one the generic evaluator reaches. -/
theorem never_stuck (p : Profile) (ρ : Env) (e : Expr) :
    (∃ v, specEval p ρ e = .ok v) ∨ (∃ s, specEval p ρ e = .error s) := by
  cases h : specEval p ρ e with
  | ok v => exact Or.inl ⟨v, rfl⟩
  | error s => exact Or.inr ⟨s, rfl⟩

/-- The stuck states of the speculating evaluator are exactly those of the generic evaluator, with the same
reason: a deoptimization never introduces a stuck state of its own. -/
theorem stuck_is_generic (p : Profile) (ρ : Env) (e : Expr) (s : Stuck)
    (h : specEval p ρ e = .error s) : eval ρ e = .error s := by
  rw [← spec_eq_generic p ρ e]
  exact h

/-! ### Theorem 4: a worked example, a guard failure and deoptimization -/

/-- `b` is a boolean, `n` an integer. -/
def exampleEnv : Env := fun x =>
  if x = "b" then some (.bool true)
  else if x = "n" then some (.int 4)
  else none

/-- Every node speculated `int`. -/
def allInt : Profile := fun _ => .int

/-- `if n < 0 then 0 else n + 1`, with the addition at node 1 speculated int. Its branch is taken with the
integer `n`: the specialized path runs and gives 5. -/
def exampleOk : Expr :=
  .ifE (.lt (.var "n") (.lit 0)) (.lit 0) (.arith 1 .add (.var "n") (.lit 1))

/-- Node 1 speculated int, and its left operand is the boolean `b`: the guard fails once, the node
deoptimizes to the generic addition, and that reports the type error. -/
def exampleDeopt : Expr :=
  .arith 1 .add (.var "b") (.lit 1)

/-- The guard holds and the specialized path gives 5, the generic evaluator's answer. -/
example : specEval allInt exampleEnv exampleOk = .ok (.int 5) := rfl
example : eval exampleEnv exampleOk = .ok (.int 5) := rfl

/-- The guard fails: the deoptimized node reports the generic type error, and so does the generic evaluator. -/
example : specEval allInt exampleEnv exampleDeopt = .error (.typeMismatch "+") := rfl
example : eval exampleEnv exampleDeopt = .error (.typeMismatch "+") := rfl

/-- The deoptimization example: the speculating and generic evaluators agree on it. -/
theorem deopt_example :
    specEval allInt exampleEnv exampleDeopt = eval exampleEnv exampleDeopt :=
  spec_eq_generic allInt exampleEnv exampleDeopt

end Nfcxx.Spec
