// A generic linked stack built on a generic class, with push and pop returning
// optionals.
class Link<T> {
  let value: T
  let below: Link<T>?
  init(value: T, below: Link<T>?) {
    self.value = value
    self.below = below
  }
}

class Stack<T> {
  var top: Link<T>?
  init() {
    self.top = nil
  }
  func push(_ value: T) {
    top = Link(value: value, below: top)
  }
}

func first<T>(_ a: T, _ b: T) -> T {
  return a
}

let s = Stack<Int>()
s.push(3)
s.push(4)
if let t = s.top {
  print(t.value)
}
print(first(9, 1))
print(first(true, false))
