func apply(_ f: (Int) -> Int, _ x: Int) -> Int {
  return f(x)
}
func double(_ n: Int) -> Int {
  return n * 2
}
let triple: (Int) -> Int = { $0 * 3 }
print(apply(double, 5))
print(apply(triple, 5))
print(apply({ (n: Int) -> Int in n + 100 }, 1))
