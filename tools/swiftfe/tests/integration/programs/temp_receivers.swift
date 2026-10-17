// Methods called on temporary class values, in statements, conditions, loops and
// returns. A temporary is released as soon as the method that borrows it returns,
// so its deinit output comes before whatever the enclosing expression prints.
class Node {
  let key: Int
  init(key: Int) {
    self.key = key
  }
  deinit {
    print(self.key)
  }
  func weight() -> Int {
    return self.key * 10
  }
  func child() -> Node {
    return Node(key: self.key + 1)
  }
  func isBig() -> Bool {
    return self.key > 5
  }
}

func make(_ k: Int) -> Node {
  return Node(key: k)
}

func sumWeights(_ n: Int) -> Int {
  var sum = 0
  var i = 0
  while i < n {
    sum = sum + make(i).weight()
    i = i + 1
  }
  return sum
}

func deepest(_ k: Int) -> Int {
  return make(k).child().child().weight()
}

print(make(1).weight())
print(make(2).child().weight())
let kept = make(3).child()
print(kept.weight())
if make(7).isBig() {
  print(100)
}
print(sumWeights(3))
print(deepest(4))
var found = 0
for j in 0..<3 {
  if make(j).isBig() {
    found = found + 1
  }
}
print(found)
print(kept.key)
