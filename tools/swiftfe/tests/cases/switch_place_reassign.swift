class Node {
  let id: Int
  init(id: Int) {
    self.id = id
  }
  deinit {
    print(self.id + 700)
  }
}

enum Holder {
  case empty
  case list([Int])
  case one(Node)
}

func demo() {
  var e = Holder.list([1, 2, 3])
  switch e {
  case .empty:
    print(0)
  case .list(let xs):
    e = .empty
    print(xs.count)
  case .one(let n):
    print(n.id)
  }
  var f = Holder.one(Node(id: 1))
  switch f {
  case .empty:
    print(0)
  case .list(let xs):
    print(xs.count)
  case .one(let n):
    f = .empty
    print(n.id)
  }
  print(2)
}
demo()
print(0)
