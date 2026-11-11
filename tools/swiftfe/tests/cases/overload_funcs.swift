func show(_ x: Int) -> Int {
  return x + 1
}
func show(_ x: Bool) -> Int {
  if x {
    return 10
  }
  return 20
}
func show(label x: Int) -> Int {
  return x * 2
}
func show(_ a: Int, _ b: Int) -> Int {
  return a * b
}
func pick(_ n: Int?) -> Int {
  if let v = n {
    return v
  }
  return -1
}
func pick(_ s: Bool) -> Int {
  if s {
    return 1
  }
  return 0
}
func twice(_ x: Int) -> Int {
  return show(x) + show(true)
}
print(show(1))
print(show(true))
print(show(label: 5))
print(show(2, 3))
print(pick(4))
print(pick(false))
print(pick(nil))
print(twice(3))
let f: (Bool) -> Int = show
print(f(false))
