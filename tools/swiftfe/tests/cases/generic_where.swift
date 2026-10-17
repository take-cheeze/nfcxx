func same<T>(_ a: T, _ b: T) -> Int where T == Int {
  return a + b
}

struct Scale<T> where T == Double {
  var factor: T
  func apply(_ x: T) -> T {
    return x * factor
  }
}

class Flag<T> where T == Bool {
  var on: T
}

func first<T>(_ a: T, _ b: T) -> T where T == Bool {
  return a
}

print(same(1, 2))
let s = Scale<Double>(factor: 2.5)
print(s.apply(4.0))
let f = Flag(on: true)
print(f.on)
print(first(true, false))
