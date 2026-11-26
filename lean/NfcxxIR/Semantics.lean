import NfcxxIR.Syntax

/-!
Executable semantics of a subset of the mid-level IR (docs/notes/pathb-stage2.md, sections 3, 4 and 6).

The subset is what an integer-only function body needs: integer types, registers, stack slots of integer type
(`load` and `store` through a local `$"x"`), block pointers into the slots (`offset`, and `load` and `store`
through a pointer, with the null and bounds traps of the memory section below), constants, the wrapping,
checked and bitwise arithmetic, comparisons, the integer conversions `iconv` and same-width `bitcast`, `eval` of
a value (its value is discarded), and the structured statements (`let`, `set`, `if`, `loop`, `block`, `switch`
with its top-level `case` and `default` labels, `break`, `continue`, `return`, `unreachable`, `trap`). Everything
else is reported as `stuck` with the reason, never silently skipped: pointers into anything but a slot, pointers
stored in memory outside the slot model (see the memory section), calls outside the module, floats, exceptions,
`goto`, and labels nested inside a switch arm. Those are the next steps.

Values are mathematical integers, kept in the range of their type by `wrapTo` after every operation, or pointers
(see the memory section). A boolean is 0 or 1. The semantics is fuel-bounded: running out of fuel is `stuck`, so
a result that is `value` or `trap` is always a real outcome of the program.

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

/-- The name of a conversion, for the stuck messages. -/
def ConvOp.name : ConvOp → String
  | .iconv => "iconv"
  | .bitcast => "bitcast"
  | .i2p => "i2p"
  | .p2i => "p2i"
  | .cf2i => "cf2i"
  | .i2f => "i2f"
  | .u2f => "u2f"
  | .fconv => "fconv"

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

/-! ### State

A block is the storage a pointer points into: a slot (a named local, `$"x"`) of the function. Its byte size is the
one its `(slot ...)` declaration gives (see the memory section). -/
inductive Block where
  | slot : String → Block

/-- A value in the state: an integer; a pointer, as the block and the byte offset from the block's first byte; or
the null pointer. -/
inductive Val where
  | int : Int → Val
  | ptr : Block → Int → Val
  | null : Val

def Val.isInt : Val → Bool
  | Val.int _ => true
  | _ => false

/-- A cell of the state: a register; one byte of a slot (the slot's name, and the index of the byte from the
slot's first byte, little-endian); or a declaration of the frame: the byte size of a slot, or a marker that the
name is declared more than once in the function (scopes are not modelled, so that block is stuck). -/
inductive Cell where
  | reg : Nat → Cell
  | byte : String → Nat → Cell
  /-- The side table of stored pointers: the pointer (a block and offset, or null) stored over the bytes
  `[i, i + ptrBytes)` of slot `x`, keyed by the slot name and the index `i` of its first byte. -/
  | ptr : String → Nat → Cell
  | size : String → Cell
  | dup : String → Cell
  deriving BEq

/-- A value in the state: the value, and the integer type it has (width and signedness) when its declared type is
an integer type. The type is what `bitcast` and `switch` check. -/
structure Entry where
  val : Val
  info : Option (Nat × Bool)

/-- The cells, the newest first. A read is the first entry for its cell. -/
abbrev Env := List (Cell × Entry)

def Env.lookup (e : Env) (c : Cell) : Option Entry :=
  match e.find? (fun p => p.1 == c) with
  | some p => some p.2
  | none => none

def Env.get (e : Env) (c : Cell) : Option Val :=
  match e.lookup c with
  | some r => some r.val
  | none => none

/-- Sets a cell. The older entry for the cell is dropped, so the environment keeps one entry per cell. -/
def Env.set (e : Env) (c : Cell) (v : Val) (info : Option (Nat × Bool)) : Env :=
  (c, ⟨v, info⟩) :: e.filter (fun p => !(p.1 == c))

/-- How a statement list ends: falling off the end, leaving a loop, continuing it, or returning. -/
inductive Flow where
  | normal
  | brk
  | cont
  | ret : Option Int → Flow
  deriving Repr

/-- The integer type of an operand, when the semantics knows it: a constant's type, or the declared type of a
register. -/
def operandInfo (env : Env) : Operand → Option (Nat × Bool)
  | Operand.reg n => match env.lookup (.reg n) with
    | some r => r.info
    | none => none
  | Operand.constant t _ => infoOf t
  | _ => none

/-- An operand as a value: a register, a constant, the address of a slot (`$"x"`, the pointer to its first byte),
or the null pointer. Other operands are stuck. -/
def evalVal (env : Env) : Operand → Except Outcome Val
  | Operand.reg n =>
    match env.get (.reg n) with
    | some v => .ok v
    | none => .error (.stuck s!"register %{n} is read before it is set")
  | Operand.constant t v =>
    match infoOf t, parseIntLit v with
    | some (b, s), some k => .ok (Val.int (wrapTo b s k))
    | _, _ => .error (.stuck s!"constant of type {tyText t} is not an integer literal: {v}")
  | Operand.localVar x => .ok (Val.ptr (Block.slot x) 0)
  | Operand.null _ => .ok Val.null
  | Operand.global x => .error (.stuck s!"the address of the global @\"{x}\" is not modelled (only slots are blocks)")
  | Operand.fnRef x => .error (.stuck s!"the address of the function &\"{x}\" is not modelled")
  | o => .error (.stuck s!"operand {operandName o} not modelled")

/-- An operand where an integer is needed: a pointer there is stuck (pointer comparison, cast and arithmetic are
not modelled). -/
def evalOperand (env : Env) (o : Operand) : Except Outcome Int :=
  match evalVal env o with
  | .ok (Val.int k) => .ok k
  | .ok _ => .error (.stuck "a pointer value is used where an integer is needed (pointer comparison, cast and arithmetic are not modelled)")
  | .error e => .error e

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

/-! ### Memory: block pointers

A slot's byte size is declared by its `(slot "x" TYPE BYTES ALIGN)`. The frame declares it when the function
starts (`slotDecls`), as a cell of the environment, and a name declared twice in one function is a marker that
makes the block stuck. The bytes of a slot are cells too: a byte that is not written has no cell, and reading it
is stuck with "slot ... is read before it is written". An integer of `bits` bits takes `byteWidth bits` bytes,
little-endian (a bool takes one byte, and reads back as its low bit).

A load or store takes its width from its own type, not from the declared type of the slot: the bytes at its
offset are read or written as they are, so a store of one width can be read back with another. That is the
bit pattern reading of `bitcast`, not C++'s aliasing rules, which this slice does not check.

A pointer value is a block and a byte offset `0 ≤ off ≤ size`. The operand `$"x"` is the pointer to the first byte
of the slot, and `(null T)` is the null pointer. The rules, where C++ makes an operation undefined:
- `offset` past the end of the block is the trap "pointer out of bounds".
- `offset` of the null pointer by zero is the null pointer; by any other count it is the trap "offset of a null
  pointer".
- A load or store through the null pointer is the trap "null dereference".
- A load or store that reaches past the end of its block is the trap "pointer out of bounds".

A pointer (of any pointee type, or null) can be stored in a slot and loaded back: it occupies `ptrBytes` = 8 bytes,
the pointer size of the module layout. Its identity is not in those bytes: each of the 8 bytes holds the marker
`ptrByte`, and the side table `Cell.ptr x i` holds the pointer itself, keyed by the slot and the index of its
first byte. A load of a pointer type reads the side table entry at its offset; a store of a pointer writes the
markers and the entry. Any integer store over part of a stored pointer drops its entry and marks the bytes of it
that it does not overwrite as `ptrStale`. The rules for the bytes:
- A pointer load where the side table has no entry at its offset is stuck: if the bytes overlap a stored pointer
  that starts before the offset, "pointer bytes read at a different width are not modelled"; if an integer store
  overwrote part of it, the reason says so; otherwise the bytes hold no stored pointer.
- An integer load that reads a marker byte, of any width or offset, is stuck with "pointer bytes read at a
  different width are not modelled" (a stale byte says it was overwritten in part).
- A pointer load or store through a global, or of a pointer as an integer, is stuck as before. Storing an integer
  through a pointer type, or storing a pointer through an integer type, is stuck.

Stuck, with the reason: a pointer where an integer is needed (arithmetic, comparison, conditions, casts, call
arguments), an integer used as an address, a pointer bound to an integer register, `ret` of a pointer, a global or
a function address, `index`, `pdiff`, `copy`, `bfstore`, and a slot the function does not declare. -/

/-- The size of a pointer in bytes: the `(pointer 8)` of the module layout that the tests use. The semantics does
not read the layout, so a module with another pointer size needs this to follow it. -/
def ptrBytes : Nat := 8

/-- The marker in a byte of a stored pointer. It is not a byte value (0 to 255), so an integer read never sees it
as one. -/
def ptrByte : Int := 256

/-- The marker in a byte of a pointer whose side table entry was dropped by an integer store over part of it. -/
def ptrStale : Int := 257

def ptrPartialMsg : String := "pointer bytes read at a different width are not modelled"
def ptrStaleMsg : String := "a stored pointer was overwritten in part by an integer, so these bytes no longer hold it"

/-- The bytes an integer of `bits` bits takes in memory. -/
def byteWidth (bits : Nat) : Nat := (bits + 7) / 8

/-- The frame's declarations of the slots of a function: the byte size of each slot, or the marker of a name that is
declared more than once. -/
def slotDecls (slots : List Slot) : Env :=
  slots.map (fun s =>
    if (slots.filter (fun t => t.name == s.name)).length > 1 then (Cell.dup s.name, ⟨Val.int 0, none⟩)
    else (Cell.size s.name, ⟨Val.int s.bytes, none⟩))

/-- The byte size of a block. -/
def blockSize (env : Env) : Block → Except Outcome Int
  | Block.slot x =>
    match env.lookup (.dup x) with
    | some _ => .error (.stuck s!"slot $\"{x}\" is declared more than once in the function; scopes are not modelled")
    | none =>
      match env.get (.size x) with
      | some (Val.int n) => .ok n
      | _ => .error (.stuck s!"slot $\"{x}\" is not declared in the function")

/-- The integer at byte `off` of a slot, of `w` bytes: the bytes read from the most significant down (the
Horner form of the little-endian value). -/
def readBytes (env : Env) (x : String) (off : Nat) : Nat → Int → Except Outcome Int
  | 0, acc => .ok acc
  | k + 1, acc =>
    match env.get (.byte x (off + k)) with
    | some (Val.int b) =>
      if b == ptrByte then .error (.stuck ptrPartialMsg)
      else if b == ptrStale then .error (.stuck ptrStaleMsg)
      else readBytes env x off k (acc * 256 + b)
    | _ => .error (.stuck s!"slot $\"{x}\" is read before it is written")

/-- Whether a byte of a slot holds the marker `t`. -/
def byteIs (env : Env) (x : String) (i : Nat) (t : Int) : Bool :=
  match env.get (.byte x i) with
  | some (Val.int b) => b == t
  | _ => false

/-- Whether a stored pointer (its side table entry, starting at `j`) overlaps the bytes `[off, off + w)`. -/
def overlapsPtr (x : String) (off w : Nat) : Cell → Bool
  | Cell.ptr y j => y == x && decide (j < off + w) && decide (off < j + ptrBytes)
  | _ => false

/-- Drops the stored pointers that overlap the bytes `[off, off + w)` of a slot. The bytes of a dropped pointer that
are still markers become stale, so reading them is stuck. The caller then writes the bytes `[off, off + w)`. -/
def invalidatePtrs (env : Env) (x : String) (off w : Nat) : Env :=
  let hit := env.filter (fun p => overlapsPtr x off w p.1)
  let kept := env.filter (fun p => !overlapsPtr x off w p.1)
  hit.foldl (fun e p =>
    match p.1 with
    | Cell.ptr _ j =>
      (List.range ptrBytes).foldl (fun e2 k =>
        if byteIs e2 x (j + k) ptrByte then e2.set (.byte x (j + k)) (Val.int ptrStale) none else e2) e
    | _ => e) kept

/-- Writes an integer of `w` bytes at byte `off` of a slot, little-endian. A stored pointer that the bytes overlap
is dropped. -/
def writeBytes (env : Env) (x : String) (off w : Nat) (v : Int) : Env :=
  (List.range w).foldl (fun e i =>
    e.set (.byte x (off + i)) (Val.int ((v % 2 ^ (8 * w)) / 256 ^ i % 256)) none) (invalidatePtrs env x off w)

/-- Writes a pointer (or null) at byte `off` of a slot: the markers over its `ptrBytes` bytes, and the side table
entry. A stored pointer that the bytes overlap is dropped first. -/
def writePtr (env : Env) (x : String) (off : Nat) (v : Val) : Env :=
  let e := invalidatePtrs env x off ptrBytes
  let e := (List.range ptrBytes).foldl (fun e i => e.set (.byte x (off + i)) (Val.int ptrByte) none) e
  e.set (.ptr x off) v none

/-- The name of a memory access on a non-integer type, for the stuck messages. -/
def memKind (verb : String) (t : Ty) : String :=
  s!"{verb} of a non-integer type {tyText t}"

/-- The block and offset an address operand denotes for an access of `w` bytes, after the null and bounds checks. -/
def derefAddr (env : Env) (o : Operand) (w : Nat) : Except Outcome (Block × Int) := do
  match ← evalVal env o with
  | Val.null => throw (.trap "null dereference")
  | Val.int _ => throw (.stuck "an integer is used as an address")
  | Val.ptr b off =>
    let size ← blockSize env b
    if off < 0 ∨ size < off + (w : Int) then throw (.trap "pointer out of bounds")
    return (b, off)

/-- The integer a load of `bits` bits and signedness `signed` reads at `off` of a block. -/
def loadInt (env : Env) (b : Block) (off : Int) (bits : Nat) (signed : Bool) : Except Outcome Val :=
  match b with
  | Block.slot x => do
    let acc ← readBytes env x off.toNat (byteWidth bits) 0
    return Val.int (wrapTo bits signed acc)

/-- The pointer a load of a pointer type reads at `off` of a block: the side table entry there. The bytes at the
offset are not a stored pointer otherwise, and the reason says which way. -/
def loadPtr (env : Env) (b : Block) (off : Int) : Except Outcome Val :=
  match b with
  | Block.slot x =>
    let o := off.toNat
    match env.get (.ptr x o) with
    | some v => .ok v
    | none =>
      if (List.range ptrBytes).any (fun k => byteIs env x (o + k) ptrByte) then .error (.stuck ptrPartialMsg)
      else if (List.range ptrBytes).any (fun k => byteIs env x (o + k) ptrStale) then .error (.stuck ptrStaleMsg)
      else .error (.stuck "a pointer load from bytes that hold no stored pointer is not modelled")

/-- A value-producing form of integer type, in the subset. -/
def evalIntRValue (env : Env) : RValue → Except Outcome Int
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
  | RValue.conv ConvOp.bitcast t a => do
    -- the same width: the bit pattern is the value modulo 2^bits, read with the new signedness
    match infoOf t, operandInfo env a with
    | some (bits, signed), some (srcBits, _) =>
      if bits == srcBits then return wrapTo bits signed (← evalOperand env a)
      else throw (.stuck s!"bitcast between integer types of different widths ({srcBits} and {bits} bits)")
    | some _, none => throw (.stuck "bitcast of an operand that is not of an integer type")
    | none, _ => throw (.stuck "bitcast to or from a non-integer type (a pointer or an aggregate) is not modelled")
  | RValue.conv op _ _ => .error (.stuck s!"value form conv ({ConvOp.name op}) not modelled")
  | rv => .error (.stuck s!"value form {rvalueName rv} not modelled")

/-- A value-producing form: an operand, a load or an offset (the pointer forms), or an integer form. -/
def evalRValue (env : Env) : RValue → Except Outcome Val
  | RValue.operand o => evalVal env o
  | RValue.load _ (Ty.ptr _) a => do
    let (b, off) ← derefAddr env a ptrBytes
    loadPtr env b off
  | RValue.load _ t a => do
    let some (bits, signed) := infoOf t
      | throw (.stuck (memKind "load" t))
    let (b, off) ← derefAddr env a (byteWidth bits)
    loadInt env b off bits signed
  | RValue.offset a n => do
    match ← evalVal env a with
    | Val.ptr b off =>
      let size ← blockSize env b
      let r := off + (n : Int)
      if size < r then throw (.trap "pointer out of bounds")
      return Val.ptr b r
    | Val.null =>
      if n == 0 then return Val.null
      else throw (.trap "offset of a null pointer")
    | Val.int _ => throw (.stuck "offset of an integer")
  | rv => Val.int <$> evalIntRValue env rv

/-! ### Switch

The front end emits `(switch OP (body (block (case C) ... (default) ...)))`: the arms are the statements of
the body's block. A block has no scope of its own (registers are numbered across the function), so the blocks
at the top of a switch body are flattened into one list of arms. Labels are kept only at that top level: a label
nested in an `if` or a loop (Duff's device) would need a jump into that statement, and is `stuck`. A nested
`switch` owns its labels. -/

/-- The statements of a list with its top-level blocks flattened, in order. -/
def flattenBlocks : List Stmt → List Stmt
  | [] => []
  | Stmt.block ss :: rest => flattenBlocks ss ++ flattenBlocks rest
  | s :: rest => s :: flattenBlocks rest

mutual

/-- Whether a statement contains a case or default label (not counting the labels of a nested switch). -/
def hasLabel : Stmt → Bool
  | Stmt.caseS _ => true
  | Stmt.dflt => true
  | Stmt.ifS _ th el => anyLabel th || (match el with
    | none => false
    | some es => anyLabel es)
  | Stmt.loop body step => anyLabel body || anyLabel step
  | Stmt.block ss => anyLabel ss
  | _ => false

def anyLabel : List Stmt → Bool
  | [] => false
  | s :: ss => hasLabel s || anyLabel ss

end

/-- Whether a switch body has a label nested inside one of its arms. The top-level labels are not counted. -/
def nestedLabel : List Stmt → Bool
  | [] => false
  | Stmt.caseS _ :: rest => nestedLabel rest
  | Stmt.dflt :: rest => nestedLabel rest
  | s :: rest => hasLabel s || nestedLabel rest

/-- The arms from the first `case` whose value (converted to the type of the condition) is `v`, the label
itself included; none when no case matches. The case values are constants, read in order. -/
def findCase (env : Env) (bits : Nat) (signed : Bool) (v : Int) : List Stmt → Except Outcome (Option (List Stmt))
  | [] => return none
  | s@(Stmt.caseS c) :: rest => do
    let k ← evalOperand env c
    if wrapTo bits signed k == v then return some (s :: rest)
    else findCase env bits signed v rest
  | _ :: rest => findCase env bits signed v rest

/-- The arms from the `default` label, the label included; none when there is no default. -/
def findDefault : List Stmt → Option (List Stmt)
  | [] => none
  | Stmt.dflt :: rest => some (Stmt.dflt :: rest)
  | _ :: rest => findDefault rest

-- Statements and statement lists with their fuel: each level of nesting uses one unit, and each loop
-- iteration runs its body with the same fuel. Out of fuel is `stuck`. A call runs its callee with the fuel
-- of the statement that makes it and one nested call less (`Ctx.depth`), so a recursion is bounded too.

/-- What the statements run in: the functions of the module, for calls, and how many nested calls are still
allowed. -/
structure Ctx where
  prog : List Func
  depth : Nat

/-- The nested calls a run allows; a recursion deeper than this is out of fuel. -/
def callDepth : Nat := 1000

/-- The kind of a parameter, for the stuck messages. -/
def paramKind : Param → String
  | Param.sret .. => "sret"
  | Param.named .. => "named"
  | Param.byval .. => "byval"
  | Param.ellipsis => "ellipsis"

/-- The environment of a callee: its parameters bound to the arguments, each reduced into the integer type of
its parameter. The environment starts empty, so the callee's registers and slots are its own. -/
def bindArgs : List Param → List Int → Except Outcome Env
  | [], [] => .ok []
  | [], _ :: _ | _ :: _, [] => .error (.stuck "argument count does not match the parameters")
  | Param.named n nm t :: ps, v :: vs => do
    match infoOf t with
    | some (bits, signed) =>
      let rest ← bindArgs ps vs
      return rest.set (.reg n) (Val.int (wrapTo bits signed v)) (some (bits, signed))
    | none => .error (.stuck s!"parameter {nm} of non-integer type {tyText t} is not modelled")
  | p :: _, _ => .error (.stuck s!"a {paramKind p} parameter is not modelled")

mutual

def execStmt : Nat → Ctx → Env → Stmt → Except Outcome (Env × Flow)
  | 0, _, _, _ => .error (.stuck "out of fuel")
  | n + 1, ctx, env, s =>
    match s with
    | Stmt.letS r t (RValue.call cty callee va args) => do
      match ← callValue n ctx env cty callee va args with
      | some v => return (env.set (.reg r) (Val.int v) (infoOf t), .normal)
      | none => .error (.stuck s!"a call without a value is bound to %{r}")
    | Stmt.letS r t rv => do
      let v ← evalRValue env rv
      -- an integer register holds an integer
      if (infoOf t).isSome && !v.isInt then throw (.stuck s!"a pointer value is bound to %{r}, which has an integer type")
      return (env.set (.reg r) v (infoOf t), .normal)
    | Stmt.setS r o => do
      let v ← evalVal env o
      -- a register keeps the type it was declared with
      let info := match env.lookup (.reg r) with
        | some reg => reg.info
        | none => operandInfo env o
      if info.isSome && !v.isInt then throw (.stuck s!"a pointer value is assigned to %{r}, which has an integer type")
      return (env.set (.reg r) v info, .normal)
    | Stmt.storeS _ (Ty.ptr _) a val => do
      let (b, off) ← derefAddr env a ptrBytes
      let v ← evalVal env val
      if v.isInt then throw (.stuck "store of an integer into a pointer type is not modelled")
      match b with
      | Block.slot x =>
        return (writePtr env x off.toNat v, .normal)
    | Stmt.storeS _ t a val => do
      let some (bits, signed) := infoOf t
        | throw (.stuck (memKind "store" t))
      let (b, off) ← derefAddr env a (byteWidth bits)
      let k ← match (← evalVal env val) with
        | Val.int k => pure k
        | _ => throw (.stuck "store of a pointer value is not modelled")
      match b with
      | Block.slot x =>
        return (writeBytes env x off.toNat (byteWidth bits) (wrapTo bits signed k), .normal)
    | Stmt.evalS (RValue.call cty callee va args) => do
      -- the value of a call is discarded; a trap or a stuck form in the call still happens
      let _ ← callValue n ctx env cty callee va args
      return (env, .normal)
    | Stmt.evalS rv => do
      -- the value is discarded; a trap or a stuck form in it still happens
      let _ ← evalRValue env rv
      return (env, .normal)
    | Stmt.switchS c body => do
      let v ← evalOperand env c
      let some (bits, signed) := operandInfo env c
        | throw (.stuck "switch on an operand that is not of an integer type")
      let arms := flattenBlocks body
      if nestedLabel arms then
        throw (.stuck "a case label nested inside a statement of a switch body is not modelled")
      let start ← findCase env bits signed v arms
      match start <|> findDefault arms with
      | none => return (env, .normal)
      | some l => do
        let (env', fl) ← execSwitchList n ctx env l
        match fl with
        | .brk => return (env', .normal)
        | _ => return (env', fl)
    | Stmt.caseS _ | Stmt.dflt => .error (.stuck "case or default label outside a switch body")
    | Stmt.ifS c th el => do
      let v ← evalOperand env c
      if v != 0 then execList n ctx env th
      else match el with
        | none => return (env, .normal)
        | some es => execList n ctx env es
    | Stmt.loop body step => execLoop n ctx env body step
    | Stmt.block ss => execList n ctx env ss
    | Stmt.brk => return (env, .brk)
    | Stmt.cont => return (env, .cont)
    | Stmt.ret none => return (env, .ret none)
    | Stmt.ret (some o) => do
      match ← evalVal env o with
      | Val.int v => return (env, .ret (some v))
      | _ => throw (.stuck "returning a pointer is not modelled")
    | Stmt.unreachable => .error (.trap "unreachable")
    | Stmt.trap => .error (.trap "trap")
    | Stmt.loc _ _ | Stmt.likely | Stmt.unlikely => return (env, .normal)
    | st => .error (.stuck s!"statement {stmtName st} not modelled")

/-- A call of a function of the module, found by its linkage name. The arguments are evaluated in the caller's
environment; the callee runs in a fresh one, with one nested call less. Its return value, reduced into the
integer type of the call, is the value of the call; a call of type void has no value. A callee outside the
module, a variadic call, a count of arguments that differs from the parameters, and an indirect call are stuck. -/
def callValue : Nat → Ctx → Env → Ty → Operand → Option Nat → List Operand → Except Outcome (Option Int)
  | 0, _, _, _, _, _, _ => .error (.stuck "out of fuel")
  | k + 1, ctx, env, ty, callee, variadic, args => do
  let name ← match callee with
    | Operand.fnRef x => pure x
    | o => throw (.stuck s!"call through {operandName o} is not modelled")
  if variadic.isSome then throw (.stuck s!"variadic call of {name} is not modelled")
  let fn ← match ctx.prog.find? (fun f => f.linkage == name) with
    | some f => pure f
    | none => throw (.stuck s!"call of external function {name} is not modelled")
  if fn.params.length != args.length then
    throw (.stuck s!"call of {name} with {args.length} arguments, but it has {fn.params.length} parameter(s)")
  let vals ← args.mapM (evalOperand env)
  if ctx.depth == 0 then throw (.stuck "out of fuel: the calls are nested too deeply")
  let frame ← bindArgs fn.params vals
  let (_, fl) ← execList k { ctx with depth := ctx.depth - 1 } (slotDecls fn.slots ++ frame) fn.body
  let r : Option Int ← match fl with
    | .ret v => pure v
    | .normal => pure none
    | _ => throw (.stuck "break or continue outside a loop")
  if primName ty == some "void" then return none
  match infoOf ty with
  | none => throw (.stuck s!"call of {name} with a result of type {tyText ty} is not modelled")
  | some (bits, signed) =>
    match r with
    | some v => return some (wrapTo bits signed v)
    | none => throw (.stuck s!"call of {name} ends without a value")

/-- The arms of a switch from the chosen label on: control falls through them in order, and a label reached
this way does nothing. `break` is handled by the switch; `continue` and `return` leave it. -/
def execSwitchList : Nat → Ctx → Env → List Stmt → Except Outcome (Env × Flow)
  | 0, _, _, _ => .error (.stuck "out of fuel")
  | _ + 1, _, env, [] => return (env, .normal)
  | n + 1, ctx, env, s :: ss =>
    match s with
    | Stmt.caseS _ | Stmt.dflt => execSwitchList n ctx env ss
    | _ => do
      let (env', fl) ← execStmt n ctx env s
      match fl with
      | .normal => execSwitchList n ctx env' ss
      | _ => return (env', fl)

def execList : Nat → Ctx → Env → List Stmt → Except Outcome (Env × Flow)
  | 0, _, _, _ => .error (.stuck "out of fuel")
  | _ + 1, _, env, [] => return (env, .normal)
  | n + 1, ctx, env, s :: ss => do
    let (env', fl) ← execStmt n ctx env s
    match fl with
    | .normal => execList n ctx env' ss
    | _ => return (env', fl)

/-- A loop: run the body; `break` leaves it; `continue` or the end of the body runs the step, then the body
again. Each iteration uses one unit of fuel, and the body and the step run with the fuel that is left, so the
loop always ends. -/
def execLoop : Nat → Ctx → Env → List Stmt → List Stmt → Except Outcome (Env × Flow)
  | 0, _, _, _, _ => .error (.stuck "out of fuel")
  | f + 1, ctx, env, body, step => do
    let (env1, fl) ← execList f ctx env body
    match fl with
    | .brk => return (env1, .normal)
    | .ret v => return (env1, .ret v)
    | _ => do
      let (env2, fl2) ← execList f ctx env1 step
      match fl2 with
      | .normal => execLoop f ctx env2 body step
      | .brk => return (env2, .normal)
      | _ => return (env2, fl2)

end

/-- Runs a function without parameters, from its body, with the functions `prog` available to its calls.
Falling off the end gives `value none`. -/
def runFn (fuel : Nat) (prog : List Func) (fn : Func) : Outcome :=
  match execList fuel { prog := prog, depth := callDepth } (slotDecls fn.slots) fn.body with
  | .error o => o
  | .ok (_, .ret v) => .value v
  | .ok (_, .normal) => .value none
  | .ok (_, _) => .stuck "break or continue outside a loop"

/-- Runs a function without parameters on its own: it has no module, so every call in it is stuck. -/
def runFunc (fuel : Nat) (fn : Func) : Outcome :=
  if !fn.params.isEmpty then .stuck "functions with parameters are not modelled"
  else runFn fuel [] fn

/-- Runs the function named `name` of a module, without parameters; its calls reach the functions of `prog`. -/
def runNamed (fuel : Nat) (prog : List Func) (name : String) : Outcome :=
  match prog.find? (fun f => f.linkage == name) with
  | none => .stuck s!"no function {name} in the module"
  | some fn =>
    if !fn.params.isEmpty then .stuck "functions with parameters are not modelled"
    else runFn fuel prog fn

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
