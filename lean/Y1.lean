/-!
Y1-SIMT: the toy GPU of the Theoric note "Building Virtual Hardware for Real Performance", as a Lean model.

Four lanes run in lockstep and share 64 vector registers; VRAM is a flat array of scalars. Three instructions:
`load4` (VRAM to a register), `write4` (a register to VRAM) and `fdot4` (a fused dot product and accumulate:
`out[t] = c[t] + dot(a, b[t])` for each lane `t`, where `b` is a block of four registers). The machine is one function,
`step`, and running a program is a fold over it.

The values are integers, not FP32, so the results are exact and decidable. The model is about the instruction semantics;
rounding is out of scope.

A register index is a `Fin NumRegs`, so writing `reg 64` is a compile error (`reg 64` needs a proof that `64 < 64`), which
is the point of the note's typed instruction set. Demo and checks follow the note's 4x4 matrix multiply.
-/

namespace Y1

abbrev Lanes : Nat := 4
abbrev NumRegs : Nat := 64

/-- One value per lane. -/
abbrev Vec := Fin Lanes → Int

abbrev Reg := Fin NumRegs

/-- The four registers of an `fdot4` operand block: lane `t` reads `block t`. -/
abbrev RegBlock := Fin Lanes → Reg

inductive Instr where
  | load4 (src : Nat) (dst : Reg)
  | write4 (src : Reg) (dst : Nat)
  | fdot4 (a : Reg) (b : RegBlock) (c : Reg)

structure State where
  regs : Reg → Vec
  vram : Array Int

/-- All registers start at zero, and VRAM holds the given scalars. -/
def initial (vram : Array Int) : State :=
  { regs := fun _ => fun _ => 0, vram := vram }

/-- The four scalars at `addr`, if they lie inside VRAM. -/
def readVram (s : State) (addr : Nat) : Except String Vec :=
  if addr + Lanes ≤ s.vram.size then
    pure (fun t => s.vram.getD (addr + t.val) 0)
  else
    throw s!"vram read out of range at {addr}"

/-- The dot product of two lane vectors, over the four lanes. -/
def dot (a w : Vec) : Int :=
  a 0 * w 0 + a 1 * w 1 + a 2 * w 2 + a 3 * w 3

def step (s : State) : Instr → Except String State
  | .load4 src dst => do
      let v ← readVram s src
      pure { s with regs := fun r => if r = dst then v else s.regs r }
  | .write4 src dst =>
      if dst + Lanes ≤ s.vram.size then
        pure { s with
          vram := (List.range Lanes).foldl (fun arr t =>
            if h : t < Lanes then arr.set! (dst + t) (s.regs src ⟨t, h⟩) else arr) s.vram }
      else
        throw s!"vram write out of range at {dst}"
  | .fdot4 a b c => do
      let va := s.regs a
      let out : Vec := fun t => s.regs c t + dot va (s.regs (b t))
      pure { s with regs := fun r => if r = c then out else s.regs r }

/-- Runs a program: a fold of `step`. -/
def run (s0 : State) (p : List Instr) : Except String State :=
  p.foldlM step s0

/-- The register with index `n` (taken mod 64): a total helper for generated programs. -/
def regN (n : Nat) : Reg :=
  ⟨n % NumRegs, Nat.mod_lt _ (by decide)⟩

/-! ## The 4x4 matrix multiply of the note

VRAM layout: A row-major at 0..15 (A i k at 4i+k), B transposed at 16..31 (B k t at 16+4t+k, so each row of the transposed
store is one column of B), C at 32..47 (C i t at 32+4i+t).

Registers: 0..3 hold the rows of A, 4..7 the block of B columns, 8..11 accumulate the rows of C.
Each `fdot4` computes one row of C: lane `t` gets `dot(A row i, B column t)`. -/

def blockB : RegBlock := fun t => regN (4 + t.val)

def matmulProgram : List Instr :=
  (List.range 4).map (fun i => Instr.load4 (4 * i) (regN i)) ++
  (List.range 4).map (fun t => Instr.load4 (16 + 4 * t) (regN (4 + t))) ++
  (List.range 4).map (fun i => Instr.fdot4 (regN i) blockB (regN (8 + i))) ++
  (List.range 4).map (fun i => Instr.write4 (regN (8 + i)) (32 + 4 * i))

/-- The 16 scalars of C after a run (or none, if the run failed). -/
def outC : Except String State → List Int
  | .ok s => (List.range 16).map (fun j => s.vram.getD (32 + j) 0)
  | .error _ => []

/-- VRAM for A and B: `a i k` and `b k t` are the entries. -/
def inputVram (a b : Nat → Nat → Int) : Array Int :=
  let aPart := (List.range 16).map (fun j => a (j / 4) (j % 4))
  let bPart := (List.range 16).map (fun j => b (j % 4) (j / 4))
  let cPart := List.replicate 16 0
  (aPart ++ bPart ++ cPart).toArray

/-- A = [[1,2,3,4],[5,6,7,8],[9,10,11,12],[13,14,15,16]] and B = 2 times the identity plus the all-ones matrix. -/
def exA : Nat → Nat → Int := fun i k => (4 * i + k + 1 : Nat)
def exB : Nat → Nat → Int := fun k t => (if k = t then 2 else 0) + 1

def exExpected : List Int :=
  (List.range 16).map (fun j =>
    let i := j / 4
    let t := j % 4
    (List.range 4).foldl (fun acc k => acc + exA i k * exB k t) 0)

/-! ## Checks, evaluated when the library is built -/

/-- The demo: the simulator's C is A times B. -/
example : outC (run (initial (inputVram exA exB)) matmulProgram) = exExpected := by decide

/-- A mutant: a wrong accumulator register breaks the result, so the check above is not vacuous. -/
def mutantProgram : List Instr :=
  matmulProgram.map (fun
    | .fdot4 a b _ => .fdot4 a b (regN 12)
    | i => i)

example : outC (run (initial (inputVram exA exB)) mutantProgram) ≠ exExpected := by decide

/-- A read past the end of VRAM is an error, not an arbitrary value. -/
example : (run (initial (inputVram exA exB)) [Instr.load4 45 (regN 0)]).isOk = false := by decide

/-- A write past the end of VRAM is an error. -/
example : (run (initial (inputVram exA exB)) [Instr.write4 (regN 0) 45]).isOk = false := by decide

end Y1
