class Counter {
  let base: Int
  init(base: Int) {
    self.base = base
  }
  func add(_ k: Int) -> Int {
    return self.base + k
  }
  func add(_ flag: Bool) -> Int {
    if flag {
      return self.base + 100
    }
    return self.base
  }
  func add(by k: Int, twice: Bool) -> Int {
    if twice {
      return self.base + 2 * k
    }
    return self.base + k
  }
  func both() -> Int {
    return add(1) + add(true)
  }
}

let c = Counter(base: 5)
print(c.add(2))
print(c.add(true))
print(c.add(false))
print(c.add(by: 3, twice: true))
print(c.add(by: 3, twice: false))
print(c.both())
