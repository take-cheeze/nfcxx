func applyTwice<T>(_ x: T, _ f: (T) -> T) -> T {
  return f(f(x))
}
func go(_ k: Int) -> Int {
  let g: (Int) -> Int = { applyTwice($0, { $0 + k }) }
  return g(1)
}
print(go(5))
func deep(_ a: Int) -> (Int) -> (Int) -> Int {
  return { (b: Int) -> (Int) -> Int in
    return { (c: Int) -> Int in
      return a * 100 + b * 10 + c
    }
  }
}
print(deep(1)(2)(3))
func shadow(_ k: Int) -> Int {
  let f: (Int) -> Int = { k in k * 2 }
  let h: (Int) -> Int = { let k = 7; return k + $0 }
  return f(k) + h(1)
}
print(shadow(4))
