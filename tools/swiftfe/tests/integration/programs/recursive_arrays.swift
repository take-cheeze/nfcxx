class Obj {
  let id: Int
  init(id: Int) {
    self.id = id
  }
  deinit {
    print(self.id + 1000)
  }
}

struct Tree {
  var label: Int
  var kids: [Tree]

  func sum() -> Int {
    var s = label
    for k in kids {
      s = s + k.sum()
    }
    return s
  }
}

enum Expr {
  case num(Int)
  case seq([Expr])
}

func evalE(_ e: Expr) -> Int {
  switch e {
  case .num(let n):
    return n
  case .seq(let es):
    var t = 0
    for x in es {
      t = t + evalE(x)
    }
    return t
  }
}

struct Holder<T> {
  var items: [T]
  var extra: Int
}

struct Bag2 {
  var objs: [Obj]
  var n: Int
}

class Owner {
  var bag: Bag2
  init(bag: Bag2) {
    self.bag = bag
  }
  func addObj(_ o: Obj) {
    bag.objs.append(o)
  }
}

func makeBag(_ n: Int) -> Bag2 {
  return Bag2(objs: [Obj(id: n)], n: n)
}

func demo() {
  let t = Tree(label: 1, kids: [Tree(label: 2, kids: []), Tree(label: 3, kids: [Tree(label: 4, kids: [])])])
  print(t.sum())
  let e = Expr.seq([.num(1), .seq([.num(2), .num(3)])])
  print(evalE(e))
  print(evalE(.num(5)))
  var h = Holder<Obj>(items: [Obj(id: 1)], extra: 2)
  let h2 = h
  h.items = []
  print(h2.items.count)
  let owner = Owner(bag: Bag2(objs: [Obj(id: 2)], n: 0))
  owner.addObj(Obj(id: 3))
  print(owner.bag.objs.count)
  var arr = [Holder<Obj>(items: [Obj(id: 4)], extra: 0)]
  arr.append(h2)
  print(arr.count)
  let fromFn = makeBag(6)
  print(fromFn.n)
  var list: [Bag2] = []
  list.append(fromFn)
  list.append(makeBag(7))
  print(list[1].objs.count)
}
demo()
print(0)
