// A small accumulator machine: an enum of instructions applied in sequence.
enum Instr {
  case push(Int)
  case add
  case mul
  case sub
  case neg
}

func step(_ acc: Int, _ instr: Instr) -> Int {
  switch instr {
  case .push(let v):
    return acc + v
  case .add:
    return acc + 1
  case .mul:
    return acc * 2
  case .sub:
    return acc - 1
  case .neg:
    return 0 - acc
  }
}

var acc = 0
acc = step(acc, .push(5))
acc = step(acc, .mul)
acc = step(acc, .push(7))
acc = step(acc, .add)
acc = step(acc, .neg)
acc = step(acc, .sub)
print(acc)
print(acc < 0)
