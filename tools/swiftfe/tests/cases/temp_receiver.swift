class Box {
  let n: Int
  init(n: Int) {
    self.n = n
  }
  deinit {
    print(self.n)
  }
  func value() -> Int {
    return self.n
  }
  func next() -> Box {
    return Box(n: self.n + 1)
  }
}

func make(_ n: Int) -> Box {
  return Box(n: n)
}

func twice(_ n: Int) -> Int {
  return make(n).next().value()
}

print(make(1).value())
let x = make(2).next().value()
print(x)
let b = make(20).next()
print(b.value())
var total = 0
total = make(7).value()
print(total)
print(twice(4))
let g: (Int) -> Int = { k in make(k).value() }
print(g(9))
