// Function values: pass named functions and non-capturing closures around and apply them.
func apply(_ f: (Int) -> Int, _ x: Int) -> Int {
  return f(x)
}

func square(_ n: Int) -> Int {
  return n * n
}

let addOne: (Int) -> Int = { $0 + 1 }
let twice: (Int) -> Int = { $0 * 2 }
let both: (Int) -> Int = { $0 * 2 + 1 }
print(apply(square, 7))
print(apply(addOne, 41))
print(apply(both, 10))
print(apply({ (n: Int) -> Int in n - 3 }, 10))
