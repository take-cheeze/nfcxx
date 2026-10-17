func first<T>(_ a: T, _ b: T) -> T {
  return a
}

func pick<T>(_ flag: Bool, _ a: T, _ b: T) -> T {
  if flag {
    return a
  }
  return b
}

func twice<T>(_ x: T, _ f: (T) -> T) -> T {
  return f(f(x))
}

func count<T>(_ x: T, _ n: Int) -> Int {
  if n == 0 {
    return 0
  }
  return 1 + count(x, n - 1)
}

func wrap<T>(_ x: T) -> T {
  return pick(true, x, x)
}

func inc(_ n: Int) -> Int {
  return n + 1
}

print(first(1, 2))
print(first(true, false))
print(first<Int>(7, 8))
print(pick(false, 10, 20))
print(wrap(5))
print(twice(3, { $0 * 2 }))
print(twice(1, inc))
print(count(true, 3))
let f: (Bool, Bool) -> Bool = first
print(f(false, true))
