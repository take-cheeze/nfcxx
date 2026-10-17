// Overloaded methods and functions, chosen by argument labels and then by argument
// types. An argument of class type picks the non-Optional overload, since it is an
// exact match, while nil can only go to the Optional one.
struct Vec {
  let x: Int
  let y: Int
  func scaled(_ k: Int) -> Vec {
    return Vec(x: self.x * k, y: self.y * k)
  }
  func scaled(by k: Double) -> Double {
    return Double(self.x) * k + Double(self.y)
  }
  func moved(dx: Int, dy: Int) -> Vec {
    return Vec(x: self.x + dx, y: self.y + dy)
  }
  func moved(_ d: Vec) -> Vec {
    return self.moved(dx: d.x, dy: d.y)
  }
}

class Item {
  let weight: Int
  init(weight: Int) {
    self.weight = weight
  }
  init(weight: Bool) {
    if weight {
      self.weight = 100
    } else {
      self.weight = 0
    }
  }
  deinit {
    print(self.weight)
  }
}

class Log {
  var seen: Int
  init() {
    self.seen = 0
  }
  func keep(_ item: Item) {
    self.seen = self.seen + item.weight
  }
  func keep(_ item: Item?) {
    if let it = item {
      self.seen = self.seen + 1000 * it.weight
    } else {
      self.seen = self.seen - 1
    }
  }
}

func total(_ xs: [Int]) -> Int {
  var sum = 0
  for x in xs {
    sum = sum + x
  }
  return sum
}

func total(_ x: Int) -> Int {
  return x
}

let v = Vec(x: 2, y: 3)
print(v.scaled(4).x)
print(v.scaled(by: 1.5))
print(v.moved(Vec(x: 1, y: 1)).y)
print(v.moved(dx: 10, dy: 0).x)

let log = Log()
let a = Item(weight: 5)
log.keep(a)
log.keep(nil)
log.keep(Item(weight: 2))
print(log.seen)
print(total([1, 2, 3]))
print(total(4))

let h = Item(weight: true)
print(h.weight)
let h2 = Item(weight: 7)
print(h2.weight)
