// Same-type requirements in where clauses: a generic struct and a generic function
// whose type parameter is fixed by the clause, used at the type that it fixes.
struct Scale<T> where T == Double {
  var factor: T
  func apply(_ x: T) -> T {
    return x * factor
  }
}

func twice<T>(_ x: T) -> T where T == Int {
  return x + x
}

func pick<T>(_ flag: Bool, _ a: T, _ b: T) -> T where T == Int {
  if flag {
    return a
  }
  return b
}

let s = Scale<Double>(factor: 2.5)
print(s.apply(4.0))
print(twice(21))
print(pick(false, 3, 4))
