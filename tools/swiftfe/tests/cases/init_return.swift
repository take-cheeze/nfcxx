class Node {
  let id: Int
  init(id: Int) {
    self.id = id
  }
  deinit {
    print(self.id)
  }
}

class Pair {
  let first: Int
  let second: Int
  init(owner: Node, skip: Bool) {
    let scratch = Node(id: 50)
    self.first = owner.id
    if skip {
      self.second = 0
      return
    }
    self.second = scratch.id + 1
  }
}

struct Range2 {
  let lo: Int
  let hi: Int
  init(lo: Int, hi: Int) {
    self.lo = lo
    self.hi = hi
    if lo > hi {
      return
    }
    print(hi - lo)
  }
}

let a = Pair(owner: Node(id: 7), skip: true)
print(a.first)
print(a.second)
let b = Pair(owner: Node(id: 8), skip: false)
print(b.second)
let r = Range2(lo: 5, hi: 2)
print(r.lo)
let s = Range2(lo: 1, hi: 4)
print(s.hi)
