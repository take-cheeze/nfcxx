class Obj {
  let id: Int
  init(id: Int) {
    self.id = id
  }
  deinit {
    print(self.id + 500)
  }
}

struct Stack {
  var items: [Obj]
  var label: Int
  init(n: Int) {
    items = []
    for i in 0..<n {
      items.append(Obj(id: i))
    }
    label = n
  }
  init(copying other: Stack) {
    self.items = other.items
    self.label = other.label + 1
  }
}

struct Box<T> {
  var values: [T]
  init(first: T) {
    values = [first]
  }
}

func demo() {
  var s = Stack(n: 2)
  let c = Stack(copying: s)
  s.items.append(Obj(id: 7))
  print(s.items.count)
  print(c.items.count)
  print(c.label)
  s = Stack(n: 1)
  print(s.items.count)
  let b = Box<Int>(first: 4)
  print(b.values[0])
  let bo = Box(first: Obj(id: 8))
  print(bo.values.count)
}
demo()
print(0)
